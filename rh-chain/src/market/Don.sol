// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SeatVault} from "./SeatVault.sol";
import {ISeatHook} from "./ISeatHook.sol";
import {ISeatArt} from "./ISeatArt.sol";

/// Don — Essey's membership NFT for the Dons era: the 8,888-piece PFP collection that IS the seat at the
/// table. It replaces Seat as the fee-earning entity, and is a faithful evolution of Seat.sol (same
/// immutable-minter + token-bound Vault + transfer-hook + art-renderer shape, so the Bell/Vault/tier
/// plumbing carries over unchanged) with two additions the Dons need:
///
///   1. TRAITS — each Don commits a `traits` hash (the resolved trait combo / uniqueness key). Set at mint
///      and re-set on a paid REROLL, so the art can change until the holder commits.
///   2. LOCK — `locked` freezes a Don's traits forever. The minter (the DonDistributor) locks a Don when it
///      is staked into the AMM to activate. Before that the art is mutable (free/reroll/custom flow);
///      after, it is permanent — "staking locks the art."
///
/// Uniqueness (no two Dons share a trait combo) is enforced by the minter's reservation ledger at set-time;
/// this contract only stores the committed hash and the lock. The minter is the sole entry point for mint /
/// reroll / lock, exactly as Seat's `minter` is its sole minter — no admin key can change who mints.
contract Don is ERC721 {
    /// The account implementation every Vault clones (reused from the Seat era — same token-bound account).
    address public immutable vaultImplementation;

    /// The one address permitted to mint / reroll / lock (the DonDistributor). Fixed at construction.
    address public immutable minter;

    /// Fixed collection size — 8,888 Dons, scarce by construction.
    uint256 public immutable maxSupply;

    uint256 public totalMinted;

    /// The committed trait combo for each Don (its uniqueness key / art seed). Mutable until `locked`.
    mapping(uint256 => bytes32) public traits;

    /// Whether a Don's traits are frozen forever. Set true by the minter when the Don is staked/activated.
    mapping(uint256 => bool) public locked;

    /// The Bell (or future replacement) — notified on every true ownership transfer so per-owner state
    /// (a Don's Tier) clears when it changes hands. Set once by the minter at deploy time.
    address public hook;

    /// The metadata renderer, wired once by the minter. Unset = empty URI.
    address public art;

    event Rerolled(uint256 indexed id, bytes32 traits);
    event Locked(uint256 indexed id, bytes32 traits);

    error NotMinter();
    error SoldOut();
    error TraitsLocked();
    error NonexistentToken();
    error HookAlreadySet();
    error HookNotContract();
    error ArtAlreadySet();
    error ArtNotContract();

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(string memory name_, string memory symbol_, uint256 maxSupply_, address minter_)
        ERC721(name_, symbol_)
    {
        vaultImplementation = address(new SeatVault());
        maxSupply = maxSupply_;
        minter = minter_;
    }

    /// Mint the next Don with its initial trait commitment, standing up its Vault in the same tx. Ids 1-based.
    function mint(address to, bytes32 traits_) external onlyMinter returns (uint256 id) {
        if (totalMinted >= maxSupply) revert SoldOut();
        id = ++totalMinted;
        traits[id] = traits_;
        _safeMint(to, id);

        // CREATE2 clone at an address only this contract can deploy to (deployer is part of the salt
        // preimage), then bind it — so no one can front-run and initialize the Vault maliciously.
        address vault = Clones.cloneDeterministic(vaultImplementation, _salt(id));
        SeatVault(payable(vault)).initialize(address(this), id);
        emit Rerolled(id, traits_);
    }

    /// Re-randomize / re-select a Don's traits (the $1 reroll or the custom build), while still mutable.
    /// Minter-gated: the distributor validates the fee + uniqueness before calling. Reverts once locked.
    function reroll(uint256 id, bytes32 traits_) external onlyMinter {
        if (_ownerOf(id) == address(0)) revert NonexistentToken();
        if (locked[id]) revert TraitsLocked();
        traits[id] = traits_;
        emit Rerolled(id, traits_);
    }

    /// Freeze a Don's traits forever — called by the minter when the Don is staked to activate. Idempotent
    /// only in that a second call would revert (already locked), keeping the one-way transition explicit.
    function lockTraits(uint256 id) external onlyMinter {
        if (_ownerOf(id) == address(0)) revert NonexistentToken();
        if (locked[id]) revert TraitsLocked();
        locked[id] = true;
        emit Locked(id, traits[id]);
    }

    /// The deterministic Vault address for a Don — derivable before or after mint.
    function vaultOf(uint256 id) public view returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, _salt(id), address(this));
    }

    function _salt(uint256 id) internal pure returns (bytes32) {
        return bytes32(id);
    }

    /// One-time wiring of the transfer hook (the Bell), by the minter. Same guards as Seat.setHook.
    function setHook(address hook_) external onlyMinter {
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_ != address(0) && hook_.code.length == 0) revert HookNotContract();
        hook = hook_;
    }

    /// The metadata renderer, wired once by the minter. Same trust shape as Seat.setArt.
    function setArt(address art_) external onlyMinter {
        if (art != address(0)) revert ArtAlreadySet();
        if (art_ != address(0) && art_.code.length == 0) revert ArtNotContract();
        art = art_;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return art == address(0) ? "" : ISeatArt(art).tokenURI(id);
    }

    /// Notify the hook on true ownership transfers only — mints (from == 0) stand up fresh state and burns
    /// don't exist in this collection.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (hook != address(0) && from != address(0) && to != address(0)) {
            ISeatHook(hook).onSeatTransfer(tokenId, from, to);
        }
    }
}
