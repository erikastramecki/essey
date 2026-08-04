// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Redeploy EsseyCases with a keeper (so a settler can open a Case on the buyer's behalf -> the buyer
// signs only the buy). Standalone: reuses the live Bell/$ESSEY/USDG/treasury and the SAME AAPL/NVDA
// Chainlink feeds (so the existing feed-keeper still covers them). Relists the two stocks with the
// same unit sizes, reseeds inventory, and funds the buyback reserve. Config reproduces the live Cases
// exactly (read from chain): casePrice 100e18, buyFee 5e6, spread 500bps, booster 7000bps.
//
//   PK=$TESTNET_DEPLOYER_PK forge script script/RedeployCases.s.sol --rpc-url rh_testnet --broadcast \
//     --private-key $PK --gas-estimate-multiplier 300
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {EsseyCases} from "../src/market/EsseyCases.sol";
import {Bell} from "../src/market/Bell.sol";

interface IMintableMock {
    function mint(address to, uint256 amount) external;
}

contract RedeployCases is Script {
    // live testnet (46630) addresses
    address constant ESSEY = 0x0659ECA47665Da545e1157edE11fcB4c8222879f;
    address constant BELL = 0x31115D449F359A05298295415665AF18Fd708d0d;
    address constant USDG = 0x7461E670d44FF4397A3E48030C5b06f6163a5De2;
    address constant USDG_FEED = 0x6ac94CAb7302415A9a29d9746Fb6051523592E3b; // base leg (shared, feed-kept)
    address constant TREASURY = 0x976EBff4D97C14772328e5E3cf4a3aBa6D45993D;
    address constant AAPL = 0xaC6cd493e69eb82e8f113E33De8e5542F313B731;
    address constant NVDA = 0x8393cc99FAC1CF79E3bEceA56f344159ddFd91E9;
    address constant AAPL_FEED = 0x01F40F92A83A2184b7C69eCE9a870A5f1420c08f; // reused (feed-kept)
    address constant NVDA_FEED = 0x8Fe3f8BCC2450a4c63e61ABDD93A17f8783319B9; // reused (feed-kept)

    uint256 constant CASE_PRICE = 100e18;
    uint256 constant BUY_FEE = 5e6;
    uint256 constant SPREAD_BPS = 500;
    uint256 constant BOOSTER_BPS = 7000;
    uint256 constant UNIT_AAPL = 5e17; // 0.5 share
    uint256 constant UNIT_NVDA = 8e17; // 0.8 share
    uint256 constant AAPL_UNITS = 60;
    uint256 constant NVDA_UNITS = 40;
    uint256 constant BUYBACK = 5_000e18;

    function run() external {
        address me = vm.addr(vm.envUint("PK")); // == treasury == bankroll == keeper
        require(me == TREASURY, "deployer must be the treasury/bankroll operator");

        vm.startBroadcast();
        EsseyCases cases_ = new EsseyCases(
            IERC20(ESSEY), Bell(BELL), AggregatorV3Interface(USDG_FEED), AggregatorV3Interface(address(0)),
            TREASURY, me, CASE_PRICE, BUY_FEE, SPREAD_BPS, BOOSTER_BPS, me // last arg: keeper = the operator
        );

        cases_.listStock(AAPL, AggregatorV3Interface(AAPL_FEED), UNIT_AAPL);
        cases_.listStock(NVDA, AggregatorV3Interface(NVDA_FEED), UNIT_NVDA);

        // Seed inventory: mint the mock stock to the bankroll, approve, deposit units.
        IMintableMock(AAPL).mint(me, UNIT_AAPL * AAPL_UNITS);
        IMintableMock(NVDA).mint(me, UNIT_NVDA * NVDA_UNITS);
        IERC20(AAPL).approve(address(cases_), type(uint256).max);
        IERC20(NVDA).approve(address(cases_), type(uint256).max);
        cases_.seedUnits(AAPL, AAPL_UNITS);
        cases_.seedUnits(NVDA, NVDA_UNITS);

        // Fund the buyback reserve so sell-back works.
        IMintableMock(USDG).mint(me, BUYBACK);
        IERC20(USDG).approve(address(cases_), type(uint256).max);
        cases_.fundBuyback(BUYBACK);
        vm.stopBroadcast();

        console.log("EsseyCases (keeper-enabled)", address(cases_));
        console.log("keeper", cases_.keeper());
        console.log("inventoryCount", cases_.inventoryCount());
    }
}
