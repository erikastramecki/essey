// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonExchange} from "../src/market/DonExchange.sol";
import {DonLoan} from "../src/market/DonLoan.sol";
import {Don} from "../src/market/Don.sol";

/// RehearseDons — one broadcast run proving every live mechanic on the deployed stack:
///   custom-mint (ETH fee) -> AMM buy (price+8%) -> borrow 50% LTV against the bought Don ->
///   repay in full (interest -> reserve, lien released) -> AMM sell (price-8%).
/// Reverts loudly if any leg misbehaves; logs the numbers for the ops record.
contract RehearseDons is Script {
    function run() external {
        DonDistributor dist = DonDistributor(vm.envAddress("DISTRIBUTOR"));
        DonReserve reserve = DonReserve(vm.envAddress("RESERVE"));
        DonExchange exchange = DonExchange(vm.envAddress("EXCHANGE"));
        DonLoan loan = DonLoan(vm.envAddress("LOAN"));
        IERC20 essey = IERC20(vm.envAddress("ESSEY"));
        Don don = dist.don();

        vm.startBroadcast();

        // 1. $10 custom mint, exact ETH fee, chosen combo.
        bytes32 combo = keccak256(abi.encode("rehearsal", block.timestamp));
        uint256 mintId = dist.mintCustom{value: dist.customFee()}(combo);
        require(don.traits(mintId) == combo, "traits mismatch");

        // 2. AMM buy at the live price + 8% (bounded).
        uint256 p = exchange.price();
        uint256 cost = p + exchange.feeOn(800);
        essey.approve(address(exchange), cost);
        uint256 boughtId = exchange.buy(cost);

        // 3. Fixed-draw borrow against the bought Don at the minimum term - it stays in the wallet,
        //    liened; the floor-priced term interest comes out of the disbursement (discount note).
        uint256 principal = loan.maxBorrow(); // the draw every loan takes
        loan.borrow(boughtId, loan.MIN_TERM());
        require(don.liened(boughtId), "not liened");
        require(don.ownerOf(boughtId) == msg.sender, "left wallet");

        // 4. Repay in full - the full principal is owed (interest was prepaid), lien releases.
        essey.approve(address(loan), principal * 101 / 100);
        loan.repay(boughtId, type(uint256).max);
        require(!don.liened(boughtId), "lien stuck");
        require(loan.debtOf(boughtId) == 0, "debt stuck");

        // 5. Sell the minted Don back to the desk at price - 8% (bounded).
        uint256 net = exchange.price() - exchange.feeOn(800);
        don.approve(address(exchange), mintId);
        exchange.sell(mintId, net);
        require(don.ownerOf(mintId) == address(exchange), "sell failed");

        vm.stopBroadcast();

        console.log("REHEARSAL PASSED");
        console.log("minted id      ", mintId);
        console.log("bought id      ", boughtId);
        console.log("borrowed       ", principal / 1e18, "ESSEY");
        console.log("sell net       ", net / 1e18, "ESSEY");
        console.log("floor now      ", reserve.floorPerDon() / 1e18, "ESSEY");
    }
}
