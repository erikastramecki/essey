// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Script, console} from "forge-std/Script.sol";
import {QuestRegistry} from "../src/testnet/QuestRegistry.sol";

contract DeployQuest is Script {
    function run() external {
        vm.startBroadcast();
        QuestRegistry q = new QuestRegistry();
        vm.stopBroadcast();
        console.log("quest", address(q));
    }
}
