// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// Deploys the stack to Robinhood Chain and wires one market.
///
///   forge script script/Deploy.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
///   forge script script/Deploy.s.sol --rpc-url rh_mainnet --broadcast --private-key $PK
///
/// EVERY ADDRESS AND DECIMAL IS READ FROM THE CHAIN, NOT TRUSTED FROM CONFIG. The worst bug this
/// codebase has had was a decimals mismatch that made every LTV limit 1e12 too permissive, and it
/// survived because a value was assumed rather than checked. `collateralDecimals` and the feed's
/// decimals are therefore queried from the live contracts and asserted here, so a fat-fingered
/// config cannot reach a deployed market.
contract Deploy is Script {
    // Robinhood Chain mainnet (4663). On testnet (46630) pass overrides via env. Feeds are Chainlink
    // AggregatorPROXY addresses (stable across aggregator rotations) — REQUIRED because the market feed is
    // append-only, so a retired raw aggregator would strand the market. (Verified: AAPL feed .aggregator()
    // returns a distinct address, i.e. it is a proxy.)
    address constant USDG_MAINNET = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_MAINNET = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED_MAINNET = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant NVDA_MAINNET = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_FEED_MAINNET = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    /// Own frame: run() is at the stack ceiling, and the reserve-routing config belongs together.
    /// Bell wiring via env (BELL_SINK=0 -> everything to the treasury; mainnet passes the Bell +
    /// BELL_SHARE_BPS=5000). The constructor proves reward coherence, so a mis-wired sink is un-deployable.
    ///
    /// RATES (mainnet-config fix): default to a live curve — 10% base APR (BASE_BPS=1000), 20% reserve
    /// factor (RESERVE_BPS=2000). A zero-rate mainnet pool accrues no interest and funds neither lenders
    /// nor the Bell; override via env only deliberately.
    /// One pool per collateral: the isolated-pool model (F1) binds each pool to a single Stock Token at
    /// construction and admits exactly one active pool per market, so AAPL and NVDA get their own pools.
    function _deployPool(address usdg, address collateral, EsseyMarkets markets, address admin, string memory sym)
        internal
        returns (EsseyPool)
    {
        return new EsseyPool(
            IERC20(usdg), collateral, markets,
            vm.envOr("BASE_BPS", uint256(1_000)),
            vm.envOr("SLOPE1_BPS", uint256(0)),
            vm.envOr("SLOPE2_BPS", uint256(0)),
            vm.envOr("RESERVE_BPS", uint256(2_000)),
            vm.envOr("BELL_SINK", address(0)),
            vm.envOr("RESERVE_TREASURY", admin),
            vm.envOr("BELL_SHARE_BPS", uint256(0)),
            EsseyPool.Identity(
                string.concat("Essey ", sym, " Pool Share"), string.concat("a", sym),
                string.concat("Essey ", sym, " Note"), string.concat("n", sym)
            )
        );
    }

    /// Own frame (run() sits at the stack ceiling). Conservative v1 parameters — 35% LTV against a
    /// 55% liquidation threshold is the 20pp gap that has to absorb a weekend the position cannot be
    /// liquidated into.
    function _proposeMarket(
        EsseyMarkets markets,
        address stock,
        address pool,
        address feed,
        uint8 feedDec,
        uint8 stockDec,
        uint8 assetDec
    ) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true,
            ltvBps: 3_500,
            liqThresholdBps: 5_500,
            liqBonusBps: 800,
            collateralDecimals: stockDec, // read from the token, never typed by hand
            cap: uint128(vm.envOr("MARKET_CAP", uint256(10_000)) * (10 ** assetDec)),
            maxPositionBps: 2_000 // 20% of cap per position; per-market, tunable later via the timelock
        });
        // Per-feed heartbeat 86_400s / maxStaleness 90_000s (the RH equity-feed profile). On RH mainnet the
        // Stock Token carries the ERC-8056 surface itself, so it is its own uiMultiplier source.
        markets.proposeMarket(stock, AggregatorV3Interface(feed), 86_400, 90_000, feedDec, stock, pool, m);
    }

    /// Read a stock + its feed decimals ON-CHAIN, assert the feed is live, deploy its dedicated pool, and
    /// propose the market. The pool constructor separately cross-checks markets.assetDecimals == USDG.decimals
    /// (impossible-by-construction), and propose+commit cross-check the collateral/feed decimals — so no
    /// decimal is trusted. Returns the pool so the deployer can log it (the multisig references it to commit).
    function _addMarket(
        address usdg,
        EsseyMarkets markets,
        address admin,
        address stock,
        address feed,
        uint8 assetDec,
        string memory sym,
        bool propose
    ) internal returns (EsseyPool pool) {
        uint8 stockDec = IERC20Metadata(stock).decimals();
        uint8 feedDec = AggregatorV3Interface(feed).decimals();
        require(stockDec > 0 && stockDec <= 36, "bad stock decimals");
        require(feedDec > 0 && feedDec <= 36, "bad feed decimals");
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0, "feed answer not positive");
        require(updatedAt > 0, "feed never updated");
        // Pools are permissionless to deploy, so the throwaway deployer stands them up even on mainnet;
        // proposeMarket is admin-only, so it runs inline only when the deployer IS the admin.
        pool = _deployPool(usdg, stock, markets, admin, sym);
        if (propose) {
            _proposeMarket(markets, stock, address(pool), feed, feedDec, stockDec, assetDec);
            console.log("  proposed market for stock", stock);
        }
    }

    function run() external {
        address usdg = vm.envOr("USDG", USDG_MAINNET);
        address admin = vm.envOr("ADMIN", msg.sender);
        address keeper = vm.envOr("KEEPER", msg.sender);
        address guardian = vm.envOr("GUARDIAN", msg.sender);
        // No Chainlink L2 sequencer uptime feed exists for this chain; address(0) skips the check and
        // LivenessOracle (keeper heartbeat) carries the risk. See the scope doc.
        address sequencer = vm.envOr("SEQUENCER_FEED", address(0));

        // MULTISIG discipline: on MAINNET (4663) admin/treasury must NOT be the throwaway deployer, and the
        // keeper (hot) must differ from the guardian (cold). Refuse to deploy control to a single EOA.
        if (block.chainid == 4663) {
            require(admin != msg.sender, "MAINNET: set ADMIN to the operator multisig");
            require(vm.envOr("RESERVE_TREASURY", msg.sender) != msg.sender, "MAINNET: set RESERVE_TREASURY to the multisig");
            require(keeper != guardian, "MAINNET: keeper (hot) must differ from guardian (cold)");
        }

        uint8 assetDec = IERC20Metadata(usdg).decimals();
        console.log("USDG decimals ", assetDec);
        require(assetDec > 0 && assetDec <= 36, "bad asset decimals");

        vm.startBroadcast();

        // 30-minute liveness bound / 15-minute gap / 30-minute post-outage grace (grace <= 4x gap guard).
        LivenessOracle liveness = new LivenessOracle(keeper, guardian, admin, 15 minutes, 30 minutes);
        // Health oracle admin is the deployer so this broadcast can wireMarkets in the same run (matching
        // DeployMarkets); its keeper posts depth, its guardian is the cold key.
        MarketHealthOracle health = new MarketHealthOracle(keeper, guardian, msg.sender);
        EsseyMarkets markets =
            new EsseyMarkets(AggregatorV3Interface(sequencer), liveness, health, admin, guardian, assetDec);
        health.wireMarkets(address(markets)); // one-shot, must run before the ramp starts

        // A dedicated pool per collateral (isolated-pool model). Pools are permissionless to deploy, so the
        // deployer stands them up even on mainnet; proposeMarket is ADMIN-only, so it runs inline only when
        // the deployer IS the admin. On mainnet the multisig proposes after deploy — pool addresses logged.
        bool selfAdmin = (admin == msg.sender);
        EsseyPool aaplPool =
            _addMarket(usdg, markets, admin, vm.envOr("STOCK", AAPL_MAINNET), vm.envOr("FEED", AAPL_FEED_MAINNET), assetDec, "AAPL", selfAdmin);
        EsseyPool nvdaPool;
        if (!vm.envOr("SKIP_NVDA", false)) {
            nvdaPool =
                _addMarket(usdg, markets, admin, vm.envOr("STOCK2", NVDA_MAINNET), vm.envOr("FEED2", NVDA_FEED_MAINNET), assetDec, "NVDA", selfAdmin);
        }

        vm.stopBroadcast();

        console.log("liveness  ", address(liveness));
        console.log("health    ", address(health));
        console.log("markets   ", address(markets));
        console.log("pool      ", address(aaplPool)); // AAPL pool — the primary; local-fork.sh reads this line
        console.log("NVDA pool ", address(nvdaPool));
        console.log("");
        if (selfAdmin) {
            console.log("Markets PROPOSED. After the 2-day timelock: commitMarket(AAPL)+commitMarket(NVDA).");
        } else {
            console.log("MULTISIG (admin) must now propose the markets against the pools above, then commit after");
            console.log("the 2-day timelock (heartbeat=86400, maxStaleness=90000, multiplierSource=stock, pool=above):");
            console.log("  proposeMarket(AAPL,AAPL_FEED,86400,90000,8,AAPL,AAPL_pool,{true,3500,5500,800,18,cap,2000})", AAPL_MAINNET);
            console.log("  proposeMarket(NVDA,NVDA_FEED,86400,90000,8,NVDA,NVDA_pool,{true,3500,5500,800,18,cap,2000})", NVDA_MAINNET);
        }
        console.log("Then: start the supervised liveness keeper (borrows AND liquidations gate on it), and");
        console.log("wire the FeeRouter + market layer per docs/MAINNET-CONFIG.md.");
    }
}
