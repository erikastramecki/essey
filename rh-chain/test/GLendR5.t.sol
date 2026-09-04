// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {GLendR4Base} from "./GLendR4.t.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IScaledUI} from "../src/interfaces/IScaledUI.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// G-LEND round 5, on the real chain, on the same fixture round 4 is pinned against.
///
/// R5 found no hole in the delay line — the attacks on it are 12/12 red for the right reason. What it
/// found is a CLOCK THE LINE COULD NOT WIND: `_confirmable` was reachable only through a readable
/// price, so the ~40h the AAPL feed is unreadable every weekend restarted the six-hour delay at the
/// feed's RETURN. Measured at 21,900s from Monday's first print to the first liquidation of a
/// position 60% underwater, on a calendar any adversary can read, with `writeOff` sharing the gate
/// and no operator override.
abstract contract GLendR5Base is GLendR4Base {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    /// The feed is stale the instant this is set — no readable window at all, unlike `_freeze`.
    function _neverReadable(int256 p) internal {
        vm.mockCall(
            AAPL_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), p, block.timestamp - 200_000, block.timestamp - 200_000, uint80(1))
        );
    }

    /// The feed STOPS PUBLISHING (the weekend). `updatedAt` stays put and ages past `maxStaleness`,
    /// so `priceOf` reverts PriceStale and `_readablePrice` answers 0 for as long as this holds.
    function _freeze(int256 p) internal {
        vm.mockCall(
            AAPL_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), p, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// The DEPLOYED keeper's tick through an outage: beat and observe every 300s, never repricing.
    /// `keeper/liveness-keeper.mjs:113` calls syncMultiplier on exactly this beat.
    function _weekend(uint256 dt) internal {
        uint256 end = block.timestamp + dt;
        while (block.timestamp < end) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
            markets.syncMultiplier(AAPL);
        }
        _postDepth();
    }

    /// The same outage with the keeper beating but NOT observing — R4 HIGH-2's world.
    function _weekendQuiet(uint256 dt) internal {
        uint256 end = block.timestamp + dt;
        while (block.timestamp < end) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
        }
        _postDepth();
    }

    /// Republish at `p` on the keeper's tick until `id` can actually be seized, and return how long
    /// that took. `type(uint256).max` when it never opens inside the horizon.
    function _secondsToLiquidatable(uint256 id, int256 p) internal returns (uint256) {
        uint256 opened = block.timestamp;
        for (uint256 i = 0; i < 300; i++) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
            _reprice(p);
            markets.syncMultiplier(AAPL);
            _postDepth();
            uint256 owed = pool.debtOf(id);
            if (
                markets.canLiquidate(AAPL) && markets.isUnderwater(AAPL, _coll(), owed)
                    && markets.isUnderwaterCorroborated(AAPL, _coll(), owed)
            ) return block.timestamp - opened;
        }
        return type(uint256).max;
    }

    /// A position past the liquidation bar, with the whole delay line holding the price that put it
    /// there — so it is seizable at this instant, before any outage.
    function _pastTheBar() internal returns (uint256 id, int256 p) {
        (id, p) = _seasonedPosition();
        p = (p * 85) / 100; // a fourth sub-bound step: still inside MAX_PRICE_DEVIATION_BPS
        _reprice(p);
        markets.syncMultiplier(AAPL);
        _hold(p, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());

        uint256 owed = pool.debtOf(id);
        assertTrue(markets.isUnderwater(AAPL, _coll(), owed), "past the bar at the live price");
        assertTrue(markets.isUnderwaterCorroborated(AAPL, _coll(), owed), "and at the corroborated one");
        assertTrue(markets.canLiquidate(AAPL), "seizable right now");
    }
}

/// MED-1. The delay line ages on wall time, so a feed outage does not reset the delay a position has
/// already served — and does not shorten the delay a move that landed DURING the outage still owes.
contract GLendR5WeekendBlackout is GLendR5Base {
    function setUp() public {
        _setUpFork();
    }

    /// The finding, inverted. RED against the pre-fix tree at 21,900s.
    function test_aPositionAlreadyPastTheBarIsSeizedWhenTheFeedReturns() public {
        (uint256 id, int256 friday) = _pastTheBar();

        _freeze(friday);
        _weekend(55 hours);
        assertFalse(markets.canLiquidate(AAPL), "an unreadable price refuses for as long as it lasts");
        (, bool okDuring) = markets.corroboratedValue(AAPL, _coll());

        // MONDAY. The feed publishes again at the price the position was already underwater at.
        // Measured BEFORE the assertions so a red run still reports the number it is red by.
        uint256 seconds_ = _secondsToLiquidatable(id, friday);
        console.log("seconds from feed-return to liquidatable:", seconds_);
        assertLe(seconds_, GAP, "seized on the first ticks back, not after a fresh six hours");
        assertTrue(okDuring, "and the line kept ageing through the outage: Friday's pair still stands");

        uint256 owed = pool.debtOf(id);
        vm.prank(liquidator);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0, "and the seizure actually lands");
        assertGt(owed, 0, "on a real debt");
    }

    /// The other direction, and the one that must not have been bought with the fix: a move that
    /// lands while the feed is dark still serves the FULL delay, because the read slot holds
    /// Friday's healthy price until four Monday observations have aged into it.
    function test_aGapThatLandedDuringTheOutageStillServesTheFullDelay() public {
        (uint256 id, int256 friday) = _seasonedPosition();
        _hold(friday, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        assertFalse(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "healthy on Friday");

        _freeze(friday);
        _weekend(55 hours);

        int256 monday = (friday * 40) / 100; // unambiguously underwater, not on the threshold
        uint256 seconds_ = _secondsToLiquidatable(id, monday);
        console.log("seconds from a weekend GAP to liquidatable:", seconds_);
        assertGe(seconds_, markets.PRICE_CONFIRM_DELAY(), "a fresh move pays the delay in full");
        // R6 LOW-3: `_secondsToLiquidatable` answers type(uint256).max when it never opens, which
        // satisfies the floor above. A mutant that broke corroboration on EVERY market passed this
        // test reporting a 2^256-1 second wait. The delay is a floor AND a ceiling.
        assertLe(
            seconds_,
            markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP(),
            "and it does open, within one ceiling of the delay"
        );
    }

    /// R4 HIGH-2 survives it, for a keeper that stops and never returns: the line ages only when
    /// someone CALLS, so a market nobody observes runs past the ceiling and refuses — a dead feed is
    /// not a dead keeper. That is HALF the property. An INTERMITTENT keeper is R6 MED-1, and lives in
    /// GLendR6ObservationGap, because this test cannot see it — nobody calls here, so nothing warms.
    function test_anUnobservedMarketStillFailsClosedWhileTheFeedIsDead() public {
        _hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        (, bool okBefore) = markets.corroboratedValue(AAPL, _coll());
        assertTrue(okBefore, "corroborated while observed");

        _freeze(realPrice);
        _weekendQuiet(55 hours);

        (, bool okAfter) = markets.corroboratedValue(AAPL, _coll());
        assertFalse(okAfter, "nobody observed: the line aged past MAX_CONFIRM_AGE and refuses");
        assertGt(block.timestamp - markets.confirmedObservedAt(AAPL), markets.MAX_CONFIRM_AGE());
    }

    /// The warmed observation is the last MATCHED pair, not a fresh read of either half. R4 MED-1 was
    /// the two halves coming apart across exactly this window — an issuer applying a split while the
    /// feed is dark — and warming the line must not reintroduce it.
    function test_theWarmedObservationStaysAMatchedPair() public {
        uint256 m0 = IScaledUI(AAPL).uiMultiplier();
        _hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        uint256 price0 = markets.confirmedPrice(AAPL);
        assertGt(price0, 0, "a real observation before the outage");
        assertEq(markets.confirmedMultiplier(AAPL), m0, "matched before it");

        // The print stays fresh for `maxStaleness` after the close, so the feed only goes dark ~25h
        // in. The issuer's 1:2 reverse split lands AFTER that, which is the R4 MED-1 window exactly.
        _freeze(realPrice);
        _weekend(30 hours);
        assertFalse(markets.canLiquidate(AAPL), "the feed is genuinely unreadable before the split");
        vm.mockCall(AAPL, abi.encodeWithSelector(IScaledUI.uiMultiplier.selector), abi.encode(m0 / 2));
        _weekend(25 hours);

        assertEq(markets.confirmedPrice(AAPL), price0, "the price half never moved");
        assertEq(markets.confirmedMultiplier(AAPL), m0, "and neither did its partner");
        assertEq(markets.seenMultiplier(AAPL), m0, "R4 MED-1 holds through every warm push");
    }

    /// WHICH pre-outage pair keeps standing: the LAST one, not an older slot. Every test above holds
    /// one price across the whole pre-outage window, so the ring's five slots are identical and the
    /// distinction is invisible — a gap the mutation gate found (M31 survived until this existed).
    /// Warming from the read slot instead of the head rotates stale prices forward, and Monday would
    /// be judged against a price from six hours before the close.
    function test_theWarmedObservationIsTheLastKnownGoodPairNotAnOlderSlot() public {
        // Fill the five slots with five DIFFERENT prices, each step inside MAX_PRICE_DEVIATION_BPS
        // so nothing arms, one CONFIRM_STEP apart so each lands in its own slot.
        int256 p = realPrice;
        for (uint256 i = 0; i < 6; i++) {
            p = (p * 95) / 100;
            _hold(p, markets.CONFIRM_STEP());
        }
        uint256 lastGood = markets.seenPrice(AAPL);
        assertTrue(markets.confirmedPrice(AAPL) != lastGood, "the read slot is an OLDER price, as designed");

        // Go dark IMMEDIATELY. `_freeze` leaves the print readable for `maxStaleness`, and 25h of
        // real pushes at one price would make the ring uniform before any warm push happened — which
        // is exactly what hid this from the first version of this test.
        _neverReadable(p);
        _weekend(20 hours);

        // Sampled across SIX consecutive push positions, not one: warming from the read slot rotates
        // the five old prices forward intact, so a single sample agrees with the correct behaviour
        // once every five pushes by coincidence.
        for (uint256 i = 0; i < 6; i++) {
            _weekend(markets.CONFIRM_STEP() + 300);
            assertEq(markets.confirmedPrice(AAPL), lastGood, "every slot stands on the LAST readable pair");
        }
    }
}

/// M30's gap. A market listed while its feed is unreadable must not be seeded AT ALL: the warm push
/// has nothing to stand on, and a zero pair in the ring would give `corroboratedValue` a SECOND
/// reason to refuse — "price == 0" as well as "too young" — which is the shape the delay line was
/// rebuilt to remove, and which made the old promotion rule unpinnable for three rounds.
contract GLendR5FreshMarket is GLendR5Base {
    EsseyMarkets markets2;

    function setUp() public {
        _setUpFork();
        MarketHealthOracle health2 = new MarketHealthOracle(keeper, guardian, admin);
        markets2 = new EsseyMarkets(AggregatorV3Interface(address(0)), liveness, health2, admin, guardian, assetDec);
        vm.prank(admin);
        health2.wireMarkets(address(markets2));
        EsseyPool pool2 = new EsseyPool(
            IERC20(USDG), AAPL, markets2, 500, 750, 3000, 1000, address(0), treasury, 0,
            EsseyPool.Identity("Essey Pool Share 2", "aUSDG2", "Essey Note 2", "eNOTE2")
        );
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true,
            ltvBps: 5_000,
            liqThresholdBps: 7_500,
            liqBonusBps: 500,
            collateralDecimals: stockDec,
            cap: uint128(250_000 * (10 ** assetDec)),
            maxPositionBps: 2_000
        });
        uint8 feedDec = AggregatorV3Interface(AAPL_FEED).decimals();
        vm.prank(admin);
        markets2.proposeMarket(
            AAPL, AggregatorV3Interface(AAPL_FEED), 86_400, 90_000, feedDec, AAPL, address(pool2), m
        );
        _warpQuiet(markets2.PARAM_TIMELOCK() + 1);
        markets2.commitMarket(AAPL);
    }

    function test_aMarketWhoseFeedWasNeverReadableIsNotSeededAtAll() public {
        _neverReadable(realPrice);
        for (uint256 i = 0; i < 40; i++) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
            markets2.syncMultiplier(AAPL);
        }
        assertEq(markets2.confirmedObservedAt(AAPL), 0, "nothing was ever pushed");
        assertEq(markets2.confirmedPrice(AAPL), 0, "and no zero pair was seeded in its place");

        // The feed returns. The FIRST readable observation is what seeds, and it fills every slot
        // with itself, so the only reason the read can refuse from here is its AGE.
        vm.warp(block.timestamp + GAP / 3);
        _beat();
        _reprice(realPrice);
        markets2.syncMultiplier(AAPL);
        assertEq(markets2.confirmedPrice(AAPL), uint256(realPrice), "seeded whole, on the first readable one");
        assertEq(markets2.confirmedObservedAt(AAPL), block.timestamp, "every slot carries this instant");

        (, bool ok) = markets2.corroboratedValue(AAPL, _coll());
        assertFalse(ok, "and it refuses for being too YOUNG, the one reason that is pinned");
    }
}

/// LOW-1. `test_theValuationAndObservationReadsShareOneBudget` passed with MULTIPLIER_READ_GAS cut
/// from 200,000 to 5,000 — below what the deployed AAPL token needs, which would return 0 from every
/// read, revert BadMultiplierSource on every valuation, and stop every borrow and every liquidation
/// on every market. It asserted the revert BRANCH, which is identical whether the read failed from a
/// revert or from starvation. This pins the MAGNITUDE against the measured cost.
contract GLendR5ReadBudget is GLendR5Base {
    function setUp() public {
        _setUpFork();
    }

    function test_theReadBudgetCoversWhatTheDeployedTokenActuallyCosts() public {
        uint256 before = gasleft();
        (bool ok,) = AAPL.staticcall(abi.encodeWithSignature("uiMultiplier()"));
        uint256 used = before - gasleft();
        assertTrue(ok, "readable");
        console.log("AAPL uiMultiplier() gas:", used);
        console.log("MULTIPLIER_READ_GAS    :", markets.MULTIPLIER_READ_GAS());

        assertLt(used, markets.MULTIPLIER_READ_GAS(), "the budget must cover the real read");
        // Headroom, not just coverage: this is a beacon-upgradeable contract the protocol does not
        // own, so the budget has to survive the token getting more expensive without a redeploy.
        assertGt(markets.MULTIPLIER_READ_GAS(), used * 4, "and with room for the token to grow");
        // R6 INFO-1: pinned DOWNWARD only, and the unpinned direction is the vector the constant
        // exists for. Widened to 30,000,000 the cap stops being a cap — a staticcall is bounded by
        // 63/64 of the gas remaining — and the untrusted token gets to burn whatever it likes on
        // five entry points. A token that grows an order of magnitude is plausible; one costing
        // 1,900x a real read is a burn loop. The deployed 200,000 is 12.7x the measured cost.
        assertLt(markets.MULTIPLIER_READ_GAS(), used * 40, "and a cap that is still a cap");

        // And BOTH reads the budget is for still work end to end at it, which is the part a
        // revert-branch assertion cannot see: starve the budget and each returns 0 instead.
        (uint256 value,) = markets.collateralValue(AAPL, _coll());
        assertGt(value, 0, "valuation reads the multiplier through the same budget");
        markets.syncMultiplier(AAPL);
        assertEq(markets.seenMultiplier(AAPL), IScaledUI(AAPL).uiMultiplier(), "and so does the observation");
    }
}

/// INFO-2a, re-run rather than inherited. The standing hypothesis was that `uiMultiplier` accrues,
/// which would make borrowing unavailable on a rolling basis. It does not: it is a stored value the
/// issuer writes. Recorded here rather than in a scratch root so round 6 does not re-open it, and so
/// the claim in docs/MAINNET-CONFIG.md ("settled, stop carrying it") has something behind it.
contract GLendR5MultiplierDrift is GLendR5Base {
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("rh_mainnet"));
    }

    function test_theDeployedMultiplierIsNotDerivedFromEitherClock() public {
        uint256 aapl0 = IScaledUI(AAPL).uiMultiplier();
        uint256 nvda0 = IScaledUI(NVDA).uiMultiplier();
        console.log("AAPL uiMultiplier at fork:", aapl0);
        console.log("NVDA uiMultiplier at fork:", nvda0);
        assertGt(aapl0, 0, "readable");

        vm.warp(block.timestamp + 1 hours);
        assertEq(IScaledUI(AAPL).uiMultiplier(), aapl0, "+1h");
        vm.warp(block.timestamp + 30 days);
        assertEq(IScaledUI(AAPL).uiMultiplier(), aapl0, "+30d");
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 10_000_000);
        assertEq(IScaledUI(AAPL).uiMultiplier(), aapl0, "+1y and +10M blocks: neither clock moves it");
        assertEq(IScaledUI(NVDA).uiMultiplier(), nvda0, "and the same for NVDA");
    }

    /// `_scheduledEffectiveAt` branch (a) is inert on every listed market, and this is why: the
    /// deployed tokens answer `newUIMultiplier()` with ONE word, and the decode requires two.
    function test_theScheduledMultiplierReturnShapeKeepsBranchAInert() public view {
        (bool okA, bytes memory retA) = AAPL.staticcall(abi.encodeWithSignature("newUIMultiplier()"));
        (bool okN, bytes memory retN) = NVDA.staticcall(abi.encodeWithSignature("newUIMultiplier()"));
        assertTrue(okA && okN, "both answer");
        assertEq(retA.length, 32, "one word, not the two IScaledUI declares");
        assertEq(retN.length, 32, "on both tokens");
    }
}
