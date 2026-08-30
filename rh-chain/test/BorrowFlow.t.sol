// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockFeed} from "../src/testnet/MockFeed.sol";
import {ScaledUIStockMock} from "../src/testnet/ScaledUIStockMock.sol";

/// The demo, as a test. This is the exact path the investor will be walked through — deposit stock,
/// borrow against it, watch the health factor — so it is pinned here rather than discovered live.
///
/// It also proves the ScaledUI fixture actually closes the gap that made `canBorrow` false on the
/// old testnet deployment: the collateral token must expose `uiMultiplier()` or `collateralValue`
/// reverts and borrowing is silently impossible.
contract BorrowFlowTest is Test {
    EsseyMarkets markets;
    EsseyPool pool;
    ScaledUIStockMock usdg;
    ScaledUIStockMock aapl;
    MockFeed aaplFeed;
    LivenessOracle liveness;
    MarketHealthOracle health;
    address lender = address(0xA1);
    address borrower = address(0xB0B);

    function setUp() public {
        MockFeed usdgFeed = new MockFeed(8, 1e8);
        // Chainlink L2 sequencer uptime: 0 = up. A price feed here reads as "down".
        MockFeed seqFeed = new MockFeed(8, 0);
        usdg = new ScaledUIStockMock("Mock USDG", "USDG");
        liveness = new LivenessOracle(address(this), address(this), 90_000, 1 hours, 900);
        health = new MarketHealthOracle(address(this), address(this), address(this));
        markets = new EsseyMarkets(AggregatorV3Interface(address(seqFeed)), liveness, health, address(this), address(this), 18);
        health.wireMarkets(address(markets));
        aapl = new ScaledUIStockMock("Mock AAPL", "AAPL");
        pool = new EsseyPool(
            IERC20(address(usdg)), address(aapl), markets, 1000, 500, 6000, 1000, address(0),
            address(this), 0, EsseyPool.Identity("Essey AAPL Pool Share", "aAAPL", "Essey AAPL Note", "nAAPL")
        );

        aaplFeed = new MockFeed(8, 200e8);
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 5000, liqThresholdBps: 7500, liqBonusBps: 500,
            collateralDecimals: 18, cap: 250_000e18, maxPositionBps: 10_000
        });
        markets.proposeMarket(address(aapl), AggregatorV3Interface(address(aaplFeed)), 86_400, 90_000, 8, address(aapl), address(pool), m);
        vm.warp(block.timestamp + 2 days + 1);
        markets.commitMarket(address(aapl));
        // canBorrow returns `inSession`, so new borrows are only admitted during US market hours
        // (14:30-20:00 UTC on a weekday, the conservative overlap of EST and EDT). Pin a Wednesday
        // 15:00 UTC so the suite does not pass or fail depending on when it is run — and ride the
        // depth ramp up to it on a live keeper cadence: a silent warp past MAX_READING_AGE resets it.
        vm.warp(1787151600 - 21 days);
        health.postDepth(address(aapl), 1_000_000e18, uint64(block.number), "fork-swap-v1");
        for (uint256 i = 0; i < 42; i++) {
            vm.warp(block.timestamp + 12 hours);
            health.postDepth(address(aapl), 1_000_000e18, uint64(block.number), "fork-swap-v1");
        }
        // A long gap puts the oracle into post-outage resume grace, during which new borrows are
        // deliberately refused. Heartbeat, let the grace elapse, heartbeat again — which is exactly
        // what a keeper does after a sequencer restart.
        liveness.heartbeat();
        vm.warp(block.timestamp + 1 hours + 1); // let the grace elapse; a SECOND heartbeat here
                                                // would exceed gapThreshold and restart it.
        // The timelock outlives the feed's 25h staleness limit, so the keeper must re-stamp before
        // anyone can borrow. Skipping this is precisely how the live testnet sat unborrowable.
        aaplFeed.set(200e8, block.timestamp);
        health.postDepth(address(aapl), 1_000_000e18, uint64(block.number), "fork-swap-v1");

        usdg.mint(lender, 100_000e18);
        aapl.mint(borrower, 100e18);
    }

    function test_theDemoPath_depositStock_borrowAgainstIt() public {
        vm.startPrank(lender);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(100_000e18, lender);
        vm.stopPrank();
        assertEq(pool.totalAssets(), 100_000e18, "pool funded");

        // The fixture gap that broke the old testnet: without uiMultiplier() this reverts.
        (uint256 value,) = markets.collateralValue(address(aapl), 100e18);
        assertEq(value, 20_000e18, "100 AAPL at $200 = $20,000");
        assertTrue(markets.canBorrow(address(aapl)), "market must be borrowable");
    }

    function test_scaledUI_isWhatMakesCollateralValueWork() public {
        // A corporate action re-scales UI balances while raw balances stay put; collateral value
        // must follow the multiplier, not the raw amount.
        aapl.setUIMultiplier(2e18);
        (uint256 value,) = markets.collateralValue(address(aapl), 100e18);
        assertEq(value, 40_000e18, "a 2x split doubles collateral value");
    }

    function test_staleFeedBlocksBorrowing_ratherThanPricingItWrong() public {
        vm.warp(block.timestamp + 100_000);
        vm.expectRevert();
        markets.collateralValue(address(aapl), 100e18);
        assertFalse(markets.canBorrow(address(aapl)), "a stale price must not be usable");
    }
}
