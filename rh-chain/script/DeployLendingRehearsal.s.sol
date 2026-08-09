// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ON-CHAIN REHEARSAL of the fixed borrow path (Robinhood Chain testnet). Self-contained: deploys its own
// USDG + ScaledUI-capable AAPL/NVDA mocks (the deployed testnet stock mocks lack uiMultiplier(), which the
// pool needs), a fresh LivenessOracle + EsseyMarkets + EsseyPool with ALL the borrow-path fixes, seeds
// liquidity, mints collateral to the deployer, PROPOSES the markets, and starts the liveness heartbeat.
//
// This is a THROWAWAY rehearsal instance (not the live site's stack, not mainnet) whose sole purpose is to
// prove borrow/repay/liquidate on a real chain. It uses PRODUCTION contracts unchanged — including the real
// 2-day param timelock — so `commitMarket` + the borrow/burn/repay/liquidate rehearsal run as a follow-up
// after the timelock elapses (see the paired keeper script). Supply/withdraw is exercisable immediately.
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed, MockStock} from "../test/RiskModules.t.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";

contract DeployLendingRehearsal is Script {
    uint256 constant SEED_LIQUIDITY = 100_000e18; // USDG lent in (18-dec mock, matching the testnet convention)
    uint256 constant COLLATERAL = 1_000e18; // AAPL/NVDA minted to the deployer to borrow against later

    function run() external {
        address me = msg.sender;
        vm.startBroadcast();

        // Borrow asset (18-dec, publicly mintable) + ScaledUI collateral (MockStock implements uiMultiplier,
        // balanceOfUI, totalSupplyUI, newUIMultiplier, adminBurn — the ERC-8056 surface the pool reads).
        ERC20Mock usdg = new ERC20Mock();
        MockStock aapl = new MockStock();
        MockStock nvda = new MockStock();
        MockFeed aaplFeed = new MockFeed(200e8, 8); // $200/share
        MockFeed nvdaFeed = new MockFeed(125e8, 8); // $125/share

        // Liveness: 30-min heartbeat / 30-min resume grace / 15-min gap (the #8-guarded config). Deployer is
        // keeper+guardian for the rehearsal.
        LivenessOracle liveness = new LivenessOracle(me, me, 30 minutes, 30 minutes, 15 minutes);
        // assetDecimals = 18 (matches this USDG mock). Sequencer feed unused on testnet (address(0)).
        EsseyMarkets markets = new EsseyMarkets(AggregatorV3Interface(address(0)), liveness, me, 18);
        // 10% base APR, 20% reserve factor, no Bell sink for the rehearsal (bellSink = 0).
        EsseyPool pool = new EsseyPool(IERC20(address(usdg)), markets, 1_000, 0, 0, 2_000, address(0), me, 0);

        _propose(markets, address(aapl), aaplFeed);
        _propose(markets, address(nvda), nvdaFeed);

        // Seed USDG liquidity so there is something to borrow; mint collateral to the deployer for later.
        usdg.mint(me, SEED_LIQUIDITY);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(SEED_LIQUIDITY, me);
        aapl.mint(me, COLLATERAL);
        nvda.mint(me, COLLATERAL);

        liveness.heartbeat(); // start the liveness clock

        vm.stopBroadcast();

        console.log("REHEARSAL ADDRESSES (Robinhood Chain testnet):");
        console.log("usdg     ", address(usdg));
        console.log("aapl     ", address(aapl));
        console.log("nvda     ", address(nvda));
        console.log("aaplFeed ", address(aaplFeed));
        console.log("nvdaFeed ", address(nvdaFeed));
        console.log("liveness ", address(liveness));
        console.log("markets  ", address(markets));
        console.log("pool     ", address(pool));
        console.log("");
        console.log("Supply/withdraw is live NOW. After the 2-day timelock, commitMarket(aapl)+commitMarket(nvda),");
        console.log("then rehearse borrow -> adminBurn -> repay(haircut) -> liquidate.");
    }

    function _propose(EsseyMarkets markets, address token, MockFeed feed) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true,
            ltvBps: 3_500,
            liqThresholdBps: 5_500,
            liqBonusBps: 800,
            collateralDecimals: 18, // MockStock is 18-dec (matched by the #3 cross-check)
            cap: uint128(1_000_000e18)
        });
        markets.proposeMarket(token, AggregatorV3Interface(address(feed)), 90_000, 8, m);
    }
}
