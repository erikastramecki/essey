// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
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
///
/// MARKETPLACE READINESS: the Don also carries a collection-wide royalty (a voluntary same-currency signal
/// marketplaces read) and a rotatable collection-metadata pointer. Both are minter-gated through the
/// distributor's passthrough — the same trust shape as hook/art/lienManager — so the treasury/rate and the
/// collection JSON can be tuned post-deploy by the same admin (a multisig in production) without ever
/// touching the immutable minter or the sealed per-token art.
contract Don is ERC721, ERC2981 {
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

    /// The loan facility (DonLoan) allowed to lien Dons as live-in-wallet collateral. Wired once by the
    /// minter, like `hook`/`art`. A liened Don cannot be transferred (so it can't be sold, redeemed, or
    /// moved out from under its debt) but STAYS in the borrower's wallet — still staked, still earning —
    /// until the lien clears on repayment or the facility seizes it on liquidation.
    address public lienManager;

    /// Whether a Don is currently pledged as loan collateral (transfer-locked).
    mapping(uint256 => bool) public liened;

    /// The hard ceiling on the collection royalty — marketplaces cap creator earnings at 10%, and both the
    /// constructor and the setter enforce it so no admin can ever set a rate a marketplace would reject.
    uint96 public constant MAX_ROYALTY_BPS = 1000;

    /// Collection-level metadata (name/description/image/banner_image/external_link JSON), rotatable like
    /// the renderer's baseURI: a settable pointer or on-chain data string, empty until set post-deploy.
    string private _contractURI;

    event Rerolled(uint256 indexed id, bytes32 traits);
    event Locked(uint256 indexed id, bytes32 traits);
    event Lien(uint256 indexed id, bool on);
    event DefaultRoyaltySet(address indexed receiver, uint96 bps);
    /// Signals collection-metadata changes so marketplaces re-pull contractURI() (ERC-7572).
    event ContractURIUpdated();

    error NotMinter();
    error BadRoyalty();
    error SoldOut();
    error TraitsLocked();
    error NonexistentToken();
    error HookAlreadySet();
    error HookNotContract();
    error ArtAlreadySet();
    error ArtNotContract();
    error LienManagerAlreadySet();
    error LienManagerNotContract();
    error NotLienManager();
    error LienActive();

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address minter_,
        address royaltyReceiver_,
        uint96 royaltyBps_
    ) ERC721(name_, symbol_) {
        vaultImplementation = address(new SeatVault());
        maxSupply = maxSupply_;
        minter = minter_;
        // Collection-wide default royalty to the treasury, capped at the 10% marketplace ceiling. OZ's
        // _setDefaultRoyalty additionally rejects a zero receiver, so a royalty is never set to nowhere.
        if (royaltyBps_ > MAX_ROYALTY_BPS) revert BadRoyalty();
        _setDefaultRoyalty(royaltyReceiver_, royaltyBps_);
        emit DefaultRoyaltySet(royaltyReceiver_, royaltyBps_);
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

    /// Re-randomize / re-select a Don's traits (the paid reroll or the custom build), while still mutable.
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

    /// One-time wiring of the loan facility, by the minter. Same trust shape as setHook/setArt: a contract,
    /// pinned forever — the power to lien (and seize liened) Dons is granted to exactly one audited facility
    /// and can never be re-pointed.
    function setLienManager(address manager_) external onlyMinter {
        if (lienManager != address(0)) revert LienManagerAlreadySet();
        if (manager_ == address(0) || manager_.code.length == 0) revert LienManagerNotContract();
        lienManager = manager_;
    }

    /// Pledge / release a Don as loan collateral. Facility-only. The facility is responsible for only
    /// liening with the owner's consent (its borrow path) and only releasing on repayment/liquidation.
    function setLien(uint256 id, bool on) external {
        if (msg.sender != lienManager) revert NotLienManager();
        if (_ownerOf(id) == address(0)) revert NonexistentToken();
        liened[id] = on;
        emit Lien(id, on);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return art == address(0) ? "" : ISeatArt(art).tokenURI(id);
    }

    /// Re-point the collection-wide royalty (receiver + rate), minter-gated through the distributor's
    /// passthrough — the same admin path as hook/art/lienManager. Collection-wide only (no per-token);
    /// capped at the 10% marketplace ceiling. A voluntary same-currency signal, not enforcement.
    function setDefaultRoyalty(address receiver, uint96 bps) external onlyMinter {
        if (bps > MAX_ROYALTY_BPS) revert BadRoyalty();
        _setDefaultRoyalty(receiver, bps); // OZ rejects a zero receiver
        emit DefaultRoyaltySet(receiver, bps);
    }

    /// Collection-level metadata (ERC-7572), read by marketplaces for the collection's name/banner/links.
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// Rotate the collection metadata, minter-gated through the distributor's passthrough. Emits the
    /// ERC-7572 signal so marketplaces re-pull. Empty is fine (set post-deploy).
    function setContractURI(string calldata uri) external onlyMinter {
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// The multiple-inheritance diamond: ERC721 answers 0x80ac58cd (+ metadata + ERC-165), ERC2981 answers
    /// 0x2a55205a. The C3-linearized super chain composes both, so a marketplace sees the collection as both
    /// an NFT and a royalty source.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// A liened Don is transfer-locked: every exit (sale, AMM, reserve redemption) is blocked until the
    /// debt clears. Only the lien facility itself may move it — the seizure path of a liquidation.
    /// The gate runs BEFORE the ownership write; mints (owner == 0) are never liened.
    ///
    /// Notify the hook on true ownership transfers only — mints (from == 0) stand up fresh state and burns
    /// don't exist in this collection.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        if (liened[tokenId] && _ownerOf(tokenId) != address(0) && msg.sender != lienManager) {
            revert LienActive();
        }
        from = super._update(to, tokenId, auth);
        if (hook != address(0) && from != address(0) && to != address(0)) {
            ISeatHook(hook).onSeatTransfer(tokenId, from, to);
        }
    }

    /// The facility may move a LIENED Don without holder approval — that is the seizure half of the lien
    /// (the transfer-lock above is the other half). Scoped strictly to liened tokens: over an unliened Don
    /// the facility has no more authority than anyone else.
    function _isAuthorized(address owner, address spender, uint256 tokenId)
        internal
        view
        override
        returns (bool)
    {
        if (liened[tokenId] && spender == lienManager) return true;
        return super._isAuthorized(owner, spender, tokenId);
    }
}
