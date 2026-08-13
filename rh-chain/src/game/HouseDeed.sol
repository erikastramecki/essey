// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IDonLike, IGameController, IScrip, IMissionBoard, GameRoles} from "./GameTypes.sol";

/// HouseDeed — the House as a 721 in the Don's 6551 (adapted from the
/// Don.sol shape: module-gated minting, tier state, deterministic custody).
///
/// Phase 0 ships exactly two rungs of the ladder: the FREE Safehouse (auto-claimed at
/// first play) and ONE paid upgrade — the Row House — to test the upgrade-purchase loop. Tier stats
/// are fixed constants: Safehouse cap $50-flat (5,000 Scrip at the 0.01 peg), Row House
/// $15 fee / $150 cap (1,500 / 15,000 Scrip). Base defense on the HD 40→120 ramp.
///
/// Custody: the deed is minted INTO vaultOf(donId) and is SOULBOUND there for Phase 0 — deed
/// withdrawal and the property market are Phase-1 scope (deferred deliberately), and the
/// install/withdraw discipline ("only while home + hopper banked") ships with that market.
/// Upgrades are in-place (no flip arbitrage), paid in Scrip, burned (the Scrip-mode fee sink).
contract HouseDeed is ERC721 {
    struct TierStats {
        uint256 upgradeFee; // Scrip, burned on upgrade INTO this tier
        uint256 deployCap; // HouseEscrow deploy ceiling
        uint16 defense; // HD — the raid engine's base defense stat
        uint8 garrisonSlots;
    }

    IGameController public immutable controller;
    IDonLike public immutable don;
    IScrip public immutable scrip;

    uint8 public constant MAX_TIER = 1; // Phase 0: 0 = Safehouse, 1 = Row House

    uint256 public totalMinted;

    mapping(uint256 => uint8) public tier; // deedId => tier
    mapping(uint256 => uint256) public deedOf; // donId => deedId (one Don, one House)
    mapping(uint256 => uint256) public donOf; // deedId => donId

    event SafehouseClaimed(uint256 indexed donId, uint256 indexed deedId);
    event Upgraded(uint256 indexed donId, uint256 indexed deedId, uint8 toTier, uint256 fee);

    error NotHouseModule();
    error NotDonOwner();
    error AlreadyHasHouse();
    error NoHouse();
    error AtMaxTier();
    error DonIsAway();
    error SoulboundInPhase0();
    error BadConfig();

    constructor(IGameController controller_, IDonLike don_, IScrip scrip_)
        ERC721("D.O.N. House Deed", "HOUSE")
    {
        if (address(controller_) == address(0) || address(don_) == address(0) || address(scrip_) == address(0)) {
            revert BadConfig();
        }
        controller = controller_;
        don = don_;
        scrip = scrip_;
    }

    /// The tier table — the launch constants, readable in one place.
    function tierStats(uint8 t) public pure returns (TierStats memory) {
        if (t == 0) {
            // Safehouse: free (the funnel gate), $50-flat cap, HD 40.
            return TierStats({upgradeFee: 0, deployCap: 5_000e18, defense: 40, garrisonSlots: 2});
        }
        // Row House: $15 fee / $150 cap, HD 60 (first step on the 40→120 ramp).
        return TierStats({upgradeFee: 1_500e18, deployCap: 15_000e18, defense: 60, garrisonSlots: 3});
    }

    // ---------------------------------------------------------------- mint / upgrade

    /// Free Safehouse, minted into the Don's 6551 — called by the HOUSE module (HouseEscrow) during
    /// first-play ensureHouse. One per Don, ever.
    function mintSafehouse(uint256 donId) external returns (uint256 deedId) {
        if (msg.sender != controller.moduleOf(GameRoles.HOUSE_MODULE)) revert NotHouseModule();
        if (deedOf[donId] != 0) revert AlreadyHasHouse();
        deedId = ++totalMinted;
        deedOf[donId] = deedId;
        donOf[deedId] = donId;
        // tier defaults to 0 (Safehouse)
        // _mint, not _safeMint (Audit fix — logic lens L-2, 2026-08-12): the deed is soulbound and
        // minted into a Don's own 6551 vault it can never leave, so the ERC721Received hook buys nothing
        // — but it fired mid-depart (before activeMissionOf/flags were set and the fee burned), a
        // reentrancy seam and a first-play self-DoS if a vault reverted in the hook. State is fully
        // written above, so a bare _mint is correct and closes the seam.
        _mint(don.vaultOf(donId), deedId);
        emit SafehouseClaimed(donId, deedId);
    }

    /// The paid upgrade (Safehouse -> Row House), in-place. Owner-only; the fee burns from the Don's
    /// banked Scrip (the vault). Blocked while the Don is away: HD and garrison slots are raid-window
    /// inputs and the garrison commit froze at depart — the House cannot change shape mid-window.
    function upgrade(uint256 donId) external {
        if (don.ownerOf(donId) != msg.sender) revert NotDonOwner();
        uint256 deedId = deedOf[donId];
        if (deedId == 0) revert NoHouse();
        uint8 cur = tier[deedId];
        if (cur >= MAX_TIER) revert AtMaxTier();
        address mission = controller.moduleOf(GameRoles.MISSION_MODULE);
        if (mission != address(0) && IMissionBoard(mission).isAway(donId)) revert DonIsAway();

        uint8 next = cur + 1;
        uint256 fee = tierStats(next).upgradeFee;
        scrip.burn(don.vaultOf(donId), fee); // Scrip-mode fee sink
        tier[deedId] = next;
        emit Upgraded(donId, deedId, next, fee);
    }

    // ---------------------------------------------------------------- game views (by donId)

    function tierOf(uint256 donId) public view returns (uint8) {
        uint256 deedId = deedOf[donId];
        if (deedId == 0) revert NoHouse();
        return tier[deedId];
    }

    function deployCapOf(uint256 donId) external view returns (uint256) {
        if (deedOf[donId] == 0) return 0; // no House, no exposure
        return tierStats(tierOf(donId)).deployCap;
    }

    function defenseOf(uint256 donId) external view returns (uint256) {
        if (deedOf[donId] == 0) return 0;
        return tierStats(tierOf(donId)).defense;
    }

    function garrisonSlotsOf(uint256 donId) external view returns (uint256) {
        if (deedOf[donId] == 0) return 0;
        return tierStats(tierOf(donId)).garrisonSlots;
    }

    // ---------------------------------------------------------------- soulbound (Phase 0)

    /// Phase-0 deeds never leave the vault they were minted into. The property market (withdrawal,
    /// listing, the 500-bps deed royalty class) is Phase-1 scope and arrives with the
    /// "withdraw only while home + hopper banked" root discipline.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0)) revert SoulboundInPhase0();
        return super._update(to, tokenId, auth);
    }
}
