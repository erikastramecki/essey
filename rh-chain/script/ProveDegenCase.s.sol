// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Proves the degen (multiplier) case flow on-chain: buy a case, have the keeper settle the roll, and
// assert winnings were credited. Must run in a US market session (buy locks the stock price).
//
//   DEGEN=.. ESSEY=.. USDG=.. DEGEN_ENTROPY=.. \
//   forge script script/ProveDegenCase.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {EsseyCasesDegen} from "../src/market/EsseyCasesDegen.sol";
import {MockEntropy} from "../src/testnet/MockEntropy.sol";

contract ProveDegenCase is Script {
    function run() external {
        address me = vm.addr(vm.envUint("PK"));
        EsseyCasesDegen degen = EsseyCasesDegen(vm.envAddress("DEGEN"));
        IERC20 essey = IERC20(vm.envAddress("ESSEY"));
        ERC20Mock usdg = ERC20Mock(vm.envAddress("USDG"));
        MockEntropy oracle = MockEntropy(vm.envAddress("DEGEN_ENTROPY"));

        vm.startBroadcast();
        usdg.mint(me, 1000e18); // buy fee currency ($ESSEY case price comes from the treasury supply we hold)
        essey.approve(address(degen), type(uint256).max);
        usdg.approve(address(degen), type(uint256).max);
        uint256 fee = degen.entropyFee();
        uint64 seq = degen.buy{value: fee}(); // roll a case
        oracle.fulfill(seq); // keeper settles it (separate tx)
        vm.stopBroadcast();

        uint256 owed = degen.owed(me);
        console.log("degen seq", seq);
        console.log("winnings credited (AAPL, 18-dec)", owed);
        require(owed > 0, "DEGEN PROOF FAILED: no winnings credited after settle");
        console.log("DEGEN PROOF PASSED: buy -> keeper settle -> winnings credited to owed[].");
    }
}
