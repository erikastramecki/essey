// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {GLendR5Base} from "./GLendR5.t.sol";
import {EsseyPool} from "../src/EsseyPool.sol";

/// G-LEND round 6, on the same real-chain fixture rounds 4 and 5 are pinned against.
///
/// R5 gave the delay line a wall clock so a feed outage could not restart the six hours a position
/// had already served. R6's finding is what that clock started measuring: `_holdConfirmable` pushed
/// the ring head back through `_confirmable`, which stamps `block.timestamp`, so MAX_CONFIRM_AGE
/// bounded the age of the last CALL rather than the age of the PRICE. One observation gap spanning
/// the feed's final round left an arbitrarily old print as the ring head, and the returning keeper
/// warmed it into "corroborated" — measured here at 300 seconds from Monday's gap to a seizure,
/// against 27,000 for the same position under a keeper that never stopped observing.
abstract contract GLendR6Base is GLendR5Base {
    /// The precondition, built exactly: a sample taken as the ring HEAD, then a window longer than
    /// `maxStaleness` (90,000s) with ZERO observations spanning the feed's final round, so nothing
    /// overwrites the sample before the feed goes dark. Returns the position, Friday's close, the
    /// sampled print and the instant it was taken.
    function _wickThenAnObservationGap(bool keeperObserves)
        internal
        returns (uint256 id, int256 friday, int256 wick, uint256 wickAt)
    {
        (id, friday) = _seasonedPosition();
        _hold(friday, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        assertFalse(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "healthy at Friday's close");

        // One sub-bound print — a real wick, inside MAX_PRICE_DEVIATION_BPS so nothing arms — taken
        // by a permissionless caller a full CONFIRM_STEP after the last push, so it lands in the ring.
        wick = (friday * 88) / 100;
        _holdQuiet(friday, markets.CONFIRM_STEP() + 1);
        _reprice(wick);
        markets.syncMultiplier(AAPL);
        wickAt = block.timestamp;
        assertEq(markets.priceDesyncAt(AAPL), 0, "sub-bound: the breaker never arms");
        assertTrue(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "and the wick alone is underwater");

        // The price recovers, the feed publishes its final round, and the market closes. The print
        // stays readable for `maxStaleness` after it, which is why the gap has to outlast that.
        _freeze(friday);
        if (keeperObserves) _weekend(27 hours);
        else _weekendQuiet(27 hours);
        assertFalse(markets.canLiquidate(AAPL), "the feed is genuinely dark before the keeper returns");
    }

    /// Beat to `t` without observing and without repricing, landing on it exactly — `_weekendQuiet`
    /// overshoots by up to one tick, and a boundary test cannot afford that.
    function _quietUntil(uint256 t) internal {
        while (block.timestamp + GAP / 3 < t) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
        }
        vm.warp(t);
        _beat();
        _postDepth();
    }

    /// Push one observation at a known instant: a full CONFIRM_STEP of quiet clears the rate limit,
    /// so the next one lands in the ring rather than being dropped by it.
    function _pushHead() internal returns (uint256 at) {
        _holdQuiet(realPrice, markets.CONFIRM_STEP() + 1);
        _reprice(realPrice);
        markets.syncMultiplier(AAPL);
        at = block.timestamp;
    }
}

/// MED-1. A warm push may refresh the line's SCHEDULE; it must not refresh a price's claim to have
/// been checked. Both tests are RED against c04a6ce.
contract GLendR6ObservationGap is GLendR6Base {
    function setUp() public {
        _setUpFork();
    }

    /// The finding, inverted. The keeper returns INSIDE the dark window and can only warm — and what
    /// it would be warming is a print from 36 hours earlier that no observation has re-read.
    function test_anObservationGapCannotResurrectAnAncientPriceAsCorroborated() public {
        (uint256 id, int256 friday, int256 wick, uint256 wickAt) = _wickThenAnObservationGap(false);
        assertEq(markets.confirmedPrice(AAPL), uint256(friday), "Friday's close is still the read slot");

        _weekend(markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        console.log("wall age of the corroborated PRICE (s):", block.timestamp - wickAt);
        console.log("age its takenAt reports (s)           :", block.timestamp - markets.confirmedObservedAt(AAPL));
        console.log("MAX_CONFIRM_AGE (s)                   :", markets.MAX_CONFIRM_AGE());
        // And why the fix is not a `seenPriceAt` ceiling in `corroboratedValue`: the ceiling that
        // shape needs is MAX_CONFIRM_AGE + maxStaleness + one weekend = 295,200s, and this state
        // sits well inside it. Bounding the OBSERVATION GAP is what catches this; bounding the
        // absolute age of the last live read is not, unless it is tightened until it refuses an
        // ordinary weekend as well.
        console.log("age seenPriceAt reports (s)           :", block.timestamp - markets.seenPriceAt(AAPL));
        (, bool ok) = markets.corroboratedValue(AAPL, _coll());
        assertTrue(markets.confirmedPrice(AAPL) != uint256(wick), "the sample never becomes the corroborated price");
        assertFalse(ok, "and nothing is corroborated at all: no observation survived the gap");

        // Monday gaps down. Underwater at the live price is the first conjunct and it holds; the
        // second must not be satisfied by the resurrected sample.
        int256 monday = (friday * 82) / 100;
        _reprice(monday);
        _beat();
        _postDepth();
        assertTrue(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "underwater at the LIVE price");
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.PriceNotCorroborated.selector, AAPL));
        pool.liquidate(id);
    }

    /// The same state, priced: how long Monday's move has to STAND before it can be seized. 300
    /// seconds against c04a6ce — a move that had stood for no time at all.
    function test_aMoveThatFollowsAnObservationGapStillPaysTheFullDelay() public {
        (uint256 id, int256 friday,,) = _wickThenAnObservationGap(false);
        _weekend(markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());

        uint256 secs = _secondsToLiquidatable(id, (friday * 82) / 100);
        console.log("seconds from feed-return to liquidatable:", secs);
        assertGe(secs, markets.PRICE_CONFIRM_DELAY(), "a move that has stood zero seconds pays the delay in full");
        assertLe(
            secs,
            markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP(),
            "and it does open, within one ceiling of the delay"
        );
    }

    /// The control, and the half of R6's residual that is CLOSED: an observing keeper leaves the
    /// caller no choice of frozen print. The feed stops MOVING 25h before it stops being READABLE,
    /// so every push in that window records the same close and overwrites the sample.
    function test_anObservingKeeperLeavesTheCallerNoChoiceOfFrozenPrint() public {
        (uint256 id, int256 friday, int256 wick,) = _wickThenAnObservationGap(true);
        assertTrue(uint256(wick) != uint256(friday), "the sample and the close really do differ");
        // R7 INFO-2: `confirmedPrice` is Friday's close in BOTH worlds — the read slot is four behind
        // the head, so the wick never reaches it either way, and asserting it here said nothing. What
        // the observing keeper bought is a LIVE line: the close pushed the wick out of the head, so
        // the head is inside its ceiling and still corroborates. Unobserved, the head IS the wick.
        assertLe(
            block.timestamp - markets.confirmedObservedAt(AAPL),
            markets.MAX_CONFIRM_AGE(),
            "the close overwrote the sample, so the head is inside its ceiling"
        );
        (, bool corroborated) = markets.corroboratedValue(AAPL, _coll());
        assertTrue(corroborated, "and the line still corroborates, which the unobserved world does not");

        uint256 secs = _secondsToLiquidatable(id, (friday * 82) / 100);
        console.log("seconds from feed-return to liquidatable:", secs);
        assertGe(secs, markets.PRICE_CONFIRM_DELAY(), "the full delay, paid");
        assertLe(
            secs,
            markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP(),
            "and it does open, within one ceiling of the delay"
        );
    }

    /// The two ceilings are ONE ceiling. `corroboratedValue` refuses an observation STRICTLY older
    /// than MAX_CONFIRM_AGE, so a head at the ceiling is not yet dead and carrying it forward is
    /// legitimate; a head one second past it is dead and nothing may carry it. Both sides, because a
    /// comparison pinned on one side is half a pin — and this one decides whether a market goes
    /// silently unliquidatable or keeps vouching for a price nobody re-read.
    function test_theWarmCeilingIsTheSameCeilingTheReadApplies() public {
        uint256 snap = vm.snapshotState();
        assertTrue(_warmsAfterAnObservationGapOf(markets.MAX_CONFIRM_AGE()), "a head AT the ceiling still warms");
        vm.revertToState(snap);
        assertFalse(_warmsAfterAnObservationGapOf(markets.MAX_CONFIRM_AGE() + 1), "one second past it, nothing does");
    }

    /// Does the line survive a `gap`-second hole in the observations, with the feed dark throughout
    /// so a warm push is the only thing that can advance it?
    function _warmsAfterAnObservationGapOf(uint256 gap) internal returns (bool ok) {
        _hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        uint256 headAt = _pushHead();
        _neverReadable(realPrice);
        _quietUntil(headAt + gap);
        markets.syncMultiplier(AAPL);
        _weekend(markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        (, ok) = markets.corroboratedValue(AAPL, _coll());
    }
}

/// LOW-2. Nothing pinned that the warm push stands on the ring HEAD rather than on the last RAW
/// read, and the alternative — `_confirmable(token, seenPrice[token], seenMultiplier[token])`, the
/// natural simplification — survived 392/392. It is not equivalent: `_syncPrice` writes `seenPrice`
/// unconditionally while `_confirmable` is rate-limited, so a feed leg landing inside a step is in
/// the raw read and NOT in the ring. Under the simplification that dislocated price becomes the
/// corroborated observation for the whole outage, which is R3 HIGH-1 reopened for every dark window.
contract GLendR6WarmSource is GLendR6Base {
    function setUp() public {
        _setUpFork();
    }

    function test_theWarmPushStandsOnTheRingHeadNotOnTheLastRawRead() public {
        _hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        uint256 prePrice = markets.confirmedPrice(AAPL);
        assertEq(prePrice, uint256(realPrice), "the whole ring holds the pre-leg pair");

        // Inside a step: pushes are CONFIRM_STEP apart and the keeper ticks every 300s, so an
        // observation taken the instant `_hold` returns is always rate-limited out of the ring.
        int256 leg = (realPrice * 81) / 100;
        _reprice(leg);
        markets.syncMultiplier(AAPL);
        assertEq(markets.seenPrice(AAPL), uint256(leg), "the raw read took the leg");
        assertEq(markets.priceDesyncAt(AAPL), 0, "sub-bound, so this is the case isUnderwaterCorroborated is for");

        // Dark immediately, with no readable window at all: from here the only thing that can
        // advance the ring is the warm push.
        _neverReadable(leg);
        uint256 observedAtBefore = markets.confirmedObservedAt(AAPL);
        for (uint256 i = 0; i < 6; i++) {
            _weekend(markets.CONFIRM_STEP() + 300);
            assertEq(markets.confirmedPrice(AAPL), prePrice, "every warm push stands on the ring head");
        }
        // NOT VACUOUS (R7 INFO-2): an equality against the pre-outage value also holds if the ring
        // never moved, which is why this whole test used to pass with the warm push deleted (M27).
        assertGt(markets.confirmedObservedAt(AAPL), observedAtBefore, "and the line really did warm");
        (, bool corroborated) = markets.corroboratedValue(AAPL, _coll());
        assertTrue(corroborated, "with a corroborated price still standing at the end of the outage");
        console.log("corroborated price after the outage:", markets.confirmedPrice(AAPL));
        console.log("the raw read it must NOT have used :", markets.seenPrice(AAPL));
        assertEq(markets.seenPrice(AAPL), uint256(leg), "and the raw read still differs, so the test discriminates");
    }
}
