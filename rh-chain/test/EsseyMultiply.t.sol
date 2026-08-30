// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {EsseyMultiply} from "../src/market/EsseyMultiply.sol";
import {Note} from "../src/market/Note.sol";
import {MockFeed} from "../src/testnet/MockFeed.sol";
import {ScaledUIStockMock} from "../src/testnet/ScaledUIStockMock.sol";

/// Feed-priced mock venue. Deliberately does NOT enforce `minOut` and can be told to lie
/// (deliver less than it claims): both exist so Multiply's OWN guards are what the tests
/// exercise, never a protection the venue happens to duplicate.
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
        out = tokenIn == usdg ? (amountIn * 1e8) / uint256(price) : (amountIn * uint256(price)) / 1e8;
        out = (out * (10_000 - slippageBps)) / 10_000;
        IERC20(tokenOut).transfer(to, (out * deliverBps) / 10_000);
    }
}

contract EsseyMultiplyTest is Test {
    EsseyMarkets markets;
    EsseyPool pool;
    MarketHealthOracle health;
    LivenessOracle liveness;
    EsseyMultiply multiply;
    MockSwapAdapter adapter;
    ScaledUIStockMock usdg;
    ScaledUIStockMock nvda;
    MockFeed nvdaFeed;
    Note note;

    address lender = address(0xA1);
    address user = address(0xB0B);
    address liquidator = address(0x11C);

    uint256 constant DEPTH = 1_500_000e18; // cap fraction 3_333 -> oracle cap ~499_950e18, static 250k binds

    function setUp() public {
        MockFeed seqFeed = new MockFeed(8, 0);
        usdg = new ScaledUIStockMock("Mock USDG", "USDG");
        nvda = new ScaledUIStockMock("Mock NVDA", "NVDA");
        liveness = new LivenessOracle(address(this), address(this), 90_000, 1 hours, 900);
        health = new MarketHealthOracle(address(this), address(this), address(this));
        markets = new EsseyMarkets(
            AggregatorV3Interface(address(seqFeed)), liveness, health, address(this), address(this), 18
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
                collateralDecimals: 18, cap: 250_000e18, maxPositionBps: 10_000
            })
        );
        vm.warp(block.timestamp + 2 days + 1);
        markets.commitMarket(address(nvda));
        // Ride the depth-oracle ramp up to the pinned Wednesday on a live keeper cadence — a
        // silent warp past MAX_READING_AGE resets it. 24 days covers raiseDelay + the ~20-day
        // climb of the 499_950e18 target on the 250k-clamped base.
        vm.warp(1787151600 - 24 days);
        health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");
        for (uint256 i = 0; i < 48; i++) {
            vm.warp(block.timestamp + 12 hours);
            health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");
        }

        // now at 1787151600: Wednesday 15:00 UTC — inside the US session (the BorrowFlow pin)
        liveness.heartbeat();
        vm.warp(block.timestamp + 1 hours + 1);
        nvdaFeed.set(175e8, block.timestamp);
        health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");

        multiply = new EsseyMultiply(markets);
        adapter = new MockSwapAdapter(nvdaFeed, address(usdg));
        multiply.listMarket(address(nvda), adapter, 20_000);
        usdg.mint(address(adapter), 1_000_000e18);
        nvda.mint(address(adapter), 10_000e18);

        usdg.mint(lender, 500_000e18);
        vm.startPrank(lender);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e18, lender);
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
        // 100 NVDA @ $175, LTV 50%: rungs borrow 8750/4375/875, buying 50/25/5 NVDA; the final
        // 5 folds into rung 1. Exact because the mock venue fills at oracle price with 0 slippage.
        assertEq(ids.length, 3, "three rungs");
        assertEq(pool.debtOf(ids[0]), 8_750e18);
        assertEq(pool.debtOf(ids[1]), 4_375e18);
        assertEq(pool.debtOf(ids[2]), 875e18);
        (, uint256 c1,,,) = pool.positions(ids[0]);
        assertEq(c1, 105e18, "final purchase folded into rung 1");
        for (uint256 i; i < ids.length; ++i) {
            assertEq(note.ownerOf(ids[i]), user, "bearer Note with the user");
        }
        assertEq(pool.marketBorrows(address(nvda)), 14_000e18, "2x-1 of equity in debt");
        assertEq(nvda.balanceOf(user), 0, "all stock deployed");
        _assertNoResidue();
    }

    function test_open_twoX_reachableWithEnoughRungs_notWithFew() public {
        // LTV 50% makes 2.0x the asymptote: 10 rungs land within 1%, 2 rungs cannot.
        vm.prank(user);
        uint256[] memory ids = multiply.open(_params(20_000, 100, 10, 100));
        assertGe(ids.length, 8);
        _assertNoResidue();
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
        vm.expectPartialRevert(EsseyMultiply.SlippageExceeded.selector);
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
        // Depth collapse: down is same-block. Cap 3k*3.333 ~ 9_999e18: rung 1 (8750) fits,
        // rung 2 (4375 more) crosses — the WHOLE open must unwind, not leave rung 1 behind.
        health.postDepth(address(nvda), 30_000e18, uint64(block.number), "test-v1");
        vm.prank(user);
        vm.expectPartialRevert(EsseyPool.ExceedsMarketCap.selector);
        multiply.open(_params(18_000, 100, 8, 100));
        assertEq(nvda.balanceOf(user), 100e18, "collateral back with the user");
        assertEq(note.balanceOf(user), 0, "no partial ladder");
        assertEq(pool.marketBorrows(address(nvda)), 0, "no debt landed");
        _assertNoResidue();
    }

    function test_open_positionCapExceeded_revertsWhole() public {
        _recommitMarket(200); // posLimit = 250k * 2% = 5_000e18 < rung 1's 8_750e18
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
        depth = uint128(bound(depth, 1e18, 3_000_000e18));
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
        usdg.mint(user, 875e18); // the seed: exactly the smallest rung's debt
        vm.prank(user);
        (uint256 assetOut, uint256 collOut) =
            multiply.close(pool, order, 875e18, false, 18_375e18, block.timestamp);
        // Cascade at $175, zero venue slippage: equity 17_500 + the 875 seed back, to the wei.
        assertEq(assetOut, 18_375e18, "equity + seed refund");
        assertEq(collOut, 0);
        assertEq(usdg.balanceOf(user), 18_375e18);
        assertEq(pool.marketBorrows(address(nvda)), 0, "book cleared");
        assertEq(note.balanceOf(user), 0, "all Notes burned");
        _assertNoResidue();
    }

    function test_close_toCollateral_userFundsDebt() public {
        uint256[] memory ids = _open18();
        usdg.mint(user, 14_000e18);
        vm.prank(user);
        (uint256 assetOut, uint256 collOut) =
            multiply.close(pool, ids, 14_000e18, true, 180e18, block.timestamp);
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
        usdg.mint(user, 875e18);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, tail, 875e18, false, 8_750e18, block.timestamp);
        assertEq(assetOut, 8_750e18, "rungs 2+3 equity + seed");
        assertEq(pool.debtOf(ids[0]), 8_750e18, "rung 1 untouched");
        assertEq(note.ownerOf(ids[0]), user);
        assertEq(pool.marketBorrows(address(nvda)), 8_750e18);
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
        assertGt(owedSmallest, 875e18, "interest accrued");
        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[2], ids[1], ids[0]);
        usdg.mint(user, 2_000e18);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, order, 2_000e18, false, 0, block.timestamp);
        // Interest reduces equity below the crisp 17_500 + seed figure but the cascade still clears.
        assertGt(assetOut, 18_000e18);
        assertLt(assetOut, 19_500e18);
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
        usdg.mint(user, 2_000e18);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, order, 2_000e18, false, 0, block.timestamp);
        assertGt(assetOut, 0, "exit stayed open");
        assertEq(pool.marketBorrows(address(nvda)), 0);
        _assertNoResidue();
    }

    function test_close_afterLiquidationOfOneRung() public {
        uint256[] memory ids = _open18();
        // $175 -> $110: rung 2 (50 NVDA / 4_375 debt) and rung 1 go underwater; rung 3 stays
        // healthy. A third party liquidates rung 2; the surplus lands with the USER (bearer Note).
        nvdaFeed.set(110e8, block.timestamp);
        uint256 nvdaBefore = nvda.balanceOf(user);
        usdg.mint(liquidator, 10_000e18);
        vm.startPrank(liquidator);
        usdg.approve(address(pool), type(uint256).max);
        pool.liquidate(ids[1]);
        vm.stopPrank();
        assertGt(nvda.balanceOf(user), nvdaBefore, "liquidation surplus refunded to the holder");

        // Passing the dead rung fails loudly...
        usdg.mint(user, 10_000e18);
        uint256[] memory dead = new uint256[](1);
        dead[0] = ids[1];
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.PositionAlreadyClosed.selector, ids[1]));
        multiply.close(pool, dead, 10_000e18, false, 0, block.timestamp);

        // ...and the surviving rungs close normally, at the crashed price.
        uint256[] memory alive = new uint256[](2);
        (alive[0], alive[1]) = (ids[2], ids[0]);
        vm.prank(user);
        (uint256 assetOut,) = multiply.close(pool, alive, 10_000e18, false, 0, block.timestamp);
        assertGt(assetOut, 0);
        assertEq(pool.marketBorrows(address(nvda)), 0);
        _assertNoResidue();
    }

    function test_close_seedCapBinds() public {
        uint256[] memory ids = _open18();
        usdg.mint(user, 20_000e18); // more than any cascade needs: the GUARD must fire, not a balance shortfall
        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[0], ids[1], ids[2]); // biggest first: needs 8_750 up front
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EsseyMultiply.SeedExceeded.selector, 8_750e18, 875e18));
        multiply.close(pool, order, 875e18, false, 0, block.timestamp);
    }

    function test_close_minOutBinds() public {
        uint256[] memory ids = _open18();
        usdg.mint(user, 875e18);
        uint256[] memory order = new uint256[](3);
        (order[0], order[1], order[2]) = (ids[2], ids[1], ids[0]);
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.SlippageExceeded.selector);
        multiply.close(pool, order, 875e18, false, 18_375e18 + 1, block.timestamp);
    }

    function test_close_wrongPool_reverts() public {
        uint256[] memory ids = _open18();
        EsseyPool other = new EsseyPool(
            IERC20(address(usdg)), address(nvda), new EsseyMarkets(
                AggregatorV3Interface(address(new MockFeed(8, 0))), liveness, health, address(this), address(this), 18
            ), 1000, 500, 6000, 1000, address(0), address(this), 0,
            EsseyPool.Identity("x", "x", "x", "x")
        );
        vm.prank(user);
        vm.expectPartialRevert(EsseyMultiply.WrongPool.selector);
        multiply.close(other, ids, 0, false, 0, block.timestamp);
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
                collateralDecimals: 18, cap: 250_000e18, maxPositionBps: maxPositionBps
            })
        );
        for (uint256 i = 0; i < 4; i++) { // 12h keeper cadence keeps the depth reading live through the timelock
            vm.warp(block.timestamp + 12 hours);
            health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");
        }
        vm.warp(block.timestamp + 1); // Friday 16:00 UTC — still a weekday session slot
        markets.commitMarket(address(nvda));
        liveness.heartbeat();
        vm.warp(block.timestamp + 1 hours + 1);
        nvdaFeed.set(175e8, block.timestamp);
        health.postDepth(address(nvda), uint128(DEPTH), uint64(block.number), "test-v1");
    }
}
