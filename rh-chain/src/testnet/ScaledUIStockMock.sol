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
/// `shape` exists because the interface lies about the deployed token. Real Robinhood Stock Tokens
/// answer `newUIMultiplier()` with ONE word, not the two `IScaledUI` declares (verified on a 4663
/// fork), and a typed `try` cannot survive that mismatch — G-LEND CRIT-1, which stayed invisible
/// precisely because this fixture could only produce the interface's own shape. OneWord is the
/// default so a testnet stack behaves like mainnet.
contract ScaledUIStockMock is ERC20 {
    enum Shape { OneWord, TwoWords, Garbage, Reverts }

    uint256 public uiMultiplier = 1e18;
    Shape public shape = Shape.OneWord;
    uint256 private _newMultiplier;
    uint256 private _effectiveAt;

    event UIMultiplierSet(uint256 multiplier);

    /// Decimals are a CONSTRUCTOR ARGUMENT, never a default (G-LEND R2 LOW-3). This mock stands in
    /// for two different things — an 18-decimal Stock Token and a 6-decimal USDG — and inheriting
    /// ERC20's 18 for both is how a testnet rehearsal came to never exercise the borrow asset that
    /// ships. Every call site states the number it means.
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setUIMultiplier(uint256 m) external {
        require(m > 0, "zero multiplier");
        uiMultiplier = m;
        emit UIMultiplierSet(m);
    }

    function setShape(Shape s) external {
        shape = s;
    }

    /// A pause on the real token BLOCKS TRANSFERS — that is the whole hazard (G-LEND MED-1). A mock
    /// that could not express it could not stand in for the token it stands in for.
    bool public paused;

    function setPaused(bool v) external {
        paused = v;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!paused, "token paused");
        super._update(from, to, amount);
    }

    /// Publishing a schedule implies the two-word shape: a token with no second word has no
    /// effectiveAt to publish.
    function scheduleUIMultiplier(uint256 m, uint256 effectiveAt_) external {
        _newMultiplier = m;
        _effectiveAt = effectiveAt_;
        shape = Shape.TwoWords;
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return (balanceOf(account) * uiMultiplier) / 1e18;
    }

    function totalSupplyUI() external view returns (uint256) {
        return (totalSupply() * uiMultiplier) / 1e18;
    }

    function newUIMultiplier() external view returns (uint256, uint256) {
        Shape s = shape;
        if (s == Shape.TwoWords) return (_newMultiplier, _effectiveAt);
        if (s == Shape.Reverts) revert("no schedule surface");
        uint256 word = uiMultiplier;
        uint256 len = s == Shape.OneWord ? 32 : 5;
        assembly ("memory-safe") {
            mstore(0x00, word)
            return(0x00, len)
        }
    }
}
