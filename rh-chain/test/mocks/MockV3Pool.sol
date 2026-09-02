// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniV3PoolMin, TickMath} from "../../src/market/EsseyLadderSeeder.sol";
import {LiquidityAmounts} from "../../src/market/StockLpVault.sol";

interface IMintCb {
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

/// Faithful-enough concentrated-liquidity pool for the vault suite: real V3 amounts<->liquidity math
/// (the same LiquidityAmounts the contract uses), position accounting keyed exactly like the pool,
/// and callback-authenticated mint. Fees are injected with `accrueFees` (fund the pool, bump owed) to
/// stand in for swap flow; `setSqrtPriceX96` moves spot for manipulation tests without touching stored
/// liquidity — which is the whole point of the oracle-valuation invariant.
contract MockV3Pool is IUniV3PoolMin {
    using SafeERC20 for IERC20;

    struct Pos {
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
        uint256 insideLast0;
        uint256 insideLast1;
    }

    uint256 internal constant Q128 = 1 << 128;

    address public immutable token0Addr;
    address public immutable token1Addr;
    int24 public immutable spacing;
    uint160 public sqrtPriceX96;
    int24 public curTick;
    // Single-position, in-range fee model: tick feeGrowthOutside is 0, so feeGrowthInside == global.
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    mapping(bytes32 => Pos) public pos;

    constructor(address t0, address t1, int24 spacing_, uint160 sqrtP, int24 tick_) {
        token0Addr = t0;
        token1Addr = t1;
        spacing = spacing_;
        sqrtPriceX96 = sqrtP;
        curTick = tick_;
    }

    function token0() external view returns (address) {
        return token0Addr;
    }

    function token1() external view returns (address) {
        return token1Addr;
    }

    function tickSpacing() external view returns (int24) {
        return spacing;
    }

    function initialize(uint160 s) external {
        sqrtPriceX96 = s;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, curTick, 0, 0, 0, 0, true);
    }

    function setSqrtPriceX96(uint160 s, int24 tick_) external {
        sqrtPriceX96 = s;
        curTick = tick_;
    }

    function _key(address owner, int24 lo, int24 hi) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, lo, hi));
    }

    function mint(address recipient, int24 lo, int24 hi, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _amountsFor(lo, hi, amount);
        uint256 b0 = IERC20(token0Addr).balanceOf(address(this));
        uint256 b1 = IERC20(token1Addr).balanceOf(address(this));
        IMintCb(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        require(IERC20(token0Addr).balanceOf(address(this)) >= b0 + amount0, "M0");
        require(IERC20(token1Addr).balanceOf(address(this)) >= b1 + amount1, "M1");
        Pos storage p = pos[_key(recipient, lo, hi)];
        _poke(p);
        p.liquidity += amount;
    }

    function burn(int24 lo, int24 hi, uint128 amount) external returns (uint256 amount0, uint256 amount1) {
        Pos storage p = pos[_key(msg.sender, lo, hi)];
        _poke(p); // real V3 pokes accrued fees into owed on any burn, including the amount==0 fee poke
        (amount0, amount1) = _amountsFor(lo, hi, amount);
        p.liquidity -= amount;
        p.owed0 += uint128(amount0);
        p.owed1 += uint128(amount1);
    }

    /// Credit a position's un-poked feeGrowth into owed, then reset its checkpoint — mirrors the real
    /// pool's _updatePosition. With outside==0, feeGrowthInside is just the global accumulator.
    function _poke(Pos storage p) internal {
        if (p.liquidity != 0) {
            unchecked {
                p.owed0 += uint128(Math.mulDiv(feeGrowthGlobal0X128 - p.insideLast0, p.liquidity, Q128));
                p.owed1 += uint128(Math.mulDiv(feeGrowthGlobal1X128 - p.insideLast1, p.liquidity, Q128));
            }
        }
        p.insideLast0 = feeGrowthGlobal0X128;
        p.insideLast1 = feeGrowthGlobal1X128;
    }

    function collect(address recipient, int24 lo, int24 hi, uint128 req0, uint128 req1)
        external
        returns (uint128 paid0, uint128 paid1)
    {
        Pos storage p = pos[_key(msg.sender, lo, hi)];
        paid0 = req0 < p.owed0 ? req0 : p.owed0;
        paid1 = req1 < p.owed1 ? req1 : p.owed1;
        p.owed0 -= paid0;
        p.owed1 -= paid1;
        if (paid0 > 0) IERC20(token0Addr).safeTransfer(recipient, paid0);
        if (paid1 > 0) IERC20(token1Addr).safeTransfer(recipient, paid1);
    }

    function positions(bytes32 key) external view returns (uint128, uint256, uint256, uint128, uint128) {
        Pos storage p = pos[key];
        return (p.liquidity, p.insideLast0, p.insideLast1, p.owed0, p.owed1);
    }

    /// Single position, always in range => tick feeGrowthOutside is zero, so feeGrowthInside == global.
    /// F2 (LOW, accepted): with outside==0 the vault's `_feeGrowthInside` out-of-range arms
    /// (tick < tickLower / tick >= tickUpper) never execute here. Before trusting pendingFees for
    /// anything load-bearing, cover them with a mainnet-fork test or a mock carrying nonzero
    /// feeGrowthOutside. View-only, off the fund path, so it does not gate this suite.
    ///
    /// S10 (LOW, accepted — SAME class): _harvest guards its fee poke with `if (_liquidity() > 0)
    /// pool.burn(tickLower, tickUpper, 0)`. On a real V3 pool a zero-liquidity `burn(0)` reverts `NP`,
    /// so the guard is load-bearing; this mock's `burn` no-ops an empty position (see `burn`/`_poke`
    /// above — liquidity 0 pokes nothing and subtracts 0), so removing the guard cannot be made to
    /// revert here and the mutant is unpinnable in-mock. The recommended mainnet-fork test must exercise
    /// BOTH: (1) pendingFees across a range boundary (F2), and (2) a harvest over an empty position to
    /// prove the `_liquidity() > 0` poke guard actually prevents the `NP` revert (S10).
    ///
    /// S10b (SAME class, found in the round-2 mutation campaign): rebalance's `if (rangeSet && liq > 0)`
    /// burn/collect guard has the identical fidelity gap — dropping the `liq > 0` arm makes rebalance
    /// burn(0)+collect an empty position, which no-ops here but reverts `NP` on a real pool. The fork
    /// test's empty-position leg (2) covers this guard too: rebalance a range whose liquidity is 0.
    function ticks(int24)
        external
        pure
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        return (0, 0, 0, 0, 0, 0, 0, false);
    }

    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        revert("mock: no swap");
    }

    /// Simulate ALREADY-POKED swap fees on a position: fund the pool, then credit owed directly.
    function accrueFees(address owner, int24 lo, int24 hi, uint128 f0, uint128 f1) external {
        Pos storage p = pos[_key(owner, lo, hi)];
        p.owed0 += f0;
        p.owed1 += f1;
    }

    /// Simulate UN-POKED swap fees: bump the global accumulator so `f` is only realized into owed on the
    /// next poke. Lets a test prove pendingFees predicts what a later harvest collects, not just owed.
    function accrueGrowth(address owner, int24 lo, int24 hi, uint128 f0, uint128 f1) external {
        uint128 liq = pos[_key(owner, lo, hi)].liquidity;
        require(liq > 0, "no liquidity");
        feeGrowthGlobal0X128 += Math.mulDiv(f0, Q128, liq);
        feeGrowthGlobal1X128 += Math.mulDiv(f1, Q128, liq);
    }

    function _amountsFor(int24 lo, int24 hi, uint128 amount) internal view returns (uint256, uint256) {
        uint160 sa = TickMath.getSqrtRatioAtTick(lo);
        uint160 sb = TickMath.getSqrtRatioAtTick(hi);
        return LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sa, sb, amount);
    }
}
