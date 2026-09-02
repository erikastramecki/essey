// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {EsseyReserveHook, IEsseyReserve} from "../src/market/EsseyReserveHook.sol";
import {EsseyReserve} from "../src/market/EsseyReserve.sol";
import {LaunchSeeder} from "../src/market/LaunchSeeder.sol";

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

/// MockV4Manager — a faithful minimal stand-in for v4-core's PoolManager, built because the vendored
/// PoolManager's solmate dependency is not checked out offline. It reproduces EXACTLY the three-branch
/// modifyLiquidity semantics of Pool.sol:206-236 (owed token + active-liquidity update by position vs.
/// current tick), the unlock/sync/settle currency-delta settlement, and the StateLibrary `extsload` slot
/// layout (slot0 packing + LIQUIDITY_OFFSET 3) the hook's guard and the seeder/POL reads depend on. Only
/// the surface those contracts touch is implemented; `probeSwap` drives just beforeSwap for the guard tests.
contract MockV4Manager {
  using StateLibrary for IPoolManager;

  bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

  address public token0;
  address public token1;
  IHooks public hook;
  bool public inited;
  uint160 public sqrtPriceX96;
  int24 public tick;
  uint128 public activeLiquidity;
  bytes32 public poolIdRaw;

  address internal unlocker;
  address internal syncedToken;
  uint256 internal syncedReserves;
  mapping(address => int256) internal currencyDelta;
  mapping(bytes32 => uint128) public positionLiquidityOf;

  error Locked();
  error NotUnlocked();
  error Unsettled();

  function initialize(PoolKey calldata k, uint160 price) external returns (int24) {
    require(!inited, "inited");
    hook = k.hooks;
    token0 = Currency.unwrap(k.currency0);
    token1 = Currency.unwrap(k.currency1);
    poolIdRaw = PoolId.unwrap(PoolIdLibrary.toId(k));
    // Drive the hook's beforeInitialize exactly as v4 does: the hook sees msg.sender == this manager.
    hook.beforeInitialize(msg.sender, k, price);
    sqrtPriceX96 = price;
    tick = TickMath.getTickAtSqrtPrice(price);
    inited = true;
    return tick;
  }

  function unlock(bytes calldata data) external returns (bytes memory result) {
    if (unlocker != address(0)) revert Locked();
    unlocker = msg.sender;
    result = IUnlockCallback(msg.sender).unlockCallback(data);
    if (currencyDelta[token0] != 0 || currencyDelta[token1] != 0) revert Unsettled();
    unlocker = address(0);
  }

  function modifyLiquidity(PoolKey calldata k, ModifyLiquidityParams calldata p, bytes calldata)
    external
    returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
  {
    if (msg.sender != unlocker) revert NotUnlocked();
    uint128 L = uint128(uint256(p.liquidityDelta)); // only adds are used
    uint160 sqrtLo = TickMath.getSqrtPriceAtTick(p.tickLower);
    uint160 sqrtHi = TickMath.getSqrtPriceAtTick(p.tickUpper);

    uint256 owed0;
    uint256 owed1;
    if (tick < p.tickLower) {
      owed0 = SqrtPriceMath.getAmount0Delta(sqrtLo, sqrtHi, L, true); // range above spot: currency0 only
    } else if (tick < p.tickUpper) {
      owed0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtHi, L, true); // straddles spot: both...
      owed1 = SqrtPriceMath.getAmount1Delta(sqrtLo, sqrtPriceX96, L, true); // ...but currency1 owed = 0 when sqrtP == sqrtLo
      activeLiquidity += L; // only a straddling position counts toward active liquidity
    } else {
      owed1 = SqrtPriceMath.getAmount1Delta(sqrtLo, sqrtHi, L, true); // range below spot: currency1 only
    }

    int128 a0 = -int128(int256(owed0));
    int128 a1 = -int128(int256(owed1));
    currencyDelta[token0] += a0;
    currencyDelta[token1] += a1;
    positionLiquidityOf[keccak256(abi.encodePacked(msg.sender, p.tickLower, p.tickUpper))] += L;

    callerDelta = toBalanceDelta(a0, a1);
    feesAccrued = toBalanceDelta(int128(0), int128(0));

    // Faithful to v4: an add on a hook carrying AFTER_ADD_LIQUIDITY_FLAG (1<<10) invokes afterAddLiquidity
    // with the principal callerDelta. The hook has afterAddLiquidityReturnDelta off, so its zero return never
    // alters this settlement — the anti-snipe stamp is the only side effect.
    if (uint160(address(hook)) & 0x400 != 0) {
      hook.afterAddLiquidity(msg.sender, k, p, callerDelta, feesAccrued, "");
    }
  }

  function sync(Currency c) external {
    syncedToken = Currency.unwrap(c);
    syncedReserves = IERC20(syncedToken).balanceOf(address(this));
  }

  function settle() external payable returns (uint256 paid) {
    paid = IERC20(syncedToken).balanceOf(address(this)) - syncedReserves;
    currencyDelta[syncedToken] += int256(paid);
  }

  function take(Currency c, address to, uint256 amount) external {
    address t = Currency.unwrap(c);
    currencyDelta[t] -= int256(amount);
    IERC20(t).transfer(to, amount);
  }

  /// StateLibrary read surface: serve the packed slot0 and the active-liquidity slot the hook guard reads.
  function extsload(bytes32 slot) external view returns (bytes32) {
    bytes32 stateSlot = keccak256(abi.encodePacked(poolIdRaw, POOLS_SLOT));
    if (slot == stateSlot) {
      return bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160));
    }
    if (slot == bytes32(uint256(stateSlot) + 3)) {
      return bytes32(uint256(activeLiquidity));
    }
    return bytes32(0);
  }

  /// Drives ONLY the hook's beforeSwap — NOT a swap. This mock has no v4 swap loop, so nothing here can
  /// observe liquidity going to zero MID-swap; that class of assertion lives on the real manager in
  /// test/EsseyHookRealSwapSeedFork.t.sol (audit A-6). Named for what it does so no future reader counts it
  /// as swap coverage.
  function probeBeforeSwap(PoolKey calldata k, SwapParams calldata p) external {
    hook.beforeSwap(msg.sender, k, p, "");
  }

  /// Model the two post-seed pool states the REAL manager reaches on a fork (proven there): a ladder walked
  /// out of range leaves zero active liquidity, and a free walk moves price off the pinned peg.
  function setActiveLiquidity(uint128 v) external {
    activeLiquidity = v;
  }

  function setSqrtPrice(uint160 v) external {
    sqrtPriceX96 = v;
    tick = TickMath.getTickAtSqrtPrice(v);
  }
}

contract EsseyReserveHookLaunchSeedTest is Test {
  using StateLibrary for IPoolManager;

  uint256 constant BPS = 10_000;
  uint256 constant BASE = 100;
  uint256 constant SNIPE_START = 9_800;
  uint256 constant SNIPE_SECONDS = 45;
  uint256 constant RES_SHARE = 4_500;
  uint256 constant HOLDERS_SHARE = 4_000;
  uint256 constant DON_SHARE = 1_500;
  uint24 constant POOL_FEE = 3000;
  int24 constant TICK_SPACING = 60;
  int24 constant OPEN_TICK = 0;
  uint160 constant OPEN_PRICE = uint160(1 << 96); // sqrtP at tick 0

  address constant DONS = address(0xD0);
  address constant HOLDERS = address(0x40);
  address constant GOV = address(0x60);

  MockV4Manager manager;
  MockEssey essey; // currency0
  MockUSDG usdg; // currency1
  EsseyReserve reserve;
  EsseyReserveHook hook;

  Currency c0;
  Currency c1;
  PoolKey key;

  function setUp() public {
    manager = new MockV4Manager();
    essey = new MockEssey(8_888_888_888e18);
    usdg = new MockUSDG();
    reserve = new EsseyReserve(IERC20(address(essey)));
    while (address(essey) >= address(usdg)) {
      essey = new MockEssey(8_888_888_888e18);
      reserve = new EsseyReserve(IERC20(address(essey)));
    }
    c0 = Currency.wrap(address(essey));
    c1 = Currency.wrap(address(usdg));

    hook = _mineHook();
    key = PoolKey({currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});
  }

  function _mineHook() internal returns (EsseyReserveHook) {
    bytes memory args = abi.encode(
      IPoolManager(address(manager)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
      BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
    );
    bytes32 initHash = keccak256(abi.encodePacked(type(EsseyReserveHook).creationCode, args));
    for (uint256 s = 0; s < 500_000; s++) {
      address addr = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(s), initHash)))));
      if (uint160(addr) & 0x3FFF == 0x24CC && addr.code.length == 0) {
        return new EsseyReserveHook{salt: bytes32(s)}(
          IPoolManager(address(manager)), IEsseyReserve(address(reserve)), c0, c1, c1, POOL_FEE, TICK_SPACING, DONS, HOLDERS, GOV,
          BASE, SNIPE_START, SNIPE_SECONDS, RES_SHARE, HOLDERS_SHARE, DON_SHARE, OPEN_PRICE
        );
      }
    }
    revert("no salt");
  }

  function _id() internal view returns (PoolId) {
    return PoolId.wrap(hook.poolIdRaw());
  }

  function _liq() internal view returns (uint128) {
    return IPoolManager(address(manager)).getLiquidity(_id());
  }

  function _deploySeeder() internal returns (LaunchSeeder) {
    return new LaunchSeeder(IPoolManager(address(manager)), c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(hook)), OPEN_PRICE);
  }

  /// Three ascending single-sided rungs; the FIRST starts AT the opening tick so it contributes active
  /// liquidity at open (the honest first buy's precondition under the guard).
  function _ladder(int24 firstLower) internal pure returns (LaunchSeeder.Rung[] memory rungs) {
    rungs = new LaunchSeeder.Rung[](3);
    rungs[0] = LaunchSeeder.Rung({tickLower: firstLower, tickUpper: 600, esseyAmount: 100e18});
    rungs[1] = LaunchSeeder.Rung({tickLower: 600, tickUpper: 1200, esseyAmount: 100e18});
    rungs[2] = LaunchSeeder.Rung({tickLower: 1200, tickUpper: 1800, esseyAmount: 100e18});
  }

  function _probeDustSwap() internal {
    SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e12, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
    manager.probeBeforeSwap(key, p);
  }

  // ================================================================= Layer 2: empty pool is un-swappable

  function test_guarded_empty_pool_swap_reverts() public {
    manager.initialize(key, OPEN_PRICE); // permissionless init, no seed
    assertEq(_liq(), 0, "pool not empty");
    assertEq(hook.launchTime(), 0, "clock stamped at init");

    vm.expectRevert(EsseyReserveHook.EmptyPool.selector);
    _probeDustSwap();

    assertEq(hook.launchTime(), 0, "empty-pool swap stamped the clock");
  }

  // ================================================================= Layer 1: atomic init + seed

  function test_atomic_seed_produces_active_liquidity_at_open() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    seeder.seed(_ladder(OPEN_TICK));

    assertEq(seeder.positionCount(), 3, "ladder not fully seeded");
    assertGt(_liq(), 0, "no active liquidity at open tick");
    // The seeded LP is owned by the seeder (locked by construction); the first rung straddles the open tick.
    bytes32 posKey = keccak256(abi.encodePacked(address(seeder), OPEN_TICK, int24(600)));
    assertGt(manager.positionLiquidityOf(posKey), 0, "seeder does not own the first rung");

    // The seed itself stamps the anti-snipe clock (afterAddLiquidity on the first ESSEY-supplying rung), so
    // decay begins at the seed — not at a later swap. With active liquidity at open, the guard also passes.
    assertEq(hook.launchTime(), block.timestamp, "seed did not stamp the clock");
  }

  // ================================================================= Layer 3: pre-init tolerated (anti-DoS)

  function test_seeder_tolerates_preinitialized_pool() public {
    manager.initialize(key, OPEN_PRICE); // griefer front-runs ONLY the init leg (pinned price)
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    seeder.seed(_ladder(OPEN_TICK)); // must NOT revert on the already-initialized pool
    assertTrue(seeder.seeded(), "seed did not complete over a pre-initialized pool");
    assertGt(_liq(), 0, "ladder not seeded after pre-init");
  }

  // ================================================================= Test D: seeder has no principal exit

  function test_seeder_no_principal_exit_path() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    seeder.seed(_ladder(OPEN_TICK));

    // seed() is one-shot; unlockCallback is manager-authenticated. There is NO withdraw / removeLiquidity path.
    vm.expectRevert(LaunchSeeder.AlreadySeeded.selector);
    seeder.seed(_ladder(OPEN_TICK));
    vm.expectRevert(LaunchSeeder.NotPoolManager.selector);
    seeder.unlockCallback("");
    assertLe(essey.balanceOf(address(seeder)), 1e18, "unexpected large leftover"); // any dust is locked forever
  }

  /// Test G, part 2 (the load-bearing dependency): a first rung ABOVE the open tick leaves ZERO active
  /// liquidity at open. seed() now refuses that whole ladder rather than opening a pool nothing can trade
  /// (audit S-2), and the one shot is not spent. RED against dropping the post-condition — the seed would
  /// complete and lock the ESSEY in a dead pool.
  function test_first_rung_above_open_is_refused() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);

    vm.expectRevert(LaunchSeeder.NoActiveLiquidity.selector);
    seeder.seed(_ladder(60)); // first rung [60,600] — strictly above the open tick 0

    assertFalse(seeder.seeded(), "the refused seed burned the one shot");
    assertEq(essey.balanceOf(address(seeder)), 300e18, "ESSEY left the seeder on a refused seed");
    seeder.seed(_ladder(OPEN_TICK)); // the corrected ladder still opens the pool
    assertGt(_liq(), 0, "corrected ladder did not open the pool");
  }

  /// The post-condition measures the seed's OWN contribution: a griefer's active rung sitting at spot before
  /// the seed must not stand in for a ladder that opens nothing. RED against checking `getLiquidity() != 0`
  /// instead of an increase — the weaker form passes here on the griefer's liquidity alone.
  function test_griefer_liquidity_cannot_mask_a_dead_ladder() public {
    manager.initialize(key, OPEN_PRICE);
    manager.setActiveLiquidity(1e18); // a griefer's dust rung, active at spot
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);

    vm.expectRevert(LaunchSeeder.NoActiveLiquidity.selector);
    seeder.seed(_ladder(60)); // ladder entirely above spot — contributes nothing active
    assertFalse(seeder.seeded(), "the refused seed burned the one shot");
  }

  /// The other arm of the same guard, at the mock's level: once the seed has stamped the clock, a pool that
  /// LATER reads zero active liquidity is swappable again. RED against dropping `launchTime == 0 &&` from the
  /// hook's empty-pool guard (audit A-1). The mid-swap version of this — liquidity hitting zero inside the v4
  /// swap loop — is only observable on the real manager; see EsseyHookRealSwapSeedFork.t.sol.
  function test_empty_pool_guard_disarms_after_the_seed() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    seeder.seed(_ladder(OPEN_TICK));
    assertGt(hook.launchTime(), 0, "seed did not stamp the clock");

    manager.setActiveLiquidity(0);
    assertEq(_liq(), 0, "liquidity not zeroed");
    _probeDustSwap(); // must NOT revert: the healing trade has to be able to run
  }

  // ================================================================= HIGH: clock stamped at the atomic seed

  /// The stamp exists and lands at the SEED moment. RED if the afterAddLiquidity stamp is removed (launchTime
  /// stays 0) or moved back to the first swap (a seed-without-swap would then read 0).
  function test_seed_stamps_launchTime_at_seed_moment() public {
    uint256 t = 1_000_000;
    vm.warp(t);
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    seeder.seed(_ladder(OPEN_TICK));
    assertEq(hook.launchTime(), t, "clock not stamped at the seed moment");
  }

  /// A post-seed dust swap CANNOT set, move, or reset the clock. RED if any unconditional
  /// `launchTime = block.timestamp` is (re)introduced into the swap path — the exact HIGH.
  function test_dust_swap_after_seed_cannot_move_the_clock() public {
    uint256 t = 1_000_000;
    vm.warp(t);
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    seeder.seed(_ladder(OPEN_TICK));
    assertEq(hook.launchTime(), t, "seed did not stamp");

    vm.warp(t + 10);
    _probeDustSwap(); // sniper dust swap, well after the seed
    assertEq(hook.launchTime(), t, "a dust swap moved the anti-snipe clock");
  }

  /// The surcharge schedule is anchored at the seed and a sniper's dust-then-wait gains ZERO edge: the clock
  /// they face is identical before and after their dust swap, and the decay window runs from the founder's
  /// seed — which they cannot advance. RED if a dust swap could (re)anchor the clock to the sniper's action.
  function test_surcharge_anchored_at_seed_zero_sniper_edge() public {
    uint256 t = 1_000_000;
    vm.warp(t);
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    seeder.seed(_ladder(OPEN_TICK));

    assertEq(hook.surchargeBpsAt(t), SNIPE_START, "surcharge not full at the seed");
    uint256 mid = SNIPE_SECONDS / 3;
    uint256 schedBefore = hook.surchargeBpsAt(t + mid);

    vm.warp(t + mid);
    _probeDustSwap(); // sniper tries to (re)start the clock cheaply
    assertEq(hook.launchTime(), t, "dust swap re-anchored the clock");
    assertEq(hook.surchargeBpsAt(t + mid), schedBefore, "dust swap changed the surcharge schedule");

    // The full window is measured from the SEED (t), not the dust swap: it is spent only at t + SNIPE_SECONDS.
    assertGt(hook.surchargeBpsAt(t + SNIPE_SECONDS - 1), 0, "surcharge gone before the seed window closes");
    assertEq(hook.surchargeBpsAt(t + SNIPE_SECONDS), 0, "surcharge not fully decayed at the seed window");
  }

  /// LOW: single-sidedness is self-enforcing. A rung whose range STRADDLES spot owes USDG the ESSEY-only
  /// seeder cannot pay, so the whole seed reverts with the EXPLICIT `UsdgOwed` error — asserted directly here,
  /// not via a downstream settle-revert. RED if the seeder's owed-USDG check is removed.
  function test_straddling_rung_reverts_usdg_owed() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);

    LaunchSeeder.Rung[] memory rungs = new LaunchSeeder.Rung[](1);
    rungs[0] = LaunchSeeder.Rung({tickLower: -60, tickUpper: 600, esseyAmount: 100e18}); // straddles open tick 0

    vm.expectRevert(LaunchSeeder.UsdgOwed.selector);
    seeder.seed(rungs);
  }

  // ================================================================= C-2: seeder defensive guards

  /// LaunchSeeder.sol:161 AMOUNT_MARGIN. Liquidity is minted from (esseyAmount − MARGIN), so the pool's
  /// round-UP of the owed ESSEY keeps a cushion and can never reach — let alone exceed — a rung's allotment.
  /// Recompute each rung's owed ESSEY from its minted liquidity and assert it stays STRICTLY below the
  /// allotment. RED against dropping `- AMOUNT_MARGIN` (owed would round-trip to exactly the allotment, so the
  /// strict-below headroom the guard guarantees is gone).
  function test_amount_margin_keeps_owed_below_allotment() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    LaunchSeeder.Rung[] memory rungs = _ladder(OPEN_TICK);
    seeder.seed(rungs);

    for (uint256 i = 0; i < rungs.length; i++) {
      (int24 lo, int24 hi, uint128 L) = seeder.positions(i);
      uint256 owed =
        SqrtPriceMath.getAmount0Delta(TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), L, true);
      assertLt(owed, rungs[i].esseyAmount, "rung round-up not held below its allotment (AMOUNT_MARGIN dropped)");
    }
  }

  /// LaunchSeeder.sol:144 MAX_LEFTOVER. A mis-parameterized ladder that strands more ESSEY than the dust cap
  /// must revert `LeftoverTooLarge`, not silently lock the surplus. Fund 302e18 against a ~300e18 ladder → the
  /// ~2e18 stranded is far over the 1e18 cap. RED against dropping the leftover check (the seed would complete
  /// and trap the surplus forever).
  function test_leftover_over_cap_reverts() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 302e18); // ladder consumes ~300e18; ~2e18 stranded > MAX_LEFTOVER (1e18)
    vm.expectRevert(LaunchSeeder.LeftoverTooLarge.selector);
    seeder.seed(_ladder(OPEN_TICK));
  }

  // ================================================================= MEDIUM: LaunchSeeder.seed access gate

  /// LaunchSeeder.sol:124 NotSeedCaller — only the deploying founder key may seed(). FUNDED here so the mutation
  /// is unambiguous: with the guard deleted a stranger's seed SUCCEEDS (no revert) — guard present -> the revert.
  function test_seed_rejects_non_seedCaller() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    vm.prank(address(0xBAD));
    vm.expectRevert(LaunchSeeder.NotSeedCaller.selector);
    seeder.seed(_ladder(OPEN_TICK));
  }

  // ================================================================= LaunchSeeder: remaining reachable guards

  /// LaunchSeeder.sol:96 ZeroAddress — split so a mutant dropping either clause of the `||` cannot survive.
  function test_seeder_constructor_rejects_zero_manager() public {
    vm.expectRevert(LaunchSeeder.ZeroAddress.selector);
    new LaunchSeeder(IPoolManager(address(0)), c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(hook)), OPEN_PRICE);
  }

  function test_seeder_constructor_rejects_zero_price() public {
    vm.expectRevert(LaunchSeeder.ZeroAddress.selector);
    new LaunchSeeder(IPoolManager(address(manager)), c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(hook)), uint160(0));
  }

  /// LaunchSeeder.sol:126 NoRungs — an empty ladder is refused before any pool work.
  function test_seed_rejects_empty_rungs() public {
    LaunchSeeder seeder = _deploySeeder();
    LaunchSeeder.Rung[] memory none = new LaunchSeeder.Rung[](0);
    vm.expectRevert(LaunchSeeder.NoRungs.selector);
    seeder.seed(none);
  }

  /// LaunchSeeder.sol:156 TickOrder — a rung whose upper is not strictly above its lower reverts.
  function test_seed_rejects_tick_order() public {
    LaunchSeeder seeder = _deploySeeder();
    LaunchSeeder.Rung[] memory r = new LaunchSeeder.Rung[](1);
    r[0] = LaunchSeeder.Rung({tickLower: 600, tickUpper: 600, esseyAmount: 100e18});
    vm.expectRevert(LaunchSeeder.TickOrder.selector);
    seeder.seed(r);
  }

  /// LaunchSeeder.sol:157 TickNotAligned — both sub-branches (lower and upper misaligned to tickSpacing).
  function test_seed_rejects_misaligned_ticks() public {
    LaunchSeeder seeder = _deploySeeder();

    LaunchSeeder.Rung[] memory lowBad = new LaunchSeeder.Rung[](1);
    lowBad[0] = LaunchSeeder.Rung({tickLower: 1, tickUpper: 600, esseyAmount: 100e18});
    vm.expectRevert(LaunchSeeder.TickNotAligned.selector);
    seeder.seed(lowBad);

    LaunchSeeder.Rung[] memory hiBad = new LaunchSeeder.Rung[](1);
    hiBad[0] = LaunchSeeder.Rung({tickLower: 0, tickUpper: 601, esseyAmount: 100e18});
    vm.expectRevert(LaunchSeeder.TickNotAligned.selector);
    seeder.seed(hiBad);
  }

  /// LaunchSeeder.sol:162 LiquidityOverflow — esseyAmount == AMOUNT_MARGIN (1e3) rounds liquidity to 0, refused.
  function test_seed_rejects_zero_liquidity() public {
    LaunchSeeder seeder = _deploySeeder();
    LaunchSeeder.Rung[] memory r = new LaunchSeeder.Rung[](1);
    r[0] = LaunchSeeder.Rung({tickLower: 0, tickUpper: 600, esseyAmount: 1000});
    vm.expectRevert(LaunchSeeder.LiquidityOverflow.selector);
    seeder.seed(r);
  }

  // ================================================================= A-3: griefed-seed recovery

  /// The escape hatch opens ONLY in the state where seed() can never succeed, and returns every wei to the
  /// founder key. RED against removing recoverGriefedSeed: the seeder has no other egress at all.
  function test_recover_returns_the_prefunded_essey_when_the_price_is_off_peg() public {
    manager.initialize(key, OPEN_PRICE);
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);
    manager.setSqrtPrice(OPEN_PRICE + 1); // the free walk, as proven reachable on the real manager

    uint256 before = essey.balanceOf(address(this));
    assertEq(seeder.recoverGriefedSeed(), 300e18, "recovery returned the wrong amount");
    assertEq(essey.balanceOf(address(this)) - before, 300e18, "ESSEY did not reach the founder");
    assertEq(essey.balanceOf(address(seeder)), 0, "ESSEY left behind");
    assertTrue(seeder.seeded(), "recovery is not terminal");
  }

  /// Every guard on the hatch, one branch per assertion: caller, pool-unopened, pool-on-peg, empty balance,
  /// and post-seed. RED against widening any single one of them into a withdrawal backdoor.
  function test_recover_is_closed_in_every_state_where_seed_still_works() public {
    LaunchSeeder seeder = _deploySeeder();
    essey.transfer(address(seeder), 300e18);

    vm.prank(address(0xBAD));
    vm.expectRevert(LaunchSeeder.NotSeedCaller.selector);
    seeder.recoverGriefedSeed();

    vm.expectRevert(LaunchSeeder.NotGriefed.selector);
    seeder.recoverGriefedSeed(); // pool never initialized

    manager.initialize(key, OPEN_PRICE);
    vm.expectRevert(LaunchSeeder.NotGriefed.selector);
    seeder.recoverGriefedSeed(); // pool live, on the peg

    seeder.seed(_ladder(OPEN_TICK));
    manager.setSqrtPrice(OPEN_PRICE + 1); // off-peg AFTER the seed must still not open the hatch
    vm.expectRevert(LaunchSeeder.AlreadySeeded.selector);
    seeder.recoverGriefedSeed();
  }

  /// An off-peg pool with nothing pre-funded reverts rather than burning the one shot on a no-op.
  function test_recover_rejects_an_empty_seeder() public {
    manager.initialize(key, OPEN_PRICE);
    LaunchSeeder seeder = _deploySeeder();
    manager.setSqrtPrice(OPEN_PRICE + 1);

    vm.expectRevert(LaunchSeeder.NothingToRecover.selector);
    seeder.recoverGriefedSeed();
    assertFalse(seeder.seeded(), "an empty recovery still burned the one shot");
  }

  /// LaunchSeeder.sol:137 PreInitWrongPrice — a pool pre-initialized at a price other than the seeder's pinned
  /// one is refused. The hook pins the real init price in prod; a mismatched-expected seeder manufactures it.
  function test_seed_rejects_preinit_wrong_price() public {
    manager.initialize(key, OPEN_PRICE); // pool live at the real pinned price
    LaunchSeeder wrong = new LaunchSeeder(
      IPoolManager(address(manager)), c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(hook)), OPEN_PRICE + 1
    );
    essey.transfer(address(wrong), 300e18);
    vm.expectRevert(LaunchSeeder.PreInitWrongPrice.selector);
    wrong.seed(_ladder(OPEN_TICK));
  }
}
