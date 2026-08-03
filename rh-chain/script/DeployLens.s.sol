// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {QuestLens, IQuest} from "../src/testnet/QuestLens.sol";

contract DeployLens is Script {
    function run() external {
        vm.startBroadcast();
        QuestLens lens = new QuestLens(
            IQuest(vm.envAddress("QUEST")),
            IERC721(vm.envAddress("SEAT")),
            IERC20(vm.envAddress("POOL")),
            IERC20(vm.envAddress("AAPL")),
            IERC20(vm.envAddress("NVDA"))
        );
        vm.stopBroadcast();
        console.log("lens", address(lens));
    }
}
