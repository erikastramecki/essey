// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {DeployMarkets, RateModes} from "../script/DeployMarkets.s.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {InkFeeds} from "../src/InkFeeds.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MockUSDG} from "./EsseyPool.t.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {RobinhoodFeeds} from "../src/RobinhoodFeeds.sol";

/// `require` in an internal library function needs an external frame for expectRevert to catch.
contract RateModesCaller {
    function curve(RateModes.Mode mode, uint256 policyRateBps) external pure returns (RateModes.Curve memory) {
        return RateModes.curve(mode, policyRateBps);
    }
}

/// WS1 config policy: the fixed-rate MODE, proven on the real pool the deploy script would
/// construct — no market ships fixed yet. Plus the deploy-profile table (chunk B) and the
/// one-pool-per-token cap hazard the rate-modes runbook cites.
contract RateModesTest is Test {
    uint256 constant POLICY_RATE_BPS = 800;
    uint256 constant KINK_BPS = 8_000; // EsseyPool.sol:108 — hardcoded, not a constructor param
    uint256 constant DEPOSIT = 10_000e6; // 1e6 units per utilization bp: borrow of u*1e6 == u bps

    EsseyPool pool;
    EsseyMarkets mk;
    LivenessOracle liv;
    MarketHealthOracle hox;
    MockFeed seq;
    MockFeed px;
    MockStock tok;
    MockUSDG usdg;

    address ADMIN;
    address KEEPER;
    address LENDER;
    address ALICE;

    uint256 constant MON_IN_SESSION = 1_753_110_000;

    function setUp() public {
        ADMIN = makeAddr("admin"); KEEPER = makeAddr("keeper");
        LENDER = makeAddr("lender"); ALICE = makeAddr("alice");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0); seq.setStartedAt(block.timestamp - 2 days);
        px = new MockFeed(200e8, 8);
        tok = new MockStock();
        usdg = new MockUSDG();
        liv = new LivenessOracle(KEEPER, ADMIN, 10 minutes, 30 minutes);
        hox = new MarketHealthOracle(KEEPER, ADMIN, ADMIN);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, ADMIN, 6);
        vm.prank(ADMIN);
        hox.wireMarkets(address(mk));
        pool = _fixedPool();

        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 5_000, liqThresholdBps: 7_500, liqBonusBps: 500,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        vm.stopPrank();
        _beat(); _advanceLive(30 minutes);
        _seedOracle();

        usdg.mint(LENDER, 10 * DEPOSIT);
        tok.mint(ALICE, 10_000e18);
        vm.startPrank(LENDER);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(DEPOSIT, LENDER);
        vm.stopPrank();
        vm.prank(ALICE);
        tok.approve(address(pool), type(uint256).max);
    }

    function _fixedPool() internal returns (EsseyPool) {
        RateModes.Curve memory c = RateModes.curve(RateModes.Mode.Fixed, POLICY_RATE_BPS);
        return new EsseyPool(
            usdg, address(tok), mk, c.baseBps, c.slope1Bps, c.slope2Bps, 1000, address(0), address(0x7EA), 0,
            EsseyPool.Identity("Essey Fixed Share", "aFIX", "Essey Fixed Note", "nFIX")
        );
    }

    function _beat() internal { vm.prank(KEEPER); liv.heartbeat(); }
    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); px.set(px.answer(), block.timestamp); _beat(); _postD();
        }
        vm.warp(end); px.set(px.answer(), block.timestamp); _beat(); _postD();
    }

    function _postD() internal {
        vm.prank(KEEPER); hox.postDepth(address(tok), 4_000_000e6, uint64(block.number), "fork-swap-v1");
    }


    /// List-time seeding for a token introduced mid-test: arm, ride the ramp on a live keeper
    /// cadence (a silent warp past MAX_READING_AGE resets it). 21 days covers the ~15.4-day
    /// clamped ramp and keeps the day-of-week.
    function _matureDepth(address token) internal {
        vm.prank(KEEPER); hox.postDepth(token, 4_000_000e6, uint64(block.number), "fork-swap-v1");
        for (uint256 i = 0; i < 42; i++) {
            vm.warp(block.timestamp + 12 hours);
            vm.prank(KEEPER); hox.postDepth(token, 4_000_000e6, uint64(block.number), "fork-swap-v1");
        }
        _beat(); _advanceLive(30 minutes);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    function _seedOracle() internal {
        _postD();
        for (uint256 i = 0; i < 42; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // ride the full ramp
        _beat(); _advanceLive(30 minutes);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    function _borrowTo(uint256 uBps, uint256 already) internal {
        vm.prank(ALICE);
        pool.borrow(1_000e18, (uBps * 1e6) - already);
    }

    // ------------------------------------------------- the curve on a real pool

    /// The fixed-mode promise itself: one flat rate at any utilization up to the kink. The
    /// mutation that must go red here is reintroducing a slope1 term into RateModes.
    function testFuzz_fixedRateConstantBelowKink(uint256 uBps) public {
        uBps = bound(uBps, 0, KINK_BPS);
        if (uBps > 0) _borrowTo(uBps, 0);
        assertEq(pool.utilizationBps(), uBps, "harness must hit the exact utilization");
        assertEq(pool.borrowRateBps(), POLICY_RATE_BPS, "fixed mode must not move below the kink");
    }

    /// Deterministic pin at 50% utilization, so a slope1 mutant dies even if the fuzzer draws
    /// only low-utilization samples in a fast run (slope1=500 would price this at 1050).
    function test_fixedRateAtHalfUtilizationIsExactlyPolicy() public {
        _borrowTo(4_000, 0);
        assertEq(pool.borrowRateBps(), POLICY_RATE_BPS);
    }

    function testFuzz_fixedRateRisesMonotonicallyAboveKink(uint256 a, uint256 b) public {
        uint256 u1 = bound(a, KINK_BPS + 1, 9_998);
        uint256 u2 = bound(b, u1 + 1, 9_999);
        _borrowTo(u1, 0);
        uint256 r1 = pool.borrowRateBps();
        _borrowTo(u2, u1 * 1e6);
        uint256 r2 = pool.borrowRateBps();
        assertGt(r1, POLICY_RATE_BPS, "emergency leg must engage above the kink");
        assertGt(r2, r1, "emergency leg must rise with utilization");
    }

    // ------------------------------------------------- the config policy itself

    /// Tydro shipped a zero-slope curve and sat at 87% utilization with no rate lever to pull
    /// liquidity back — depositors locked, nothing to do but watch. Fixed mode here therefore
    /// KEEPS slope2 as an emergency kink; this test is the tripwire that fails the suite if
    /// anyone ships s2 == 0 in fixed mode.
    function test_fixedModeNeverShipsWithoutTheEmergencyKink() public pure {
        RateModes.Curve memory c = RateModes.curve(RateModes.Mode.Fixed, POLICY_RATE_BPS);
        assertGt(c.slope2Bps, 0, "fixed mode with s2 == 0 is the Tydro 87%-util exposure");
        assertEq(c.slope1Bps, 0, "fixed means fixed: no slope below the kink");
        assertEq(c.baseBps, POLICY_RATE_BPS, "the policy rate IS the base");
    }

    /// Pins today's live listing curve so a profile refactor cannot drift it silently.
    function test_kinkModeIsTheDeployedCurve() public pure {
        RateModes.Curve memory c = RateModes.curve(RateModes.Mode.Kink, 0);
        assertEq(c.baseBps, 1_000);
        assertEq(c.slope1Bps, 500);
        assertEq(c.slope2Bps, 6_000);
    }

    function test_modeFieldConfusionReverts() public {
        RateModesCaller caller = new RateModesCaller();
        vm.expectRevert(bytes("policyRateBps is a Fixed-mode field"));
        caller.curve(RateModes.Mode.Kink, POLICY_RATE_BPS);
        vm.expectRevert(bytes("a Fixed listing needs a nonzero policy rate"));
        caller.curve(RateModes.Mode.Fixed, 0);
    }

    // ------------------------------------------------- deploy profiles (chunk B)

    function test_profileTable() public {
        DeployMarkets d = new DeployMarkets();

        DeployMarkets.Profile memory rh = d.profileFor(4_663);
        assertEq(rh.name, "RobinhoodMainnet");
        assertFalse(rh.testnet);
        assertTrue(rh.multiplierIsToken);
        assertEq(rh.heartbeat, RobinhoodFeeds.HEARTBEAT);
        assertEq(rh.maxStaleness, RobinhoodFeeds.RECOMMENDED_MAX_STALENESS);
        assertEq(rh.usdg, address(0), "mainnet USDG comes from env, never hardcoded");
        assertEq(rh.seqFeed, address(0), "no RH sequencer feed exists; deploy banners it loudly");

        DeployMarkets.Profile memory tn = d.profileFor(46_630);
        assertEq(tn.name, "RobinhoodTestnet");
        assertTrue(tn.testnet);
        assertTrue(tn.multiplierIsToken);

        DeployMarkets.Profile memory ink = d.profileFor(57_073);
        assertEq(ink.name, "Ink");
        assertFalse(ink.testnet, "TESTNET=1 must never validate against Ink");
        assertFalse(ink.multiplierIsToken, "Backed's 4626 wrapper lacks uiMultiplier - ConstantMultiplier");
        assertEq(ink.heartbeat, 3_600);
        assertEq(ink.maxStaleness, 7_200);
        assertEq(ink.usdg, InkFeeds.USDG);
        assertEq(ink.seqFeed, InkFeeds.SEQUENCER_UPTIME);
    }

    function test_unknownChainHasNoProfile() public {
        DeployMarkets d = new DeployMarkets();
        vm.expectRevert(bytes("no deploy profile for this chain id"));
        d.profileFor(1);
    }

    /// Same bound commitMarket enforces on-chain ([heartbeat, heartbeat+grace], StaleFeedGuard),
    /// asserted at CI time so a profile typo dies here and not mid-broadcast.
    function test_profileStalenessWithinFeedGuardBounds() public {
        DeployMarkets d = new DeployMarkets();
        uint256[3] memory chains = [uint256(4_663), 46_630, 57_073];
        for (uint256 i = 0; i < chains.length; i++) {
            DeployMarkets.Profile memory p = d.profileFor(chains[i]);
            assertGe(p.maxStaleness, p.heartbeat, p.name);
            assertLe(p.maxStaleness, p.heartbeat + mk.STALENESS_GRACE(), p.name);
        }
    }

    // ------------------------------------------------- the one-pool-per-token law, on chain

    /// THE CAP-DOUBLING HAZARD (F1, round 6), and the gate that killed it. Each pool checks its
    /// OWN marketBorrows (EsseyPool.sol:114) against the SHARED Market.cap, so before the
    /// activePool gate a second live pool on the same token doubled the effective market cap —
    /// the pre-fix shape of this test PROVED it (both pools filled the cap). Now only
    /// markets.activePool(token) may open new borrows: the second pool dies at the gate and the
    /// combined book cannot exceed the shared cap. The one-live-pool rule is contract law, not
    /// an operational law.
    function test_secondPoolOnSameTokenCannotDoubleTheEffectiveCap() public {
        MockStock tok2 = new MockStock();
        MockFeed px2 = new MockFeed(200e8, 8);
        EsseyPool a = _poolOn(address(tok2), "A");
        EsseyPool b = _poolOn(address(tok2), "B");
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 5_000, liqThresholdBps: 7_500, liqBonusBps: 500,
            collateralDecimals: 18, cap: 1_000e6, maxPositionBps: 10_000
        });
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok2), AggregatorV3Interface(address(px2)), 86_400, 90_000, 8, address(tok2), address(a), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px2.set(200e8, block.timestamp);
        mk.commitMarket(address(tok2));
        vm.stopPrank();
        px.set(200e8, block.timestamp);
        _beat(); _advanceLive(30 minutes);
        _matureDepth(address(tok2));
        px2.set(200e8, block.timestamp);

        usdg.mint(LENDER, 4_000e6);
        tok2.mint(ALICE, 100e18);
        vm.startPrank(LENDER);
        usdg.approve(address(a), type(uint256).max); a.deposit(2_000e6, LENDER);
        usdg.approve(address(b), type(uint256).max); b.deposit(2_000e6, LENDER);
        vm.stopPrank();

        vm.startPrank(ALICE);
        tok2.approve(address(a), type(uint256).max);
        tok2.approve(address(b), type(uint256).max);
        a.borrow(20e18, 1_000e6); // fills the whole 1_000e6 market cap on the ACTIVE pool
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsMarketCap.selector, 1_001e6, 1_000e6));
        a.borrow(20e18, 1e6); // pool A's accounting is correct in isolation
        assertTrue(mk.canBorrow(address(tok2)), "the market itself is open - only the pool identity gates");
        vm.expectRevert(EsseyPool.NotActivePool.selector);
        b.borrow(20e18, 1_000e6); // the pre-fix double-count dies at the gate
        vm.stopPrank();

        assertEq(a.marketBorrows(address(tok2)) + b.marketBorrows(address(tok2)), 1_000e6, "the shared cap binds");
    }

    function _poolOn(address token, string memory tag) internal returns (EsseyPool) {
        RateModes.Curve memory c = RateModes.curve(RateModes.Mode.Kink, 0);
        return new EsseyPool(
            usdg, token, mk, c.baseBps, c.slope1Bps, c.slope2Bps, 1000, address(0), address(0x7EA), 0,
            EsseyPool.Identity(tag, tag, tag, tag)
        );
    }
}
