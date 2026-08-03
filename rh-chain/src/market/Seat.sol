// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SeatVault} from "./SeatVault.sol";
import {ISeatHook} from "./ISeatHook.sol";

/// Seat — Essey's membership NFT, like a seat on an exchange: scarce, tradeable, and entitled to a share
/// of the floor's activity. Each Seat deterministically owns a Vault (its token-bound account), created
/// and initialized atomically at mint, so:
///   - the Vault address is stable and derivable off-chain (vaultOf),
///   - the Vault, and everything sealed inside it, travels with the Seat on transfer,
///   - only the current holder controls the Vault.
///
/// This is the foundation (phase 1) of the market layer: later phases raise a Seat's Tier by staking
/// $ESSEY and ring the Bell to Payout protocol fees into active Seats' Vaults. See
/// docs/DESIGN-seats-market-layer.md.
contract Seat is ERC721 {
    /// The account implementation every Vault clones.
    address public immutable vaultImplementation;

    /// The one address permitted to mint (the Floor / mint-sale contract in later phases). Fixed at
    /// construction — no admin key can change who mints.
    address public immutable minter;

    /// Fixed collection size — a Seat is scarce by construction.
    uint256 public immutable maxSupply;

    uint256 public totalMinted;

    /// The Bell (or future replacement) — notified on every true ownership transfer so per-owner state
    /// (a Seat's Tier) clears when the Seat changes hands. Set once by the minter at deploy time; the
    /// hook is trusted infrastructure (pure state updates, no external calls), so its call is NOT
    /// try/caught — a reverting hook would be a deployment bug, not a user-facing hazard.
    address public hook;

    error NotMinter();
    error SoldOut();
    error HookAlreadySet();

    constructor(string memory name_, string memory symbol_, uint256 maxSupply_, address minter_)
        ERC721(name_, symbol_)
    {
        vaultImplementation = address(new SeatVault());
        maxSupply = maxSupply_;
        minter = minter_;
    }

    /// Mint the next Seat and stand up its Vault in the same transaction. Ids are 1-based.
    function mint(address to) external returns (uint256 id) {
        if (msg.sender != minter) revert NotMinter();
        if (totalMinted >= maxSupply) revert SoldOut();
        id = ++totalMinted;
        _safeMint(to, id);

        // CREATE2 clone at an address only this contract can deploy to (deployer is part of the salt
        // preimage), then bind it — so no one can front-run and initialize the Vault maliciously.
        address vault = Clones.cloneDeterministic(vaultImplementation, _salt(id));
        SeatVault(payable(vault)).initialize(address(this), id);
    }

    /// The deterministic Vault address for a Seat — derivable before or after mint.
    function vaultOf(uint256 id) public view returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, _salt(id), address(this));
    }

    function _salt(uint256 id) internal pure returns (bytes32) {
        return bytes32(id);
    }

    /// One-time wiring of the transfer hook (the Bell), by the minter.
    function setHook(address hook_) external {
        if (msg.sender != minter) revert NotMinter();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
    }

    /// Notify the hook on true ownership transfers only — mints (from == 0) stand up fresh state and
    /// burns don't exist in this collection.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (hook != address(0) && from != address(0) && to != address(0)) {
            ISeatHook(hook).onSeatTransfer(tokenId, from, to);
        }
    }
}
