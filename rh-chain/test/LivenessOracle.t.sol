// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";

contract LivenessOracleTest is Test {
    LivenessOracle o;
    address KEEPER;
    address GUARDIAN;
    address ROTATOR;

    uint256 constant GRACE = 30 minutes;
    uint256 constant GAP = 10 minutes; // ~2 missed beats at a 5-minute cadence, and THE bound

    function setUp() public {
        KEEPER = makeAddr("keeper");
        GUARDIAN = makeAddr("guardian");
        ROTATOR = makeAddr("rotationAdmin");
        vm.warp(1_753_110_000);
        o = new LivenessOracle(KEEPER, GUARDIAN, ROTATOR, GAP, GRACE);
    }

    function _beat() internal {
        vm.prank(KEEPER);
        o.heartbeat();
    }

    /// A fresh deployment has not proven anything. It must start CLOSED.
    function test_startsClosed() public view {
        assertFalse(o.liquidationsAllowed());
        assertEq(o.lastHeartbeat(), 0);
    }

    /// "Never beat" and "beat, but stale" are different states, and the first must be closed on
    /// its own terms. Near genesis the staleness check alone would NOT catch it — block.timestamp
    /// minus a zero lastHeartbeat is small — so without the explicit zero check the oracle would
    /// read as OPEN on a fresh chain. Found by mutation: deleting that check passed every other test.
    function test_neverBeatIsClosedEvenAtLowTimestamps() public {
        LivenessOracle fresh = new LivenessOracle(KEEPER, GUARDIAN, ROTATOR, GAP, GRACE);
        vm.warp(60); // 60s after genesis: younger than gapThreshold
        assertEq(fresh.lastHeartbeat(), 0);
        assertFalse(fresh.liquidationsAllowed(), "must be closed because it has NEVER beat");
    }

    /// Even the first heartbeat serves the grace period — being alive now is not evidence that
    /// borrowers have had a chance to act.
    function test_firstHeartbeatStartsGraceNotOpen() public {
        _beat();
        assertFalse(o.liquidationsAllowed(), "first beat must not open immediately");
        _advanceLive(GRACE);
        assertTrue(o.liquidationsAllowed());
    }

    /// Advance `secs` the way a live keeper would: beating every 5 minutes throughout, so the
    /// heartbeat stays fresh. Warping without beating models an OUTAGE, not the passage of time —
    /// conflating the two is what made the first draft of these tests wrong.
    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes);
            _beat();
        }
        vm.warp(end);
        _beat();
    }

    function _bringOnline() internal {
        _beat();
        _advanceLive(GRACE);
        assertTrue(o.liquidationsAllowed());
    }

    function test_steadyHeartbeatKeepsItOpen() public {
        _bringOnline();
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 5 minutes);
            _beat();
            assertTrue(o.liquidationsAllowed(), "steady beats must not trip the gap logic");
        }
    }

    /// THE CORE CASE. The chain halts, so the keeper cannot post. Liquidations must be disabled
    /// ALREADY when it comes back — with no transaction needed at the critical moment, and
    /// therefore nothing for a liquidation bot to front-run.
    function test_outageDisablesLiquidationsWithoutAnyTransaction() public {
        _bringOnline();
        // chain halts for 4 hours: no heartbeat is possible
        vm.warp(block.timestamp + 4 hours);
        assertFalse(o.liquidationsAllowed(), "must be closed on restart with NO tx sent");
    }

    /// And coming back online does not immediately re-open — the borrower gets the grace window.
    function test_restartStartsGraceRatherThanReopening() public {
        _bringOnline();
        vm.warp(block.timestamp + 4 hours); // outage
        _beat(); // keeper's first post-outage beat
        assertFalse(o.liquidationsAllowed(), "restart must not re-open instantly");

        _advanceLive(GRACE - 5 minutes);
        assertFalse(o.liquidationsAllowed(), "still inside grace");
        _advanceLive(5 minutes);
        assertTrue(o.liquidationsAllowed(), "open after grace");
    }

    /// Keeper failure is indistinguishable from chain failure, and must be treated identically.
    function test_keeperFailureIsTreatedAsAnOutage() public {
        _bringOnline();
        vm.warp(block.timestamp + GAP + 1); // keeper simply stopped
        assertFalse(o.liquidationsAllowed());
    }

    /// SHORT OUTAGE. It must trip the grace on the beat that ends it, as well as closing the view
    /// while it lasts.
    function test_shortOutageStillTripsTheGrace() public {
        _bringOnline();
        vm.warp(block.timestamp + 12 minutes);
        _beat();
        assertFalse(o.liquidationsAllowed(), "a short outage must still start the grace");
        _advanceLive(GRACE);
        assertTrue(o.liquidationsAllowed());
    }

    /// G-LEND HIGH-1. The shipped pair was maxHeartbeatAge 90,000 against gapThreshold 900, and the
    /// whole 25-hour interval between them was open season: after any halt shorter than that,
    /// liquidationsAllowed() was still TRUE in the first block back, so a bot's queued liquidation
    /// executed before the keeper could post the beat that registers the gap. Proven at 6 hours.
    /// There is no such interval now — one threshold serves both sides.
    function test_shortOutageClosesLiquidationsWithNoTransaction() public {
        _bringOnline();
        vm.warp(block.timestamp + 6 hours);
        assertFalse(o.liquidationsAllowed(), "HIGH-1: a 6h halt must close BEFORE the keeper posts");
    }

    /// "Closes eventually" is not the property. The property is that the view and heartbeat() agree
    /// on the SAME instant, so no interval is an outage to one and normal to the other.
    function test_theViewAndTheBeatShareOneBoundary() public {
        _bringOnline();
        vm.warp(o.lastHeartbeat() + GAP);
        assertTrue(o.liquidationsAllowed(), "at the threshold: not an outage");
        _beat();
        assertTrue(o.liquidationsAllowed(), "and the beat agrees - no gap registered");

        vm.warp(block.timestamp + GAP + 1);
        assertFalse(o.liquidationsAllowed(), "one second past: closed with NO tx sent");
        _beat();
        assertFalse(o.liquidationsAllowed(), "and the beat hands straight over to the grace");
    }

    /// The cadence the contract recommends must not itself look like an outage. It used to: the old
    /// advice was maxHeartbeatAge / 3 = 8.3h against a 900s gapThreshold, so every beat at the
    /// recommended cadence registered a gap and re-armed an hour of grace, indefinitely.
    function test_theRecommendedCadenceNeverTripsAGap() public {
        _bringOnline();
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + o.gapThreshold() / 3);
            _beat();
            assertTrue(o.liquidationsAllowed(), "the recommended cadence must not arm the grace");
        }
    }

    function test_gapThresholdMustBeNonZero() public {
        vm.expectRevert(LivenessOracle.BadGapThreshold.selector);
        new LivenessOracle(KEEPER, GUARDIAN, ROTATOR, 0, GRACE);
    }

    /// G-LEND R2 MED-1. The old rule bounded the RATIO (resumeGrace <= 4x gapThreshold), which forced a
    /// tight detection threshold to buy a tight grace and left the deploy sitting on the ceiling. The
    /// bound is now absolute on each side, because the amplification is handled by the mechanism.
    function test_theBoundsAreAbsoluteNotARatio() public {
        // 6x, un-deployable under the old rule, is fine now: the grace granted is the gap observed.
        LivenessOracle wide = new LivenessOracle(KEEPER, GUARDIAN, ROTATOR, 10 minutes, 1 hours);
        assertEq(wide.resumeGrace(), 1 hours);

        vm.expectRevert(LivenessOracle.BadResumeGrace.selector);
        new LivenessOracle(KEEPER, GUARDIAN, ROTATOR, 10 minutes, 6 hours + 1);
        vm.expectRevert(LivenessOracle.BadResumeGrace.selector);
        new LivenessOracle(KEEPER, GUARDIAN, ROTATOR, 10 minutes, 0); // a zero grace hands back the restart race
        vm.expectRevert(LivenessOracle.BadGapThreshold.selector);
        new LivenessOracle(KEEPER, GUARDIAN, ROTATOR, 1 hours + 1, GRACE); // round-1 HIGH-1, pinned in the ctor
        new LivenessOracle(KEEPER, GUARDIAN, ROTATOR, 1 hours, 6 hours); // both exactly at the ceiling
    }

    /// THE FINDING. 901 seconds of keeper silence used to cost 4,501 seconds of total outage, because
    /// the beat that ended a 901s gap armed the FULL hour of grace. The grace is now the gap.
    function test_aShortGapCostsAtMostTwiceItself() public {
        _bringOnline();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + GAP + 1);
        assertFalse(o.liquidationsAllowed());
        _beat();
        assertEq(o.liquidationsResumeAt(), block.timestamp + GAP + 1, "the grace equals the gap");

        uint256 reopened;
        for (uint256 i = 0; i < 40; i++) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
            if (o.liquidationsAllowed()) {
                reopened = block.timestamp;
                break;
            }
        }
        assertGt(reopened, 0, "must reopen");
        assertLe(reopened - t0, 2 * (GAP + 1) + GAP / 3, "amplification is bounded at 2x, plus one beat");
    }

    /// And a real outage still earns the FULL window — the cap binds from above, not the gap.
    function test_aLongOutageStillEarnsTheFullGrace() public {
        _bringOnline();
        vm.warp(block.timestamp + 4 hours);
        _beat();
        assertEq(o.liquidationsResumeAt(), block.timestamp + GRACE, "capped at resumeGrace");
    }

    /// A short gap arriving inside a long outage's grace must not SHORTEN it. Without the monotonic
    /// guard in heartbeat() the second, smaller grace would move the deadline nearer and cut the
    /// reaction time the long outage already earned.
    function test_aLaterShortGapCannotShortenAnEarnedGrace() public {
        _bringOnline();
        vm.warp(block.timestamp + 4 hours);
        _beat();
        uint256 earned = o.liquidationsResumeAt();
        vm.warp(block.timestamp + GAP + 1); // a short gap while still inside the grace
        _beat();
        assertEq(o.liquidationsResumeAt(), earned, "the earned deadline stands");
    }

    function test_onlyKeeperCanBeat() public {
        vm.expectRevert(LivenessOracle.NotKeeper.selector);
        o.heartbeat();
    }

    function test_guardianRotatesKeeper() public {
        address k2 = makeAddr("keeper2");
        vm.prank(GUARDIAN);
        o.setKeeper(k2);
        assertEq(o.keeper(), k2);
        vm.prank(k2);
        o.heartbeat(); // new keeper works
    }

    function test_keeperCannotBeRotatedToZero() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(LivenessOracle.ZeroAddress.selector);
        o.setKeeper(address(0));
    }

    function test_nonGuardianCannotRotateKeeper() public {
        vm.prank(KEEPER);
        vm.expectRevert(LivenessOracle.NotGuardian.selector);
        o.setKeeper(makeAddr("keeper2"));
    }

    function test_countdownIsVisibleToTheUi() public {
        _bringOnline();
        vm.warp(block.timestamp + 4 hours); // outage
        _beat();
        assertEq(o.secondsUntilLiquidationsAllowed(), GRACE);
        _advanceLive(20 minutes);
        assertEq(o.secondsUntilLiquidationsAllowed(), GRACE - 20 minutes);
    }

    // ------------------------------------------------- R4 MED-2: the recovery path

    /// THE HOLE THE MUTATION SWEEP FOUND. `cancelRotation` is deliberately NOT available to the
    /// guardian, and the reason is the whole finding: a guardian that can veto its own removal
    /// restores exactly the permanent, unrecoverable kill switch the rotation exists to end. That
    /// was a comment asserting a mechanism, with nothing testing it — letting the guardian cancel
    /// left the entire suite green.
    function test_theGuardianCannotVetoItsOwnRemoval() public {
        address newKeeper = makeAddr("newKeeper");
        address newGuardian = makeAddr("newGuardian");
        vm.prank(ROTATOR);
        o.proposeRotation(newKeeper, newGuardian);

        vm.prank(GUARDIAN);
        vm.expectRevert(LivenessOracle.NotRotationAdmin.selector);
        o.cancelRotation();
        vm.prank(KEEPER);
        vm.expectRevert(LivenessOracle.NotRotationAdmin.selector);
        o.cancelRotation();

        vm.warp(block.timestamp + o.ROTATION_TIMELOCK());
        o.commitRotation();
        assertEq(o.guardian(), newGuardian, "the removal stands");
    }

    /// The recovery key may still change its mind, and a cancelled rotation is not a committable one.
    function test_theRecoveryKeyCanCancelItsOwnProposal() public {
        vm.prank(ROTATOR);
        o.proposeRotation(makeAddr("k"), makeAddr("g"));
        vm.prank(ROTATOR);
        o.cancelRotation();
        assertEq(o.pendingRotationEffectiveAt(), 0, "cleared");

        vm.warp(block.timestamp + o.ROTATION_TIMELOCK() + 1);
        vm.expectRevert(LivenessOracle.NoPendingRotation.selector);
        o.commitRotation();
        assertEq(o.guardian(), GUARDIAN, "and nothing rotated");
    }

    /// The notice is the control, so it is EXACT in both directions.
    function test_theRotationTimelockBoundaryIsExact() public {
        vm.prank(ROTATOR);
        o.proposeRotation(makeAddr("k"), makeAddr("g"));
        uint256 ripe = o.pendingRotationEffectiveAt();
        assertEq(ripe, block.timestamp + 2 days, "two days, the same notice every risk parameter pays");

        vm.warp(ripe - 1);
        vm.expectRevert(abi.encodeWithSelector(LivenessOracle.RotationNotElapsed.selector, uint256(1)));
        o.commitRotation();
        vm.warp(ripe);
        o.commitRotation();
        assertEq(o.keeper(), makeAddr("k"), "and on the second itself it commits");
    }

    /// The guardian keeps its immediate lever — that is its job — but it may not hand the keeper
    /// role to the recovery key and collapse the two-of into one.
    function test_theGuardianMayNotMakeTheRecoveryKeyItsKeeper() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(LivenessOracle.RolesMustDiffer.selector);
        o.setKeeper(ROTATOR);
        vm.prank(GUARDIAN);
        o.setKeeper(makeAddr("someoneElse")); // any other address is fine
    }

    function test_zeroAddressRejected() public {
        vm.expectRevert(LivenessOracle.ZeroAddress.selector);
        new LivenessOracle(address(0), GUARDIAN, ROTATOR, GAP, GRACE);
        vm.expectRevert(LivenessOracle.ZeroAddress.selector);
        new LivenessOracle(KEEPER, address(0), ROTATOR, GAP, GRACE);
    }
}
