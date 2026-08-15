// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Deploy AffinityRegistry against the LIVE testnet Dons stack.
//
//   forge script script/DeployAffinity.s.sol --rpc-url rh_testnet \
//     --private-key $TESTNET_DEPLOYER_PK --broadcast --gas-estimate-multiplier 300
//
// Env:
//   DON        — the Don ERC721 (default: live testnet v3 Don)
//   CONTROLLER — the sealed GameController (default: live testnet)
//
// Deploy only. Attestation is a keeper job and previewSheet() needs neither, so the site can read
// stat sheets off a bare deployment.
import {Script, console} from "forge-std/Script.sol";
import {AffinityRegistry} from "../src/game/AffinityRegistry.sol";
import {IGameController} from "../src/game/GameTypes.sol";
import {IDonTraits} from "../src/game/IAffinityRegistry.sol";

contract DeployAffinity is Script {
    address constant DON_DEFAULT = 0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c;
    address constant CONTROLLER_DEFAULT = 0xe2BEA5db063EA57F73D6bA8294592d7f60CBec9f;

    function run() external {
        address don = vm.envOr("DON", DON_DEFAULT);
        address controller = vm.envOr("CONTROLLER", CONTROLLER_DEFAULT);

        vm.startBroadcast();
        AffinityRegistry reg = new AffinityRegistry(IGameController(controller), IDonTraits(don));
        vm.stopBroadcast();

        console.log("AffinityRegistry", address(reg));
        console.log("  don           ", address(reg.don()));
        console.log("  controller    ", address(reg.controller()));
    }
}
