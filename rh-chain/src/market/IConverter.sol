// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Claim-edge payout conversion for the Bell. An implementation pulls `amountIn` of the Bell's base
/// reward token from the caller, swaps it for `targetToken`, and delivers the output DIRECTLY to
/// `recipient` (a Seat's Vault) — the converter must never custody funds at rest.
///
/// The implementation is responsible for fairness: it must revert unless the delivered amount is at
/// least the oracle-implied value minus its slippage bound. The Bell wraps `convert` in try/catch and
/// FAILS OPEN to paying the base asset — so a converter can decline (revert) freely, but can never
/// block a payout.
interface IConverter {
    /// True if `token` is a registered, convertible payout target.
    function isSupported(address token) external view returns (bool);

    /// Pull `amountIn` base from msg.sender, swap, deliver >= oracle-fair `targetToken` to `recipient`.
    function convert(uint256 amountIn, address targetToken, address recipient)
        external
        returns (uint256 amountOut);
}

/// Minimal Uniswap V3-style swap router surface — the SwapRouter02 struct shape (NO deadline field),
/// which is the only router deployed on Robinhood Chain mainnet (verified on-chain 2026-08-11: the
/// classic deadline-carrying selector is absent from its bytecode; encoding it reverts every swap).
/// Callers needing deadline protection enforce it in their own contract before calling.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
