// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Mainnet-calibrated EsseyCasesDegen — the GAME-MAINNET-ECONOMY-SCOPE fixes #2 + #3 as DEPLOY ARGS
// (the ladder, reference and price are immutable constructor args, so calibration is config, not code):
//
//   #2 value-faucet fix: price the play IN THE PAYOUT ASSET (essey == payoutStock == the real stock).
//       Price and payout then share one unit, so value-RTP = E[payout]/casePrice is oracle-free and the
//       constructor pins it <= 100% (rejects casePrice < expectedPayoutShares). Pricing in $ESSEY —
//       which launches ~$0.0000281 — would make a 100-$ESSEY price a ~36,000% value faucet; that is the
//       config this replaces. Fee stays in USDG (Bell.reward()), which must differ from the payout asset.
//   #3 seed calibration: top tier 50x -> 10x and reference 0.5 -> 0.02 stock unit. Worst-case reservation
//       per open falls 25 -> 0.2 stock unit (ref x 10), a ~125x seed cut; a ~5-unit seed runs ~2,000 opens.
//
// House edge (this ladder): E[multiplier] = 0.816x, so casePrice == referenceShares => value RTP 81.6%
// (+18.4% edge). To retune toward ~90% the ECONOMIST redistributes the bands or lowers casePrice toward
// expectedPayoutShares; the constructor guard holds the solvency floor either way. RTP is the economist's
// dial — this script only ships the calibrated, structurally-safe defaults.
//
// NOT a mainnet deploy. The founder runs the broadcast. Verify DEGEN_STOCK/BELL/TREASURY/BANKROLL and the
// Dice provider against the live chain first (never guess a reserve/stock address).
//   DEGEN_STOCK=0x.. BELL=0x.. TREASURY=0x.. BANKROLL=0x.. ENTROPY_PROVIDER=0x.. \
//   forge script script/DeployDegenMainnet.s.sol:DeployDegenMainnet --rpc-url rh_mainnet \
//     --private-key $PK --broadcast --gas-estimate-multiplier 300
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bell} from "../src/market/Bell.sol";
import {EsseyCasesDegen, IEntropy} from "../src/market/EsseyCasesDegen.sol";

contract DeployDegenMainnet is Script {
    // Dice Protocol (Pyth-Entropy) on Robinhood Chain — the request-side oracle.
    address constant DICE_ENTROPY = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;

    // --- calibrated economic args (fix #3) ---
    uint256 constant REFERENCE_SHARES = 2e16; // 0.02 stock unit at 1x (was 0.5)
    uint256 constant CASE_PRICE = REFERENCE_SHARES; // priced IN the payout asset (fix #2): value RTP = E[mult] = 81.6%
    uint256 constant BUY_FEE = 0; // set the USDG buy-fee per the fee card; 0 keeps the pilot frictionless
    uint256 constant BOOSTER_BPS = 7000; // 70% of the buy fee to the Bell pot
    uint32 constant CALLBACK_GAS = 200_000;

    function run() external {
        address stock = vm.envAddress("DEGEN_STOCK"); // the real payout stock (also the price currency)
        address bell = vm.envAddress("BELL");
        address treasury = vm.envAddress("TREASURY");
        address bankroll = vm.envAddress("BANKROLL");
        address provider = vm.envAddress("ENTROPY_PROVIDER");
        address entropy = vm.envOr("ENTROPY", DICE_ENTROPY);

        // 10x-capped ladder (fix #3): 0.65x/1x/2x/5x/10x at 84% / 10.5% / 4% / 1.3% / 0.2%.
        uint256[] memory mult = new uint256[](5);
        mult[0] = 6500;
        mult[1] = 10000;
        mult[2] = 20000;
        mult[3] = 50000;
        mult[4] = 100000; // was 500000 (50x)
        uint256[] memory cum = new uint256[](5);
        cum[0] = 840000;
        cum[1] = 945000;
        cum[2] = 985000;
        cum[3] = 998000;
        cum[4] = 1000000;

        vm.startBroadcast();
        EsseyCasesDegen degen = new EsseyCasesDegen(
            EsseyCasesDegen.Config({
                essey: IERC20(stock), // price currency == payout asset => oracle-free value RTP
                bell: Bell(bell),
                treasury: treasury,
                bankroll: bankroll,
                entropy: IEntropy(entropy),
                entropyProvider: provider,
                payoutStock: IERC20(stock),
                referenceShares: REFERENCE_SHARES,
                casePrice: CASE_PRICE,
                buyFee: BUY_FEE,
                boosterShareBps: BOOSTER_BPS,
                callbackGasLimit: CALLBACK_GAS,
                multiplierBps: mult,
                cumPpm: cum
            })
        );
        vm.stopBroadcast();

        console.log("EsseyCasesDegen (mainnet, payout-asset priced)", address(degen));
        console.log("pricedInPayoutAsset", degen.pricedInPayoutAsset());
        console.log("expectedPayoutShares (E[payout], units)", degen.expectedPayoutShares());
        console.log("casePrice (units)", degen.casePrice());
        console.log("worst-case reservation / open (units)", (REFERENCE_SHARES * degen.maxMultiplierBps()) / 10_000);
        console.log("SEED the bankroll separately: ~5 stock units via seedReserve for ~2,000 opens.");
    }
}
