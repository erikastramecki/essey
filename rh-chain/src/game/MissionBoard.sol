// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IEntropy, IEntropyConsumer} from "../market/EsseyCasesDegen.sol";
import {IDonLike, IGameController, IScrip, IHouseEscrow, GameRoles} from "./GameTypes.sol";
import {IAffinityRegistry} from "./IAffinityRegistry.sol";

/// MissionBoard — depart/resolve on the Cases/Degen engine. "The Degen
/// case IS a mission with no theme": pay in, reserve the worst case from a real budget, request
/// entropy, settle against a published cumPpm ladder, permissionless floor-reclaim if the keeper
/// stalls, credit the payout to the House hopper.
///
/// Phase-0 adaptations:
///  - 4 briefs (one per duration tier, lore codenames): the odds tables are
///    seeded at deploy and IMMUTABLE once posted (the Degen "disclosed odds can't be
///    swapped under holders" rule). The windowed BriefPoster is Phase-1; Phase 0 runs the permanent
///    core rows (liveness table: the board degrades to the safe on-ramp, never to zero).
///  - Payouts are Scrip, minted from a funded MISSION BUDGET with Degen-style worst-case
///    reservation: depart reverts unless the budget already covers the best possible outcome
///    (success pay + the full provisioning boost). No mission can ever be an unfunded liability.
///  - THE GAS LAW: the depart tx settles an EIP-712 signed loadout that freezes the garrison
///    commit for the whole away window — "you set your defenses before you leave." Recomposing the
///    garrison while home is a free re-sign; only the loadout presented at depart ever hits the
///    chain. The signature binds briefId + provision too, so a relayed loadout can never spend the
///    vault on terms the owner didn't sign (Phase 1 generalizes this into the LoadoutRegistry).
///  - Entropy is requested at RESOLVE, not depart (requesting at dispatch leaks
///    the outcome hours early, a free option on banking/garrison decisions).
///  - THE KIT (Phase-0 SIMPLIFIED): trait preimages live off-chain in the
///    reserve API, so the Phase-0 kit is KEEPER-ATTESTED — the keeper submits the Don's grip class
///    alongside its first resolve; `kitClaimed` latches forever (one kit per Don, ever; rerolls
///    never re-mint). Phase 1 replaces the attestation with the trustless resolver-picks derivation
///    WITHOUT redeploying Scrip or this board: the latch + class storage here are already the final
///    interface (`kitClaimed` / `kitClassOf`), only the attestor role re-points.
contract MissionBoard is IEntropyConsumer, ReentrancyGuard {
    // ---------------------------------------------------------------- types

    struct Brief {
        bool live;
        uint8 tier; // 1..4, display + telemetry
        uint32 duration; // seconds the Don is away
        uint32 cumSuccessPpm; // roll < this  => SUCCESS (full pay + provision boost)
        uint32 cumPartialPpm; // roll < this  => PARTIAL ("the job went sideways"); else FAIL
        uint256 successPay; // Scrip
        uint256 partialPay; // Scrip (the reclaim floor — never zero, never better than a roll)
        uint256 dispatchFee; // Scrip, burned (1.5% of E[payout], the rate card)
        uint256 provisionCap; // Scrip
        uint256 betaBps; // success-payout boost per provisioned Scrip (90% marginal RTP)
        string codename; // lore surface (GLASS HARVEST, ...)
    }

    /// The EIP-712 depart intent. Signed by ownerOf(donId); submittable by anyone (relayer/session
    /// key), which is why it binds the brief and the provision — the signature authorizes exactly
    /// one shaped spend, and the garrison hash rides the same signature (the gas law).
    struct Loadout {
        uint256 donId;
        uint64 briefId;
        uint256 provision;
        bytes32 garrisonHash; // keccak256(abi.encode(garrisonHitterIds, salt)); 0 = openly ungarrisoned
        uint256 nonce;
        uint256 deadline;
    }

    struct Mission {
        uint256 donId;
        uint64 briefId;
        uint64 departAt;
        uint64 due;
        bytes32 garrisonHash;
        uint256 provision;
        uint256 reserved; // worst-case Scrip reserved from the budget at depart
        bool entropyRequested;
        bool settled;
    }

    // ---------------------------------------------------------------- config

    IGameController public immutable controller;
    IScrip public immutable scrip;
    IDonLike public immutable don;
    IHouseEscrow public immutable escrow;
    IEntropy public immutable entropy;
    address public immutable entropyProvider;
    uint32 public immutable callbackGasLimit;
    /// Zero address = traits off. statsOf() returns a zero sheet for an unattested Don, so an
    /// un-attested player simply gets the published odds rather than an error.
    IAffinityRegistry public immutable affinity;

    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant BPS = 10_000;
    /// NRV is bps of PROBABILITY (100 = +1pp) and the bands are ppm, so 1 bps of probability is
    /// 100 ppm. The Edge Budget caps a whole sheet at 1000 bps, i.e. +10pp of success at most.
    uint256 internal constant BPS_TO_PPM = 100;
    /// Unresolved past due + grace => anyone may floor-settle at PARTIAL (the Degen
    /// reclaim philosophy: the valve is never better than a real roll, so it only un-sticks).
    uint256 public constant RECLAIM_GRACE = 2 hours;

    bytes32 public constant LOADOUT_TYPEHASH = keccak256(
        "Loadout(uint256 donId,uint64 briefId,uint256 provision,bytes32 garrisonHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ---------------------------------------------------------------- state

    uint64 public briefCount;
    mapping(uint64 => Brief) public briefs;

    uint64 public missionCount;
    mapping(uint64 => Mission) public missions;
    mapping(uint256 => uint64) public activeMissionOf; // donId => missionId (0 = home)
    mapping(uint64 => uint64) public seqToMission; // entropy seq => missionId

    /// Per-TOKEN monotonic loadout nonce (the gas law). Stale signatures also die on transfer
    /// because the signer must equal the CURRENT owner at settle time.
    mapping(uint256 => uint256) public lastSettledNonce;

    mapping(uint256 => bool) public hasDispatched;
    mapping(uint256 => bool) public kitClaimed; // the kit latch — one kit per Don, EVER
    mapping(uint256 => uint8) public kitClassOf; // keeper-attested grip class (Phase-0; see header)

    uint256 public missionBudget; // funded emission line (S_declared events)
    uint256 public outstandingReserved; // Σ live reservations — must drain to 0 before a generation retires

    // ---------------------------------------------------------------- events / errors

    event BriefPosted(uint64 indexed briefId, string codename, uint8 tier, uint32 duration);
    event Departed(
        uint64 indexed missionId,
        uint256 indexed donId,
        uint64 indexed briefId,
        uint256 provision,
        uint256 fee,
        uint256 reserved,
        bytes32 garrisonHash
    );
    event ResolveRequested(uint64 indexed missionId, uint64 seq);
    event Resolved(uint64 indexed missionId, uint256 indexed donId, uint8 outcome, uint256 payout);
    event Reclaimed(uint64 indexed missionId, uint256 indexed donId, uint256 payout);
    event KitAttested(uint256 indexed donId, uint8 gripClass);
    event BudgetFunded(uint256 amount, uint256 newTotal);

    error NotAdmin();
    error NotKeeper();
    error BadBrief();
    error BriefNotLive();
    error GenerationClosed();
    error AlreadyAway();
    error BadLoadout();
    error LoadoutExpired();
    error StaleNonce();
    error NotOwnerSignature();
    error OverProvisionCap();
    error InsufficientBudget();
    error UnknownMission();
    error NotDue();
    error AlreadyRequested();
    error AlreadySettledMission();
    error NotYetReclaimable();
    error InsufficientFee();
    error RefundFailed();
    error KitAlreadyClaimed();
    error NeverDispatched();
    error BadConfig();

    constructor(
        IGameController controller_,
        IScrip scrip_,
        IDonLike don_,
        IHouseEscrow escrow_,
        IEntropy entropy_,
        address entropyProvider_,
        uint32 callbackGasLimit_,
        IAffinityRegistry affinity_
    ) {
        if (
            address(controller_) == address(0) || address(scrip_) == address(0)
                || address(don_) == address(0) || address(escrow_) == address(0)
                || address(entropy_) == address(0) || callbackGasLimit_ == 0
        ) revert BadConfig();
        controller = controller_;
        affinity = affinity_;
        scrip = scrip_;
        don = don_;
        escrow = escrow_;
        entropy = entropy_;
        entropyProvider = entropyProvider_;
        callbackGasLimit = callbackGasLimit_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DON-Loadout")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    // ---------------------------------------------------------------- briefs (immutable rows)

    /// Post a brief. Admin-only (deploy-time seeding in Phase 0), IMMUTABLE once posted — there is
    /// deliberately no edit/retire path: disclosed odds can't be swapped under holders (the Degen
    /// rule), and the core rows never expire (liveness: the board degrades to the safe on-ramp,
    /// never to zero). New odds = new brief in the NEXT generation's board.
    function postBrief(
        string calldata codename,
        uint8 tier,
        uint32 duration,
        uint32 cumSuccessPpm,
        uint32 cumPartialPpm,
        uint256 successPay,
        uint256 partialPay,
        uint256 dispatchFee,
        uint256 provisionCap,
        uint256 betaBps
    ) external returns (uint64 briefId) {
        if (msg.sender != controller.admin()) revert NotAdmin();
        // The Degen ladder-validation discipline: strictly increasing bands terminating inside PPM,
        // and a floor (partial) that a real roll always weakly beats.
        if (
            duration == 0 || cumSuccessPpm == 0 || cumPartialPpm <= cumSuccessPpm || cumPartialPpm > PPM
                || successPay == 0 || partialPay == 0 || partialPay >= successPay
        ) revert BadBrief();
        briefId = ++briefCount;
        briefs[briefId] = Brief({
            live: true,
            tier: tier,
            duration: duration,
            cumSuccessPpm: cumSuccessPpm,
            cumPartialPpm: cumPartialPpm,
            successPay: successPay,
            partialPay: partialPay,
            dispatchFee: dispatchFee,
            provisionCap: provisionCap,
            betaBps: betaBps,
            codename: codename
        });
        emit BriefPosted(briefId, codename, tier, duration);
    }

    /// Fund the mission-payout emission line — the visible, admin-signed budget event.
    function fundMissionBudget(uint256 amount) external {
        if (msg.sender != controller.admin()) revert NotAdmin();
        missionBudget += amount;
        emit BudgetFunded(amount, missionBudget);
    }

    // ---------------------------------------------------------------- depart

    /// Send a Don on a job. One tx does everything the gas law allows to cost gas: settles the
    /// signed loadout, freezes the garrison commit, auto-claims the free Safehouse (+ stipend) on
    /// first play, burns the dispatch fee and the provision (both Scrip sinks), and reserves the
    /// worst-case payout from the budget (the Degen `buy` reservation, in Scrip).
    ///
    /// The Don is soft-locked (state, not custody — the NFT never moves): a locked Don can't depart
    /// again, deploy, or bank until resolve/reclaim brings him home. `reclaim` is permissionless, so
    /// the lock ALWAYS expires, dead keeper or not.
    function depart(Loadout calldata l, bytes calldata sig) external nonReentrant returns (uint64 missionId) {
        if (controller.closed()) revert GenerationClosed(); // no NEW exposure after close()
        Brief storage b = briefs[l.briefId];
        if (!b.live) revert BriefNotLive();
        if (activeMissionOf[l.donId] != 0) revert AlreadyAway();
        if (l.provision > b.provisionCap) revert OverProvisionCap();
        _settleLoadout(l, sig);

        // First-play funnel: free Safehouse + one-time stipend, before any charge.
        escrow.ensureHouse(l.donId);

        address vault = don.vaultOf(l.donId);
        scrip.burn(vault, b.dispatchFee); // rate card: Scrip-mode dispatch fees burn
        if (l.provision > 0) scrip.burn(vault, l.provision); // consumed at dispatch — the gamble

        // Worst-case reservation BEFORE the roll exists (the solvency law): best outcome is
        // success pay + the full provisioning boost.
        uint256 worst = b.successPay + (l.provision * b.betaBps) / BPS;
        if (missionBudget < worst) revert InsufficientBudget();
        missionBudget -= worst;
        outstandingReserved += worst;

        missionId = ++missionCount;
        missions[missionId] = Mission({
            donId: l.donId,
            briefId: l.briefId,
            departAt: uint64(block.timestamp),
            due: uint64(block.timestamp) + b.duration,
            garrisonHash: l.garrisonHash,
            provision: l.provision,
            reserved: worst,
            entropyRequested: false,
            settled: false
        });
        activeMissionOf[l.donId] = missionId;
        hasDispatched[l.donId] = true;

        emit Departed(missionId, l.donId, l.briefId, l.provision, b.dispatchFee, worst, l.garrisonHash);
    }

    /// EIP-712 settlement (the gas law): recover the signer, require it to be the CURRENT owner
    /// (transfer therefore kills every prior owner's signatures with no epoch bookkeeping), enforce
    /// deadline + per-token monotonic nonce.
    function _settleLoadout(Loadout calldata l, bytes calldata sig) internal {
        if (l.deadline < block.timestamp) revert LoadoutExpired();
        if (l.nonce <= lastSettledNonce[l.donId]) revert StaleNonce();
        bytes32 structHash = keccak256(
            abi.encode(LOADOUT_TYPEHASH, l.donId, l.briefId, l.provision, l.garrisonHash, l.nonce, l.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (ECDSA.recover(digest, sig) != don.ownerOf(l.donId)) revert NotOwnerSignature();
        lastSettledNonce[l.donId] = l.nonce;
    }

    // ---------------------------------------------------------------- resolve / reclaim

    /// The entropy fee the resolver must send (ETH) — Degen pattern, excess refunded.
    function entropyFee() public view returns (uint256) {
        return entropy.getFeeV2(entropyProvider, callbackGasLimit);
    }

    /// Request the roll — at expiry, never at dispatch. Permissionless on purpose:
    /// the keeper normally runs it (and pays), but a stalled keeper can't stall a mission — anyone
    /// can trigger the roll, and `reclaim` floors it if even the entropy never lands.
    function resolve(uint64 missionId) external payable nonReentrant {
        Mission storage m = missions[missionId];
        if (m.donId == 0) revert UnknownMission();
        if (m.settled) revert AlreadySettledMission();
        if (block.timestamp < m.due) revert NotDue();
        if (m.entropyRequested) revert AlreadyRequested();
        m.entropyRequested = true;

        uint256 fee = entropyFee();
        if (msg.value < fee) revert InsufficientFee();
        bytes32 userRandom = keccak256(abi.encodePacked(msg.sender, missionId, blockhash(block.number - 1)));
        uint64 seq = entropy.requestV2{value: fee}(entropyProvider, userRandom, callbackGasLimit);
        seqToMission[seq] = missionId;
        emit ResolveRequested(missionId, seq);

        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// Entropy settlement: one roll against the brief's published cumPpm bands.
    /// outcome 0 = SUCCESS (full pay + provision boost) / 1 = PARTIAL (0.4x-class consolation) /
    /// 2 = FAIL (nothing lands; the provision was already consumed at dispatch).
    function entropyCallback(uint64 sequenceNumber, address, bytes32 randomNumber) internal override nonReentrant {
        uint64 missionId = seqToMission[sequenceNumber];
        Mission storage m = missions[missionId];
        if (missionId == 0 || m.settled) revert AlreadySettledMission();
        Brief storage b = briefs[m.briefId];

        uint256 roll = uint256(randomNumber) % PPM;
        uint256 cumSuccess = _successBandFor(m.donId, b);
        uint8 outcome;
        uint256 payout;
        if (roll < cumSuccess) {
            outcome = 0;
            payout = b.successPay + (m.provision * b.betaBps) / BPS;
        } else if (roll < _maxUint(cumSuccess, b.cumPartialPpm)) {
            outcome = 1;
            payout = b.partialPay;
        } else {
            outcome = 2;
            payout = 0;
        }
        _settle(m, payout);
        emit Resolved(missionId, m.donId, outcome, payout);
    }

    /// NRV widens the success band. Two things this must never do, and does not:
    ///   - break solvency. depart() reserves the BEST outcome from a funded budget before any roll
    ///     exists, so shifting probability toward success can only spend a reservation that was
    ///     already made. It cannot create an unfunded liability.
    ///   - erase the partial band. Success is capped at cumPartialPpm, so PARTIAL can shrink to
    ///     nothing but FAIL always keeps whatever cumPartialPpm left it.
    /// An unattested Don reads a zero sheet and gets exactly the published odds.
    function _successBandFor(uint256 donId, Brief storage b) internal view returns (uint256) {
        if (address(affinity) == address(0)) return b.cumSuccessPpm;
        uint256 nrvBps;
        try affinity.statsOf(donId) returns (IAffinityRegistry.Stats memory st) {
            nrvBps = uint256(st.nrvBps);
        } catch {
            return b.cumSuccessPpm; // a registry fault must never strand a settlement
        }
        if (nrvBps == 0) return b.cumSuccessPpm;
        uint256 widened = uint256(b.cumSuccessPpm) + nrvBps * BPS_TO_PPM;
        return widened > b.cumPartialPpm ? b.cumPartialPpm : widened;
    }

    function _maxUint(uint256 a, uint256 c) private pure returns (uint256) {
        return a > c ? a : c;
    }

    /// The floor valve (permissionless, the Degen `reclaim` philosophy): a mission unresolved past
    /// due + grace settles at the PARTIAL floor — never zero (the player did the time), never
    /// better than a real roll (so stalling can't be farmed) — and the Don comes home. This is the
    /// guarantee behind every "lock" in the game: liveness failure degrades, it never strands.
    function reclaim(uint64 missionId) external nonReentrant {
        Mission storage m = missions[missionId];
        if (m.donId == 0) revert UnknownMission();
        if (m.settled) revert AlreadySettledMission();
        if (block.timestamp < uint256(m.due) + RECLAIM_GRACE) revert NotYetReclaimable();
        uint256 payout = briefs[m.briefId].partialPay;
        _settle(m, payout);
        emit Reclaimed(missionId, m.donId, payout);
    }

    /// Common settlement: release the reservation (unspent budget returns to the pool — the drain
    /// discipline that lets a closed generation retire at outstandingReserved == 0), mint the
    /// payout to the escrow and land it in the House hopper, unlock the Don.
    function _settle(Mission storage m, uint256 payout) internal {
        m.settled = true;
        activeMissionOf[m.donId] = 0;
        missionBudget += m.reserved - payout;
        outstandingReserved -= m.reserved;
        if (payout > 0) {
            scrip.mint(address(escrow), payout);
            escrow.creditLoot(m.donId, payout);
        }
    }

    // ---------------------------------------------------------------- the kit (Phase-0 attested)

    /// Keeper-attested Starting Kit (Phase-0 SIMPLIFIED — see the contract header): the keeper
    /// submits the grip class read from the Don's resolved art alongside the first resolve. Latches
    /// forever; rerolls never re-mint and never revoke. Phase 1 swaps the attestor for the
    /// trustless resolver-picks derivation behind the same latch + storage — no redeploy of Scrip
    /// or this board.
    function attestKit(uint256 donId, uint8 gripClass) external {
        if (msg.sender != controller.moduleOf(GameRoles.KEEPER)) revert NotKeeper();
        if (!hasDispatched[donId]) revert NeverDispatched();
        if (kitClaimed[donId]) revert KitAlreadyClaimed();
        kitClaimed[donId] = true;
        kitClassOf[donId] = gripClass;
        emit KitAttested(donId, gripClass);
    }

    // ---------------------------------------------------------------- views

    function isAway(uint256 donId) external view returns (bool) {
        return activeMissionOf[donId] != 0;
    }

    /// The frozen garrison commit for the Don's LIVE mission (0 while home / ungarrisoned) — the
    /// RaidEngine's defense input, provably committed before any raid against this window.
    function garrisonHashOf(uint256 donId) external view returns (bytes32) {
        uint64 missionId = activeMissionOf[donId];
        if (missionId == 0) return bytes32(0);
        return missions[missionId].garrisonHash;
    }
}
