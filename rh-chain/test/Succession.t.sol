// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MockFeed, MockStock, PoolStub} from "./RiskModules.t.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {MockUSDG} from "./EsseyPool.t.sol";
import {NoteArt} from "../src/market/NoteArt.sol";
import {PoolFactory} from "../src/market/PoolFactory.sol";

/// F1 (round 6, MEDIUM), inverted: the finding was that after a same-token pool succession the
/// RETIRED pool's borrow gate re-armed — any stranger could deposit into it and borrow, doubling
/// effective exposure against the shared Market.cap. This file proves the activePool mechanism
/// kills exactly that, and NOTHING else: every wind-down path on the superseded pool is pinned
/// OPEN (repay, repayPartial, addCollateral, liquidate, writeOff — the absence of gating is the
/// invariant, house style).
contract SuccessionTest is Test {
    EsseyMarkets mk;
    EsseyPool pool1;
    PoolFactory factory;
    LivenessOracle liv;
    MarketHealthOracle hox;
    MockFeed seq;
    MockFeed px;
    MockStock tok;
    MockUSDG usdg;

    address ADMIN;
    address KEEPER;
    address GUARDIAN;
    address RESOLVER;
    address LENDER;
    address ALICE;
    address STRANGER;
    address LIQUIDATOR;

    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant GRACE = 30 minutes;

    function setUp() public {
        ADMIN = makeAddr("admin"); KEEPER = makeAddr("keeper"); GUARDIAN = makeAddr("guardian");
        RESOLVER = makeAddr("resolver"); LENDER = makeAddr("lender");
        ALICE = makeAddr("alice"); STRANGER = makeAddr("stranger"); LIQUIDATOR = makeAddr("liquidator");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0); seq.setStartedAt(block.timestamp - 2 days);
        px = new MockFeed(200e8, 8);
        tok = new MockStock();
        usdg = new MockUSDG();
        liv = new LivenessOracle(KEEPER, GUARDIAN, makeAddr("livenessRotator"), 10 minutes, GRACE);
        hox = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, GUARDIAN, 6);
        vm.prank(ADMIN);
        hox.wireMarkets(address(mk));
        factory = new PoolFactory(mk);
        pool1 = _wiredPool();

        vm.startPrank(ADMIN);
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool1),
            _market(3_500, 5_500)
        );
        mk.proposeResolver(RESOLVER);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        mk.commitResolver();
        factory.register(address(tok), address(pool1));
        vm.stopPrank();
        _beat(); _advanceLive(GRACE);
        _seedOracle();

        usdg.mint(LENDER, 2_000_000e6);
        usdg.mint(ALICE, 100_000e6);
        usdg.mint(LIQUIDATOR, 100_000e6);
        usdg.mint(RESOLVER, 100_000e6);
        tok.mint(ALICE, 1_000e18);
        tok.mint(STRANGER, 100e18);
        vm.startPrank(LENDER);
        usdg.approve(address(pool1), type(uint256).max);
        pool1.deposit(500_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(pool1), type(uint256).max);
        usdg.approve(address(pool1), type(uint256).max);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        usdg.approve(address(pool1), type(uint256).max);
        vm.prank(RESOLVER);
        usdg.approve(address(pool1), type(uint256).max);
    }

    function _market(uint16 ltv, uint16 lt) internal pure returns (EsseyMarkets.Market memory) {
        return EsseyMarkets.Market({
            enabled: true, ltvBps: ltv, liqThresholdBps: lt, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
    }

    /// Zero-rate pool with art wired, the way the deploy script builds one.
    function _wiredPool() internal returns (EsseyPool p) {
        p = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0,
            EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        p.setNoteArt(address(new NoteArt(p, p.note())));
    }

    function _beat() internal { vm.prank(KEEPER); liv.heartbeat(); }

    /// Beats on the keeper's tick and OBSERVES every sixth one — R4 LOW-5: it used to beat only,
    /// so a fixture seasoning a price left the breaker's baseline stale and its deviation check
    /// silently skipped.
    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); px.set(px.answer(), block.timestamp); _beat(); _postD(); if (++_tick % 6 == 0) _observe();
        }
        vm.warp(end); px.set(px.answer(), block.timestamp); _beat(); _postD(); _observe();
    }

    uint256 private _tick;

    function _observe() internal { mk.syncMultiplier(address(tok)); }


    function _postD() internal {
        vm.prank(KEEPER); hox.postDepth(address(tok), 4_000_000e6, uint64(block.number), "fork-swap-v1");
    }

    function _seedOracle() internal {
        _postD();
        for (uint256 i = 0; i < 41; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // ride the full ramp
        _beat(); _advanceLive(GRACE);
        _fillDelayLine(12 hours - GRACE);
        _toSession();
    }
    /// R4 HIGH-1: a market has no corroborated price until the delay line has been observed for
    /// PRICE_CONFIRM_DELAY, so the fixture serves one out the way the deployed keeper would — as
    /// the 42nd step of the ramp above, keeping the elapsed time and the day-of-week it always had.
    function _fillDelayLine(uint256 secs) internal {
        require(secs >= mk.PRICE_CONFIRM_DELAY() + 2 * mk.CONFIRM_STEP(), "fixture: too short to fill");
        _advanceLive(secs);
    }

    function _toSession() internal {
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    /// The succession itself: same feed, same freshness pair, same multiplier source — only the
    /// pool (and, if wanted, risk params) change. Committed by a STRANGER: the flip needs no
    /// privilege once the timelock is served.
    function _succeed(EsseyPool p) internal {
        vm.prank(ADMIN);
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(p),
            _market(3_500, 5_500)
        );
        for (uint256 i = 0; i < 4; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // depth stays live through the timelock
        px.set(200e8, block.timestamp);
        vm.prank(STRANGER);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
        _toSession();
    }

    // ------------------------------------------------- the F1 PoC, inverted

    /// Full lifecycle: incumbent carries a live book; a successor commits; the incumbent's NEW
    /// borrows die in that block while every wind-down path stays open; the successor lends; the
    /// factory follows; nothing is stranded.
    function test_successionClosesTheRetiredPoolAndStrandsNothing() public {
        vm.startPrank(ALICE);
        uint256 id1 = pool1.borrow(10e18, 700e6); // repaid in full below
        uint256 id2 = pool1.borrow(10e18, 500e6); // serviced (partial + top-up), then closed
        uint256 id3 = pool1.borrow(10e18, 600e6); // liquidated below
        uint256 id4 = pool1.borrow(10e18, 600e6); // written off below
        vm.stopPrank();

        EsseyPool pool2 = _wiredPool();
        _succeed(pool2);
        assertEq(mk.activePool(address(tok)), address(pool2), "the commit flips the authority");

        // THE FINDING'S SHAPE: a stranger walks up to the retired pool, which still holds lender
        // cash, with an enabled market and an open session — and the gate refuses.
        assertTrue(mk.canBorrow(address(tok)), "market-level gate is open; only the pool identity closes");
        vm.startPrank(STRANGER);
        tok.approve(address(pool1), type(uint256).max);
        vm.expectRevert(EsseyPool.NotActivePool.selector);
        pool1.borrow(10e18, 100e6);
        vm.stopPrank();

        // The successor lends the same block.
        vm.startPrank(LENDER);
        usdg.approve(address(pool2), type(uint256).max);
        pool2.deposit(500_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(pool2), type(uint256).max);
        uint256 newId = pool2.borrow(10e18, 700e6);
        vm.stopPrank();
        assertEq(pool2.debtOf(newId), 700e6, "successor open for business");

        // Discovery follows the flip.
        vm.prank(ADMIN);
        factory.register(address(tok), address(pool2));
        assertEq(factory.poolFor(address(tok)), address(pool2), "registry mirrors the successor");

        // WIND-DOWN, each path pinned OPEN on the superseded pool:
        vm.startPrank(ALICE);
        pool1.repayPartial(id2, 100e6); // 500 -> 400
        assertEq(pool1.debtOf(id2), 400e6, "repayPartial survives succession");
        pool1.addCollateral(id2, 1e18);
        pool1.repay(id2, 400e6);
        assertEq(pool1.debtOf(id2), 0, "repay survives succession");
        pool1.repay(id1, 700e6);
        vm.stopPrank();

        _walkPriceAndSettle(80e8); // $800 backing $600 at a 55% threshold: id3 is underwater
        vm.prank(LIQUIDATOR);
        pool1.liquidate(id3);
        assertEq(pool1.debtOf(id3), 0, "liquidate survives succession");

        tok.adminBurn(address(pool1), tok.balanceOf(address(pool1))); // id4's backing is destroyed
        vm.prank(RESOLVER);
        pool1.writeOff(id4, 100e6);
        assertEq(pool1.debtOf(id4), 0, "writeOff survives succession");

        assertEq(pool1.totalBorrows(), 0, "the retired book wound down to zero");
        assertEq(pool1.marketBorrows(address(tok)), 0);
        assertEq(tok.balanceOf(address(pool1)), 0, "no collateral stranded in the retired pool");
    }

    /// The cap half of the finding: the retired pool cannot ADD to marketBorrows at all — even
    /// far below the shared cap — so the doubled-exposure path runs through no pool.
    function test_retiredPoolCannotGrowItsBookBelowTheCap() public {
        vm.prank(ALICE);
        pool1.borrow(10e18, 700e6);
        _succeed(_wiredPool());
        assertLt(pool1.marketBorrows(address(tok)), 1_000_000e6, "plenty of cap headroom");
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotActivePool.selector);
        pool1.borrow(10e18, 1e6);
    }

    // ------------------------------------------------- the binding checks, both ends

    function test_proposeRejectsAZeroPool() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.BadActivePool.selector, address(tok), address(0)));
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(0),
            _market(3_500, 5_500)
        );
    }

    function test_proposeRejectsAPoolServingAnotherToken() public {
        PoolStub wrong = new PoolStub(makeAddr("otherToken"), address(mk));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.BadActivePool.selector, address(tok), address(wrong)));
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(wrong),
            _market(3_500, 5_500)
        );
    }

    /// The cross-registry squat: a pool answering for a FOREIGN markets must never become this
    /// registry's active pool.
    function test_proposeRejectsAPoolBoundToAForeignRegistry() public {
        PoolStub foreign = new PoolStub(address(tok), makeAddr("foreignMarkets"));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.BadActivePool.selector, address(tok), address(foreign)));
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(foreign),
            _market(3_500, 5_500)
        );
    }

    /// Commit re-asserts the binding (the _assertMultiplierSource precedent): a wiring that
    /// breaks inside the timelock fails AT COMMIT, never as a bricked activePool.
    function test_commitReassertsThePoolBinding() public {
        PoolStub stub = new PoolStub(address(tok), address(mk));
        vm.prank(ADMIN);
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub),
            _market(3_500, 5_500)
        );
        stub.setCollateralToken(makeAddr("otherToken")); // breaks while the proposal is pending
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.BadActivePool.selector, address(tok), address(stub)));
        mk.commitMarket(address(tok));
        assertEq(mk.activePool(address(tok)), address(pool1), "the incumbent authority is untouched");
    }

    // ------------------------------------------------- succession x the freshness latch

    /// Round-6 A/B interplay: the latch compares the PAIR only, so a succession that keeps the
    /// pair commits — while one that rides a freshness change along reverts. Succession must
    /// never become a side door through FreshnessIsImmutable.
    function test_successionCannotRideAFreshnessChangeAlong() public {
        EsseyPool pool2 = _wiredPool();
        vm.startPrank(ADMIN);
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 89_000, 8, address(tok), address(pool2),
            _market(3_500, 5_500)
        );
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.FreshnessIsImmutable.selector, address(tok)));
        mk.commitMarket(address(tok));
        vm.stopPrank();
        assertEq(mk.activePool(address(tok)), address(pool1), "no flip on a refused commit");

        _succeed(pool2); // identical pair: the same successor commits cleanly
        assertEq(mk.activePool(address(tok)), address(pool2));
    }

    // ------------------------------------------------- succession x deprecation interleave

    /// A guardian disable mid-succession: the sticky delete kills the pending successor (no
    /// silent re-enable — the round-2 guarantee), activePool stays with the incumbent, and the
    /// succession must be RE-PROPOSED at full timelock price.
    function test_disableMidSuccessionKillsThePendingSuccessor() public {
        vm.prank(ADMIN);
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool1),
            _market(0, 5_500)
        );
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok)); // stage 1: retirement underway

        EsseyPool pool2 = _wiredPool();
        vm.prank(ADMIN);
        mk.proposeMarket(
            address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool2),
            _market(3_500, 5_500)
        );
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK()); // successor proposal ripens...
        px.set(200e8, block.timestamp);
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok)); // ...and an incident kills it, sticky
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.NoPendingChange.selector, address(tok)));
        mk.commitMarket(address(tok));
        assertEq(mk.activePool(address(tok)), address(pool1), "authority never moved to the dead pending");

        _beat(); _advanceLive(GRACE);
        _succeed(pool2); // a fresh proposal at full timelock price completes the succession
        assertEq(mk.activePool(address(tok)), address(pool2), "succession resumed, not resurrected");
    }

    /// Walk the feed to `target` in observed steps inside EsseyMarkets.MAX_PRICE_DEVIATION_BPS. A
    /// market MOVES; a corporate action GAPS, and since G-LEND R2 HIGH-1 a single step past the bound
    /// arms the desync breaker and holds both gates. See EsseyPool.t.sol:_walkPrice.
    /// G-LEND R3 HIGH-1: a seizure needs the move CORROBORATED — EsseyMarkets promotes an EARLIER
    /// observation to `confirmedPrice`, and only once PRICE_CONFIRM_DELAY has passed, so a level
    /// that has just moved cannot justify a liquidation until it has stood for that long.
    function _walkPriceAndSettle(int256 target) internal {
        _walkPrice(target);
        // R4 HIGH-1: the whole delay line has to have been observed AT the new level before the
        // oldest slot holds it, so this is the delay plus two steps, not the delay plus a second.
        _advanceLive(mk.PRICE_CONFIRM_DELAY() + 2 * mk.CONFIRM_STEP());
        mk.syncMultiplier(address(tok));
    }

    function _walkPrice(int256 target) internal {
        int256 cur = px.answer();
        while (cur != target) {
            int256 next = target < cur ? (cur * 85) / 100 : (cur * 115) / 100;
            if (target < cur ? next < target : next > target) next = target;
            if (next == cur) next = target;
            cur = next;
            px.set(cur, block.timestamp);
            mk.syncMultiplier(address(tok));
        }
        px.set(target, block.timestamp);
    }

}
