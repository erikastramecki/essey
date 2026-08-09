// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// TESTNET lending stack — the "get paid in stock → borrow against it" half of the flywheel, wired so
// loan interest routes to the same Bell the game feeds. Run after DeployMarket + SeedTestnet.
//
// Deploys LivenessOracle + EsseyMarkets + EsseyPool(BELL_SINK=bell), funds the pool with USDG so
// there is liquidity to borrow, and PROPOSES the AAPL/NVDA collateral markets. The 2-day param
// timelock is a real safety feature, not a knob — supply/withdraw works immediately; borrowing opens
// when commitMarket can be called (a follow-up tx after the timelock).
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "../test/RiskModules.t.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";

contract DeployLending is Script {
    uint256 constant SEED_LIQUIDITY = 100_000e18; // USDG lent into the pool at launch (18-dec mock)
    uint256 constant BELL_SHARE = 5_000; // 50% of skimmed loan-interest reserve → the Bell

    function run() external {
        address bell = vm.envAddress("BELL");
        ERC20Mock usdg = ERC20Mock(vm.envAddress("USDG"));
        address aapl = vm.envAddress("AAPL");
        address nvda = vm.envAddress("NVDA");
        address me = msg.sender;

        vm.startBroadcast();

        // Liveness: 30-min heartbeat, 30-min resume grace, 15-min gap (grace <= 4x gap guard). Deployer is
        // keeper+guardian on testnet; a real keeper would beat it (liquidation AND now borrow gate on it).
        LivenessOracle liveness = new LivenessOracle(me, me, 30 minutes, 30 minutes, 15 minutes);
        EsseyMarkets markets = new EsseyMarkets(AggregatorV3Interface(address(0)), liveness, me, 18);
        // 10% base APR, 20% of interest reserved, loan-interest reserve split 50% → the Bell.
        EsseyPool pool = new EsseyPool(IERC20(address(usdg)), markets, 1_000, 0, 0, 2_000, bell, me, BELL_SHARE);

        // Collateral markets: the same AAPL/NVDA tokens Cases pay out, so a winner can borrow against
        // exactly what they drew. Conservative 35% LTV / 55% liquidation (the 20pp gap).
        MockFeed aaplFeed = new MockFeed(200e8, 8);
        MockFeed nvdaFeed = new MockFeed(125e8, 8);
        _propose(markets, aapl, aaplFeed);
        _propose(markets, nvda, nvdaFeed);

        // Seed liquidity so there is USDG to borrow, and beat the liveness once to start its clock.
        usdg.mint(me, SEED_LIQUIDITY);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(SEED_LIQUIDITY, me);
        liveness.heartbeat();

        vm.stopBroadcast();

        console.log("liveness  ", address(liveness));
        console.log("markets   ", address(markets));
        console.log("pool      ", address(pool));
        console.log("aaplFeed  ", address(aaplFeed));
        console.log("nvdaFeed  ", address(nvdaFeed));
        console.log("");
        console.log("Markets PROPOSED. After the 2-day timelock, call markets.commitMarket(aapl) and");
        console.log("markets.commitMarket(nvda) to open borrowing. Supply/withdraw works now.");
    }

    function _propose(EsseyMarkets markets, address token, MockFeed feed) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true,
            ltvBps: 3_500,
            liqThresholdBps: 5_500,
            liqBonusBps: 800,
            collateralDecimals: 18, // mock stocks are 18-dec on testnet
            cap: uint128(1_000_000e18)
        });
        markets.proposeMarket(token, AggregatorV3Interface(address(feed)), 90_000, 8, m);
    }
}
