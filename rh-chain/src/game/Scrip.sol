// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IGameController, GameRoles} from "./GameTypes.sol";

/// Scrip — season-scoped, NON-TRANSFERABLE game points (contracts-architecture §2.13). Phase 0's
/// entire settlement asset (the ruled two-tier currency, A3: routine play prices in Scrip; $ESSEY
/// and USDG never enter the Phase-0 loop).
///
/// Design laws in code:
///  - NOT an ERC-20. There is no transfer, no approve, no allowance — a player can never sell,
///    bridge, or wash-trade Scrip. Balances move only through registered game modules, each of which
///    holds one narrowly-scoped power (missions mint from budget, raids MOVE — never mint — and fees
///    BURN, the Scrip-mode fee sink per economy §9.1 A1).
///  - Balances are keyed (seasonId, account): season close is an O(1) global reset (bump the key);
///    old seasons stay readable for archives via `balanceOfAt`.
///  - Scrip emission is not a solvency liability (RNG bible units convention) — but emission is
///    still budget-gated at the MODULE layer (MissionBoard/HouseEscrow reserve worst-case before any
///    roll), so this contract enforces the WHO, the modules enforce the HOW MUCH.
///
/// Display peg (accounting convention only, never an exchange rate): 1 Scrip ≈ 0.01 USDG-mark.
/// 18 decimals so Scrip math composes with the repo's token idioms.
contract Scrip {
    string public constant name = "D.O.N. Scrip";
    string public constant symbol = "SCRIP";
    uint8 public constant decimals = 18;

    IGameController public immutable controller;

    uint256 public seasonId = 1;

    /// season => account => balance. Accounts are wallet addresses AND Don 6551 vault addresses —
    /// a Don's banked Scrip lives at its vault, so "sell the Don, sell the portfolio" holds for
    /// points too.
    mapping(uint256 => mapping(address => uint256)) public balanceOfAt;
    mapping(uint256 => uint256) public totalSupplyAt;
    /// Cumulative fee-sink burns per season — the economy dashboard's Scrip-mode revenue line.
    mapping(uint256 => uint256) public burnedAt;

    event Minted(address indexed to, uint256 amount, address indexed module);
    event Burned(address indexed from, uint256 amount, address indexed module);
    event Moved(address indexed from, address indexed to, uint256 amount, address indexed module);
    event SeasonClosed(uint256 indexed oldSeason, uint256 indexed newSeason);

    error NotModule();
    error NotSeasonAuthority();
    error InsufficientScrip();
    error BadConfig();

    modifier onlyModule() {
        if (!controller.isModule(msg.sender)) revert NotModule();
        _;
    }

    constructor(IGameController controller_) {
        if (address(controller_) == address(0)) revert BadConfig();
        controller = controller_;
    }

    // ---------------------------------------------------------------- views (current season)

    function balanceOf(address account) public view returns (uint256) {
        return balanceOfAt[seasonId][account];
    }

    function totalSupply() external view returns (uint256) {
        return totalSupplyAt[seasonId];
    }

    function totalBurned() external view returns (uint256) {
        return burnedAt[seasonId];
    }

    // ---------------------------------------------------------------- module powers

    function mint(address to, uint256 amount) external onlyModule {
        if (to == address(0)) revert BadConfig();
        balanceOfAt[seasonId][to] += amount;
        totalSupplyAt[seasonId] += amount;
        emit Minted(to, amount, msg.sender);
    }

    /// Burn = the Scrip-mode fee sink (dispatch fees, hit tax, repair fees, mint prices all land
    /// here per the rate card). Also how provisions are consumed at dispatch.
    function burn(address from, uint256 amount) external onlyModule {
        uint256 bal = balanceOfAt[seasonId][from];
        if (bal < amount) revert InsufficientScrip();
        unchecked {
            balanceOfAt[seasonId][from] = bal - amount;
        }
        totalSupplyAt[seasonId] -= amount;
        burnedAt[seasonId] += amount;
        emit Burned(from, amount, msg.sender);
    }

    /// Reassignment without emission — the raid law: raids move value between players, they can
    /// never mint it (solvency law, contracts-architecture §3).
    function move(address from, address to, uint256 amount) external onlyModule {
        if (to == address(0)) revert BadConfig();
        uint256 bal = balanceOfAt[seasonId][from];
        if (bal < amount) revert InsufficientScrip();
        unchecked {
            balanceOfAt[seasonId][from] = bal - amount;
        }
        balanceOfAt[seasonId][to] += amount;
        emit Moved(from, to, amount, msg.sender);
    }

    // ---------------------------------------------------------------- season boundary

    /// O(1) season reset: bump the key. Callable ONLY by the SEASON_MODULE (Phase 2's escrow), never the
    /// admin. In Phase 0 no SEASON_MODULE is wired, so this is uncallable — deliberately. (Audit fix,
    /// fund-safety lens 2026-08-12: an admin fallback was a footgun — HouseEscrow's ledgers are NOT
    /// season-scoped, so a bare season bump would zero escrow's current-season balance while its
    /// deployed/hopper ledgers still claim the old amounts, permanently bricking bank() — the sacred exit.
    /// The Phase-2 SEASON_MODULE MUST settle/migrate all escrow custody BEFORE it may call this.)
    function closeSeason() external {
        if (msg.sender != controller.moduleOf(GameRoles.SEASON_MODULE)) {
            revert NotSeasonAuthority();
        }
        uint256 old = seasonId;
        seasonId = old + 1;
        emit SeasonClosed(old, old + 1);
    }
}
