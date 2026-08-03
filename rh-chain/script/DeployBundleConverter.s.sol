// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// TESTNET: deploy the inventory BundleConverter, list AAPL/NVDA, build the default basket, and seed
// its stock reserve — the piece that makes the Bell pay out real stock. Run this FIRST, then deploy
// the market with CONVERTER=<printed converter> DEFAULT_PAYOUT=<printed BUNDLE>.
//
//   forge script script/DeployBundleConverter.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
//
// Reuses the existing mock AAPL/NVDA token addresses (so the lending pool + lens keep working) and
// gives the converter its own $200/$125 feeds. The broadcaster holds the bankroll/treasury roles.
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "../test/RiskModules.t.sol";
import {BundleConverter} from "../src/market/BundleConverter.sol";

contract DeployBundleConverter is Script {
    // Reserve seeded per stock (whole shares) — generous for a testnet playground.
    uint256 constant AAPL_RESERVE = 5_000e18;
    uint256 constant NVDA_RESERVE = 5_000e18;

    function run() external {
        address usdg = vm.envAddress("USDG");
        address usdgFeed = vm.envAddress("USDG_FEED");
        address aapl = vm.envAddress("AAPL");
        address nvda = vm.envAddress("NVDA");
        address sequencer = vm.envOr("SEQUENCER_FEED", address(0));
        address treasury = vm.envOr("TREASURY", msg.sender);
        uint256 spreadBps = vm.envOr("CONVERTER_SPREAD_BPS", uint256(0)); // full oracle value by default

        vm.startBroadcast();

        // Own feeds for the converter's price legs (same values the pool/Cases use).
        MockFeed aaplFeed = new MockFeed(200e8, 8); // $200/share
        MockFeed nvdaFeed = new MockFeed(125e8, 8); // $125/share

        BundleConverter conv = new BundleConverter(
            IERC20(usdg),
            AggregatorV3Interface(usdgFeed),
            AggregatorV3Interface(sequencer),
            msg.sender, // bankroll (add-only)
            treasury,
            spreadBps
        );

        conv.listStock(aapl, AggregatorV3Interface(address(aaplFeed)));
        conv.listStock(nvda, AggregatorV3Interface(address(nvdaFeed)));
        conv.addBundleMember(aapl);
        conv.addBundleMember(nvda);

        // Seed the stock reserve (mint the mock stock to the bankroll, approve, deposit).
        ERC20Mock(aapl).mint(msg.sender, AAPL_RESERVE);
        ERC20Mock(nvda).mint(msg.sender, NVDA_RESERVE);
        ERC20Mock(aapl).approve(address(conv), type(uint256).max);
        ERC20Mock(nvda).approve(address(conv), type(uint256).max);
        conv.seedReserve(aapl, AAPL_RESERVE);
        conv.seedReserve(nvda, NVDA_RESERVE);

        vm.stopBroadcast();

        console.log("BundleConverter ", address(conv));
        console.log("  BUNDLE (default payout) ", conv.BUNDLE());
        console.log("  aaplFeed      ", address(aaplFeed));
        console.log("  nvdaFeed      ", address(nvdaFeed));
        console.log("  aapl reserve  ", conv.reserveOf(aapl));
        console.log("  nvda reserve  ", conv.reserveOf(nvda));
        console.log("NEXT 1) DeployMarket with CONVERTER=<above> DEFAULT_PAYOUT=<BUNDLE above>");
        console.log("NEXT 2) WireConverterBell with CONVERTER=<above> BELL=<new Bell>  (gates convert to the Bell)");
    }
}
