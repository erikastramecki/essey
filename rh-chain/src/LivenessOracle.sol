// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Chain-liveness gate, standing in for the L2 Sequencer Uptime Feed that Robinhood Chain does
/// not appear to have.
///
/// THE PROBLEM. Robinhood Chain is an Arbitrum Orbit L2. If its sequencer halts, nothing executes
/// — nobody can repay, top up, or liquidate. That much is unavoidable. The damage happens on
/// RESTART: a backlog runs at once, liquidation bots are fastest, and a borrower who was healthy
/// when the chain died and fell 15% during the outage is liquidated in the first block back,
/// having had no opportunity to react. Chainlink's uptime feed exists to prevent exactly that, and
/// on this chain it could not be found (see StaleFeedGuard for the search).
///
/// WHY A "PAUSE ON OUTAGE" KEEPER DOES NOT WORK. The obvious design — watch for blocks stopping,
/// then pause — cannot send its pause transaction, because the chain it would send it to is down.
/// It could only act after resumption, racing the same backlog as the liquidators. It loses that
/// race, and a safety control that loses a race is not a safety control.
///
/// THE INVERSION. The keeper posts a HEARTBEAT on a schedule instead. Liquidations require a
/// recent heartbeat. If the chain halts the keeper cannot post, so on restart the heartbeat is
/// stale and liquidations are ALREADY disabled — no transaction needed at the critical moment, and
/// nothing to front-run. The default after any gap is "off". Fail-closed by construction.
///
/// This also covers keeper failure, sequencer failure, and RPC failure identically, because from
/// this contract's point of view they are the same event: the heartbeat stopped.
///
/// ONE BOUND, NOT TWO (G-LEND HIGH-1). A separate `maxHeartbeatAge` for the view and a tighter
/// `gapThreshold` for `heartbeat()` made the interval between them the very race the header above
/// claims cannot exist: at the deployed 90,000 / 900 pair, any outage under 25 hours left
/// `liquidationsAllowed()` TRUE in the first block back. Both sides now test the SAME predicate
/// against the SAME threshold, so no interval is an outage to one and normal to the other.
///
/// THE GRACE IS SIZED TO THE OUTAGE (G-LEND R2 MED-1). A flat grace bounded at 4x `gapThreshold` made
/// 901 seconds of keeper silence cost 4,501 seconds of total outage, borrowing included. Bounding a
/// RATIO was the error: a borrower who could not act for `gap` seconds is owed `gap` seconds to act,
/// so that is what the beat grants, capped at `resumeGrace`. Amplification is at most 2x for every
/// parameter pair — a property of the mechanism, not of the numbers chosen.
contract LivenessOracle {
    error NotKeeper();
    error NotGuardian();
    error NotRotationAdmin();
    error ZeroAddress();
    error BadGapThreshold();
    error BadResumeGrace();
    error RolesMustDiffer();
    error NoPendingRotation();
    error RotationNotElapsed(uint256 secondsRemaining);

    event Heartbeat(uint256 at);
    event GapDetected(uint256 gapSeconds, uint256 liquidationsResumeAt);
    event KeeperChanged(address indexed keeper);
    event GuardianChanged(address indexed guardian);
    event RotationProposed(address indexed keeper, address indexed guardian, uint256 effectiveAt);
    event RotationCancelled();

    /// Posts heartbeats. A hot key; compromise of it can only cause a spurious "healthy" reading,
    /// never a seizure, because it cannot move funds.
    address public keeper;
    /// Can rotate the keeper, immediately. Cold key.
    ///
    /// G-LEND R4 MED-2: NO LONGER IMMUTABLE, because on its own it was a permanent and
    /// UNRECOVERABLE kill switch for liquidation and for borrowing. `setKeeper` to an address that
    /// never beats put `liquidationsAllowed()` false from gapThreshold onward, forever, in one
    /// un-timelocked transaction — and with this slot immutable and EsseyMarkets.liveness immutable
    /// too, the only way back was redeploying the registry and every pool and migrating every
    /// position. R3 closed GUARDIAN == LIVENESS_GUARDIAN on the reasoning that their union is "halt
    /// everything, indefinitely"; one key already was, and unlike the union it had no exit.
    address public guardian;
    /// The recovery key: it may rotate BOTH roles above, but only behind the same 2-day notice
    /// every risk parameter pays. The deploy script binds it to the market admin (the multisig).
    ///
    /// Rotating the GUARDIAN, not just the keeper, is what actually closes MED-2 — a compromised
    /// guardian holds an immediate setKeeper and would re-brick the keeper in the block after every
    /// recovery, so a recovery path that cannot remove it is not one.
    ///
    /// WHAT THIS COSTS, stated because it is a real trade and not a free win: after 2 days of public
    /// notice this key can install a keeper of its own, which can hold liquidation open while the
    /// chain is demonstrably HEALTHY. It cannot hold it open through an OUTAGE — this block claimed
    /// that for a round and R5 INFO-1 refuted it: `heartbeat` derives the gap from `lastHeartbeat`,
    /// never from its caller, so during a halt a hostile keeper is as frozen as the borrowers and
    /// serves the full grace on restart — measured at 12 beats / 3,600s after a 4h halt.
    ///
    /// The bound is the notice, the RotationProposed event, and `EsseyMarkets.guardian` — a
    /// DIFFERENT, immutable address this rotation does not touch, which DeployMarkets._checkRoles
    /// forces to differ from both liveness roles, so `pauseLiquidation` and `disableMarket` stay
    /// available before, during and after a hostile commit. NOT the incumbent liveness guardian,
    /// which `commitRotation` replaces in the SAME transaction it replaces the keeper — R5 LOW-3.
    address public immutable rotationAdmin;
    /// Same 2 days as EsseyMarkets.PARAM_TIMELOCK: a privileged change that is atomic with its use
    /// is not a control at all.
    uint256 public constant ROTATION_TIMELOCK = 2 days;

    address public pendingKeeper;
    address public pendingGuardian;
    uint256 public pendingRotationEffectiveAt;

    /// THE bound, used in both directions. Silence longer than this is an outage: the view refuses
    /// liquidations while it lasts, and the beat that ends it starts the grace period. Set to a
    /// small multiple of the keeper's beat interval, so a couple of missed beats trips it — and no
    /// larger, because it is also the longest a halted chain can stay liquidatable-into.
    uint256 public immutable gapThreshold;
    /// CEILING on the post-gap grace; the grace GRANTED is the observed gap, capped here. Mirrors
    /// Chainlink's recommended sequencer grace at its cap.
    uint256 public immutable resumeGrace;

    /// Absolute ceilings, replacing `resumeGrace <= 4 * gapThreshold`. That ratio forced a tight
    /// detection threshold to buy a tight grace, which is backwards, and the DoS it guarded is gone.
    /// MAX_GAP_THRESHOLD is also the longest a halted chain stays liquidatable-into on restart — the
    /// whole of round-1 HIGH-1 — pinned here rather than left to the deploy script.
    uint256 public constant MAX_GAP_THRESHOLD = 1 hours;
    uint256 public constant MAX_RESUME_GRACE = 6 hours;

    uint256 public lastHeartbeat;
    /// Timestamp until which liquidations remain disabled following a gap. 0 = none pending.
    uint256 public liquidationsResumeAt;

    constructor(
        address keeper_,
        address guardian_,
        address rotationAdmin_,
        uint256 gapThreshold_,
        uint256 resumeGrace_
    ) {
        if (keeper_ == address(0) || guardian_ == address(0) || rotationAdmin_ == address(0)) revert ZeroAddress();
        // Held with either operational role, the recovery path recovers from nothing: the guardian
        // would rotate itself back in the same block, and the keeper would hold both halves of its
        // own liveness. Enforced HERE and not only in the deploy script, because the script binds
        // one deployment and this binds every one.
        if (rotationAdmin_ == keeper_ || rotationAdmin_ == guardian_) revert RolesMustDiffer();
        rotationAdmin = rotationAdmin_;
        if (gapThreshold_ == 0 || gapThreshold_ > MAX_GAP_THRESHOLD) revert BadGapThreshold();
        // A zero grace hands the restart race straight back: the beat that ends an outage would
        // re-open liquidations in the same block, which is the thing this contract exists to stop.
        if (resumeGrace_ == 0 || resumeGrace_ > MAX_RESUME_GRACE) revert BadResumeGrace();
        keeper = keeper_;
        guardian = guardian_;
        resumeGrace = resumeGrace_;
        gapThreshold = gapThreshold_;
        // Deliberately NOT seeded with block.timestamp. A fresh deployment has not proven liveness,
        // so it starts closed and opens on the first heartbeat.
        lastHeartbeat = 0;
    }

    /// Called by the keeper on a schedule: gapThreshold / 3, so two consecutive misses still leave
    /// margin. Beating SLOWER than gapThreshold makes every beat look like an outage and re-arms
    /// resumeGrace indefinitely — the self-inconsistency the old `maxHeartbeatAge / 3` advice
    /// produced against a tighter gapThreshold.
    ///
    /// A heartbeat that arrives after a gap does NOT immediately re-enable liquidations — it
    /// starts the grace period. This is the whole point: the chain being back is not the same as
    /// borrowers having had a chance to act.
    function heartbeat() external {
        if (msg.sender != keeper) revert NotKeeper();
        uint256 prev = lastHeartbeat;
        lastHeartbeat = block.timestamp;
        emit Heartbeat(block.timestamp);

        // prev == 0 is the first-ever heartbeat: treat it as a gap so a fresh deployment also
        // serves out the grace period rather than opening instantly.
        uint256 gap = prev == 0 ? type(uint256).max : block.timestamp - prev;
        if (gap <= gapThreshold) return;

        uint256 resumeAt = block.timestamp + (gap < resumeGrace ? gap : resumeGrace);
        // Never SHORTEN a grace already earned: a short gap arriving inside a long outage's window
        // would otherwise move the deadline nearer and cut reaction time a borrower was already owed.
        if (resumeAt > liquidationsResumeAt) liquidationsResumeAt = resumeAt;
        emit GapDetected(gap == type(uint256).max ? 0 : gap, liquidationsResumeAt);
    }

    /// Is the chain demonstrably live AND past any post-gap grace period?
    ///
    /// Callers gate LIQUIDATION on this. They must NOT gate repay or collateral top-up on it —
    /// during an outage recovery those are exactly the actions a borrower needs, and blocking them
    /// would turn a liveness control into the cause of the liquidation it exists to prevent.
    function liquidationsAllowed() public view returns (bool) {
        if (lastHeartbeat == 0) return false; // never proven live
        // The SAME predicate heartbeat() uses to declare a gap. Testing it here is what closes the
        // restart race: an outage in progress disables liquidations with no transaction, and the
        // beat that ends it hands straight over to resumeGrace. No interval belongs to neither.
        if (block.timestamp - lastHeartbeat > gapThreshold) return false;
        if (block.timestamp < liquidationsResumeAt) return false; // in post-gap grace
        return true;
    }

    /// Seconds until liquidations are allowed again, or 0 if they already are. For the UI, so a
    /// borrower can see they have a window rather than guessing.
    function secondsUntilLiquidationsAllowed() external view returns (uint256) {
        if (liquidationsAllowed()) return 0;
        if (block.timestamp < liquidationsResumeAt) return liquidationsResumeAt - block.timestamp;
        return 0; // blocked on liveness, not on the clock — needs a heartbeat, not time
    }

    function setKeeper(address keeper_) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (keeper_ == address(0)) revert ZeroAddress();
        if (keeper_ == rotationAdmin) revert RolesMustDiffer();
        keeper = keeper_;
        emit KeeperChanged(keeper_);
    }

    /// R4 MED-2's recovery path. Both roles in one payload because rotating the keeper alone leaves
    /// a compromised guardian free to undo it immediately.
    function proposeRotation(address keeper_, address guardian_) external {
        if (msg.sender != rotationAdmin) revert NotRotationAdmin();
        if (keeper_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (keeper_ == rotationAdmin || guardian_ == rotationAdmin) revert RolesMustDiffer();
        pendingKeeper = keeper_;
        pendingGuardian = guardian_;
        pendingRotationEffectiveAt = block.timestamp + ROTATION_TIMELOCK;
        emit RotationProposed(keeper_, guardian_, pendingRotationEffectiveAt);
    }

    /// PERMISSIONLESS once ripe, exactly like EsseyMarkets.commitMarket: the notice is the control,
    /// and an executor privilege would only add a key that could sit on a recovery.
    function commitRotation() external {
        uint256 at = pendingRotationEffectiveAt;
        if (at == 0) revert NoPendingRotation();
        if (block.timestamp < at) revert RotationNotElapsed(at - block.timestamp);
        keeper = pendingKeeper;
        guardian = pendingGuardian;
        emit KeeperChanged(keeper);
        emit GuardianChanged(guardian);
        _clearRotation();
    }

    /// Cancellable by the recovery key alone. NOT by the guardian: a guardian that could veto its
    /// own removal is the unrecoverable state this whole path exists to end.
    function cancelRotation() external {
        if (msg.sender != rotationAdmin) revert NotRotationAdmin();
        if (pendingRotationEffectiveAt == 0) revert NoPendingRotation();
        _clearRotation();
        emit RotationCancelled();
    }

    function _clearRotation() internal {
        delete pendingKeeper;
        delete pendingGuardian;
        delete pendingRotationEffectiveAt;
    }
}
