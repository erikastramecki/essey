// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Proves the full paid-in-stock loop on-chain, as the deployer: buy a Seat, stake Tier I, grow the
// pot with a couple more trades, ring, then claim — and ASSERT real stock (AAPL/NVDA) landed in the
// Seat's Vault. Reverts if the Vault got no stock (conversion didn't settle — off-session or reserve
// short), so a green run IS the proof. Must run in a US market session.
//
//   SEAT=.. BELL=.. EXCHANGE=.. ESSEY=.. USDG=.. AAPL=.. NVDA=.. \
//   FOUNDRY_PROFILE=script forge script script/ProveStockPayout.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell} from "../src/market/Bell.sol";
import {EsseyExchange} from "../src/market/EsseyExchange.sol";

contract ProveStockPayout is Script {
    function run() external {
        address me = vm.addr(vm.envUint("PK"));
        EsseyExchange exchange = EsseyExchange(vm.envAddress("EXCHANGE"));
        Bell bell = Bell(vm.envAddress("BELL"));
        Seat seat = Seat(vm.envAddress("SEAT"));
        IERC20 essey = IERC20(vm.envAddress("ESSEY"));
        ERC20Mock usdg = ERC20Mock(vm.envAddress("USDG"));
        IERC20 aapl = IERC20(vm.envAddress("AAPL"));
        IERC20 nvda = IERC20(vm.envAddress("NVDA"));

        vm.startBroadcast();
        usdg.mint(me, 10_000e18); // fee currency (deployer already holds the $ESSEY supply)
        essey.approve(address(exchange), type(uint256).max);
        usdg.approve(address(exchange), type(uint256).max);
        essey.approve(address(bell), type(uint256).max);

        uint256 id = exchange.buy(); // buy a Seat
        bell.activate(id, 1); // stake Tier I (this Seat now earns payout weight)
        exchange.buy(); // two more trades — each fee grows the Bell pot
        exchange.buy();
        bell.ring(); // distribute the pot to active Seats
        bell.claim(id); // claim -> unset Seat defaults to the BUNDLE -> stock into the Vault
        vm.stopBroadcast();

        address vault = seat.vaultOf(id);
        uint256 a = aapl.balanceOf(vault);
        uint256 n = nvda.balanceOf(vault);
        console.log("Seat id       ", id);
        console.log("Vault         ", vault);
        console.log("AAPL in vault ", a);
        console.log("NVDA in vault ", n);
        require(
            a > 0 || n > 0,
            "PROOF FAILED: no stock in the Vault - conversion did not settle (off-session, stale feed, or reserve short)"
        );
        console.log("PROOF PASSED: real stock delivered to the Seat's Vault via the Bell claim.");
    }
}
