// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GameRoles} from "./GameTypes.sol";

/// GameController — the generation registry.
///
/// One question, one seam: persistent contracts (Scrip, HouseDeed, HouseEscrow) never name mechanics
/// contracts directly — they ask `moduleOf(role)` / `isModule(addr)`. Upgrades are generational
/// deploys: a new MissionBoard/RaidEngine is pointed in at a season boundary, the old one is
/// close()d and drains via its permissionless reclaim paths. No proxies, ever, on money paths (the
/// Cases-v2 lesson).
///
/// THE ROLE LIST IS FIXED AT DEPLOY and can never grow: a module can be re-pointed, a new *power*
/// cannot be invented. The list reserves OUTFIT_MODULE now — Outfits
/// ship at Phase 1.5 into a slot that already exists — and SEASON_MODULE for the Phase-2 escrow.
///
/// Wiring discipline: deploy-time wiring is instant (the stack is assembled in one script run);
/// `seal()` is one-way, after which every re-point goes through the 2-day queue/execute timelock
/// (the DonDistributor `rootTimelock` precedent — propose publicly, commit after review).
contract GameController {
    uint256 public constant TIMELOCK = 2 days;

    address public admin;
    address public pendingAdmin;
    /// One-way: after sealing, module re-points require the timelock.
    bool public sealed_;
    /// Generational close: modules consult this before any NEW exposure (departs, raid commits,
    /// hitter mints, deploys). Exits, resolves, reclaims and bank() NEVER consult it — closing a
    /// generation can stop new play, never strand or gate an exit.
    bool public closed;

    mapping(bytes32 => bool) public isRole;
    mapping(bytes32 => address) public moduleOf;

    struct Pending {
        address module;
        uint64 eta;
    }

    mapping(bytes32 => Pending) public pendingModule;

    // Cached fixed list for the isModule() scan (8 slots, cheap).
    bytes32[8] private _roles;

    event ModuleSet(bytes32 indexed role, address indexed module);
    event ModuleQueued(bytes32 indexed role, address indexed module, uint64 eta);
    event Sealed();
    event Closed();
    event AdminProposed(address indexed pending);
    event AdminAccepted(address indexed admin);

    error NotAdmin();
    error UnknownRole();
    error AlreadySealed();
    error NotSealed();
    error NothingQueued();
    error TimelockActive();
    error NotPendingAdmin();
    error BadConfig();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address admin_) {
        if (admin_ == address(0)) revert BadConfig();
        admin = admin_;
        _roles = [
            GameRoles.MISSION_MODULE,
            GameRoles.RAID_MODULE,
            GameRoles.HOUSE_MODULE,
            GameRoles.DEED_MODULE,
            GameRoles.HITTER_MODULE,
            GameRoles.SEASON_MODULE,
            GameRoles.OUTFIT_MODULE,
            GameRoles.KEEPER
        ];
        for (uint256 i = 0; i < _roles.length; i++) {
            isRole[_roles[i]] = true;
        }
    }

    /// Instant wiring while unsealed (deploy-time assembly only). Reverts after seal().
    function setModule(bytes32 role, address module) external onlyAdmin {
        if (!isRole[role]) revert UnknownRole();
        if (sealed_) revert AlreadySealed();
        moduleOf[role] = module;
        emit ModuleSet(role, module);
    }

    /// Post-seal path: queue a re-point, execute after the 2-day public-review window.
    function queueModule(bytes32 role, address module) external onlyAdmin {
        if (!isRole[role]) revert UnknownRole();
        if (!sealed_) revert NotSealed();
        uint64 eta = uint64(block.timestamp + TIMELOCK);
        pendingModule[role] = Pending(module, eta);
        emit ModuleQueued(role, module, eta);
    }

    function executeModule(bytes32 role) external onlyAdmin {
        Pending memory p = pendingModule[role];
        if (p.eta == 0) revert NothingQueued();
        if (block.timestamp < p.eta) revert TimelockActive();
        delete pendingModule[role];
        moduleOf[role] = p.module;
        emit ModuleSet(role, p.module);
    }

    /// One-way: end the deploy-time assembly window; every later re-point is timelocked.
    function seal() external onlyAdmin {
        if (sealed_) revert AlreadySealed();
        sealed_ = true;
        emit Sealed();
    }

    /// Generational close: no NEW departs/commits/mints/deploys. Existing missions and raids
    /// resolve or reclaim normally; bank() and every exit stay open forever.
    function close() external onlyAdmin {
        closed = true;
        emit Closed();
    }

    /// Two-step admin handover (multisig in production).
    function proposeAdmin(address next) external onlyAdmin {
        pendingAdmin = next;
        emit AdminProposed(next);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminAccepted(msg.sender);
    }

    /// The Scrip mint/burn/move gate: true ONLY for the five money-path modules that legitimately move Scrip
    /// (mission payouts, raid transfers, house accrual, deed/hitter fee burns). The KEEPER role and the reserved
    /// SEASON/OUTFIT slots are DELIBERATELY EXCLUDED — the keeper is a hot operator key whose jobs (permissionless
    /// resolve, attestKit, garrison reveal) never touch Scrip, so it must never hold emission or transfer power.
    /// Granting it Scrip power via a whole-array scan would let a compromised keeper mint unbounded Scrip or drain
    /// any vault, bypassing every module-layer budget reservation. (Audit fix — auth lens, 2026-08-12.)
    function isModule(address account) external view returns (bool) {
        if (account == address(0)) return false;
        return account == moduleOf[GameRoles.MISSION_MODULE]
            || account == moduleOf[GameRoles.RAID_MODULE]
            || account == moduleOf[GameRoles.HOUSE_MODULE]
            || account == moduleOf[GameRoles.DEED_MODULE]
            || account == moduleOf[GameRoles.HITTER_MODULE];
    }
}
