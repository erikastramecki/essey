// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {EsseyToken} from "../src/market/EsseyToken.sol";
import {EsseyReserve} from "../src/market/EsseyReserve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Deploys the Essey BASE LAYER on Robinhood mainnet (4663):
///   1. EsseyToken   — mints the full 8,888,888,888 $ESSEY to the TREASURY wallet.
///   2. EsseyReserve — FULLY ADMINLESS claim-based floor. No registrar, no basket, no owner: it holds
///      ANY token sent to it and $ESSEY redeems pro-rata in-kind against the live pile, so backing
///      needs no listing and grows without bound. It deploys EMPTY; the treasury funds it on its own
///      schedule (permissionless deposit / raw transfer). $ESSEY is NOT tradable here — no AMM seeded.
///
/// The TREASURY is passed via env (`ESSEY_TREASURY`) so the address is not baked into a public repo;
/// the deployer key (--private-key / keystore) SHOULD be the treasury itself so the mint recipient ==
/// the deployer. Run behind the founder's per-action mainnet gate.
///
/// DEPLOY INVARIANT: EsseyReserve captures `claimBase = essey.totalSupply()` in its constructor, so the
/// token MUST be deployed and fully minted FIRST (it is, below) — the reserve reads 8.888e27 at line 2.
contract DeployEsseyFoundation is Script {
    function run() external {
        address treasury = vm.envAddress("ESSEY_TREASURY");
        require(treasury != address(0), "ESSEY_TREASURY unset");
        require(block.chainid == 4663, "not RH mainnet 4663");

        vm.startBroadcast();
        EsseyToken essey = new EsseyToken(treasury);
        EsseyReserve reserve = new EsseyReserve(IERC20(address(essey)));
        vm.stopBroadcast();

        console2.log("ESSEY token   :", address(essey));
        console2.log("EsseyReserve  :", address(reserve));
        console2.log("treasury/mint :", treasury);
        console2.log("supply minted :", essey.totalSupply());
        console2.log("claimBase     :", reserve.claimBase());
        console2.log("NOTE: reserve is EMPTY + adminless. Backing counts the moment stock is deposited.");
    }
}
