// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Deploy the degen (multiplier) case. Env-driven so it slots onto whichever Bell:
//   BELL=0x.. ESSEY=0x.. STOCK=0x.. forge script script/DeployDegenCase.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
//
// TESTNET: deploys a MockEntropy keeper (real Dice isn't confirmed on 46630) + a $200 payout-stock
// feed, wires EsseyCasesDegen with the disclosed 0.65x-50x / ~90% RTP ladder, and seeds the reserve.
// MAINNET: pass ENTROPY=0xd8a0680e7699526b57140ed4eafdcc7219dc0a0c (Dice) + ENTROPY_PROVIDER to skip
// the mock. The payout stock is reused (e.g. the existing mock AAPL), so its reserve is minted+seeded.
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "../test/RiskModules.t.sol";
import {Bell} from "../src/market/Bell.sol";
import {EsseyCasesDegen, IEntropy} from "../src/market/EsseyCasesDegen.sol";
import {MockEntropy} from "../src/testnet/MockEntropy.sol";

contract DeployDegenCase is Script {
    uint256 constant RESERVE = 5_000e18; // payout-stock shares seeded to back payouts

    function run() external {
        address bell = vm.envAddress("BELL");
        address essey = vm.envAddress("ESSEY");
        address stock = vm.envAddress("STOCK"); // payout stock (reused mock, e.g. AAPL)
        address treasury = vm.envOr("TREASURY", msg.sender);
        address bankroll = vm.envOr("BANKROLL", msg.sender);
        address seqFeed = vm.envOr("SEQUENCER_FEED", address(0));

        vm.startBroadcast();

        // Entropy: real Dice on mainnet, else a testnet MockEntropy keeper.
        address entropy = vm.envOr("ENTROPY", address(0));
        address provider = vm.envOr("ENTROPY_PROVIDER", address(0xDACE));
        if (entropy == address(0)) {
            MockEntropy mock = new MockEntropy(0.000025 ether, provider);
            entropy = address(mock);
        }

        // Payout-stock price feed ($200/share) for reference->shares sizing.
        MockFeed stockFeed = new MockFeed(200e8, 8);

        // Ladder: 0.65x/1x/2x/5x/50x at 84% / 10.5% / 4% / 1.3% / 0.2% -> ~89.6% RTP.
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

        EsseyCasesDegen degen = new EsseyCasesDegen(
            EsseyCasesDegen.Config({
                essey: IERC20(essey),
                bell: Bell(bell),
                stockFeed: AggregatorV3Interface(address(stockFeed)),
                sequencerFeed: AggregatorV3Interface(seqFeed),
                treasury: treasury,
                bankroll: bankroll,
                entropy: IEntropy(entropy),
                entropyProvider: provider,
                payoutStock: IERC20(stock),
                referenceUsd: vm.envOr("DEGEN_REFERENCE_USD", uint256(100e18)),
                casePrice: vm.envOr("DEGEN_CASE_PRICE", uint256(100e18)),
                buyFee: vm.envOr("DEGEN_BUY_FEE", uint256(5e18)),
                boosterShareBps: vm.envOr("DEGEN_BOOSTER_BPS", uint256(7000)),
                callbackGasLimit: uint32(vm.envOr("DEGEN_CALLBACK_GAS", uint256(200_000))),
                multiplierBps: mult,
                cumPpm: cum
            })
        );

        // Seed the reserve (mint mock payout stock to the bankroll, approve, deposit).
        ERC20Mock(stock).mint(msg.sender, RESERVE);
        ERC20Mock(stock).approve(address(degen), type(uint256).max);
        degen.seedReserve(RESERVE);

        vm.stopBroadcast();

        console.log("EsseyCasesDegen ", address(degen));
        console.log("  entropy       ", entropy);
        console.log("  stockFeed     ", address(stockFeed));
        console.log("  reserve       ", degen.freeReserve());
        console.log("  maxMultiplier ", degen.maxMultiplierBps());
    }
}
