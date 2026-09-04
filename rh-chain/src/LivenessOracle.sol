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
contract LivenessOracle {
    error NotKeeper();
    error NotGuardian();
    error ZeroAddress();
    error BadGapThreshold();
    error BadResumeGrace();

    event Heartbeat(uint256 at);
    event GapDetected(uint256 gapSeconds, uint256 liquidationsResumeAt);
    event KeeperChanged(address indexed keeper);

    /// Posts heartbeats. A hot key; compromise of it can only cause a spurious "healthy" reading,
    /// never a seizure, because it cannot move funds.
    address public keeper;
    /// Can rotate the keeper. Cold key.
    address public immutable guardian;

    /// THE bound, used in both directions. Silence longer than this is an outage: the view refuses
    /// liquidations while it lasts, and the beat that ends it starts the grace period. Set to a
    /// small multiple of the keeper's beat interval, so a couple of missed beats trips it — and no
    /// larger, because it is also the longest a halted chain can stay liquidatable-into.
    uint256 public immutable gapThreshold;
    /// After a detected gap, liquidations stay disabled this long so borrowers can react.
    /// Mirrors Chainlink's own recommended sequencer grace period.
    uint256 public immutable resumeGrace;

    uint256 public lastHeartbeat;
    /// Timestamp until which liquidations remain disabled following a gap. 0 = none pending.
    uint256 public liquidationsResumeAt;

    constructor(address keeper_, address guardian_, uint256 gapThreshold_, uint256 resumeGrace_) {
        if (keeper_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (gapThreshold_ == 0) revert BadGapThreshold();
        // The post-gap grace must not dwarf the gap that triggers it. A gap only just over the threshold
        // — e.g. routine keeper jitter — would otherwise suspend liquidations for many multiples of the
        // outage's own length, and repeated jitter re-arms it: a liquidation DoS. Bounding resumeGrace to
        // <= 4x gapThreshold makes that impossible-by-construction; the previously-shipped 1h grace over a
        // 10m gap (6x) is now un-deployable.
        if (resumeGrace_ > 4 * gapThreshold_) revert BadResumeGrace();
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
        if (gap > gapThreshold) {
            liquidationsResumeAt = block.timestamp + resumeGrace;
            emit GapDetected(gap == type(uint256).max ? 0 : gap, liquidationsResumeAt);
        }
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
        keeper = keeper_;
        emit KeeperChanged(keeper_);
    }
}
