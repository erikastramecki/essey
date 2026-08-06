// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Essey Private — Phase 0. Deploys the ERC-5564 announcer, the ERC-6538 registry, and the private-pay
// path. No config, no funds, no privileged roles — they're deployed once and used permissionlessly.
//
//   PK=$TESTNET_DEPLOYER_PK forge script script/DeployStealth.s.sol --rpc-url rh_testnet --broadcast \
//     --private-key $PK --gas-estimate-multiplier 300
import {Script, console} from "forge-std/Script.sol";
import {EsseyStealthAnnouncer, IERC5564Announcer} from "../src/private/EsseyStealthAnnouncer.sol";
import {EsseyStealthRegistry} from "../src/private/EsseyStealthRegistry.sol";
import {EsseyStealthPay} from "../src/private/EsseyStealthPay.sol";

contract DeployStealth is Script {
    function run() external {
        vm.startBroadcast();
        EsseyStealthAnnouncer announcer = new EsseyStealthAnnouncer();
        EsseyStealthRegistry registry = new EsseyStealthRegistry();
        EsseyStealthPay payer = new EsseyStealthPay(IERC5564Announcer(address(announcer)));
        vm.stopBroadcast();

        console.log("EsseyStealthAnnouncer", address(announcer));
        console.log("EsseyStealthRegistry ", address(registry));
        console.log("EsseyStealthPay      ", address(payer));
    }
}
