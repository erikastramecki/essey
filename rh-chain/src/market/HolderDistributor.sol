// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IConverter} from "./IConverter.sol";

interface IBasketRegistry {
    function isRegisteredStock(address token) external view returns (bool);
}

/// HolderDistributor — the 40-bps holder-airdrop sink (Model B, keeper-minimized). Keeper buys stock
/// with the received USDG, posts a per-epoch Merkle root, and holders claim; the keeper has no custody
/// and no withdraw. Bad-root and liveness bounds — challenge window, guardian slash, bonded fallback —
/// and the invariants each guard are documented in the commit, not here.
contract HolderDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdg; // the 40-bps slice the hook transfers in; the pot each epoch buys from
    IConverter public immutable converter; // USDG -> stock, oracle-fair or it reverts
    IBasketRegistry public immutable registry; // the pot may only buy stocks this has committed
    address public immutable floorSink; // swept unclaimed stock lands here (e.g. the adminless reserve)
    address public immutable slashSink; // a slashed poster's bond lands here

    // Immutable protocol params. PENDING FOUNDER CONFIRMATION — chosen at deploy, never weakenable after.
    uint256 public immutable minEpochInterval; // cadence lower bound between roots (~12h)
    uint256 public immutable challengeWindow; // dispute delay before a posted root pays
    uint256 public immutable claimWindow; // how long a root stays claimable after it activates
    uint256 public immutable keeperGrace; // dark-keeper timeout before the bonded fallback opens
    uint256 public immutable minBond; // bond a root poster must hold (native token)

    address public governor; // rotates the keeper, voids a bad root in-window; no power over funds
    address public keeper; // default poster/buyer; can always post
    uint256 public lastKeeperRootAt; // last time the keeper itself posted (arms the fallback)

    uint256 public currentBuyEpoch; // the epoch settleBuy credits; postRoot finalizes it and increments
    uint256 public lastRootAt; // enforces the cadence lower bound

    mapping(uint256 => bytes32) public epochRoot; // epoch => root (0 = none/voided/unclaimable)
    mapping(uint256 => uint256) public rootActiveAt; // epoch => when its root becomes claimable
    mapping(uint256 => address) public rootPoster; // epoch => who posted (the slash target)
    mapping(uint256 => bool) public challenged; // epoch => root voided by the guardian

    // Per-epoch, per-token accounting — the isolation that makes a bad root non-contagious.
    mapping(uint256 => mapping(address => uint256)) public reserved; // stock bought and owed for this epoch
    mapping(uint256 => mapping(address => uint256)) public claimedTotal; // stock already paid out this epoch
    mapping(uint256 => mapping(address => mapping(address => bool))) public claimed; // epoch=>holder=>token

    mapping(address => uint256) public bond; // poster => posted bond
    mapping(address => uint256) public bondLockedUntil; // poster => cannot withdraw until this time

    event StockBought(uint256 indexed epoch, address indexed token, uint256 usdgIn, uint256 received);
    event RootPosted(uint256 indexed epoch, bytes32 root, address indexed poster, uint256 activeAt);
    event RootChallenged(uint256 indexed epoch, address indexed poster, uint256 slashed);
    event Paid(uint256 indexed epoch, address indexed holder, address indexed token, uint256 amount);
    event Swept(uint256 indexed epoch, address indexed token, uint256 amount);
    event BondPosted(address indexed poster, uint256 amount);
    event BondWithdrawn(address indexed poster, uint256 amount);
    event KeeperSet(address indexed keeper);
    event GovernorRenounced();

    error ZeroAddress();
    error ZeroParam();
    error NotKeeperOrFallback();
    error NotGovernor();
    error InsufficientBond();
    error TooEarly();
    error NotRegistered();
    error NothingToBuy();
    error UnknownEpoch();
    error ChallengeWindowActive();
    error ClaimWindowClosed();
    error AlreadyClaimed();
    error BadProof();
    error ExceedsReserved();
    error ZeroAmount();
    error NotYetSweepable();
    error BondLocked();
    error LengthMismatch();
    error TransferFailed();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(
        IERC20 usdg_,
        IConverter converter_,
        IBasketRegistry registry_,
        address floorSink_,
        address slashSink_,
        address governor_,
        address keeper_,
        uint256 minEpochInterval_,
        uint256 challengeWindow_,
        uint256 claimWindow_,
        uint256 keeperGrace_,
        uint256 minBond_
    ) {
        if (
            address(usdg_) == address(0) || address(converter_) == address(0) || address(registry_) == address(0)
                || floorSink_ == address(0) || slashSink_ == address(0) || governor_ == address(0)
                || keeper_ == address(0)
        ) revert ZeroAddress();
        if (challengeWindow_ == 0 || claimWindow_ == 0 || keeperGrace_ == 0) revert ZeroParam();
        usdg = usdg_;
        converter = converter_;
        registry = registry_;
        floorSink = floorSink_;
        slashSink = slashSink_;
        governor = governor_;
        keeper = keeper_;
        lastKeeperRootAt = block.timestamp; // anchor the fallback grace at deploy, not at epoch 0
        minEpochInterval = minEpochInterval_;
        challengeWindow = challengeWindow_;
        claimWindow = claimWindow_;
        keeperGrace = keeperGrace_;
        minBond = minBond_;
    }

    // ------------------------------------------------------------------ bond (poster accountability)

    function postBond() external payable {
        if (msg.value == 0) revert ZeroAmount();
        bond[msg.sender] += msg.value;
        emit BondPosted(msg.sender, msg.value);
    }

    /// Withdraw bond once no root you posted is still inside its challenge window.
    function withdrawBond(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < bondLockedUntil[msg.sender]) revert BondLocked();
        uint256 b = bond[msg.sender];
        if (amount > b) revert InsufficientBond();
        bond[msg.sender] = b - amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit BondWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------ keeper: buy + post (no custody)

    /// True while msg.sender may post/buy: the keeper always may; anyone else only after the keeper has
    /// gone silent past the grace period. Either way a bond >= minBond is required, so every poster is
    /// challengeable and slashable.
    function _authorizePoster() internal view {
        bool isKeeper = msg.sender == keeper;
        if (!isKeeper && block.timestamp < lastKeeperRootAt + keeperGrace) revert NotKeeperOrFallback();
        if (bond[msg.sender] < minBond) revert InsufficientBond();
    }

    /// Spend `usdgAmount` of the held pot on `token` for the current epoch. The converter enforces an
    /// oracle-fair minimum and reverts off-session, so a caller cannot sandwich this; the delivered
    /// amount is measured by balance delta, never trusted from the return.
    function settleBuy(address token, uint256 usdgAmount) external nonReentrant returns (uint256 received) {
        _authorizePoster();
        if (usdgAmount == 0) revert NothingToBuy();
        if (!registry.isRegisteredStock(token)) revert NotRegistered();
        uint256 before = IERC20(token).balanceOf(address(this));
        usdg.forceApprove(address(converter), usdgAmount);
        converter.convert(usdgAmount, token, address(this));
        usdg.forceApprove(address(converter), 0);
        received = IERC20(token).balanceOf(address(this)) - before;
        reserved[currentBuyEpoch][token] += received;
        emit StockBought(currentBuyEpoch, token, usdgAmount, received);
    }

    /// Finalize the current epoch with its Merkle root and open the challenge window, then advance so the
    /// next buys credit a fresh epoch. Cadence is a lower bound only (never publish early).
    function postRoot(bytes32 root) external nonReentrant returns (uint256 epoch) {
        _authorizePoster();
        if (root == bytes32(0)) revert BadProof();
        if (block.timestamp < lastRootAt + minEpochInterval) revert TooEarly();
        epoch = currentBuyEpoch;
        uint256 activeAt = block.timestamp + challengeWindow;
        epochRoot[epoch] = root;
        rootActiveAt[epoch] = activeAt;
        rootPoster[epoch] = msg.sender;
        uint256 lockUntil = activeAt;
        if (lockUntil > bondLockedUntil[msg.sender]) bondLockedUntil[msg.sender] = lockUntil;
        if (msg.sender == keeper) lastKeeperRootAt = block.timestamp;
        lastRootAt = block.timestamp;
        currentBuyEpoch = epoch + 1;
        emit RootPosted(epoch, root, msg.sender, activeAt);
    }

    // ------------------------------------------------------------------ guardian: void a bad root

    /// Void a root during its challenge window and slash the poster's entire bond. The epoch's stock is
    /// untouched — it becomes sweepable to the floor, so a bad root loses nothing to holders at large.
    function challengeRoot(uint256 epoch) external onlyGovernor nonReentrant {
        if (epochRoot[epoch] == bytes32(0)) revert UnknownEpoch();
        if (block.timestamp >= rootActiveAt[epoch]) revert ChallengeWindowActive();
        epochRoot[epoch] = bytes32(0);
        challenged[epoch] = true;
        address poster = rootPoster[epoch];
        uint256 slashed = bond[poster];
        if (slashed > 0) {
            bond[poster] = 0;
            (bool ok,) = slashSink.call{value: slashed}("");
            if (!ok) revert TransferFailed();
        }
        emit RootChallenged(epoch, poster, slashed);
    }

    // ------------------------------------------------------------------ claim / push (always pay the leaf)

    /// Claim your own leaf. Pays msg.sender (bound into the leaf), reverts if already taken.
    function claim(uint256 epoch, address token, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        _settle(epoch, msg.sender, token, amount, proof);
    }

    /// Auto-push: permissionless, pays the LEAF'S holder (never msg.sender), so a keeper can deliver to
    /// holders. This is the deliberate divergence from Floor, whose claimMany binds payout to the caller.
    function push(uint256 epoch, address holder, address token, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        _settle(epoch, holder, token, amount, proof);
    }

    /// Batch self-claim; already-claimed legs are skipped, not reverted.
    function claimMany(
        uint256[] calldata epochs,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        uint256 n = epochs.length;
        if (tokens.length != n || amounts.length != n || proofs.length != n) revert LengthMismatch();
        for (uint256 i = 0; i < n; i++) {
            _trySettle(epochs[i], msg.sender, tokens[i], amounts[i], proofs[i]);
        }
    }

    /// Batch auto-push to many leaf holders; already-claimed legs are skipped, not reverted.
    function pushMany(
        uint256[] calldata epochs,
        address[] calldata holders,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        uint256 n = epochs.length;
        if (holders.length != n || tokens.length != n || amounts.length != n || proofs.length != n) {
            revert LengthMismatch();
        }
        for (uint256 i = 0; i < n; i++) {
            _trySettle(epochs[i], holders[i], tokens[i], amounts[i], proofs[i]);
        }
    }

    function _settle(uint256 epoch, address holder, address token, uint256 amount, bytes32[] calldata proof) internal {
        bytes32 root = epochRoot[epoch];
        if (root == bytes32(0)) revert UnknownEpoch();
        if (block.timestamp < rootActiveAt[epoch]) revert ChallengeWindowActive();
        if (block.timestamp > rootActiveAt[epoch] + claimWindow) revert ClaimWindowClosed();
        if (amount == 0) revert ZeroAmount();
        if (claimed[epoch][holder][token]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(epoch, holder, token, amount))));
        if (!MerkleProof.verify(proof, root, leaf)) revert BadProof();
        uint256 avail = reserved[epoch][token] - claimedTotal[epoch][token];
        if (amount > avail) revert ExceedsReserved();
        claimed[epoch][holder][token] = true; // CEI: consume before the outbound transfer
        claimedTotal[epoch][token] += amount;
        IERC20(token).safeTransfer(holder, amount);
        emit Paid(epoch, holder, token, amount);
    }

    /// Batch variant: a leaf that would revert on the double-claim guard is skipped so one stale entry
    /// can't brick a keeper's push batch. Every OTHER guard still reverts the batch (a bad proof or an
    /// over-reserved amount is never silently swallowed).
    function _trySettle(uint256 epoch, address holder, address token, uint256 amount, bytes32[] calldata proof)
        internal
    {
        if (claimed[epoch][holder][token]) return;
        _settle(epoch, holder, token, amount, proof);
    }

    // ------------------------------------------------------------------ sweep (unclaimed -> floor)

    /// After the claim window, or once a root is voided, move an epoch's unclaimed stock to the floor
    /// sink — value returns to $ESSEY holders at large, and the keeper never touches it. Permissionless.
    function sweepEpoch(uint256 epoch, address token) external nonReentrant returns (uint256 leftover) {
        bool voided = challenged[epoch];
        bool expired = rootActiveAt[epoch] != 0 && block.timestamp > rootActiveAt[epoch] + claimWindow;
        if (!voided && !expired) revert NotYetSweepable();
        leftover = reserved[epoch][token] - claimedTotal[epoch][token];
        if (leftover == 0) revert ZeroAmount();
        claimedTotal[epoch][token] = reserved[epoch][token]; // CEI: nothing left to claim
        IERC20(token).safeTransfer(floorSink, leftover);
        emit Swept(epoch, token, leftover);
    }

    // ------------------------------------------------------------------ governor (bounded)

    function setKeeper(address keeper_) external onlyGovernor {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// One-way: renounce keeper rotation + challenge power. Roots then run purely bonded/permissionless.
    function renounceGovernor() external onlyGovernor {
        governor = address(0);
        emit GovernorRenounced();
    }

    // ------------------------------------------------------------------ views

    function leafOf(uint256 epoch, address holder, address token, uint256 amount) external pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, holder, token, amount))));
    }

    function claimable(uint256 epoch, address token) external view returns (uint256) {
        return reserved[epoch][token] - claimedTotal[epoch][token];
    }

    function isActive(uint256 epoch) external view returns (bool) {
        uint256 activeAt = rootActiveAt[epoch];
        return
            epochRoot[epoch] != bytes32(0) && block.timestamp >= activeAt && block.timestamp <= activeAt + claimWindow;
    }
}
