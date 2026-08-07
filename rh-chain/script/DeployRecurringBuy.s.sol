// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Deploy RecurringBuy (Auto-stack into stock) — a non-custodial DCA that settles through the existing
// StockConverter (oracle-floored, session-gated). USDG must be the converter's base asset.
//
//   USDG=$TESTNET_USDG CONVERTER=0x3c6a57b2... PK=$TESTNET_DEPLOYER_PK \
//   forge script script/DeployRecurringBuy.s.sol --rpc-url rh_testnet --broadcast --private-key $PK \
//     --gas-estimate-multiplier 200
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RecurringBuy, IStockConverter} from "../src/market/RecurringBuy.sol";

contract DeployRecurringBuy is Script {
  function run() external {
    address usdg = vm.envAddress("USDG");
    address converter = vm.envAddress("CONVERTER");
    vm.startBroadcast();
    RecurringBuy rb = new RecurringBuy(IERC20(usdg), IStockConverter(converter));
    vm.stopBroadcast();
    console.log("RecurringBuy ", address(rb));
    console.log("base (USDG)  ", usdg);
    console.log("converter    ", converter);
  }
}
