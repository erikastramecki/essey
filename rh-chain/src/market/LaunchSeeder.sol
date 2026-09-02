// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// LaunchSeeder — one-shot atomic init + single-sided seed for the hooked $ESSEY/USDG V4 pool. It closes
/// the anti-snipe HIGH's root cause — the live-but-empty pool window between a permissionless `initialize`
/// and a deferred seed — by initializing (or tolerating a pre-initialized pool) and minting the whole ESSEY
/// ask ladder in ONE call, so nothing can interleave between init and seed.
///
/// SEEDED SIDE = currency0 (ESSEY): every rung sits at/above the opening tick, owing ONLY currency0, no USDG
/// (Pool.modifyLiquidity :206-226). The FIRST rung starts AT the opening tick, so it contributes ACTIVE
/// liquidity at open (owing zero USDG since sqrtP == sqrtLower) — what lets the honest first buy pass the
/// hook's empty-pool guard.
/// LOCKED BY CONSTRUCTION: the LP owner is THIS contract (PoolManager.sol:164); no withdraw / modifyLiquidity(-)
/// / position-move / fee-collect path exists, so principal and its fees can never leave. recoverGriefedSeed()
/// is pre-seed only and moves this contract's own ERC20 balance — never a minted position.
/// SINGLE-SIDEDNESS IS SELF-ENFORCING: holding only ESSEY, a rung that straddled spot would owe USDG it
/// cannot pay and revert the whole seed — a wrong ladder cannot half-deploy.
contract LaunchSeeder is IUnlockCallback {
  using SafeERC20 for IERC20;
  using StateLibrary for IPoolManager;
  using BalanceDeltaLibrary for BalanceDelta;

  /// Liquidity is computed from (amount − MARGIN) so the pool's round-UP of the owed ESSEY can never exceed
  /// a rung's allotment. 1000 wei of ESSEY ≈ $2.8e-17.
  uint256 internal constant AMOUNT_MARGIN = 1e3;
  /// Post-seed ESSEY left in this contract above this reverts — catches gross mis-parameterization (wrong
  /// decimals / ticks) while tolerating margin + round-down dust. Any tolerated dust is locked here forever.
  uint256 internal constant MAX_LEFTOVER = 1e18;

  IPoolManager public immutable poolManager;
  IERC20 public immutable essey; // currency0 — the only asset this seeder ever supplies
  Currency public immutable currency0;
  Currency public immutable currency1;
  uint24 public immutable poolFee;
  int24 public immutable poolTickSpacing;
  IHooks public immutable hooks;
  uint160 public immutable expectedSqrtPriceX96;
  address public immutable seedCaller; // the founder key that may call seed(), once

  bool public seeded;

  struct Rung {
    int24 tickLower;
    int24 tickUpper;
    uint256 esseyAmount;
  }

  struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
  }

  Position[] public positions;

  event Initialized(uint160 sqrtPriceX96);
  event ToleratedPreInit(uint160 sqrtPriceX96);
  event RungMinted(uint256 indexed idx, int24 tickLower, int24 tickUpper, uint128 liquidity);
  event Seeded(uint256 esseyIn);
  event RecoveredUnseeded(uint256 essey);

  error ZeroAddress();
  error NotSeedCaller();
  error AlreadySeeded();
  error NoRungs();
  error NotPoolManager();
  error TickNotAligned();
  error TickOrder();
  error UsdgOwed(); // a rung straddled spot — ladder mis-parameterized; the whole seed reverts
  error PreInitWrongPrice(); // pool was pre-initialized at a price other than the pinned one (impossible via the hook)
  error LiquidityOverflow();
  error LeftoverTooLarge();
  error NoActiveLiquidity();
  error NotGriefed();
  error NothingToRecover();

  constructor(
    IPoolManager _poolManager,
    Currency _currency0,
    Currency _currency1,
    uint24 _poolFee,
    int24 _poolTickSpacing,
    IHooks _hooks,
    uint160 _expectedSqrtPriceX96
  ) {
    if (address(_poolManager) == address(0) || _expectedSqrtPriceX96 == 0) revert ZeroAddress();
    poolManager = _poolManager;
    currency0 = _currency0;
    currency1 = _currency1;
    essey = IERC20(Currency.unwrap(_currency0));
    poolFee = _poolFee;
    poolTickSpacing = _poolTickSpacing;
    hooks = _hooks;
    expectedSqrtPriceX96 = _expectedSqrtPriceX96;
    seedCaller = msg.sender;
  }

  function key() public view returns (PoolKey memory) {
    return PoolKey({currency0: currency0, currency1: currency1, fee: poolFee, tickSpacing: poolTickSpacing, hooks: hooks});
  }

  function poolId() public view returns (PoolId) {
    return PoolIdLibrary.toId(key());
  }

  function positionCount() external view returns (uint256) {
    return positions.length;
  }

  /// One-shot: initialize (or tolerate a pre-initialized pool) and mint the whole ESSEY ladder atomically.
  /// Founder pre-funds this contract with the seed ESSEY before calling. No USDG is ever required.
  /// @param rungs ascending, aligned ranges at/above the opening tick; ESSEY amounts in wei.
  function seed(Rung[] calldata rungs) external {
    if (msg.sender != seedCaller) revert NotSeedCaller();
    if (seeded) revert AlreadySeeded();
    if (rungs.length == 0) revert NoRungs();
    seeded = true;

    // Layer 3 — pre-init tolerance. A permissionless griefer can front-run ONLY the init leg, and only at
    // the pinned price (the hook's beforeInitialize rejects any other). Detect that and skip straight to
    // seeding rather than reverting on the already-initialized pool.
    (uint160 sqrtP,,,) = poolManager.getSlot0(poolId());
    if (sqrtP == 0) {
      poolManager.initialize(key(), expectedSqrtPriceX96);
      emit Initialized(expectedSqrtPriceX96);
    } else {
      if (sqrtP != expectedSqrtPriceX96) revert PreInitWrongPrice();
      emit ToleratedPreInit(sqrtP);
    }

    uint256 esseyIn = essey.balanceOf(address(this));
    uint128 liqBefore = poolManager.getLiquidity(poolId());
    poolManager.unlock(abi.encode(rungs));

    // A ladder entirely above spot mints fine and opens a pool nothing can trade (S-2). Measured as an
    // INCREASE, so a griefer's pre-existing rung at spot cannot stand in for the seed's own liquidity.
    if (poolManager.getLiquidity(poolId()) <= liqBefore) revert NoActiveLiquidity();
    if (essey.balanceOf(address(this)) > MAX_LEFTOVER) revert LeftoverTooLarge();
    emit Seeded(esseyIn);
  }

  /// Escape hatch for the one state where seed() can only ever revert PreInitWrongPrice: a pool live off the
  /// pinned price (A-3). The launch redeploys against a fresh hook, abandoning the griefed pool. The guards
  /// below close this in every state where seed() can still succeed, and it is terminal, so it never precedes one.
  function recoverGriefedSeed() external returns (uint256 amount) {
    if (msg.sender != seedCaller) revert NotSeedCaller();
    if (seeded) revert AlreadySeeded();
    (uint160 sqrtP,,,) = poolManager.getSlot0(poolId());
    if (sqrtP == 0 || sqrtP == expectedSqrtPriceX96) revert NotGriefed();
    amount = essey.balanceOf(address(this));
    if (amount == 0) revert NothingToRecover();

    seeded = true; // terminal: recovery and seeding are mutually exclusive, in either order
    essey.safeTransfer(seedCaller, amount);
    emit RecoveredUnseeded(amount);
  }

  function unlockCallback(bytes calldata data) external returns (bytes memory) {
    if (msg.sender != address(poolManager)) revert NotPoolManager();
    Rung[] memory rungs = abi.decode(data, (Rung[]));

    int24 s = poolTickSpacing;
    int256 owed0;
    for (uint256 i = 0; i < rungs.length; i++) {
      Rung memory r = rungs[i];
      if (r.tickUpper <= r.tickLower) revert TickOrder();
      if (r.tickLower % s != 0 || r.tickUpper % s != 0) revert TickNotAligned();

      uint160 sqrtLo = TickMath.getSqrtPriceAtTick(r.tickLower);
      uint160 sqrtHi = TickMath.getSqrtPriceAtTick(r.tickUpper);
      uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtLo, sqrtHi, r.esseyAmount - AMOUNT_MARGIN);
      if (liquidity == 0) revert LiquidityOverflow();

      (BalanceDelta delta,) = poolManager.modifyLiquidity(
        key(), ModifyLiquidityParams({tickLower: r.tickLower, tickUpper: r.tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)}), ""
      );
      // A single-sided ESSEY rung must owe ZERO USDG (currency1). If it owes any, the range straddled spot.
      if (delta.amount1() != 0) revert UsdgOwed();
      owed0 += delta.amount0();

      positions.push(Position({tickLower: r.tickLower, tickUpper: r.tickUpper, liquidity: liquidity}));
      emit RungMinted(i, r.tickLower, r.tickUpper, liquidity);
    }

    // Settle the ESSEY the ladder owes in one shot; USDG was proven zero above.
    if (owed0 < 0) {
      poolManager.sync(currency0);
      essey.safeTransfer(address(poolManager), uint256(-owed0));
      poolManager.settle();
    }
    return "";
  }
}
