// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// The venue seam for Multiply's swap legs (AD-3: venue differences live in adapters, never in
/// forked siblings). An adapter pulls `amountIn` of `tokenIn` from the caller (allowance is set
/// per call, exact), delivers `tokenOut` to `to`, and returns the delivered amount. The return
/// value is informational: callers MUST verify delivery by their own balance delta, so a lying
/// or fee-taking venue is caught at the caller, not trusted.
interface ISwapAdapter {
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut);
}
