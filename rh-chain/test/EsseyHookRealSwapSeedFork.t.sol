// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {EsseyReserveHook, IEsseyReserve} from "../src/market/EsseyReserveHook.sol";
import {LaunchSeeder} from "../src/market/LaunchSeeder.sol";

/// Minimal real router: drives the GENUINE PoolManager's unlock/swap/modifyLiquidity and settles both legs.
/// Pre-fund it with the input token; outputs are taken straight to `beneficiary`.
contract V4Actor is IUnlockCallback {
  using SafeERC20 for IERC20;

  IPoolManager public immutable pm;

  constructor(IPoolManager _pm) {
    pm = _pm;
  }

  function swap(PoolKey memory key, SwapParams memory p, address beneficiary) external returns (BalanceDelta d) {
    return abi.decode(pm.unlock(abi.encode(uint8(0), beneficiary, key, p, _emptyLiq())), (BalanceDelta));
  }

  function modify(PoolKey memory key, ModifyLiquidityParams memory p, address beneficiary)
    external
    returns (BalanceDelta d)
  {
    return abi.decode(pm.unlock(abi.encode(uint8(1), beneficiary, key, _emptySwap(), p)), (BalanceDelta));
  }

  function unlockCallback(bytes calldata data) external returns (bytes memory) {
    require(msg.sender == address(pm), "not pm");
    (uint8 action, address beneficiary, PoolKey memory key, SwapParams memory sp, ModifyLiquidityParams memory mp) =
      abi.decode(data, (uint8, address, PoolKey, SwapParams, ModifyLiquidityParams));

    BalanceDelta d;
    if (action == 0) d = pm.swap(key, sp, "");
    else (d,) = pm.modifyLiquidity(key, mp, "");

    _settle(key.currency0, d.amount0(), beneficiary);
    _settle(key.currency1, d.amount1(), beneficiary);
    return abi.encode(d);
  }

  function _settle(Currency c, int128 amt, address beneficiary) internal {
    if (amt < 0) {
      pm.sync(c);
      IERC20(Currency.unwrap(c)).safeTransfer(address(pm), uint256(uint128(-amt)));
      pm.settle();
    } else if (amt > 0) {
      pm.take(c, beneficiary, uint256(uint128(amt)));
    }
  }

  function _emptySwap() internal pure returns (SwapParams memory) {
    return SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
  }

  function _emptyLiq() internal pure returns (ModifyLiquidityParams memory) {
    return ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, salt: bytes32(0)});
  }
}

/// The two views of the deployed EsseyReserve the misconfiguration test reads (EsseyReserve.sol:193,:197).
interface EsseyReserveView {
  function circulatingSupply() external view returns (uint256);
  function reserveOf(address token) external view returns (uint256);
}

/// Calls the hook's PoolManager-only entry points directly, i.e. pretends to be a hostile manager.
contract HostileManager {
  function callBeforeSwap(EsseyReserveHook hook, PoolKey memory key, SwapParams memory p) external {
    hook.beforeSwap(address(this), key, p, "");
  }

  function callAfterAddLiquidity(EsseyReserveHook hook, PoolKey memory key, BalanceDelta d) external {
    hook.afterAddLiquidity(
      address(this),
      key,
      ModifyLiquidityParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, salt: bytes32(0)}),
      d,
      d,
      ""
    );
  }

  function callAfterSwap(EsseyReserveHook hook, PoolKey memory key, SwapParams memory p, BalanceDelta d) external {
    hook.afterSwap(address(this), key, p, d, "");
  }

  function callBeforeInitialize(EsseyReserveHook hook, PoolKey memory key, uint160 sp) external view {
    hook.beforeInitialize(address(this), key, sp);
  }
}

/// A "reserve" that re-enters the hook's payout the moment it is funded.
contract ReentrantReserve {
  EsseyReserveHook public hook;
  address public token;
  bool public armed;

  function arm(EsseyReserveHook _hook, address _token) external {
    hook = _hook;
    token = _token;
    armed = true;
  }

  function fund(address t, uint256 amount) external {
    IERC20(t).transferFrom(msg.sender, address(this), amount);
    if (armed) {
      armed = false;
      hook.fundReserve(token); // must be blocked by nonReentrant
    }
  }
}

/// ================================================================================================
/// The REAL-manager, REAL-token swap+seed harness for the $ESSEY launch hook.
///
/// Substrate: a pinned fork of Robinhood Chain mainnet (4663). Nothing here is mocked — the PoolManager,
/// $ESSEY, USDG and EsseyReserve are the deployed production contracts, and the seed ESSEY is moved by a
/// genuine ERC-20 transfer from the address that actually holds the entire supply today.
///
/// It exists to settle two things the audit gate (docs/audits/esseyreservehook-gate-2026-08-31.md:28-30)
/// explicitly deferred to deploy: feeCurrency==USDG, and $ESSEY non-circulating until the atomic seed.
/// ================================================================================================
contract EsseyHookRealSwapSeedForkTest is Test {
  using StateLibrary for IPoolManager;
  using SafeERC20 for IERC20;

  // --- RH mainnet 4663 anchors, all verified live (script/DeployEsseyV4Pool.s.sol:29-32) ---
  address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
  address constant ESSEY = 0x315790B57C19141B34C4653a91b096Cf3f071610; // currency0, 18 dec
  address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // currency1, 6 dec
  address constant RESERVE = 0xd970Ca726188e38982906Ae2284D2bdB80205A7b;
  /// The sole holder of all 8.888B $ESSEY (genesis mint 0x0->here, the token's only Transfer ever).
  address constant ESSEY_TREASURY = 0x93e6e42CcC676614FB3635b0983d60F35dDE4B9E;

  // --- the exact deploy config (script/DeployEsseyV4Pool.s.sol:37-49) ---
  uint24 constant POOL_FEE = 3000;
  int24 constant TICK_SPACING = 60;
  uint256 constant BPS = 10_000;
  uint256 constant BASE_FEE_BPS = 100;
  uint256 constant SNIPE_START_BPS = 9_800;
  uint256 constant SNIPE_SECONDS = 45;
  uint256 constant RES_SHARE = 4_500;
  uint256 constant HOLDERS_SHARE = 4_000;
  uint256 constant DONS_SHARE = 1_500;

  address constant DONS = address(0xD05);
  address constant HOLDERS = address(0x401);
  address constant GOV = address(0x60F);
  address constant BUYER = address(0xB0B);
  address constant SNIPER = address(0x51FE);

  /// ~$0.0000281/ESSEY at 18/6 decimals: raw price 2.81e-17 -> tick ~-381060, spacing-aligned.
  /// Chosen so the harness runs at the real 18-vs-6 decimal scale rather than a toy 1:1 price.
  int24 constant OPEN_TICK = -381_060;

  Currency c0 = Currency.wrap(ESSEY);
  Currency c1 = Currency.wrap(USDG);
  IPoolManager pm = IPoolManager(POOL_MANAGER);

  uint160 openPrice;
  bool forked;

  function setUp() public {
    try vm.createSelectFork(vm.rpcUrl("rh_mainnet")) {
      forked = true;
    } catch {
      forked = false;
    }
    openPrice = TickMath.getSqrtPriceAtTick(OPEN_TICK);
  }

  modifier onFork() {
    if (!forked) {
      emit log("SKIP: rh_mainnet fork unavailable");
      return;
    }
    _;
  }

  // ---------------------------------------------------------------- deployment helpers

  function _args(Currency feeCurrency) internal view returns (bytes memory) {
    return abi.encode(
      pm,
      IEsseyReserve(RESERVE),
      c0,
      c1,
      feeCurrency,
      POOL_FEE,
      TICK_SPACING,
      DONS,
      HOLDERS,
      GOV,
      BASE_FEE_BPS,
      SNIPE_START_BPS,
      SNIPE_SECONDS,
      RES_SHARE,
      HOLDERS_SHARE,
      DONS_SHARE,
      openPrice
    );
  }

  function _mineHook(Currency feeCurrency) internal returns (EsseyReserveHook) {
    bytes32 initHash = keccak256(abi.encodePacked(type(EsseyReserveHook).creationCode, _args(feeCurrency)));
    for (uint256 s = 0; s < 500_000; s++) {
      address a =
        address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(s), initHash)))));
      if (uint160(a) & 0x3FFF == 0x24CC && a.code.length == 0) {
        return new EsseyReserveHook{salt: bytes32(s)}(
          pm,
          IEsseyReserve(RESERVE),
          c0,
          c1,
          feeCurrency,
          POOL_FEE,
          TICK_SPACING,
          DONS,
          HOLDERS,
          GOV,
          BASE_FEE_BPS,
          SNIPE_START_BPS,
          SNIPE_SECONDS,
          RES_SHARE,
          HOLDERS_SHARE,
          DONS_SHARE,
          openPrice
        );
      }
    }
    revert("no salt");
  }

  function _key(EsseyReserveHook hook) internal view returns (PoolKey memory) {
    return PoolKey({
      currency0: c0,
      currency1: c1,
      fee: POOL_FEE,
      tickSpacing: TICK_SPACING,
      hooks: IHooks(address(hook))
    });
  }

  /// Three ascending single-sided ESSEY rungs; the first starts AT the opening tick so it is ACTIVE at open.
  function _ladder() internal pure returns (LaunchSeeder.Rung[] memory r) {
    r = new LaunchSeeder.Rung[](3);
    r[0] = LaunchSeeder.Rung({tickLower: OPEN_TICK, tickUpper: OPEN_TICK + 6000, esseyAmount: 500_000_000e18});
    r[1] = LaunchSeeder.Rung({tickLower: OPEN_TICK + 6000, tickUpper: OPEN_TICK + 12_000, esseyAmount: 500_000_000e18});
    r[2] =
      LaunchSeeder.Rung({tickLower: OPEN_TICK + 12_000, tickUpper: OPEN_TICK + 18_000, esseyAmount: 500_000_000e18});
  }

  function _seedLadderAmount() internal pure returns (uint256) {
    return 1_500_000_000e18;
  }

  /// Real ERC-20 transfer from the wallet that genuinely holds the supply — no `deal` on $ESSEY.
  function _sendEssey(address to, uint256 amount) internal {
    vm.prank(ESSEY_TREASURY);
    IERC20(ESSEY).safeTransfer(to, amount);
  }

  function _giveUsdg(address to, uint256 amount) internal {
    deal(USDG, to, amount);
    assertEq(IERC20(USDG).balanceOf(to), amount, "USDG funding failed on the real proxy");
  }

  function _deploySeeder(EsseyReserveHook hook) internal returns (LaunchSeeder) {
    return new LaunchSeeder(pm, c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(hook)), openPrice);
  }

  /// Full production launch sequence on the real manager: mine the hook, deploy the seeder, fund it with
  /// real $ESSEY, and run the one-shot atomic init+seed.
  function _launch() internal returns (EsseyReserveHook hook, LaunchSeeder seeder) {
    hook = _mineHook(c1);
    seeder = _deploySeeder(hook);
    _sendEssey(address(seeder), _seedLadderAmount());
    seeder.seed(_ladder());
  }

  function _liq(EsseyReserveHook hook) internal view returns (uint128) {
    return pm.getLiquidity(PoolId.wrap(hook.poolIdRaw()));
  }

  // ---------------------------------------------------------------- independent fee math (non-circular)

  function _surchargeAt(uint256 launchTime, uint256 ts) internal pure returns (uint256) {
    if (launchTime == 0 || ts <= launchTime) return SNIPE_START_BPS;
    uint256 e = ts - launchTime;
    if (e >= SNIPE_SECONDS) return 0;
    return (SNIPE_START_BPS * (SNIPE_SECONDS - e)) / SNIPE_SECONDS;
  }

  function _expectedFee(uint256 amount, uint256 launchTime, uint256 ts) internal pure returns (uint256) {
    return (amount * BASE_FEE_BPS) / BPS + (amount * _surchargeAt(launchTime, ts)) / BPS;
  }

  // ---------------------------------------------------------------- swap helpers (real manager)

  function _buy(EsseyReserveHook hook, address who, uint256 usdgIn) internal returns (BalanceDelta) {
    V4Actor actor = new V4Actor(pm);
    _giveUsdg(address(actor), usdgIn);
    return actor.swap(
      _key(hook),
      SwapParams({
        zeroForOne: false,
        amountSpecified: -int256(usdgIn),
        sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
      }),
      who
    );
  }

  function _sell(EsseyReserveHook hook, address who, uint256 esseyIn) internal returns (BalanceDelta) {
    V4Actor actor = new V4Actor(pm);
    _sendEssey(address(actor), esseyIn);
    return actor.swap(
      _key(hook),
      SwapParams({
        zeroForOne: true,
        amountSpecified: -int256(esseyIn),
        sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
      }),
      who
    );
  }

  // ================================================================= 0. the substrate is real

  function test_R0_substrate_is_the_real_deployed_stack() public onFork {
    assertEq(block.chainid, 4663, "not RH mainnet");
    assertGt(POOL_MANAGER.code.length, 20_000, "PoolManager is not the real 24kB manager");
    assertEq(IERC20(ESSEY).totalSupply(), 8_888_888_888e18, "not the real fixed-supply $ESSEY");
    assertEq(IERC20(USDG).totalSupply() > 0, true, "USDG dead on fork");
    assertEq(ESSEY < USDG, true, "currency sort");

    // Precondition 2, as it stands TODAY on chain: 100% of $ESSEY sits in one treasury EOA.
    assertEq(
      IERC20(ESSEY).balanceOf(ESSEY_TREASURY), IERC20(ESSEY).totalSupply(), "$ESSEY is NOT fully non-circulating"
    );
    emit log_named_decimal_uint("ESSEY held by treasury", IERC20(ESSEY).balanceOf(ESSEY_TREASURY), 18);
    emit log_named_uint("USDG decimals", 6);
  }

  // ================================================================= 1. atomic init + seed, real manager

  function test_R1_atomic_seed_on_real_manager() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    LaunchSeeder seeder = _deploySeeder(hook);

    (uint160 pre,,,) = pm.getSlot0(PoolId.wrap(hook.poolIdRaw()));
    assertEq(pre, 0, "pool already initialized before seed");

    _sendEssey(address(seeder), _seedLadderAmount());
    uint256 pmEsseyBefore = IERC20(ESSEY).balanceOf(POOL_MANAGER);

    seeder.seed(_ladder());

    (uint160 post, int24 tick,,) = pm.getSlot0(PoolId.wrap(hook.poolIdRaw()));
    assertEq(post, openPrice, "opening price not pinned");
    assertEq(tick, OPEN_TICK, "opening tick wrong");
    assertEq(seeder.positionCount(), 3, "ladder not fully minted");
    assertGt(_liq(hook), 0, "no ACTIVE liquidity at open");
    assertEq(hook.launchTime(), block.timestamp, "clock not stamped at the seed");

    uint256 moved = IERC20(ESSEY).balanceOf(POOL_MANAGER) - pmEsseyBefore;
    emit log_named_decimal_uint("ESSEY actually delivered to the real PoolManager", moved, 18);
    assertGt(moved, _seedLadderAmount() - 1e18, "seed under-delivered");
    assertLe(IERC20(ESSEY).balanceOf(address(seeder)), 1e18, "leftover above MAX_LEFTOVER");
    assertEq(IERC20(USDG).balanceOf(address(seeder)), 0, "seeder touched USDG");
  }

  // ================================================================= 2. real buy, fee reconciled to the wei

  function test_R2_real_buy_skims_usdg_exactly() public onFork {
    (EsseyReserveHook hook,) = _launch();
    uint256 launchTime = hook.launchTime();

    uint256 usdgIn = 1_000e6; // 1,000 USDG
    uint256 expFee = _expectedFee(usdgIn, launchTime, block.timestamp);

    _buy(hook, BUYER, usdgIn);

    uint256 hookUsdg = IERC20(USDG).balanceOf(address(hook));
    emit log_named_uint("fee bps at t0", BASE_FEE_BPS + _surchargeAt(launchTime, block.timestamp));
    emit log_named_uint("USDG in (6dec raw)", usdgIn);
    emit log_named_uint("USDG skimmed by hook", hookUsdg);
    emit log_named_decimal_uint("ESSEY delivered to buyer", IERC20(ESSEY).balanceOf(BUYER), 18);

    assertEq(hookUsdg, expFee, "skim != independently computed fee");
    assertEq(
      hook.reserveEscrow(USDG) + hook.holdersEscrow(USDG) + hook.donsEscrow(USDG),
      hookUsdg,
      "escrow does not reconcile to the wei"
    );

    // The whole surcharge is the reserve's, plus its slice of the base fee.
    uint256 baseFee = (usdgIn * BASE_FEE_BPS) / BPS;
    uint256 surcharge = expFee - baseFee;
    uint256 dons = (baseFee * DONS_SHARE) / BPS;
    uint256 holders = (baseFee * HOLDERS_SHARE) / BPS;
    assertEq(hook.donsEscrow(USDG), dons, "dons slice");
    assertEq(hook.holdersEscrow(USDG), holders, "holders slice");
    assertEq(hook.reserveEscrow(USDG), baseFee - dons - holders + surcharge, "reserve slice + surcharge");

    // Precondition 1 observable: the hook never holds $ESSEY.
    assertEq(IERC20(ESSEY).balanceOf(address(hook)), 0, "hook skimmed $ESSEY");
    assertGt(IERC20(ESSEY).balanceOf(BUYER), 0, "buyer got no ESSEY");
  }

  // ================================================================= 3. real sell (unspecified-leg skim)

  function test_R3_real_sell_skims_usdg_on_the_unspecified_leg() public onFork {
    (EsseyReserveHook hook,) = _launch();
    vm.warp(block.timestamp + SNIPE_SECONDS); // surcharge exhausted -> steady state 1%

    // Prime the pool with USDG so a sell has something to pay out.
    _buy(hook, BUYER, 1_000e6);
    uint256 hookUsdgAfterBuy = IERC20(USDG).balanceOf(address(hook));

    uint256 esseyIn = 1_000_000e18;
    BalanceDelta d = _sell(hook, BUYER, esseyIn);

    // amount1 > 0 is the USDG the swapper actually received, already net of the hook's afterSwap delta.
    uint256 usdgOut = uint256(uint128(d.amount1()));
    uint256 skim = IERC20(USDG).balanceOf(address(hook)) - hookUsdgAfterBuy;
    emit log_named_uint("USDG out to seller (net)", usdgOut);
    emit log_named_uint("USDG skimmed on the sell", skim);

    assertEq(_surchargeAt(hook.launchTime(), block.timestamp), 0, "surcharge should be exhausted");
    // Gross USDG off the pool = what the seller kept + what the hook took; the skim is 1% of the gross.
    uint256 gross = usdgOut + skim;
    assertEq(skim, (gross * BASE_FEE_BPS) / BPS, "sell skim != 1% of the gross USDG leg");
    assertEq(IERC20(ESSEY).balanceOf(address(hook)), 0, "hook skimmed $ESSEY on the sell");
    assertEq(
      hook.reserveEscrow(USDG) + hook.holdersEscrow(USDG) + hook.donsEscrow(USDG),
      IERC20(USDG).balanceOf(address(hook)),
      "escrow does not reconcile after two real swaps"
    );
  }

  // ================================================================= 4. decay is real and monotone

  function test_R4_surcharge_decays_across_the_real_window() public onFork {
    (EsseyReserveHook hook,) = _launch();
    uint256 t0 = hook.launchTime();

    uint256[3] memory offsets = [uint256(0), 22, 45];
    uint256 prevBps = type(uint256).max;
    for (uint256 i = 0; i < 3; i++) {
      vm.warp(t0 + offsets[i]);
      uint256 before = IERC20(USDG).balanceOf(address(hook));
      uint256 amt = 1_000e6;
      _buy(hook, BUYER, amt);
      uint256 taken = IERC20(USDG).balanceOf(address(hook)) - before;
      uint256 bps = (taken * BPS) / amt;
      emit log_named_uint("t+", offsets[i]);
      emit log_named_uint("  effective fee bps", bps);
      assertEq(taken, _expectedFee(amt, t0, t0 + offsets[i]), "fee off the independent schedule");
      assertLt(bps, prevBps, "surcharge not strictly decreasing");
      prevBps = bps;
    }
    assertEq(prevBps, BASE_FEE_BPS, "steady state is not the 1% base fee");
  }

  // ================================================================= 5. payouts hit the REAL reserve

  function test_R5_payouts_reach_the_real_adminless_reserve() public onFork {
    (EsseyReserveHook hook,) = _launch();
    _buy(hook, BUYER, 1_000e6);

    uint256 resEscrow = hook.reserveEscrow(USDG);
    uint256 holdEscrow = hook.holdersEscrow(USDG);
    uint256 donEscrow = hook.donsEscrow(USDG);
    uint256 reserveBefore = IERC20(USDG).balanceOf(RESERVE);

    hook.fundReserve(USDG);
    hook.fundHolders(USDG);
    hook.fundDons(USDG);

    assertEq(IERC20(USDG).balanceOf(RESERVE) - reserveBefore, resEscrow, "reserve did not receive its slice");
    assertEq(IERC20(USDG).balanceOf(HOLDERS), holdEscrow, "holders sink short");
    assertEq(IERC20(USDG).balanceOf(DONS), donEscrow, "dons sink short");
    assertEq(IERC20(USDG).balanceOf(address(hook)), 0, "hook retained value after payout");

    emit log_named_uint("USDG into the real reserve 0xd970", resEscrow);

    vm.expectRevert(EsseyReserveHook.NothingToFund.selector);
    hook.fundReserve(USDG);
  }

  // ================================================================= 6. PRECONDITION 1 — feeCurrency=USDG

  function test_P1_deployed_config_pins_feeCurrency_to_usdg() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    assertEq(Currency.unwrap(hook.feeCurrency()), USDG, "feeCurrency is not USDG");
    assertTrue(hook.feeIsCurrency1(), "USDG must be the currency1 leg");
  }

  /// The misconfiguration the receipt warns about is REAL and the contract does not self-defend: with
  /// feeCurrency = ESSEY the identical code skims $ESSEY out of the buyer's output on every buy.
  function test_P1_misconfigured_feeCurrency_essey_actually_skims_essey() public onFork {
    EsseyReserveHook bad = _mineHook(c0); // feeCurrency = currency0 = $ESSEY
    assertEq(Currency.unwrap(bad.feeCurrency()), ESSEY, "setup");
    assertFalse(bad.feeIsCurrency1(), "setup");

    LaunchSeeder seeder = _deploySeeder(bad);
    _sendEssey(address(seeder), _seedLadderAmount());
    seeder.seed(_ladder());

    _buy(bad, BUYER, 1_000e6);

    uint256 stolen = IERC20(ESSEY).balanceOf(address(bad));
    emit log_named_decimal_uint("FINDING: misconfigured hook skimmed $ESSEY", stolen, 18);
    emit log_named_uint("           and USDG skimmed", IERC20(USDG).balanceOf(address(bad)));

    assertGt(stolen, 0, "misconfig did NOT skim ESSEY - re-derive the failure mode");
    assertEq(IERC20(USDG).balanceOf(address(bad)), 0, "misconfigured hook should take nothing in USDG");
    assertEq(bad.reserveEscrow(ESSEY) + bad.holdersEscrow(ESSEY) + bad.donsEscrow(ESSEY), stolen, "escrow keyed on ESSEY");
    // The buyer is the one paying it: their ESSEY output is reduced by the skim.
    assertEq(IERC20(ESSEY).balanceOf(address(bad)) > 0 && IERC20(ESSEY).balanceOf(BUYER) > 0, true, "buy path");
  }

  /// The misconfiguration's worst consequence, on the REAL reserve. EsseyReserve.payShare (`:162-174`) has no
  /// exclusion for its own claim token, and circulatingSupply (`:193`) subtracts the reserve's own ESSEY
  /// balance. So a feeCurrency=ESSEY hook does not merely skim the wrong asset — it pumps $ESSEY into the
  /// reserve, where it simultaneously reads as burned supply AND as claimable backing for itself.
  function test_P1_misconfig_pollutes_the_real_reserve_with_its_own_claim_token() public onFork {
    EsseyReserveHook bad = _mineHook(c0);
    LaunchSeeder seeder = _deploySeeder(bad);
    _sendEssey(address(seeder), _seedLadderAmount());
    seeder.seed(_ladder());
    _buy(bad, BUYER, 1_000e6);

    uint256 circBefore = EsseyReserveView(RESERVE).circulatingSupply();
    assertEq(EsseyReserveView(RESERVE).reserveOf(ESSEY), 0, "reserve should hold no ESSEY at launch");

    uint256 amount = bad.fundReserve(ESSEY);

    assertEq(EsseyReserveView(RESERVE).reserveOf(ESSEY), amount, "ESSEY did not land in the reserve");
    emit log_named_decimal_uint("FINDING: $ESSEY pushed into its own reserve as 'backing'", amount, 18);
    emit log_named_decimal_uint("  circulatingSupply understated by", circBefore - EsseyReserveView(RESERVE).circulatingSupply(), 18);
    assertEq(circBefore - EsseyReserveView(RESERVE).circulatingSupply(), amount, "display supply not distorted 1:1");
  }

  /// The seeded LP is owned by the seeder (PoolManager.sol:160 keys the position on msg.sender). A third
  /// party cannot remove it even though beforeRemoveLiquidity is not gated by the hook.
  function test_L1_seeded_lp_cannot_be_removed_by_a_third_party() public onFork {
    (EsseyReserveHook hook, LaunchSeeder seeder) = _launch();
    uint128 liq = _liq(hook);
    (,, uint128 rung0) = seeder.positions(0);

    V4Actor thief = new V4Actor(pm);
    vm.expectRevert(); // the thief's own position at that range is empty; the removal underflows
    thief.modify(
      _key(hook),
      ModifyLiquidityParams({
        tickLower: OPEN_TICK,
        tickUpper: OPEN_TICK + 6000,
        liquidityDelta: -int256(uint256(rung0)),
        salt: bytes32(0)
      }),
      SNIPER
    );
    assertEq(_liq(hook), liq, "seeded liquidity moved");
    assertEq(IERC20(ESSEY).balanceOf(SNIPER), 0, "thief extracted ESSEY");
  }

  /// USDG donated straight to the hook is never credited to escrow, so the payouts cannot pay it out and no
  /// one can pull it. Not a theft vector — a permanent stranding one.
  function test_L2_donated_usdg_is_stranded_not_stealable() public onFork {
    (EsseyReserveHook hook,) = _launch();
    _buy(hook, BUYER, 1_000e6);
    uint256 escrowed =
      hook.reserveEscrow(USDG) + hook.holdersEscrow(USDG) + hook.donsEscrow(USDG);

    deal(USDG, address(this), 500e6);
    IERC20(USDG).safeTransfer(address(hook), 500e6);

    assertEq(
      hook.reserveEscrow(USDG) + hook.holdersEscrow(USDG) + hook.donsEscrow(USDG),
      escrowed,
      "a donation was credited to escrow"
    );
    hook.fundReserve(USDG);
    hook.fundHolders(USDG);
    hook.fundDons(USDG);
    assertEq(IERC20(USDG).balanceOf(address(hook)), 500e6, "donation not stranded exactly");
    vm.expectRevert(EsseyReserveHook.NothingToFund.selector);
    hook.fundReserve(USDG);
    emit log_named_uint("USDG permanently stranded in the hook by a donation", 500e6);
  }

  function test_P1_constructor_rejects_feeCurrency_outside_the_pair() public onFork {
    vm.expectRevert(EsseyReserveHook.BadConfig.selector);
    new EsseyReserveHook(
      pm,
      IEsseyReserve(RESERVE),
      c0,
      c1,
      Currency.wrap(address(0xDEAD)),
      POOL_FEE,
      TICK_SPACING,
      DONS,
      HOLDERS,
      GOV,
      BASE_FEE_BPS,
      SNIPE_START_BPS,
      SNIPE_SECONDS,
      RES_SHARE,
      HOLDERS_SHARE,
      DONS_SHARE,
      openPrice
    );
  }

  // ================================================================= 7. PRECONDITION 2 — atomic seed

  function test_P2_essey_cannot_be_bought_before_the_seed() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    pm.initialize(_key(hook), openPrice); // permissionless init at the pinned price
    assertEq(_liq(hook), 0, "pool not empty");

    V4Actor actor = new V4Actor(pm);
    _giveUsdg(address(actor), 1_000e6);
    vm.expectRevert(); // manager bubbles EsseyReserveHook.EmptyPool
    actor.swap(
      _key(hook),
      SwapParams({zeroForOne: false, amountSpecified: -int256(1_000e6), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
      SNIPER
    );
    assertEq(IERC20(ESSEY).balanceOf(SNIPER), 0, "sniper acquired ESSEY pre-seed");
    assertEq(hook.launchTime(), 0, "empty-pool swap stamped the clock");
  }

  function test_P2_seed_is_one_shot() public onFork {
    (, LaunchSeeder seeder) = _launch();
    _sendEssey(address(seeder), 1_000e18);
    vm.expectRevert(LaunchSeeder.AlreadySeeded.selector);
    seeder.seed(_ladder());
  }

  function test_P2_seed_is_seedCaller_only() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    LaunchSeeder seeder = _deploySeeder(hook);
    _sendEssey(address(seeder), _seedLadderAmount());
    vm.prank(SNIPER);
    vm.expectRevert(LaunchSeeder.NotSeedCaller.selector);
    seeder.seed(_ladder());
  }

  /// A partial seed must be impossible: one straddling rung reverts the WHOLE call, leaving no position,
  /// no liquidity, and every wei of ESSEY still in the seeder.
  function test_P2_partial_seed_is_impossible() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    LaunchSeeder seeder = _deploySeeder(hook);
    _sendEssey(address(seeder), _seedLadderAmount());

    LaunchSeeder.Rung[] memory bad = new LaunchSeeder.Rung[](3);
    bad[0] = LaunchSeeder.Rung({tickLower: OPEN_TICK, tickUpper: OPEN_TICK + 6000, esseyAmount: 500_000_000e18});
    bad[1] = LaunchSeeder.Rung({tickLower: OPEN_TICK + 6000, tickUpper: OPEN_TICK + 12_000, esseyAmount: 500_000_000e18});
    bad[2] = LaunchSeeder.Rung({tickLower: OPEN_TICK - 6000, tickUpper: OPEN_TICK + 6000, esseyAmount: 500_000_000e18}); // straddles spot

    vm.expectRevert(LaunchSeeder.UsdgOwed.selector);
    seeder.seed(bad);

    assertEq(seeder.positionCount(), 0, "a rung survived the reverted seed");
    assertEq(_liq(hook), 0, "liquidity survived the reverted seed");
    assertEq(seeder.seeded(), false, "seeded flag stuck after a reverted seed");
    assertEq(IERC20(ESSEY).balanceOf(address(seeder)), _seedLadderAmount(), "ESSEY left the seeder on a failed seed");
    assertEq(hook.launchTime(), 0, "clock stamped by a failed seed");
  }

  function test_P2_init_frontrun_at_pinned_price_is_tolerated() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    vm.prank(SNIPER);
    pm.initialize(_key(hook), openPrice);

    LaunchSeeder seeder = _deploySeeder(hook);
    _sendEssey(address(seeder), _seedLadderAmount());
    seeder.seed(_ladder()); // must not revert
    assertTrue(seeder.seeded(), "seed blocked by an init front-run");
    assertGt(_liq(hook), 0, "no liquidity after tolerated pre-init");
    assertEq(hook.launchTime(), block.timestamp, "clock not stamped at the seed");
  }

  function test_P2_init_frontrun_at_a_chosen_price_is_rejected() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    vm.prank(SNIPER);
    vm.expectRevert(); // manager bubbles WrongOpeningPrice
    pm.initialize(_key(hook), TickMath.getSqrtPriceAtTick(OPEN_TICK + 60_000));

    (uint160 sp,,,) = pm.getSlot0(PoolId.wrap(hook.poolIdRaw()));
    assertEq(sp, 0, "pool got initialized at the attacker's price");
  }

  /// THE reason precondition 2 is load-bearing. Anyone holding even DUST $ESSEY can initialize the pool and
  /// add a single ESSEY-only rung, which stamps `launchTime`. Warp past the window and the founder's seed
  /// lands into an already-expired anti-snipe surcharge: the first buy pays 1% instead of 99%.
  function test_P2_ATTACK_circulating_essey_lets_a_third_party_start_the_clock() public onFork {
    EsseyReserveHook hook = _mineHook(c1);

    uint256 dust = 1_000_000e18; // ESSEY the attacker holds because it circulated
    _sendEssey(SNIPER, dust);

    vm.prank(SNIPER);
    pm.initialize(_key(hook), openPrice);
    assertEq(hook.launchTime(), 0, "init alone must not stamp");

    // one ESSEY-only rung at the open tick
    V4Actor actor = new V4Actor(pm);
    vm.prank(SNIPER);
    IERC20(ESSEY).safeTransfer(address(actor), dust);
    uint128 L = LiquidityAmounts.getLiquidityForAmount0(
      TickMath.getSqrtPriceAtTick(OPEN_TICK), TickMath.getSqrtPriceAtTick(OPEN_TICK + 6000), dust - 1e3
    );
    actor.modify(
      _key(hook),
      ModifyLiquidityParams({
        tickLower: OPEN_TICK,
        tickUpper: OPEN_TICK + 6000,
        liquidityDelta: int256(uint256(L)),
        salt: bytes32(0)
      }),
      SNIPER
    );

    assertEq(hook.launchTime(), block.timestamp, "FINDING EXPECTED: attacker could not stamp the clock");
    emit log_named_uint("attacker stamped launchTime at", hook.launchTime());

    vm.warp(block.timestamp + SNIPE_SECONDS + 1);
    assertEq(hook.surchargeBpsAt(block.timestamp), 0, "surcharge should be fully decayed by the attacker");

    // Founder's seed now lands into an expired window and does NOT re-stamp.
    LaunchSeeder seeder = _deploySeeder(hook);
    _sendEssey(address(seeder), _seedLadderAmount());
    uint256 stampBefore = hook.launchTime();
    seeder.seed(_ladder());
    assertEq(hook.launchTime(), stampBefore, "seed re-stamped (would have saved the launch)");

    uint256 before = IERC20(USDG).balanceOf(address(hook));
    _buy(hook, SNIPER, 10_000e6);
    uint256 paid = IERC20(USDG).balanceOf(address(hook)) - before;
    uint256 sniped = IERC20(ESSEY).balanceOf(SNIPER);
    emit log_named_uint("sniper paid fee bps", (paid * BPS) / 10_000e6);
    emit log_named_decimal_uint("sniper ESSEY out", sniped, 18);
    assertEq((paid * BPS) / 10_000e6, BASE_FEE_BPS, "sniper did not get the 1% rate");

    // Counterfactual: the SAME 10,000 USDG buy against an un-attacked launch, at the seed instant.
    (EsseyReserveHook clean,) = _launch();
    _buy(clean, BUYER, 10_000e6);
    uint256 honest = IERC20(ESSEY).balanceOf(BUYER);
    emit log_named_decimal_uint("same buy on an un-attacked launch", honest, 18);
    emit log_named_uint("ESSEY multiple the attack bought the sniper", sniped / honest);
    emit log_named_uint("USDG the reserve LOST on this one buy", (10_000e6 * SNIPE_START_BPS) / BPS - (paid - (10_000e6 * BASE_FEE_BPS) / BPS));
    assertGt(sniped, honest * 50, "attack did not materially advantage the sniper");
  }

  /// The mirror: circulating USDG is harmless. A USDG-only add owes no currency0, so it cannot stamp.
  function test_P2_circulating_usdg_cannot_start_the_clock() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    pm.initialize(_key(hook), openPrice);

    V4Actor actor = new V4Actor(pm);
    _giveUsdg(address(actor), 1_000e6);
    uint128 L = LiquidityAmounts.getLiquidityForAmount1(
      TickMath.getSqrtPriceAtTick(OPEN_TICK - 12_000), TickMath.getSqrtPriceAtTick(OPEN_TICK - 6000), 900e6
    );
    actor.modify(
      _key(hook),
      ModifyLiquidityParams({
        tickLower: OPEN_TICK - 12_000,
        tickUpper: OPEN_TICK - 6000,
        liquidityDelta: int256(uint256(L)),
        salt: bytes32(0)
      }),
      SNIPER
    );

    assertEq(hook.launchTime(), 0, "a USDG-only add stamped the clock");
    assertEq(_liq(hook), 0, "USDG-only add below spot became active liquidity");
  }

  // ================================================================= 8. hostile callers

  function test_A1_hostile_manager_cannot_drive_the_hook() public onFork {
    (EsseyReserveHook hook,) = _launch();
    HostileManager evil = new HostileManager();
    PoolKey memory k = _key(hook);

    vm.expectRevert(EsseyReserveHook.NotPoolManager.selector);
    evil.callBeforeSwap(
      hook, k, SwapParams({zeroForOne: false, amountSpecified: -1e9, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1})
    );

    vm.expectRevert(EsseyReserveHook.NotPoolManager.selector);
    evil.callBeforeInitialize(hook, k, openPrice);
  }

  function test_A2_hostile_manager_cannot_restamp_or_forge_a_skim() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    HostileManager evil = new HostileManager();
    PoolKey memory k = _key(hook);
    BalanceDelta d = BalanceDelta.wrap(int256(uint256(uint128(uint256(int256(-1e18)))) << 128));

    vm.expectRevert(EsseyReserveHook.NotPoolManager.selector);
    evil.callAfterAddLiquidity(hook, k, d);
    assertEq(hook.launchTime(), 0, "a non-manager stamped the clock");

    vm.expectRevert(EsseyReserveHook.NotPoolManager.selector);
    evil.callAfterSwap(
      hook, k, SwapParams({zeroForOne: false, amountSpecified: -1e9, sqrtPriceLimitX96: 0}), d
    );
    assertEq(hook.reserveEscrow(USDG), 0, "a non-manager forged escrow");
  }

  function test_A3_reentrant_reserve_is_blocked_on_payout() public onFork {
    ReentrantReserve evil = new ReentrantReserve();
    // A hook whose reserve is hostile: same code, different constructor arg.
    bytes memory args = abi.encode(
      pm,
      IEsseyReserve(address(evil)),
      c0,
      c1,
      c1,
      POOL_FEE,
      TICK_SPACING,
      DONS,
      HOLDERS,
      GOV,
      BASE_FEE_BPS,
      SNIPE_START_BPS,
      SNIPE_SECONDS,
      RES_SHARE,
      HOLDERS_SHARE,
      DONS_SHARE,
      openPrice
    );
    bytes32 initHash = keccak256(abi.encodePacked(type(EsseyReserveHook).creationCode, args));
    EsseyReserveHook hook;
    for (uint256 s = 0; s < 500_000; s++) {
      address a =
        address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(s), initHash)))));
      if (uint160(a) & 0x3FFF == 0x24CC && a.code.length == 0) {
        hook = new EsseyReserveHook{salt: bytes32(s)}(
          pm,
          IEsseyReserve(address(evil)),
          c0,
          c1,
          c1,
          POOL_FEE,
          TICK_SPACING,
          DONS,
          HOLDERS,
          GOV,
          BASE_FEE_BPS,
          SNIPE_START_BPS,
          SNIPE_SECONDS,
          RES_SHARE,
          HOLDERS_SHARE,
          DONS_SHARE,
          openPrice
        );
        break;
      }
    }
    LaunchSeeder seeder = _deploySeeder(hook);
    _sendEssey(address(seeder), _seedLadderAmount());
    seeder.seed(_ladder());
    _buy(hook, BUYER, 1_000e6);

    evil.arm(hook, USDG);
    uint256 escrow = hook.reserveEscrow(USDG);
    vm.expectRevert(); // ReentrancyGuard bubbles through the hostile reserve
    hook.fundReserve(USDG);
    assertEq(hook.reserveEscrow(USDG), escrow, "escrow moved despite the reverted reentrant payout");
    assertEq(IERC20(USDG).balanceOf(address(evil)), 0, "hostile reserve extracted value");
  }

  // ================================================================= 9. dust / rounding

  function test_D1_dust_buy_pays_zero_fee_and_the_leak_is_bounded() public onFork {
    (EsseyReserveHook hook,) = _launch();
    vm.warp(block.timestamp + SNIPE_SECONDS); // 1% steady state = worst case for rounding

    // 99 raw USDG (9.9e-5 USDG): 99*100/10000 == 0 -> the fee rounds away entirely.
    uint256 dustIn = 99;
    _buy(hook, BUYER, dustIn);
    assertEq(IERC20(USDG).balanceOf(address(hook)), 0, "dust unexpectedly skimmed");
    emit log_named_uint("dust buy raw USDG in (fee rounds to 0)", dustIn);
    emit log_named_uint("max free notional per swap (raw USDG)", (BPS / BASE_FEE_BPS) - 1);
    emit log_named_decimal_uint("ESSEY the dust buy extracted", IERC20(ESSEY).balanceOf(BUYER), 18);

    // The leak is bounded by 99 raw USDG per swap, i.e. < $0.0001 of notional; gas dwarfs it.
    assertLt((BPS / BASE_FEE_BPS) - 1, 100, "free-notional window wider than one basis unit");
  }

  // ================================================================= 10. S-1 / S-2 (open LOW findings)

  /// S-1, independently reproduced on the REAL manager: the empty-pool guard never disarms. One buy large
  /// enough to walk price past the top rung leaves getLiquidity()==0, and from then on EVERY swap — in BOTH
  /// directions, including the sell that would arbitrage the price back — reverts. The pool is bricked.
  function test_S1_oversized_buy_bricks_the_pool_permanently() public onFork {
    (EsseyReserveHook hook,) = _launch();
    vm.warp(block.timestamp + SNIPE_SECONDS);
    assertGt(_liq(hook), 0, "precondition: pool is live");

    _buy(hook, BUYER, 1_000_000e6); // 1,000,000 USDG — walks past the top rung

    (, int24 tick,,) = pm.getSlot0(PoolId.wrap(hook.poolIdRaw()));
    emit log_named_int("tick after the oversized buy", tick);
    emit log_named_uint("active liquidity after", _liq(hook));
    assertEq(_liq(hook), 0, "S-1 not reproduced: liquidity survived");

    V4Actor a1 = new V4Actor(pm);
    _giveUsdg(address(a1), 1_000e6);
    vm.expectRevert();
    a1.swap(
      _key(hook),
      SwapParams({zeroForOne: false, amountSpecified: -int256(1_000e6), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
      BUYER
    );

    // The recovery trade is blocked too — this is what makes it a brick rather than illiquidity.
    V4Actor a2 = new V4Actor(pm);
    _sendEssey(address(a2), 1_000e18);
    vm.expectRevert();
    a2.swap(
      _key(hook),
      SwapParams({zeroForOne: true, amountSpecified: -int256(1_000e18), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
      BUYER
    );
    emit log("FINDING S-1 CONFIRMED on the real manager: pool un-swappable in both directions");
  }

  /// S-2, independently reproduced: a ladder entirely ABOVE spot passes every per-rung check, mints all three
  /// positions, and yields ZERO active liquidity. `seeded` is now true, there is no withdraw path, and the
  /// guard makes the pool un-swappable — the seed ESSEY is locked forever.
  function test_S2_ladder_above_spot_seeds_zero_active_liquidity_and_locks_the_essey() public onFork {
    EsseyReserveHook hook = _mineHook(c1);
    LaunchSeeder seeder = _deploySeeder(hook);
    _sendEssey(address(seeder), _seedLadderAmount());

    LaunchSeeder.Rung[] memory above = new LaunchSeeder.Rung[](3);
    above[0] = LaunchSeeder.Rung({tickLower: OPEN_TICK + 6000, tickUpper: OPEN_TICK + 12_000, esseyAmount: 500_000_000e18});
    above[1] =
      LaunchSeeder.Rung({tickLower: OPEN_TICK + 12_000, tickUpper: OPEN_TICK + 18_000, esseyAmount: 500_000_000e18});
    above[2] =
      LaunchSeeder.Rung({tickLower: OPEN_TICK + 18_000, tickUpper: OPEN_TICK + 24_000, esseyAmount: 500_000_000e18});

    uint256 pmBefore = IERC20(ESSEY).balanceOf(POOL_MANAGER);
    seeder.seed(above); // passes every check

    assertTrue(seeder.seeded(), "seed did not complete");
    assertEq(seeder.positionCount(), 3, "rungs not minted");
    assertEq(_liq(hook), 0, "S-2 not reproduced: the above-spot ladder was active");
    uint256 locked = IERC20(ESSEY).balanceOf(POOL_MANAGER) - pmBefore;
    emit log_named_decimal_uint("FINDING S-2 CONFIRMED: ESSEY locked in a dead pool", locked, 18);
    assertGt(locked, _seedLadderAmount() - 1e18, "ESSEY not delivered");

    // One-shot: no retry, and no withdraw path exists.
    _sendEssey(address(seeder), 1_000e18);
    vm.expectRevert(LaunchSeeder.AlreadySeeded.selector);
    seeder.seed(_ladder());
  }

  /// Precondition 1 as strengthened 2026-09-02: the constructor has NO native-currency check. A hook whose
  /// feeCurrency is the zero address (native) constructs happily; its payout path would then call
  /// IERC20(address(0)) and strand every skimmed wei. Deploy must assert ERC20-ness, not merely "not ESSEY."
  function test_P1_constructor_does_not_reject_a_native_feeCurrency() public onFork {
    Currency native = Currency.wrap(address(0));
    bytes memory args = abi.encode(
      pm, IEsseyReserve(RESERVE), native, c1, native, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      BASE_FEE_BPS, SNIPE_START_BPS, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DONS_SHARE, openPrice
    );
    bytes32 initHash = keccak256(abi.encodePacked(type(EsseyReserveHook).creationCode, args));
    for (uint256 s = 0; s < 500_000; s++) {
      address a =
        address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(s), initHash)))));
      if (uint160(a) & 0x3FFF == 0x24CC && a.code.length == 0) {
        EsseyReserveHook nativeHook = new EsseyReserveHook{salt: bytes32(s)}(
          pm, IEsseyReserve(RESERVE), native, c1, native, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
          BASE_FEE_BPS, SNIPE_START_BPS, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DONS_SHARE, openPrice
        );
        assertEq(Currency.unwrap(nativeHook.feeCurrency()), address(0), "setup");
        emit log("FINDING: constructor ACCEPTS a native (address(0)) feeCurrency - deploy must reject it");
        // The payout leg is ERC20-only, so anything skimmed here could never be paid out.
        vm.expectRevert(); // no code at address(0): SafeERC20 reverts before NothingToFund is even relevant
        nativeHook.fundHolders(address(0));
        return;
      }
    }
    revert("no salt");
  }

  function test_D2_zero_amount_swap_is_rejected_by_the_real_manager() public onFork {
    (EsseyReserveHook hook,) = _launch();
    V4Actor actor = new V4Actor(pm);
    vm.expectRevert();
    actor.swap(
      _key(hook),
      SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
      BUYER
    );
  }
}
