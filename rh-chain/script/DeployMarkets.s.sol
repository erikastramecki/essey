// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ConstantMultiplier} from "../src/adapters/ConstantMultiplier.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {InkFeeds} from "../src/InkFeeds.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {MockFeed} from "../src/testnet/MockFeed.sol";
import {NoteArt} from "../src/market/NoteArt.sol";
import {PoolFactory} from "../src/market/PoolFactory.sol";
import {RobinhoodFeeds} from "../src/RobinhoodFeeds.sol";
import {ScaledUIStockMock} from "../src/testnet/ScaledUIStockMock.sol";

/// WS1: a market's rate curve is a per-listing CONFIG choice, not a contract. Fixed mode is the
/// same EsseyPool with slope1 = 0 — flat at the policy rate up to the pool's kink (80% util,
/// EsseyPool.sol:108) — and slope2 KEPT nonzero as the emergency leg above it. Tydro shipped a
/// zero-slope curve and sat exposed at 87% utilization with no rate to pull liquidity back;
/// RateModes.t.sol pins that a fixed listing here can never ship that shape.
library RateModes {
    enum Mode {
        Kink,
        Fixed
    }

    struct Curve {
        uint256 baseBps;
        uint256 slope1Bps;
        uint256 slope2Bps;
    }

    uint256 internal constant EMERGENCY_SLOPE2_BPS = 6_000;

    function curve(Mode mode, uint256 policyRateBps) internal pure returns (Curve memory) {
        if (mode == Mode.Kink) {
            // A policy rate on a kink listing would be silently ignored — refuse the confusion.
            require(policyRateBps == 0, "policyRateBps is a Fixed-mode field");
            return Curve(1_000, 500, 6_000);
        }
        require(policyRateBps != 0, "a Fixed listing needs a nonzero policy rate");
        return Curve(policyRateBps, 0, EMERGENCY_SLOPE2_BPS);
    }
}

/// Mainnet-shaped stack deploy: LivenessOracle + EsseyMarkets + PoolFactory once, then per
/// `_marketList()` entry: pool + NoteArt deployed HERE, proposeMarket after — listing market #9
/// is one line. The script owns the `new`s because a deployPool factory embedding both creation
/// codes blew the EIP-170 runtime limit and aborted the broadcast. factory.register moved OUT of
/// this script (F1): it now requires the pool to BE markets.activePool, which only commitMarket
/// sets — CommitAndRehearse registers after the timelock, and the keeper discovers from its logs.
///
/// Chain differences live in `profileFor` (AD-3: config, never forked siblings). TESTNET=1 is
/// only valid on the Robinhood testnet profile and deploys the ScaledUI/MockFeed fixtures;
/// RobinhoodMainnet takes USDG + `<SYMBOL>_TOKEN` from env with feeds from RobinhoodFeeds; Ink
/// is SCAFFOLDING — compiled and fork-simulatable, not yet deployed — and takes every token and
/// feed address from INK_* env vars that must also match the InkFeeds record (see that file).
///
/// NOTE ON TIMING, because it decides the schedule: `proposeMarket` starts a `PARAM_TIMELOCK`
/// = 2 day clock and there is no constructor seeding, by design. Collateral cannot be borrowed
/// against until `commitMarket` two days later. Deploying earlier does not shorten it; only
/// proposing earlier does.
contract DeployMarkets is Script {
    uint8 constant FEED_DECIMALS = 8;

    struct Profile {
        string name;
        bool testnet;
        /// Robinhood Stock Tokens carry the ERC-8056 surface themselves; Backed's Ink 4626
        /// wrapper does not, so an Ink stack deploys one ConstantMultiplier and lists it instead.
        bool multiplierIsToken;
        /// Asserted against the on-chain decimals() before any broadcast (the 1e12 lesson).
        uint8 usdgDecimals;
        uint32 heartbeat;
        uint32 maxStaleness;
        address usdg; // address(0) = from the USDG env var (or a testnet mock)
        address seqFeed; // address(0) = SEQUENCER_UPTIME_FEED env var, else DISABLED with a loud banner
    }

    function profileFor(uint256 chainid) public pure returns (Profile memory) {
        if (chainid == 4_663) {
            return Profile(
                "RobinhoodMainnet", false, true, 6, RobinhoodFeeds.HEARTBEAT,
                RobinhoodFeeds.RECOMMENDED_MAX_STALENESS, address(0), address(0)
            );
        }
        if (chainid == 46_630) {
            return Profile(
                "RobinhoodTestnet", true, true, 6, RobinhoodFeeds.HEARTBEAT,
                RobinhoodFeeds.RECOMMENDED_MAX_STALENESS, address(0), address(0)
            );
        }
        if (chainid == 57_073) {
            return Profile(
                "Ink", false, false, 6, InkFeeds.HEARTBEAT, InkFeeds.RECOMMENDED_MAX_STALENESS,
                InkFeeds.USDG, InkFeeds.SEQUENCER_UPTIME
            );
        }
        revert("no deploy profile for this chain id");
    }

    /// Every privileged key the stack bakes in. Read and CHECKED before any broadcast (G-LEND MED-2).
    struct Roles {
        address guardian;
        address livenessKeeper;
        address livenessGuardian;
        address depthKeeper;
        address reserveTreasury;
    }

    /// One role key. On a non-testnet profile it MUST be set and MUST NOT be the deploy key.
    ///
    /// The previous version console.log'd a warning and broadcast anyway, which is not a control:
    /// EsseyMarkets.guardian and EsseyPool.reserveTreasury are immutable, so a single-key posture
    /// shipped once is shipped forever — one key that was market admin, market guardian, liveness
    /// keeper, liveness guardian, depth keeper, health admin AND the reserve treasury.
    function _roleKey(string memory name, address a, bool mainnet) internal view returns (address) {
        if (!mainnet) return a == address(0) ? msg.sender : a;
        require(a != address(0), string.concat(name, " is required on mainnet - refusing to deploy"));
        require(a != msg.sender, string.concat(name, " must not be the deploy key - refusing to deploy"));
        return a;
    }

    function _roles(bool testnet) internal view returns (Roles memory) {
        return _checkRoles(
            testnet,
            Roles({
                guardian: vm.envOr("GUARDIAN", address(0)),
                livenessKeeper: vm.envOr("LIVENESS_KEEPER", address(0)),
                livenessGuardian: vm.envOr("LIVENESS_GUARDIAN", address(0)),
                depthKeeper: vm.envOr("DEPTH_KEEPER", address(0)),
                reserveTreasury: vm.envOr("RESERVE_TREASURY", address(0))
            })
        );
    }

    /// The RULE, separated from the lookup so a test can exercise it without mutating the process
    /// environment — `vm.setEnv` is global and forge runs test cases concurrently, so an env-driven
    /// test of this races every other suite.
    function _checkRoles(bool testnet, Roles memory r) internal view returns (Roles memory) {
        bool mainnet = !testnet;
        r.guardian = _roleKey("GUARDIAN", r.guardian, mainnet);
        r.livenessKeeper = _roleKey("LIVENESS_KEEPER", r.livenessKeeper, mainnet);
        r.livenessGuardian = _roleKey("LIVENESS_GUARDIAN", r.livenessGuardian, mainnet);
        r.depthKeeper = _roleKey("DEPTH_KEEPER", r.depthKeeper, mainnet);
        r.reserveTreasury = _roleKey("RESERVE_TREASURY", r.reserveTreasury, mainnet);
        // The liveness guardian's only power is rotating the liveness keeper. Held by the same
        // address, that rotation is not a recovery path from anything.
        require(
            testnet || r.livenessKeeper != r.livenessGuardian,
            "LIVENESS_KEEPER must not be its own guardian - refusing to deploy"
        );
        return r;
    }

    struct MarketCfg {
        string symbol;
        string tokenEnv; // env var naming the collateral token; ignored under TESTNET=1
        address feed; // ignored under TESTNET=1
        int256 mockPrice; // testnet feed seed, FEED_DECIMALS decimals
        RateModes.Mode mode;
        uint256 policyRateBps; // Fixed mode only; no market ships fixed yet — the founder picks per listing
    }

    function _marketList(uint256 chainid) internal view returns (MarketCfg[] memory list) {
        if (chainid == 57_073) return _inkList();
        list = new MarketCfg[](2);
        list[0] = MarketCfg("AAPL", "AAPL_TOKEN", RobinhoodFeeds.AAPL_USD, 200e8, RateModes.Mode.Kink, 0);
        list[1] = MarketCfg("NVDA", "NVDA_TOKEN", RobinhoodFeeds.NVDA_USD, 125e8, RateModes.Mode.Kink, 0);
    }

    function _inkList() internal view returns (MarketCfg[] memory list) {
        list = new MarketCfg[](3);
        list[0] = _inkMarket("wNVDAx", "INK_WNVDAX_TOKEN", "INK_WNVDAX_FEED", InkFeeds.WNVDAX_USD);
        list[1] = _inkMarket("wSPYx", "INK_WSPYX_TOKEN", "INK_WSPYX_FEED", InkFeeds.WSPYX_USD);
        list[2] = _inkMarket("wQQQx", "INK_WQQQX_TOKEN", "INK_WQQQX_FEED", InkFeeds.WQQQX_USD);
    }

    /// Two independent sources must agree before an Ink feed is used: the env var (a fresh
    /// verification act at deploy time — missing = revert) and the InkFeeds record (a moved
    /// feed forces a reviewed edit there). Neither alone can put an address on chain.
    function _inkMarket(string memory symbol, string memory tokenEnv, string memory feedEnv, address recorded)
        internal
        view
        returns (MarketCfg memory)
    {
        address feed = vm.envAddress(feedEnv);
        require(feed == recorded, string.concat(feedEnv, " does not match the InkFeeds record - re-verify both"));
        return MarketCfg(symbol, tokenEnv, feed, 0, RateModes.Mode.Kink, 0);
    }

    function run() external {
        bool testnet = vm.envOr("TESTNET", uint256(0)) == 1;
        Profile memory prof = profileFor(block.chainid);
        // A TESTNET flag pointed at the wrong RPC must die before any broadcast (C-L4).
        require(prof.testnet == testnet, "chain id does not match the TESTNET flag");
        address seqFeed = prof.seqFeed == address(0) ? vm.envOr("SEQUENCER_UPTIME_FEED", address(0)) : prof.seqFeed;

        address usdg = prof.usdg;
        if (!testnet) {
            if (usdg == address(0)) usdg = vm.envAddress("USDG");
            // Read the chain BEFORE broadcasting anything: a wrong assetDecimals is the 1e12
            // over-valuation drain, and the pool constructor would only catch it after the
            // registry is already on-chain.
            require(
                IERC20Metadata(usdg).decimals() == prof.usdgDecimals,
                "USDG.decimals() on-chain != profile - refusing to deploy"
            );
        }

        // Before the broadcast, so a missing or shared key costs nothing but a re-run.
        Roles memory roles = _roles(prof.testnet);

        vm.startBroadcast();

        if (testnet) {
            // Chainlink L2 sequencer uptime shape: 0 = up. A price feed here reads as "down".
            if (seqFeed == address(0)) seqFeed = address(new MockFeed(FEED_DECIMALS, 0));
            usdg = address(new ScaledUIStockMock("Mock USDG", "USDG"));
        }
        uint8 assetDecimals = IERC20Metadata(usdg).decimals();

        // gapThreshold 900s is BOTH the outage bound and the liveness bound (G-LEND HIGH-1: two
        // bounds meant a 25-hour window in which a halted chain was still liquidatable-into). It
        // implies a 5-minute keeper cadence — gapThreshold / 3 — which is what keeper/liveness-keeper.mjs
        // already runs. resumeGrace 1h is Chainlink's recommended sequencer grace and exactly the
        // 4x gapThreshold ceiling the constructor enforces.
        LivenessOracle liveness = new LivenessOracle(roles.livenessKeeper, roles.livenessGuardian, 900, 1 hours);
        // AD-2: markets sit at borrowCap 0 until the depth keeper posts and the raise matures.
        MarketHealthOracle health = new MarketHealthOracle(roles.depthKeeper, roles.guardian, msg.sender);
        EsseyMarkets markets = new EsseyMarkets(
            AggregatorV3Interface(seqFeed), liveness, health, msg.sender, roles.guardian, assetDecimals
        );
        // The oracle's from-zero ramp base is 0 until wired: same broadcast, always.
        health.wireMarkets(address(markets));
        PoolFactory factory = new PoolFactory(markets);
        address sharedMultiplier = prof.multiplierIsToken ? address(0) : address(new ConstantMultiplier());

        MarketCfg[] memory list = _marketList(block.chainid);
        for (uint256 i = 0; i < list.length; i++) {
            _listMarket(markets, usdg, assetDecimals, prof, sharedMultiplier, roles.reserveTreasury, list[i]);
        }

        // LivenessOracle starts CLOSED and treats the first heartbeat as a gap, so it serves out
        // `resumeGrace` before liquidations — and therefore borrows — are allowed. Without this the
        // stack deploys, the timelock elapses, and canBorrow is STILL false with nothing saying why.
        // Only the keeper may post it, and on mainnet that is deliberately not the deploy key.
        if (roles.livenessKeeper == msg.sender) liveness.heartbeat();

        vm.stopBroadcast();

        if (markets.sequencerCheckDisabled()) {
            console.log("");
            console.log("!!! SEQUENCER CHECK DISABLED: SEQUENCER_UPTIME_FEED resolved to address(0) !!!");
            console.log("!!! compensating controls REQUIRED - 20pp risk gap + liveness keeper       !!!");
            console.log("!!! (StaleFeedGuard.sol documents both). Set the env var if a feed exists. !!!");
            console.log("");
        }
        console.log("profile   ", prof.name);
        console.log("liveness  ", address(liveness));
        console.log("markets   ", address(markets));
        console.log("admin     ", msg.sender);
        console.log("guardian  ", roles.guardian);
        console.log("liv keeper", roles.livenessKeeper);
        console.log("liv guard ", roles.livenessGuardian);
        console.log("depth keep", roles.depthKeeper);
        console.log("reserve tr", roles.reserveTreasury);
        console.log("factory   ", address(factory));
        console.log("usdg      ", usdg);
        if (roles.livenessKeeper != msg.sender) {
            console.log("LIVENESS_KEEPER must post the FIRST heartbeat - resumeGrace starts there, not at deploy");
        }
        console.log("commitMarket callable in 2 days");
        console.log("AT COMMIT: factory.register(token, pool) per market (CommitAndRehearse does");
        console.log("both) - register requires activePool, which only the commit sets.");
        console.log("THEN, before the first borrow can succeed:");
        console.log("  1. wait out LivenessOracle resumeGrace (1 hour from the heartbeat above)");
        console.log("  2. RE-STAMP the feeds - the 2-day timelock outlives their 25h staleness limit");
        console.log("  3. US market session must be open (14:30-20:00 UTC, weekday)");
    }

    function _listMarket(
        EsseyMarkets markets,
        address usdg,
        uint8 assetDecimals,
        Profile memory prof,
        address sharedMultiplier,
        address reserveTreasury,
        MarketCfg memory cfg
    ) internal {
        address token;
        address feed = cfg.feed;
        if (prof.testnet) {
            token = address(new ScaledUIStockMock(string.concat("Mock ", cfg.symbol), cfg.symbol));
            feed = address(new MockFeed(FEED_DECIMALS, cfg.mockPrice));
        } else {
            token = vm.envAddress(cfg.tokenEnv);
        }

        RateModes.Curve memory c = RateModes.curve(cfg.mode, cfg.policyRateBps);
        EsseyPool pool = new EsseyPool(
            IERC20(usdg), token, markets, c.baseBps, c.slope1Bps, c.slope2Bps, 1000, address(0), reserveTreasury, 0,
            _identity(cfg.symbol)
        );
        pool.setNoteArt(address(new NoteArt(pool, pool.note())));
        _propose(
            markets, token, feed, assetDecimals, prof, sharedMultiplier == address(0) ? token : sharedMultiplier,
            address(pool)
        );

        console.log(string.concat(cfg.symbol, " token "), token);
        console.log(string.concat(cfg.symbol, " feed  "), feed);
        console.log(string.concat(cfg.symbol, " pool  "), address(pool));
    }

    function _identity(string memory sym) internal pure returns (EsseyPool.Identity memory) {
        return EsseyPool.Identity(
            string.concat("Essey ", sym, " Pool Share"), string.concat("a", sym),
            string.concat("Essey ", sym, " Note"), string.concat("n", sym)
        );
    }

    /// 50% LTV, liquidate at 75%, 5% liquidator bonus, 250k cap in borrow-asset units. The
    /// 25-point gap clears MIN_RISK_GAP_BPS; a tighter one is rejected by _validate. Decimals
    /// are read from the contracts, and commitMarket re-asserts them against the chain.
    function _propose(
        EsseyMarkets markets,
        address token,
        address feed,
        uint8 assetDecimals,
        Profile memory prof,
        address multiplierSource,
        address pool
    ) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true,
            ltvBps: 5000,
            liqThresholdBps: 7500,
            liqBonusBps: 500,
            collateralDecimals: IERC20Metadata(token).decimals(),
            cap: uint128(250_000 * 10 ** assetDecimals),
            maxPositionBps: 2_000 // 20% of cap per position (the architecture spec's example); per-market, tunable later via the normal timelock
        });
        markets.proposeMarket(
            token, AggregatorV3Interface(feed), prof.heartbeat, prof.maxStaleness,
            AggregatorV3Interface(feed).decimals(), multiplierSource, pool, m
        );
    }
}
