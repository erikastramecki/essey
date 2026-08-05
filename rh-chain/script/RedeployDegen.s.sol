// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Redeploy EsseyCasesDegen with the SHARE-denominated reference (open 24/7, no oracle). Standalone:
// reuses the live Bell / $ESSEY / AAPL / MockEntropy (so the existing degen-keeper settles it) and the
// same ladder + fee config as the deployed degen. Reference is 0.5 AAPL at 1x (== the old $100 @ $200
// worst case: 25 AAPL reserved at 50x). Seeds the reserve.
//
//   PK=$TESTNET_DEPLOYER_PK forge script script/RedeployDegen.s.sol --rpc-url rh_testnet --broadcast \
//     --private-key $PK --gas-estimate-multiplier 300
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bell} from "../src/market/Bell.sol";
import {EsseyCasesDegen, IEntropy} from "../src/market/EsseyCasesDegen.sol";

interface IMintableMock {
    function mint(address to, uint256 amount) external;
}

contract RedeployDegen is Script {
    // live testnet (46630) addresses
    address constant ESSEY = 0x0659ECA47665Da545e1157edE11fcB4c8222879f;
    address constant BELL = 0x31115D449F359A05298295415665AF18Fd708d0d;
    address constant TREASURY = 0x976EBff4D97C14772328e5E3cf4a3aBa6D45993D;
    address constant AAPL = 0xaC6cd493e69eb82e8f113E33De8e5542F313B731;
    address constant ENTROPY = 0xb9b82A4900642A98e29F59B937FDE6B2DDaF1E6F; // existing MockEntropy (keeper watches it)
    address constant PROVIDER = 0x000000000000000000000000000000000000daCe;

    uint256 constant REFERENCE_SHARES = 5e17; // 0.5 AAPL at 1x
    uint256 constant CASE_PRICE = 100e18;
    uint256 constant BUY_FEE = 5e18;
    uint256 constant BOOSTER_BPS = 7000;
    uint32 constant CALLBACK_GAS = 200_000;
    uint256 constant RESERVE = 5_000e18;

    function run() external {
        address me = vm.addr(vm.envUint("PK")); // == treasury == bankroll
        require(me == TREASURY, "deployer must be the treasury/bankroll operator");

        uint256[] memory mult = new uint256[](5);
        mult[0] = 6500;
        mult[1] = 10000;
        mult[2] = 20000;
        mult[3] = 50000;
        mult[4] = 500000;
        uint256[] memory cum = new uint256[](5);
        cum[0] = 840000;
        cum[1] = 945000;
        cum[2] = 985000;
        cum[3] = 998000;
        cum[4] = 1000000;

        vm.startBroadcast();
        EsseyCasesDegen degen = new EsseyCasesDegen(
            EsseyCasesDegen.Config({
                essey: IERC20(ESSEY),
                bell: Bell(BELL),
                treasury: TREASURY,
                bankroll: me,
                entropy: IEntropy(ENTROPY),
                entropyProvider: PROVIDER,
                payoutStock: IERC20(AAPL),
                referenceShares: REFERENCE_SHARES,
                casePrice: CASE_PRICE,
                buyFee: BUY_FEE,
                boosterShareBps: BOOSTER_BPS,
                callbackGasLimit: CALLBACK_GAS,
                multiplierBps: mult,
                cumPpm: cum
            })
        );

        // Seed the stock reserve.
        IMintableMock(AAPL).mint(me, RESERVE);
        IERC20(AAPL).approve(address(degen), type(uint256).max);
        degen.seedReserve(RESERVE);
        vm.stopBroadcast();

        console.log("EsseyCasesDegen (24/7, share-denominated)", address(degen));
        console.log("referenceShares", degen.referenceShares());
        console.log("freeReserve", degen.freeReserve());
        console.log("maxMultiplierBps", degen.maxMultiplierBps());
    }
}
