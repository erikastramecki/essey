// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Local-anvil rehearsal fixtures only — never part of a real deploy.
import {Script, console} from "forge-std/Script.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockFeed} from "../test/RiskModules.t.sol";

contract SetupMocks is Script {
    function run() external {
        vm.startBroadcast();
        ERC20Mock usdg = new ERC20Mock();
        MockFeed feed = new MockFeed(1e8, 8);
        vm.stopBroadcast();
        console.log("USDG", address(usdg));
        console.log("FEED", address(feed));
    }
}
