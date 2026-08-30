// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// A testnet stand-in for a Robinhood Stock Token: an ERC-20 that also implements the ERC-8056
/// "Scaled UI Amount" surface (`IScaledUI`).
///
/// This exists because the surface is NOT optional. `EsseyMarkets.collateralValue` computes
/// `uiAmount = rawAmount * uiMultiplier() / 1e18` before pricing, so a collateral token without
/// `uiMultiplier()` makes that call revert and `canBorrow` returns false — which is exactly the
/// state the earlier plain-ERC20Mock testnet fixtures left the markets in. Mainnet Stock Tokens
/// implement it, so the gap was a fixture gap rather than a contract bug; this closes it without
/// weakening anything the real token does.
///
/// `setUIMultiplier` models a corporate action (a split re-scales every holder's UI balance while
/// raw balances are untouched), so the split-handling path can be exercised on testnet too.
contract ScaledUIStockMock is ERC20 {
    uint256 public uiMultiplier = 1e18;
    uint256 private _newMultiplier;
    uint256 private _effectiveAt;

    event UIMultiplierSet(uint256 multiplier);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setUIMultiplier(uint256 m) external {
        require(m > 0, "zero multiplier");
        uiMultiplier = m;
        emit UIMultiplierSet(m);
    }

    function scheduleUIMultiplier(uint256 m, uint256 effectiveAt_) external {
        _newMultiplier = m;
        _effectiveAt = effectiveAt_;
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return (balanceOf(account) * uiMultiplier) / 1e18;
    }

    function totalSupplyUI() external view returns (uint256) {
        return (totalSupply() * uiMultiplier) / 1e18;
    }

    function newUIMultiplier() external view returns (uint256, uint256) {
        return (_newMultiplier, _effectiveAt);
    }
}
