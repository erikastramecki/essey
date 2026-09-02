// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StockLpVault, IStockOracle} from "../src/market/StockLpVault.sol";
import {IUniV3PoolMin, TickMath} from "../src/market/EsseyLadderSeeder.sol";

interface IAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// Price comes from the REAL Chainlink aggregator on 4663, so nothing the vault computes feeds back into
/// its own oracle. `inSession` is pinned true — wall-clock policy, already pinned in the in-mock suite.
contract ForkOracle is IStockOracle {
    mapping(address => address) public feedOf;
    mapping(address => uint256) public override_;
    bool public session = true;

    function setFeed(address token, address feed) external {
        feedOf[token] = feed;
    }

    function setSession(bool s) external {
        session = s;
    }

    /// Only the truncation control uses this: an exactly-representable price is its counterfactual.
    function setOverride(address token, uint256 answer) external {
        override_[token] = answer;
    }

    function priceOf(address token) external view returns (uint256, uint8, bool) {
        IAggregator f = IAggregator(feedOf[token]);
        uint256 o = override_[token];
        if (o != 0) return (o, f.decimals(), session);
        (, int256 answer,,,) = f.latestRoundData();
        return (uint256(answer), f.decimals(), session);
    }
}

contract ForkSwapper {
    IUniV3PoolMin public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint160 internal constant MIN_SQRT = 4_295_128_739;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    constructor(IUniV3PoolMin p, IERC20 t0, IERC20 t1) {
        pool = p;
        token0 = t0;
        token1 = t1;
    }

    function swapExactIn(bool zeroForOne, uint256 amountIn) external returns (int256 a0, int256 a1) {
        return pool.swap(address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1, "");
    }

    function swapToPrice(bool zeroForOne, uint160 sqrtLimit) external returns (int256 a0, int256 a1) {
        return pool.swap(address(this), zeroForOne, type(int128).max, sqrtLimit, "");
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        require(msg.sender == address(pool), "not pool");
        if (d0 > 0) token0.transfer(msg.sender, uint256(d0));
        if (d1 > 0) token1.transfer(msg.sender, uint256(d1));
    }
}

/// StockLpVault against a LIVE Uniswap-V3 pool on Robinhood Chain mainnet (4663).
///
/// `MockV3Pool` reuses the vault's OWN `LiquidityAmounts`, so previewWithdraw-vs-burn and the position
/// value math are CIRCULAR in-mock (audit F-C, and F2 / S10 / S10b at test/mocks/MockV3Pool.sol:136-152).
/// A real pool prices the burn with its own SqrtPriceMath and reverts `NP` on an empty poke; only a fork
/// can settle them.
///
/// FORK TARGET — NVDA/USDG fee-500 pool `0xd4EB…14a3`, VERIFIED on chain 2026-09-02 by `cast` against
/// https://rpc.mainnet.chain.robinhood.com: factory `0x1f7d…2efa` `getPool(NVDA,USDG,500)` returns it;
/// `liquidity()` 9.916e18, the deepest stock/USDG pool on the chain (10 pairs x 4 tiers scanned);
/// token0 USDG 6-dec, token1 NVDA 18-dec, tickSpacing 10; slot0 implies ~$217.0/NVDA against the feed's
/// $216.79, ~0.1% apart. NVDA is a listed Essey market with a verified feed (docs/MAINNET-CONFIG.md:184).
contract StockLpVaultForkTest is Test {
    address constant POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    /// What a round trip may lose to V3 liquidity rounding and the AMOUNT_MARGIN left idle — NOT a
    /// tolerance for a mis-mark, which moved dollars a trip. Measured at ~$0.0002 on the live pool.
    uint256 constant ROUNDING_DUST_USD18 = 1e15; // $0.001

    uint16 constant PERF_BPS = 1_000;
    uint16 constant BOUNTY_BPS = 10;
    uint256 constant DEV_BPS = 100;

    address keeper = address(0xCAFE1);
    address governor = address(0x600D);
    address feeRecipient = address(0xFEE5);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    IUniV3PoolMin pool = IUniV3PoolMin(POOL);
    IERC20 usdg = IERC20(USDG);
    IERC20 nvda = IERC20(NVDA);
    ForkOracle oracle;
    ForkSwapper swapper;
    StockLpVault vault;

    int24 spacing;
    int24 lowWide;
    int24 highWide;
    int24 lowNarrow;
    int24 highNarrow;
    bool forked;

    function setUp() public {
        // Unpinned, like test/EsseyReserveHookFork.t.sol:34 — and forced: the RH RPC prunes state, so a
        // pinned block returns `metadata is not found` within minutes (VERIFIED at 52_549_624).
        try vm.createSelectFork(vm.rpcUrl("rh_mainnet")) {
            forked = true;
        } catch {
            forked = false;
            return;
        }

        oracle = new ForkOracle();
        oracle.setFeed(NVDA, NVDA_FEED);
        oracle.setFeed(USDG, USDG_FEED);
        swapper = new ForkSwapper(pool, usdg, nvda);
        vault = _newVault(DEV_BPS);

        spacing = pool.tickSpacing();
        deal(NVDA, address(swapper), 2_000_000e18);
        deal(USDG, address(swapper), 500_000_000e6);
        _alignSpotToOracle();

        (, int24 tick,,,,,) = pool.slot0();
        int24 center = (tick / spacing) * spacing;
        lowWide = center - 20 * spacing;
        highWide = center + 20 * spacing;
        lowNarrow = center - 3 * spacing;
        highNarrow = center + 3 * spacing;

        _fund(alice);
        _fund(bob);
    }

    /// Live state drifts and the gate is 1%, so without this `deposit` would be callable only some runs.
    function _alignSpotToOracle() internal {
        uint160 target = _oracleSqrt();
        swapper.swapToPrice(_spotSqrt() > target, target);
        assertLe(_deviationBps(), 5, "could not align real pool spot to the oracle mark");
    }

    function _oracleSqrt() internal view returns (uint160) {
        (uint256 pS, uint8 dS,) = oracle.priceOf(NVDA);
        (uint256 pB, uint8 dB,) = oracle.priceOf(USDG);
        uint256 fS = pS * (10 ** (36 - dS - 18)); // mirrors _factor: USD 1e36 per raw token, no divide
        uint256 fB = pB * (10 ** (36 - dB - 6));
        return uint160(Math.sqrt(Math.mulDiv(fB, uint256(1) << 192, fS)));
    }

    function _newVault(uint256 devBps) internal returns (StockLpVault) {
        return new StockLpVault(
            StockLpVault.VaultConfig({
                pool: pool,
                oracle: IStockOracle(address(oracle)),
                stock: nvda,
                base: usdg,
                keeper: keeper,
                governor: governor,
                feeRecipient: feeRecipient,
                maxDeviationBps: devBps,
                performanceFeeBps: PERF_BPS,
                bountyBps: BOUNTY_BPS,
                name: "Essey NVDA LP",
                symbol: "eNVDA-LP"
            })
        );
    }

    function _fund(address who) internal {
        deal(NVDA, who, 10_000e18);
        deal(USDG, who, 5_000_000e6);
        vm.startPrank(who);
        nvda.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _seed(int24 lo, int24 hi) internal {
        vm.prank(keeper);
        vault.rebalance(lo, hi);
    }

    function _deposit(address who, uint256 stockAmt, uint256 baseAmt) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(stockAmt, baseAmt, 0);
    }

    /// Full-precision USD (1e18) at the live feed marks — deliberately NOT the vault's `_factor`, which
    /// floors an 18-dec stock to whole dollars. Skim must be measured against the real price.
    function _usd18(uint256 stockRaw, uint256 baseRaw) internal view returns (uint256) {
        (uint256 pS, uint8 dS,) = oracle.priceOf(NVDA);
        (uint256 pB, uint8 dB,) = oracle.priceOf(USDG);
        uint256 s = Math.mulDiv(stockRaw, pS * (10 ** (18 - dS)), 1e18);
        uint256 b = Math.mulDiv(baseRaw, pB * (10 ** (18 - dB)), 1e6);
        return s + b;
    }

    function _pendingBounty() internal view returns (uint256 b0, uint256 b1) {
        (uint256 f0, uint256 f1) = vault.pendingFees();
        b0 = f0 * BOUNTY_BPS / 10_000;
        b1 = f1 * BOUNTY_BPS / 10_000;
    }

    function _vaultLiquidity() internal view returns (uint256 liq) {
        bytes32 key = keccak256(abi.encodePacked(address(vault), vault.tickLower(), vault.tickUpper()));
        (liq,,,,) = pool.positions(key);
    }

    function _spotSqrt() internal view returns (uint160 s) {
        (s,,,,,,) = pool.slot0();
    }

    /// |pool spot - oracle|, in bps of price, exactly as `_requireTradeable` computes it.
    function _deviationBps() internal view returns (uint256) {
        uint256 r = Math.mulDiv(_oracleSqrt(), 1e18, _spotSqrt());
        uint256 ratio = Math.mulDiv(r, r, 1e18);
        uint256 diff = ratio > 1e18 ? ratio - 1e18 : 1e18 - ratio;
        return diff * 10_000 / 1e18;
    }

    function _skip() internal returns (bool) {
        if (forked) return false;
        emit log("SKIP: rh_mainnet fork unavailable");
        return true;
    }

    // ================================================================ F-C: preview vs a REAL pool.burn

    /// F-C — the whole point of this file. `previewWithdraw` prices the slice with the vault's own
    /// `LiquidityAmounts`, the real `pool.burn` with Uniswap's `SqrtPriceMath`: in-mock the same code, so
    /// the assertion was vacuous. Balance DELTAS are asserted, not just the return values.
    function test_fork_previewWithdraw_matches_real_pool_burn() public {
        if (_skip()) return;
        _seed(lowWide, highWide);
        uint256 shares = _deposit(alice, 500e18, 110_000e6);

        swapper.swapExactIn(false, 300e18);
        swapper.swapExactIn(true, 40_000e6);

        (uint256 pStock, uint256 pBase) = vault.previewWithdraw(shares);
        (uint256 bounty0, uint256 bounty1) = _pendingBounty();

        uint256 s0 = nvda.balanceOf(alice);
        uint256 b0 = usdg.balanceOf(alice);
        vm.prank(alice);
        (uint256 aStock, uint256 aBase) = vault.withdraw(shares, 0, 0);
        uint256 dStock = nvda.balanceOf(alice) - s0;
        uint256 dBase = usdg.balanceOf(alice) - b0;

        // The withdrawer also cranks the harvest, so the bounty lands on the SAME address: withdrawal +
        // bounty and nothing else, so a stray transfer in either direction breaks this.
        assertEq(dStock, aStock + bounty1, "stock delta != withdrawal + crank bounty");
        assertEq(dBase, aBase + bounty0, "base delta != withdrawal + crank bounty");
        assertGt(bounty0 + bounty1, 0, "no fees pending: the fee leg of the preview proves nothing");
        assertApproxEqAbs(aStock, pStock, 2, "F-C: preview stock vs real burn");
        assertApproxEqAbs(aBase, pBase, 2, "F-C: preview base vs real burn");
        assertGt(aStock, 0, "no stock out");
        assertGt(aBase, 0, "no base out");
    }

    /// F-C, partial exit — a whole-position exit could hide a fraction-rounding bug.
    function test_fork_previewWithdraw_matches_real_partial_burn() public {
        if (_skip()) return;
        _seed(lowWide, highWide);
        uint256 shares = _deposit(alice, 500e18, 110_000e6);
        swapper.swapExactIn(false, 250e18);

        uint256 liqBefore = _vaultLiquidity();
        uint256 part = shares / 3;
        (uint256 pStock, uint256 pBase) = vault.previewWithdraw(part);
        vm.prank(alice);
        (uint256 aStock, uint256 aBase) = vault.withdraw(part, 0, 0);
        assertApproxEqAbs(aStock, pStock, 2, "F-C partial: preview stock");
        assertApproxEqAbs(aBase, pBase, 2, "F-C partial: preview base");
        // Read back from the REAL pool: the fraction must have come out of the position, not all of it.
        assertApproxEqRel(_vaultLiquidity(), liqBefore - liqBefore / 3, 1e12, "partial burn took the wrong slice");

        (uint256 pStock2, uint256 pBase2) = vault.previewWithdraw(shares - part);
        vm.prank(alice);
        (uint256 aStock2, uint256 aBase2) = vault.withdraw(shares - part, 0, 0);
        assertApproxEqAbs(aStock2, pStock2, 2, "F-C remainder: preview stock");
        assertApproxEqAbs(aBase2, pBase2, 2, "F-C remainder: preview base");
        assertEq(vault.totalSupply(), 0, "supply must be fully burned");
    }

    // ================================================================ F2: pendingFees on a real pool

    /// F2 — the mock's `ticks()` returns zeros, so `feeGrowthOutside` is always 0 and the out-of-range
    /// arms of `_feeGrowthInside` never execute. Real boundary ticks carry NONZERO growth-outside the
    /// moment they initialize. Pinned inside, below, above, and on each boundary exactly.
    function test_fork_pendingFees_predicts_harvest_in_and_out_of_range() public {
        if (_skip()) return;
        _seed(lowNarrow, highNarrow);
        _deposit(alice, 400e18, 90_000e6);
        _assertBoundaryTicksCarryOutsideGrowth();

        swapper.swapExactIn(false, 120e18);
        _assertTickInside(true);
        _assertPendingMatchesHarvest("in-range");

        // Each traversal earns fees on the way through, then parks spot outside: the out-of-range arm
        // is what must value them.
        swapper.swapToPrice(false, TickMath.getSqrtRatioAtTick(highNarrow + 5 * spacing));
        _assertTickInside(false);
        _assertPendingMatchesHarvest("above-range");

        swapper.swapToPrice(true, TickMath.getSqrtRatioAtTick(lowNarrow - 5 * spacing));
        _assertTickInside(false);
        _assertPendingMatchesHarvest("below-range");

        // The arms' off-by-one mutants only separate at an exact boundary tick, and V3 lands ON the
        // boundary approaching from below but one short coming down — hence the pairing.
        swapper.swapToPrice(false, TickMath.getSqrtRatioAtTick(highNarrow));
        _assertTickEquals(highNarrow, "spot must sit exactly on tickUpper");
        _assertPendingMatchesHarvest("exactly-at-upper");

        swapper.swapToPrice(true, TickMath.getSqrtRatioAtTick(lowNarrow - 3 * spacing));
        swapper.swapToPrice(false, TickMath.getSqrtRatioAtTick(lowNarrow));
        _assertTickEquals(lowNarrow, "spot must sit exactly on tickLower");
        _assertPendingMatchesHarvest("exactly-at-lower");
    }

    function _assertTickEquals(int24 want, string memory why) internal view {
        (, int24 tick,,,,,) = pool.slot0();
        assertEq(tick, want, why);
    }

    function _assertTickInside(bool want) internal view {
        (, int24 tick,,,,,) = pool.slot0();
        bool inside = tick >= lowNarrow && tick < highNarrow;
        assertEq(inside, want, "tick not where the leg needs it");
    }

    /// Without nonzero growth-outside the arms still run against zeros and this file proves nothing.
    function _assertBoundaryTicksCarryOutsideGrowth() internal view {
        (,, uint256 lo0, uint256 lo1,,,,) = IUniV3PoolFeesView(POOL).ticks(lowNarrow);
        (,, uint256 up0, uint256 up1,,,,) = IUniV3PoolFeesView(POOL).ticks(highNarrow);
        assertGt(lo0 + lo1 + up0 + up1, 0, "real pool must carry nonzero feeGrowthOutside");
    }

    function _assertPendingMatchesHarvest(string memory leg) internal {
        (uint256 p0, uint256 p1) = vault.pendingFees();
        (uint256 h0, uint256 h1) = vault.harvest();
        assertEq(h0, p0, string.concat(leg, ": pendingFees0 != harvested0"));
        assertEq(h1, p1, string.concat(leg, ": pendingFees1 != harvested1"));
        assertGt(p0 + p1, 0, string.concat(leg, ": no fees accrued, leg proves nothing"));
    }

    // ================================================================ S10 / S10b: empty-position NP

    /// S10 — the real pool rejects a zero-liquidity poke with `NP` while the mock no-ops it, so the
    /// `_liquidity() > 0` guard (src/market/StockLpVault.sol:359) was unpinnable in-mock. Proven on the
    /// REAL pool against the vault's OWN position key, then shown the guarded path survives.
    function test_fork_empty_position_poke_reverts_NP_but_harvest_is_guarded() public {
        if (_skip()) return;
        _seed(lowWide, highWide); // rangeSet, but zero liquidity: nothing has been deposited
        assertEq(vault.rangeSet(), true, "range must be set");

        vm.prank(address(vault));
        vm.expectRevert(bytes("NP"));
        pool.burn(lowWide, highWide, 0);

        vault.harvest(); // guard holds: no poke is attempted, so no NP
        (uint256 f0, uint256 f1) = vault.pendingFees();
        assertEq(f0, 0, "empty position owes no fee0");
        assertEq(f1, 0, "empty position owes no fee1");
    }

    /// S10b — the same guard in `rebalance` (src/market/StockLpVault.sol:344). Moving off an EMPTY range
    /// must not burn/collect it; on the real pool that reverts `NP` and bricks the keeper.
    function test_fork_rebalance_off_empty_range_is_guarded() public {
        if (_skip()) return;
        _seed(lowWide, highWide);
        _seed(lowNarrow, highNarrow);
        assertEq(vault.tickLower(), lowNarrow, "range must have moved");
        assertEq(vault.tickUpper(), highNarrow, "range must have moved");
    }

    /// The converse: with liquidity the skipped poke succeeds, so the guard is narrow, not a blanket.
    function test_fork_funded_position_poke_succeeds() public {
        if (_skip()) return;
        _seed(lowWide, highWide);
        _deposit(alice, 100e18, 22_000e6);
        vm.prank(address(vault));
        pool.burn(lowWide, highWide, 0);
    }

    // ================================================================ L-A-1 + the mis-mark it exposed

    /// FINDING, FIXED. `_factor` used to divide by `10 ** tokenDec`, which for an 18-dec stock FLOORED
    /// the mark to whole dollars — NVDA's live feed reads $216.7894 and the vault marked it $216. Shares
    /// minted against that under-mark, so bringing the EXACTLY-priced leg (USDG) and burning for a
    /// pro-rata slice of the UNDER-marked one netted the difference at zero pool deviation,
    /// permissionlessly and repeatably; the stock depositor paid it. MEASURED before the fix on this same
    /// live pool: +20 bps a trip in, -20 bps a trip out, against a 44 bps mis-mark. The mark is now
    /// carried at USD 1e36 with no divide (src/market/StockLpVault.sol:466), so a non-integral price
    /// leaks nothing. Invisible in-mock, whose 220e8 feed the old `_factor` represented exactly
    /// (test/StockLpVault.t.sol:83) — which is why this lives on the fork.
    function test_fork_FINDING_whole_dollar_mark_truncation_is_fixed() public {
        if (_skip()) return;
        uint256 wouldLeakBps = _priceRemainderBps();
        (int256 basePnl, uint256 baseIn) = _roundTripPnl(false, false, 0, 22_000e6);
        (int256 stockPnl,) = _roundTripPnl(false, false, 100e18, 0);
        emit log_named_uint("bps the old whole-dollar mark discarded", wouldLeakBps);
        emit log_named_int("zero-deviation base-only round trip, USD 1e18", basePnl);
        emit log_named_int("zero-deviation stock-only round trip, USD 1e18", stockPnl);

        // A near-integral live price leaves nothing to leak either way, so the pins would assert on noise.
        if (wouldLeakBps < 10) {
            emit log("live price is near-integral this run; the fix is not being exercised");
            return;
        }
        // The band is only meaningful while it sits far below what the old mark actually moved.
        assertGt(wouldLeakBps * baseIn / 10_000, 100 * ROUNDING_DUST_USD18, "mis-mark too small to discriminate");
        assertLe(_abs(basePnl), ROUNDING_DUST_USD18, "the exactly-priced leg must extract nothing");
        assertLe(_abs(stockPnl), ROUNDING_DUST_USD18, "the stock depositor must no longer pay a mis-mark");
    }

    /// The control that names the cause: same pool, same trip, a mark `_factor` represents EXACTLY. The
    /// leak goes to zero, so it is the flooring — not pool mechanics, fees or rounding.
    function test_fork_FINDING_leak_vanishes_when_the_mark_is_exactly_representable() public {
        if (_skip()) return;
        oracle.setOverride(NVDA, 216e8);
        _alignSpotToOracle();
        assertEq(_priceRemainderBps(), 0, "override must be exactly representable");

        assertEq(_roundTripBps(false, false, 0, 22_000e6), 0, "base-only trip must be free of the mark");
        assertEq(_roundTripBps(false, false, 100e18, 0), 0, "stock-only trip must be free of the mark");
    }

    /// L-A-1 — deposit mints at the ORACLE mark while withdraw pays a SPOT-basis pro-rata slice, so a
    /// round trip taken off-oracle skims the incumbent. Measured as the DIFFERENCE against the same trip
    /// at zero deviation so the mis-mark is not double-counted, and in BOTH directions.
    function test_fork_two_sided_roundtrip_skim_bounded_at_max_deviation() public {
        if (_skip()) return;
        int256 flat = _roundTripBps(false, false, 100e18, 22_000e6);
        int256 dearer = _roundTripBps(true, true, 100e18, 22_000e6);
        int256 cheaper = _roundTripBps(true, false, 100e18, 22_000e6);
        emit log_named_int("two-sided flat bps", flat);
        emit log_named_int("two-sided stock-dearer bps", dearer);
        emit log_named_int("two-sided stock-cheaper bps", cheaper);

        assertLe(_abs(dearer - flat), 25, "L-A-1: deviation term above the pinned bound");
        assertLe(_abs(cheaper - flat), 25, "L-A-1: deviation term above the pinned bound");
    }

    /// L-A-1 control — the single-sided MVP shape the scope calls arb-free. At ZERO deviation it now is:
    /// while the mark truncated, the stock-only trip lost the mis-mark before any deviation term, and
    /// this test asserted that it was NOT free. What remains is the deviation term alone, bounded.
    function test_fork_single_sided_roundtrip_costs_only_the_deviation_term() public {
        if (_skip()) return;
        (int256 flatPnl,) = _roundTripPnl(false, false, 100e18, 0);
        int256 flat = _roundTripBps(false, false, 100e18, 0);
        int256 dearer = _roundTripBps(true, true, 100e18, 0);
        emit log_named_int("single-sided flat, USD 1e18", flatPnl);
        emit log_named_int("single-sided stock-dearer bps", dearer);

        assertLe(_abs(dearer - flat), 25, "L-A-1: single-sided deviation term above the pinned bound");
        assertLe(_abs(flatPnl), ROUNDING_DUST_USD18, "at zero deviation the single-sided trip is dust-free");
    }

    /// One round trip by a second entrant against a seeded incumbent, at TRUE marks, in bps of the input.
    function _roundTripBps(bool pushed, bool dearer, uint256 inStock, uint256 inBase) internal returns (int256) {
        (int256 pnl, uint256 valueIn) = _roundTripPnl(pushed, dearer, inStock, inBase);
        return pnl * 10_000 / int256(valueIn);
    }

    /// The same trip in signed USD-1e18, for assertions the bps rounding would swallow: a 20 bps skim on
    /// a $22k trip is ~$44, but so is anything under 1 bps, and the fix has to leave DUST, not "0 bps".
    function _roundTripPnl(bool pushed, bool dearer, uint256 inStock, uint256 inBase)
        internal
        returns (int256 pnl, uint256 valueIn)
    {
        uint256 snap = vm.snapshotState();
        _seed(lowWide, highWide);
        _deposit(alice, 500e18, 110_000e6);
        if (pushed) _pushDeviation(dearer);

        valueIn = _usd18(inStock, inBase);
        uint256 shares = _deposit(bob, inStock, inBase);
        vm.prank(bob);
        (uint256 outStock, uint256 outBase) = vault.withdraw(shares, 0, 0);
        pnl = int256(_usd18(outStock, outBase)) - int256(valueIn);
        vm.revertToState(snap);
    }

    /// The fractional-dollar remainder of the live stock price, in bps of it — exactly what the old
    /// whole-dollar mark discarded, and so the size of the leak the rescale removes.
    function _priceRemainderBps() internal view returns (uint256) {
        (uint256 px, uint8 dec,) = oracle.priceOf(NVDA);
        uint256 truePx = px * (10 ** (18 - dec));
        return (truePx - (truePx / 1e18) * 1e18) * 10_000 / truePx;
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return v < 0 ? uint256(-v) : uint256(v);
    }

    /// Park the REAL pool just inside the deviation gate. token1 is the stock, so the quoted sqrt is
    /// NVDA-per-USDG and making the stock DEARER drives sqrt DOWN — the zeroForOne direction. A price
    /// move is ~half that in sqrt; the target comes off the ORACLE sqrt so it does not drift with spot.
    function _pushDeviation(bool stockDearerThanOracle) internal {
        uint256 halfBps = (DEV_BPS * 9) / 20;
        uint256 o = _oracleSqrt();
        uint160 target =
            stockDearerThanOracle ? uint160(o * (10_000 - halfBps) / 10_000) : uint160(o * (10_000 + halfBps) / 10_000);
        swapper.swapToPrice(stockDearerThanOracle, target);
        uint256 dev = _deviationBps();
        assertGe(dev, 75, "deviation not pushed near the gate ceiling");
        assertLe(dev, DEV_BPS, "deviation escaped the gate the vault enforces");
    }

    // ================================================================ F-A / F-B boundaries

    /// F-A — the ceiling is inclusive: exactly `MAX_DEVIATION_CEIL_BPS` is legal, one over is not.
    function test_fork_maxDeviation_ceiling_is_inclusive_at_500() public {
        if (_skip()) return;
        StockLpVault v = _newVault(500);
        assertEq(v.maxDeviationBps(), 500, "500 must be accepted");
        vm.expectRevert(StockLpVault.BadConfig.selector);
        _newVault(501);
    }

    /// F-B — `minShares` is inclusive, and the first deposit mints exactly its oracle-mark USD. Since the
    /// mark truncation was fixed that USD is the TRUE one: `_usd18` is derived from the feed independently
    /// of `_factor`, so the equality below also pins the rescale end to end.
    function test_fork_minShares_equal_is_accepted() public {
        if (_skip()) return;
        _seed(lowWide, highWide);
        (uint256 pS, uint8 dS,) = oracle.priceOf(NVDA);
        (uint256 pB, uint8 dB,) = oracle.priceOf(USDG);
        uint256 expected = (100e18 * (pS * (10 ** (36 - dS - 18))) + 22_000e6 * (pB * (10 ** (36 - dB - 6)))) / 1e18;

        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, 22_000e6, expected);
        assertEq(shares, expected, "first deposit must mint exactly its oracle-mark USD");
        assertApproxEqAbs(shares, _usd18(100e18, 22_000e6), 1, "and that USD is the feed's true mark");
    }
}

interface IUniV3PoolFeesView {
    function ticks(int24 tick) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool);
}
