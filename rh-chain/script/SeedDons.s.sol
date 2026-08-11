// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonExchange} from "../src/market/DonExchange.sol";
import {DonLoan} from "../src/market/DonLoan.sol";
import {Don} from "../src/market/Don.sol";

/// SeedDons — the founder-approved post-deploy ops for a freshly deployed Dons stack (testnet rehearsal
/// sizes by default; mainnet re-runs with env overrides). Broadcaster must be the admin/treasury EOA
/// (testnet) holding the $ESSEY supply.
///
///   1. fund DonReserve  (RESERVE_FUND, default 2,666,666,666e18 -> the 300k floor)
///   2. fund DonLoan     (LOAN_FUND, default 100,000,000e18 rehearsal pot)
///   3. mintReserved SEED_COUNT Dons (default 50; mainnet ops run the full 2,222 in batches) + seed
///      the exchange with them
///   4. proposeRoot(0, WL_ROOT) if set (commitRoot after the 2-day timelock, separately)
///   5. setPublicOpen(true) - the $10 custom mint goes live
contract SeedDons is Script {
    function run() external {
        DonDistributor dist = DonDistributor(vm.envAddress("DISTRIBUTOR"));
        DonReserve reserve = DonReserve(vm.envAddress("RESERVE"));
        DonExchange exchange = DonExchange(vm.envAddress("EXCHANGE"));
        DonLoan loan = DonLoan(vm.envAddress("LOAN"));
        IERC20 essey = IERC20(vm.envAddress("ESSEY"));
        uint256 reserveFund = vm.envOr("RESERVE_FUND", uint256(2_666_666_666e18));
        uint256 loanFund = vm.envOr("LOAN_FUND", uint256(100_000_000e18));
        uint256 seedCount = vm.envOr("SEED_COUNT", uint256(50));
        bytes32 wlRoot = vm.envOr("WL_ROOT", bytes32(0));

        Don don = dist.don();
        vm.startBroadcast();

        if (reserveFund > 0) {
            essey.approve(address(reserve), reserveFund);
            reserve.fund(reserveFund);
        }
        if (loanFund > 0) {
            essey.approve(address(loan), loanFund);
            loan.fund(loanFund);
        }

        if (seedCount > 0) {
            bytes32[] memory combos = new bytes32[](seedCount);
            uint256 base = don.totalMinted();
            for (uint256 i = 0; i < seedCount; i++) {
                combos[i] = keccak256(abi.encode("amm-float", base + i + 1));
            }
            dist.mintReserved(msg.sender, combos); // to the broadcaster (the seeder on testnet)
            uint256[] memory ids = new uint256[](seedCount);
            for (uint256 i = 0; i < seedCount; i++) ids[i] = base + i + 1;
            don.setApprovalForAll(address(exchange), true);
            exchange.seed(ids);
        }

        if (wlRoot != bytes32(0)) dist.proposeRoot(0, wlRoot);
        dist.setPublicOpen(true);

        vm.stopBroadcast();

        console.log("floorPerDon    ", reserve.floorPerDon() / 1e18, "ESSEY");
        console.log("exchange price ", exchange.price() / 1e18, "ESSEY");
        console.log("loan pot       ", loan.lendable() / 1e18, "ESSEY");
        console.log("maxBorrow/Don  ", loan.maxBorrow() / 1e18, "ESSEY");
        console.log("inventory      ", exchange.inventoryCount());
        console.log("publicOpen     ", dist.publicOpen());
    }
}
