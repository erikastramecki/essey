// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IDonLike,
    IGameController,
    IScrip,
    IHouseDeed,
    IMissionBoard,
    GameRoles
} from "./GameTypes.sol";

/// HouseEscrow — the game-contestable custody heart: two ledgers, one
/// custody pool, the Bell O(1) accrual pattern for House yield.
///
///   deployed[donId] — working capital the player moved Vault→House (robbable while the Don is away)
///   hopper[donId]   — mission loot + accrued yield, landed but not yet banked
///
/// Every Scrip unit in either ledger is physically held at this address (`scrip.balanceOf(escrow) ==
/// totalDeployed + totalHopper` — the Phase-1 audit invariant, enforced by construction: deploys move
/// in, loot/yield mint in, banks move out, raids move out, taxes burn out).
///
/// THE EXITS LAW — `bank()` is the sacred function:
/// free forever, no fee, no pause, no keeper in the path, no admin hook, and it does NOT consult
/// the generational `closed` flag. The only condition is the design law itself: the Don must be home
/// (away = the exposure the player chose at depart, and MissionBoard.reclaim guarantees every Don
/// always comes home even with a dead keeper). Any PR adding a fee or a gate to bank() is wrong by
/// definition.
///
/// House yield is a FUNDED BUDGET LINE, never a promise: the accrual index
/// advances at the launch rate only while `yieldBudget` covers the emission; when the budget runs
/// dry the index simply stops (the Phase-0 form of the deposit-cap valve — refuse new liability,
/// never dilute or owe). Budgets are funded by visible, admin-signed events (the S_declared line).
contract HouseEscrow is ReentrancyGuard {
    IGameController public immutable controller;
    IScrip public immutable scrip;
    IDonLike public immutable don;
    IHouseDeed public immutable deed;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRECISION = 1e18;

    /// Launch gross rate: 15 bps/day on effective deployed weight (the exposure frontier;
    /// floor/cap float arrives with the USDG-mode budget quotient in Phase 1).
    uint256 public constant RATE_BPS_PER_DAY = 15;
    /// Small-hit earning debuff: -40% until repaired.
    uint256 public constant DAMAGE_BPS = 4_000;
    /// Repair = 1.5 days of the House's gross earning, pro-rated by damage (the rate card).
    uint256 public constant REPAIR_DAYS_X10 = 15; // 1.5 days, x10 fixed point
    /// Hit tax on every raid transfer: 7.5% uniform, burned (the Scrip-mode fee sink).
    uint256 public constant HIT_TAX_BPS = 750;
    /// First-play starter stipend (the grinder faucet's Scrip-mode stand-in) — enough
    /// to cover early dispatch fees + a small provision, minted into the Don's vault once, ever.
    uint256 public constant STIPEND = 50e18;

    // ---- custody ledgers ----
    mapping(uint256 => uint256) public deployedOf;
    mapping(uint256 => uint256) public hopperOf;
    uint256 public totalDeployed;
    uint256 public totalHopper;

    // ---- earning (the Bell accumulator, per-House) ----
    mapping(uint256 => uint256) public weightOf; // deployed x (1 - damage)
    mapping(uint256 => uint256) public rewardDebt;
    uint256 public totalWeight;
    uint256 public accPerWeight; // 1e18 fixed
    uint64 public lastAccrual;

    // ---- condition ----
    mapping(uint256 => uint256) public damageBps; // 0 or DAMAGE_BPS
    /// Deployed principal FROZEN at the instant damage landed — the repair-fee basis (Audit fix,
    /// fund-safety lens F3, 2026-08-12). Scaling the fee off LIVE deployedOf let a damaged, home Don
    /// bank its deployed to 0 (free, ungated), zero out repairFeeOf, repair for nothing, then redeploy
    /// at full weight — the "steadiest sink in the game" was dodgeable at will. The snapshot is set by
    /// the raid outcome (attacker-triggered, not defender-timed) so banking after can't shrink it.
    mapping(uint256 => uint256) public damageBaseDeployed;

    // ---- budgets (funded emission lines) ----
    uint256 public yieldBudget;
    uint256 public stipendBudget;
    mapping(uint256 => bool) public stipendPaid;

    event Deployed(uint256 indexed donId, uint256 amount);
    event Banked(uint256 indexed donId, uint256 fromDeployed, uint256 fromHopper);
    event LootCredited(uint256 indexed donId, uint256 amount);
    event YieldAccrued(uint256 indexed donId, uint256 amount);
    event RaidApplied(uint256 indexed donId, uint8 outcome, uint256 taken, uint256 tax);
    event Damaged(uint256 indexed donId);
    event Repaired(uint256 indexed donId, uint256 fee);
    event StipendPaid(uint256 indexed donId, uint256 amount);
    event BudgetFunded(bytes32 indexed line, uint256 amount, uint256 newTotal);

    error NotDonOwner();
    error NotMissionModule();
    error NotRaidModule();
    error NotAdmin();
    error DonIsAway();
    error OverDeployCap();
    error InsufficientBalance();
    error NotDamaged();
    error GenerationClosed();
    error BadConfig();

    constructor(IGameController controller_, IScrip scrip_, IDonLike don_, IHouseDeed deed_) {
        if (
            address(controller_) == address(0) || address(scrip_) == address(0)
                || address(don_) == address(0) || address(deed_) == address(0)
        ) revert BadConfig();
        controller = controller_;
        scrip = scrip_;
        don = don_;
        deed = deed_;
        lastAccrual = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- modifiers / auth

    modifier onlyMission() {
        if (msg.sender != controller.moduleOf(GameRoles.MISSION_MODULE)) revert NotMissionModule();
        _;
    }

    modifier onlyRaid() {
        if (msg.sender != controller.moduleOf(GameRoles.RAID_MODULE)) revert NotRaidModule();
        _;
    }

    function _requireHome(uint256 donId) internal view {
        address mission = controller.moduleOf(GameRoles.MISSION_MODULE);
        if (mission != address(0) && IMissionBoard(mission).isAway(donId)) revert DonIsAway();
    }

    // ---------------------------------------------------------------- budgets (S_declared lines)

    /// Fund the House-yield emission line. Admin-only and LOUD — every top-up is the visible,
    /// signed subsidy/budget event the economy model demands (never an open-ended rate promise).
    function fundYieldBudget(uint256 amount) external {
        if (msg.sender != controller.admin()) revert NotAdmin();
        yieldBudget += amount;
        emit BudgetFunded("YIELD", amount, yieldBudget);
    }

    function fundStipendBudget(uint256 amount) external {
        if (msg.sender != controller.admin()) revert NotAdmin();
        stipendBudget += amount;
        emit BudgetFunded("STIPEND", amount, stipendBudget);
    }

    // ---------------------------------------------------------------- first play

    /// Idempotent first-play setup, called by MissionBoard inside the first depart tx: the free
    /// Safehouse (the funnel gate) + the one-time starter stipend into the Don's vault.
    function ensureHouse(uint256 donId) external onlyMission {
        if (deed.deedOf(donId) == 0) {
            deed.mintSafehouse(donId);
        }
        if (!stipendPaid[donId] && stipendBudget >= STIPEND) {
            stipendPaid[donId] = true;
            stipendBudget -= STIPEND;
            scrip.mint(don.vaultOf(donId), STIPEND);
            emit StipendPaid(donId, STIPEND);
        }
    }

    // ---------------------------------------------------------------- deploy / bank / repair

    /// Vault -> House: move banked Scrip into the contestable domain, up to the deed's cap. This is
    /// the player's explicit exposure choice — everything raidable traces back to this tx (or to
    /// loot they chose not to bank yet).
    function deploy(uint256 donId, uint256 amount) external nonReentrant {
        if (don.ownerOf(donId) != msg.sender) revert NotDonOwner();
        if (controller.closed()) revert GenerationClosed(); // no NEW exposure in a closed generation
        _requireHome(donId);
        _accrue();
        _checkpoint(donId);
        uint256 newDeployed = deployedOf[donId] + amount;
        if (newDeployed > deed.deployCapOf(donId)) revert OverDeployCap();
        deployedOf[donId] = newDeployed;
        totalDeployed += amount;
        scrip.move(don.vaultOf(donId), address(this), amount);
        _syncWeight(donId);
        emit Deployed(donId, amount);
    }

    /// THE SACRED FUNCTION — House -> Vault, free forever (the zero-fee exit
    /// law). No fee, no pause, no closed-flag, no admin path, no keeper dependency. The single
    /// requirement is the design law: the Don is home (and MissionBoard.reclaim guarantees "home"
    /// is always reachable, keeper or no keeper).
    function bank(uint256 donId, uint256 fromDeployed, uint256 fromHopper) external nonReentrant {
        if (don.ownerOf(donId) != msg.sender) revert NotDonOwner();
        _requireHome(donId);
        _accrue();
        _checkpoint(donId); // realize pending yield into the hopper first, so it banks too
        if (deployedOf[donId] < fromDeployed || hopperOf[donId] < fromHopper) revert InsufficientBalance();
        unchecked {
            deployedOf[donId] -= fromDeployed;
            hopperOf[donId] -= fromHopper;
        }
        totalDeployed -= fromDeployed;
        totalHopper -= fromHopper;
        scrip.move(address(this), don.vaultOf(donId), fromDeployed + fromHopper);
        _syncWeight(donId);
        emit Banked(donId, fromDeployed, fromHopper);
    }

    /// Clear the small-hit debuff. Fee = 1.5 days of the House's gross earning pro-rated by damage,
    /// burned from the Don's banked Scrip. The steadiest sink in the game.
    function repair(uint256 donId) external nonReentrant {
        if (don.ownerOf(donId) != msg.sender) revert NotDonOwner();
        if (damageBps[donId] == 0) revert NotDamaged();
        _accrue();
        _checkpoint(donId);
        uint256 fee = repairFeeOf(donId);
        if (fee > 0) scrip.burn(don.vaultOf(donId), fee); // Scrip-mode fee sink
        damageBps[donId] = 0;
        damageBaseDeployed[donId] = 0; // basis consumed with the debuff (F3)
        _syncWeight(donId);
        emit Repaired(donId, fee);
    }

    /// dailyGross x 1.5 x (damage / DAMAGE_BPS). With damage always DAMAGE_BPS in Phase 0 this is
    /// 1.5 days of gross earning at the launch rate.
    function repairFeeOf(uint256 donId) public view returns (uint256) {
        // Basis is the deployed frozen at damage-time (F3 fix), NOT live deployedOf — otherwise banking
        // to 0 before repairing makes the fee 0.
        uint256 dailyGross = (damageBaseDeployed[donId] * RATE_BPS_PER_DAY) / BPS;
        return (dailyGross * REPAIR_DAYS_X10 * damageBps[donId]) / (10 * DAMAGE_BPS);
    }

    // ---------------------------------------------------------------- module powers (one each)

    /// MissionBoard's single power: land mission loot in the hopper. The board mints the Scrip to
    /// this address (from its reserved budget) in the same tx.
    function creditLoot(uint256 donId, uint256 amount) external onlyMission {
        hopperOf[donId] += amount;
        totalHopper += amount;
        emit LootCredited(donId, amount);
    }

    /// RaidEngine's common hit ("they cracked the back office"): the hopper — unbanked yield and
    /// loot, never principal — transfers to the attacker, minus the 7.5% hit tax (burned), and the
    /// House takes the -40% earning debuff until repaired.
    function applyRaidCommon(uint256 targetDonId, address attackerVault)
        external
        onlyRaid
        nonReentrant
        returns (uint256 taken, uint256 tax)
    {
        _accrue();
        _checkpoint(targetDonId);
        taken = hopperOf[targetDonId];
        if (taken > 0) {
            hopperOf[targetDonId] = 0;
            totalHopper -= taken;
            tax = (taken * HIT_TAX_BPS) / BPS;
            scrip.burn(address(this), tax); // the fee sink eats with the raider
            scrip.move(address(this), attackerVault, taken - tax);
        }
        damageBps[targetDonId] = DAMAGE_BPS;
        damageBaseDeployed[targetDonId] = deployedOf[targetDonId]; // freeze the repair-fee basis (F3)
        _syncWeight(targetDonId);
        emit Damaged(targetDonId);
        emit RaidApplied(targetDonId, 0, taken, tax);
    }

    /// RaidEngine's big score ("they found the safe"): a capped slice of DEPLOYED only — principal
    /// moves, hit-taxed, raids reassign and never mint. Slice band is the engine's job; this side
    /// hard-caps at 30% (the Scrip-band ceiling).
    function applyRaidBig(uint256 targetDonId, address attackerVault, uint256 sliceBps)
        external
        onlyRaid
        nonReentrant
        returns (uint256 taken, uint256 tax)
    {
        if (sliceBps > 3_000) revert BadConfig();
        _accrue();
        _checkpoint(targetDonId);
        taken = (deployedOf[targetDonId] * sliceBps) / BPS;
        if (taken > 0) {
            deployedOf[targetDonId] -= taken;
            totalDeployed -= taken;
            tax = (taken * HIT_TAX_BPS) / BPS;
            scrip.burn(address(this), tax);
            scrip.move(address(this), attackerVault, taken - tax);
        }
        _syncWeight(targetDonId);
        emit RaidApplied(targetDonId, 1, taken, tax);
    }

    /// DEAD IN THIS GENERATION (kept so source matches the 2026-08-13 testnet bytecode): the H-1
    /// audit fixes made the garrison-timeout path run the real roll, so nothing calls this anymore.
    /// Still onlyRaid-gated => harmless. REMOVE at the next generational deploy.
    function applyDamage(uint256 targetDonId) external onlyRaid nonReentrant {
        _accrue();
        _checkpoint(targetDonId);
        damageBps[targetDonId] = DAMAGE_BPS;
        damageBaseDeployed[targetDonId] = deployedOf[targetDonId]; // freeze the repair-fee basis (F3)
        _syncWeight(targetDonId);
        emit Damaged(targetDonId);
    }

    // ---------------------------------------------------------------- views

    /// Pending (unrealized) yield — what the next checkpoint will land in the hopper.
    function pendingYieldOf(uint256 donId) external view returns (uint256) {
        uint256 acc = accPerWeight;
        if (block.timestamp > lastAccrual && totalWeight > 0 && yieldBudget > 0) {
            uint256 delta =
                (RATE_BPS_PER_DAY * (block.timestamp - lastAccrual) * PRECISION) / (BPS * 1 days);
            uint256 emission = (delta * totalWeight) / PRECISION;
            if (emission > yieldBudget) delta = (yieldBudget * PRECISION) / totalWeight;
            acc += delta;
        }
        return (weightOf[donId] * acc) / PRECISION - rewardDebt[donId];
    }

    // ---------------------------------------------------------------- internals (the Bell pattern)

    /// Advance the global index at the launch rate, clamped by the remaining budget — the Phase-0
    /// valve: an unfunded budget stops the index, it never mints an IOU.
    function _accrue() internal {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs == lastAccrual) return;
        if (totalWeight == 0 || yieldBudget == 0) {
            lastAccrual = nowTs;
            return;
        }
        uint256 elapsed = nowTs - lastAccrual;
        lastAccrual = nowTs;
        uint256 delta = (RATE_BPS_PER_DAY * elapsed * PRECISION) / (BPS * 1 days);
        uint256 emission = (delta * totalWeight) / PRECISION;
        if (emission > yieldBudget) {
            delta = (yieldBudget * PRECISION) / totalWeight;
            emission = (delta * totalWeight) / PRECISION;
        }
        yieldBudget -= emission;
        accPerWeight += delta;
    }

    /// Realize a House's accrued yield into its hopper (minted here, budget-accounted in _accrue).
    function _checkpoint(uint256 donId) internal {
        uint256 w = weightOf[donId];
        if (w != 0) {
            uint256 pending = (w * accPerWeight) / PRECISION - rewardDebt[donId];
            if (pending > 0) {
                scrip.mint(address(this), pending);
                hopperOf[donId] += pending;
                totalHopper += pending;
                emit YieldAccrued(donId, pending);
            }
        }
        rewardDebt[donId] = (w * accPerWeight) / PRECISION;
    }

    /// Recompute effective earning weight after any deployed/damage change (checkpoint first!).
    function _syncWeight(uint256 donId) internal {
        uint256 newW = (deployedOf[donId] * (BPS - damageBps[donId])) / BPS;
        totalWeight = totalWeight - weightOf[donId] + newW;
        weightOf[donId] = newW;
        rewardDebt[donId] = (newW * accPerWeight) / PRECISION;
    }
}
