// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {GLendR6Base} from "./GLendR6.t.sol";
import {IScaledUI} from "../src/interfaces/IScaledUI.sol";

/// G-LEND round 7 — the warmed pair's MULTIPLIER half, which nothing pinned. Two survivors lived
/// here: `seenMultiplier[token]` (LOW-2, 397/397) and `confirmedObservation(token).mult` (398/398).
///
/// R5's `test_theWarmedObservationStaysAMatchedPair` mocks the split AFTER the feed goes dark, and a
/// dark feed is exactly when `seenMultiplier` cannot advance (`EsseyMarkets.sol:686` is gated on
/// `_syncPrice` returning true) — so the two values are equal by construction there. M28 warms with
/// the LIVE read and M32 takes BOTH halves raw; the one-half variants fall between them.
///
/// Under either, every warm push for the rest of an outage vouches for a pair that never coexisted:
/// R4 MED-1's shape reopened for the whole dark window, mis-scaling corroborated collateral by the
/// whole ratio of the corporate action.
contract GLendR7WarmPair is GLendR6Base {
    function setUp() public {
        _setUpFork();
    }

    function test_theWarmedMultiplierIsTheRingHeadsNotTheLastRawRead() public {
        uint256 m0 = IScaledUI(AAPL).uiMultiplier();
        _hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        assertEq(markets.confirmedMultiplier(AAPL), m0, "the whole ring holds the pre-leg pair");

        // The leg lands while the feed still READS, inside a CONFIRM_STEP, so the raw read takes it
        // and `_confirmable` rate-limits it out of the ring. R5's fixture cannot produce that order.
        vm.mockCall(AAPL, abi.encodeWithSelector(IScaledUI.uiMultiplier.selector), abi.encode(m0 / 2));
        markets.syncMultiplier(AAPL);
        assertEq(markets.seenMultiplier(AAPL), m0 / 2, "the raw read took the leg");
        assertEq(markets.confirmedMultiplier(AAPL), m0, "and the ring did not");

        _neverReadable(realPrice);
        uint256 observedAtBefore = markets.confirmedObservedAt(AAPL);
        for (uint256 i = 0; i < 6; i++) {
            _weekend(markets.CONFIRM_STEP() + 300);
            assertEq(markets.confirmedMultiplier(AAPL), m0, "every warm push carries the ring head's OWN multiplier");
        }

        // NOT VACUOUS: an equality against the pre-outage value also holds if nothing warmed at all,
        // which is how M27 passes GLendR6WarmSource. Pin that the line MOVED as well.
        assertGt(markets.confirmedObservedAt(AAPL), observedAtBefore, "and the line really did warm");
        (, bool ok) = markets.corroboratedValue(AAPL, _coll());
        assertTrue(ok, "with a corroborated price still standing at the end of the outage");
        console.log("corroborated multiplier after the outage:", markets.confirmedMultiplier(AAPL));
        console.log("the raw read it must NOT have used      :", markets.seenMultiplier(AAPL));
        assertEq(markets.seenMultiplier(AAPL), m0 / 2, "and the raw read still differs, so the test discriminates");
        assertEq(markets.confirmedPrice(AAPL), uint256(realPrice), "the price half is untouched either way");
    }

    /// THE SIXTH FALSE GREEN, found by asking the same question of the OTHER slot. R5's older-slot
    /// test varies five PRICES and holds one multiplier, so it pinned half the property — and
    /// `head.mult` -> `confirmedObservation(token).mult` survived 398/398, the test above included.
    /// The read slot is four steps behind: a leg that reached the head before the close is rotated
    /// back out, pairing a post-leg price with a pre-leg multiplier for the whole outage.
    function test_theWarmedMultiplierIsTheLastKnownGoodPairNotAnOlderSlot() public {
        // Five distinct multipliers, one per slot: 5% steps against MAX_PRICE_DEVIATION_BPS of
        // 2,000 so nothing arms, one CONFIRM_STEP apart so each lands in its own slot.
        uint256 m = IScaledUI(AAPL).uiMultiplier();
        for (uint256 i = 0; i < 6; i++) {
            m = (m * 95) / 100;
            vm.mockCall(AAPL, abi.encodeWithSelector(IScaledUI.uiMultiplier.selector), abi.encode(m));
            _hold(realPrice, markets.CONFIRM_STEP());
        }
        uint256 lastGood = markets.seenMultiplier(AAPL);
        assertEq(lastGood, m, "the raw read holds the newest multiplier");
        assertTrue(markets.confirmedMultiplier(AAPL) != lastGood, "the read slot is an OLDER multiplier, as designed");

        _neverReadable(realPrice);
        uint256 observedAtBefore = markets.confirmedObservedAt(AAPL);
        _weekend(20 hours);

        // Six consecutive positions, not one: the read slot rotates the five old multipliers forward
        // intact, so a single sample agrees with correct behaviour once every five pushes.
        for (uint256 i = 0; i < 6; i++) {
            _weekend(markets.CONFIRM_STEP() + 300);
            assertEq(markets.confirmedMultiplier(AAPL), lastGood, "every slot stands on the LAST readable pair");
        }
        assertGt(markets.confirmedObservedAt(AAPL), observedAtBefore, "and the line really did warm");
        (, bool ok) = markets.corroboratedValue(AAPL, _coll());
        assertTrue(ok, "with a corroborated price still standing at the end of the outage");
    }
}
