// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IEsseyReserve {
  function fund(address token, uint256 amount) external;
}

/// EsseyReserveHook — money chokepoint for the $ESSEY/USDG V4 pool. Skims a 1% base fee split three ways
/// (reserve / holders / Dons) + a decaying launch anti-snipe surcharge (100% to reserve), always in the QUOTE
/// currency (never $ESSEY). Only the base-fee SPLIT is mutable: behind a governor with hard immutable rails, a
/// 48h timelock, and a one-way lock(). The governor touches the split ONLY — never the rate, sinks, or reserve.
contract EsseyReserveHook is IHooks, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using SafeCast for uint256;
  using StateLibrary for IPoolManager;
  using BalanceDeltaLibrary for BalanceDelta;

  uint256 public constant BPS = 10_000;

  // Hard immutable governor rails, enforced on every proposed split. FOUNDER-CONFIRMED 2026-09-02: every
  // bucket has a FLOOR, so no governor can zero holders or Dons and lock() that in. Floors sum to 7_000.
  // The two CEILINGS are not independently reachable: the reserve floor caps them JOINTLY at
  // holders + dons <= BPS - MIN_RESERVE_BPS == 6_000, so (5_000, 2_000) is rejected, not allowed.
  uint256 public constant MIN_RESERVE_BPS = 4_000;
  uint256 public constant MIN_HOLDERS_BPS = 2_500;
  uint256 public constant MAX_HOLDERS_BPS = 5_000;
  uint256 public constant MIN_DONS_BPS = 500;
  uint256 public constant MAX_DONS_BPS = 2_000;
  uint256 public constant SPLIT_TIMELOCK = 48 hours; // propose -> execute delay; long enough for holders to react

  IPoolManager public immutable poolManager;
  IEsseyReserve public immutable reserve;
  Currency public immutable currency0;
  Currency public immutable currency1;
  uint24 public immutable poolFee;
  int24 public immutable poolTickSpacing;
  address public immutable donsSink;
  address public immutable holdersSink; // the HolderDistributor the holder-airdrop bucket routes to

  /// keccak of this hook's own PoolKey — the empty-pool guard reads active liquidity against it.
  bytes32 public immutable poolIdRaw;

  /// The one price initialize may open this pool at. beforeInitialize is permissionless and one-shot, so
  /// without this an attacker could race the founder's initialize and lock the pool at a chosen price.
  uint160 public immutable expectedSqrtPriceX96;

  /// The one currency every skim is denominated in (USDG). Must be currency0 or currency1 of the pool.
  Currency public immutable feeCurrency;
  bool public immutable feeIsCurrency1;

  uint256 public immutable baseFeeBps; // steady-state fee, e.g. 100 = 1%
  uint256 public immutable snipeStartBps; // surcharge at launch, e.g. 9800 = 98%
  uint256 public immutable snipeSeconds; // linear decay window

  /// base + full surcharge. Enforced STRICTLY < BPS (not <=): the buy path skims the quote out of the swap
  /// INPUT in beforeSwap, so a 100% fee would zero the swapped amount and revert in the manager — defeating
  /// "a block-0 snipe funds the peg". Strict < BPS keeps every swap executable and every skim funding.
  uint256 public immutable maxTotalFeeBps;

  // ---- base-fee split: STORAGE behind the governor (rails + timelock + one-way lock) ----
  uint256 public reserveShareBps;
  uint256 public holdersShareBps;
  uint256 public donsShareBps;

  address public governor;
  bool public splitLocked;
  uint256 public pendingReserveBps;
  uint256 public pendingHoldersBps;
  uint256 public pendingDonsBps;
  uint256 public pendingEffectiveTime; // 0 = no pending change

  uint256 public launchTime; // 0 = not yet seeded; stamped in afterAddLiquidity on the first ESSEY-supplying
  // liquidity-add — the atomic seed — so decay begins at the founder's seed, not at a sniper's cheap first swap.

  mapping(address => uint256) public reserveEscrow;
  mapping(address => uint256) public holdersEscrow;
  mapping(address => uint256) public donsEscrow;

  event Skimmed(address indexed token, uint256 baseFee, uint256 surcharge, uint256 feeBps);
  event ReserveFunded(address indexed token, uint256 amount);
  event HoldersFunded(address indexed token, uint256 amount);
  event DonsFunded(address indexed token, uint256 amount);
  event SplitProposed(uint256 reserveBps, uint256 holdersBps, uint256 donsBps, uint256 effectiveTime);
  event SplitExecuted(uint256 reserveBps, uint256 holdersBps, uint256 donsBps);
  event SplitFrozen();

  error NotPoolManager();
  error WrongPoolKey();
  error WrongOpeningPrice();
  error BadConfig();
  error NothingToFund();
  error EmptyPool();
  error NotGovernor();
  error SplitFrozenError();
  error BadSplit();
  error NothingPending();
  error TimelockPending();
  error PartialFill();

  constructor(
    IPoolManager _poolManager,
    IEsseyReserve _reserve,
    Currency _currency0,
    Currency _currency1,
    Currency _feeCurrency,
    uint24 _poolFee,
    int24 _poolTickSpacing,
    address _donsSink,
    address _holdersSink,
    address _governor,
    uint256 _baseFeeBps,
    uint256 _snipeStartBps,
    uint256 _snipeSeconds,
    uint256 _reserveShareBps,
    uint256 _holdersShareBps,
    uint256 _donsShareBps,
    uint160 _expectedSqrtPriceX96
  ) {
    if (
      address(_poolManager) == address(0) || address(_reserve) == address(0) || _donsSink == address(0)
        || _holdersSink == address(0) || _governor == address(0)
    ) revert BadConfig();
    if (Currency.unwrap(_currency0) >= Currency.unwrap(_currency1)) revert BadConfig();
    bool feeIs1 = Currency.unwrap(_feeCurrency) == Currency.unwrap(_currency1);
    if (!feeIs1 && Currency.unwrap(_feeCurrency) != Currency.unwrap(_currency0)) revert BadConfig();
    if (_snipeSeconds == 0) revert BadConfig();
    if (!_splitWithinRails(_reserveShareBps, _holdersShareBps, _donsShareBps)) revert BadConfig();
    if (_expectedSqrtPriceX96 == 0) revert BadConfig();
    uint256 cap = _baseFeeBps + _snipeStartBps;
    if (cap == 0 || cap >= BPS) revert BadConfig();

    poolManager = _poolManager;
    reserve = _reserve;
    currency0 = _currency0;
    currency1 = _currency1;
    feeCurrency = _feeCurrency;
    feeIsCurrency1 = feeIs1;
    poolFee = _poolFee;
    poolTickSpacing = _poolTickSpacing;
    donsSink = _donsSink;
    holdersSink = _holdersSink;
    baseFeeBps = _baseFeeBps;
    snipeStartBps = _snipeStartBps;
    snipeSeconds = _snipeSeconds;
    expectedSqrtPriceX96 = _expectedSqrtPriceX96;
    maxTotalFeeBps = cap;
    poolIdRaw = _ownPoolId(_currency0, _currency1, _poolFee, _poolTickSpacing);

    // Storage (not immutable) writes live in a helper to keep the constructor's immutable-assignment stack
    // shallow enough for via_ir (stack-too-deep otherwise).
    _initGovernedSplit(_governor, _reserveShareBps, _holdersShareBps, _donsShareBps);

    Hooks.validateHookPermissions(this, getHookPermissions());
  }

  function _initGovernedSplit(address _governor, uint256 res, uint256 holders, uint256 dons) internal {
    governor = _governor;
    reserveShareBps = res;
    holdersShareBps = holders;
    donsShareBps = dons;
  }

  /// keccak of this hook's own PoolKey. Extracted from the constructor to keep its stack shallow (via_ir).
  function _ownPoolId(Currency a, Currency b, uint24 f, int24 ts) internal view returns (bytes32) {
    return PoolId.unwrap(
      PoolIdLibrary.toId(PoolKey({currency0: a, currency1: b, fee: f, tickSpacing: ts, hooks: IHooks(address(this))}))
    );
  }

  // ------------------------------------------------------------------ hook permissions

  function getHookPermissions() public pure returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
      beforeInitialize: true,
      afterInitialize: false,
      beforeAddLiquidity: false,
      afterAddLiquidity: true,
      beforeRemoveLiquidity: false,
      afterRemoveLiquidity: false,
      beforeSwap: true,
      afterSwap: true,
      beforeDonate: false,
      afterDonate: false,
      beforeSwapReturnDelta: true,
      afterSwapReturnDelta: true,
      afterAddLiquidityReturnDelta: false,
      afterRemoveLiquidityReturnDelta: false
    });
  }

  // ------------------------------------------------------------------ fee schedule (pure, no admin)

  /// Linear decay: full at launch, exactly 0 at and after snipeSeconds. Monotonically non-increasing.
  function surchargeBpsAt(uint256 ts) public view returns (uint256) {
    uint256 t0 = launchTime;
    if (t0 == 0 || ts <= t0) return snipeStartBps;
    uint256 elapsed = ts - t0;
    if (elapsed >= snipeSeconds) return 0;
    return (snipeStartBps * (snipeSeconds - elapsed)) / snipeSeconds;
  }

  function feeBpsAt(uint256 ts) public view returns (uint256) {
    return baseFeeBps + surchargeBpsAt(ts);
  }

  // ------------------------------------------------------------------ beforeInitialize: pin the pool config

  /// Pins the pool key to this hook's immutable config and the founder-set opening price. Deliberately does NOT
  /// stamp the anti-snipe clock (that fires at the atomic seed); PoolManager already blocks re-initialization.
  function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) external view returns (bytes4) {
    if (msg.sender != address(poolManager)) revert NotPoolManager();
    if (
      Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
        || Currency.unwrap(key.currency1) != Currency.unwrap(currency1) || key.fee != poolFee
        || key.tickSpacing != poolTickSpacing || address(key.hooks) != address(this)
    ) revert WrongPoolKey();
    // Permissionless one-shot initialize: reject any opening price but the founder-set one, closing the
    // front-run that would otherwise lock the pool at an attacker's price. Same price is harmless (clock
    // is lazy, so no decay starts here).
    if (sqrtPriceX96 != expectedSqrtPriceX96) revert WrongOpeningPrice();
    return IHooks.beforeInitialize.selector;
  }

  // ------------------------------------------------------------------ swap skim (always in feeCurrency)

  /// The quote is the SPECIFIED leg exactly when feeIsCurrency1 == (currency1 is specified). currency1 is the
  /// specified leg iff (amountSpecified<0) != zeroForOne (v4-core Hooks.afterSwap delta ordering).
  function _feeIsSpecified(SwapParams calldata p) internal view returns (bool) {
    bool specifiedIsCurrency1 = (p.amountSpecified < 0) != p.zeroForOne;
    return feeIsCurrency1 == specifiedIsCurrency1;
  }

  /// When the quote is the specified leg, take the fee here: a positive specified delta makes v4-core reduce
  /// the swapped amount by exactly `fee` of the quote and credit the hook the same amount. Otherwise afterSwap
  /// charges the unspecified leg, and this returns a zero delta.
  function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
    external
    returns (bytes4, BeforeSwapDelta, uint24)
  {
    if (msg.sender != address(poolManager)) revert NotPoolManager();
    // Empty-pool guard, PRE-SEED ONLY: a zero-liquidity swap nets (0,0) while walking price to the caller's
    // limit, which before the seed moves the pool off its pinned opening price for free. It must not stay
    // armed after (A-1): a seeded pool legitimately empties at either end of the ladder, and an armed guard
    // would block the healing trade forever.
    if (launchTime == 0 && poolManager.getLiquidity(PoolId.wrap(poolIdRaw)) == 0) revert EmptyPool();
    if (!_feeIsSpecified(params)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    uint256 fee = _feeOnSpecified(params);
    if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
  }

  /// Realize the skim in `feeCurrency` and accrue it. `take` pulls `fee` and the v4-core credit nets the hook's
  /// manager delta to zero — the caller pays. A specified-leg skim already returned its delta in beforeSwap, so
  /// return 0 here to avoid double-charging.
  function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
    external
    returns (bytes4, int128)
  {
    if (msg.sender != address(poolManager)) revert NotPoolManager();

    bool feeSpecified = _feeIsSpecified(params);
    uint256 amount = feeSpecified ? _absSpecified(params) : _absFeeLeg(delta);
    (uint256 baseFee, uint256 surcharge, uint256 fee) = _feeParts(amount, params.amountSpecified < 0);
    if (fee == 0) return (IHooks.afterSwap.selector, int128(0));

    // beforeSwap must commit the specified-leg credit on the amount REQUESTED, and v4-core returns whatever the
    // pool could not consume (Pool.sol :456-462) — so a short fill billed the unfilled notional at 100%. No
    // refund is reachable from here: afterSwap's return delta is the UNSPECIFIED currency, and take()ing the
    // surplus to `sender` pays the router, where it is anyone's to sweep. The leg must fill whole instead.
    if (feeSpecified && !_filledWhole(params, delta, fee)) revert PartialFill();

    address token = Currency.unwrap(feeCurrency);
    poolManager.take(feeCurrency, address(this), fee);

    // Split the BASE fee three ways; the RESERVE holds the rounding remainder so the parts sum EXACTLY to
    // baseFee AND a 0% share accrues EXACTLY 0. The whole surcharge goes to the reserve.
    uint256 donPart = (baseFee * donsShareBps) / BPS;
    uint256 holdersPart = (baseFee * holdersShareBps) / BPS;
    uint256 resPart = baseFee - donPart - holdersPart;
    reserveEscrow[token] += resPart + surcharge;
    holdersEscrow[token] += holdersPart;
    donsEscrow[token] += donPart;

    emit Skimmed(token, baseFee, surcharge, baseFeeBps + surchargeBpsAt(block.timestamp));
    return (IHooks.afterSwap.selector, feeSpecified ? int128(0) : fee.toInt128());
  }

  // ------------------------------------------------------------------ anti-snipe clock: stamp at atomic seed

  /// Stamp launchTime at the ATOMIC SEED — the first liquidity-add that SUPPLIES ESSEY (currency0 owed, i.e.
  /// delta.amount0() < 0). ESSEY is non-circulating until the founder's one-shot seed, so no earlier add can
  /// carry it. Decay therefore begins at the seed, an instant a sniper can neither pre-start nor cheaply reset.
  /// Returns a zero hook delta (afterAddLiquidityReturnDelta is off), so the seed's settlement is never disturbed.
  function afterAddLiquidity(
    address,
    PoolKey calldata,
    ModifyLiquidityParams calldata,
    BalanceDelta delta,
    BalanceDelta,
    bytes calldata
  ) external returns (bytes4, BalanceDelta) {
    if (msg.sender != address(poolManager)) revert NotPoolManager();
    if (launchTime == 0 && delta.amount0() < 0) launchTime = block.timestamp;
    return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
  }

  // ------------------------------------------------------------------ fee math

  /// The fee is the same share of the GROSS quote on all four swap shapes. exactIn hands us that gross (the
  /// buyer's whole input, or the pool's whole output on a sell); exactOut hands us the NET and must be grossed
  /// up, or the identical trade costs less for being routed exactOut — ~50x less at the launch surcharge.
  /// maxTotalFeeBps < BPS (constructor) keeps the denominator non-zero.
  function _feeParts(uint256 amount, bool exactIn)
    internal
    view
    returns (uint256 baseFee, uint256 surcharge, uint256 fee)
  {
    uint256 sur = surchargeBpsAt(block.timestamp);
    uint256 denom = exactIn ? BPS : BPS - baseFeeBps - sur;
    baseFee = (amount * baseFeeBps) / denom;
    surcharge = (amount * sur) / denom;
    fee = baseFee + surcharge;
  }

  function _feeOnSpecified(SwapParams calldata p) internal view returns (uint256 fee) {
    (,, fee) = _feeParts(_absSpecified(p), p.amountSpecified < 0);
  }

  function _absSpecified(SwapParams calldata p) internal pure returns (uint256) {
    return p.amountSpecified < 0 ? uint256(-p.amountSpecified) : uint256(p.amountSpecified);
  }

  /// v4 ran the pool on `amountSpecified + fee` — the amount left after the beforeSwap credit — so a complete
  /// fill returns exactly that on the specified leg. Equivalent to Pool.sol's amountSpecifiedRemaining == 0.
  function _filledWhole(SwapParams calldata p, BalanceDelta delta, uint256 fee) internal view returns (bool) {
    return _feeLegDelta(delta) == p.amountSpecified + int256(fee);
  }

  function _feeLegDelta(BalanceDelta delta) internal view returns (int256) {
    return feeIsCurrency1 ? int256(delta.amount1()) : int256(delta.amount0());
  }

  function _absFeeLeg(BalanceDelta delta) internal view returns (uint256) {
    int256 leg = _feeLegDelta(delta);
    return leg < 0 ? uint256(-leg) : uint256(leg);
  }

  // ------------------------------------------------------------------ permissionless payouts (fixed sinks)

  function fundReserve(address token) external nonReentrant returns (uint256 amount) {
    amount = reserveEscrow[token];
    if (amount == 0) revert NothingToFund();
    reserveEscrow[token] = 0;
    IERC20(token).forceApprove(address(reserve), amount);
    reserve.fund(token, amount);
    emit ReserveFunded(token, amount);
  }

  function fundHolders(address token) external nonReentrant returns (uint256 amount) {
    amount = holdersEscrow[token];
    if (amount == 0) revert NothingToFund();
    holdersEscrow[token] = 0;
    IERC20(token).safeTransfer(holdersSink, amount);
    emit HoldersFunded(token, amount);
  }

  function fundDons(address token) external nonReentrant returns (uint256 amount) {
    amount = donsEscrow[token];
    if (amount == 0) revert NothingToFund();
    donsEscrow[token] = 0;
    IERC20(token).safeTransfer(donsSink, amount);
    emit DonsFunded(token, amount);
  }

  // ------------------------------------------------------------------ split governor (split-only, bounded)

  /// True iff the three base-fee shares sum to BPS and sit inside the hard rails. Reserve has no ceiling: the
  /// other two floors imply one (BPS - MIN_HOLDERS_BPS - MIN_DONS_BPS).
  function _splitWithinRails(uint256 res, uint256 holders, uint256 dons) internal pure returns (bool) {
    if (res + holders + dons != BPS) return false;
    if (res < MIN_RESERVE_BPS) return false;
    if (holders < MIN_HOLDERS_BPS || holders > MAX_HOLDERS_BPS) return false;
    if (dons < MIN_DONS_BPS || dons > MAX_DONS_BPS) return false;
    return true;
  }

  modifier onlyGovernor() {
    if (msg.sender != governor) revert NotGovernor();
    _;
  }

  /// Queue a new base-fee split. Applies only after SPLIT_TIMELOCK via executeSplit — never immediately.
  function proposeSplit(uint256 res, uint256 holders, uint256 dons) external onlyGovernor {
    if (splitLocked) revert SplitFrozenError();
    if (!_splitWithinRails(res, holders, dons)) revert BadSplit();
    pendingReserveBps = res;
    pendingHoldersBps = holders;
    pendingDonsBps = dons;
    pendingEffectiveTime = block.timestamp + SPLIT_TIMELOCK;
    emit SplitProposed(res, holders, dons, pendingEffectiveTime);
  }

  /// Permissionless: apply the pending split once its timelock has elapsed.
  function executeSplit() external {
    if (splitLocked) revert SplitFrozenError();
    uint256 eff = pendingEffectiveTime;
    if (eff == 0) revert NothingPending();
    if (block.timestamp < eff) revert TimelockPending();
    reserveShareBps = pendingReserveBps;
    holdersShareBps = pendingHoldersBps;
    donsShareBps = pendingDonsBps;
    pendingEffectiveTime = 0;
    emit SplitExecuted(reserveShareBps, holdersShareBps, donsShareBps);
  }

  /// One-way, irreversible: freeze the current split and renounce the governor forever. Progressive
  /// decentralization — adjustable during bootstrap, then truly immutable whenever the founder chooses.
  function lock() external onlyGovernor {
    if (splitLocked) revert SplitFrozenError();
    splitLocked = true;
    governor = address(0);
    pendingEffectiveTime = 0; // cancel any queued change
    emit SplitFrozen();
  }

  // ------------------------------------------------------------------ unused hook surface (flags are off)

  function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
    revert HookNotImplemented();
  }

  function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    revert HookNotImplemented();
  }

  function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
    external
    pure
    returns (bytes4)
  {
    revert HookNotImplemented();
  }

  function afterRemoveLiquidity(
    address,
    PoolKey calldata,
    ModifyLiquidityParams calldata,
    BalanceDelta,
    BalanceDelta,
    bytes calldata
  ) external pure returns (bytes4, BalanceDelta) {
    revert HookNotImplemented();
  }

  function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
    revert HookNotImplemented();
  }

  function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
    revert HookNotImplemented();
  }

  error HookNotImplemented();
}
