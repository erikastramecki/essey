// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Don} from "./Don.sol";

/// DonDistributor — the Dons' sole minter and mint-economics engine. Evolves MintDistributor (the Seat
/// whitelist claimer) into the 3-path Don mint the founder specified:
///
///   • FREE (whitelist) — a WL wallet claims its `allocation` Dons for gas only, each with a randomly-rolled
///     trait combo. Merkle-gated, once per (stage, account), reusing MintDistributor's exact leaf format so
///     the scalable allowlist root drops straight in.
///   • REROLL (~$3) — re-randomize a Don you own that isn't yet staked (locked). Unlimited; each reroll costs
///     `rerollFee` in ETH (the chain's native token, so no USDG swap needed). Frees the old combo, reserves the new.
///   • CUSTOM (~$10) — mint a Don with an EXACT chosen combo. `customFee` in ETH. The paid alternative to a random
///     free/reroll Don.
///
/// Fees are in ETH and configurable (admin-set to track ~$3 / ~$10 as we finalize). By default **100% of every
/// fee → `feeSink`** — the fee→stock router that buys Robinhood stock for the staked+activated Dons right away
/// (teamBps = 0). This is deliberate: reroll/custom activity flows straight back to holders as stock, which
/// drives more rerolling and custom mints. A `teamBps` cut to `treasury` stays configurable if we ever want one.
///
/// Uniqueness is enforced ON-CHAIN here: every Don's `combo` (its resolved trait hash / the builder's
/// reservation key) is check-and-locked in `usedCombo`, so no two Dons ever share a combo — the reservation
/// ledger lives on-chain, not in a server file. Randomness for the "random" paths is front-end-rolled (the
/// client picks an unused combo); on-chain we guarantee uniqueness, not the roll's entropy. (A future rev can
/// seed the roll from the chain's entropy/Dice for trustless fairness — noted, not v1.)
///
/// All mint FEES (USDG) flow to `feeSink` — the fee→auto-stock router (task #75) that DCA-buys Robinhood stock
/// for the Bell. Trust model mirrors MintDistributor: timelocked roots, a bounded admin reserve, the Don's
/// own maxSupply as the hard ceiling, no way to move a minted Don or reset a claim.
contract DonDistributor is ReentrancyGuard {
    Don public don; // the collection this distributor mints; set once via initDon
    address public immutable admin; // whitelist curator (a multisig in production)
    uint256 public immutable reserveCap; // hard cap on admin-minted Dons (float + partners)
    uint256 public immutable rootTimelock; // public-review delay between proposing and committing a root

    // Fees are ETH (native), configurable so we can track ~$3 reroll / ~$10 custom as we finalize.
    uint256 public rerollFee; // wei charged to reroll (~$3)
    uint256 public customFee; // wei charged to custom-mint (~$10)
    uint256 public teamBps; // share of each fee to `treasury` (default 0 = 100% to stock/feeSink); configurable

    address public treasury; // team treasury — receives teamBps of every fee
    address public feeSink; // the fee→stock router — receives the rest, buys stock for staked Dons
    address public staker; // the AMM/staking contract allowed to trigger a Don's art-lock on activation
    bool public publicOpen; // whether the $10 custom / public mint is live

    uint256 public reserveMinted; // running total minted via mintReserved (<= reserveCap)

    mapping(bytes32 => bool) public usedCombo; // trait combo -> taken (the on-chain uniqueness ledger)
    mapping(uint256 => bytes32) public comboOf; // don id -> its current combo (for reroll release)

    mapping(uint256 => bytes32) public stageRoot; // stage => live allowlist root
    mapping(uint256 => bool) public stageOpen; // stage => claim window open
    mapping(uint256 => bytes32) public pendingRoot; // stage => proposed root awaiting timelock
    mapping(uint256 => uint256) public pendingEta; // stage => earliest commit time (0 = none pending)
    mapping(uint256 => mapping(address => bool)) public claimed; // stage => account => already claimed

    event DonInitialized(address indexed don);
    event FeeSinkSet(address indexed sink);
    event TreasurySet(address indexed treasury);
    event FeesSet(uint256 rerollFee, uint256 customFee);
    event SplitSet(uint256 teamBps);
    event StakerSet(address indexed staker);
    event PublicOpenSet(bool open);
    event FeeSplit(uint256 total, uint256 toTeam, uint256 toStock);
    event RootProposed(uint256 indexed stage, bytes32 root, uint256 eta);
    event RootCommitted(uint256 indexed stage, bytes32 root);
    event StageOpenSet(uint256 indexed stage, bool open);
    event ClaimedWL(uint256 indexed stage, address indexed account, uint256 allocation, uint256 firstId);
    event Rerolled(uint256 indexed id, bytes32 oldCombo, bytes32 newCombo, uint256 fee);
    event CustomMinted(address indexed to, uint256 indexed id, bytes32 combo, uint256 fee);
    event ReservedMinted(address indexed to, uint256 count);

    error NotAdmin();
    error NotStaker();
    error ZeroAddress();
    error ZeroTimelock();
    error DonAlreadySet();
    error DonNotSet();
    error NotMinterOfDon();
    error ZeroAllocation();
    error StageClosed();
    error PublicClosed();
    error AlreadyClaimed();
    error BadProof();
    error NothingPending();
    error TimelockNotElapsed();
    error ReserveCapExceeded();
    error ComboTaken();
    error AllocationMismatch();
    error NotOwner();
    error SinksUnset();
    error WrongFee();
    error BadSplit();
    error TransferFailed();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(
        address admin_,
        uint256 reserveCap_,
        uint256 rootTimelock_,
        uint256 rerollFee_,
        uint256 customFee_,
        uint256 teamBps_
    ) {
        if (admin_ == address(0)) revert ZeroAddress();
        if (rootTimelock_ == 0) revert ZeroTimelock();
        if (teamBps_ > 10_000) revert BadSplit();
        admin = admin_;
        reserveCap = reserveCap_;
        rootTimelock = rootTimelock_;
        rerollFee = rerollFee_;
        customFee = customFee_;
        teamBps = teamBps_;
    }

    /// One-time wiring of the Don, after it's deployed with THIS contract as its immutable minter.
    function initDon(Don don_) external onlyAdmin {
        if (address(don) != address(0)) revert DonAlreadySet();
        if (don_.minter() != address(this)) revert NotMinterOfDon();
        don = don_;
        emit DonInitialized(address(don_));
    }

    // ---------------------------------------------------------------- combo uniqueness (internal)

    function _take(bytes32 combo) internal {
        if (usedCombo[combo]) revert ComboTaken();
        usedCombo[combo] = true;
    }

    // ---------------------------------------------------------------- FREE whitelist claim (Merkle-gated)

    /// Claim the `allocation` Dons the committed root attests for `msg.sender` in `stage`, each with a fresh
    /// unique `combos[i]`. Free (gas only), once per (stage, account). `combos.length` must equal `allocation`.
    function claimWL(uint256 stage, uint256 allocation, bytes32[] calldata proof, bytes32[] calldata combos)
        external
        nonReentrant
        returns (uint256 firstId)
    {
        if (address(don) == address(0)) revert DonNotSet();
        if (!stageOpen[stage]) revert StageClosed();
        if (allocation == 0) revert ZeroAllocation();
        if (combos.length != allocation) revert AllocationMismatch();
        if (claimed[stage][msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, stage, allocation))));
        if (!MerkleProof.verify(proof, stageRoot[stage], leaf)) revert BadProof();

        claimed[stage][msg.sender] = true; // effects before interaction (mint is a _safeMint callback)
        for (uint256 i = 0; i < allocation; i++) {
            _take(combos[i]);
            uint256 id = don.mint(msg.sender, combos[i]);
            comboOf[id] = combos[i];
            if (i == 0) firstId = id;
        }
        emit ClaimedWL(stage, msg.sender, allocation, firstId);
    }

    // ---------------------------------------------------------------- $1 REROLL (owned, unlocked)

    /// Re-randomize a Don you own that isn't staked yet. Pays `rerollFee` in ETH (split team/stock); frees the
    /// old combo and reserves the new one. `Don.reroll` reverts if the Don's traits are already locked.
    function reroll(uint256 id, bytes32 newCombo) external payable nonReentrant {
        if (address(don) == address(0)) revert DonNotSet();
        if (msg.value != rerollFee) revert WrongFee();
        if (don.ownerOf(id) != msg.sender) revert NotOwner();
        _take(newCombo);

        bytes32 old = comboOf[id];
        usedCombo[old] = false; // released — now available to others
        comboOf[id] = newCombo;
        don.reroll(id, newCombo); // reverts (TraitsLocked) if already staked

        _splitFee(msg.value);
        emit Rerolled(id, old, newCombo, msg.value);
    }

    // ---------------------------------------------------------------- $5 CUSTOM mint (public)

    /// Mint a Don with an EXACT chosen `combo`. Pays `customFee` in ETH. Open only when `publicOpen`.
    function mintCustom(bytes32 combo) external payable nonReentrant returns (uint256 id) {
        if (address(don) == address(0)) revert DonNotSet();
        if (!publicOpen) revert PublicClosed();
        if (msg.value != customFee) revert WrongFee();
        _take(combo);
        id = don.mint(msg.sender, combo);
        comboOf[id] = combo;
        _splitFee(msg.value);
        emit CustomMinted(msg.sender, id, combo, msg.value);
    }

    /// Split an ETH fee: teamBps to the treasury, the remainder to the stock feeSink. Both sinks must be
    /// wired. Sends happen after all state changes (nonReentrant + effects-before-interaction).
    function _splitFee(uint256 amount) internal {
        if (feeSink == address(0)) revert SinksUnset(); // the stock sink is always required
        uint256 toTeam = (amount * teamBps) / 10_000;
        uint256 toStock = amount - toTeam;
        if (toTeam > 0) {
            if (treasury == address(0)) revert SinksUnset(); // treasury only required when there IS a team cut
            (bool s1,) = treasury.call{value: toTeam}("");
            if (!s1) revert TransferFailed();
        }
        if (toStock > 0) {
            (bool s2,) = feeSink.call{value: toStock}("");
            if (!s2) revert TransferFailed();
        }
        emit FeeSplit(amount, toTeam, toStock);
    }

    // ---------------------------------------------------------------- staking lock passthrough

    /// Freeze a Don's art when it is staked to activate. Callable only by the wired `staker` (the AMM), so
    /// the Don's `onlyMinter` lock is reachable exactly once, by exactly the activation path.
    function lockOnStake(uint256 id) external {
        if (msg.sender != staker) revert NotStaker();
        don.lockTraits(id);
    }

    // ---------------------------------------------------------------- admin: roots (timelocked)

    function proposeRoot(uint256 stage, bytes32 root) external onlyAdmin {
        pendingRoot[stage] = root;
        uint256 eta = block.timestamp + rootTimelock;
        pendingEta[stage] = eta;
        emit RootProposed(stage, root, eta);
    }

    function commitRoot(uint256 stage) external onlyAdmin {
        uint256 eta = pendingEta[stage];
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TimelockNotElapsed();
        bytes32 root = pendingRoot[stage];
        stageRoot[stage] = root;
        pendingRoot[stage] = bytes32(0);
        pendingEta[stage] = 0;
        emit RootCommitted(stage, root);
    }

    function setStageOpen(uint256 stage, bool open) external onlyAdmin {
        stageOpen[stage] = open;
        emit StageOpenSet(stage, open);
    }

    // ---------------------------------------------------------------- admin: config

    function setFeeSink(address sink) external onlyAdmin {
        if (sink == address(0)) revert ZeroAddress();
        feeSink = sink;
        emit FeeSinkSet(sink);
    }

    function setTreasury(address treasury_) external onlyAdmin {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// Change the ETH fees as we finalize (~$3 reroll / ~$10 custom in ETH terms).
    function setFees(uint256 rerollFee_, uint256 customFee_) external onlyAdmin {
        rerollFee = rerollFee_;
        customFee = customFee_;
        emit FeesSet(rerollFee_, customFee_);
    }

    /// Change the team/stock split (bps to treasury; rest to the stock feeSink). Default 4000 = 40%.
    function setTeamBps(uint256 teamBps_) external onlyAdmin {
        if (teamBps_ > 10_000) revert BadSplit();
        teamBps = teamBps_;
        emit SplitSet(teamBps_);
    }

    function setStaker(address staker_) external onlyAdmin {
        if (staker_ == address(0)) revert ZeroAddress();
        staker = staker_;
        emit StakerSet(staker_);
    }

    function setPublicOpen(bool open) external onlyAdmin {
        publicOpen = open;
        emit PublicOpenSet(open);
    }

    /// Wire the Don's transfer hook (the Bell) / art renderer via the distributor (the Don's immutable minter).
    function setDonHook(address hook_) external onlyAdmin {
        if (address(don) == address(0)) revert DonNotSet();
        don.setHook(hook_);
    }

    function setDonArt(address art_) external onlyAdmin {
        if (address(don) == address(0)) revert DonNotSet();
        don.setArt(art_);
    }

    // ---------------------------------------------------------------- admin: reserved float/partners

    /// Mint reserved Dons (float, partners) with explicit unique combos. Bounded by the immutable reserveCap.
    function mintReserved(address to, bytes32[] calldata combos) external onlyAdmin nonReentrant {
        if (address(don) == address(0)) revert DonNotSet();
        if (to == address(0)) revert ZeroAddress();
        uint256 count = combos.length;
        if (count == 0) revert ZeroAllocation();
        uint256 minted = reserveMinted + count;
        if (minted > reserveCap) revert ReserveCapExceeded();
        reserveMinted = minted;
        for (uint256 i = 0; i < count; i++) {
            _take(combos[i]);
            uint256 id = don.mint(to, combos[i]);
            comboOf[id] = combos[i];
        }
        emit ReservedMinted(to, count);
    }

    // ---------------------------------------------------------------- views

    function leafOf(address account, uint256 stage, uint256 allocation) external pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, stage, allocation))));
    }

    function reserveRemaining() external view returns (uint256) {
        return reserveCap - reserveMinted;
    }
}
