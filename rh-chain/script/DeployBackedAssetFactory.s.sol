// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bell} from "../src/market/Bell.sol";
import {BackedAssetFactory} from "../src/travel/BackedAssetFactory.sol";

/// Deploy the BackedAssetFactory — the self-serve launchpad for USDG-backed tokenized assets.
///
/// It wires into the ALREADY-DEPLOYED canonical ecosystem: the real USDG stable, the shared $ESSEY access
/// token, the shared Bell fee engine, and the protocol treasury. Every operator launch inherits these, so a
/// launched product plugs straight into the existing Gotcha/vault economy. The factory holds no funds and has
/// no admin, so there is nothing to configure post-deploy — operators call `launch`/`launchRaffle` themselves.
///
/// Env:
///   USDG      — the 6-dec backing/settlement stable (Global Dollar)
///   ESSEY     — the shared access token raffles are priced in
///   BELL      — the shared fee -> reward engine
///   TREASURY  — the protocol treasury (raffle case price + fee remainder)
///
/// Source the addresses from docs/DEPLOYMENT-testnet.md (testnet) or docs/MAINNET-CONFIG.md (mainnet).
contract DeployBackedAssetFactory is Script {
    function run() external returns (BackedAssetFactory factory) {
        address usdg = vm.envAddress("USDG");
        address essey = vm.envAddress("ESSEY");
        address bell = vm.envAddress("BELL");
        address treasury = vm.envAddress("TREASURY");

        require(usdg != address(0) && essey != address(0) && bell != address(0) && treasury != address(0), "env");
        require(essey != usdg, "ESSEY must differ from USDG"); // the voucher backing vs the access token

        vm.startBroadcast();
        factory = new BackedAssetFactory(IERC20(usdg), IERC20(essey), Bell(bell), treasury);
        vm.stopBroadcast();

        console.log("BackedAssetFactory:", address(factory));
        console.log("  usdg    ", usdg);
        console.log("  essey   ", essey);
        console.log("  bell    ", bell);
        console.log("  treasury", treasury);
    }
}
