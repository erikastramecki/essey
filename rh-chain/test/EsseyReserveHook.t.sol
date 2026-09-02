// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {EsseyReserveHook, IEsseyReserve} from "../src/market/EsseyReserveHook.sol";
import {EsseyReserve} from "../src/market/EsseyReserve.sol";

contract MockEssey is ERC20 {
  constructor(uint256 supply) ERC20("ESSEY", "ESSEY") {
    _mint(msg.sender, supply);
  }
  function burn(uint256 a) external {
    _burn(msg.sender, a);
  }
}

contract MockUSDG is ERC20 {
  constructor() ERC20("USDG", "USDG") {}
  function mint(address to, uint256 a) external {
    _mint(to, a);
  }
  function decimals() public pure override returns (uint8) {
    return 6;
  }
}

/// Faithful stand-in for v4-core's PoolManager swap-hook settlement. `driveSwap` replays the exact delta math
/// of Hooks.beforeSwap + Hooks.afterSwap (v4-core/src/libraries/Hooks.sol). It also serves the hook's Layer-2
/// empty-pool guard: `extsload` returns the settable `liq` so `StateLibrary.getLiquidity` reads it (the guard
/// is the only extsload path hit in these unit tests). Default `liq` is nonzero so ordinary swaps pass; a test
/// sets it to 0 to model the empty pool. Two money-path contracts are asserted on every swap:
///   (1) the hook's realized credit equals what it took in the fee currency (net manager delta = 0), and
///   (2) the hook is credited in the fee currency ONLY — never the other (clean) token.
contract MockPoolManager {
  using BeforeSwapDeltaLibrary for BeforeSwapDelta;
  using BalanceDeltaLibrary for BalanceDelta;

  uint128 public liq = 1e18; // active liquidity the empty-pool guard reads; default nonzero

  function setLiquidity(uint128 v) external {
    liq = v;
  }

  function extsload(bytes32) external view returns (bytes32) {
    return bytes32(uint256(liq));
  }

  function take(Currency currency, address to, uint256 amount) external {
    IERC20(Currency.unwrap(currency)).transfer(to, amount);
  }

  function driveInit(EsseyReserveHook hook, PoolKey calldata key, uint160 sqrtP) external view returns (bytes4) {
    return hook.beforeInitialize(address(this), key, sqrtP);
  }

  /// Drive the anti-snipe stamp exactly as v4 does at the atomic seed: an add that SUPPLIES ESSEY (currency0
  /// owed, amount0 < 0) calls afterAddLiquidity, which stamps launchTime. The seeder's own settlement is
  /// unaffected — the hook returns a zero delta. Returns the stamped launchTime.
  function driveSeed(EsseyReserveHook hook, PoolKey calldata key) external returns (uint256) {
    ModifyLiquidityParams memory p =
      ModifyLiquidityParams({tickLower: 0, tickUpper: 600, liquidityDelta: int256(uint256(1e18)), salt: bytes32(0)});
    BalanceDelta principal = toBalanceDelta(-int128(uint128(1e18)), int128(0)); // owes currency0 (ESSEY) only
    (bytes4 sel, BalanceDelta hookDelta) =
      hook.afterAddLiquidity(address(this), key, p, principal, BalanceDeltaLibrary.ZERO_DELTA, "");
    require(sel == IHooks.afterAddLiquidity.selector, "aal sel");
    require(BalanceDelta.unwrap(hookDelta) == 0, "aal returned nonzero delta");
    return hook.launchTime();
  }

  /// Drive an add that supplies NO ESSEY — currency1 (USDG) owed only, amount0 == 0. This is the boundary of
  /// the stamp guard (`delta.amount0() < 0`): it must NOT stamp the clock. Returns launchTime after the add.
  function driveNonEsseyAdd(EsseyReserveHook hook, PoolKey calldata key) external returns (uint256) {
    ModifyLiquidityParams memory p =
      ModifyLiquidityParams({tickLower: -600, tickUpper: 0, liquidityDelta: int256(uint256(1e18)), salt: bytes32(0)});
    BalanceDelta principal = toBalanceDelta(int128(0), -int128(uint128(1e6))); // owes currency1 (USDG) only
    (bytes4 sel, BalanceDelta hookDelta) =
      hook.afterAddLiquidity(address(this), key, p, principal, BalanceDeltaLibrary.ZERO_DELTA, "");
    require(sel == IHooks.afterAddLiquidity.selector, "aal sel");
    require(BalanceDelta.unwrap(hookDelta) == 0, "aal returned nonzero delta");
    return hook.launchTime();
  }

  function driveSwap(EsseyReserveHook hook, PoolKey calldata key, SwapParams calldata params, BalanceDelta swapDelta)
    external
    returns (uint256 feeTaken)
  {
    bool feeIs1 = hook.feeIsCurrency1();
    IERC20 feeTok = IERC20(Currency.unwrap(hook.feeCurrency()));
    IERC20 otherTok = IERC20(Currency.unwrap(feeIs1 ? key.currency0 : key.currency1));
    uint256 feeBefore = feeTok.balanceOf(address(hook));
    uint256 otherBefore = otherTok.balanceOf(address(hook));

    (bytes4 bsel, BeforeSwapDelta bsd,) = hook.beforeSwap(address(this), key, params, "");
    require(bsel == IHooks.beforeSwap.selector, "bsel");
    int128 hookDeltaSpecified = bsd.getSpecifiedDelta();
    int128 hookDeltaUnspecified = bsd.getUnspecifiedDelta();

    (bytes4 asel, int128 charged) = hook.afterSwap(address(this), key, params, swapDelta, "");
    require(asel == IHooks.afterSwap.selector, "asel");
    hookDeltaUnspecified += charged;

    BalanceDelta hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
      ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
      : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);
    int128 feeCredit = feeIs1 ? hookDelta.amount1() : hookDelta.amount0();
    int128 otherCredit = feeIs1 ? hookDelta.amount0() : hookDelta.amount1();

    feeTaken = feeTok.balanceOf(address(hook)) - feeBefore;
    require(feeCredit >= 0 && uint256(uint128(feeCredit)) == feeTaken, "fee credit != taken");
    require(otherCredit == 0, "hook credited non-fee currency");
    require(otherTok.balanceOf(address(hook)) == otherBefore, "hook moved non-fee token");
  }
}

contract EsseyReserveHookTest is Test {
  uint256 constant BPS = 10_000;
  uint256 constant BASE = 100; // 1%
  uint256 constant SNIPE_START = 9_800; // 98% — cap 9900 < BPS (buy path skims the INPUT; 100% would revert)
  uint256 constant SNIPE_SECONDS = 45;
  // Fee-model v2 three-bucket default split (docs/ESSEY-FEE-MODEL-V2-HOLDER-AIRDROP-SCOPE.md §0). Ops + POL gone.
  uint256 constant RES_SHARE = 4_500;
  uint256 constant HOLDERS_SHARE = 4_000;
  uint256 constant DON_SHARE = 1_500;
  uint24 constant POOL_FEE = 3000;
  int24 constant TICK_SPACING = 60;
  uint160 constant OPEN_PRICE = uint160(1 << 96); // pinned launch price (sqrtP for 1:1)

  address constant DONS = address(0xD0);
  address constant HOLDERS = address(0x40); // the HolderDistributor sink
  address constant GOV = address(0x60);

  MockPoolManager mgr;
  MockEssey essey; // currency0 (reserve claim token) — must NEVER be skimmed
  MockUSDG usdg; // currency1 = the quote / feeCurrency
  EsseyReserve reserve;
  EsseyReserveHook hook;

  Currency c0;
  Currency c1;
  PoolKey key;

  function setUp() public {
    mgr = new MockPoolManager();
    essey = new MockEssey(8_888_888_888e18);
    usdg = new MockUSDG();
    reserve = new EsseyReserve(IERC20(address(essey)));

    // The hook depends on the sorted (currency0, currency1); force essey=c0 < usdg=c1 to mirror the real
    // pool (VERIFIED: ESSEY 0x3157… < USDG 0x5fc5…). Redeploy essey until it lands below usdg.
    while (address(essey) >= address(usdg)) {
      essey = new MockEssey(8_888_888_888e18);
      reserve = new EsseyReserve(IERC20(address(essey)));
    }
    c0 = Currency.wrap(address(essey));
    c1 = Currency.wrap(address(usdg));

    hook = _deployHook();
    key = PoolKey({currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});
    mgr.driveInit(hook, key, OPEN_PRICE);
  }

  function _deployHook() internal returns (EsseyReserveHook) {
    // Mine a CREATE2 salt so the deployed address carries flags 0x24CC (beforeInitialize | afterAddLiquidity |
    // beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta), which validateHookPermissions enforces.
    bytes memory args = _args();
    bytes32 initHash = keccak256(abi.encodePacked(type(EsseyReserveHook).creationCode, args));
    uint160 flags = uint160(0x24CC);
    for (uint256 s = 0; s < 500_000; s++) {
      address addr = _create2addr(address(this), bytes32(s), initHash);
      if (uint160(addr) & 0x3FFF == flags && addr.code.length == 0) {
        EsseyReserveHook h = _construct(bytes32(s));
        require(address(h) == addr, "create2");
        return h;
      }
    }
    revert("no salt");
  }

  function _args() internal view returns (bytes memory) {
    return abi.encode(
      IPoolManager(address(mgr)),
      IEsseyReserve(address(reserve)),
      c0,
      c1,
      c1, // feeCurrency = USDG (the quote)
      POOL_FEE,
      TICK_SPACING,
      DONS,
      HOLDERS,
      GOV,
      BASE,
      SNIPE_START,
      SNIPE_SECONDS,
      RES_SHARE,
      HOLDERS_SHARE,
      DON_SHARE,
      OPEN_PRICE
    );
  }

  function _construct(bytes32 salt) internal returns (EsseyReserveHook) {
    return new EsseyReserveHook{salt: salt}(
      IPoolManager(address(mgr)),
      IEsseyReserve(address(reserve)),
      c0,
      c1,
      c1,
      POOL_FEE,
      TICK_SPACING,
      DONS,
      HOLDERS,
      GOV,
      BASE,
      SNIPE_START,
      SNIPE_SECONDS,
      RES_SHARE,
      HOLDERS_SHARE,
      DON_SHARE,
      OPEN_PRICE
    );
  }

  function _create2addr(address deployer, bytes32 salt, bytes32 initHash) internal pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
  }

  // ------------------------------------------------------------------ the four swap directions

  /// SELL exact-in (ESSEY->USDG, specified=ESSEY input): USDG is the UNSPECIFIED output → afterSwap skims it.
  function _sellExactIn(uint128 esseyIn, uint128 usdgOut) internal returns (uint256) {
    usdg.mint(address(mgr), usdgOut);
    SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -int256(uint256(esseyIn)), sqrtPriceLimitX96: 0});
    BalanceDelta d = toBalanceDelta(-int128(esseyIn), int128(usdgOut));
    return mgr.driveSwap(hook, key, p, d);
  }

  /// SELL exact-out (want USDG out, pay ESSEY, specified=USDG output): USDG is the SPECIFIED leg → beforeSwap.
  function _sellExactOut(uint128 usdgOut, uint128 esseyIn) internal returns (uint256) {
    usdg.mint(address(mgr), usdgOut);
    SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: int256(uint256(usdgOut)), sqrtPriceLimitX96: 0});
    BalanceDelta d = toBalanceDelta(-int128(esseyIn), int128(usdgOut));
    return mgr.driveSwap(hook, key, p, d);
  }

  /// BUY exact-in (USDG->ESSEY, specified=USDG input): USDG is the SPECIFIED leg → beforeSwap skims the input.
  function _buyExactIn(uint128 usdgIn, uint128 esseyOut) internal returns (uint256) {
    usdg.mint(address(mgr), usdgIn);
    SwapParams memory p = SwapParams({zeroForOne: false, amountSpecified: -int256(uint256(usdgIn)), sqrtPriceLimitX96: 0});
    BalanceDelta d = toBalanceDelta(int128(esseyOut), -int128(usdgIn));
    return mgr.driveSwap(hook, key, p, d);
  }

  /// BUY exact-out (want ESSEY out, pay USDG, specified=ESSEY output): USDG is the UNSPECIFIED input → afterSwap.
  function _buyExactOut(uint128 esseyOut, uint128 usdgIn) internal returns (uint256) {
    usdg.mint(address(mgr), usdgIn);
    SwapParams memory p = SwapParams({zeroForOne: false, amountSpecified: int256(uint256(esseyOut)), sqrtPriceLimitX96: 0});
    BalanceDelta d = toBalanceDelta(int128(esseyOut), -int128(usdgIn));
    return mgr.driveSwap(hook, key, p, d);
  }

  /// Open trading: stamp the anti-snipe clock at the atomic seed (the first ESSEY-supplying add), then run a
  /// throwaway swap and sweep the escrow it produced back to a zero-escrow baseline. All three buckets are
  /// nonzero at the default split, so every fund*() has funds. Sink-balance tests measure deltas.
  function _openTrading() internal {
    mgr.driveSeed(hook, key);
    _sellExactIn(1e18, 1e6);
    hook.fundReserve(address(usdg));
    hook.fundHolders(address(usdg));
    hook.fundDons(address(usdg));
  }

  // ================================================================= (vi) fee ALWAYS in USDG, never ESSEY

  function test_inv_fee_always_usdg_buy_exact_in() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100); // base-only, deterministic
    uint256 taken = _buyExactIn(1_000_000e6, 500_000e18);
    assertEq(taken, (uint256(1_000_000e6) * BASE) / BPS, "buy exactIn fee not base on USDG input");
    _assertUsdgOnly(taken);
  }

  function test_inv_fee_always_usdg_buy_exact_out() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100);
    uint256 taken = _buyExactOut(500_000e18, 1_000_000e6);
    assertEq(taken, (uint256(1_000_000e6) * BASE) / BPS, "buy exactOut fee not base on USDG input");
    _assertUsdgOnly(taken);
  }

  function test_inv_fee_always_usdg_sell_exact_in() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100);
    uint256 taken = _sellExactIn(500_000e18, 1_000_000e6);
    assertEq(taken, (uint256(1_000_000e6) * BASE) / BPS, "sell exactIn fee not base on USDG output");
    _assertUsdgOnly(taken);
  }

  function test_inv_fee_always_usdg_sell_exact_out() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100);
    uint256 taken = _sellExactOut(1_000_000e6, 500_000e18);
    assertEq(taken, (uint256(1_000_000e6) * BASE) / BPS, "sell exactOut fee not base on USDG output");
    _assertUsdgOnly(taken);
  }

  /// The whole point of the rework: escrow accrues USDG, ESSEY escrow stays exactly zero, hook holds no ESSEY.
  function _assertUsdgOnly(uint256 taken) internal view {
    assertEq(usdg.balanceOf(address(hook)), taken, "hook USDG != fee");
    assertEq(essey.balanceOf(address(hook)), 0, "hook holds ESSEY");
    assertEq(hook.reserveEscrow(address(essey)), 0, "ESSEY reserve escrow nonzero");
    assertEq(hook.holdersEscrow(address(essey)), 0, "ESSEY holders escrow nonzero");
    assertEq(hook.donsEscrow(address(essey)), 0, "ESSEY dons escrow nonzero");
    assertGt(usdg.balanceOf(address(hook)), 0, "no USDG skimmed");
  }

  /// Fuzz all four directions at any point in the decay window: skim is always USDG, ESSEY never touched.
  function test_inv_fee_always_usdg_fuzz(uint8 dir, uint128 amt, uint256 dt) public {
    _openTrading();
    amt = uint128(bound(amt, 1e6, 1e30));
    dt = bound(dt, 0, SNIPE_SECONDS + 50);
    vm.warp(hook.launchTime() + dt);
    uint128 counter = uint128(bound(uint256(amt) / 2 + 1, 1, type(uint128).max));
    dir = uint8(bound(dir, 0, 3));
    if (dir == 0) _buyExactIn(amt, counter);
    else if (dir == 1) _buyExactOut(counter, amt);
    else if (dir == 2) _sellExactIn(counter, amt);
    else _sellExactOut(amt, counter);
    assertEq(essey.balanceOf(address(hook)), 0, "ESSEY skimmed");
    uint256 esseyEscrow =
      hook.reserveEscrow(address(essey)) + hook.holdersEscrow(address(essey)) + hook.donsEscrow(address(essey));
    assertEq(esseyEscrow, 0, "ESSEY escrow");
  }

  // ================================================================= (i) fee cap

  function test_inv_feeBps_never_exceeds_cap(uint256 dt) public {
    _openTrading();
    dt = bound(dt, 0, 10_000);
    assertLe(hook.feeBpsAt(hook.launchTime() + dt), hook.maxTotalFeeBps(), "feeBps over cap");
  }

  function test_feeCap_is_base_plus_start_at_launch() public {
    _openTrading();
    assertEq(hook.feeBpsAt(hook.launchTime()), BASE + SNIPE_START);
    assertEq(hook.maxTotalFeeBps(), BASE + SNIPE_START);
  }

  function test_inv_skimmed_fee_within_cap(uint128 usdgOut, uint256 dt) public {
    _openTrading();
    usdgOut = uint128(bound(usdgOut, 1, 1e24));
    dt = bound(dt, 0, SNIPE_SECONDS + 100);
    vm.warp(hook.launchTime() + dt);
    uint256 taken = _sellExactIn(1e18, usdgOut);
    assertLe(taken, (uint256(usdgOut) * hook.maxTotalFeeBps()) / BPS, "skim over cap");
  }

  // ================================================================= (ii) surcharge decay

  function test_inv_surcharge_full_at_launch_zero_after_N() public {
    _openTrading();
    uint256 t0 = hook.launchTime();
    assertEq(hook.surchargeBpsAt(t0), SNIPE_START, "not full at launch");
    assertEq(hook.surchargeBpsAt(t0 + SNIPE_SECONDS), 0, "not zero at N");
    assertEq(hook.surchargeBpsAt(t0 + SNIPE_SECONDS + 1), 0, "not zero after N");
    assertGt(hook.surchargeBpsAt(t0 + SNIPE_SECONDS - 1), 0, "zero before N");

    // Pin the interior SHAPE, not just the endpoints: a step function (full then cliff) matches every
    // endpoint assertion above but fails these two.
    assertGt(hook.surchargeBpsAt(t0 + 5), hook.surchargeBpsAt(t0 + 10), "surcharge not strictly decaying inside the window");
    assertEq(hook.surchargeBpsAt(t0 + 15), (SNIPE_START * (SNIPE_SECONDS - 15)) / SNIPE_SECONDS, "interior surcharge != linear");
  }

  function test_inv_surcharge_monotonic_nonincreasing(uint256 a, uint256 b) public {
    _openTrading();
    uint256 t0 = hook.launchTime();
    a = bound(a, 0, SNIPE_SECONDS + 50);
    b = bound(b, a, SNIPE_SECONDS + 50);
    assertGe(hook.surchargeBpsAt(t0 + a), hook.surchargeBpsAt(t0 + b), "decay not monotonic");
  }

  // ================================================================= (iii) full accounting -> reserve

  function test_inv_every_skimmed_unit_accounted() public {
    // Before the seed, launchTime == 0, so surchargeBpsAt returns the FULL surcharge (largest split) — the
    // hardest case for accounting. No seed/warp needed; the pre-seed clock reads full surcharge by construction.
    uint256 taken = _sellExactIn(1e18, 1_000_000e6);
    uint256 sum =
      hook.reserveEscrow(address(usdg)) + hook.holdersEscrow(address(usdg)) + hook.donsEscrow(address(usdg));
    assertEq(sum, taken, "escrow != fee");
    assertEq(usdg.balanceOf(address(hook)), taken, "hook holds != fee");
  }

  /// Pins "nothing stranded / every unit accounted" against the remainder-vs-proportional mutant. A
  /// non-divisible baseFee separates them: usdgOut 1300 -> baseFee 13 -> don 1(=13*1500/1e4=1), holders 5,
  /// res(remainder) 7, sum 13 == taken. Base-only (post-window) so taken == baseFee exactly.
  function test_inv_non_divisible_base_fully_accounted() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100);
    uint256 taken = _sellExactIn(1e18, 1300);
    assertEq(taken, 13, "base fee not 13 for usdgOut 1300");
    uint256 sum =
      hook.reserveEscrow(address(usdg)) + hook.holdersEscrow(address(usdg)) + hook.donsEscrow(address(usdg));
    assertEq(sum, taken, "non-divisible base leaves a unit stranded");
  }

  function test_inv_reserve_share_reaches_reserve() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100); // base-only split, no surcharge
    uint128 usdgOut = 1_000_000e6;
    _sellExactIn(1e18, usdgOut);

    uint256 baseFee = (uint256(usdgOut) * BASE) / BPS;
    uint256 expDon = (baseFee * DON_SHARE) / BPS;
    uint256 expHolders = (baseFee * HOLDERS_SHARE) / BPS;
    uint256 expReserve = baseFee - expDon - expHolders; // remainder -> reserve

    // _openTrading already funded the sinks once; measure the deltas this swap adds, not absolute balances.
    uint256 rBefore = usdg.balanceOf(address(reserve));
    uint256 hBefore = usdg.balanceOf(HOLDERS);
    uint256 dBefore = usdg.balanceOf(DONS);
    hook.fundReserve(address(usdg));
    hook.fundHolders(address(usdg));
    hook.fundDons(address(usdg));

    assertEq(usdg.balanceOf(address(reserve)) - rBefore, expReserve, "reserve short");
    assertEq(usdg.balanceOf(HOLDERS) - hBefore, expHolders, "holders short");
    assertEq(usdg.balanceOf(DONS) - dBefore, expDon, "dons short");
    assertEq(usdg.balanceOf(address(hook)), 0, "hook retained dust");
    assertEq(expReserve + expHolders + expDon, baseFee, "sum != fee");
  }

  function test_surcharge_all_goes_to_reserve() public {
    // Pre-seed (launchTime == 0) => full surcharge by construction; whole surcharge routes to the reserve.
    uint128 usdgOut = 1_000_000e6;
    _sellExactIn(1e18, usdgOut);
    uint256 baseFee = (uint256(usdgOut) * BASE) / BPS;
    uint256 surcharge = (uint256(usdgOut) * SNIPE_START) / BPS;
    uint256 expDon = (baseFee * DON_SHARE) / BPS;
    uint256 expHolders = (baseFee * HOLDERS_SHARE) / BPS;
    uint256 expReserve = baseFee - expDon - expHolders + surcharge;
    assertEq(hook.reserveEscrow(address(usdg)), expReserve, "surcharge not 100% to reserve");
  }

  // ================================================================= (viii) 0-share rounding dust -> reserve

  /// With a 0% bucket the escrow for that bucket must accrue EXACTLY 0 after any swap — the rounding remainder
  /// lives in the RESERVE, not the 0% bucket. Govern dons to 0 (a valid rail split), then a non-divisible base
  /// is the discriminating case. RED if the remainder ever leaks into the 0% bucket.
  function test_inv_zero_share_accrues_exactly_zero() public {
    _openTrading();
    vm.prank(GOV);
    hook.proposeSplit(6_000, 4_000, 0); // dons -> 0, rails-valid
    vm.warp(block.timestamp + 48 hours); // clears timelock AND leaves the anti-snipe window (surcharge 0)
    hook.executeSplit();

    _sellExactIn(1e18, 1300); // baseFee 13 — indivisible across the shares
    assertEq(hook.donsEscrow(address(usdg)), 0, "0% dons accrued nonzero dust");
    uint256 sum =
      hook.reserveEscrow(address(usdg)) + hook.holdersEscrow(address(usdg)) + hook.donsEscrow(address(usdg));
    assertEq(sum, 13, "parts do not sum to baseFee");
  }

  function test_inv_zero_share_fuzz(uint128 usdgOut) public {
    _openTrading();
    vm.prank(GOV);
    hook.proposeSplit(6_000, 4_000, 0);
    vm.warp(block.timestamp + 48 hours);
    hook.executeSplit();

    usdgOut = uint128(bound(usdgOut, 1, 1e24));
    uint256 taken = _sellExactIn(1e18, usdgOut);
    assertEq(hook.donsEscrow(address(usdg)), 0, "0% dons accrued dust");
    uint256 sum =
      hook.reserveEscrow(address(usdg)) + hook.holdersEscrow(address(usdg)) + hook.donsEscrow(address(usdg));
    assertEq(sum, taken, "parts do not sum to baseFee");
  }

  // ================================================================= (ix) holders slice: always USDG, sums, forward

  function test_inv_holders_slice_is_usdg_and_sums() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100);
    uint128 usdgOut = 1_000_000e6;
    _sellExactIn(1e18, usdgOut);
    uint256 baseFee = (uint256(usdgOut) * BASE) / BPS;
    assertEq(hook.holdersEscrow(address(usdg)), (baseFee * HOLDERS_SHARE) / BPS, "holders slice wrong");
    assertEq(hook.holdersEscrow(address(essey)), 0, "holders slice in ESSEY");

    uint256 before = usdg.balanceOf(HOLDERS);
    uint256 moved = hook.fundHolders(address(usdg));
    assertEq(usdg.balanceOf(HOLDERS) - before, moved, "fundHolders did not reach the holders sink");
    assertEq(hook.holdersEscrow(address(usdg)), 0, "holders escrow not cleared");
  }

  // ================================================================= (iv) no privileged redirect / drain

  function test_inv_sinks_are_immutable_no_setter() public view {
    assertEq(address(hook.reserve()), address(reserve));
    assertEq(hook.holdersSink(), HOLDERS);
    assertEq(hook.donsSink(), DONS);
  }

  function test_inv_funds_route_only_to_fixed_sinks() public {
    _sellExactIn(1e18, 1_000_000e6);
    address attacker = address(0xBAD);
    vm.prank(attacker);
    hook.fundDons(address(usdg));
    assertEq(usdg.balanceOf(attacker), 0, "attacker skimmed");
    assertGt(usdg.balanceOf(DONS), 0, "dons not funded");
  }

  function test_fund_reverts_when_empty() public {
    vm.expectRevert(EsseyReserveHook.NothingToFund.selector);
    hook.fundReserve(address(usdg));
  }

  function test_fundHolders_reverts_when_empty() public {
    vm.expectRevert(EsseyReserveHook.NothingToFund.selector);
    hook.fundHolders(address(usdg));
  }

  function test_fundDons_reverts_when_empty() public {
    vm.expectRevert(EsseyReserveHook.NothingToFund.selector);
    hook.fundDons(address(usdg));
  }

  // ================================================================= (v) clean-token invariant

  function test_inv_essey_supply_untouched_by_hook() public {
    uint256 supplyBefore = essey.totalSupply();
    vm.warp(hook.launchTime());
    // Every direction, including the buy flows that on the OLD design skimmed ESSEY. None may touch it now.
    _buyExactIn(1_000_000e6, 500_000e18);
    _buyExactOut(400_000e18, 800_000e6);
    _sellExactIn(300_000e18, 600_000e6);
    _sellExactOut(500_000e6, 250_000e18);
    assertEq(essey.totalSupply(), supplyBefore, "hook changed ESSEY supply");
    assertEq(essey.balanceOf(address(hook)), 0, "hook holds ESSEY");
    assertEq(essey.balanceOf(address(reserve)), 0, "ESSEY leaked to reserve");
  }

  // ================================================================= (H-A) empty-pool swap guard (Layer 2)

  /// Reproduce the HIGH's precondition and show it is CLOSED: on a pool with zero active liquidity, a swap
  /// REVERTS (EmptyPool) and never walks price. The clock is stamped at the seed (not here), so on an unseeded
  /// pool launchTime stays 0 no matter how many empty-pool swaps are attempted.
  function test_empty_pool_swap_reverts_and_does_not_stamp_clock() public {
    // Pre-mint outside the expectRevert window so it lands squarely on the guarded swap.
    usdg.mint(address(mgr), 1_000_000e6);
    SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -int256(uint256(1e18)), sqrtPriceLimitX96: 0});
    BalanceDelta d = toBalanceDelta(-int128(uint128(1e18)), int128(uint128(1_000_000e6)));

    mgr.setLiquidity(0);
    assertEq(hook.launchTime(), 0, "clock stamped before any swap");
    vm.expectRevert(EsseyReserveHook.EmptyPool.selector);
    mgr.driveSwap(hook, key, p, d);
    assertEq(hook.launchTime(), 0, "empty-pool swap stamped the clock");
  }

  function test_empty_pool_guard_lets_real_swap_through_once_seeded() public {
    usdg.mint(address(mgr), 1_000_000e6);
    SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -int256(uint256(1e18)), sqrtPriceLimitX96: 0});
    BalanceDelta d = toBalanceDelta(-int128(uint128(1e18)), int128(uint128(1_000_000e6)));

    mgr.setLiquidity(0);
    vm.expectRevert(EsseyReserveHook.EmptyPool.selector);
    mgr.driveSwap(hook, key, p, d);

    // Seeding stamps the clock (afterAddLiquidity) AND materializes active liquidity; the same swap now
    // succeeds. Because the seed and this swap share a block, the swap still pays the full surcharge — but the
    // stamp came from the SEED, not the swap.
    mgr.driveSeed(hook, key);
    assertEq(hook.launchTime(), block.timestamp, "seed did not stamp the clock");
    mgr.setLiquidity(1e18);
    uint256 taken = _sellExactIn(1e18, 1_000_000e6);
    assertEq(taken, (uint256(1_000_000e6) * (BASE + SNIPE_START)) / BPS, "first real swap not full surcharge");
    assertEq(hook.launchTime(), block.timestamp, "swap moved the clock the seed already set");
  }

  // ================================================================= H-B1: anti-snipe clock stamped at seed

  /// (a) No surcharge decay happens between initialize and the SEED, no matter how much time passes.
  function test_hb1_no_decay_between_init_and_seed() public {
    assertEq(hook.launchTime(), 0, "clock stamped at initialize");
    vm.warp(block.timestamp + 10 * SNIPE_SECONDS);
    assertEq(hook.surchargeBpsAt(block.timestamp), SNIPE_START, "surcharge decayed on an un-seeded pool");
    assertEq(hook.feeBpsAt(block.timestamp), BASE + SNIPE_START, "fee decayed before the seed");
  }

  /// (b) The seed stamps the clock; decay begins from the seed moment, and the first swap after it sees the
  /// full surcharge only while it shares the seed's block.
  function test_hb1_seed_stamps_clock_then_decays_from_seed() public {
    vm.warp(block.timestamp + 10 * SNIPE_SECONDS);
    mgr.driveSeed(hook, key);
    assertEq(hook.launchTime(), block.timestamp, "seed did not stamp the clock to now");

    uint256 firstTaken = _sellExactIn(1e18, 1_000_000e6);
    uint256 expectFull = (uint256(1_000_000e6) * (BASE + SNIPE_START)) / BPS;
    assertEq(firstTaken, expectFull, "swap in the seed block did not pay the full surcharge");

    vm.warp(hook.launchTime() + SNIPE_SECONDS);
    uint256 laterTaken = _sellExactIn(1e18, 1_000_000e6);
    assertEq(laterTaken, (uint256(1_000_000e6) * BASE) / BPS, "surcharge did not decay from the seed");
  }

  function test_beforeSwap_only_poolManager() public {
    SwapParams memory p = SwapParams({zeroForOne: false, amountSpecified: -1e6, sqrtPriceLimitX96: 0});
    vm.expectRevert(EsseyReserveHook.NotPoolManager.selector);
    hook.beforeSwap(address(this), key, p, "");
  }

  function test_afterSwap_only_poolManager() public {
    SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    BalanceDelta d = toBalanceDelta(-1e18, 1e6);
    vm.expectRevert(EsseyReserveHook.NotPoolManager.selector);
    hook.afterSwap(address(this), key, p, d, "");
  }

  // ================================================================= (G) split governor: rails / timelock / lock

  function _validSplit() internal pure returns (uint256, uint256, uint256) {
    // At the rails corners: reserve 4000 (min), holders 5000 (max), dons 1000 residual (<= 2000 max).
    return (4_000, 5_000, 1_000);
  }

  function test_gov_propose_requires_governor() public {
    vm.expectRevert(EsseyReserveHook.NotGovernor.selector);
    hook.proposeSplit(4_000, 5_000, 1_000);
  }

  function test_gov_rails_reserve_floor_enforced() public {
    vm.startPrank(GOV);
    vm.expectRevert(EsseyReserveHook.BadSplit.selector);
    hook.proposeSplit(3_999, 5_000, 1_001); // reserve < 4000; holders/dons within caps, sum ok
    hook.proposeSplit(4_000, 5_000, 1_000); // exactly 4000 accepted
    vm.stopPrank();
  }

  function test_gov_rails_holders_ceiling_enforced() public {
    vm.startPrank(GOV);
    vm.expectRevert(EsseyReserveHook.BadSplit.selector);
    hook.proposeSplit(4_000, 5_001, 999); // holders > 5000
    hook.proposeSplit(4_000, 5_000, 1_000); // holders exactly 5000 accepted
    vm.stopPrank();
  }

  function test_gov_rails_dons_ceiling_enforced() public {
    vm.startPrank(GOV);
    vm.expectRevert(EsseyReserveHook.BadSplit.selector);
    hook.proposeSplit(4_000, 3_999, 2_001); // dons > 2000
    hook.proposeSplit(4_000, 4_000, 2_000); // dons exactly 2000 accepted
    vm.stopPrank();
  }

  function test_gov_rails_sum_must_equal_bps() public {
    vm.startPrank(GOV);
    vm.expectRevert(EsseyReserveHook.BadSplit.selector);
    hook.proposeSplit(4_500, 4_000, 1_499); // sums 9999
    vm.expectRevert(EsseyReserveHook.BadSplit.selector);
    hook.proposeSplit(4_500, 4_000, 1_501); // sums 10001
    vm.stopPrank();
  }

  function test_gov_timelock_cannot_be_bypassed() public {
    (uint256 r, uint256 h, uint256 d) = _validSplit();
    vm.prank(GOV);
    hook.proposeSplit(r, h, d);

    vm.expectRevert(EsseyReserveHook.TimelockPending.selector);
    hook.executeSplit(); // before the 48h delay

    vm.warp(block.timestamp + 48 hours - 1);
    vm.expectRevert(EsseyReserveHook.TimelockPending.selector);
    hook.executeSplit(); // still one second short

    vm.warp(block.timestamp + 1); // now exactly at effective time
    hook.executeSplit();
    assertEq(hook.reserveShareBps(), r, "reserve not applied");
    assertEq(hook.holdersShareBps(), h, "holders not applied");
    assertEq(hook.donsShareBps(), d, "dons not applied");
  }

  function test_gov_execute_reverts_without_pending() public {
    vm.expectRevert(EsseyReserveHook.NothingPending.selector);
    hook.executeSplit();
  }

  /// For every governor state reachable here (default, and a post-execute state), the split sums to BPS.
  function test_inv_split_always_sums_to_bps() public {
    assertEq(hook.reserveShareBps() + hook.holdersShareBps() + hook.donsShareBps(), BPS, "default off-sum");
    (uint256 r, uint256 h, uint256 d) = _validSplit();
    vm.prank(GOV);
    hook.proposeSplit(r, h, d);
    vm.warp(block.timestamp + 48 hours);
    hook.executeSplit();
    assertEq(hook.reserveShareBps() + hook.holdersShareBps() + hook.donsShareBps(), BPS, "post-execute off-sum");
  }

  function test_gov_lock_is_permanent() public {
    // Queue a change, then lock: the pending change is cancelled and the split freezes forever.
    (uint256 r, uint256 h, uint256 d) = _validSplit();
    vm.prank(GOV);
    hook.proposeSplit(r, h, d);

    uint256 res0 = hook.reserveShareBps();
    uint256 hol0 = hook.holdersShareBps();
    uint256 don0 = hook.donsShareBps();

    vm.prank(GOV);
    hook.lock();
    assertTrue(hook.splitLocked(), "not locked");
    assertEq(hook.governor(), address(0), "governor not renounced");

    // Every setter reverts, permanently.
    vm.prank(GOV);
    vm.expectRevert(EsseyReserveHook.NotGovernor.selector);
    hook.proposeSplit(r, h, d);

    assertEq(hook.pendingEffectiveTime(), 0, "lock did not cancel the queued change");
    vm.expectRevert(EsseyReserveHook.SplitFrozenError.selector);
    hook.executeSplit(); // pending was cleared by lock()

    vm.prank(GOV);
    vm.expectRevert(EsseyReserveHook.NotGovernor.selector);
    hook.lock();

    // The active split is unchanged by the whole sequence.
    assertEq(hook.reserveShareBps(), res0, "reserve moved after lock");
    assertEq(hook.holdersShareBps(), hol0, "holders moved after lock");
    assertEq(hook.donsShareBps(), don0, "dons moved after lock");
  }

  /// (K) A full governor cycle (propose + execute + lock) never touches the fee RATE. The rate has no setter
  /// at all; this pins that the governor path leaves it exactly where the constructor set it.
  function test_gov_never_touches_the_fee_rate() public {
    uint256 base0 = hook.baseFeeBps();
    uint256 start0 = hook.snipeStartBps();
    uint256 sec0 = hook.snipeSeconds();
    uint256 cap0 = hook.maxTotalFeeBps();

    (uint256 r, uint256 h, uint256 d) = _validSplit();
    vm.prank(GOV);
    hook.proposeSplit(r, h, d);
    vm.warp(block.timestamp + 48 hours);
    hook.executeSplit();
    vm.prank(GOV);
    hook.lock();

    assertEq(hook.baseFeeBps(), base0, "base rate changed");
    assertEq(hook.snipeStartBps(), start0, "snipe start changed");
    assertEq(hook.snipeSeconds(), sec0, "snipe seconds changed");
    assertEq(hook.maxTotalFeeBps(), cap0, "cap changed");
  }

  // ================================================================= beforeInitialize / access guards

  function test_beforeInitialize_only_poolManager() public {
    EsseyReserveHook fresh = _deployHook();
    vm.expectRevert(EsseyReserveHook.NotPoolManager.selector);
    fresh.beforeInitialize(address(this), key, uint160(1 << 96));
  }

  function test_beforeInitialize_rejects_wrong_key() public {
    EsseyReserveHook fresh = _deployHook();
    PoolKey memory bad = key;
    bad.fee = 500;
    vm.expectRevert(EsseyReserveHook.WrongPoolKey.selector);
    mgr.driveInit(fresh, bad, uint160(1 << 96));
  }

  // ================================================================= constructor guards

  function test_permission_flags_are_24CC() public view {
    assertEq(uint160(address(hook)) & 0x3FFF, 0x24CC, "flags not encoded in address");
  }

  /// C-1: the anti-snipe stamp is idempotent. Only the FIRST ESSEY-supplying add stamps the clock; a later
  /// ESSEY-supplying add must not re-stamp it. RED against dropping the `launchTime == 0` guard (a later add
  /// would re-anchor the clock and restart the whole surcharge decay from that add's block).
  function test_second_essey_add_does_not_restamp_clock() public {
    vm.warp(1_000_000);
    mgr.driveSeed(hook, key);
    uint256 t0 = hook.launchTime();
    assertEq(t0, 1_000_000, "seed did not stamp");
    vm.warp(1_000_500);
    mgr.driveSeed(hook, key); // a later ESSEY-supplying add
    assertEq(hook.launchTime(), t0, "a later ESSEY add re-stamped the anti-snipe clock");
  }

  /// The stamp fires ONLY for an ESSEY-supplying add (amount0 < 0). A USDG-only add (amount0 == 0), the exact
  /// boundary of the guard, must NOT stamp — else a pre-seed USDG add could start the surcharge decay early.
  /// RED in both directions: a `<= 0` mutant stamps on the USDG-only add; dropping the stamp fails the seed leg.
  function test_usdg_only_add_does_not_stamp_clock() public {
    assertEq(hook.launchTime(), 0, "clock stamped before any add");
    uint256 afterUsdg = mgr.driveNonEsseyAdd(hook, key);
    assertEq(afterUsdg, 0, "a USDG-only add (amount0 == 0) stamped the anti-snipe clock");
    vm.warp(777);
    assertEq(mgr.driveSeed(hook, key), 777, "ESSEY-supplying add did not stamp the clock");
  }

  function test_feeCurrency_is_usdg() public view {
    assertEq(Currency.unwrap(hook.feeCurrency()), address(usdg));
    assertTrue(hook.feeIsCurrency1());
  }

  function _newHook(uint256 res, uint256 holders, uint256 dons) internal returns (EsseyReserveHook) {
    return new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      BASE, SNIPE_START, SNIPE_SECONDS, res, holders, dons, OPEN_PRICE
    );
  }

  function test_constructor_rejects_undersum_split() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    _newHook(7_000, 1_500, 500); // 9000 != BPS
  }

  /// Over-100% must also revert — an over-sum makes `baseFee - donPart - holdersPart` underflow and brick
  /// every swap; the rails sum check catches it at construction first.
  function test_constructor_rejects_oversum_split() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    _newHook(8_000, 2_000, 1_000); // 11000 > BPS
  }

  function test_constructor_rejects_reserve_below_rail() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    _newHook(3_999, 5_000, 1_001); // reserve < MIN_RESERVE_BPS, sum ok, holders/dons within caps
  }

  function test_constructor_rejects_holders_over_rail() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    _newHook(4_000, 5_001, 999); // holders > MAX_HOLDERS_BPS, sum ok
  }

  function test_constructor_rejects_dons_over_rail() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    _newHook(4_000, 3_999, 2_001); // dons > MAX_DONS_BPS, sum ok
  }

  function test_constructor_rejects_zero_governor() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS,
      address(0), BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  function test_constructor_rejects_cap_at_or_over_bps() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      100, 9900, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE // 100+9900 == BPS, strict
    );
  }

  function test_constructor_rejects_feeCurrency_not_in_pool() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, Currency.wrap(address(0xBEEF)), POOL_FEE,
      TICK_SPACING, DONS, HOLDERS, GOV, BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  // ================================================================= opening-price pin (front-run)

  function test_beforeInitialize_rejects_wrong_price() public {
    EsseyReserveHook fresh = _deployHook();
    PoolKey memory k =
      PoolKey({currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(fresh))});
    vm.expectRevert(EsseyReserveHook.WrongOpeningPrice.selector);
    mgr.driveInit(fresh, k, OPEN_PRICE + 1);
  }

  function test_beforeInitialize_accepts_expected_price() public {
    EsseyReserveHook fresh = _deployHook();
    PoolKey memory k =
      PoolKey({currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(fresh))});
    assertEq(mgr.driveInit(fresh, k, OPEN_PRICE), IHooks.beforeInitialize.selector, "expected price not bound");
  }

  function test_constructor_rejects_zero_opening_price() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, uint160(0)
    );
  }

  // ================================================================= WrongPoolKey per-branch

  function test_beforeInitialize_rejects_wrong_currency0() public {
    EsseyReserveHook fresh = _deployHook();
    PoolKey memory bad = key;
    bad.hooks = IHooks(address(fresh));
    bad.currency0 = Currency.wrap(address(0xBEEF));
    vm.expectRevert(EsseyReserveHook.WrongPoolKey.selector);
    mgr.driveInit(fresh, bad, OPEN_PRICE);
  }

  function test_beforeInitialize_rejects_wrong_currency1() public {
    EsseyReserveHook fresh = _deployHook();
    PoolKey memory bad = key;
    bad.hooks = IHooks(address(fresh));
    bad.currency1 = Currency.wrap(address(0xBEEF));
    vm.expectRevert(EsseyReserveHook.WrongPoolKey.selector);
    mgr.driveInit(fresh, bad, OPEN_PRICE);
  }

  function test_beforeInitialize_rejects_wrong_tickSpacing() public {
    EsseyReserveHook fresh = _deployHook();
    PoolKey memory bad = key;
    bad.hooks = IHooks(address(fresh));
    bad.tickSpacing = 10;
    vm.expectRevert(EsseyReserveHook.WrongPoolKey.selector);
    mgr.driveInit(fresh, bad, OPEN_PRICE);
  }

  /// The last WrongPoolKey sub-branch: a key naming a DIFFERENT hooks address. Pins that branch of the `||`
  /// chain — a mutant that drops the `key.hooks != this` clause would let a foreign-hook key initialize.
  function test_beforeInitialize_rejects_wrong_hooks() public {
    EsseyReserveHook fresh = _deployHook();
    PoolKey memory bad = key;
    bad.hooks = IHooks(address(0xBEEF)); // not `fresh` itself; every other field matches fresh's config
    vm.expectRevert(EsseyReserveHook.WrongPoolKey.selector);
    mgr.driveInit(fresh, bad, OPEN_PRICE);
  }

  // ================================================================= access gates: remaining hook callbacks

  /// afterAddLiquidity is the anti-snipe stamp site; only the manager may drive it. A mutant dropping this gate
  /// would let anyone stamp launchTime and start the surcharge decay off an unseeded pool.
  function test_afterAddLiquidity_only_poolManager() public {
    ModifyLiquidityParams memory p =
      ModifyLiquidityParams({tickLower: 0, tickUpper: 600, liquidityDelta: int256(uint256(1e18)), salt: bytes32(0)});
    BalanceDelta d = toBalanceDelta(-int128(uint128(1e18)), int128(0));
    vm.expectRevert(EsseyReserveHook.NotPoolManager.selector);
    hook.afterAddLiquidity(address(this), key, p, d, BalanceDeltaLibrary.ZERO_DELTA, "");
  }

  // ================================================================= three-way split full accounting

  /// Pins the THREE-WAY SPLIT ACCOUNTING at the DEFAULT split (holders 4000 > 0, dons 1500 > 0), so the
  /// remainder `resPart = baseFee - donPart - holdersPart` (hook) is exercised with BOTH terms nonzero. A
  /// mutant dropping either `- donPart` or `- holdersPart` inflates reserveEscrow, so the three escrows
  /// over-claim the hook's real USDG balance and the LAST fund*() reverts (stranded funds / per-sink DoS).
  /// Accrue, assert the escrows sum to exactly the fee taken, then fund ALL THREE sinks and assert the hook
  /// drains to exactly zero and each sink got its exact share. RED under either dropped term.
  function test_threeWaySplit_fullyAccounted() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100); // base-only, no surcharge

    uint128 usdgOut = 1_000_000e6;
    _sellExactIn(1e18, usdgOut);

    uint256 baseFee = (uint256(usdgOut) * BASE) / BPS;
    uint256 donPart = (baseFee * hook.donsShareBps()) / BPS;
    uint256 holdersPart = (baseFee * hook.holdersShareBps()) / BPS;
    uint256 resPart = baseFee - donPart - holdersPart; // remainder folds into reserve
    assertGt(donPart, 0, "dons slice not exercised");
    assertGt(holdersPart, 0, "holders slice not exercised");

    // every accrued unit is attributed across the three escrows and nowhere else
    assertEq(
      hook.reserveEscrow(address(usdg)) + hook.holdersEscrow(address(usdg)) + hook.donsEscrow(address(usdg)),
      baseFee,
      "escrows do not sum to the fee taken"
    );
    assertEq(hook.reserveEscrow(address(usdg)), resPart, "reserve escrow != remainder");
    assertEq(hook.holdersEscrow(address(usdg)), holdersPart, "holders escrow != holdersPart");
    assertEq(usdg.balanceOf(address(hook)), baseFee, "hook holds exactly the accrued fee");

    uint256 resBefore = usdg.balanceOf(address(reserve));
    uint256 holBefore = usdg.balanceOf(HOLDERS);
    uint256 donsBefore = usdg.balanceOf(DONS);

    // funding ALL THREE must drain the hook to exactly zero — the strongest catch for an over/under-claim
    hook.fundReserve(address(usdg));
    hook.fundHolders(address(usdg));
    hook.fundDons(address(usdg));

    assertEq(usdg.balanceOf(address(hook)), 0, "hook not fully drained: escrows mis-account the fee");
    assertEq(usdg.balanceOf(address(reserve)) - resBefore, resPart, "reserve sink got wrong amount");
    assertEq(usdg.balanceOf(HOLDERS) - holBefore, holdersPart, "holders sink got wrong amount");
    assertEq(usdg.balanceOf(DONS) - donsBefore, donPart, "dons sink got wrong amount");
  }

  /// fundHolders PAYOUT DESTINATION. Pins that fundHolders pays the holders sink EXACTLY while no other sink
  /// moves. RED against `safeTransfer(holdersSink,...)` -> `safeTransfer(donsSink,...)`.
  function test_fundHolders_routes_to_holdersSink_not_dons() public {
    _openTrading();
    vm.warp(hook.launchTime() + 100); // surcharge 0, base-only

    uint128 usdgOut = 1_000_000e6;
    _sellExactIn(1e18, usdgOut);

    uint256 baseFee = (uint256(usdgOut) * BASE) / BPS;
    uint256 expHolders = (baseFee * hook.holdersShareBps()) / BPS;
    assertGt(expHolders, 0, "holders slice not exercised");
    assertEq(hook.holdersEscrow(address(usdg)), expHolders, "holders escrow != holdersPart");

    uint256 holBefore = usdg.balanceOf(HOLDERS);
    uint256 donsBefore = usdg.balanceOf(DONS);
    uint256 resBefore = usdg.balanceOf(address(reserve));

    uint256 moved = hook.fundHolders(address(usdg));

    assertEq(moved, expHolders, "fundHolders moved != holdersPart");
    assertEq(usdg.balanceOf(HOLDERS) - holBefore, expHolders, "holders sink did not receive the holders slice");
    assertEq(usdg.balanceOf(DONS), donsBefore, "fundHolders leaked to donsSink");
    assertEq(usdg.balanceOf(address(reserve)), resBefore, "fundHolders leaked to reserve");
    assertEq(hook.holdersEscrow(address(usdg)), 0, "holders escrow not cleared");
  }

  // ================================================================= constructor BadConfig, one test per branch

  /// Each zero-address arg trips the SAME combined guard. Split so a mutant deleting one clause of the `||`
  /// chain cannot survive: only the arg it dropped would stop reverting.
  function test_constructor_rejects_zero_poolManager() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(0)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  function test_constructor_rejects_zero_reserve() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(0)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  function test_constructor_rejects_zero_donsSink() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, address(0), HOLDERS,
      GOV, BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  function test_constructor_rejects_zero_holdersSink() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, address(0),
      GOV, BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  /// currency0 must sort strictly below currency1; pass them swapped so unwrap(c0) >= unwrap(c1) trips.
  function test_constructor_rejects_currency0_ge_currency1() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c1, c0, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  /// snipeSeconds == 0 would make the decay divide by zero; the constructor forbids it up front.
  function test_constructor_rejects_zero_snipe_seconds() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      BASE, SNIPE_START, 0, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  /// The other half of the cap guard (the `>= BPS` half is already pinned): a zero total fee is rejected too.
  function test_constructor_rejects_zero_cap() public {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      IPoolManager(address(mgr)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      0, 0, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
  }

  // ================================================================= dead hook surface reverts (flags are off)

  /// The six disabled callbacks must revert HookNotImplemented on any direct call. A mutant that returned a
  /// valid selector instead would silently re-enable a surface the permission flags say is off.
  function test_unused_hook_surface_reverts() public {
    ModifyLiquidityParams memory p =
      ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: int256(0), salt: bytes32(0)});
    BalanceDelta z = BalanceDeltaLibrary.ZERO_DELTA;

    vm.expectRevert(EsseyReserveHook.HookNotImplemented.selector);
    hook.afterInitialize(address(this), key, OPEN_PRICE, 0);
    vm.expectRevert(EsseyReserveHook.HookNotImplemented.selector);
    hook.beforeAddLiquidity(address(this), key, p, "");
    vm.expectRevert(EsseyReserveHook.HookNotImplemented.selector);
    hook.beforeRemoveLiquidity(address(this), key, p, "");
    vm.expectRevert(EsseyReserveHook.HookNotImplemented.selector);
    hook.afterRemoveLiquidity(address(this), key, p, z, z, "");
    vm.expectRevert(EsseyReserveHook.HookNotImplemented.selector);
    hook.beforeDonate(address(this), key, 0, 0, "");
    vm.expectRevert(EsseyReserveHook.HookNotImplemented.selector);
    hook.afterDonate(address(this), key, 0, 0, "");
  }
}
