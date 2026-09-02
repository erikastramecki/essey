// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// ---------------------------------------------------------------------------------------------
/// Minimal Uniswap-V3 surfaces (pool + factory). NO NonfungiblePositionManager anywhere: the NFPM
/// was never located/verified on RH-chain (MAINNET-CONFIG), so positions are pool-native — minted
/// with `pool.mint` + the `uniswapV3MintCallback`, owned by THIS contract, keyed by
/// keccak256(owner, tickLower, tickUpper). One fewer external contract to trust.
/// ---------------------------------------------------------------------------------------------
interface IUniV3FactoryMin {
    function getPool(address, address, uint24) external view returns (address);
    function createPool(address, address, uint24) external returns (address);
}

interface IUniV3PoolMin {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256, uint256);
    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Req, uint128 amount1Req)
        external
        returns (uint128, uint128);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
    function positions(bytes32 key)
        external
        view
        returns (uint128 liquidity, uint256, uint256, uint128 tokensOwed0, uint128 tokensOwed1);
}

/// EsseyLadderSeeder — one-shot holder of the $ESSEY launch liquidity ladder (locked POL).
///
/// WHAT IT DOES (once, then it is inert forever):
///   1. receives the seed ESSEY (300M per the founder-ruled zero-capital launch),
///   2. creates + initializes the ESSEY/USDG fee-3000 pool at the founder's opening price,
///   3. mints N single-sided, SELL-side-only v3 ranges ("tranches") via direct pool.mint —
///      zero USDG is ever required: every range sits entirely on the ESSEY side of the price,
///      so buyers bring all the dollars and the traversed ranges convert into the USDG
///      support wall underneath them (the ladder mechanic, DON-ESSEY-LIQUIDITY-PLAN addendum).
///
/// LOCKED BY CONSTRUCTION (the DonReserve/DonFeeRouter doctrine applied to liquidity):
///   - NO withdraw function. NO decreaseLiquidity path: `pool.burn` is only ever called with
///     amount = 0 (the fee "poke"). The principal cannot leave — not timelocked, nonexistent.
///   - `collectFees()` is PERMISSIONLESS and can only send accrued swap fees (plus any loose,
///     non-position dust) to the immutable `feeRecipient` (the treasury multisig). Fees landing
///     at the treasury re-enter the standing 25% LP-skim policy — the simplest safe disposition
///     until the LPManager v2 ships (which will mint its OWN position alongside; no migration).
///
/// GRIEFING (plan §3c): an empty pool costs nothing for a griefer to pre-create/initialize at a
/// skewed price the moment the token address appears. Handling:
///   - pool missing        -> create + initialize at target. Normal path.
///   - initialized BELOW   -> proceed. All tranches still sit strictly above spot, mints stay
///     our open price        single-sided; the first buy walks the empty gap up to the ladder.
///   - initialized ABOVE   -> bounded correction: swap up to `maxCorrectionEsseyIn` ESSEY toward
///     our open price        the target price (through an empty book this consumes ~dust; through
///                           griefer liquidity it SELLS ESSEY above our open — never a loss).
///                           If the target is not reached exactly, revert PriceNotCorrected —
///                           fail closed, founder re-runs with a bigger bound or waits out the LP.
///
/// SINGLE-SIDEDNESS IS SELF-ENFORCING: this contract never holds USDG at seed time, so if any
/// range were mis-parameterized to straddle spot, the pool's mint callback would demand USDG the
/// seeder cannot pay and the whole seed reverts — a wrong ladder cannot half-deploy.
contract EsseyLadderSeeder {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ immutable configuration
    IERC20 public immutable essey;
    IERC20 public immutable usdg;
    IUniV3FactoryMin public immutable factory;
    uint24 public immutable fee; // 3000 — matches DonFeeRouter.esseyPoolFee (MAINNET-CONFIG blocker #3)
    address public immutable feeRecipient; // treasury multisig — the ONLY place value can ever exit to
    address public immutable seedCaller; // the founder key that may call seed(), once

    // ------------------------------------------------------------------ state
    IUniV3PoolMin public pool; // set during seed()
    bool public seeded;

    struct Tranche {
        int24 lowerOffset; // ticks above the open, in ESSEY-price space (token0 orientation)
        int24 upperOffset;
        uint256 esseyAmount; // 18-dec ESSEY committed to this range
    }

    /// Stored post-seed for verification + the collect loop (absolute pool ticks, orientation applied).
    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 esseyUsed;
    }

    Position[] public positions;

    /// Rounding guard: liquidity is computed from (amount − MARGIN) so the pool's round-UP of the
    /// owed amount can never exceed what the tranche was allotted. 1000 wei of ESSEY ≈ $2.8e-17.
    uint256 internal constant AMOUNT_MARGIN = 1e3;
    /// Post-seed leftover above this reverts — catches gross mis-parameterization (wrong decimals,
    /// wrong ticks) while tolerating margin + round-down dust.
    uint256 internal constant MAX_LEFTOVER = 1e18; // 1 ESSEY
    /// The last tranche absorbs the remainder; it may deviate from its nominal amount by at most
    /// this much (covers a used price-correction + accidental over-transfer without fat-fingering).
    uint256 internal constant LAST_TRANCHE_TOLERANCE = 10e18; // 10 ESSEY

    event Seeded(address pool, uint160 sqrtPriceX96, uint256 esseyIn);
    event TrancheMinted(uint256 indexed idx, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 esseyUsed);
    event PriceCorrected(uint256 esseyIn, uint256 usdgOut);
    event FeesCollected(uint256 esseyOut, uint256 usdgOut);

    error ZeroAddress();
    error NotSeedCaller();
    error AlreadySeeded();
    error NotSeededYet();
    error NoTranches();
    error TickNotAligned();
    error TickOrder();
    error PriceNotCorrected(); // pool pre-initialized above target and the bounded swap could not restore it
    error NotPool();
    error UsdgOwedOnMint(); // a range straddled spot — ladder mis-parameterized, whole seed reverts
    error LeftoverTooLarge();
    error LastTrancheDrift();
    error LiquidityOverflow();

    constructor(IERC20 essey_, IERC20 usdg_, IUniV3FactoryMin factory_, uint24 fee_, address feeRecipient_) {
        if (
            address(essey_) == address(0) || address(usdg_) == address(0) || address(factory_) == address(0)
                || feeRecipient_ == address(0)
        ) revert ZeroAddress();
        essey = essey_;
        usdg = usdg_;
        factory = factory_;
        fee = fee_;
        feeRecipient = feeRecipient_;
        seedCaller = msg.sender;
    }

    // ================================================================== the one-shot seed

    /// @param openTickE0 the opening tick in TOKEN0=ESSEY orientation (USDG-per-ESSEY raw price =
    ///        1.0001^openTickE0). If sorting puts ESSEY at token1, everything is mirrored (tick
    ///        negation flips a price into its reciprocal, ranges [a,b] -> [-b,-a]) — callers always
    ///        think in ESSEY-price space and never need to know the sort order.
    /// @param tranches ascending, contiguous-or-gapped ranges ABOVE the open, ESSEY amounts in wei.
    /// @param maxCorrectionEsseyIn ESSEY budget for the anti-griefing price correction (0 = refuse
    ///        to correct: any pre-initialized-above pool reverts the seed).
    function seed(int24 openTickE0, Tranche[] calldata tranches, uint256 maxCorrectionEsseyIn) external {
        if (msg.sender != seedCaller) revert NotSeedCaller();
        if (seeded) revert AlreadySeeded();
        if (tranches.length == 0) revert NoTranches();
        seeded = true;

        uint256 esseyIn = essey.balanceOf(address(this));
        bool esseyIs0 = address(essey) < address(usdg);

        // ---- pool: fetch or create ----
        address p = factory.getPool(address(essey), address(usdg), fee);
        if (p == address(0)) p = factory.createPool(address(essey), address(usdg), fee);
        pool = IUniV3PoolMin(p);

        // ---- price: initialize at target, or correct a griefed initialization ----
        uint160 targetSqrt = TickMath.getSqrtRatioAtTick(esseyIs0 ? openTickE0 : -openTickE0);
        (uint160 sqrtP,,,,,,) = pool.slot0();
        if (sqrtP == 0) {
            pool.initialize(targetSqrt);
        } else {
            // "ESSEY price above our open" in pool coordinates: token0=ESSEY -> sqrt too HIGH;
            // token1=ESSEY (price is ESSEY-per-USDG) -> sqrt too LOW.
            bool above = esseyIs0 ? sqrtP > targetSqrt : sqrtP < targetSqrt;
            if (above) {
                if (maxCorrectionEsseyIn == 0) revert PriceNotCorrected();
                // Sell ESSEY toward the target with the price limit AT the target: through an empty
                // book this moves spot for ~dust; through hostile liquidity it stops at the bound.
                (int256 a0, int256 a1) =
                    pool.swap(address(this), esseyIs0, int256(maxCorrectionEsseyIn), targetSqrt, "");
                (sqrtP,,,,,,) = pool.slot0();
                if (sqrtP != targetSqrt) revert PriceNotCorrected();
                uint256 spent = uint256(esseyIs0 ? a0 : a1); // positive = paid by us (ESSEY)
                uint256 got = uint256(-(esseyIs0 ? a1 : a0)); // negative = received (USDG)
                emit PriceCorrected(spent, got);
            }
            // BELOW target: proceed — every range still sits strictly above spot (single-sided),
            // and the first market buy walks the empty gap up to the ladder's first rung.
        }

        // ---- mint the ladder ----
        int24 spacing = pool.tickSpacing(); // 60 for fee 3000 — verified on-chain, still read live
        for (uint256 i = 0; i < tranches.length; i++) {
            Tranche calldata t = tranches[i];
            if (t.upperOffset <= t.lowerOffset) revert TickOrder();

            // Orientation: token0=ESSEY keeps ESSEY-price ticks as-is; token1=ESSEY mirrors them.
            (int24 lo, int24 hi) = esseyIs0
                ? (openTickE0 + t.lowerOffset, openTickE0 + t.upperOffset)
                : (-(openTickE0 + t.upperOffset), -(openTickE0 + t.lowerOffset));
            if (lo % spacing != 0 || hi % spacing != 0) revert TickNotAligned();

            // The LAST tranche absorbs the remainder (correction spend + rounding), within tolerance.
            uint256 amt = i == tranches.length - 1 ? essey.balanceOf(address(this)) : t.esseyAmount;
            if (i == tranches.length - 1) {
                uint256 nominal = t.esseyAmount;
                if (amt + LAST_TRANCHE_TOLERANCE < nominal || amt > nominal + LAST_TRANCHE_TOLERANCE) {
                    revert LastTrancheDrift();
                }
            }

            uint160 sqrtLo = TickMath.getSqrtRatioAtTick(lo);
            uint160 sqrtHi = TickMath.getSqrtRatioAtTick(hi);
            // Single-sided liquidity for `amt` of ESSEY over [lo, hi] (margin guards round-up):
            //   token0:  L = amt · (√lo·√hi / Q96) / (√hi − √lo)
            //   token1:  L = amt · Q96 / (√hi − √lo)
            uint256 liq = esseyIs0
                ? Math.mulDiv(amt - AMOUNT_MARGIN, Math.mulDiv(sqrtLo, sqrtHi, FixedPoint96.Q96), sqrtHi - sqrtLo)
                : Math.mulDiv(amt - AMOUNT_MARGIN, FixedPoint96.Q96, sqrtHi - sqrtLo);
            if (liq > type(uint128).max) revert LiquidityOverflow();

            uint256 balBefore = essey.balanceOf(address(this));
            (uint256 m0, uint256 m1) = pool.mint(address(this), lo, hi, uint128(liq), "");
            // Zero USDG may ever be owed — if it is, a range straddles spot and the ladder is wrong.
            if ((esseyIs0 ? m1 : m0) != 0) revert UsdgOwedOnMint();
            uint256 used = balBefore - essey.balanceOf(address(this));

            positions.push(Position({tickLower: lo, tickUpper: hi, liquidity: uint128(liq), esseyUsed: used}));
            emit TrancheMinted(i, lo, hi, uint128(liq), used);
        }

        if (essey.balanceOf(address(this)) > MAX_LEFTOVER) revert LeftoverTooLarge();
        emit Seeded(p, targetSqrt, esseyIn);
    }

    // ================================================================== permissionless fee sweep

    /// Poke + collect the accrued 0.30% swap fees on every tranche and forward them (with any loose
    /// non-position dust) to the immutable treasury. PERMISSIONLESS — anyone may crank; the caller
    /// chooses nothing. `burn(…, 0)` only updates fee accounting: position PRINCIPAL is untouchable
    /// because no code path ever calls burn with a nonzero amount.
    function collectFees() external returns (uint256 esseyOut, uint256 usdgOut) {
        if (!seeded) revert NotSeededYet();
        for (uint256 i = 0; i < positions.length; i++) {
            Position storage q = positions[i];
            pool.burn(q.tickLower, q.tickUpper, 0); // fee poke, zero liquidity change
            pool.collect(address(this), q.tickLower, q.tickUpper, type(uint128).max, type(uint128).max);
        }
        esseyOut = essey.balanceOf(address(this));
        usdgOut = usdg.balanceOf(address(this));
        if (esseyOut > 0) essey.safeTransfer(feeRecipient, esseyOut);
        if (usdgOut > 0) usdg.safeTransfer(feeRecipient, usdgOut);
        emit FeesCollected(esseyOut, usdgOut);
    }

    // ================================================================== views

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    /// The pool's storage key for tranche `i` — for external `pool.positions(key)` verification.
    function positionKey(uint256 i) external view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), positions[i].tickLower, positions[i].tickUpper));
    }

    // ================================================================== uniswap callbacks

    /// Pool-authenticated: pays exactly what the pool computed for our own mint call, nothing else.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (msg.sender != address(pool)) revert NotPool();
        bool esseyIs0 = address(essey) < address(usdg);
        if ((esseyIs0 ? amount1Owed : amount0Owed) != 0) revert UsdgOwedOnMint();
        uint256 owed = esseyIs0 ? amount0Owed : amount1Owed;
        if (owed > 0) essey.safeTransfer(msg.sender, owed);
    }

    /// Only reachable from the bounded anti-griefing correction inside seed(). Pays the ESSEY leg;
    /// a positive USDG delta is impossible for the direction we swap, and is rejected anyway.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(pool)) revert NotPool();
        bool esseyIs0 = address(essey) < address(usdg);
        int256 esseyDelta = esseyIs0 ? amount0Delta : amount1Delta;
        int256 usdgDelta = esseyIs0 ? amount1Delta : amount0Delta;
        if (usdgDelta > 0) revert UsdgOwedOnMint();
        if (esseyDelta > 0) essey.safeTransfer(msg.sender, uint256(esseyDelta));
    }
}

library FixedPoint96 {
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2^96
}

/// Canonical Uniswap-V3 TickMath.getSqrtRatioAtTick, 0.8-safe (unchecked block replaces the 0.7.6
/// wrap semantics; constants verbatim from v3-core). Only the tick->sqrtRatio direction is needed:
/// ticks are chosen by the deploy script, sqrt ratios are what the pool consumes.
library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    error TickOutOfRange();

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange();

            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Q128.128 -> Q64.96, rounding up — identical to v3-core.
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }
}
