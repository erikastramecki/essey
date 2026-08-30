// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// The multiplierSource for collateral without the ERC-8056 surface (Backed's Ink 4626 wrapper):
/// its Chainlink feed prices the WRAPPED token directly, so corporate actions are already in the
/// price and the multiplier is identity. Implements exactly the two members EsseyMarkets consumes.
contract ConstantMultiplier {
    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function newUIMultiplier() external pure returns (uint256, uint256) {
        return (0, 0);
    }
}
