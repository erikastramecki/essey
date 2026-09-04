// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {EsseyMultiply} from "../src/market/EsseyMultiply.sol";
import {Note} from "../src/market/Note.sol";
import {MockFeed} from "../src/testnet/MockFeed.sol";
import {MockUSDG} from "./EsseyPool.t.sol";
import {ScaledUIStockMock} from "../src/testnet/ScaledUIStockMock.sol";

/// Feed-priced mock venue, DECIMAL-AWARE: the borrow asset is 6dp and the stock 18dp, so an adapter
/// that ignored decimals would put the 1e12 error back on the venue side and the ladder would
/// swallow it. Deliberately does NOT enforce `minOut` and can be told to lie (deliver less than it
/// claims): both exist so Multiply's OWN guards are what the tests exercise.
contract MockSwapAdapter is ISwapAdapter {
    MockFeed public immutable feed; // stock price, 8dp
    address public immutable usdg;
    uint256 public slippageBps;
    uint256 public deliverBps = 10_000;

    constructor(MockFeed feed_, address usdg_) {
        feed = feed_;
        usdg = usdg_;
    }

    function setSlippageBps(uint256 v) external {
        slippageBps = v;
    }

    function setDeliverBps(uint256 v) external {
        deliverBps = v;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256, address to)
        external
        returns (uint256 out)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (, int256 price,,,) = feed.latestRoundData();
        uint256 sIn = 10 ** IERC20Metadata(tokenIn).decimals();
        uint256 sOut = 10 ** IERC20Metadata(tokenOut).decimals();
        out = tokenIn == usdg
            ? (amountIn * 1e8 * sOut) / (uint256(price) * sIn)
            : (amountIn * uint256(price) * sOut) / (1e8 * sIn);
        out = (out * (10_000 - slippageBps)) / 10_000;
        IERC20(tokenOut).transfer(to, (out * deliverBps) / 10_000);
    }
}

/// G-LEND LOW-2. `close()`'s only binding used to be `pool.markets() == markets`, and any contract
/// can return the right address. Everything downstream — collateralToken(), asset(), note(),
/// debtOf(), repay() — was then attacker-defined, and the close path left a standing allowance on
/// the REAL borrow asset to an address of their choosing.
contract SpoofPool {
    address public immutable markets;
    address public immutable collateralToken;
    address public immutable asset;

    constructor(address m, address t, address a) {
        markets = m;
        collateralToken = t;
        asset = a;
    }

    function note() external view returns (address) { return address(this); }
    function accrue() external {}
    function debtOf(uint256) external pure returns (uint256) { return 1e6; }
    function repay(uint256, uint256) external {}
    function transferFrom(address, address, uint256) external {}
    function positions(uint256) external pure returns (address, uint256, uint256, uint256, uint256) {
        return (address(0), 0, 0, 0, 0);
    }
}

contract EsseyMultiplyTest is Test {
    EsseyMarkets markets;
    EsseyPool pool;
    MarketHealthOracle health;
    LivenessOracle liveness;
    EsseyMultiply multiply;
    MockSwapAdapter adapter;
    MockUSDG usdg;
    ScaledUIStockMock nvda;
    MockFeed nvdaFeed;
    Note note;

    address lender = address(0xA1);
    address user = address(0xB0B);
    address liquidator = address(0x11C);

    uint256 constant DEPTH = 1_500_000e6; // cap fraction 3_333 -> oracle cap ~499_950e6, static 250k binds

    /// SIX-decimal borrow asset, matching real mainnet USDG. The 18dp mock this replaces made
    /// `10**assetDecimals / 10**collateralDecimals` the identity — the fixture shape that hid a
    /// 1e12 LTV over-valuation in this repo once already.
    function setUp() public {
        MockFeed seqFeed = new MockFeed(8, 0);
        usdg = new MockUSDG();
        nvda = new ScaledUIStockMock("Mock NVDA", "NVDA", 18);
        liveness = new LivenessOracle(address(this), address(this), 900, 1 hours);
        health = new MarketHealthOracle(address(this), address(this), address(this));
        markets = new EsseyMarkets(
            AggregatorV3Interface(address(seqFeed)), liveness, health, address(this), address(this), 6
        );
        health.wireMarkets(address(markets));
        pool = new EsseyPool(
            IERC20(address(usdg)), address(nvda), markets, 1000, 500, 6000, 1000, address(0),
            address(this), 0, EsseyPool.Identity("Essey NVDA Pool Share", "aNVDA", "Essey NVDA Note", "nNVDA")
        );
        note = pool.note();

        nvdaFeed = new MockFeed(8, 175e8);
        markets.proposeMarket(
            address(nvda), AggregatorV3Interface(address(nvdaFeed)), 86_400, 90_000, 8, address(nvda), address(pool),
            EsseyMarkets.Market({
                enabled: true, ltvBps: 5000, liqThresholdBps: 7500, liqBonusBps: 500,
                collateralDecimals: 18, cap: 250_000e6, maxPositionBps: 10_000
            })
        );
        vm.warp(block.timestamp + 2 days + 1);
        markets.commitMarket(address(nvda));
        // Ride the depth-oracle ramp up to the pinned Wednesday on a live keeper cadence — a
        // silent warp past MAX_READING_AGE resets it. 24 days covers raiseDelay + the ~20-day
        // climb of the 499_950e6 target on the 250k-clamped base.
        vm.warp(1787151600 - 24 days);
        health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");
        for (uint256 i = 0; i < 48; i++) {
            vm.warp(block.timestamp + 12 hours);
            health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");
        }

        // now at 1787151600: Wednesday 15:00 UTC — inside the US session (the BorrowFlow pin)
        liveness.heartbeat();
        _advanceLive(1 hours + 1); // serve out resumeGrace on a live cadence
        nvdaFeed.set(175e8, block.timestamp);
        health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");

        multiply = new EsseyMultiply(markets);
        adapter = new MockSwapAdapter(nvdaFeed, address(usdg));
        multiply.listMarket(address(nvda), adapter, 20_000);
        usdg.mint(address(adapter), 1_000_000e6);
        nvda.mint(address(adapter), 10_000e18);

        usdg.mint(lender, 500_000e6);
        vm.startPrank(lender);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, lender);
        vm.stopPrank();

        nvda.mint(user, 100e18);
        vm.startPrank(user);
        nvda.approve(address(multiply), type(uint256).max);
        usdg.approve(address(multiply), type(uint256).max);
        note.setApprovalForAll(address(multiply), true);
        vm.stopPrank();
    }

    function _params(uint256 target, uint256 tol, uint256 maxNotes, uint256 slip)
        internal
        view
        returns (EsseyMultiply.OpenParams memory)
    {
        return EsseyMultiply.OpenParams({
            token: address(nvda),
            collateralIn: 100e18,
            targetLeverageBps: target,
            toleranceBps: tol,
            maxNotes: maxNotes,
            maxSlippageBps: slip,
            deadline: block.timestamp
        });
    }

    function _open18() internal returns (uint256[] memory ids) {
        vm.prank(user);
        ids = multiply.open(_params(18_000, 100, 8, 100));
    }

    function _assertNoResidue() internal view {
        assertEq(nvda.balanceOf(address(multiply)), 0, "no stock residue");
        assertEq(usdg.balanceOf(address(multiply)), 0, "no usdg residue");
        assertEq(note.balanceOf(address(multiply)), 0, "no custodied notes");
    }

    // ---------------------------------------------------------------- open

    function test_open_buildsLadder_atTarget() public {
        uint256[] memory ids = _open18();
        // 100 NVDA @ $175 = $17_500 of 6dp USDG, LTV 50%: rungs borrow 8750/4375/875, buying
        // 50/25/5 NVDA; the final 5 folds into rung 1. Exact because the venue fills at the oracle
        // price with 0 slippage.
        assertEq(ids.length, 3, "three rungs");
        assertEq(pool.debtOf(ids[0]), 8_750e6);
        assertEq(pool.debtOf(ids[1]), 4_375e6);
        assertEq(pool.debtOf(ids[2]), 875e6);
        (, uint256 c1,,,) = pool.positions(ids[0]);
        assertEq(c1, 105e18, "final purchase folded into rung 1");
        for (uint256 i; i < ids.length; ++i) {
            assertEq(note.ownerOf(ids[i]), user, "bearer Note with the user");
        }
        assertEq(pool.marketBorrows(address(nvda)), 14_000e6, "2x-1 of equity in debt");
        assertEq(nvda.balanceOf(user), 0, "all stock deployed");
        _assertNoResidue();
    }

    /// LTV 50% makes 2.0x the asymptote. Both halves of the name are now tested, and the reachable
    /// half asserts the LEVERAGE reached: a length-only assertion passes on a ladder that built ten
    /// rungs and landed nowhere near 2x.
    function test_open_twoX_reachableWithEnoughRungs_notWithFew() public {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) ids[i] = i + 1;
        vm.expectEmit(true, true, true, true, address(multiply));
        emit EsseyMultiply.MultiplyOpened(user, address(nvda), address(pool), ids, 100e18, 17_482_910_155, 19_990);
        vm.prank(user);
        assertEq(multiply.open(_params(20_000, 100, 10, 100)).length, 10, "ten rungs to get inside 1%");
        assertEq(pool.marketBorrows(address(nvda)), 17_482_910_155, "the geometric sum, to the unit");
        _assertNoResidue();

        // ...and two rungs cannot: 1.75x is as far as the halving series gets.
        nvda.mint(user, 100e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.LeverageMissed.selector, 17_500, 20_000, 100));
        multiply.open(_params(20_000, 100, 2, 100));
    }

    /// A SUCCESSFUL open against a LOSSY venue — every lossy setup here was followed by an
    /// expectRevert, so two things went unpinned. `achieved` divides by the ladder's OWN equity
    /// (totalValue - totalDebt), which a zero-slippage venue makes equal to the deposit's value, so
    /// a mutant dividing by the deposit read identically; and `maxSlippageBps` never appeared in a
    /// fill. Here the venue takes 50bps of every leg.
    function test_open_lossyVenue_pricesTheLadderAndTheAchievedLeverage() public {
        adapter.setSlippageBps(50);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (1, 2, 3);
        vm.expectEmit(true, true, true, true, address(multiply));
        emit EsseyMultiply.MultiplyOpened(user, address(nvda), address(pool), ids, 100e18, 14_000e6, 18_032);
        vm.prank(user);
        multiply.open(_params(18_000, 100, 8, 100));

        assertEq(pool.debtOf(1), 8_750e6, "rung 1 sizes off the deposit, before any venue loss");
        assertEq(pool.debtOf(2), 4_353_125_000, "rung 2 sizes off the SHRUNKEN first purchase");
        assertEq(pool.debtOf(3), 896_875_000, "rung 3 is what is left of `need`");
        (, uint256 c1,,,) = pool.positions(1);
        assertEq(c1, 105_099_375_000_000_000_000, "the fold carries the venue loss too");
        (, uint256 c2,,,) = pool.positions(2);
        assertEq(c2, 49.75e18, "50 NVDA less 50bps");
        (, uint256 c3,,,) = pool.positions(3);
        assertEq(c3, 24_750_625_000_000_000_000);
        _assertNoResidue();
    }

    /// The `out < minOut` boundary: a venue eating EXACTLY the authorised slippage is a fill.
    function test_open_venueExactlyAtMaxSlippage_succeeds() public {
        adapter.setSlippageBps(100);
        vm.prank(user);
        uint256[] memory ids = multiply.open(_params(18_000, 100, 8, 100));
        assertEq(ids.length, 3);
        assertEq(pool.debtOf(ids[1]), 4_331_250_000, "rung 2 off a 1%-shrunken purchase");
        _assertNoResidue();
    }

    /// ONE BASIS POINT past the authorisation, against the exact floor. The old lossy reverts used
    /// 3% against a 1% authorisation, so a minOut computed at DOUBLE the caller's slippage still
    /// reverted and survived; this is the case that separates them.
    function test_open_venueOneBpPastMaxSlippage_reverts() public {
        adapter.setSlippageBps(101);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.SlippageExceeded.selector, 49.495e18, 49.5e18));
        multiply.open(_params(18_000, 100, 8, 100));
    }

    function test_open_targetMissed_revertsWhole() public {
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.LeverageMissed.selector);
        multiply.open(_params(20_000, 100, 2, 100));
        assertEq(nvda.balanceOf(user), 100e18, "nothing pulled");
        assertEq(note.balanceOf(user), 0, "no partial position");
    }

    function test_open_aboveConfigMax_reverts() public {
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.AboveMaxLeverage.selector);
        multiply.open(_params(20_001, 100, 10, 100));
    }

    function test_open_atOne_orBelow_reverts() public {
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.AboveMaxLeverage.selector);
        multiply.open(_params(10_000, 100, 10, 100));
    }

    function test_open_slippagePushesPastConfigMax_reverts() public {
        // 3% venue slippage lifts a need-terminated 1.8x ladder to ~1.82x achieved: inside the
        // caller's tolerance, past a 1.81x market cap — the hard cap must win over tolerance.
        EsseyMultiply tight = new EsseyMultiply(markets);
        tight.listMarket(address(nvda), adapter, 18_100);
        adapter.setSlippageBps(300);
        vm.startPrank(user);
        nvda.approve(address(tight), type(uint256).max);
        vm.expectPartialRevert(EsseyMultiply.AboveMaxLeverage.selector);
        tight.open(_params(18_000, 300, 8, 400));
        vm.stopPrank();
    }

    function test_open_atExactlyConfigMax_succeeds() public {
        // achieved == maxLeverageBps is legal: the cap is `>`, not `>=`. Zero-slippage venue
        // makes a 1.8x target land at exactly 18_000, pinned against a market capped at 18_000.
        EsseyMultiply tight = new EsseyMultiply(markets);
        tight.listMarket(address(nvda), adapter, 18_000);
        vm.startPrank(user);
        nvda.approve(address(tight), type(uint256).max);
        uint256[] memory ids = tight.open(_params(18_000, 100, 8, 100));
        vm.stopPrank();
        assertEq(ids.length, 3);
    }

    function test_open_overshootBeyondTolerance_reverts() public {
        // Venue slippage lifts achieved (~1.82x) past target+tolerance while staying inside the
        // market cap: more leverage than asked for is a miss, not a bonus.
        adapter.setSlippageBps(300);
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.LeverageMissed.selector);
        multiply.open(_params(18_000, 100, 8, 400));
    }

    function test_open_zeroSlippageTolerance_exactVenue_succeeds() public {
        // maxSlippageBps 0 against a venue filling exactly at oracle price: the guard must be
        // `out < minOut`, never `<=` — an exact fill is a fill.
        vm.prank(user);
        uint256[] memory ids = multiply.open(_params(18_000, 100, 8, 0));
        assertEq(ids.length, 3);
        _assertNoResidue();
    }

    function test_open_zeroCollateral_reverts() public {
        EsseyMultiply.OpenParams memory p = _params(18_000, 100, 8, 100);
        p.collateralIn = 0;
        vm.prank(user);
        vm.expectRevert(EsseyMultiply.ZeroAmount.selector);
        multiply.open(p);
    }

    function test_open_venueWorseThanMaxSlippage_reverts() public {
        adapter.setSlippageBps(300);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.SlippageExceeded.selector, 48.5e18, 49.5e18));
        multiply.open(_params(18_000, 100, 8, 100));
    }

    function test_open_lyingVenue_caughtByBalanceDelta() public {
        adapter.setDeliverBps(9_000);
        vm.prank(user);
        // Exact args pin the DELTA-measured amount (45 = 90% of the claimed 50): a mutant trusting
        // the adapter's return value dies here, not on a downstream balance error.
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.SlippageExceeded.selector, 45e18, 49.5e18));
        multiply.open(_params(18_000, 100, 8, 100));
    }

    function test_open_capExceededMidLoop_revertsWhole() public {
        // Depth collapse: down is same-block. Cap 30k*3.333 ~ 9_999e6: rung 1 (8750) fits,
        // rung 2 (4375 more) crosses — the WHOLE open must unwind, not leave rung 1 behind.
        health.postDepth(address(nvda), 30_000e6, uint64(block.number), "test-v1");
        vm.prank(user);
        vm.expectPartialRevert(EsseyPool.ExceedsMarketCap.selector);
        multiply.open(_params(18_000, 100, 8, 100));
        assertEq(nvda.balanceOf(user), 100e18, "collateral back with the user");
        assertEq(note.balanceOf(user), 0, "no partial ladder");
        assertEq(pool.marketBorrows(address(nvda)), 0, "no debt landed");
        _assertNoResidue();
    }

    function test_open_positionCapExceeded_revertsWhole() public {
        _recommitMarket(200); // posLimit = 250k * 2% = 5_000e6 < rung 1's 8_750e6
        vm.prank(user);
        vm.expectPartialRevert(EsseyPool.ExceedsPositionCap.selector);
        multiply.open(_params(18_000, 100, 8, 100));
        assertEq(nvda.balanceOf(user), 100e18);
        assertEq(note.balanceOf(user), 0);
    }

    function test_open_marketNotBorrowable_reverts() public {
        markets.disableMarket(address(nvda));
        // maxBorrow inside the sizing loop hits the registry's gate before pool.borrow would.
        vm.prank(user);
        vm.expectPartialRevert(EsseyMarkets.MarketNotEnabled.selector);
        multiply.open(_params(18_000, 100, 8, 100));
    }

    function test_open_unlistedToken_reverts() public {
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.NotListed.selector);
        EsseyMultiply.OpenParams memory p = _params(18_000, 100, 8, 100);
        p.token = address(usdg);
        multiply.open(p);
    }

    function test_open_expiredDeadline_reverts() public {
        EsseyMultiply.OpenParams memory p = _params(18_000, 100, 8, 100);
        p.deadline = block.timestamp - 1;
        vm.prank(user);
        vm.expectRevert(EsseyMultiply.Expired.selector);
        multiply.open(p);
    }

    function testFuzz_open_atomic_acrossTargetsAndHeadroom(uint128 depth, uint256 target) public {
        target = bound(target, 10_501, 20_000);
        depth = uint128(bound(depth, 1e6, 3_000_000e6));
        health.postDepth(address(nvda), depth, uint64(block.number), "t");
        vm.prank(user);
        try multiply.open(_params(target, 300, 12, 100)) returns (uint256[] memory ids) {
            assertLe(pool.marketBorrows(address(nvda)), markets.borrowCap(address(nvda)), "cap honored");
            assertGt(ids.length, 0);
            for (uint256 i; i < ids.length; ++i) {
                assertEq(note.ownerOf(ids[i]), user);
            }
            _assertNoResidue();
        } catch {
            assertEq(nvda.balanceOf(user), 100e18, "revert leaves the user whole");
            assertEq(note.balanceOf(user), 0, "no partial position on revert");
            assertEq(pool.marketBorrows(address(nvda)), 0, "no debt on revert");
            _assertNoResidue();
        }
    }

    // ---------------------------------------------------------------- close / deleverage

    function test_close_fullLifecycle_cascadeFromSeed() public {
        uint256[] memory ids = _open18();
        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[2], ids[1], ids[0]); // smallest debt first
        usdg.mint(user, 875e6); // the seed: exactly the smallest rung's debt
        vm.prank(user);
        (uint256 assetOut, uint256 collOut) =
            multiply.close(pool, order, 875e6, false, 18_375e6, block.timestamp);
        // Cascade at $175, zero venue slippage: equity 17_500 + the 875 seed back, to the unit.
        assertEq(assetOut, 18_375e6, "equity + seed refund");
        assertEq(collOut, 0);
        assertEq(usdg.balanceOf(user), 18_375e6);
        assertEq(pool.marketBorrows(address(nvda)), 0, "book cleared");
        assertEq(note.balanceOf(user), 0, "all Notes burned");
        _assertNoResidue();
    }

    function test_close_toCollateral_userFundsDebt() public {
        uint256[] memory ids = _open18();
        usdg.mint(user, 14_000e6);
        vm.prank(user);
        (uint256 assetOut, uint256 collOut) =
            multiply.close(pool, ids, 14_000e6, true, 180e18, block.timestamp);
        assertEq(collOut, 180e18, "all collateral back as stock");
        assertEq(assetOut, 0);
        assertEq(nvda.balanceOf(user), 180e18);
        assertEq(usdg.balanceOf(user), 0, "seed fully consumed by debt");
        _assertNoResidue();
    }

    function test_partialDeleverage_closeSubsetOnly() public {
        uint256[] memory ids = _open18();
        uint256[] memory tail = new uint256[](2);
        (tail[0], tail[1]) = (ids[2], ids[1]);
        usdg.mint(user, 875e6);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, tail, 875e6, false, 8_750e6, block.timestamp);
        assertEq(assetOut, 8_750e6, "rungs 2+3 equity + seed");
        assertEq(pool.debtOf(ids[0]), 8_750e6, "rung 1 untouched");
        assertEq(note.ownerOf(ids[0]), user);
        assertEq(pool.marketBorrows(address(nvda)), 8_750e6);
        _assertNoResidue();
    }

    function test_close_withInterestAccrued() public {
        uint256[] memory ids = _open18();
        vm.warp(block.timestamp + 30 days);
        // Probe the precondition on a snapshot: accruing for real here would mask close()'s own
        // pool.accrue() (src/market/EsseyMultiply.sol) — deleting it must turn THIS test red.
        uint256 snap = vm.snapshotState();
        pool.accrue();
        uint256 owedSmallest = pool.debtOf(ids[2]);
        vm.revertToState(snap);
        // 14_000e6 against 486_000e6 idle cash is 280bps utilization -> 1000 + 500 x 280/8000 =
        // 1017bps, flat across the window. assetOut is the wrong place to look for the interest at
        // all (the price fixes the proceeds), so pin the debt and the seed the user actually spends.
        assertEq(owedSmallest, 882_314_041, "30 days at 1017bps on 875e6");
        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[2], ids[1], ids[0]);
        usdg.mint(user, 2_000e6);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, order, 2_000e6, false, 0, block.timestamp);
        assertEq(assetOut, 18_375e6, "proceeds + seed refund: the price never moved");
        assertEq(usdg.balanceOf(user), 2_000e6 - 992_024_656 + 18_375e6, "the interest comes out of the seed");
        assertEq(pool.marketBorrows(address(nvda)), 0);
        _assertNoResidue();
    }

    /// The founder constraint verbatim: closing must work in every state the pool's repay works
    /// in — market disabled, depth cap 0, feed stale, liveness dead, off-session. No oracle read
    /// and no gate sits on Multiply's close path.
    function test_close_worksUnderFullGatingLockdown() public {
        uint256[] memory ids = _open18();
        markets.disableMarket(address(nvda));
        health.postDepth(address(nvda), 0, uint64(block.number), "t"); // depth collapse -> cap 0
        vm.warp(block.timestamp + 26 hours); // feed stale, liveness gap blown, session over
        assertFalse(markets.canBorrow(address(nvda)), "borrows fully shut");
        assertFalse(markets.canLiquidate(address(nvda)), "even liquidation gated");

        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[2], ids[1], ids[0]);
        usdg.mint(user, 2_000e6);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, order, 2_000e6, false, 0, block.timestamp);
        // `> 0` is not "the exit works" — it passes on a cascade returning one unit.
        assertEq(assetOut, 18_375e6, "exit stayed open, at the full payout");
        assertEq(usdg.balanceOf(user), 2_000e6 - 879_225_889 + 18_375e6, "26h of interest, and no more");
        assertEq(pool.marketBorrows(address(nvda)), 0);
        _assertNoResidue();
    }

    function test_close_afterLiquidationOfOneRung() public {
        uint256[] memory ids = _open18();
        // $175 -> $110: rung 2 (50 NVDA / 4_375 debt) and rung 1 go underwater; rung 3 stays
        // healthy. A third party liquidates rung 2; the surplus lands with the USER (bearer Note).
        _walkPrice(110e8);
        usdg.mint(liquidator, 10_000e6);
        vm.startPrank(liquidator);
        usdg.approve(address(pool), type(uint256).max);
        pool.liquidate(ids[1]);
        vm.stopPrank();
        // `> before` passes for any surplus at all, so a hardcoded bonus survived: 4_375e6 debt +
        // the market's 500bp = 4_593.75e6 of value, at $110 = 41.7613... of the 50 NVDA posted.
        assertEq(nvda.balanceOf(liquidator), 41_761_363_636_363_636_363, "debt + the 5% bonus, and no more");
        assertEq(nvda.balanceOf(user), 8_238_636_363_636_363_637, "surplus refunded to the Note holder");

        // Passing the dead rung fails loudly...
        usdg.mint(user, 10_000e6);
        uint256[] memory dead = new uint256[](1);
        dead[0] = ids[1];
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.PositionAlreadyClosed.selector, ids[1]));
        multiply.close(pool, dead, 10_000e6, false, 0, block.timestamp);

        // ...and the surviving rungs close normally, at the crashed price: 130 NVDA sold at $110.
        uint256[] memory alive = new uint256[](2);
        (alive[0], alive[1]) = (ids[2], ids[0]);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, alive, 10_000e6, false, 0, block.timestamp);
        assertEq(assetOut, 11_550e6, "the surviving rungs' proceeds, at the crashed price");
        assertEq(usdg.balanceOf(user), 10_000e6 - 6_875e6 + 11_550e6, "seed consumed by the cascade");
        assertEq(pool.marketBorrows(address(nvda)), 0);
        _assertNoResidue();
    }

    /// A full LOSSY round trip, 50bps on all six legs. The close path deliberately carries no oracle
    /// floor (`minOut = 0` per leg): only the caller's own total `minOut` stands between a levered
    /// exit and a bad fill, and nothing pinned what such an exit actually pays.
    function test_close_throughALossyVenue_paysTheRealisedPriceNotTheOraclePrice() public {
        adapter.setSlippageBps(50);
        vm.prank(user);
        uint256[] memory ids = multiply.open(_params(18_000, 100, 8, 100));
        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[2], ids[1], ids[0]);

        usdg.mint(user, 1_100e6);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, order, 1_100e6, false, 0, block.timestamp);
        assertEq(assetOut, 18_300_428_671, "six lossy legs, priced at what the venue actually paid");
        assertEq(usdg.balanceOf(user), 1_100e6 - 1_027_578_672 + 18_300_428_671, "seed in, payout out");
        assertEq(pool.marketBorrows(address(nvda)), 0, "book cleared");
        _assertNoResidue();
    }

    function test_close_seedCapBinds() public {
        uint256[] memory ids = _open18();
        usdg.mint(user, 20_000e6); // more than any cascade needs: the GUARD must fire, not a balance shortfall
        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[0], ids[1], ids[2]); // biggest first: needs 8_750 up front
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.SeedExceeded.selector, 8_750e6, 875e6));
        multiply.close(pool, order, 875e6, false, 0, block.timestamp);
    }

    function test_close_minOutBinds() public {
        uint256[] memory ids = _open18();
        usdg.mint(user, 875e6);
        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[2], ids[1], ids[0]);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.SlippageExceeded.selector, 18_375e6, 18_375e6 + 1));
        multiply.close(pool, order, 875e6, false, 18_375e6 + 1, block.timestamp);
    }

    function test_close_wrongPool_reverts() public {
        uint256[] memory ids = _open18();
        EsseyPool other = new EsseyPool(
            IERC20(address(usdg)), address(nvda), new EsseyMarkets(
                AggregatorV3Interface(address(new MockFeed(8, 0))), liveness, health, address(this), address(this), 6
            ), 1000, 500, 6000, 1000, address(0), address(this), 0,
            EsseyPool.Identity("x", "x", "x", "x")
        );
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.WrongPool.selector);
        multiply.close(other, ids, 0, false, 0, block.timestamp);
    }

    /// A pool must be one the REGISTRY named or this periphery itself opened. Satisfying the old
    /// `markets()` check is not enough, and the difference is a permanent attacker-controlled claim
    /// on the real borrow asset sized by whatever the victim posted.
    function test_close_spoofedPoolIsRefused() public {
        uint256[] memory ids = _open18();
        SpoofPool fake = new SpoofPool(address(markets), address(nvda), address(usdg));
        assertEq(fake.markets(), address(markets), "the OLD binding is fully satisfied");
        usdg.mint(user, 10_000e6);
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.WrongPool.selector);
        multiply.close(EsseyPool(address(fake)), ids, 10_000e6, false, 0, block.timestamp);
        assertEq(usdg.allowance(address(multiply), address(fake)), 0, "no standing allowance is created");
    }

    /// And the real pool gets no standing allowance either: the periphery is stateless between
    /// transactions, which is only true if nothing survives the call.
    function test_close_leavesNoStandingAllowance() public {
        uint256[] memory ids = _open18();
        usdg.mint(user, 14_000e6);
        vm.prank(user);
        multiply.close(pool, ids, 14_000e6, true, 180e18, block.timestamp);
        assertEq(usdg.allowance(address(multiply), address(pool)), 0, "the approval is zeroed after repay");
    }

    /// A collateral-token pause makes the pool ESCROW rather than return (EsseyPool.claimCollateral),
    /// and the Note survives as the claim ticket. This periphery holds nothing between transactions,
    /// so a surviving Note must go back to the caller — its own header says anything left here is
    /// lost to whoever calls next.
    function test_close_underACollateralPauseHandsTheNoteBack() public {
        uint256[] memory ids = _open18();
        usdg.mint(user, 14_000e6);
        nvda.setPaused(true);
        vm.prank(user);
        (uint256 assetOut, uint256 collOut) = multiply.close(pool, ids, 14_000e6, true, 0, block.timestamp);
        assertEq(collOut, 0, "no stock could move");
        assertEq(assetOut, 0);
        for (uint256 i; i < ids.length; i++) {
            assertEq(note.ownerOf(ids[i]), user, "every claim ticket comes back to the caller");
            assertEq(pool.debtOf(ids[i]), 0, "and every debt is settled anyway");
        }
        _assertNoResidue();

        nvda.setPaused(false);
        for (uint256 i; i < ids.length; i++) {
            vm.prank(user);
            pool.claimCollateral(ids[i]);
        }
        assertEq(nvda.balanceOf(user), 180e18, "and the stock is collectable once the pause lifts");
    }

    // ---------------------------------------------------------------- config

    function test_listMarket_gates() public {
        vm.prank(user);
        vm.expectRevert(EsseyMultiply.NotAdmin.selector);
        multiply.listMarket(address(usdg), adapter, 15_000);

        vm.expectPartialRevert(EsseyMultiply.AlreadyListed.selector);
        multiply.listMarket(address(nvda), adapter, 15_000);

        vm.expectRevert(EsseyMultiply.AdapterNotContract.selector);
        multiply.listMarket(address(usdg), ISwapAdapter(address(0xDEAD)), 15_000);

        vm.expectRevert(EsseyMultiply.BadLeverageCap.selector);
        multiply.listMarket(address(usdg), adapter, 10_000);
    }

    // ---------------------------------------------------------------- helpers

    /// Re-commit the NVDA market with a different maxPositionBps, then restore the borrowable
    /// state (fresh heartbeat, feed stamp, depth reading) the 2-day timelock aged out.
    function _recommitMarket(uint16 maxPositionBps) internal {
        markets.proposeMarket(
            address(nvda), AggregatorV3Interface(address(nvdaFeed)), 86_400, 90_000, 8, address(nvda), address(pool),
            EsseyMarkets.Market({
                enabled: true, ltvBps: 5000, liqThresholdBps: 7500, liqBonusBps: 500,
                collateralDecimals: 18, cap: 250_000e6, maxPositionBps: maxPositionBps
            })
        );
        for (uint256 i = 0; i < 4; i++) { // 12h keeper cadence keeps the depth reading live through the timelock
            vm.warp(block.timestamp + 12 hours);
            health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");
        }
        vm.warp(block.timestamp + 1); // Friday 16:00 UTC — still a weekday session slot
        markets.commitMarket(address(nvda));
        liveness.heartbeat();
        _advanceLive(1 hours + 1); // serve out resumeGrace on a live cadence
        nvdaFeed.set(175e8, block.timestamp);
        health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");
    }

    /// Advance `secs` the way a LIVE keeper does — beating every gapThreshold/3 throughout — so the
    /// heartbeat never goes stale. Warping without beating models an OUTAGE, not the passage of time,
    /// and since G-LEND HIGH-1 the oracle can tell the difference: `liquidationsAllowed()` now closes
    /// on the same threshold `heartbeat()` calls a gap, so serving out resumeGrace requires the
    /// keeper to keep posting through it.
    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        uint256 step = liveness.gapThreshold() / 3;
        while (block.timestamp + step < end) {
            vm.warp(block.timestamp + step);
            liveness.heartbeat();
        }
        vm.warp(end);
        liveness.heartbeat();
    }

    /// Walk the feed to `target` in observed steps inside EsseyMarkets.MAX_PRICE_DEVIATION_BPS. A
    /// market MOVES; a corporate action GAPS, and since G-LEND R2 HIGH-1 a single step past the bound
    /// arms the desync breaker and holds both gates. See EsseyPool.t.sol:_walkPrice.
    function _walkPrice(int256 target) internal {
        (, int256 cur,,,) = nvdaFeed.latestRoundData();
        while (cur != target) {
            int256 next = target < cur ? (cur * 85) / 100 : (cur * 115) / 100;
            if (target < cur ? next < target : next > target) next = target;
            if (next == cur) next = target;
            cur = next;
            nvdaFeed.set(cur, block.timestamp);
            markets.syncMultiplier(address(nvda));
        }
        nvdaFeed.set(target, block.timestamp);
    }

}
