// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// D.O.N. Skirmish — Phase-0 shared surface (interfaces + the fixed role vocabulary).
///
/// Phase 0 is the Scrip-only playable core ("Skirmish v2"): mission board +
/// House/Vault + one raid type (house robbery in the away window) + season-scoped points. No items,
/// no marketplace, no Specialists, no Outfits, no real assets — but every interface below leaves the
/// seam its Phase-1 hardening needs (see per-contract notes).

/// The character layer — the deployed Don collection satisfies this (ERC721 ownerOf + token-bound
/// 6551 vault), same shape the Bell consumes via ISeatLike. The game never takes custody of the NFT.
interface IDonLike {
    function ownerOf(uint256 id) external view returns (address);
    function vaultOf(uint256 id) external view returns (address);
}

/// The generation registry: fixed role list, timelocked
/// re-pointing, generational close(). Persistent contracts never name mechanics contracts directly —
/// they ask this one question: who currently holds operator powers over me?
interface IGameController {
    function admin() external view returns (address);
    function closed() external view returns (bool);
    function moduleOf(bytes32 role) external view returns (address);
    function isModule(address account) external view returns (bool);
}

/// The fixed role vocabulary. IMMUTABLE at deploy: the reserved
/// OUTFIT_MODULE slot must exist NOW (the list can never grow), even though no Outfit contract ships
/// before Phase 1.5. SEASON_MODULE is likewise reserved for the Phase-2 SeasonEscrow.
library GameRoles {
    bytes32 internal constant MISSION_MODULE = "MISSION_MODULE";
    bytes32 internal constant RAID_MODULE = "RAID_MODULE";
    bytes32 internal constant HOUSE_MODULE = "HOUSE_MODULE"; // HouseEscrow
    bytes32 internal constant DEED_MODULE = "DEED_MODULE"; // HouseDeed (burns upgrade fees)
    bytes32 internal constant HITTER_MODULE = "HITTER_MODULE";
    bytes32 internal constant SEASON_MODULE = "SEASON_MODULE"; // reserved (Phase 2)
    bytes32 internal constant OUTFIT_MODULE = "OUTFIT_MODULE"; // reserved (Phase 1.5)
    bytes32 internal constant KEEPER = "KEEPER";
}

/// Season-scoped, non-transferable points. Mint/burn/move only by
/// registered game modules; raids move, missions mint from budget, fees burn (the Scrip-mode sink).
interface IScrip {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function move(address from, address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function seasonId() external view returns (uint256);
}

interface IHouseDeed {
    function mintSafehouse(uint256 donId) external returns (uint256 deedId);
    function deedOf(uint256 donId) external view returns (uint256);
    function tierOf(uint256 donId) external view returns (uint8);
    function deployCapOf(uint256 donId) external view returns (uint256);
    function defenseOf(uint256 donId) external view returns (uint256);
    function garrisonSlotsOf(uint256 donId) external view returns (uint256);
}

interface IHouseEscrow {
    function ensureHouse(uint256 donId) external;
    function creditLoot(uint256 donId, uint256 amount) external;
    function applyRaidCommon(uint256 targetDonId, address attackerVault)
        external
        returns (uint256 taken, uint256 tax);
    function applyRaidBig(uint256 targetDonId, address attackerVault, uint256 sliceBps)
        external
        returns (uint256 taken, uint256 tax);
    function applyDamage(uint256 targetDonId) external;
    function deployedOf(uint256 donId) external view returns (uint256);
    function hopperOf(uint256 donId) external view returns (uint256);
}

interface IMissionBoard {
    function isAway(uint256 donId) external view returns (bool);
    /// The garrison commit frozen at depart (the gas law): zero while home or if the player
    /// departed ungarrisoned (public information, priced by the player's own choice).
    function garrisonHashOf(uint256 donId) external view returns (bytes32);
}

interface IHitterGame {
    function ownerOf(uint256 id) external view returns (address);
    function lastAttemptAt(uint256 id) external view returns (uint64);
    function hospitalUntil(uint256 id) external view returns (uint64);
    function noteAttempt(uint256 id) external;
    function hospitalize(uint256 id) external;
}
