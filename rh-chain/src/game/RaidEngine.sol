// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IEntropy, IEntropyConsumer} from "../market/EsseyCasesDegen.sol";
import {IAffinityRegistry} from "./IAffinityRegistry.sol";
import {
    IDonLike,
    IGameController,
    IScrip,
    IHouseDeed,
    IHouseEscrow,
    IMissionBoard,
    IHitterGame,
    GameRoles
} from "./GameTypes.sol";

/// RaidEngine — commit-reveal house robbery, Phase 0's single raid type. The Cases
/// entropy engine + a commit-reveal shell + the power/odds model below.
///
/// The window law: a House is robbable ONLY while its Don is away (MissionBoard flags the window),
/// and the defense was FROZEN at the defender's depart tx (the garrison commit rode the loadout —
/// the gas law). The commit provably predates every raid against the window; no equip-front-run is
/// possible because the garrison literally cannot change.
///
/// The roll (one entropy word, partitioned reads — the Degen `_multiplierFor` idiom):
///   p_hit  = clamp(0.72 x A/(A+D), 5%, 70%)          A = crew power (cooldown-diminished)
///   two-tier on success, cumPpm [920000, 1e6]:        D = House HD + garrison power x 0.95
///     92% COMMON  — the hopper (unbanked yield/loot, never principal) transfers, -40% debuff
///      8% BIG     — 15% + 15%·u² of DEPLOYED (the Scrip band, mean 20%, max 30%),
///                   48h per-House lockout (the principal-drain hard cap at the Scrip-mode floor)
///   on miss: P(kill|fail) = 0.15 + 0.35 x D/(A+D) per Hitter — 48h hospital (kit loss is Phase 1)
///   7.5% hit tax burned on every transfer, applied inside HouseEscrow.
///
/// Cooldown is STRATEGY, not a revert: early hunting is allowed at (t/20h)²-diminished
/// power, so patience strictly dominates and ~1.2 full-odds attempts/day/Hitter is the natural rate
/// limit — the curve IS the bookkeeping.
///
/// THE ROLL IS DRAWN LAST (audit fix — H-1, 2026-08-19): no entropy is requested until the defence
/// is FIXED, so the word lands and settles in one transaction. Requesting at reveal published it
/// into the public `raids` mapping an hour early, which priced two free options for the defender:
/// open the garrison to flip a known hit, or come home and bank ahead of it.
///
/// Liveness (the Degen reclaim ethic — the keeper can grief liveness, never solvency, never exits):
///   - garrison never revealed  => the roll is drawn at the floor: it runs with the garrison
///     counting for zero (House defends alone, worst p_hit). Suppressing the reveal never dodges
///     loot/principal — it only forfeits the defensive bonus a reveal would have proven.
///   - entropy withheld         => reclaim: MISS outcome, no transfers, cooldowns stand. The commit
///     fee stays sunk (sunk win-or-lose — the rate card is canonical over an earlier
///     "stake returned" sketch; a refund would need a mint, and raids never mint).
///   - roll never drawn         => the same reclaim, clocked from when it BECAME drawable.
///   - no reveal in the window  => forfeit: the held fee burns. (Bonding the fee to the target needs
///     the target's identity, which only the reveal discloses — flagged as a Phase-0 deviation.)
contract RaidEngine is IEntropyConsumer, ReentrancyGuard {
    // ---------------------------------------------------------------- config

    IGameController public immutable controller;
    IScrip public immutable scrip;
    IDonLike public immutable don;
    IHouseDeed public immutable deed;
    IHouseEscrow public immutable escrow;
    IMissionBoard public immutable board;
    IHitterGame public immutable hitter;
    IEntropy public immutable entropy;
    address public immutable entropyProvider;
    uint32 public immutable callbackGasLimit;

    uint256 internal constant PPM = 1_000_000;

    /// $0.50 flat per attempt at the peg, sunk win-or-lose — prices ATTEMPTS, undodgeable by
    /// target selection.
    uint256 public constant COMMIT_FEE = 50e18;
    /// Reveal window [10, 40] min after commit — kills mempool sniping both directions.
    uint256 public constant REVEAL_DELAY = 10 minutes;
    uint256 public constant REVEAL_WINDOW = 40 minutes;
    /// Hitter cooldown anchor for the (t/20h)^2 diminished-odds curve.
    uint256 public constant COOLDOWN = 20 hours;
    /// Target immunity after any resolved attempt (<= 2 attempts/target/day).
    uint256 public constant HEAT = 8 hours;
    /// One attempt per attacker-target pair per 24h (no focus-fire).
    uint256 public constant PAIR_COOLDOWN = 24 hours;
    /// Scrip-mode big-score lockout: 48h per House.
    uint256 public constant BIG_SCORE_LOCKOUT = 48 hours;
    /// Garrison unrevealed this long after the raid reveal => the roll is drawable at the floor.
    uint256 public constant GARRISON_TIMEOUT = 1 hours;
    /// Entropy withheld this long after the roll became drawable => reclaim (miss).
    uint256 public constant RECLAIM_TIMEOUT = 2 hours;

    // The power/odds constants (ppm / bps where rolled on-chain).
    uint256 public constant TWO_TIER_CUM_PPM = 920_000; // 92 common / 8 big
    uint256 public constant P_COEF_PPM = 720_000; // 0.72 coefficient
    uint256 public constant P_MIN_PPM = 50_000; // 5% floor — every commit is a real gamble
    uint256 public constant P_MAX_PPM = 700_000; // 70% ceiling — never a sure thing
    uint256 public constant KILL_BASE_PPM = 150_000;
    uint256 public constant KILL_SLOPE_PPM = 350_000;
    /// Zero address = traits off. An unattested Don reads a zero sheet and fights at base power.
    IAffinityRegistry public immutable affinity;

    uint256 public constant BASE_POWER = 50; // HitterPower at L1 (levels are Phase 1)
    uint256 public constant GARRISON_EFF_BPS = 9_500; // defenders fight at 0.95x
    uint256 public constant MAX_CREW = 5; // the crew cap

    // ---------------------------------------------------------------- state

    enum RaidState {
        Committed,
        Revealed,
        Settled,
        Forfeited
    }

    struct Raid {
        uint256 attackerDon;
        uint256 targetDon; // 0 until revealed
        uint64 committedAt;
        uint64 revealedAt;
        bytes32 commitHash;
        bytes32 garrisonHash; // snapshot of the frozen commit, taken at reveal
        uint256 attackPower; // x1e6 (cooldown-diminished), fixed at reveal
        uint256 defensePower; // x1e6, fixed at garrison reveal
        bytes32 word;
        RaidState state;
        bool wordReceived;
        bool garrisonRevealed;
    }

    uint64 public raidCount;
    mapping(uint64 => Raid) public raids;
    /// 0 until the roll is drawn; non-zero implies the defence was already fixed. Kept beside the
    /// struct, not in it: a 13th field overflows the stack in every caller decoding `raids`.
    mapping(uint64 => uint64) public rollRequestedAt;
    mapping(uint64 => uint256[]) internal _crew; // raidId => attacker hitter ids
    mapping(uint64 => uint64) public seqToRaid;

    mapping(uint256 => uint64) public heatUntil; // targetDon => immunity end
    mapping(uint256 => uint64) public bigLockUntil; // targetDon => big-score lockout end
    mapping(uint256 => mapping(uint256 => uint64)) public lastPairAttempt; // attacker => target => ts

    // ---------------------------------------------------------------- events / errors

    event RaidCommitted(uint64 indexed raidId, uint256 indexed attackerDon, bytes32 commitHash);
    event RaidRevealed(
        uint64 indexed raidId, uint256 indexed attackerDon, uint256 indexed targetDon, uint256 attackPower, uint64 seq
    );
    event GarrisonRevealed(uint64 indexed raidId, uint256 indexed targetDon, uint256 defensePower);
    /// outcome: 0 MISS / 1 COMMON hit / 2 BIG score / 4 RECLAIMED (entropy withheld). A suppressed
    /// garrison is not its own outcome — it settles as the real roll it always was, at House-only
    /// defense, so 3 is retired and never emitted.
    event RaidSettled(uint64 indexed raidId, uint8 outcome, uint256 pHitPpm, uint256 taken, uint256 tax);
    event HitterDown(uint64 indexed raidId, uint256 indexed hitterId);
    event RaidForfeited(uint64 indexed raidId);

    error NotDonOwner();
    error GenerationClosed();
    error UnknownRaid();
    error WrongState();
    error RevealTooEarly();
    error RevealTooLate();
    error CommitMismatch();
    error TargetNotAway();
    error TargetOnHeat();
    error PairCooldown();
    error SelfRaid();
    error BadCrew();
    error HitterUnavailable();
    error GarrisonMismatch();
    error TooManyGarrison();
    error NotYetTimedOut();
    error InsufficientFee();
    error RefundFailed();
    error AlreadyDelivered();

    constructor(
        IGameController controller_,
        IScrip scrip_,
        IDonLike don_,
        IHouseDeed deed_,
        IHouseEscrow escrow_,
        IMissionBoard board_,
        IHitterGame hitter_,
        IEntropy entropy_,
        address entropyProvider_,
        uint32 callbackGasLimit_,
        IAffinityRegistry affinity_
    ) {
        controller = controller_;
        affinity = affinity_;
        scrip = scrip_;
        don = don_;
        deed = deed_;
        escrow = escrow_;
        board = board_;
        hitter = hitter_;
        entropy = entropy_;
        entropyProvider = entropyProvider_;
        callbackGasLimit = callbackGasLimit_;
    }

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    function crewOf(uint64 raidId) external view returns (uint256[] memory) {
        return _crew[raidId];
    }

    function entropyFee() public view returns (uint256) {
        return entropy.getFeeV2(entropyProvider, callbackGasLimit);
    }

    // ---------------------------------------------------------------- commit

    /// Commit a salted raid: h = keccak256(abi.encode(attackerDonId, hitterIds, targetDonId, salt)).
    /// The target stays hidden until reveal (the fog the Scout economy prices later). The commit fee
    /// moves into the engine and burns at reveal (sunk) or at forfeit.
    function commit(uint256 attackerDonId, bytes32 h) external nonReentrant returns (uint64 raidId) {
        if (controller.closed()) revert GenerationClosed(); // no NEW aggression after close()
        if (don.ownerOf(attackerDonId) != msg.sender) revert NotDonOwner();
        scrip.move(don.vaultOf(attackerDonId), address(this), COMMIT_FEE);
        raidId = ++raidCount;
        Raid storage r = raids[raidId];
        r.attackerDon = attackerDonId;
        r.committedAt = uint64(block.timestamp);
        r.commitHash = h;
        emit RaidCommitted(raidId, attackerDonId, h);
    }

    // ---------------------------------------------------------------- reveal

    /// Open the commit inside the [10, 40] min window, prove the target is exposed (away-window
    /// law), lock in the crew's cooldown-diminished attack power, note every Hitter's attempt
    /// (cooldown restarts win or lose), and burn the fee.
    ///
    /// The roll is drawn here only against an openly ungarrisoned target, whose defence is already
    /// final. Behind a live garrison commit the fee is returned and the roll waits (H-1).
    function reveal(uint64 raidId, uint256[] calldata hitterIds, uint256 targetDonId, bytes32 salt)
        external
        payable
        nonReentrant
        returns (uint64 seq)
    {
        Raid storage r = raids[raidId];
        if (r.attackerDon == 0) revert UnknownRaid();
        if (r.state != RaidState.Committed) revert WrongState();
        if (don.ownerOf(r.attackerDon) != msg.sender) revert NotDonOwner();
        if (block.timestamp < r.committedAt + REVEAL_DELAY) revert RevealTooEarly();
        if (block.timestamp > r.committedAt + REVEAL_WINDOW) revert RevealTooLate();
        if (keccak256(abi.encode(r.attackerDon, hitterIds, targetDonId, salt)) != r.commitHash) {
            revert CommitMismatch();
        }
        if (targetDonId == r.attackerDon) revert SelfRaid();
        if (!board.isAway(targetDonId)) revert TargetNotAway();
        if (block.timestamp < heatUntil[targetDonId]) revert TargetOnHeat();
        if (block.timestamp < lastPairAttempt[r.attackerDon][targetDonId] + PAIR_COOLDOWN) revert PairCooldown();
        lastPairAttempt[r.attackerDon][targetDonId] = uint64(block.timestamp);
        // Heat is claimed at reveal, not just at settle (Audit fix — logic lens L-1, 2026-08-12): the
        // cap is "<= 2 attempts/target/day", and an in-flight (revealed, unsettled) attempt IS an
        // attempt. Writing heat only at settle let N attackers all pass the gate and reveal against one
        // target inside a single ~30-min window before any settled, silently voiding the cap. Settle
        // refreshes it from resolution time.
        heatUntil[targetDonId] = uint64(block.timestamp + HEAT);

        r.targetDon = targetDonId;
        r.revealedAt = uint64(block.timestamp);
        r.state = RaidState.Revealed;
        r.attackPower = _withAttack(r.attackerDon, _settleCrew(raidId, hitterIds));

        // The fee is sunk the moment the attempt is real — entropy + keeper resources are
        // consumed whether or not the hit lands.
        scrip.burn(address(this), COMMIT_FEE);

        // Snapshot the garrison commit that was FROZEN at the defender's depart (the gas law).
        bytes32 g = board.garrisonHashOf(targetDonId);
        r.garrisonHash = g;
        if (g == bytes32(0)) {
            // Openly ungarrisoned: defense is the House alone, settle as soon as the word lands.
            r.garrisonRevealed = true;
            r.defensePower = _withDefense(targetDonId, deed.defenseOf(targetDonId) * PPM, 0);
            emit GarrisonRevealed(raidId, targetDonId, r.defensePower);
        }

        if (r.garrisonRevealed) {
            seq = _drawRoll(raidId);
        } else {
            _refund(msg.value);
        }
        emit RaidRevealed(raidId, r.attackerDon, targetDonId, r.attackPower, seq);
    }

    /// Draw the roll — permissionless and payable, the rail `MissionBoard.resolve` already runs on.
    /// The gate is the whole H-1 fix: never while the defence can still move. Past the window an
    /// unproven garrison earns no credit, exactly as the 2026-08-12 suppression fix intended.
    function requestRoll(uint64 raidId) external payable nonReentrant returns (uint64 seq) {
        Raid storage r = raids[raidId];
        if (r.attackerDon == 0) revert UnknownRaid();
        if (r.state != RaidState.Revealed || rollRequestedAt[raidId] != 0) revert WrongState();
        if (!r.garrisonRevealed) {
            if (block.timestamp < r.revealedAt + GARRISON_TIMEOUT) revert NotYetTimedOut();
            r.garrisonRevealed = true;
            r.defensePower = deed.defenseOf(r.targetDon) * PPM;
            emit GarrisonRevealed(raidId, r.targetDon, r.defensePower);
        }
        seq = _drawRoll(raidId);
    }

    /// RP scales the raider's crew. Powers are x1e6 and the sheet is bps, so this is a pure
    /// multiplier on a number the existing p_hit curve already consumed — the odds formula is
    /// untouched, only its inputs move. A registry fault leaves the raid at base power rather than
    /// bricking a reveal that has already burned its fee.
    function _withAttack(uint256 donId, uint256 power) internal view returns (uint256) {
        if (address(affinity) == address(0)) return power;
        try affinity.statsOf(donId) returns (IAffinityRegistry.Stats memory st) {
            return power + (power * uint256(st.rpBps)) / 10_000;
        } catch {
            return power;
        }
    }

    /// HD scales the defender, with the flat addend applied BEFORE the percentage (the sheet's own
    /// stated order), and CMD scaling only the garrison portion rather than the House itself.
    function _withDefense(uint256 donId, uint256 power, uint256 garrisonPower)
        internal
        view
        returns (uint256)
    {
        if (address(affinity) == address(0)) return power;
        try affinity.statsOf(donId) returns (IAffinityRegistry.Stats memory st) {
            uint256 p = power + uint256(st.hdFlat) * PPM;
            p += (garrisonPower * uint256(st.cmdGarrisonBps)) / 10_000;
            return p + (p * uint256(st.hdBps)) / 10_000;
        } catch {
            return power;
        }
    }

    /// Validate the crew and lock in attack power (x1e6): each Hitter contributes BASE_POWER scaled
    /// by the (elapsed/20h)^2 cooldown curve — diminished odds, never a hard gate.
    /// Strictly-increasing ids kill duplicate stacking; hospitalized Hitters can't ride.
    function _settleCrew(uint64 raidId, uint256[] calldata hitterIds) internal returns (uint256 power) {
        uint256 n = hitterIds.length;
        if (n == 0 || n > MAX_CREW) revert BadCrew();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = hitterIds[i];
            if (i > 0 && id <= hitterIds[i - 1]) revert BadCrew();
            if (hitter.ownerOf(id) != msg.sender) revert HitterUnavailable();
            if (block.timestamp < hitter.hospitalUntil(id)) revert HitterUnavailable();
            power += BASE_POWER * _cooldownPpm(hitter.lastAttemptAt(id));
            hitter.noteAttempt(id);
            _crew[raidId].push(id);
        }
    }

    /// m(t) = (t/20h)^2 in ppm; a never-used Hitter hunts at full odds.
    function _cooldownPpm(uint64 lastAt) internal view returns (uint256) {
        if (lastAt == 0) return PPM;
        uint256 elapsed = block.timestamp - lastAt;
        if (elapsed >= COOLDOWN) return PPM;
        uint256 lin = (elapsed * PPM) / COOLDOWN;
        return (lin * lin) / PPM;
    }

    function _drawRoll(uint64 raidId) internal returns (uint64 seq) {
        uint256 fee = entropyFee();
        if (msg.value < fee) revert InsufficientFee();
        rollRequestedAt[raidId] = uint64(block.timestamp);
        bytes32 userRandom = keccak256(abi.encodePacked(msg.sender, raidId, blockhash(block.number - 1)));
        seq = entropy.requestV2{value: fee}(entropyProvider, userRandom, callbackGasLimit);
        seqToRaid[seq] = raidId;
        _refund(msg.value - fee);
    }

    function _refund(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert RefundFailed();
    }

    // ---------------------------------------------------------------- garrison reveal

    /// Open the defender's frozen commit — normally the keeper (which holds the plaintext via the
    /// relayer rail), but PERMISSIONLESS: anyone with the plaintext may reveal, so the keeper can
    /// stall a reveal but never monopolize it (the gas-law fallback). Garrison Hitters no longer
    /// owned by the defender (sold mid-window) or hospitalized contribute zero rather than reverting
    /// — a stale plaintext must never brick the reveal.
    /// It fixes the defence and stops — drawing the roll carries the fee, so a defender opening
    /// their own garrison is never made to fund the attack against them.
    function revealGarrison(uint64 raidId, uint256[] calldata garrisonIds, bytes32 salt) external nonReentrant {
        Raid storage r = raids[raidId];
        if (r.attackerDon == 0) revert UnknownRaid();
        if (r.state != RaidState.Revealed || r.garrisonRevealed) revert WrongState();
        if (keccak256(abi.encode(garrisonIds, salt)) != r.garrisonHash) revert GarrisonMismatch();
        if (garrisonIds.length > deed.garrisonSlotsOf(r.targetDon)) revert TooManyGarrison();

        address defender = don.ownerOf(r.targetDon);
        uint256 power = deed.defenseOf(r.targetDon) * PPM;
        uint256 garrisonPower;
        for (uint256 i = 0; i < garrisonIds.length; i++) {
            uint256 id = garrisonIds[i];
            if (i > 0 && id <= garrisonIds[i - 1]) revert BadCrew();
            if (hitter.ownerOf(id) != defender) continue;
            if (block.timestamp < hitter.hospitalUntil(id)) continue;
            uint256 slot = (BASE_POWER * PPM * GARRISON_EFF_BPS) / 10_000;
            power += slot;
            garrisonPower += slot;
        }
        r.garrisonRevealed = true;
        power = _withDefense(r.targetDon, power, garrisonPower);
        r.defensePower = power;
        emit GarrisonRevealed(raidId, r.targetDon, power);
    }

    // ---------------------------------------------------------------- entropy + settlement

    function entropyCallback(uint64 sequenceNumber, address, bytes32 randomNumber) internal override nonReentrant {
        uint64 raidId = seqToRaid[sequenceNumber];
        Raid storage r = raids[raidId];
        if (raidId == 0 || r.state != RaidState.Revealed || r.wordReceived) revert AlreadyDelivered();
        r.word = randomNumber;
        r.wordReceived = true;
        // Unconditional — the H-1 invariant: `word` is only ever written in a tx that also settles.
        _settle(raidId);
    }

    /// The full roll — one word, partitioned reads.
    function _settle(uint64 raidId) internal {
        Raid storage r = raids[raidId];
        r.state = RaidState.Settled;
        heatUntil[r.targetDon] = uint64(block.timestamp + HEAT);

        uint256 a = r.attackPower;
        uint256 d = r.defensePower;
        uint256 pHit = (P_COEF_PPM * a) / (a + d);
        if (pHit < P_MIN_PPM) pHit = P_MIN_PPM;
        if (pHit > P_MAX_PPM) pHit = P_MAX_PPM;

        uint256 word = uint256(r.word);
        if (word % PPM < pHit) {
            _settleHit(raidId, r, pHit, word);
        } else {
            _settleMiss(raidId, pHit, a, d, word);
        }
    }

    function _settleHit(uint64 raidId, Raid storage r, uint256 pHit, uint256 word) internal {
        uint256 tierRoll = uint256(keccak256(abi.encodePacked(word, uint8(1)))) % PPM;
        address attackerVault = don.vaultOf(r.attackerDon);
        bool big = tierRoll >= TWO_TIER_CUM_PPM && block.timestamp >= bigLockUntil[r.targetDon];
        if (big) {
            // The Scrip band: slice = 15% + 15%·u², u ~ U[0,1) — mean 20%, max 30%.
            uint256 u = uint256(keccak256(abi.encodePacked(word, uint8(2)))) % PPM;
            uint256 sliceBps = 1_500 + (1_500 * ((u * u) / PPM)) / PPM;
            bigLockUntil[r.targetDon] = uint64(block.timestamp + BIG_SCORE_LOCKOUT);
            (uint256 taken, uint256 tax) = escrow.applyRaidBig(r.targetDon, attackerVault, sliceBps);
            emit RaidSettled(raidId, 2, pHit, taken, tax);
        } else {
            // Common hit — or a big roll inside the lockout, downgraded ("the safe got moved").
            (uint256 taken, uint256 tax) = escrow.applyRaidCommon(r.targetDon, attackerVault);
            emit RaidSettled(raidId, 1, pHit, taken, tax);
        }
    }

    function _settleMiss(uint64 raidId, uint256 pHit, uint256 a, uint256 d, uint256 word) internal {
        // P(kill | fail) = 0.15 + 0.35 x D/(A+D) — returning fire is real; the defended punish hard.
        uint256 pKill = KILL_BASE_PPM + (KILL_SLOPE_PPM * d) / (a + d);
        uint256[] storage crew = _crew[raidId];
        for (uint256 i = 0; i < crew.length; i++) {
            if (uint256(keccak256(abi.encodePacked(word, uint8(100), i))) % PPM < pKill) {
                hitter.hospitalize(crew[i]);
                emit HitterDown(raidId, crew[i]);
            }
        }
        emit RaidSettled(raidId, 0, pHit, 0, 0);
    }

    // ---------------------------------------------------------------- liveness valves

    /// Entropy withheld: settle as a MISS with no kill rolls (no word => no roll). Cooldowns stand
    /// (the attempt was public), the fee stays sunk. Anyone may call — a dead keeper can never
    /// strand a raid.
    ///
    /// Clocked from when the roll BECAME drawable, not the reveal: from the reveal, a suppressed
    /// garrison would get one hour of grace instead of two, and a late draw could be reclaimed as a
    /// miss minutes after it.
    function reclaimRaid(uint64 raidId) external nonReentrant {
        Raid storage r = raids[raidId];
        if (r.attackerDon == 0) revert UnknownRaid();
        if (r.state != RaidState.Revealed) revert WrongState();
        if (block.timestamp < _reclaimableAt(raidId)) revert NotYetTimedOut();
        r.state = RaidState.Settled;
        heatUntil[r.targetDon] = uint64(block.timestamp + HEAT);
        emit RaidSettled(raidId, 4, 0, 0, 0);
    }

    function _reclaimableAt(uint64 raidId) internal view returns (uint256) {
        uint64 drawn = rollRequestedAt[raidId];
        uint256 drawable = drawn == 0 ? raids[raidId].revealedAt + GARRISON_TIMEOUT : drawn;
        return drawable + RECLAIM_TIMEOUT;
    }

    /// Commit abandoned past the reveal window: the held fee burns. Permissionless cleanup.
    /// (A "bond to the target" design needs a target identity the chain never learned — Phase-0
    /// deviation, flagged; abandoning a bad-looking commit still costs more than rolling it.)
    function forfeit(uint64 raidId) external nonReentrant {
        Raid storage r = raids[raidId];
        if (r.attackerDon == 0) revert UnknownRaid();
        if (r.state != RaidState.Committed) revert WrongState();
        if (block.timestamp <= r.committedAt + REVEAL_WINDOW) revert NotYetTimedOut();
        r.state = RaidState.Forfeited;
        scrip.burn(address(this), COMMIT_FEE);
        emit RaidForfeited(raidId);
    }
}
