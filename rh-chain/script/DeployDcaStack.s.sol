// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TESTNET: deploy the DCA settlement stack. A fresh (already-audited) BundleConverter whose SOLE convert
// caller is RecurringBuy — so RecurringBuy is the DCA's oracle-fair, session-gated, reserve-backed stock
// desk. (On mainnet, RecurringBuy instead points at the real Uniswap-swap StockConverter.) Reuses the
// feed-kept AAPL/NVDA/USDG feeds so prices stay fresh.
//
//   USDG=$TESTNET_USDG USDG_FEED=$TESTNET_USDG_FEED AAPL=0xaC6c... NVDA=0x8393... \
//   forge script script/DeployDcaStack.s.sol --rpc-url rh_testnet --broadcast --private-key $PK \
//     --gas-estimate-multiplier 250
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {BundleConverter} from "../src/market/BundleConverter.sol";
import {RecurringBuy, IStockConverter} from "../src/market/RecurringBuy.sol";

contract DeployDcaStack is Script {
  // The feed-kept feeds (refreshed by the existing keeper), same ones Cases/the pool use.
  address constant AAPL_FEED = 0x01F40F92A83A2184b7C69eCE9a870A5f1420c08f;
  address constant NVDA_FEED = 0x8Fe3f8BCC2450a4c63e61ABDD93A17f8783319B9;
  uint256 constant SEED = 5_000e18; // per-stock reserve, generous for a testnet playground

  function run() external {
    address usdg = vm.envAddress("USDG");
    address usdgFeed = vm.envAddress("USDG_FEED");
    address aapl = vm.envAddress("AAPL");
    address nvda = vm.envAddress("NVDA");
    address sequencer = vm.envOr("SEQUENCER_FEED", address(0));

    vm.startBroadcast();
    // Reserve-based converter (no Uniswap needed on testnet); bankroll + treasury = broadcaster.
    BundleConverter conv = new BundleConverter(
      IERC20(usdg), AggregatorV3Interface(usdgFeed), AggregatorV3Interface(sequencer), msg.sender, msg.sender, 0
    );
    conv.listStock(aapl, AggregatorV3Interface(AAPL_FEED));
    conv.listStock(nvda, AggregatorV3Interface(NVDA_FEED));

    // Seed the stock reserve (mint mock stock → approve → seed).
    ERC20Mock(aapl).mint(msg.sender, SEED);
    ERC20Mock(nvda).mint(msg.sender, SEED);
    ERC20Mock(aapl).approve(address(conv), type(uint256).max);
    ERC20Mock(nvda).approve(address(conv), type(uint256).max);
    conv.seedReserve(aapl, SEED);
    conv.seedReserve(nvda, SEED);

    // Deploy the DCA and wire it as the converter's SOLE convert caller (one-shot).
    RecurringBuy rb = new RecurringBuy(IERC20(usdg), IStockConverter(address(conv)));
    conv.initBell(address(rb));
    vm.stopBroadcast();

    console.log("DcaConverter ", address(conv));
    console.log("RecurringBuy ", address(rb));
    console.log("  aapl reserve", conv.reserveOf(aapl));
    console.log("  nvda reserve", conv.reserveOf(nvda));
  }
}
