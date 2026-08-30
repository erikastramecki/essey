// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {EsseyPoolTest} from "./EsseyPool.t.sol";
import {PoolStub} from "./RiskModules.t.sol";

/// AD-2, spec §7. Inherits the seeded pool harness: hox holds effectiveCap 1_333_200e6
/// (4_000_000e6 × 3333bps) over a 1_000_000e6 Market.cap, so borrowCap = the static cap.
contract MarketHealthOracleTest is EsseyPoolTest {
    uint256 constant C_SEED = 1_333_200e6;
    uint256 constant STATIC_CAP = 1_000_000e6;

    function _post(uint128 d) internal {
        vm.prank(KEEPER);
        hox.postDepth(address(tok), d, uint64(block.number), "fork-swap-v1");
    }

    /// Time passes, liveness and price stay proven, but the depth keeper is SILENT.
    function _advanceNoPost(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); px.set(px.answer(), block.timestamp); _beat();
        }
        vm.warp(end); px.set(px.answer(), block.timestamp); _beat();
    }

    function _installResolverHere() internal returns (address R) {
        R = makeAddr("resolver");
        vm.prank(ADMIN);
        mk.proposeResolver(R);
        for (uint256 i = 0; i < 4; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // depth stays live through the timelock
        px.set(200e8, block.timestamp);
        vm.prank(ADMIN);
        mk.commitResolver();
        _beat(); _advanceLive(GRACE);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
        usdg.mint(R, 100_000e6);
        vm.prank(R);
        usdg.approve(address(pool), type(uint256).max);
    }

    // ---------------------------------------------------------------- harness + defaults

    function test_seededHarnessShape() public view {
        assertEq(hox.effectiveCap(address(tok)), C_SEED, "seeded oracle cap");
        assertEq(mk.borrowCap(address(tok)), STATIC_CAP, "min() picks the static cap");
        assertEq(hox.capFractionBps(), 3_333);
        assertEq(hox.hysteresisBps(), 1_000);
        assertEq(hox.maxRaisePerDayBps(), 1_000);
        assertEq(hox.v4DiscountBps(), 5_000);
        assertEq(hox.raiseDelay(), 2 days);
        assertEq(hox.MAX_READING_AGE(), 24 hours);
    }

    // ---------------------------------------------------------------- §7.2 fresh deploy closed

    /// A wired stack whose oracle has never been posted to: the from-zero states start here.
    function _freshStack() internal returns (MarketHealthOracle hox2, EsseyMarkets mk2) {
        hox2 = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        mk2 = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox2, ADMIN, GUARDIAN, 6);
        vm.prank(ADMIN);
        hox2.wireMarkets(address(mk2));
        PoolStub stub2 = new PoolStub(address(tok), address(mk2));
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
        vm.prank(ADMIN);
        mk2.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub2), m);
        _advanceLive(2 days);
        mk2.commitMarket(address(tok));
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    function _post2(MarketHealthOracle h, uint128 d) internal {
        vm.prank(KEEPER);
        h.postDepth(address(tok), d, uint64(block.number), "fork-swap-v1");
    }

    function test_freshDeployStartsClosedEndToEnd() public {
        (MarketHealthOracle hox2, EsseyMarkets mk2) = _freshStack();
        assertEq(hox2.effectiveCap(address(tok)), 0, "no seeding");

        // every other gate is green (mk shares liv/px and IS borrowable); only depth is missing
        assertTrue(mk.canBorrow(address(tok)), "control: the seeded registry is open");
        assertEq(mk2.borrowCap(address(tok)), 0);
        assertFalse(mk2.canBorrow(address(tok)), "fresh stack must be closed");

        vm.prank(KEEPER);
        hox2.postDepth(address(tok), SEED_DEPTH, uint64(block.number), "fork-swap-v1");
        assertFalse(mk2.canBorrow(address(tok)), "a post alone must not open it before raiseDelay");
    }

    // ---------------------------------------------------------------- §7.1 silence fails closed

    function test_staleReadingZeroesTheCapAtExactly24hPlusOne() public {
        _advanceNoPost(hox.MAX_READING_AGE());
        assertEq(hox.effectiveCap(address(tok)), C_SEED, "age == MAX_READING_AGE is still fresh");
        vm.warp(block.timestamp + 1);
        assertEq(hox.effectiveCap(address(tok)), 0, "one second past: zero, never last-known-good");
    }

    function test_silenceBlocksNewBorrowsButEveryExitStaysOpen() public {
        _installResolverHere();
        vm.startPrank(ALICE);
        uint256 idRepay = pool.borrow(10e18, 700e6);
        uint256 idLiq = pool.borrow(10e18, 700e6);
        uint256 idWoff = pool.borrow(10e18, 700e6);
        vm.stopPrank();

        _advanceNoPost(25 hours);
        assertEq(hox.effectiveCap(address(tok)), 0);
        assertFalse(mk.canBorrow(address(tok)));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrow(10e18, 100e6);

        vm.startPrank(ALICE);
        pool.repayPartial(idRepay, 100e6);
        pool.addCollateral(idRepay, 1e18);
        pool.repay(idRepay, 700e6);
        vm.stopPrank();

        px.set(30e8, block.timestamp); // $300 collateral vs $700 debt
        assertTrue(mk.canLiquidate(address(tok)), "liquidation never consults depth");
        vm.prank(LIQUIDATOR);
        pool.liquidate(idLiq);

        px.set(5e8, block.timestamp); // $50 collateral vs $700 debt: beyond recovery
        vm.prank(makeAddr("resolver"));
        pool.writeOff(idWoff, 60e6);
        assertEq(pool.debtOf(idWoff), 0, "written off at cap 0");
    }

    function testFuzz_capZeroNeverBlocksAnExit(uint256 part, uint256 add, bool viaSilence) public {
        uint256 id = _borrow(700e6);
        if (viaSilence) _advanceNoPost(25 hours);
        else _post(0);
        assertEq(hox.effectiveCap(address(tok)), 0);

        part = bound(part, 1, 400e6);
        add = bound(add, 1, 5e18); // debt stays >= 300e6 vs <= $75 collateral at the $5 crash
        tok.mint(ALICE, add);
        vm.startPrank(ALICE);
        pool.repayPartial(id, part);
        pool.addCollateral(id, add);
        vm.stopPrank();

        px.set(5e8, block.timestamp);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0);
    }

    function testFuzz_capZeroNeverBlocksWriteOff(uint256 recovered, bool viaSilence) public {
        address R = _installResolverHere();
        uint256 id = _borrow(700e6);
        if (viaSilence) _advanceNoPost(25 hours);
        else _post(0);
        assertEq(hox.effectiveCap(address(tok)), 0);

        tok.adminBurn(address(pool), tok.balanceOf(address(pool))); // wiped cohort: no price needed
        recovered = bound(recovered, 0, pool.debtOf(id));
        vm.prank(R);
        pool.writeOff(id, recovered);
        assertEq(pool.debtOf(id), 0);
    }

    /// §5 blast radius: a deflated (or zeroed) post blocks NEW borrows only — it must never
    /// flip a healthy position into liquidatable territory. The oracle has zero seizure authority.
    function test_spoofDownIsNotALiquidationLever() public {
        uint256 id = _borrow(700e6); // $2000 collateral vs $700 debt: comfortably healthy
        _post(0);
        assertEq(hox.effectiveCap(address(tok)), 0);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.PositionHealthy.selector);
        pool.liquidate(id);
        assertFalse(mk.isUnderwater(address(tok), 10e18, pool.debtOf(id)));
    }

    // ---------------------------------------------------------------- §7.3 spike cannot raise

    function test_spikeLeavesTheCapUnchangedUntilRaiseDelayThenSlews() public {
        uint128 spike = 40_000_000e6; // target 13_332_000e6, 10x the current cap
        _post(spike);
        assertEq(hox.effectiveCap(address(tok)), C_SEED, "no same-block raise");
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + 6 hours);
            assertEq(hox.effectiveCap(address(tok)), C_SEED, "unchanged through raiseDelay");
            _post(spike);
        }
        // 48h in: matured this very second, ramp gain still zero
        assertEq(hox.effectiveCap(address(tok)), C_SEED);
        vm.warp(block.timestamp + 1 days);
        uint256 dayOne = (C_SEED * 11_000) / 10_000;
        assertEq(hox.effectiveCap(address(tok)), dayOne, "exactly +10% after one day");
        _post(spike);
        assertEq(hox.effectiveCap(address(tok)), dayOne, "a post crystallizes the ramp, never jumps to target");
        vm.warp(block.timestamp + 1 days);
        assertEq(hox.effectiveCap(address(tok)), (C_SEED * 12_000) / 10_000, "day two: still 10%/day of the ARM-time base");
    }

    function test_anyLowerPostCancelsAnArmedRaise() public {
        uint128 spike = 40_000_000e6;
        _post(spike);
        assertGt(hox.capState(address(tok)).pendingRaiseAt, 0, "armed");
        vm.warp(block.timestamp + 1 days);
        _post(spike);
        vm.warp(block.timestamp + 1 days);
        _post(SEED_DEPTH); // honest reading returns: lower than the pending target
        assertEq(hox.capState(address(tok)).pendingRaiseAt, 0, "cancelled");
        assertEq(hox.capState(address(tok)).pendingRaiseTo, 0);
        vm.warp(block.timestamp + 1 days);
        _post(SEED_DEPTH);
        assertEq(hox.effectiveCap(address(tok)), C_SEED, "the spike bought nothing");
    }

    /// §7.3 slew + §7.4 ceiling, fuzzed over posting sequences. The bound is stated independently
    /// of _ramped's internals — the old form restated the from-zero base formula and so validated
    /// the buggy code against itself: the POOL-FACING cap may never rise faster than
    /// maxRaisePerDayBps of the static cap per day, from any state, including from zero. Steps may
    /// exceed MAX_READING_AGE: across a staleness gap the resume post must land inside the same
    /// bound measured from the resume — silence is never credit.
    function testFuzz_slewAndCeilingHoldOverAnyPostingSequence(uint128[8] memory depths, uint256[8] memory dts) public {
        for (uint256 i = 0; i < 8; i++) {
            uint128 d = uint128(bound(depths[i], 0, 100_000_000e6));
            uint256 dt = bound(dts[i], 1, 3 days);

            uint256 before_ = mk.borrowCap(address(tok));
            _post(d);
            assertLe(mk.borrowCap(address(tok)), before_, "a post may only lower, never raise");

            uint256 c0 = mk.borrowCap(address(tok));
            vm.warp(block.timestamp + dt);
            uint256 c1 = mk.borrowCap(address(tok));
            assertLe(c1, c0 + (STATIC_CAP * 1_000 * dt) / (1 days * 10_000) + 1, "slew bound: never faster than maxRaisePerDayBps of the static cap");
            assertLe(c1, STATIC_CAP, "Market.cap is the ceiling");
        }

        // then restart from zero and march an extreme raise through maturity under the same bound:
        // random <=12h steps rarely outlive raiseDelay, and exact zero (target 0) is unreachable
        // from fuzzed depths — yet from-zero is precisely where the unclamped base broke
        _post(0);
        _post(100_000_000e6);
        for (uint256 i = 0; i < 10; i++) {
            uint256 c0 = mk.borrowCap(address(tok));
            vm.warp(block.timestamp + 12 hours);
            uint256 c1 = mk.borrowCap(address(tok));
            assertLe(c1, c0 + (STATIC_CAP * 1_000 * 12 hours) / (1 days * 10_000) + 1, "from-zero slew bound");
            assertLe(c1, STATIC_CAP, "Market.cap is the ceiling");
            _post(100_000_000e6);
        }
    }

    // ---------------------------------------------------------------- from-zero bootstrap clamp

    /// The auditor's PoC, inverted: a compromised keeper posts ~133x the static cap into an empty
    /// market. Unclamped, borrowCap swept 0 -> Market.cap ~2.4h after the delay; clamped, the
    /// same sweep must serve the full BPS/maxRaisePerDayBps (~10) days, however large the target.
    function test_absurdBootstrapTargetStillTakesTenDaysToTheStaticCap() public {
        (MarketHealthOracle hox2, EsseyMarkets mk2) = _freshStack();
        uint128 absurd = 400_000_000e6; // target 133_320_000e6 vs the 1_000_000e6 static cap
        _post2(hox2, absurd);
        uint256 t0 = block.timestamp;
        uint256 maturity = t0 + hox2.raiseDelay();
        vm.warp(t0 + 23 hours); _post2(hox2, absurd); // hold the reading fresh through the delay
        vm.warp(t0 + 46 hours); _post2(hox2, absurd);

        vm.warp(maturity);
        assertEq(mk2.borrowCap(address(tok)), 0, "maturity instant: ramp gain is zero");
        vm.warp(maturity + 8_640); // 2.4h: where the unclamped ramp had already crossed static
        assertEq(mk2.borrowCap(address(tok)), 10_000e6, "2.4h in: 1% of the static cap, not 100%");
        vm.warp(maturity + 22 hours); _post2(hox2, absurd);
        vm.warp(maturity + 1 days);
        assertLt(mk2.borrowCap(address(tok)), 100_000e6 + 1, "one day past maturity: <= 10% of static");

        // ride the ramp with 12h keeper posts until the pool-facing cap reaches the ceiling
        uint256 reachedAt;
        for (uint256 i = 0; i < 120; i++) {
            vm.warp(block.timestamp + 12 hours);
            if (mk2.borrowCap(address(tok)) >= STATIC_CAP) { reachedAt = block.timestamp; break; }
            _post2(hox2, absurd);
        }
        assertGt(reachedAt, 0, "must reach the static cap inside the 60-day horizon");
        assertGe(reachedAt - maturity, 10 days, "from-zero to static: never under BPS/maxRaisePerDayBps days");
    }

    /// Honest bootstrap is SUSTAINED posting, not one post and a silent warp (the old shape
    /// blessed the stale-resume bug). On a 12h cadence the arm-time base makes the schedule
    /// exact: raiseDelay + BPS/maxRaisePerDayBps ramp days, no crystallize-and-re-base crawl.
    function test_honestBootstrapStillReachesItsTargetAfterTheFullRamp() public {
        (MarketHealthOracle hox2, EsseyMarkets mk2) = _freshStack();
        uint128 honest = 2_400_000e6; // target 799_920e6, under the static cap: the clamp is inert
        _post2(hox2, honest);
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 23; i++) { vm.warp(block.timestamp + 12 hours); _post2(hox2, honest); }
        assertEq(hox2.effectiveCap(address(tok)), 799_920e6 - 39_996e6, "one 12h step short: 95% of target");
        vm.warp(block.timestamp + 12 hours);
        assertEq(block.timestamp, t0 + 12 days, "raiseDelay 2d + 10 ramp days");
        assertEq(hox2.effectiveCap(address(tok)), 799_920e6, "the full target, on the nominal schedule");
        assertEq(mk2.borrowCap(address(tok)), 799_920e6, "pool-facing: the honest target");
    }

    /// The crawl fix, pool-facing: from zero on a 12h cadence, borrowCap reaches the static cap
    /// at exactly raiseDelay + BPS/maxRaisePerDayBps days — not the ~25 the old re-based slew took.
    function test_sustainedPostingOpensOnTheNominalSchedule() public {
        (MarketHealthOracle hox2, EsseyMarkets mk2) = _freshStack();
        _post2(hox2, SEED_DEPTH); // target 1_333_200e6: crosses the 1_000_000e6 static cap
        for (uint256 i = 0; i < 23; i++) { vm.warp(block.timestamp + 12 hours); _post2(hox2, SEED_DEPTH); }
        assertEq(mk2.borrowCap(address(tok)), 950_000e6, "9.5 ramp days in: 95% of static");
        vm.warp(block.timestamp + 12 hours); _post2(hox2, SEED_DEPTH);
        assertEq(mk2.borrowCap(address(tok)), STATIC_CAP, "static reached at raiseDelay + 10 days exactly");
        assertEq(hox2.effectiveCap(address(tok)), 1_000_000e6, "the oracle itself is mid-ramp toward 1_333_200e6");
    }

    // ---------------------------------------------------------------- staleness resets the ramp

    /// The auditor's stale-then-resume PoC, inverted: arm toward the static cap, go silent 12
    /// days, resume with ONE post. The blackout must crystallize nothing and the full schedule
    /// must restart from the resume.
    function test_blackoutResumePostEarnsNothingAndRestartsTheFullRamp() public {
        (MarketHealthOracle hox2, EsseyMarkets mk2) = _freshStack();
        _post2(hox2, SEED_DEPTH); // arms a raise to 1_333_200e6, effective 0
        vm.warp(block.timestamp + 12 days); // silence spans the old maturity + 10 ramp days
        assertEq(mk2.borrowCap(address(tok)), 0, "stale: 0");

        _post2(hox2, SEED_DEPTH); // the resume post
        uint256 resumeAt = block.timestamp;
        assertEq(hox2.effectiveCap(address(tok)), 0, "no blackout credit in the resume block");
        assertEq(hox2.capState(address(tok)).effective, 0, "ramp state reset");
        assertEq(hox2.capState(address(tok)).pendingRaiseAt, resumeAt + hox2.raiseDelay(), "re-armed through the FULL raiseDelay");

        uint256 reachedAt;
        for (uint256 i = 0; i < 60; i++) {
            vm.warp(block.timestamp + 12 hours);
            if (mk2.borrowCap(address(tok)) >= STATIC_CAP) { reachedAt = block.timestamp; break; }
            _post2(hox2, SEED_DEPTH);
        }
        assertEq(reachedAt, resumeAt + 12 days, "static only raiseDelay + 10 ramp days after the resume");
    }

    function test_resumeAfterSilenceClearsBothProgressAndTheArmedRaise() public {
        (MarketHealthOracle hox2,) = _freshStack();
        _post2(hox2, SEED_DEPTH);
        for (uint256 i = 0; i < 6; i++) { vm.warp(block.timestamp + 12 hours); _post2(hox2, SEED_DEPTH); }
        assertEq(hox2.capState(address(tok)).effective, 100_000e6, "one ramp day crystallized");

        vm.warp(block.timestamp + 24 hours + 1); // one second past MAX_READING_AGE
        _post2(hox2, SEED_DEPTH);
        assertEq(hox2.capState(address(tok)).effective, 0, "crystallized progress does not survive silence");
        assertEq(hox2.capState(address(tok)).pendingRaiseAt, block.timestamp + hox2.raiseDelay(), "old maturity discarded");
        assertEq(hox2.capState(address(tok)).pendingRaiseTo, 1_333_200e6);
    }

    /// The arm-time snapshot removes the view-time re-basing (round-2 accepted LOW): a static-cap
    /// raise committed mid-ramp must not change the rate of a raise armed before it.
    function test_staticCapRaiseMidRampDoesNotRebaseTheSlew() public {
        (MarketHealthOracle hox2, EsseyMarkets mk2) = _freshStack();
        _post2(hox2, SEED_DEPTH); // arm: base snapshots min(1_333_200e6 target, 1_000_000e6 static)
        for (uint256 i = 0; i < 8; i++) { vm.warp(block.timestamp + 12 hours); _post2(hox2, SEED_DEPTH); }
        assertEq(hox2.effectiveCap(address(tok)), 200_000e6, "two ramp days in");

        PoolStub stub3 = new PoolStub(address(tok), address(mk2));
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 2_000_000e6, maxPositionBps: 10_000
        });
        vm.prank(ADMIN);
        mk2.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub3), m);
        for (uint256 i = 0; i < 4; i++) { vm.warp(block.timestamp + 12 hours); _post2(hox2, SEED_DEPTH); }
        px.set(px.answer(), block.timestamp);
        mk2.commitMarket(address(tok));
        assertEq(mk2.marketCap(address(tok)), 2_000_000e6, "static cap doubled mid-ramp");

        vm.warp(block.timestamp + 12 hours);
        assertEq(hox2.effectiveCap(address(tok)), 450_000e6, "4.5 ramp days: still 10%/day of the ARM-time base");
    }

    function test_gapUpToMaxReadingAgeKeepsCrystallizedProgress() public {
        (MarketHealthOracle hox2,) = _freshStack();
        _post2(hox2, SEED_DEPTH);
        for (uint256 i = 0; i < 6; i++) { vm.warp(block.timestamp + 12 hours); _post2(hox2, SEED_DEPTH); }
        assertEq(hox2.capState(address(tok)).effective, 100_000e6);

        vm.warp(block.timestamp + 24 hours); // exactly MAX_READING_AGE: still fresh, no reset
        _post2(hox2, SEED_DEPTH);
        assertEq(hox2.capState(address(tok)).effective, 200_000e6, "the fresh-window day crystallizes; nothing resets");
    }

    function test_noisyPostsKeepCrystallizedBootstrapProgress() public {
        (MarketHealthOracle hox2,) = _freshStack();
        uint128 honest = 2_400_000e6; // target 799_920e6
        _post2(hox2, honest);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 23 hours); _post2(hox2, honest);
        vm.warp(t0 + 46 hours); _post2(hox2, honest);

        vm.warp(t0 + hox2.raiseDelay() + 12 hours);
        _post2(hox2, honest); // same-target mid-ramp post: crystallizes, never resets
        assertEq(hox2.capState(address(tok)).effective, 39_996e6, "12h in: 5% of the target, stored");
        vm.warp(block.timestamp + 12 hours);
        assertEq(hox2.effectiveCap(address(tok)), 79_992e6, "ramp continues at the arm-time rate, not re-based");

        _post2(hox2, 1_500_000e6); // lower target: cancels the pending raise, re-arms at 499_950e6
        assertEq(hox2.capState(address(tok)).pendingRaiseTo, 499_950e6, "re-armed at the lower target");
        assertEq(hox2.capState(address(tok)).effective, 79_992e6, "crystallized progress survives the cancel");
    }

    function test_wireMarketsIsOneShotAndUnwiredFailsClosed() public {
        MarketHealthOracle bare = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        uint128 absurd = 400_000_000e6;
        _post2(bare, absurd);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 23 hours); _post2(bare, absurd);
        vm.warp(t0 + 46 hours); _post2(bare, absurd);

        vm.warp(t0 + 2 days + 12 hours); // matured 12h ago, reading still fresh
        assertEq(bare.effectiveCap(address(tok)), 0, "unwired: the from-zero base is 0");

        vm.prank(ALICE);
        vm.expectRevert(MarketHealthOracle.NotAdmin.selector);
        bare.wireMarkets(address(mk));
        vm.prank(ADMIN);
        vm.expectRevert(MarketHealthOracle.ZeroAddress.selector);
        bare.wireMarkets(address(0));

        vm.prank(ADMIN);
        bare.wireMarkets(address(mk));
        assertEq(address(bare.markets()), address(mk));
        assertEq(bare.effectiveCap(address(tok)), 0, "late wiring earns no retroactive ramp credit");
        vm.warp(block.timestamp + 8_640); // 2.4h from the wire
        assertEq(bare.effectiveCap(address(tok)), 10_000e6, "and ramps at the clamped rate from the wire");

        vm.prank(ADMIN);
        vm.expectRevert(MarketHealthOracle.AlreadyWired.selector);
        bare.wireMarkets(address(mk));

        // an unwired oracle's posts crystallize nothing either — postDepth shares _ramped
        MarketHealthOracle bare2 = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        _post2(bare2, absurd);
        uint256 t1 = block.timestamp;
        vm.warp(t1 + 23 hours); _post2(bare2, absurd);
        vm.warp(t1 + 46 hours); _post2(bare2, absurd);
        vm.warp(t1 + 2 days + 12 hours);
        _post2(bare2, absurd);
        assertEq(bare2.capState(address(tok)).effective, 0, "unwired: nothing crystallizes");
    }

    // ---------------------------------------------------------------- §7.5 ratchet down

    function test_ratchetDownIsSameBlock() public {
        _post(2_000_000e6); // target 666_600e6
        assertEq(hox.effectiveCap(address(tok)), 666_600e6, "down bites in the posting block");
        assertEq(mk.borrowCap(address(tok)), 666_600e6, "and the pool cap follows");
        _post(0);
        assertEq(hox.effectiveCap(address(tok)), 0, "post-0 closes the market same block");
        assertFalse(mk.canBorrow(address(tok)));
    }

    // ---------------------------------------------------------------- §7.6 hysteresis

    function test_hysteresisIgnoresSmallMovesBothDirections() public {
        _post(3_000_000e6); // target 999_900e6: beyond the band, ratchets down
        uint256 c0 = 999_900e6;
        assertEq(hox.effectiveCap(address(tok)), c0);

        _post(2_700_000e6); // target 899_910e6: down by exactly the 10% band — ignored
        assertEq(hox.effectiveCap(address(tok)), c0, "within-band drop ignored");
        _post(2_600_000e6); // target 866_580e6: beyond the band — applied
        assertEq(hox.effectiveCap(address(tok)), 866_580e6, "beyond-band drop applied");

        _post(2_860_000e6); // target 953_238e6: up by exactly the 10% band — ignored
        assertEq(hox.capState(address(tok)).pendingRaiseAt, 0, "within-band rise arms nothing");
        assertEq(hox.effectiveCap(address(tok)), 866_580e6);
        _post(2_900_000e6); // target 966_570e6: beyond the band — arms
        assertEq(hox.capState(address(tok)).pendingRaiseTo, 966_570e6, "beyond-band rise arms");
        assertEq(hox.effectiveCap(address(tok)), 866_580e6, "but does not move the cap yet");
    }

    // ---------------------------------------------------------------- §7.7 positions untouched

    function test_capCrashNeverTouchesExistingPositions() public {
        address R = _installResolverHere();
        vm.startPrank(ALICE);
        uint256 idRepay = pool.borrow(10e18, 700e6);
        uint256 idLiq = pool.borrow(10e18, 700e6);
        uint256 idWoff = pool.borrow(10e18, 700e6);
        vm.stopPrank();

        _post(0); // measured depth collapses: cap 0, same block
        assertEq(mk.borrowCap(address(tok)), 0);
        assertEq(pool.debtOf(idRepay), 700e6, "debt untouched by the crash");
        assertEq(pool.marketBorrows(address(tok)), 2_100e6, "exposure ledger untouched");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrow(10e18, 1e6);

        vm.startPrank(ALICE);
        pool.repayPartial(idRepay, 100e6);
        pool.addCollateral(idRepay, 1e18);
        pool.repay(idRepay, 700e6);
        vm.stopPrank();

        px.set(30e8, block.timestamp);
        vm.prank(LIQUIDATOR);
        pool.liquidate(idLiq);

        px.set(5e8, block.timestamp);
        vm.prank(R);
        pool.writeOff(idWoff, 60e6);
        assertEq(pool.marketBorrows(address(tok)), 0, "full lifecycle closed out at cap 0");
    }

    // ---------------------------------------------------------------- §7.8 canBorrow <-> pool

    function test_canBorrowAgreesWithThePoolAtCapZero() public {
        assertTrue(mk.canBorrow(address(tok)));
        uint256 id = _borrow(700e6); // open while it says open
        assertGt(id, 0);

        _post(0);
        assertFalse(mk.canBorrow(address(tok)), "cap 0 must be advertised");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrow(10e18, 100e6);
    }

    // ---------------------------------------------------------------- §7.4 min() both directions

    function test_borrowCapIsTheMinOfStaticAndOracle() public {
        assertEq(mk.borrowCap(address(tok)), STATIC_CAP, "oracle above static: static wins");
        _post(1_500_000e6); // target 499_950e6, below static
        assertEq(mk.borrowCap(address(tok)), 499_950e6, "oracle below static: oracle wins");
    }

    function test_poolEnforcesTheOracleCapNotJustTheStaticOne() public {
        _post(90_000e6); // target 29_997e6
        vm.startPrank(ALICE);
        pool.borrow(500e18, 29_000e6);
        pool.borrow(100e18, 997e6); // exactly at the oracle cap: allowed
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsMarketCap.selector, 29_998e6, 29_997e6));
        pool.borrow(100e18, 1e6);
        vm.stopPrank();
    }

    function test_positionLimitFloatsWithTheLiveCap() public {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 2_000
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), m);
        for (uint256 i = 0; i < 4; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // depth stays live through the timelock
        px.set(px.answer(), block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);

        _post(100_000e6); // live cap 33_330e6 -> per-position limit 6_666e6, NOT 200_000e6
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsPositionCap.selector, 6_667e6, 6_666e6));
        pool.borrow(500e18, 6_667e6);
        pool.borrow(500e18, 6_666e6); // exactly at the floating limit: allowed
        pool.borrow(500e18, 6_666e6); // the limit is PER POSITION, not cumulative
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- roles

    function test_postDepthIsKeeperOnly() public {
        vm.prank(ALICE);
        vm.expectRevert(MarketHealthOracle.NotKeeper.selector);
        hox.postDepth(address(tok), 1e6, 1, "x");
    }

    function test_guardianRotatesTheKeeper() public {
        address newKeeper = makeAddr("new-keeper");
        vm.prank(ADMIN);
        vm.expectRevert(MarketHealthOracle.NotGuardian.selector);
        hox.setKeeper(newKeeper);
        vm.prank(GUARDIAN);
        vm.expectRevert(MarketHealthOracle.ZeroAddress.selector);
        hox.setKeeper(address(0));
        vm.prank(GUARDIAN);
        hox.setKeeper(newKeeper);
        vm.prank(KEEPER);
        vm.expectRevert(MarketHealthOracle.NotKeeper.selector);
        hox.postDepth(address(tok), 1e6, 1, "x");
        vm.prank(newKeeper);
        hox.postDepth(address(tok), SEED_DEPTH, uint64(block.number), "fork-swap-v1");
        (, uint64 postedAt,) = hox.readings(address(tok));
        assertEq(postedAt, block.timestamp);
    }

    function test_everyPostLogsTheMethodologyTag() public {
        vm.expectEmit(true, false, false, true, address(hox));
        emit MarketHealthOracle.DepthPosted(address(tok), SEED_DEPTH, uint64(block.number), "fork-swap-v1", uint256(C_SEED));
        _post(SEED_DEPTH);
    }

    // ---------------------------------------------------------------- params (timelocked)

    function _validParams() internal pure returns (MarketHealthOracle.Params memory) {
        return MarketHealthOracle.Params({
            capFractionBps: 3_333, hysteresisBps: 1_000, maxRaisePerDayBps: 1_000,
            v4DiscountBps: 5_000, raiseDelay: 2 days
        });
    }

    function test_paramChangeIsAdminProposedTimelockedAndPermissionlesslyCommitted() public {
        MarketHealthOracle.Params memory p = _validParams();
        p.capFractionBps = 2_000;
        vm.prank(ALICE);
        vm.expectRevert(MarketHealthOracle.NotAdmin.selector);
        hox.proposeParams(p);
        vm.prank(ADMIN);
        hox.proposeParams(p);
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.TimelockNotElapsed.selector, 2 days));
        hox.commitParams();
        for (uint256 i = 0; i < 4; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // depth stays live through the timelock
        vm.prank(makeAddr("stranger"));
        hox.commitParams();
        assertEq(hox.capFractionBps(), 2_000);
        _post(SEED_DEPTH); // 4_000_000e6 x 2_000bps = 800_000e6: the new fraction is live
        assertEq(hox.effectiveCap(address(tok)), 800_000e6);
    }

    function test_paramProposalCanBeCancelled() public {
        vm.prank(ADMIN);
        hox.proposeParams(_validParams());
        vm.prank(ALICE);
        vm.expectRevert(MarketHealthOracle.NotAdmin.selector);
        hox.cancelParamsProposal();
        vm.prank(ADMIN);
        hox.cancelParamsProposal();
        vm.warp(block.timestamp + hox.PARAM_TIMELOCK());
        vm.expectRevert(MarketHealthOracle.NoPendingChange.selector);
        hox.commitParams();
    }

    function test_paramBoundsAreValidatedAtPropose() public {
        MarketHealthOracle.Params memory p;
        vm.startPrank(ADMIN);
        p = _validParams(); p.capFractionBps = 0;
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.InvalidParams.selector, "cap fraction"));
        hox.proposeParams(p);
        p = _validParams(); p.capFractionBps = 5_001;
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.InvalidParams.selector, "cap fraction"));
        hox.proposeParams(p);
        p = _validParams(); p.hysteresisBps = 5_001;
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.InvalidParams.selector, "hysteresis"));
        hox.proposeParams(p);
        p = _validParams(); p.maxRaisePerDayBps = 0;
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.InvalidParams.selector, "raise slew"));
        hox.proposeParams(p);
        p = _validParams(); p.maxRaisePerDayBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.InvalidParams.selector, "raise slew"));
        hox.proposeParams(p);
        p = _validParams(); p.v4DiscountBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.InvalidParams.selector, "v4 discount"));
        hox.proposeParams(p);
        p = _validParams(); p.raiseDelay = 1 days - 1;
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.InvalidParams.selector, "raise delay"));
        hox.proposeParams(p);
        p = _validParams(); p.raiseDelay = 30 days + 1;
        vm.expectRevert(abi.encodeWithSelector(MarketHealthOracle.InvalidParams.selector, "raise delay"));
        hox.proposeParams(p);

        // the exact boundary values are all legal
        p = _validParams();
        p.capFractionBps = 5_000; p.hysteresisBps = 5_000; p.maxRaisePerDayBps = 10_000;
        p.v4DiscountBps = 10_000; p.raiseDelay = 30 days;
        hox.proposeParams(p);
        p.capFractionBps = 1; p.hysteresisBps = 0; p.maxRaisePerDayBps = 1;
        p.v4DiscountBps = 0; p.raiseDelay = 1 days;
        hox.proposeParams(p);
        hox.cancelParamsProposal();
        vm.stopPrank();
    }
}
