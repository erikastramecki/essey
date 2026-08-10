// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SolvencyVerifier} from "../src/verifier/SolvencyVerifier.sol";

/// Deploy the SolvencyVerifier — the stateless Groth16 verifier for the dregg solvency proof. It has no
/// constructor args, no admin, no state, and depends only on the bn254 precompiles, so the SAME contract
/// can be deployed on ANY EVM chain to independently verify a solvency proof for a few hundred k gas. This
/// is the "verify our 1:1-collateralized solvency on the chain you settle on" primitive — deploy it once
/// per destination chain, permissionlessly.
contract DeploySolvencyVerifier is Script {
    function run() external returns (SolvencyVerifier verifier) {
        vm.startBroadcast();
        verifier = new SolvencyVerifier();
        vm.stopBroadcast();
        console.log("SolvencyVerifier:", address(verifier));
    }
}
