// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// $ESSEY — the Essey Market's access token. Spent to buy Seats on the Exchange, activate/upgrade
/// Tiers at the Bell, and buy Cases. Never the reward asset: Payouts are stocks/USDG, so there are no
/// staking emissions and nothing to inflate (see docs/TOKENOMICS-essey.md — the three-asset rule).
///
/// Deliberately minimal and ADMINLESS: fixed supply minted once at construction to the distribution
/// treasury (which then seeds the Exchange float reserve, liquidity, and community allocations by
/// ordinary transfers). No mint function, no owner, no pause, no blocklist — nothing for a key to do.
///
///   - Supply: 8,888,888,888 (18 decimals) — the 8,888-Don collection motif, same order as the
///     reference economy's proven scale (docs/ECONOMICS-seats-model.md).
///   - ERC20Burnable: real supply-reducing burns. (The Bell's tier-fee sink transfers to 0xdEaD, which
///     works for any ERC-20; burn() lets integrators reduce totalSupply outright when preferred.)
///   - ERC20Permit: gasless approvals, so activating a Tier or buying a Case is one transaction.
contract EsseyToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 8_888_888_888e18;

    error TreasuryZero();

    constructor(address treasury) ERC20("Essey", "ESSEY") ERC20Permit("Essey") {
        if (treasury == address(0)) revert TreasuryZero();
        _mint(treasury, TOTAL_SUPPLY);
    }
}
