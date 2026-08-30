// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConstantMultiplier} from "../src/adapters/ConstantMultiplier.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed, MockStock, PoolStub} from "./RiskModules.t.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {MockUSDG} from "./EsseyPool.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Backed's Ink wrapper shape: a plain ERC-20 with NO ERC-8056 surface. Pre-seam, listing this
/// as collateral bricked the market (collateralValue reverted forever).
contract WrappedStock is ERC20 {
    constructor() ERC20("Backed wNVDAx", "wNVDAx") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// WS4 #4: the multiplier adapter seam. The Robinhood shape (source == token) is pinned by the
/// whole existing suite; this file pins the Ink shape and the source/token separation.
contract AdapterSeamTest is Test {
    EsseyMarkets mk;
    EsseyPool pool;
    LivenessOracle liv;
    MarketHealthOracle hox;
    MockFeed seq;
    MockFeed px;
    WrappedStock wtok;
    ConstantMultiplier cm;
    MockUSDG usdg;

    address ADMIN;
    address KEEPER;
    address RESOLVER;
    address LENDER;
    address ALICE;
    address LIQUIDATOR;

    uint256 constant MON_IN_SESSION = 1_753_110_000;

    function setUp() public {
        ADMIN = makeAddr("admin"); KEEPER = makeAddr("keeper"); RESOLVER = makeAddr("resolver");
        LENDER = makeAddr("lender"); ALICE = makeAddr("alice"); LIQUIDATOR = makeAddr("liquidator");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0); seq.setStartedAt(block.timestamp - 2 days);
        px = new MockFeed(200e8, 8);
        wtok = new WrappedStock();
        cm = new ConstantMultiplier();
        usdg = new MockUSDG();
        liv = new LivenessOracle(KEEPER, makeAddr("guardian"), 15 minutes, 30 minutes, 10 minutes);
        hox = new MarketHealthOracle(KEEPER, makeAddr("hox-guardian"), ADMIN);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, makeAddr("mk-guardian"), 6);
        vm.prank(ADMIN);
        hox.wireMarkets(address(mk));
        pool = new EsseyPool(usdg, address(wtok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey wNVDAx Share", "awNVDAx", "Essey wNVDAx Note", "nwNVDAx"));

        vm.startPrank(ADMIN);
        mk.proposeMarket(address(wtok), AggregatorV3Interface(address(px)), 3_600, 7_200, 8, address(cm), address(pool), _market());
        mk.proposeResolver(RESOLVER);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(wtok));
        mk.commitResolver();
        vm.stopPrank();

        _beat(); _advanceLive(30 minutes);
        _seedOracle();

        usdg.mint(LENDER, 1_000_000e6);
        usdg.mint(LIQUIDATOR, 100_000e6);
        usdg.mint(RESOLVER, 100_000e6);
        wtok.mint(ALICE, 1_000e18);
        vm.startPrank(LENDER);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        wtok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(RESOLVER);
        usdg.approve(address(pool), type(uint256).max);
    }

    function _market() internal pure returns (EsseyMarkets.Market memory) {
        return EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
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
        vm.prank(KEEPER); hox.postDepth(address(wtok), 4_000_000e6, uint64(block.number), "fork-swap-v1");
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

    /// The market a bare wrapper used to brick works end to end through the adapter:
    /// borrow, repay, liquidate, write off.
    function test_inkShape_fullLifecycleThroughTheAdapter() public {
        assertEq(mk.multiplierSource(address(wtok)), address(cm), "the adapter is the wired source");
        (uint256 v,) = mk.collateralValue(address(wtok), 10e18);
        assertEq(v, 2_000e6, "identity multiplier: 10 wNVDAx @ $200 = $2000 in USDG units");
        assertTrue(mk.canBorrow(address(wtok)), "the pre-seam brick: this was permanently false");

        vm.startPrank(ALICE);
        uint256 idRepay = pool.borrow(10e18, 600e6);
        pool.repay(idRepay, 700e6);
        uint256 idLiq = pool.borrow(10e18, 600e6);
        uint256 idWoff = pool.borrow(10e18, 600e6);
        vm.stopPrank();
        assertEq(wtok.balanceOf(ALICE), 1_000e18 - 20e18, "repay returned the first position's collateral");

        px.set(80e8, block.timestamp); // $800 collateral vs $600 debt: past the 55% threshold
        assertTrue(mk.canLiquidate(address(wtok)));
        vm.prank(LIQUIDATOR);
        pool.liquidate(idLiq);
        assertEq(pool.debtOf(idLiq), 0, "liquidated through the adapter path");

        px.set(1e8, block.timestamp); // $10 collateral vs $600 debt: beyond recovery
        (uint256 floor,) = mk.collateralValue(address(wtok), 10e18);
        vm.prank(RESOLVER);
        pool.writeOff(idWoff, floor);
        assertEq(pool.debtOf(idWoff), 0, "written off through the adapter path");
    }

    /// The desync guard reads the SOURCE. Pointing it back at the token would both miss real
    /// corporate actions on the source and re-introduce the bare-wrapper revert.
    function test_desyncGuardReadsTheSourceNotTheToken() public {
        MockStock tokX = new MockStock();
        MockStock srcX = new MockStock();
        srcX.setMultiplier(3e18); // distinct from the token's 1e18, so a seed from the wrong
                                  // contract makes the first sync read as a corporate action
        MockFeed pxX = new MockFeed(200e8, 8);
        PoolStub stubX = new PoolStub(address(tokX), address(mk));
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tokX), AggregatorV3Interface(address(pxX)), 86_400, 90_000, 8, address(srcX), address(stubX), _market());
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        pxX.set(200e8, block.timestamp);
        mk.commitMarket(address(tokX));
        vm.stopPrank();
        _beat(); _advanceLive(30 minutes);
        _matureDepth(address(tokX));
        pxX.set(200e8, block.timestamp);

        mk.syncMultiplier(address(tokX));
        assertTrue(mk.canBorrow(address(tokX)), "baseline open (and the 3e18 seed came from the source)");

        tokX.schedule(2e18, block.timestamp + 20 minutes); // a schedule on the TOKEN is not the market's
        assertTrue(mk.canBorrow(address(tokX)), "the token is not the multiplier source");
        tokX.schedule(0, 0);

        srcX.schedule(2e18, block.timestamp + 20 minutes); // the SOURCE's schedule is
        assertFalse(mk.canBorrow(address(tokX)), "source schedule closes borrowing");
        assertFalse(mk.canLiquidate(address(tokX)), "and liquidation");
        srcX.schedule(0, 0);

        srcX.setMultiplier(6e18); // an applied move on the source, observed via sync
        mk.syncMultiplier(address(tokX));
        assertFalse(mk.canBorrow(address(tokX)), "observed source move closes borrowing");
    }

    /// The pool calls syncMultiplier before canBorrow, so on a never-committed market it must
    /// decline quietly — an unguarded read of source==0 hits the codeless-address try/catch trap
    /// (solc >=0.8.10 empty-returndata: the revert lands OUTSIDE the catch) and turns "market
    /// closed" into a raw revert.
    function test_syncOnANeverCommittedMarketIsANoOp() public {
        mk.syncMultiplier(makeAddr("ghost-token"));
        assertEq(mk.seenMultiplier(makeAddr("ghost-token")), 0, "nothing recorded");
    }

    function test_zeroMultiplierSourceIsRejected() public {
        MockStock tokX = new MockStock();
        PoolStub stubX = new PoolStub(address(tokX), address(mk));
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(EsseyMarkets.BadMultiplierSource.selector, address(tokX), address(0))
        );
        mk.proposeMarket(address(tokX), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(0), address(stubX), _market());
    }

    function test_sourceWithoutUiMultiplierIsRejectedLoudly() public {
        MockStock tokX = new MockStock();
        PoolStub stubX = new PoolStub(address(tokX), address(mk));
        vm.prank(ADMIN);
        vm.expectRevert(); // the bare call reverts — never a silent 1e18 default (the 1e12 lesson)
        mk.proposeMarket(address(tokX), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(wtok), address(stubX), _market());
    }

    /// The loudness pin: a wiring that breaks between propose and commit fails AT COMMIT — the
    /// pre-seam behavior was a market that commits fine and bricks at the first borrow.
    function test_brokenSourceFailsAtCommitNotAtFirstBorrow() public {
        MockStock tokX = new MockStock();
        MockStock srcX = new MockStock();
        PoolStub stubX = new PoolStub(address(tokX), address(mk));
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tokX), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(srcX), address(stubX), _market());
        srcX.setMultiplier(0); // breaks while the proposal is in the timelock
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(EsseyMarkets.BadMultiplierSource.selector, address(tokX), address(srcX))
        );
        mk.commitMarket(address(tokX));
        vm.stopPrank();
        assertFalse(mk.canBorrow(address(tokX)), "nothing was installed");
    }

    /// Same rug edge as the feed: a later commit must not be able to swap a live market's source.
    function test_multiplierSourceCannotBeSwappedOnRecommit() public {
        ConstantMultiplier other = new ConstantMultiplier();
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(wtok), AggregatorV3Interface(address(px)), 3_600, 7_200, 8, address(other), address(pool), _market());
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.MultiplierSourceIsImmutable.selector, address(wtok)));
        mk.commitMarket(address(wtok));
        vm.stopPrank();
    }
}
