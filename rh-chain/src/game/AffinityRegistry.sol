// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAffinityRegistry, IDonTraits} from "./IAffinityRegistry.sol";
import {AffinityTraits} from "./AffinityTraits.sol";
import {IGameController} from "./GameTypes.sol";

/// AffinityRegistry — the per-Don stat sheet every v2 raid contract reads (D.O.N. v2 workstream 1c).
///
/// ============================================================================================
/// 1. TRAIT SOURCING: PERMISSIONLESS PREIMAGE ATTESTATION — NO TRUSTED PARTY
/// ============================================================================================
/// Where the build plan was ambiguous it is resolved toward zero trust; see AffinityTraits.sol for
/// the full derivation. In one line: a Don's traits are already committed on-chain as
/// `Don.traits(id)`, the commitment's preimage is a plain byte string, and both hash steps
/// (sha256 then keccak256 over lowercase hex) are EVM-native. So `attest()` takes the preimage from
/// ANYONE, recomputes the commitment, and refuses anything that does not match the collection's own
/// bytes. Nobody can grant a stat, nobody can withhold one, and the sheet a Don gets is a pure
/// function of the art it already owns.
///
/// A rerolled Don's stored sheet goes STALE the instant `Don.traits` changes; every read path checks
/// that (or short-circuits once `Don.locked` has frozen the traits forever, which is the D7 end
/// state). A player therefore cannot attest a god-roll and then reroll away from it.
///
/// ============================================================================================
/// 2. THE EDGE BUDGET IS ENFORCED HERE, BY CONSTRUCTION
/// ============================================================================================
/// Law 3 (ruled D1): traits + Favor + items sum on ONE saturating curve — <= +10pp of odds shift,
/// fee-discount stack <= 25%, ItemMult <= x1.35. This contract stores the RAW derivation and clamps
/// on the way OUT, so:
///   * every value any game contract can read is already inside the budget — a caller cannot break
///     the law by mistake, and the law is testable as a property over the whole combo space;
///   * when the sum of a Don's odds-affecting stats exceeds the budget, all of them are scaled down
///     PROPORTIONALLY. That is the law's own sentence rendered as arithmetic: traits shift WHERE
///     your edge lives, never how much of it you have. Offence and defence saturate identically.
///   * `rawStatsOf` exposes the unclamped derivation for display and telemetry only.
/// Nothing here can reach an RTP surface, the 7.5% hit tax, or a cash-flow rate (YLD is capacity and
/// fee-side only — ruling D8/T-5).
///
/// ============================================================================================
/// 3. KNOBS (law B11): IMMUTABLE BOUNDS, BOUNDED VALUES
/// ============================================================================================
/// The three budget ceilings are immutable constants — the ruled numbers, forever. The ACTIVE budget
/// values are setters bounded by them, so a season can be tuned TIGHTER without migrating a contract,
/// and can never be tuned looser than the ruling. There is no setter for a stat, a trait, a
/// destination or a fund: this contract holds no value and has no withdrawal path.
contract AffinityRegistry is IAffinityRegistry {
    using AffinityTraits for AffinityTraits.Raw;

    // ------------------------------------------------------------------ RaidEngine units (mirrored)

    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant BASE_POWER = 50; // RaidEngine.BASE_POWER
    uint256 internal constant GARRISON_EFF_BPS = 9_500; // RaidEngine.GARRISON_EFF_BPS
    uint256 internal constant P_COEF_PPM = 720_000; // RaidEngine.P_COEF_PPM
    uint256 internal constant P_MIN_PPM = 50_000;
    uint256 internal constant P_MAX_PPM = 700_000;
    uint256 internal constant KILL_BASE_PPM = 150_000;
    uint256 internal constant KILL_SLOPE_PPM = 350_000;
    uint256 internal constant MAX_CREW = 5;
    uint256 internal constant HOSPITAL = 48 hours; // HitterNFT hospital lockout

    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------ Edge-Budget BOUNDS (immutable)

    /// +10pp of odds shift, expressed in bps of probability. The ruled ceiling (D1) — forever.
    uint16 public constant ODDS_BUDGET_MAX = 1_000;
    /// A season may tighten the budget but never below a fifth of it (a floor stops a silent nerf to 0).
    uint16 public constant ODDS_BUDGET_MIN = 200;
    /// The fee-discount stack ceiling, 25%.
    uint16 public constant FEE_STACK_MAX = 2_500;
    /// The item multiplier ceiling, x1.35 (read by the item/kit layer; the registry only publishes it).
    uint16 public constant ITEM_MULT_MAX = 13_500;
    uint16 public constant ITEM_MULT_MIN = 10_000;

    // ---- the conversion from a stat to its share of the ODDS budget (Part A's own reading rule).
    // RP: +8% A moves median p_hit ~1.2pp  ->  15 bps of odds per 1% of A.
    // HD: +15% D moves it ~2.4pp the other way -> 16 bps of odds per 1% of D. Offence and defence are
    // the same size by construction, which is the whole game (Part A, reading rule).
    uint256 internal constant RP_ODDS_PER_PCT = 15;
    uint256 internal constant HD_ODDS_PER_PCT = 16;
    /// A flat HD point priced against the Part-F reference House (Row House + 3 garrison ~ 200):
    /// 1 point = 0.5% of D = 8 bps of odds.
    uint256 internal constant HD_FLAT_ODDS = 8;
    uint256 internal constant REF_DEFENSE = 200;

    // ------------------------------------------------------------------ wiring + state

    IGameController public immutable controller;
    IDonTraits public immutable don;

    /// The bounded VALUES. Openable only inside the bounds above.
    uint16 public oddsBudgetBps = ODDS_BUDGET_MAX;
    uint16 public feeStackCapBps = FEE_STACK_MAX;
    uint16 public itemMultCapBps = ITEM_MULT_MAX;

    mapping(uint256 => Stats) private _sheet;
    mapping(uint256 => bytes32) public sheetCombo;
    mapping(uint256 => bool) public frozen;

    error BadConfig();
    error NotAdmin();
    error UnknownDon();
    error ComboMismatch();
    error AlreadyAttested();
    error OutOfBounds();

    constructor(IGameController controller_, IDonTraits don_) {
        if (address(controller_) == address(0) || address(don_) == address(0)) revert BadConfig();
        controller = controller_;
        don = don_;
    }

    modifier onlyAdmin() {
        if (msg.sender != controller.admin()) revert NotAdmin();
        _;
    }

    // ==================================================================== the write path

    /// @inheritdoc IAffinityRegistry
    function attest(uint256 donId, bytes calldata preimage) external {
        bytes32 committed = don.traits(donId);
        if (committed == bytes32(0)) revert UnknownDon();
        if (sheetCombo[donId] == committed) revert AlreadyAttested();
        // THE ENTIRE TRUST MODEL: the submitted bytes must reproduce the collection's own commitment.
        if (AffinityTraits.commitmentOf(preimage) != committed) revert ComboMismatch();

        Stats memory s = AffinityTraits.toStats(AffinityTraits.decode(preimage));
        _sheet[donId] = s;
        sheetCombo[donId] = committed;
        // Once the collection has frozen the traits (D7 "staking locks the art") the sheet can never go
        // stale, so reads may skip the staleness check forever after.
        if (don.locked(donId)) frozen[donId] = true;

        emit Attested(donId, committed, s.archetype, s.flags);
    }

    /// Record a lock that happened after attestation, so reads stop paying for the staleness check.
    /// Permissionless and idempotent-safe: it can only ever be called truthfully.
    function refreshFreeze(uint256 donId) external {
        if (sheetCombo[donId] == bytes32(0)) revert UnknownDon();
        if (sheetCombo[donId] != don.traits(donId)) revert ComboMismatch();
        if (!don.locked(donId)) revert ComboMismatch();
        frozen[donId] = true;
    }

    // ==================================================================== sheet reads

    /// The live sheet, or an all-zero sheet when the Don was never attested or has been rerolled since.
    function _live(uint256 donId) internal view returns (Stats memory s) {
        bytes32 c = sheetCombo[donId];
        if (c == bytes32(0)) return s;
        if (!frozen[donId] && don.traits(donId) != c) return s; // stale after a reroll — grant nothing
        s = _sheet[donId];
    }

    function rawStatsOf(uint256 donId) public view returns (Stats memory) {
        return _live(donId);
    }

    function statsOf(uint256 donId) public view returns (Stats memory) {
        return _clamp(_live(donId));
    }

    function isAttested(uint256 donId) external view returns (bool) {
        return sheetCombo[donId] != bytes32(0) && (frozen[donId] || don.traits(donId) == sheetCombo[donId]);
    }

    function archetypeOf(uint256 donId) external view returns (Archetype) {
        return Archetype(_live(donId).archetype);
    }

    function oddsEdgeBps(uint256 donId) external view returns (uint256) {
        return edgeOf(statsOf(donId));
    }

    // ==================================================================== the Edge Budget

    /// The odds-shift a sheet consumes, in bps of probability. This is the quantity law 3 bounds.
    function edgeOf(Stats memory s) public pure returns (uint256) {
        return (uint256(s.rpBps) * RP_ODDS_PER_PCT) / 100 + (uint256(s.hdBps) * HD_ODDS_PER_PCT) / 100
            + (uint256(s.cmdGarrisonBps) * HD_ODDS_PER_PCT) / 100 + uint256(s.hdFlat) * HD_FLAT_ODDS
            + uint256(s.nrvBps) + uint256(s.cmdFactionBps) + uint256(s.lckBps);
    }

    /// Saturate a sheet onto the budget. Proportional, so the SHAPE of a build survives and only its
    /// TOTAL is bounded — "traits shift where your edge lives, never total power".
    function _clamp(Stats memory s) internal view returns (Stats memory) {
        uint256 budget = oddsBudgetBps;
        uint256 e = edgeOf(s);
        if (e > budget) {
            s.rpBps = uint16((uint256(s.rpBps) * budget) / e);
            s.hdBps = uint16((uint256(s.hdBps) * budget) / e);
            s.hdFlat = uint16((uint256(s.hdFlat) * budget) / e);
            s.nrvBps = uint16((uint256(s.nrvBps) * budget) / e);
            s.lckBps = uint16((uint256(s.lckBps) * budget) / e);
            s.cmdGarrisonBps = uint16((uint256(s.cmdGarrisonBps) * budget) / e);
            s.cmdFactionBps = uint16((uint256(s.cmdFactionBps) * budget) / e);
        }
        uint16 feeCap = feeStackCapBps;
        if (s.feeDiscBps > feeCap) s.feeDiscBps = feeCap;
        return s;
    }

    // ==================================================================== reader helpers

    function applyRaidPower(uint256 donId, uint256 basePower) external view returns (uint256) {
        return basePower + (basePower * statsOf(donId).rpBps) / BPS;
    }

    function applyHouseDefense(uint256 donId, uint256 baseDefense) external view returns (uint256) {
        Stats memory s = statsOf(donId);
        uint256 d = baseDefense + uint256(s.hdFlat) * PPM; // flat first ...
        return d + (d * s.hdBps) / BPS; // ... then percent (the Part-F ordering)
    }

    function applyGarrison(uint256 donId, uint256 garrisonPower) external view returns (uint256) {
        return garrisonPower + (garrisonPower * statsOf(donId).cmdGarrisonBps) / BPS;
    }

    function applyCooldown(uint256 donId, uint256 cooldown) external view returns (uint256) {
        return cooldown - (cooldown * statsOf(donId).cmdCooldownBps) / BPS;
    }

    function applyHospital(uint256 donId, uint256 lockout) external view returns (uint256) {
        return lockout - (lockout * statsOf(donId).resHospBps) / BPS;
    }

    function applyPetrify(uint256 defenderDonId, uint256 lockout) external view returns (uint256) {
        return lockout + (lockout * statsOf(defenderDonId).resPetrifyBps) / BPS;
    }

    function applyFeeDiscount(uint256 donId, uint256 fee) external view returns (uint256) {
        return fee - (fee * statsOf(donId).feeDiscBps) / BPS;
    }

    function nerveBps(uint256 donId) external view returns (uint256) {
        return statsOf(donId).nrvBps;
    }

    function factionBps(uint256 donId) external view returns (uint256) {
        return statsOf(donId).cmdFactionBps;
    }

    function luckBps(uint256 donId) external view returns (uint256) {
        return statsOf(donId).lckBps;
    }

    function ambushBps(uint256 donId) external view returns (uint256) {
        return statsOf(donId).resAmbushBps;
    }

    function feeDiscountBps(uint256 donId) external view returns (uint256) {
        return statsOf(donId).feeDiscBps;
    }

    function yieldCapSteps(uint256 donId) external view returns (uint256) {
        return statsOf(donId).yldCapSteps;
    }

    function guileTier(uint256 donId) external view returns (uint8) {
        return statsOf(donId).guiTier;
    }

    function counterRecon(uint256 donId) external view returns (bool) {
        return _live(donId).flags & AffinityTraits.F_COUNTER_RECON != 0;
    }

    function unscoutable(uint256 donId) external view returns (bool) {
        return _live(donId).flags & AffinityTraits.F_UNSCOUTABLE != 0;
    }

    function scoutLite(uint256 donId) external view returns (bool) {
        return _live(donId).flags & AffinityTraits.F_SCOUT_LITE != 0;
    }

    // ==================================================================== Skirmish preview (no state)

    /// @inheritdoc IAffinityRegistry
    function previewSheet(bytes calldata preimage) external view returns (Stats memory) {
        return _clamp(AffinityTraits.toStats(AffinityTraits.decode(preimage)));
    }

    /// The commitment a preimage produces — the builder panel's "is this the Don I own" check.
    function commitmentOf(bytes calldata preimage) external pure returns (bytes32) {
        return AffinityTraits.commitmentOf(preimage);
    }

    function previewVsGarrison(uint256 attackerDonId, GarrisonClass class_, uint256 crewSize)
        external
        view
        returns (Skirmish memory)
    {
        (uint256 deedDefense, uint256 garrisonSize) = referenceGarrison(class_);
        Stats memory bare;
        return skirmish(statsOf(attackerDonId), bare, crewSize, garrisonSize, deedDefense);
    }

    function previewDuel(
        uint256 attackerDonId,
        uint256 defenderDonId,
        uint256 crewSize,
        uint256 garrisonSize,
        uint256 deedDefense
    ) external view returns (Skirmish memory) {
        return skirmish(statsOf(attackerDonId), statsOf(defenderDonId), crewSize, garrisonSize, deedDefense);
    }

    /// The reference Houses the preview panel offers: the live Phase-0 HouseDeed tier stats.
    function referenceGarrison(GarrisonClass class_)
        public
        pure
        returns (uint256 deedDefense, uint256 garrisonSize)
    {
        if (class_ == GarrisonClass.BARE_SAFEHOUSE) return (40, 0);
        if (class_ == GarrisonClass.GUARDED_SAFEHOUSE) return (40, 2);
        if (class_ == GarrisonClass.OPEN_ROW_HOUSE) return (60, 0);
        return (60, 3); // FORTRESS_ROW_HOUSE — the Part-F worked example
    }

    /// The whole duel, over hypothetical sheets. PURE READ MATH: no storage writes, no side effects,
    /// and it re-implements nothing — the formula is RaidEngine's own, with the trait modifiers in.
    function skirmish(
        Stats memory attacker,
        Stats memory defender,
        uint256 crewSize,
        uint256 garrisonSize,
        uint256 deedDefense
    ) public view returns (Skirmish memory out) {
        if (crewSize > MAX_CREW) crewSize = MAX_CREW;
        // Clamp BOTH sides here too: the preview is a public entry point that accepts hand-made sheets,
        // and a preview that could quote an out-of-budget number would be a lie about the game.
        attacker = _clamp(attacker);
        defender = _clamp(defender);

        uint256 aBase = crewSize * BASE_POWER * PPM; // a fresh crew: cooldownPpm == PPM
        uint256 garrison = (garrisonSize * BASE_POWER * PPM * GARRISON_EFF_BPS) / BPS;
        uint256 dBase = deedDefense * PPM + garrison;

        uint256 a = aBase + (aBase * attacker.rpBps) / BPS;
        uint256 g = garrison + (garrison * defender.cmdGarrisonBps) / BPS;
        uint256 d = deedDefense * PPM + g + uint256(defender.hdFlat) * PPM;
        d += (d * defender.hdBps) / BPS;

        out.attackPower = a;
        out.defensePower = d;
        out.pHitBaseBps = _pHitBps(aBase, dBase);
        out.pHitEdgedBps = _pHitBps(a, d);
        out.deltaBps = int256(out.pHitEdgedBps) - int256(out.pHitBaseBps);
        out.pKillOnFailBps =
            a + d == 0 ? KILL_BASE_PPM / 100 : (KILL_BASE_PPM + (KILL_SLOPE_PPM * d) / (a + d)) / 100;
        out.attackerLockout = HOSPITAL + (HOSPITAL * defender.resPetrifyBps) / BPS;
        out.oddsEdgeBps = edgeOf(attacker);
    }

    function _pHitBps(uint256 a, uint256 d) internal pure returns (uint256) {
        if (a + d == 0) return P_MIN_PPM / 100;
        uint256 p = (P_COEF_PPM * a) / (a + d);
        if (p < P_MIN_PPM) p = P_MIN_PPM;
        if (p > P_MAX_PPM) p = P_MAX_PPM;
        return p / 100; // ppm -> bps
    }

    // ==================================================================== knobs

    /// Tighten (never loosen past the ruling) the three Edge-Budget values. Admin is the
    /// GameController's admin, i.e. the same timelocked multisig every other module answers to. No
    /// setter here can move a stat, a trait, a destination or a token — this contract holds nothing.
    function setBudget(uint16 odds, uint16 feeStack, uint16 itemMult) external onlyAdmin {
        if (odds < ODDS_BUDGET_MIN || odds > ODDS_BUDGET_MAX) revert OutOfBounds();
        if (feeStack > FEE_STACK_MAX) revert OutOfBounds();
        if (itemMult < ITEM_MULT_MIN || itemMult > ITEM_MULT_MAX) revert OutOfBounds();
        oddsBudgetBps = odds;
        feeStackCapBps = feeStack;
        itemMultCapBps = itemMult;
        emit BudgetSet(odds, feeStack, itemMult);
    }
}
