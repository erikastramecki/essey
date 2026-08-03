// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// TESTNET: the FINAL deploy step. `BundleConverter.convert` is gated to the Bell, but the Bell takes
// the converter in ITS constructor, so the converter can't know the Bell at its own deploy time. After
// DeployMarket produces the converter-wired Bell, this closes the loop (one-shot, bankroll-only).
//
//   forge script script/WireConverterBell.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
//
// Reads CONVERTER and BELL from env. Until this runs, convert() reverts for everyone (the reserve is
// untouchable), so payouts fall open to USDG — run it before expecting stock payouts.
import {Script, console} from "forge-std/Script.sol";
import {BundleConverter} from "../src/market/BundleConverter.sol";

contract WireConverterBell is Script {
    function run() external {
        BundleConverter conv = BundleConverter(vm.envAddress("CONVERTER"));
        address bell = vm.envAddress("BELL");
        vm.startBroadcast();
        conv.initBell(bell);
        vm.stopBroadcast();
        console.log("converter", address(conv));
        console.log("  bell wired ->", conv.bell());
    }
}
