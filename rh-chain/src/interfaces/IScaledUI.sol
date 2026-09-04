// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// The ERC-8056 "Scaled UI Amount" surface Robinhood Stock Tokens implement.
/// `balanceOf` is the raw amount; `balanceOfUI` is the share-equivalent after corporate actions.
interface IScaledUI {
    function uiMultiplier() external view returns (uint256);
    function balanceOfUI(address account) external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
    /// Scheduled-but-not-yet-effective multiplier, if the token exposes it.
    ///
    /// THE DEPLOYED ROBINHOOD STOCK TOKEN DOES NOT MATCH THIS SIGNATURE: `0xaF3D…93f9` answers with
    /// ONE word (ForkMvp.t.sol asserts the return LENGTH), and a typed `try` cannot survive that. So
    /// EsseyMarkets._scheduledEffectiveAt and CollateralReconciler.pendingMultiplier read it by raw
    /// staticcall — do not "simplify" either back to this. Kept because other ERC-8056
    /// implementations do have the shape (adapters/ConstantMultiplier).
    function newUIMultiplier() external view returns (uint256 newMultiplier, uint256 effectiveAt);
}
