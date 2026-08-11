// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// TESTNET operational seeding — run once after DeployMarket, by the deployer (who holds every
// admin/seeder/bankroll/treasury role on testnet). Gives the playground everything a tester needs:
// Exchange float, Case inventory, a funded buyback reserve, and a public faucet.
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "../test/RiskModules.t.sol";
import {Seat} from "../src/market/Seat.sol";
import {EsseyToken} from "../src/market/EsseyToken.sol";
import {EsseyExchange} from "../src/market/EsseyExchange.sol";
import {EsseyCases} from "../src/market/EsseyCases.sol";
import {MintDistributor} from "../src/market/MintDistributor.sol";
import {TestnetFaucet, IMintableMock} from "../src/testnet/TestnetFaucet.sol";

contract SeedTestnet is Script {
    uint256 constant FLOAT = 20; // Seats seeded into the Exchange
    uint256 constant FAUCET_ESSEY = 2_000_000e18; // ~400 drips

    function run() external {
        MintDistributor dist = MintDistributor(vm.envAddress("DISTRIBUTOR"));
        Seat seat = Seat(vm.envAddress("SEAT"));
        EsseyToken essey = EsseyToken(vm.envAddress("ESSEY"));
        EsseyExchange exchange = EsseyExchange(vm.envAddress("EXCHANGE"));
        EsseyCases cases_ = EsseyCases(vm.envAddress("CASES"));
        ERC20Mock usdg = ERC20Mock(vm.envAddress("USDG"));

        vm.startBroadcast();

        // 1. Exchange float: mint reserved Seats to the seeder (the broadcaster) and seed them.
        uint256 startId = seat.totalMinted() + 1;
        dist.mintReserved(msg.sender, FLOAT);
        uint256[] memory ids = new uint256[](FLOAT);
        for (uint256 i = 0; i < FLOAT; i++) {
            ids[i] = startId + i;
        }
        seat.setApprovalForAll(address(exchange), true);
        exchange.seed(ids);

        // 2. Case inventory: two mock stocks with $1-anchored feeds, units ~= the $100 case price.
        ERC20Mock aapl = new ERC20Mock();
        ERC20Mock nvda = new ERC20Mock();
        MockFeed aaplFeed = new MockFeed(200e8, 8); // $200/share -> 0.5-share units
        MockFeed nvdaFeed = new MockFeed(125e8, 8); // $125/share -> 0.8-share units
        cases_.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)), 5e17);
        cases_.listStock(address(nvda), AggregatorV3Interface(address(nvdaFeed)), 8e17);
        aapl.mint(msg.sender, 1_000e18);
        nvda.mint(msg.sender, 1_000e18);
        aapl.approve(address(cases_), type(uint256).max);
        nvda.approve(address(cases_), type(uint256).max);
        cases_.seedUnits(address(aapl), 60);
        cases_.seedUnits(address(nvda), 40);

        // 3. Buyback reserve so sell-backs work.
        usdg.mint(msg.sender, 50_000e18);
        usdg.approve(address(cases_), type(uint256).max);
        cases_.fundBuyback(50_000e18);

        // 4. The faucet: fund it with $ESSEY from the treasury (the broadcaster holds it on testnet).
        TestnetFaucet faucet = new TestnetFaucet(IERC20(address(essey)), IMintableMock(address(usdg)), msg.sender, 100_000e18, 1_000e18, 8 hours);
        essey.transfer(address(faucet), FAUCET_ESSEY);

        vm.stopBroadcast();

        console.log("faucet     ", address(faucet));
        console.log("aapl       ", address(aapl));
        console.log("nvda       ", address(nvda));
        console.log("float      ", exchange.inventoryCount());
        console.log("case units ", cases_.inventoryCount());
    }
}
