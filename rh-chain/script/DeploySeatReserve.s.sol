// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Deploy the SeatReserve — a USDG price floor for Seats. backedSupply = the Seat's maxSupply (every possible
// Seat backed equally, so no Seat is ever un-redeemable and backedSupply can't underflow). Seed the reserve
// separately with fund() (ops / protocol proceeds) to set the floor.
//
//   USDG=$TESTNET_USDG SEAT=0x7bcc... PK=$TESTNET_DEPLOYER_PK \
//   forge script script/DeploySeatReserve.s.sol --rpc-url rh_testnet --broadcast --private-key $PK \
//     --gas-estimate-multiplier 200
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatReserve} from "../src/market/SeatReserve.sol";

contract DeploySeatReserve is Script {
  function run() external {
    address usdg = vm.envAddress("USDG");
    address seat = vm.envAddress("SEAT");

    vm.startBroadcast();
    // The constructor reads Seat.maxSupply() itself and pins backedSupply to it (theft-proof by construction).
    SeatReserve reserve = new SeatReserve(IERC20(usdg), IERC721(seat));
    vm.stopBroadcast();

    console.log("SeatReserve  ", address(reserve));
    console.log("backedSupply ", reserve.backedSupply());
    console.log("Seed it with fund(amount) to set the floor (floorPerSeat = reserve / backedSupply).");
  }
}
