// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {DonFeeRouter, ISwapRouter, IWETH} from "../src/market/DonFeeRouter.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {MockFeed} from "../test/RiskModules.t.sol";
import {MockWETH} from "../test/DonFeeRouter.t.sol";
import {MockRouter} from "../test/StockConverter.t.sol";

interface IMintable {
    function mint(address to, uint256 amt) external;
}

/// WireDonFees — TESTNET-ONLY: stand up the fee route the main deploy skipped (no WETH/ETH-feed on the
/// RH testnet), then point the distributor's feeSink at the real DonFeeRouter. Deploys mock WETH, a
/// $4,500 ETH/USD feed, and a fixed-rate mock swap router funded with mock USDG — the same fixture
/// pattern the lending rehearsal uses. Mainnet uses the REAL WETH/feeds/Uniswap via DeployDons env.
contract WireDonFees is Script {
    function run() external {
        DonDistributor dist = DonDistributor(vm.envAddress("DISTRIBUTOR"));
        IERC20 essey = IERC20(vm.envAddress("ESSEY"));
        IERC20 usdg = IERC20(vm.envAddress("USDG")); // mock, publicly mintable test fixture
        address usdgFeed = vm.envAddress("USDG_FEED");
        address bell = vm.envAddress("BELL");

        vm.startBroadcast();

        MockWETH weth = new MockWETH();
        MockFeed ethFeed = new MockFeed(4500e8, 8); // $4,500, 8-dec Chainlink shape
        // Fair fixed rate: 1 WETH -> 4,500 USDG (18-dec mock), 1e18-scaled; ESSEY leg quoted by keeper.
        MockRouter router = new MockRouter(4500e18);
        IMintable(address(usdg)).mint(address(router), 10_000_000e18); // swap liquidity

        DonFeeRouter feeRouter = new DonFeeRouter(
            DonFeeRouter.Config({
                essey: essey,
                usdg: usdg,
                weth: IWETH(address(weth)),
                bell: bell,
                admin: msg.sender,
                router: ISwapRouter(address(router)),
                ethPoolFee: 3000,
                esseyPoolFee: 3000,
                minOutBps: 9700,
                ethFeed: AggregatorV3Interface(address(ethFeed)),
                usdgFeed: AggregatorV3Interface(usdgFeed),
                sequencerUptimeFeed: AggregatorV3Interface(address(0))
            })
        );
        dist.setFeeSink(address(feeRouter));

        vm.stopBroadcast();

        console.log("weth       ", address(weth));
        console.log("ethFeed    ", address(ethFeed));
        console.log("swapRouter ", address(router));
        console.log("feeRouter  ", address(feeRouter));
        console.log("feeSink now", dist.feeSink());
        console.log("NOTE: feed-keeper cron must refresh ethFeed like the USDG/AAPL/NVDA mocks (25h staleness).");
    }
}
