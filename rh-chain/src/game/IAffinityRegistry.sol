// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// D.O.N. v2 — the traits-as-gameplay read surface.
///
/// THIS FILE IS THE CONTRACT BETWEEN WORKSTREAM 1c AND EVERY OTHER v2 RAID CONTRACT.
/// RaidEngine v2 (1a), MissionBoard v2 (1b) and SpecialistRegistry (1d) build against `IAffinityRegistry`
/// and nothing else; the implementation may be redeployed generationally without changing this surface.
///
/// The eight stats (DON-TRAITS-AS-GAMEPLAY Part A, ruled verbatim by decision D5):
///   RP  RAID POWER      -> RaidEngine attack power `A`            (1 sp = +1% A)
///   HD  HOUSE DEFENSE   -> RaidEngine defense `D`                 (1 sp = +1 flat, or +1% D)
///   YLD YIELD/ESTATE    -> deploy/provision headroom + fee legs   (never the 15 bps/day rate — D8/T-5)
///   GUI GUILE/SCOUT     -> Scout read tier + counter-recon        (0..2 tiers)
///   NRV NERVE           -> MissionBoard success shift             (1 sp = +1pp)
///   RES RESILIENCE      -> hospital / petrify / ambush mitigation
///   CMD COMMAND         -> garrison efficiency, faction success, crew cooldown
///   LCK LUCK            -> discrete-lottery nudges (never an RTP surface)
///
/// THE EDGE BUDGET (law 3, ruled D1) is enforced on this surface, not by its callers: every value a
/// reader returns is already inside `≤ +10pp odds / fee-stack ≤ 25% / ItemMult ≤ x1.35`. A caller that
/// simply applies what it reads cannot break the budget, and a caller that reads `rawStatsOf` gets the
/// unclamped derivation for display/telemetry only.
interface IAffinityRegistry {
    // ------------------------------------------------------------------ types

    /// The per-Don stat sheet. Deliberately sized to ONE storage slot (31 bytes) so a raid-path read is
    /// a single SLOAD. Every field is a *modifier*, never an absolute: zero == a Don with no loaded
    /// traits, which is a fully playable Don (law 1: affinity, never exclusivity).
    struct Stats {
        uint16 rpBps; //           RP  — bps added to attack power A (400 = +4%)
        uint16 hdBps; //           HD  — bps added to defense D (1500 = +15%)
        uint16 hdFlat; //          HD  — flat defense addend, applied BEFORE hdBps
        uint16 nrvBps; //          NRV — mission-success shift in bps of probability (100 = +1pp)
        uint16 lckBps; //          LCK — discrete-lottery nudge in bps of probability
        uint16 cmdGarrisonBps; //  CMD — bps added to garrison effective power
        uint16 cmdFactionBps; //   CMD — bps added to faction mission success (100 = +1pp)
        uint16 cmdCooldownBps; //  CMD — bps cut from the crew hunt cooldown
        uint16 feeDiscBps; //      YLD — the fee-discount stack (capped at 25%)
        uint16 resHospBps; //      RES — bps cut from OWN hospital lockout
        uint16 resPetrifyBps; //   RES — bps ADDED to a failed attacker's lockout (Medusa)
        uint16 resAmbushBps; //    RES — bps cut from field-ambush probability
        uint8 guiTier; //          GUI — Scout read tier, 0..2
        uint8 yldCapSteps; //      YLD — deploy/provision headroom steps
        uint8 archetype; //        the resolved Archetype (see enum below)
        uint32 flags; //           TraitFlag bitfield
    }

    /// The six named playstyles (DON-TRAITS-AS-GAMEPLAY Part C) plus the honest default. Resolution is a
    /// pure, deterministic function of the raw sheet — never of the Edge-Budget knob — so a Don's
    /// archetype can never change under it.
    enum Archetype {
        UNSPECIALIZED,
        ENFORCER,
        MATRIARCH,
        GHOST,
        BROKER,
        BOSS,
        HIGH_ROLLER
    }

    /// Canned reference garrisons for the Skirmish preview panel ("your edge versus this garrison type").
    /// Values are the live Phase-0 HouseDeed tier stats — Safehouse defense 40 / 2 slots, Row House 60 / 3.
    enum GarrisonClass {
        BARE_SAFEHOUSE, //      defense 40, 0 garrison — the Broker's open door
        GUARDED_SAFEHOUSE, //   defense 40, 2 garrison
        OPEN_ROW_HOUSE, //      defense 60, 0 garrison
        FORTRESS_ROW_HOUSE //   defense 60, 3 garrison — the Part-F worked example
    }

    /// The read-only Skirmish preview payload the UI renders before a player commits the 50-Scrip fee.
    struct Skirmish {
        uint256 attackPower; //     A with the attacker's RP applied (x1e6, RaidEngine units)
        uint256 defensePower; //    D with the defender's HD/CMD applied (x1e6)
        uint256 pHitBaseBps; //     p_hit with NO traits on either side
        uint256 pHitEdgedBps; //    p_hit with both sides' traits, after the same [5%,70%] clamp
        int256 deltaBps; //         edged − base, the number the panel headlines
        uint256 pKillOnFailBps; //  attacker kill-on-fail at the edged power ratio
        uint256 attackerLockout; // seconds a failed attacker's crew sits out, after the defender's RES
        uint256 oddsEdgeBps; //     the attacker's consumed Edge Budget (of `oddsBudgetBps`)
    }

    // ------------------------------------------------------------------ events

    event Attested(uint256 indexed donId, bytes32 indexed combo, uint8 archetype, uint32 flags);
    event BudgetSet(uint16 oddsBudgetBps, uint16 feeStackCapBps, uint16 itemMultCapBps);

    // ------------------------------------------------------------------ write path (permissionless)

    /// Derive and store `donId`'s stat sheet from the trait preimage. PERMISSIONLESS AND TRUSTLESS:
    /// the only thing accepted is a byte string that hashes to the combo the Don already committed
    /// on-chain (`Don.traits(donId)`), so there is no signer, no oracle and no privileged writer.
    /// Idempotent: re-attesting the same combo reverts; a rerolled Don may be re-attested by anyone.
    function attest(uint256 donId, bytes calldata preimage) external;

    /// The commitment a preimage produces — the same bytes32 the Don collection stores. The builder
    /// panel uses it to prove "this preview is your Don" without a round trip to any server.
    function commitmentOf(bytes calldata preimage) external pure returns (bytes32);

    /// How much of the odds Edge Budget a sheet consumes, in bps of probability. Public so a caller can
    /// audit the clamp rather than take it on faith.
    function edgeOf(Stats memory s) external pure returns (uint256);

    /// The canned reference House behind each `GarrisonClass`.
    function referenceGarrison(GarrisonClass class_)
        external
        pure
        returns (uint256 deedDefense, uint256 garrisonSize);

    // ------------------------------------------------------------------ sheet reads

    /// The Edge-Budget-clamped sheet. THIS is what game contracts read.
    function statsOf(uint256 donId) external view returns (Stats memory);

    /// The unclamped derivation (display + telemetry only — never apply this to a roll).
    function rawStatsOf(uint256 donId) external view returns (Stats memory);

    function isAttested(uint256 donId) external view returns (bool);
    /// The combo the stored sheet was derived from; 0 if never attested. Stale iff != Don.traits(donId).
    function sheetCombo(uint256 donId) external view returns (bytes32);
    /// True once the Don's traits are frozen on the collection (`Don.locked`) — the sheet is forever.
    function frozen(uint256 donId) external view returns (bool);
    function archetypeOf(uint256 donId) external view returns (Archetype);
    /// How much of the odds Edge Budget this Don consumes, after clamping. Always <= oddsBudgetBps().
    function oddsEdgeBps(uint256 donId) external view returns (uint256);

    // ------------------------------------------------------------------ reader helpers (1a/1b/1d call these)

    /// A' = basePower * (1 + RP). RaidEngine v2 `_settleCrew` calls this once on the summed crew power.
    function applyRaidPower(uint256 donId, uint256 basePower) external view returns (uint256);
    /// D' = (baseDefense + HD_flat) * (1 + HD_pct). Flat first, then percent (the Part-F ordering).
    /// `baseDefense` is in RaidEngine PPM units (a defence stat of 60 is passed as 60e6), and the flat
    /// HD addend is scaled to match — this is the one place the registry knows the engine's units.
    function applyHouseDefense(uint256 donId, uint256 baseDefense) external view returns (uint256);
    /// Garrison contribution scaled by CMD.
    function applyGarrison(uint256 donId, uint256 garrisonPower) external view returns (uint256);
    /// Crew hunt cooldown after CMD.
    function applyCooldown(uint256 donId, uint256 cooldown) external view returns (uint256);
    /// Own hospital lockout after RES.
    function applyHospital(uint256 donId, uint256 lockout) external view returns (uint256);
    /// A FAILED ATTACKER's lockout, extended by the DEFENDER's RES (Medusa petrify).
    function applyPetrify(uint256 defenderDonId, uint256 lockout) external view returns (uint256);
    /// A fee after the Don's YLD discount stack (never below the caller's own floor).
    function applyFeeDiscount(uint256 donId, uint256 fee) external view returns (uint256);

    function nerveBps(uint256 donId) external view returns (uint256);
    function factionBps(uint256 donId) external view returns (uint256);
    function luckBps(uint256 donId) external view returns (uint256);
    function ambushBps(uint256 donId) external view returns (uint256);
    function feeDiscountBps(uint256 donId) external view returns (uint256);
    function yieldCapSteps(uint256 donId) external view returns (uint256);

    /// Scout read tier 0..2 (SpecialistRegistry gates report depth on this — ruling E2).
    function guileTier(uint256 donId) external view returns (uint8);
    /// The Don's away-window is returned to Scouts as a noisy band (every woman, W1; Snake; Ghost).
    function counterRecon(uint256 donId) external view returns (bool);
    /// The Don never appears in a Scout report at all (Ghost background / The Vanish set).
    function unscoutable(uint256 donId) external view returns (bool);
    /// The Don produces free Scout-lite reports (Hawk / Bird).
    function scoutLite(uint256 donId) external view returns (bool);

    // ------------------------------------------------------------------ Skirmish preview (pure/view, no state)

    /// The stat block for a combo that need not exist yet — the builder's "this is what you are locking"
    /// panel (H.4). Pure: no token, no storage, no trust.
    function previewSheet(bytes calldata preimage) external view returns (Stats memory);

    /// "Your Don's edge versus this garrison type", against a canned reference House.
    function previewVsGarrison(uint256 attackerDonId, GarrisonClass class_, uint256 crewSize)
        external
        view
        returns (Skirmish memory);

    /// The full duel: two attested Dons, a crew size, a garrison size and the defender's deed defense.
    function previewDuel(
        uint256 attackerDonId,
        uint256 defenderDonId,
        uint256 crewSize,
        uint256 garrisonSize,
        uint256 deedDefense
    ) external view returns (Skirmish memory);

    /// The same math over hypothetical sheets — the builder panel's "what if I roll this" mode.
    function skirmish(
        Stats memory attacker,
        Stats memory defender,
        uint256 crewSize,
        uint256 garrisonSize,
        uint256 deedDefense
    ) external view returns (Skirmish memory);

    // ------------------------------------------------------------------ knobs (VALUES bounded, BOUNDS immutable)

    function oddsBudgetBps() external view returns (uint16);
    function feeStackCapBps() external view returns (uint16);
    function itemMultCapBps() external view returns (uint16);
}

/// The trait commitment surface of the live `Don` collection (rh-chain/src/market/Don.sol). The registry
/// reads it and nothing else — it never takes custody, never mints, never writes to the collection.
interface IDonTraits {
    function traits(uint256 id) external view returns (bytes32);
    function locked(uint256 id) external view returns (bool);
    function ownerOf(uint256 id) external view returns (address);
}
