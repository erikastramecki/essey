// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

import {EsseyToken} from "../src/market/EsseyToken.sol";
import {Don} from "../src/market/Don.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonFeeRouter, ISwapRouter, IWETH} from "../src/market/DonFeeRouter.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {BundleConverter} from "../src/market/BundleConverter.sol";
import {IConverter} from "../src/market/IConverter.sol";

interface IPausable {
    function paused() external view returns (bool);
}

/// DonForkExtended — PHASE 2 lane B: mainnet-fork coverage of the STOCK-PAYOUT path Phase 1 left out.
///
/// Phase 1 (DonMainnetFork.t.sol) wired `converter = address(0)` (base-only Bell) and never reached a
/// ring->claim->stock-payout. This file deploys the REAL stock-payout path against the REAL Robinhood
/// Chain mainnet fork (chainId 4663, latest) and exercises the three testnet-impossible legs:
///
///   1. BundleConverter + stock payout — the Bell's fee (USDG) is converted through the REAL BundleConverter
///      into REAL tokenized AAPL/NVDA (the actual 18-dec, pausable mainnet tokens) delivered into a Don's
///      token-bound Vault, at the REAL Chainlink equity-feed price.
///   2. Full Bell ring->claim cycle — fees (real ETH -> real Uniswap flush -> USDG, plus a top-up) accrue
///      into the pot, `ring()` distributes pro-rata by tier weight, `claim()` pays each staked Don its share
///      in real stock, into its Vault, pro-rata.
///   3. Pausable fail-open — AAPL is a real pausable token. We PAUSE it mid-payout (flip the real Pausable
///      storage slot, the effect of the pauser calling `pause()`; the role holder is not enumerable on-chain)
///      and confirm the paused stock transfer reverts inside the converter, the Bell CATCHES it and FAILS
///      OPEN to USDG — the claim is never bricked and no funds are stranded. Testnet mocks can't show this.
///
/// ORACLE TIME NORMALIZATION. The equity converter only settles stock during US market hours with a fresh
/// feed. At a `latest` fork that is true only when the suite happens to run intraday. To make the
/// must-deliver-stock tests DETERMINISTIC at any wall-clock time, `_enterSession()` warps to the next
/// in-session weekday and freshens the three feeds to their REAL last prices at the warped timestamp
/// (`vm.mockCall` on `latestRoundData` only — real token, real decimals, real price magnitude, real
/// transfer). Two tests deliberately DON'T normalize: `test_realOracle_liveOutcome` runs against the
/// untouched real feeds and asserts the design-correct LIVE outcome (stock iff the market is open right
/// now), and `test_failsClosed_staleFeed_paysBase` warps the REAL feeds past staleness to prove the
/// genuine fail-closed->fail-open path. The real fee->USDG flush leg runs BEFORE any warp, honoring the
/// Phase-1 feed-freshness-vs-warp ordering.
///
/// Run:  forge test --match-path test/DonForkExtended.t.sol -vv
contract DonForkExtendedTest is Test {
    using stdStorage for StdStorage;

    // ---- REAL mainnet dependencies (see docs/MAINNET-CONFIG.md; re-verified against live chain) ----
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6-dec Global Dollar
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02
    address constant ETH_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9; // ETH/USD 8-dec
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2; // USDG/USD 8-dec
    address constant USDG_WHALE = 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a; // 500-tier pool (~1M USDG)
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9; // 18-dec pausable
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // 18-dec pausable
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0; // AAPL/USD 8-dec
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15; // NVDA/USD 8-dec

    // ---- stack ----
    EsseyToken essey;
    DonDistributor dist;
    Don don;
    DonReserve reserve;
    Bell bell;
    BundleConverter conv;
    DonFeeRouter feeRouter;

    address deployer; // admin == treasury == bankroll == seeder (single controlled actor)
    address guardian;

    uint256 constant RESERVE_FUND = 2_666_666_666e18; // -> ~300k floor at 8888 cap
    uint256 constant CUSTOM_FEE = 0.0053 ether;
    uint256 constant MIN_RING = 10e6; // 10 USDG (6-dec)

    // real feed prices captured at fork, reused when we freshen feeds under warp
    int256 usdgPx;
    int256 aaplPx;
    int256 nvdaPx;

    function setUp() public {
        // Fork at latest by default. The public RH RPC is heavily rate-limited (HTTP 429) and NOT an
        // archive node, so running all tests against `latest` re-fetches state per test and trips the
        // limiter. Set FORK_BLOCK to a RECENT block (e.g. the current latest) so every test shares ONE
        // block and Foundry's on-disk RPC cache serves the repeats — run with `-j 1` to serialize bursts.
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(vm.rpcUrl("rh_mainnet"));
        } else {
            vm.createSelectFork(vm.rpcUrl("rh_mainnet"), pin);
        }
        deployer = makeAddr("deployer");
        guardian = makeAddr("guardian");

        (, usdgPx,,,) = AggregatorV3Interface(USDG_FEED).latestRoundData();
        (, aaplPx,,,) = AggregatorV3Interface(AAPL_FEED).latestRoundData();
        (, nvdaPx,,,) = AggregatorV3Interface(NVDA_FEED).latestRoundData();

        _deployAndWire();
    }

    // ============================================================ DEPLOY + WIRE (converter path)

    function _deployAndWire() internal {
        (uint256[] memory fees, uint256[] memory weights) = _ladder();

        vm.startPrank(deployer);
        essey = new EsseyToken(deployer);
        dist = new DonDistributor(deployer, 2722, 2 days, 0.0016 ether, CUSTOM_FEE, 0);
        don = new Don("Essey Dons", "DON", 8888, address(dist), deployer, 500);
        reserve = new DonReserve(IERC20(address(essey)), IERC721(address(don)));

        // The REAL BundleConverter: USDG base priced by the real USDG/USD feed, spreadBps = 0 (full value),
        // bankroll = treasury = deployer, no sequencer feed (RH chain has none — keeper substitute).
        conv = new BundleConverter(
            IERC20(USDG), AggregatorV3Interface(USDG_FEED), AggregatorV3Interface(address(0)), deployer, deployer, 0
        );
        // List AAPL/NVDA against their REAL Chainlink feeds and add both to the default BUNDLE.
        conv.listStock(AAPL, AggregatorV3Interface(AAPL_FEED));
        conv.listStock(NVDA, AggregatorV3Interface(NVDA_FEED));
        conv.addBundleMember(AAPL);
        conv.addBundleMember(NVDA);

        // Bell wired to the converter with defaultPayout = BUNDLE (the decided mainnet shape: stock default,
        // USDG opt-out). tip = 0 for clean pro-rata accounting.
        bell = new Bell(
            ISeatLike(address(don)), IERC20(address(essey)), IERC20(USDG), deployer, MIN_RING, 0, fees, weights,
            IConverter(address(conv)), conv.BUNDLE()
        );
        conv.initBell(address(bell)); // gate convert() to this Bell (one-shot)

        feeRouter = new DonFeeRouter(
            DonFeeRouter.Config({
                essey: IERC20(address(essey)),
                usdg: IERC20(USDG),
                weth: IWETH(WETH),
                bell: address(bell),
                admin: deployer,
                router: ISwapRouter(ROUTER),
                ethPoolFee: 3000,
                esseyPoolFee: 3000,
                minOutBps: 9700,
                ethFeed: AggregatorV3Interface(ETH_FEED),
                usdgFeed: AggregatorV3Interface(USDG_FEED),
                sequencerUptimeFeed: AggregatorV3Interface(address(0))
            })
        );

        // wiring
        dist.initDon(don);
        dist.setDonHook(address(bell));
        dist.setBell(address(bell));
        dist.setFeeSink(address(feeRouter));
        dist.setTreasury(deployer);
        essey.approve(address(reserve), RESERVE_FUND);
        reserve.fund(RESERVE_FUND);
        dist.setPublicOpen(true);
        vm.stopPrank();

        // Seed the converter's stock reserves with REAL AAPL/NVDA (cheatcode-minted balances; ZERO real
        // money). Mainnet ops acquire real stock to seedReserve — the standing B2 finding; here `deal`
        // stands in for that acquisition so the fork can exercise the real transfer path end to end.
        _seedStock(AAPL, 100_000e18);
        _seedStock(NVDA, 100_000e18);
    }

    function _seedStock(address token, uint256 amount) internal {
        deal(token, deployer, amount);
        vm.startPrank(deployer);
        IERC20(token).approve(address(conv), amount);
        conv.seedReserve(token, amount);
        vm.stopPrank();
    }

    function _ladder() internal pure returns (uint256[] memory fees, uint256[] memory weights) {
        fees = new uint256[](5);
        weights = new uint256[](5);
        (fees[0], weights[0]) = (66_666e18, 100);
        (fees[1], weights[1]) = (166_666e18, 125);
        (fees[2], weights[2]) = (366_666e18, 160);
        (fees[3], weights[3]) = (666_666e18, 200);
        (fees[4], weights[4]) = (1_666_666e18, 333);
    }

    // ---- helpers ----

    function _wallet(string memory name, uint256 esseyAmt) internal returns (address w) {
        w = makeAddr(name);
        vm.deal(w, 1 ether);
        vm.prank(deployer);
        essey.transfer(w, esseyAmt);
    }

    function _mintAndStake(string memory name, uint8 tier) internal returns (uint256 id, address w) {
        w = _wallet(name, 3_000_000e18);
        bytes32 combo = keccak256(abi.encode("mint", name));
        vm.startPrank(w);
        id = dist.mintCustom{value: CUSTOM_FEE}(combo);
        essey.approve(address(bell), bell.tierFees(tier - 1));
        bell.activate(id, tier);
        vm.stopPrank();
    }

    /// Put USDG into the Bell pot from the on-chain whale (stand-in for already-flushed fees).
    function _fundPot(uint256 usdgAmount) internal {
        vm.deal(USDG_WHALE, 1 ether);
        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(address(bell), usdgAmount);
    }

    /// Warp to the next in-session weekday and freshen the three feeds (real last price, updatedAt = now)
    /// so the equity converter deterministically settles stock regardless of when the suite runs.
    function _enterSession() internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 400; i++) {
            if (conv.isUsMarketHours(t)) break;
            t += 1800;
        }
        require(conv.isUsMarketHours(t), "no session found");
        vm.warp(t);
        _freshFeed(USDG_FEED, usdgPx, t);
        _freshFeed(AAPL_FEED, aaplPx, t);
        _freshFeed(NVDA_FEED, nvdaPx, t);
    }

    function _freshFeed(address feed, int256 px, uint256 t) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), px, t, t, uint80(1))
        );
    }

    // ============================================================ 1) converter deploy + wiring sanity

    function test_01_converter_wiring() public view {
        assertEq(IERC20Metadata(USDG).decimals(), 6, "USDG 6-dec");
        assertEq(IERC20Metadata(AAPL).decimals(), 18, "AAPL 18-dec");
        assertTrue(conv.isSupported(AAPL), "AAPL listed");
        assertTrue(conv.isSupported(NVDA), "NVDA listed");
        assertTrue(conv.isSupported(conv.BUNDLE()), "bundle populated");
        assertEq(conv.bundleSize(), 2, "bundle = AAPL + NVDA");
        assertEq(conv.bell(), address(bell), "convert() gated to the Bell");
        assertEq(bell.defaultPayout(), conv.BUNDLE(), "Bell defaultPayout = BUNDLE");
        assertEq(address(bell.converter()), address(conv), "Bell wired to converter");
        assertEq(conv.reserveOf(AAPL), 100_000e18, "AAPL reserve seeded");
        assertEq(conv.reserveOf(NVDA), 100_000e18, "NVDA reserve seeded");
        assertFalse(IPausable(AAPL).paused(), "AAPL live at fork");
    }

    // ============================================================ 2) full Bell cycle: fee->USDG->ring->claim->STOCK

    /// The flagship: real ETH fee -> real Uniswap flush -> USDG in the pot (+ top-up) -> ring -> claim pays
    /// two staked Dons REAL AAPL+NVDA into their Vaults, pro-rata by tier weight.
    function test_02_fullCycle_flush_ring_claim_paysRealStock() public {
        // Two Dons at different tiers so we can prove pro-rata payout.
        (uint256 idA,) = _mintAndStake("stakerA", 1); // weight 100
        (uint256 idB,) = _mintAndStake("stakerB", 5); // weight 333
        assertEq(bell.totalWeight(), 100 + 333, "roll weight");

        // --- real fee -> USDG leg (BEFORE any warp: real feeds are fresh at `latest`) ---
        // Mint a few more Dons so mint-fee ETH accrues in the router, then flush through the real pool.
        uint256 routerEth0 = address(feeRouter).balance; // the two stakers' mint fees are already here
        for (uint256 i = 0; i < 6; i++) {
            address m = _wallet(string.concat("minter", vm.toString(i)), 0);
            bytes32 combo = keccak256(abi.encode("feemint", i));
            vm.prank(m);
            dist.mintCustom{value: CUSTOM_FEE}(combo);
        }
        assertEq(address(feeRouter).balance, routerEth0 + 6 * CUSTOM_FEE, "router accrued 6 more mint fees");
        uint256 flushed = feeRouter.flushEth(block.timestamp + 1);
        assertGt(flushed, 0, "flushEth produced USDG into the Bell");
        console.log("real fee flush -> USDG (6-dec) into pot:", flushed);

        // top up so the pot is comfortably above MIN_RING and pro-rata numbers are clean
        _fundPot(1000e6);
        uint256 potBefore = bell.pot();
        assertGe(potBefore, MIN_RING, "pot >= MIN_RING");

        // --- ring: one division, credited pro-rata by weight ---
        bell.ring();
        uint256 pendA = bell.pendingOf(idA);
        uint256 pendB = bell.pendingOf(idB);
        assertGt(pendA, 0, "A has pending");
        // weight ratio 333:100 -> B earns ~3.33x A
        assertApproxEqRel(pendB, pendA * 333 / 100, 0.001e18, "pending pro-rata by weight");

        // --- enter US session (deterministic) and claim both into stock ---
        _enterSession();
        bell.claim(idA);
        bell.claim(idB);

        _assertProRataStock(idA, idB);

        // Accounting settled; converter holds no base at rest.
        assertEq(bell.pendingOf(idA), 0, "A claimed");
        assertEq(bell.pendingOf(idB), 0, "B claimed");
        assertApproxEqAbs(bell.reserved(), 0, 2, "reserved settled (sub-wei dust ok)");
        assertEq(IERC20(USDG).balanceOf(address(conv)), 0, "converter holds no base at rest");
    }

    /// Real AAPL+NVDA landed in each Vault, no base, and pro-rata by tier weight (B 333 : A 100).
    function _assertProRataStock(uint256 idA, uint256 idB) internal view {
        address vaultA = don.vaultOf(idA);
        address vaultB = don.vaultOf(idB);
        uint256 aA = IERC20(AAPL).balanceOf(vaultA);
        uint256 nA = IERC20(NVDA).balanceOf(vaultA);
        uint256 aB = IERC20(AAPL).balanceOf(vaultB);
        uint256 nB = IERC20(NVDA).balanceOf(vaultB);
        assertGt(aA, 0, "vaultA got AAPL");
        assertGt(nA, 0, "vaultA got NVDA");
        assertGt(aB, 0, "vaultB got AAPL");
        assertGt(nB, 0, "vaultB got NVDA");
        assertEq(IERC20(USDG).balanceOf(vaultA), 0, "no base when bundle settles (A)");
        assertEq(IERC20(USDG).balanceOf(vaultB), 0, "no base when bundle settles (B)");
        assertApproxEqRel(aB, aA * 333 / 100, 0.01e18, "AAPL delivered pro-rata by weight");
        assertApproxEqRel(nB, nA * 333 / 100, 0.01e18, "NVDA delivered pro-rata by weight");
        console.log("vaultA AAPL/NVDA:", aA, nA);
        console.log("vaultB AAPL/NVDA:", aB, nB);
    }

    // ============================================================ 3) single-stock election -> only that stock

    function test_03_electSingleStock_paysOnlyThatStock() public {
        (uint256 id, address w) = _mintAndStake("electAAPL", 3);
        vm.prank(w);
        bell.setPayoutToken(id, AAPL);

        _fundPot(500e6);
        bell.ring();
        _enterSession();

        address vault = don.vaultOf(id);
        bell.claim(id);
        assertGt(IERC20(AAPL).balanceOf(vault), 0, "paid in AAPL only");
        assertEq(IERC20(NVDA).balanceOf(vault), 0, "no NVDA");
        assertEq(IERC20(USDG).balanceOf(vault), 0, "no base");
    }

    // ============================================================ 4) PAUSABLE EDGE: fails open to USDG

    /// AAPL is a real pausable token. Pause it mid-payout: the paused stock transfer reverts inside the
    /// converter, the Bell CATCHES it and FAILS OPEN — the whole (atomic) bundle claim pays USDG instead.
    /// A paused stock can neither brick the claim nor strand funds.
    function test_04_pausable_bundle_failsOpenToBase() public {
        (uint256 id, ) = _mintAndStake("pauseBundle", 4);
        _fundPot(500e6);
        bell.ring();
        uint256 pending = bell.pendingOf(id);
        _enterSession();

        // PAUSE the real AAPL token (flip its real Pausable slot — the effect of the pauser calling pause()).
        _pause(AAPL);
        assertTrue(IPausable(AAPL).paused(), "AAPL paused");

        address vault = don.vaultOf(id);
        uint256 treasuryUsdg0 = IERC20(USDG).balanceOf(deployer);
        bell.claim(id); // routes to BUNDLE -> AAPL leg reverts -> Bell fails open

        // Failed open: full payout delivered in USDG, zero stock, nothing stranded.
        assertEq(IERC20(USDG).balanceOf(vault), pending, "full payout delivered in USDG (fail-open)");
        assertEq(IERC20(AAPL).balanceOf(vault), 0, "no AAPL (paused)");
        assertEq(IERC20(NVDA).balanceOf(vault), 0, "atomic: NVDA leg rolled back too");
        assertEq(bell.pendingOf(id), 0, "claim settled");
        assertEq(bell.reserved(), 0, "no reward reserved-but-stuck");
        assertEq(IERC20(USDG).balanceOf(address(conv)), 0, "converter holds no base");
        assertEq(IERC20(USDG).allowance(address(bell), address(conv)), 0, "no standing allowance after fail-open");
        assertEq(IERC20(USDG).balanceOf(deployer), treasuryUsdg0, "no base forwarded (convert reverted atomically)");
    }

    /// Same pause, but the Don elected AAPL single-stock: still fails open to USDG (no partial, no brick).
    function test_05_pausable_singleStock_failsOpenToBase() public {
        (uint256 id, address w) = _mintAndStake("pauseSingle", 3);
        vm.prank(w);
        bell.setPayoutToken(id, AAPL);
        _fundPot(500e6);
        bell.ring();
        uint256 pending = bell.pendingOf(id);
        _enterSession();

        _pause(AAPL);
        address vault = don.vaultOf(id);
        bell.claim(id);
        assertEq(IERC20(USDG).balanceOf(vault), pending, "single-stock paused -> USDG fail-open");
        assertEq(IERC20(AAPL).balanceOf(vault), 0, "no AAPL");
    }

    /// NVDA elected + only NVDA paused, AAPL still live -> still fails open (proves the pause, not a
    /// coincidental empty reserve, drove the fallback).
    function test_06_pausable_isThePauseNotReserve() public {
        (uint256 id, address w) = _mintAndStake("pauseNvda", 4);
        vm.prank(w);
        bell.setPayoutToken(id, NVDA);
        _fundPot(500e6);
        bell.ring();
        _enterSession();

        address vault = don.vaultOf(id);
        uint256 pending = bell.pendingOf(id);

        // control: with NVDA live the claim WOULD pay stock — snapshot, verify, then revert to isolate the pause
        uint256 snap = vm.snapshotState();
        bell.claim(id);
        assertGt(IERC20(NVDA).balanceOf(vault), 0, "control: NVDA pays when live");
        vm.revertToState(snap);

        // now pause ONLY NVDA (AAPL stays live, reserve is full) -> the PAUSE alone drives the fallback
        _pause(NVDA);
        bell.claim(id);
        assertEq(IERC20(USDG).balanceOf(vault), pending, "NVDA paused -> full USDG fail-open");
        assertEq(IERC20(NVDA).balanceOf(vault), 0, "no NVDA");
    }

    // ============================================================ 5) fail-CLOSED on stale real feed -> base

    /// Warp the REAL feeds past the staleness bound (no freshening): the converter fails closed and the
    /// Bell fails open to USDG. Exercises the genuine real-oracle staleness path (respects freshness/warp).
    function test_07_failsClosed_staleFeed_paysBase() public {
        (uint256 id, ) = _mintAndStake("staleFeed", 2);
        _fundPot(500e6);
        bell.ring();
        uint256 pending = bell.pendingOf(id);

        // 26h forward with NO feed freshening -> real equity feed age > 90000s bound -> priceOf reverts.
        vm.warp(block.timestamp + 26 hours);
        address vault = don.vaultOf(id);
        bell.claim(id);
        assertEq(IERC20(USDG).balanceOf(vault), pending, "stale real feed -> USDG fail-open");
        assertEq(IERC20(AAPL).balanceOf(vault), 0, "no stock on a silent oracle");
    }

    // ============================================================ 6) REAL oracle, LIVE outcome (no normalization)

    /// No warp, no mock: run the claim against the UNTOUCHED real feeds and assert the design-correct LIVE
    /// outcome — stock iff the market is genuinely open right now, base otherwise. Exercises the real
    /// session gate + real feeds exactly as mainnet would at this instant.
    function test_08_realOracle_liveOutcome() public {
        (uint256 id, ) = _mintAndStake("realOracle", 3);
        _fundPot(500e6);
        bell.ring();
        uint256 pending = bell.pendingOf(id);
        address vault = don.vaultOf(id);

        bool settlesStock;
        try conv.priceOf(AAPL) returns (uint256, uint8, bool inSession) {
            // BUNDLE needs BOTH legs to settle; approximate liveness by AAPL's session+freshness.
            settlesStock = inSession;
        } catch {
            settlesStock = false;
        }

        bell.claim(id);
        if (settlesStock) {
            assertGt(IERC20(AAPL).balanceOf(vault) + IERC20(NVDA).balanceOf(vault), 0, "live session -> real stock");
            console.log("LIVE: market open at fork -> paid real stock");
        } else {
            assertEq(IERC20(USDG).balanceOf(vault), pending, "closed/stale -> base fail-open");
            console.log("LIVE: market closed/stale at fork -> paid USDG (fail-open)");
        }
    }

    // ---- pause via the real Pausable slot (role holder not enumerable; slot flip == pauser calling pause) ----
    function _pause(address token) internal {
        uint256 slot = stdstore.target(token).sig(IPausable.paused.selector).find();
        bytes32 cur = vm.load(token, bytes32(slot));
        vm.store(token, bytes32(slot), bytes32((uint256(cur) & ~uint256(0xff)) | 1));
    }
}
