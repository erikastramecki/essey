// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {DonFeeRouter, ISwapRouter, IWETH} from "../src/market/DonFeeRouter.sol";
import {StaleFeedGuard} from "../src/StaleFeedGuard.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "./RiskModules.t.sol";
import {MockRouter} from "./StockConverter.t.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract USDG6 is ERC20 {
    constructor() ERC20("USDG", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract DonFeeRouterTest is Test {
    ERC20Mock essey;
    ERC20Mock usdg; // 18-dec reward token
    MockWETH weth;
    MockFeed ethFeed; // $2500, 8 dec
    MockFeed usdgFeed; // $1, 8 dec
    MockRouter swap;
    DonFeeRouter router;

    address bell = address(0xBE11);
    address rando = address(0x4A2D0);

    uint256 constant MIN_OUT_BPS = 9700;

    function setUp() public {
        vm.warp(1_753_110_000); // real-ish clock so feed freshness math behaves

        essey = new ERC20Mock();
        usdg = new ERC20Mock();
        weth = new MockWETH();
        ethFeed = new MockFeed(2500e8, 8);
        usdgFeed = new MockFeed(1e8, 8);

        swap = new MockRouter(2500e18); // fair: 1 WETH -> 2500 USDG (also used for ESSEY legs per-test)
        usdg.mint(address(swap), 1_000_000_000e18);

        router = new DonFeeRouter(_config(IERC20(address(usdg)), MIN_OUT_BPS));
    }

    function _config(IERC20 usdg_, uint256 minOutBps_) internal view returns (DonFeeRouter.Config memory c) {
        c = DonFeeRouter.Config({
            essey: IERC20(address(essey)),
            usdg: usdg_,
            weth: IWETH(address(weth)),
            bell: bell,
            admin: address(this),
            router: ISwapRouter(address(swap)),
            ethPoolFee: 3000,
            esseyPoolFee: 3000,
            minOutBps: minOutBps_,
            ethFeed: AggregatorV3Interface(address(ethFeed)),
            usdgFeed: AggregatorV3Interface(address(usdgFeed)),
            sequencerUptimeFeed: AggregatorV3Interface(address(0))
        });
    }

    function _fundEth(uint256 amt) internal {
        vm.deal(address(this), amt);
        (bool ok,) = address(router).call{value: amt}("");
        assertTrue(ok, "receive() accepts mint-fee ETH");
    }

    // ---------------------------------------------------------------- construction

    function test_ConstructorGuards() public {
        vm.expectRevert(DonFeeRouter.BadBps.selector);
        new DonFeeRouter(_config(IERC20(address(usdg)), 8999)); // >10% slippage allowance refused

        vm.expectRevert(DonFeeRouter.BadBps.selector);
        new DonFeeRouter(_config(IERC20(address(usdg)), 10_001));

        DonFeeRouter.Config memory c = _config(IERC20(address(usdg)), MIN_OUT_BPS);
        c.bell = address(0);
        vm.expectRevert(DonFeeRouter.ZeroAddress.selector);
        new DonFeeRouter(c);

        c = _config(IERC20(address(usdg)), MIN_OUT_BPS);
        c.ethFeed = AggregatorV3Interface(address(0));
        vm.expectRevert(DonFeeRouter.ZeroAddress.selector);
        new DonFeeRouter(c);

        assertEq(router.keeper(), address(this), "keeper defaults to admin");
        assertTrue(router.sequencerCheckDisabled(), "RH-chain has no uptime feed");
    }

    // ---------------------------------------------------------------- ETH leg (permissionless, oracle-fair)

    function test_FlushEthSwapsAtOracleFairRate() public {
        _fundEth(2 ether);
        vm.prank(rando); // ANYONE may trigger — the bound comes from the oracle, not the caller
        uint256 out = router.flushEth(block.timestamp);
        assertEq(out, 5000e18, "2 ETH x $2500 -> 5000 USDG");
        assertEq(usdg.balanceOf(bell), 5000e18, "all of it lands at the Bell");
        assertEq(address(router).balance, 0);
    }

    /// THE sandwich regression: no caller input can lower the bound. A pool quoting below
    /// oracle-fair x minOutBps makes the swap revert — value cannot be extracted past the oracle.
    function test_FlushEthRefusesBelowOracleBound() public {
        _fundEth(1 ether);
        swap.setRate(2400e18); // 4% under fair; bound is 3%
        vm.prank(rando);
        vm.expectRevert("Too little received");
        router.flushEth(block.timestamp);
        assertEq(address(router).balance, 1 ether, "ETH simply waits for a fair pool");

        swap.setRate(2430e18); // 2.8% under fair — inside the 3% tolerance
        vm.prank(rando);
        assertEq(router.flushEth(block.timestamp), 2430e18);
    }

    function test_FlushEthFailsClosedOnStaleFeed() public {
        _fundEth(1 ether);
        vm.warp(block.timestamp + router.FEED_HEARTBEAT() + router.STALENESS_GRACE() + 1);
        vm.expectPartialRevert(StaleFeedGuard.PriceStale.selector);
        router.flushEth(block.timestamp);

        // feed recovers -> the held ETH flushes fine
        ethFeed.set(2500e8, block.timestamp);
        usdgFeed.set(1e8, block.timestamp);
        assertEq(router.flushEth(block.timestamp), 2500e18);
        assertEq(usdg.balanceOf(bell), 2500e18);
    }

    function test_FlushEthNoBalanceStillSweepsStrayUsdg() public {
        usdg.mint(address(router), 77e18); // e.g. mis-sent
        assertEq(router.flushEth(block.timestamp), 77e18);
        assertEq(usdg.balanceOf(bell), 77e18, "stranded USDG always forwarded to the Bell");
    }

    /// USDG with 6 decimals (the realistic stable shape): fair-out normalization must scale.
    function test_FlushEthHandles6DecimalUsdg() public {
        USDG6 usdg6 = new USDG6();
        MockRouter swap6 = new MockRouter(2500e6); // 1e18 WETH-in -> 2500e6 USDG-out
        usdg6.mint(address(swap6), 1_000_000e6);
        DonFeeRouter.Config memory c = _config(IERC20(address(usdg6)), MIN_OUT_BPS);
        c.router = ISwapRouter(address(swap6));
        DonFeeRouter r6 = new DonFeeRouter(c);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(r6).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(r6.flushEth(block.timestamp), 2500e6, "6-dec fair out computed correctly");
        assertEq(usdg6.balanceOf(bell), 2500e6);

        // and the bound still bites at 6 decimals
        vm.deal(address(this), 1 ether);
        (ok,) = address(r6).call{value: 1 ether}("");
        assertTrue(ok);
        swap6.setRate(2400e6);
        vm.expectRevert("Too little received");
        r6.flushEth(block.timestamp);
    }

    // ---------------------------------------------------------------- $ESSEY leg (keeper, quoted)

    function test_FlushEsseyKeeperOnly() public {
        essey.mint(address(router), 1000e18);
        vm.prank(rando);
        vm.expectRevert(DonFeeRouter.NotKeeper.selector);
        router.flushEssey(block.timestamp, 1e18);
    }

    function test_FlushEsseyRequiresQuoteAndEnforcesBound() public {
        swap.setRate(1e15); // 1000 ESSEY -> 1 USDG
        essey.mint(address(router), 1000e18);

        vm.expectRevert(DonFeeRouter.ZeroQuote.selector);
        router.flushEssey(block.timestamp, 0); // a 0 quote would disable the bound — refused

        // honest quote for the whole balance: 1 USDG out
        uint256 out = router.flushEssey(block.timestamp, 1e18);
        assertEq(out, 1e18);
        assertEq(usdg.balanceOf(bell), 1e18);
        assertEq(essey.allowance(address(router), address(swap)), 0, "allowance reset after the swap");

        // pool sagging below quote x bound -> refused
        essey.mint(address(router), 1000e18);
        swap.setRate(9e14); // 10% under the quote
        vm.expectRevert("Too little received");
        router.flushEssey(block.timestamp, 1e18);
    }

    function test_FlushEsseyEmptyIsSweepOnly() public {
        usdg.mint(address(router), 5e18);
        assertEq(router.flushEssey(block.timestamp, 123), 5e18, "no ESSEY held -> quote unused, sweep only");
        assertEq(usdg.balanceOf(bell), 5e18);
    }

    // ---------------------------------------------------------------- admin surface

    function test_AdminSettersGatedAndBounded() public {
        vm.startPrank(rando);
        vm.expectRevert(DonFeeRouter.NotAdmin.selector);
        router.setRoute(ISwapRouter(address(swap)), 500, 500, MIN_OUT_BPS);
        vm.expectRevert(DonFeeRouter.NotAdmin.selector);
        router.setKeeper(rando);
        vm.stopPrank();

        vm.expectRevert(DonFeeRouter.BadBps.selector);
        router.setRoute(ISwapRouter(address(swap)), 500, 500, 8999); // can't reopen the sandwich window

        router.setKeeper(rando);
        assertEq(router.keeper(), rando);
        essey.mint(address(router), 10e18);
        swap.setRate(1e15);
        vm.prank(rando);
        router.flushEssey(block.timestamp, 1e16); // rotated keeper works
    }

    /// Funds can never be redirected: every path ends at the immutable bell.
    function test_NoPathMovesFundsAnywhereButBell() public {
        _fundEth(1 ether);
        essey.mint(address(router), 1000e18);
        swap.setRate(2500e18);
        router.flushEth(block.timestamp);
        swap.setRate(1e15);
        router.flushEssey(block.timestamp, 1e18);
        assertEq(usdg.balanceOf(bell), 2500e18 + 1e18);
        assertEq(usdg.balanceOf(address(router)), 0);
        assertEq(usdg.balanceOf(address(this)), 0, "admin/keeper got nothing");
    }
}
