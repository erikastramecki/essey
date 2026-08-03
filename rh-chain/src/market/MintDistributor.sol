// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Seat} from "./Seat.sol";

/// The MintDistributor — Essey's whitelist mint engine and the Seat's sole minter.
///
/// The Seat's `minter` is IMMUTABLE, so this contract must be deployed FIRST and passed as the Seat's
/// minter; the Seat is then wired back in once via `initSeat`. After that the ONLY way a Seat is ever
/// minted is through this distributor — there is no other minter, forever.
///
/// Distribution is a Merkle allowlist, per stage. An off-chain indexer scores the testnet "trading day"
/// quest (see docs/DESIGN-whitelist-onboarding.md), publishes the full {wallet → allocation} dataset, and
/// commits its Merkle root here. Because the dataset is public, anyone can recompute the root and verify
/// their own allocation before claiming — the chain never needs the list, only the root.
///
///   leaf = keccak256(bytes.concat(keccak256(abi.encode(account, stage, allocation))))
///
/// (double-hashed, matching OpenZeppelin's `merkle-tree` JS builder, so an off-chain tree and this
/// verifier agree bit-for-bit and no internal node can be passed off as a leaf.)
///
/// Free mint: claiming costs only gas — no price. Each `(stage, account)` can claim exactly once, for the
/// exact `allocation` the root attests. The stage's window is opened/closed by the admin.
///
/// Trust model. The whitelist is inherently curated (off-chain quest data → on-chain root), so a single
/// attestor — the `admin`, in production a multisig — must commit each root. That power is bounded on
/// every side:
///   - Roots are TIMELOCKED: proposed, then committable only after `rootTimelock` (which the constructor
///     forces non-zero), giving the public a window to recompute the published dataset's root and reject a
///     mismatch before it can go live.
///   - The admin can NEVER mint by fiat beyond `reserveCap` — a small immutable tranche for the Exchange
///     float and partner seats. Everything above that is claimable ONLY against a committed root.
///   - The Seat's own `maxSupply` (`SoldOut`) is the hard ceiling on everything, admin included.
/// There is no owner over funds, no pause, no upgrade, no way to move a minted Seat or reset a claim.
contract MintDistributor is ReentrancyGuard {
    Seat public seat; // the collection this distributor mints; set once via initSeat
    address public immutable admin; // whitelist curator (a multisig in production)
    uint256 public immutable reserveCap; // hard cap on admin-minted seats (Exchange float + partners)
    uint256 public immutable rootTimelock; // public-review delay between proposing and committing a root

    uint256 public reserveMinted; // running total minted via mintReserved (<= reserveCap)

    mapping(uint256 => bytes32) public stageRoot; // stage => live allowlist root
    mapping(uint256 => bool) public stageOpen; // stage => claim window open
    mapping(uint256 => bytes32) public pendingRoot; // stage => proposed root awaiting timelock
    mapping(uint256 => uint256) public pendingEta; // stage => earliest commit time (0 = none pending)
    mapping(uint256 => mapping(address => bool)) public claimed; // stage => account => already claimed

    event SeatInitialized(address indexed seat);
    event SeatHookSet(address indexed hook);
    event RootProposed(uint256 indexed stage, bytes32 root, uint256 eta);
    event RootCommitted(uint256 indexed stage, bytes32 root);
    event StageOpenSet(uint256 indexed stage, bool open);
    event Claimed(uint256 indexed stage, address indexed account, uint256 allocation, uint256 firstId);
    event ReservedMinted(address indexed to, uint256 count);

    error NotAdmin();
    error ZeroTimelock();
    error SeatAlreadySet();
    error SeatNotSet();
    error NotMinterOfSeat();
    error ZeroAddress();
    error ZeroAllocation();
    error StageClosed();
    error AlreadyClaimed();
    error BadProof();
    error NothingPending();
    error TimelockNotElapsed();
    error ReserveCapExceeded();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address admin_, uint256 reserveCap_, uint256 rootTimelock_) {
        if (admin_ == address(0)) revert ZeroAddress();
        // A zero timelock would let a root be proposed and committed in the same block, silently voiding
        // the public-review window the trust model depends on — reject it at deploy rather than trust the
        // deployer to remember. (Also keeps `pendingEta == 0` an unambiguous "nothing pending" sentinel.)
        if (rootTimelock_ == 0) revert ZeroTimelock();
        admin = admin_;
        reserveCap = reserveCap_;
        rootTimelock = rootTimelock_;
    }

    /// One-time wiring of the Seat, after it has been deployed with THIS contract as its immutable minter.
    /// Reverts unless we really are that minter, so a mis-ordered deploy is caught here rather than
    /// leaving a distributor that can never mint.
    function initSeat(Seat seat_) external onlyAdmin {
        if (address(seat) != address(0)) revert SeatAlreadySet();
        if (seat_.minter() != address(this)) revert NotMinterOfSeat();
        seat = seat_;
        emit SeatInitialized(address(seat_));
    }

    /// Wire the Seat's transfer hook (the Bell). `Seat.setHook` is `minter`-gated, and this distributor is
    /// the Seat's IMMUTABLE minter — so this passthrough is the ONLY way the hook can ever be set. Without
    /// it the Bell could never attach and Seat transfers would never fire `onSeatTransfer` (the mechanism
    /// that clears a Seat's tier/weight on resale). `Seat.setHook` is itself one-shot, so this can only
    /// ever land the hook once; admin-gated so a stray address can't front-run it with a hostile hook.
    function setSeatHook(address hook_) external onlyAdmin {
        if (address(seat) == address(0)) revert SeatNotSet();
        seat.setHook(hook_);
        emit SeatHookSet(hook_);
    }

    // ---------------------------------------------------------------- claim (public, Merkle-gated)

    /// Claim the `allocation` Seats the committed root attests for `msg.sender` in `stage`. Free (gas
    /// only), exactly once per `(stage, account)`. The Seat's `SoldOut` is the backstop if a stage's
    /// published allocations were over-committed against remaining supply.
    function claim(uint256 stage, uint256 allocation, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 firstId)
    {
        if (address(seat) == address(0)) revert SeatNotSet();
        if (!stageOpen[stage]) revert StageClosed();
        if (allocation == 0) revert ZeroAllocation();
        if (claimed[stage][msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, stage, allocation))));
        if (!MerkleProof.verify(proof, stageRoot[stage], leaf)) revert BadProof();

        claimed[stage][msg.sender] = true; // effects before interaction (Seat mint is a _safeMint callback)
        firstId = seat.mint(msg.sender);
        for (uint256 i = 1; i < allocation; i++) {
            seat.mint(msg.sender);
        }
        emit Claimed(stage, msg.sender, allocation, firstId);
    }

    // ---------------------------------------------------------------- admin: roots (timelocked)

    /// Propose a stage's allowlist root. Starts the public-review clock; it cannot go live until
    /// `commitRoot` is callable at the earliest at `block.timestamp + rootTimelock`.
    function proposeRoot(uint256 stage, bytes32 root) external onlyAdmin {
        pendingRoot[stage] = root;
        uint256 eta = block.timestamp + rootTimelock;
        pendingEta[stage] = eta;
        emit RootProposed(stage, root, eta);
    }

    /// Commit a proposed root once its timelock has elapsed, making it the live allowlist for `stage`.
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

    /// Open or close a stage's claim window. A root can be committed while closed; claims only succeed
    /// while open. Kept separate from the timelock so a live stage can be paused instantly if needed.
    function setStageOpen(uint256 stage, bool open) external onlyAdmin {
        stageOpen[stage] = open;
        emit StageOpenSet(stage, open);
    }

    // ---------------------------------------------------------------- admin: reserved float/partners

    /// Mint reserved Seats (Exchange float, partner allocations) directly to `to`. Bounded for all time by
    /// the immutable `reserveCap`; everything above that tranche is claimable ONLY via a committed root.
    function mintReserved(address to, uint256 count) external onlyAdmin nonReentrant {
        if (address(seat) == address(0)) revert SeatNotSet();
        if (to == address(0)) revert ZeroAddress();
        if (count == 0) revert ZeroAllocation();
        uint256 minted = reserveMinted + count;
        if (minted > reserveCap) revert ReserveCapExceeded();
        reserveMinted = minted;
        for (uint256 i = 0; i < count; i++) {
            seat.mint(to);
        }
        emit ReservedMinted(to, count);
    }

    // ---------------------------------------------------------------- views

    /// The leaf a caller must be able to prove for `(account, stage, allocation)` — exposed so front-ends
    /// and tests build proofs against the exact hashing this contract verifies.
    function leafOf(address account, uint256 stage, uint256 allocation) external pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, stage, allocation))));
    }

    /// Seats the admin may still mint via `mintReserved`.
    function reserveRemaining() external view returns (uint256) {
        return reserveCap - reserveMinted;
    }
}
