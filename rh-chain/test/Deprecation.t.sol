// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {MockUSDG} from "./EsseyPool.t.sol";

/// WS3: the orderly-retirement playbook, end to end against the real pool (zero-rate, so every
/// figure below is exact). Stage 1 = ltv -> 0 (borrows close, everything else lives); stage 2 =
/// dust threshold over a second timelock (every open position becomes liquidatable at market,
/// surplus refunded); the residue is written off. The invariant this file exists for: NO PATH
/// STRANDS COLLATERAL.
contract DeprecationLifecycleTest is Test {
    EsseyMarkets mk;
    EsseyPool pool;
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
    address LIQUIDATOR;

    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant GRACE = 30 minutes;

    function setUp() public {
        ADMIN = makeAddr("admin"); KEEPER = makeAddr("keeper"); GUARDIAN = makeAddr("guardian");
        RESOLVER = makeAddr("resolver"); LENDER = makeAddr("lender");
        ALICE = makeAddr("alice"); LIQUIDATOR = makeAddr("liquidator");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0); seq.setStartedAt(block.timestamp - 2 days);
        px = new MockFeed(200e8, 8); // $200/share
        tok = new MockStock();
        usdg = new MockUSDG();
        liv = new LivenessOracle(KEEPER, GUARDIAN, 15 minutes, GRACE, 10 minutes);
        hox = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, GUARDIAN, 6);
        vm.prank(ADMIN);
        hox.wireMarkets(address(mk));
        // zero-rate pool: isolates the lifecycle arithmetic from accrual drift
        pool = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0,
            EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));

        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), _market(3_500, 5_500));
        mk.proposeResolver(RESOLVER);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        mk.commitResolver();
        vm.stopPrank();
        _beat(); _advanceLive(GRACE);
        _seedOracle();

        usdg.mint(LENDER, 1_000_000e6);
        usdg.mint(LIQUIDATOR, 100_000e6);
        usdg.mint(RESOLVER, 100_000e6);
        usdg.mint(ALICE, 100_000e6);
        tok.mint(ALICE, 1_000e18);
        vm.startPrank(LENDER);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(RESOLVER);
        usdg.approve(address(pool), type(uint256).max);
    }

    function _market(uint16 ltv, uint16 lt) internal pure returns (EsseyMarkets.Market memory) {
        return EsseyMarkets.Market({
            enabled: true, ltvBps: ltv, liqThresholdBps: lt, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
    }

    function _beat() internal { vm.prank(KEEPER); liv.heartbeat(); }

    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); px.set(200e8, block.timestamp); _beat(); _postD();
        }
        vm.warp(end); px.set(200e8, block.timestamp); _beat(); _postD();
    }

    function _postD() internal {
        vm.prank(KEEPER); hox.postDepth(address(tok), 4_000_000e6, uint64(block.number), "fork-swap-v1");
    }

    function _seedOracle() internal {
        _postD();
        for (uint256 i = 0; i < 42; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // ride the full ramp
        _beat(); _advanceLive(GRACE);
    }

    function _advanceToSession() internal {
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    /// Propose a retirement-stage config, serve the full timelock, commit, re-prove liveness.
    function _commitStage(uint16 ltv, uint16 lt) internal {
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), _market(ltv, lt));
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        _beat();
        _advanceLive(GRACE);
    }

    function test_fullRetirementLifecycleStrandsNoCollateral() public {
        _advanceToSession();
        vm.startPrank(ALICE);
        uint256 id1 = pool.borrow(10e18, 700e6);
        uint256 id2 = pool.borrow(10e18, 500e6);
        uint256 id3 = pool.borrow(10e18, 300e6);
        vm.stopPrank();

        // ---- stage 1: ltv -> 0, threshold kept. Borrows close; every servicing path stays open.
        _commitStage(0, 5_500);
        _advanceToSession();
        assertTrue(mk.isUsMarketHours(block.timestamp), "in session: the refusal below is stage 1, not the clock");
        assertFalse(mk.canBorrow(address(tok)), "stage 1 refuses new borrows");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrow(10e18, 100e6);

        vm.startPrank(ALICE);
        pool.repayPartial(id1, 200e6); // debt 700 -> 500
        pool.addCollateral(id2, 5e18); // 10 -> 15 shares backing id2
        pool.repay(id3, 400e6); // full close, collateral home
        vm.stopPrank();
        assertEq(pool.debtOf(id3), 0, "repay alive through stage 1");
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.PositionHealthy.selector);
        pool.liquidate(id1); // healthy at the KEPT threshold: stage 1 forces nobody out

        // ---- stage 2: dust threshold, over a second full timelock. Everything open is now
        // liquidatable at market price; the liquidator takes debt + bonus, the holder the rest.
        _commitStage(0, 100);
        _advanceToSession();
        assertTrue(mk.isUnderwater(address(tok), 10e18, pool.debtOf(id1)), "dust threshold exposes id1");
        vm.prank(LIQUIDATOR);
        pool.liquidate(id1);
        // seize = 500 * 1.08 = 540 USDG at $200/share = 2.7 shares; refund = 7.3 to the holder
        assertEq(tok.balanceOf(LIQUIDATOR), 27e17, "liquidator gets exactly debt + bonus");

        // ---- the residue: id2's collateral is destroyed by the issuer; only writeOff can clear it.
        tok.adminBurn(address(pool), tok.balanceOf(address(pool)));
        vm.prank(RESOLVER);
        pool.writeOff(id2, 100e6);

        // ---- the book is empty and nothing is stranded.
        assertEq(pool.debtOf(id1) + pool.debtOf(id2) + pool.debtOf(id3), 0, "no debt survives");
        assertEq(pool.totalBorrows(), 0);
        assertEq(pool.marketBorrows(address(tok)), 0);
        assertEq(tok.balanceOf(address(pool)), 0, "no collateral stranded in the pool");
        // ALICE: 1000 in, 35 posted, back 10 (id3) + 7.3 (id1 surplus); id2's 15 died with the burn
        assertEq(tok.balanceOf(ALICE), 1000e18 - 35e18 + 10e18 + 73e17, "surplus refunds reached the holder");
    }

    /// WS3 x sticky disable: an incident mid-retirement. The disable kills the ripe stage-2
    /// pending (audit-pinned delete); the LADDER survives it — installed ltv stays 0, so a fresh
    /// stage-2 proposal commits after one more full timelock, and although that commit sets
    /// enabled=true again, ltv == 0 keeps borrowing closed. The sticky-disable guarantee (no
    /// silent borrow re-open, round 2 of docs/audits/ad1-batch-rounds-1-5.md) holds throughout.
    function test_disableDuringStage1KillsThePendingButNotTheLadder() public {
        _advanceToSession();
        vm.prank(ALICE);
        uint256 id = pool.borrow(10e18, 700e6);

        _commitStage(0, 5_500); // stage 1
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), _market(0, 100));
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);

        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok)); // incident: the guardian's one power, mid-retirement
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.NoPendingChange.selector, address(tok)));
        mk.commitMarket(address(tok));

        _beat();
        _advanceLive(GRACE);
        assertTrue(mk.canLiquidate(address(tok)), "existing positions stay serviceable while disabled");
        assertEq(pool.debtOf(id), 700e6);

        _commitStage(0, 100); // re-proposed stage 2 pays a fresh full timelock; guard passes (ltv still 0)
        assertEq(mk.market(address(tok)).liqThresholdBps, 100, "the ladder resumed where it stood");
        assertTrue(mk.market(address(tok)).enabled, "the commit re-set the flag");
        _advanceToSession();
        assertFalse(mk.canBorrow(address(tok)), "but ltv == 0 keeps borrowing closed regardless");
    }
}
