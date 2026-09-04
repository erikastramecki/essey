// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

import {EsseyToken} from "../src/market/EsseyToken.sol";
import {Don} from "../src/market/Don.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonExchange, IDonFloor} from "../src/market/DonExchange.sol";
import {DonFeeRouter, ISwapRouter, IWETH} from "../src/market/DonFeeRouter.sol";
import {DonLoan} from "../src/market/DonLoan.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";

interface IStockToken {
    function decimals() external view returns (uint8);
    function uiMultiplier() external view returns (uint256);
    function paused() external view returns (bool);
}

interface IUniV3Factory {
    function getPool(address, address, uint24) external view returns (address);
    function createPool(address, address, uint24) external returns (address);
}

interface IUniV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// DonMainnetFork — PHASE 1 mainnet-fork validation of the Essey "Don" v3 stack.
///
/// Forks REAL Robinhood Chain mainnet (chainId 4663) at a pinned block, deploys the whole Don v3 stack
/// against the REAL external dependencies (6-dec USDG, the WETH, the Uniswap SwapRouter02, the Chainlink
/// ETH/USD + USDG/USD feeds), funds everything with cheatcodes (ZERO real money), and drives every user
/// journey PLUS the two testnet-impossible legs:
///   (1) the real fee-flush swap through the real SwapRouter02 + the real WETH/USDG pool (flushEth) and a
///       fork-created ESSEY/USDG pool (flushEssey), and
///   (2) 6-decimal USDG conversions end-to-end (feeds -> minOut -> pool -> Bell).
///
/// Run:  forge test --match-path test/DonMainnetFork.t.sol -vv
contract DonMainnetForkTest is Test {
    using SafeERC20 for IERC20;

    // ---- REAL mainnet dependencies (verified on-chain 2026-08; see docs/MAINNET-CONFIG.md) ----
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6-dec "Global Dollar"
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; // UniswapV3Factory
    address constant ETH_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9; // ETH/USD, 8-dec
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2; // USDG/USD, 8-dec
    address constant WETH_USDG_3000 = 0xa9188730Fe85Be88ad499D7d52B099e800fB0334; // live 3000-tier pool
    address constant USDG_WHALE = 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a; // WETH/USDG 500-tier pool (~1.06M USDG)
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    // The public RH mainnet RPC is NOT a full archive node — it prunes state within ~1-2k blocks and then
    // returns "metadata is not found" for lazily-fetched accounts. Forking at a pinned OLDER block therefore
    // fails mid-test. We fork at LATEST (a just-produced block whose state the node still serves) so every
    // account read/impersonation resolves. Set FORK_BLOCK>0 (env) only against a real archive endpoint.
    uint256 constant PIN_BLOCK = 0; // 0 = latest

    // ---- stack ----
    EsseyToken essey;
    DonDistributor dist;
    Don don;
    DonReserve reserve;
    Bell bell;
    DonFeeRouter feeRouter;
    DonExchange exchange;
    DonLoan loan;

    address deployer; // admin == treasury == seeder (single controlled actor)
    address guardian;

    // deploy constants mirroring DeployDons.s.sol
    uint256 constant RESERVE_FUND = 2_666_666_666e18; // -> 300k floor at 8888 cap
    uint256 constant LOAN_FUND = 266_666_666e18; // founder rec ~3%
    uint256 constant CUSTOM_FEE = 0.0053 ether; // MAINNET-CONFIG resized value
    uint256 constant REROLL_FEE = 0.0016 ether;
    uint256 constant DON_PRICE = 300_000e18;

    // uniswap mint-callback scratch
    address _mintT0;
    address _mintT1;

    function setUp() public {
        if (PIN_BLOCK == 0) {
            vm.createSelectFork(vm.rpcUrl("rh_mainnet")); // latest — state served by the (non-archive) node
        } else {
            vm.createSelectFork(vm.rpcUrl("rh_mainnet"), PIN_BLOCK);
        }
        deployer = _asEoa(makeAddr("deployer"));
        guardian = _asEoa(makeAddr("guardian"));
        _deployAndSeed();
    }

    // ============================================================ DEPLOY (mirrors DeployDons.deployAll)

    /// R4 LOW-6. `makeAddr` returns a VANITY address, and a fork at LATEST carries whatever a
    /// stranger has since deployed or DELEGATED there. makeAddr("deployer") resolves to
    /// 0xaE0bDc4eEAC5E950B67C6819B118761CaAF61946, which now holds an EIP-7702 delegation
    /// designator on mainnet 4663 (`cast code` -> 0xef0100…), so it has code, `_safeMint`'s receiver
    /// check calls into it, and every mint in this fixture reverts ERC721InvalidReceiver — on every
    /// machine, until someone clears it, which nobody here can. Normalise the account to the plain
    /// EOA the fixture means, and say why.
    function _asEoa(address a) internal returns (address) {
        if (a.code.length != 0) vm.etch(a, "");
        return a;
    }

    function _deployAndSeed() internal {
        (uint256[] memory fees, uint256[] memory weights) = _ladder();

        vm.startPrank(deployer);
        essey = new EsseyToken(deployer); // fresh 8.888B, minted to treasury(=deployer)
        dist = new DonDistributor(deployer, 2722, 2 days, REROLL_FEE, CUSTOM_FEE, 0);
        don = new Don("Essey Dons", "DON", 8888, address(dist), deployer, 500);
        reserve = new DonReserve(IERC20(address(essey)), IERC721(address(don)));
        bell = new Bell(
            ISeatLike(address(don)), IERC20(address(essey)), IERC20(USDG), deployer, 10e6, 0, fees, weights,
            IConverter(address(0)), address(0)
        );

        // Route env fully wired -> real DonFeeRouter is the feeSink (B1: NOT the treasury-interim).
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
                sequencerUptimeFeed: AggregatorV3Interface(address(0)) // none on RH-chain
            })
        );
        address sink = address(feeRouter);

        exchange = new DonExchange(
            IERC721(address(don)), IERC20(address(essey)), IDonFloor(address(reserve)), sink, deployer,
            deployer, DON_PRICE, 800, 1200, 7000, guardian
        );
        loan = new DonLoan(
            DonLoan.Config({
                essey: IERC20(address(essey)),
                don: don,
                reserve: reserve,
                feeSink: sink,
                treasury: deployer,
                ltvBps: 5000,
                liqThresholdBps: 7000,
                defaultGraceSeconds: 30 days,
                liqTipBps: 100,
                ethPerFloorPerYearWad: 0,
                ethFeeStockShareBps: 7000,
                guardian: guardian
            })
        );

        // one-shot wiring
        dist.initDon(don);
        dist.setDonHook(address(bell));
        dist.setBell(address(bell));
        dist.setDonLienManager(address(loan));
        dist.setFeeSink(sink);
        dist.setTreasury(deployer);

        // seed: reserve floor, loan pot, desk float, open mint
        essey.approve(address(reserve), RESERVE_FUND);
        reserve.fund(RESERVE_FUND);
        essey.approve(address(loan), LOAN_FUND);
        loan.fund(LOAN_FUND);
        dist.setPublicOpen(true);

        uint256 deskSeed = 12;
        bytes32[] memory combos = new bytes32[](deskSeed);
        for (uint256 i = 0; i < deskSeed; i++) combos[i] = keccak256(abi.encode("desk", i));
        dist.mintReserved(deployer, combos);
        uint256[] memory ids = new uint256[](deskSeed);
        for (uint256 i = 0; i < deskSeed; i++) ids[i] = i + 1;
        don.setApprovalForAll(address(exchange), true);
        exchange.seed(ids);
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

    /// Fund a fresh wallet with ETH + ESSEY from cheatcodes/deployer. ZERO real money.
    function _wallet(string memory name, uint256 esseyAmt) internal returns (address w) {
        w = makeAddr(name);
        vm.deal(w, 1 ether);
        vm.prank(deployer);
        essey.transfer(w, esseyAmt);
    }

    function _mint(address w) internal returns (uint256 id) {
        bytes32 combo = keccak256(abi.encode("mint", w));
        vm.prank(w);
        id = dist.mintCustom{value: CUSTOM_FEE}(combo);
        assertEq(don.ownerOf(id), w, "mint: owner");
    }

    // ============================================================ REAL-DEP SANITY

    function test_01_realDeps_behaveAsDocumented() public view {
        assertEq(IERC20Metadata(USDG).decimals(), 6, "USDG must be 6-dec");
        assertGt(WETH.code.length, 0, "WETH code");
        assertGt(ROUTER.code.length, 0, "router code");
        assertGt(FACTORY.code.length, 0, "factory code");

        // AAPL: pausable + uiMultiplier + 18-dec
        assertEq(IStockToken(AAPL).decimals(), 18, "AAPL 18-dec");
        // NOT 1e18 any more, and this suite could not tell anyone because its setUp had been
        // reverting (R4 LOW-6). Measured 2026-09-04 at latest: 1_000_566_080_061_092_436, a 5.66bps
        // drift. The property that matters is that it is READABLE and at least par — a multiplier
        // below par would value collateral under the raw balance, which no corporate action does.
        uint256 aaplMult = IStockToken(AAPL).uiMultiplier();
        assertGe(aaplMult, 1e18, "AAPL uiMultiplier at or above par");
        console.log("AAPL uiMultiplier:", aaplMult);
        console.log("NVDA uiMultiplier:", IStockToken(NVDA).uiMultiplier());
        assertFalse(IStockToken(AAPL).paused(), "AAPL not paused at fork");
        assertEq(IStockToken(NVDA).decimals(), 18, "NVDA 18-dec");

        // feeds respond + fresh within heartbeat at the pinned block
        (, int256 ethPx,, uint256 ethUpd,) = AggregatorV3Interface(ETH_FEED).latestRoundData();
        (, int256 usdgPx,, uint256 usdgUpd,) = AggregatorV3Interface(USDG_FEED).latestRoundData();
        assertGt(ethPx, 0, "ETH feed positive");
        assertGt(usdgPx, 0, "USDG feed positive");
        assertLt(block.timestamp - ethUpd, uint256(90_000), "ETH feed fresh (<heartbeat+grace)");
        assertLt(block.timestamp - usdgUpd, uint256(90_000), "USDG feed fresh");
        assertEq(AggregatorV3Interface(ETH_FEED).decimals(), 8, "ETH feed 8-dec");

        // the WETH/USDG 3000-tier pool the flushEth leg routes through is live
        assertEq(IUniV3Factory(FACTORY).getPool(WETH, USDG, 3000), WETH_USDG_3000, "3000 pool");
        assertGt(IUniV3Pool(WETH_USDG_3000).liquidity(), 0, "3000 pool has liquidity");
        console.log("ETH/USD (8dec):", uint256(ethPx));
        console.log("USDG/USD(8dec):", uint256(usdgPx));
    }

    // ============================================================ DEPLOY + B1 WIRING

    function test_02_deploy_and_B1_wiring() public view {
        assertEq(essey.totalSupply(), 8_888_888_888e18, "fresh 8.888B supply");
        // 2,666,666,666e18 / 8888 cap ~= 300,030 (the doc's ~300k floor; not exactly 300000)
        assertApproxEqRel(reserve.floorPerDon(), DON_PRICE, 0.001e18, "floor ~= 300k");
        assertEq(loan.lendable(), LOAN_FUND, "loan pot funded");
        assertEq(exchange.inventoryCount(), 12, "desk seeded");

        // B1 / A3: feeSink must be the REAL DonFeeRouter, NOT the treasury-interim.
        assertEq(exchange.feeSink(), address(feeRouter), "exchange feeSink = router");
        assertEq(loan.feeSink(), address(feeRouter), "loan feeSink = router");
        assertEq(dist.feeSink(), address(feeRouter), "dist feeSink = router");
        assertTrue(exchange.feeSink() != exchange.treasury(), "feeSink != treasury (B1 correct)");
        // router is oracle-backed + handles BOTH ESSEY and ETH -> nothing stranded (Dons-era B1 resolution)
        assertEq(feeRouter.bell(), address(bell), "router USDG sink = bell (immutable)");
    }

    // ============================================================ MINT + STAKE (Bell tiers)

    function test_03_mint_stake_upgrade() public {
        address w = _wallet("staker", 1_000_000e18);
        uint256 id = _mint(w);

        uint256 f1 = bell.tierFees(0);
        vm.startPrank(w);
        essey.approve(address(bell), f1);
        bell.activate(id, 1);
        (uint8 t1,,,) = bell.seats(id);
        assertEq(t1, 1, "tier 1");

        uint256 delta = bell.tierFees(1) - bell.tierFees(0);
        essey.approve(address(bell), delta);
        bell.upgrade(id, 2);
        (uint8 t2,,,) = bell.seats(id);
        assertEq(t2, 2, "tier 2");
        vm.stopPrank();
    }

    // ============================================================ BORROW + REPAY (7d & 365d)

    function _borrowRepay(uint256 term) internal {
        address w = _wallet(string.concat("borrower", vm.toString(term)), 1_000_000e18);
        uint256 id = _mint(w);
        uint256 want = loan.maxBorrow();
        assertEq(want, (reserve.floorPerDon() * 5000) / 10_000, "maxBorrow = 50% floor");
        uint256 prepaid = loan.prepaidEth(term);
        assertEq(prepaid, 0, "free borrowing (rate=0)");

        uint256 e0 = essey.balanceOf(w);
        vm.prank(w);
        loan.borrow{value: prepaid}(id, term);
        assertTrue(don.liened(id), "liened");
        assertEq(loan.debtOf(id), want, "debt = principal");
        assertEq(essey.balanceOf(w) - e0, want, "proceeds = maxBorrow");

        uint256 debt = loan.debtOf(id);
        vm.startPrank(w);
        essey.approve(address(loan), debt);
        loan.repay(id, type(uint256).max);
        vm.stopPrank();
        assertEq(loan.debtOf(id), 0, "repaid");
        assertFalse(don.liened(id), "lien released");
    }

    function test_04_borrow_repay_7d() public {
        _borrowRepay(loan.MIN_TERM());
    }

    function test_05_borrow_repay_365d() public {
        _borrowRepay(365 days);
    }

    // ============================================================ LIQUIDATION (time-warp)

    function test_06_liquidation_timewarp() public {
        address borrower = _wallet("liqBorrower", 1_000_000e18);
        address liquidator = makeAddr("liquidator");
        vm.deal(liquidator, 1 ether); // materialize the account locally (avoids a pruned-state RPC fetch)
        uint256 id = _mint(borrower);

        uint256 term = loan.MIN_TERM();
        uint256 prepaid = loan.prepaidEth(term); // compute BEFORE prank (arg-call would consume it)
        vm.prank(borrower);
        loan.borrow{value: prepaid}(id, term);
        uint256 principal = loan.debtOf(id);
        (,, uint64 expiry,) = loan.loans(id);

        vm.warp(uint256(expiry) + loan.defaultGraceSeconds() + 1);

        uint256 proceeds = reserve.floorPerDon();
        uint256 tip = (proceeds * loan.liqTipBps()) / 10_000;
        uint256 surplus = proceeds - tip - principal;
        uint256 bBefore = essey.balanceOf(borrower);
        uint256 lBefore = essey.balanceOf(liquidator);

        vm.prank(liquidator);
        loan.liquidate(id);

        assertEq(loan.debtOf(id), 0, "loan cleared");
        assertEq(don.ownerOf(id), address(reserve), "Don seized+redeemed");
        assertEq(essey.balanceOf(liquidator) - lBefore, tip, "liquidator tip 1%");
        assertEq(essey.balanceOf(borrower) - bBefore, surplus, "surplus back to borrower");
    }

    // ============================================================ DESK round-trips + 70/30 fee routing

    function test_07_desk_buy_snipe_sell_feeRouting() public {
        address w = _wallet("trader", 2_000_000e18);
        uint256 id = _buyAssertFee(w);
        _sellBack(w, id);
        _snipeAssert(w);
    }

    // BUY: cost = price + 8% fee; assert 70% -> feeSink(router), 30% -> treasury
    function _buyAssertFee(address w) internal returns (uint256 id) {
        uint256 fee = exchange.feeOn(exchange.swapFeeBps());
        uint256 cost = exchange.price() + fee;
        uint256 sink0 = essey.balanceOf(address(feeRouter));
        uint256 tre0 = essey.balanceOf(deployer);
        vm.startPrank(w);
        essey.approve(address(exchange), cost);
        id = exchange.buy(cost);
        vm.stopPrank();
        assertEq(don.ownerOf(id), w, "buy received");
        uint256 toStock = (fee * exchange.stockShareBps()) / 10_000;
        assertEq(essey.balanceOf(address(feeRouter)) - sink0, toStock, "70% ESSEY -> router");
        assertEq(essey.balanceOf(deployer) - tre0, fee - toStock, "30% ESSEY -> treasury");
    }

    function _sellBack(address w, uint256 id) internal {
        uint256 net = exchange.price() - exchange.feeOn(exchange.swapFeeBps());
        uint256 e1 = essey.balanceOf(w);
        vm.startPrank(w);
        don.approve(address(exchange), id);
        exchange.sell(id, net);
        vm.stopPrank();
        assertEq(essey.balanceOf(w) - e1, net, "sell net proceeds");
        assertEq(don.ownerOf(id), address(exchange), "don returned to desk");
    }

    function _snipeAssert(address w) internal {
        uint256 target = exchange.inventoryAt(0);
        uint256 cost3 = exchange.price() + exchange.feeOn(exchange.snipeFeeBps());
        vm.startPrank(w);
        essey.approve(address(exchange), cost3);
        exchange.snipe(target, cost3);
        vm.stopPrank();
        assertEq(don.ownerOf(target), w, "snipe received");
    }

    // ============================================================ RESERVE fund + redeem

    function test_08_reserve_fund_redeem() public {
        address w = _wallet("redeemer", 2_000_000e18);
        // buy a Don off the desk
        uint256 cost = exchange.price() + exchange.feeOn(exchange.swapFeeBps());
        vm.startPrank(w);
        essey.approve(address(exchange), cost);
        uint256 id = exchange.buy(cost);
        vm.stopPrank();

        // permissionless fund raises the floor
        uint256 f0 = reserve.floorPerDon();
        vm.startPrank(w);
        essey.approve(address(reserve), 1_000_000e18);
        reserve.fund(1_000_000e18);
        assertGe(reserve.floorPerDon(), f0, "floor non-decreasing");

        // redeem at the floor
        uint256 e0 = essey.balanceOf(w);
        don.approve(address(reserve), id);
        uint256 paid = reserve.redeem(id);
        vm.stopPrank();
        assertGt(paid, 0, "redeem pays floor");
        assertEq(don.ownerOf(id), address(reserve), "don locked in reserve");
        assertEq(essey.balanceOf(w) - e0, paid, "redeem proceeds");
    }

    // ============================================================ FEE-FLUSH: ETH -> USDG -> Bell (REAL pool)

    function test_09_flushEth_realPool_to_bell() public {
        // Accumulate mint-fee ETH in the router by minting several Dons (100% of ETH fee -> feeSink=router).
        for (uint256 i = 0; i < 5; i++) {
            address m = _wallet(string.concat("minter", vm.toString(i)), CUSTOM_FEE == 0 ? 0 : 1e18);
            _mint(m);
        }
        uint256 routerEth = address(feeRouter).balance;
        assertEq(routerEth, 5 * CUSTOM_FEE, "router holds all mint-fee ETH");

        uint256 bellUsdg0 = IERC20(USDG).balanceOf(address(bell));
        // permissionless flush; minOut is oracle-derived on-chain (6-dec USDG math)
        uint256 usdgOut = feeRouter.flushEth(block.timestamp + 1);

        assertGt(usdgOut, 0, "flushEth produced USDG");
        assertEq(address(feeRouter).balance, 0, "router ETH swept");
        assertEq(IERC20(USDG).balanceOf(address(bell)) - bellUsdg0, usdgOut, "USDG forwarded to Bell");
        assertEq(IERC20(USDG).balanceOf(address(feeRouter)), 0, "router holds no USDG (all -> bell)");
        // 6-dec sanity: ~0.0265 ETH * ~$1892 ~= $50 -> ~50e6 USDG order of magnitude
        console.log("flushEth: ETH in (wei) =", routerEth);
        console.log("flushEth: USDG out (6-dec raw) =", usdgOut);
    }

    // ============================================================ FEE-FLUSH: ESSEY -> USDG -> Bell (created pool)

    function test_10_flushEssey_createdPool_to_bell() public {
        // 1. Create + seed an ESSEY/USDG V3 pool on the REAL factory the router uses (fresh ESSEY has none).
        address pool = _createAndSeedEsseyUsdgPool();
        assertEq(IUniV3Factory(FACTORY).getPool(address(essey), USDG, 3000), pool, "essey/usdg pool created");
        assertGt(IUniV3Pool(pool).liquidity(), 0, "essey/usdg pool seeded");

        // 2. Accumulate ESSEY in the router via desk trade fees (70% of each fee -> feeSink=router).
        address w = _wallet("flushTrader", 5_000_000e18);
        for (uint256 i = 0; i < 3; i++) _deskRoundTrip(w);
        uint256 esseyIn = essey.balanceOf(address(feeRouter));
        assertGt(esseyIn, 0, "router accumulated ESSEY fees");

        // 3. Keeper flush: supply a conservative off-chain USDG (6-dec) quote; swap enforces quote*minOutBps.
        //    ~100k ESSEY @ the sandbox price (0.001 USDG) ~= $100; quote a very conservative 1 USDG so the
        //    swap provably executes regardless of exact pool depth/slippage.
        uint256 bellUsdg0 = IERC20(USDG).balanceOf(address(bell));
        uint256 conservativeQuote = 1e6; // 1 USDG in 6-dec
        vm.prank(deployer); // deployer is the default keeper
        uint256 usdgOut = feeRouter.flushEssey(block.timestamp + 1, conservativeQuote);

        assertGt(usdgOut, 0, "flushEssey produced USDG");
        assertEq(essey.balanceOf(address(feeRouter)), 0, "router ESSEY swept");
        assertEq(IERC20(USDG).balanceOf(address(bell)) - bellUsdg0, usdgOut, "USDG forwarded to Bell");
        console.log("flushEssey: ESSEY in (18-dec raw) =", esseyIn);
        console.log("flushEssey: USDG out (6-dec raw)  =", usdgOut);
    }

    // ============================================================ FEED STALENESS: fails closed after warp

    function test_11_flushEth_failsClosed_whenFeedStale() public {
        // give the router some ETH
        _mint(_wallet("staleMinter", 1e18));
        assertGt(address(feeRouter).balance, 0, "router has ETH");
        // warp past heartbeat+grace so the real feeds are stale
        vm.warp(block.timestamp + 90_000 + 1);
        vm.expectRevert(); // StaleFeedGuard.PriceStale — fail-closed, ETH simply waits
        feeRouter.flushEth(block.timestamp + 1);
    }

    function _deskRoundTrip(address w) internal {
        uint256 cost = exchange.price() + exchange.feeOn(exchange.swapFeeBps());
        vm.startPrank(w);
        essey.approve(address(exchange), cost);
        uint256 id = exchange.buy(cost);
        don.approve(address(exchange), id);
        exchange.sell(id, exchange.price() - exchange.feeOn(exchange.swapFeeBps()));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ uniswap helpers

    /// Create the ESSEY/USDG 3000-tier pool via the REAL factory (fresh ESSEY has none), initialize it at a
    /// realistic sandbox price (1 ESSEY ~= 0.001 USDG), and seed a deep full-range position via the mint
    /// callback. USDG can't be deal()'d (proxy token) so it's sourced from a real on-chain USDG holder by
    /// impersonation; ESSEY comes from the treasury. ZERO real money — all cheatcode-funded on the fork.
    function _createAndSeedEsseyUsdgPool() internal returns (address pool) {
        // sandbox reserves defining the price: 200M ESSEY (18-dec) <-> 200k USDG (6-dec) => 1 ESSEY=0.001 USDG
        uint256 esseyRes = 200_000_000e18;
        uint256 usdgRes = 200_000e6;

        // source seed tokens onto THIS contract (generous, to cover whatever the callback owes)
        vm.prank(deployer);
        essey.transfer(address(this), 1_000_000_000e18);
        vm.deal(USDG_WHALE, 1 ether); // materialize the whale locally before impersonating (pruned-state guard)
        vm.prank(USDG_WHALE); // a real USDG-rich pool on the fork; ZERO real money moved off-chain
        IERC20(USDG).transfer(address(this), 400_000e6);

        pool = IUniV3Factory(FACTORY).createPool(address(essey), USDG, 3000);
        _mintT0 = IUniV3Pool(pool).token0();
        _mintT1 = IUniV3Pool(pool).token1();
        // sqrtPriceX96 = sqrt(reserve1/reserve0) * 2^96, ordered by token0/token1
        uint256 r0 = _mintT0 == address(essey) ? esseyRes : usdgRes;
        uint256 r1 = _mintT1 == address(essey) ? esseyRes : usdgRes;
        uint160 sqrtP = uint160((_isqrt(r1) * (2 ** 96)) / _isqrt(r0));
        IUniV3Pool(pool).initialize(sqrtP);

        // full range for tickSpacing 60; L sized so both owed amounts fit the balances held above
        IUniV3Pool(pool).mint(address(this), -887220, 887220, uint128(5e18), "");
    }

    function _isqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// Uniswap V3 mint callback — pays the pool what it asks from this contract's dealt balances.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (amount0Owed > 0) IERC20(_mintT0).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) IERC20(_mintT1).safeTransfer(msg.sender, amount1Owed);
    }
}
