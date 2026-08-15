// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAffinityRegistry} from "./IAffinityRegistry.sol";

/// AffinityTraits — the FROZEN trait->stat table and the trustless preimage decoder.
///
/// ============================================================================================
/// WHY THIS IS TRUSTLESS (the design choice the build plan left open, resolved here)
/// ============================================================================================
/// The plan (DON-V2-BUILD-PLAN §2.1 row 13) sketched the sheet as "derived off-chain ... written
/// on-chain at mint/reroll" — i.e. a server writes each Don's stats. That is a trusted party: the
/// writer could grant itself a god-roll. Ground truth in this repo says we do not need one.
///
///   * `Don.traits[id]` (rh-chain/src/market/Don.sol L44) already stores a bytes32 COMMITMENT to the
///     Don's resolved trait combo, set at mint and re-set on reroll, frozen forever by `lockTraits`.
///   * `DonDistributor` enforces `usedCombo` uniqueness over that same value, so the commitment is
///     the collection's own source of truth for "which traits is this Don".
///   * The commitment's preimage is fully specified and reproducible on-chain. From
///     `app/web/src/pfp-resolve.ts` L256-257 and `app/web/api/_don-lib.ts` L44:
///
///         key   = hex_lower( sha256( gender || "\n" || sorted(visible leaf paths).join("\n") ) )
///         combo = keccak256( utf8(key) )
///
///     Both hashes are EVM precompiles/opcodes. So a contract can VERIFY a submitted preimage
///     rather than trust anyone's claim about it.
///
/// The design chosen here is therefore: PERMISSIONLESS PREIMAGE ATTESTATION. Anybody may hand the
/// registry the plaintext trait blob for any Don. The registry recomputes the commitment; if it does
/// not equal `Don.traits(donId)` byte-for-byte the call reverts. If it does, the blob IS that Don's
/// trait list — cryptographically, not by assertion — and the registry derives the sheet itself, in
/// Solidity, from the immutable table below. There is no writer role, no signature, no oracle, no
/// server, and no admin who can change what a Don is. The only privileged surface in the whole
/// workstream is a bounded knob that can *shrink* the Edge Budget, never a stat.
///
/// The resolver's conflict/hide rules do NOT need re-implementing: the commitment is taken over the
/// already-resolved VISIBLE leaf paths, so any blob that hashes correctly is by definition the post-
/// conflict trait set the art renders. We read it; we never re-derive it.
///
/// ============================================================================================
/// GRAIN (ruling D6) — stats map at GROUP grain: the first two '/'-separated segments of a leaf
/// path ("5 Suit/The General"). Colourways and deeper variants are cosmetic and carry zero load, and
/// a group that appears on several leaves (art + its shadow layer) is counted ONCE.
/// ============================================================================================
library AffinityTraits {
    // ------------------------------------------------------------------ Part-A sp -> number (ruling D5)

    uint16 internal constant RP_SP = 100; //  1 sp RP  = +1% attack power A
    uint16 internal constant NRV_SP = 100; // 1 sp NRV = +1pp mission success
    uint16 internal constant HD_SP = 100; //  1 sp HD  = +1% defense D (the percent form; flat is explicit)
    uint16 internal constant CMD_SP = 100; // 1 sp CMD = +1% garrison / +1pp faction
    uint16 internal constant LCK_SP = 100; // 1 sp LCK = +1pp on a discrete lottery

    // ------------------------------------------------------------------ per-Don soft caps (Part A col 7)

    uint16 internal constant RP_CAP = 800; //         +8 sp  -> +8% A
    uint16 internal constant HD_PCT_CAP = 1500; //    +15% D (the W2 Matriarch ceiling)
    uint16 internal constant HD_FLAT_CAP = 40; //     Leadership 1 + Doggy 20 + Hawk 10 = 31, with headroom
    uint16 internal constant NRV_CAP = 500; //        +5pp (the Con-line ceiling)
    uint16 internal constant CMD_GARRISON_CAP = 500; //  +5% garrison (The Bull)
    uint16 internal constant CMD_FACTION_CAP = 200; //   +2% faction (Matriarch/Queen)
    uint16 internal constant CMD_COOLDOWN_CAP = 500; //  -5% hunt cooldown (Swift)
    uint16 internal constant LCK_CAP = 200; //        one weekly reroll + one favor-adjacent rider
    uint16 internal constant RES_HOSP_CAP = 5000; //  -50% own hospital (Zombie)
    uint16 internal constant RES_PETRIFY_CAP = 5000; // +50% attacker lockout (Medusa)
    uint16 internal constant RES_AMBUSH_CAP = 1000; // -10% ambush (Neko)
    uint8 internal constant GUI_TIER_CAP = 2; //      read tier 2
    uint8 internal constant YLD_STEP_CAP = 2; //      +2 provisioning-cap steps

    // ------------------------------------------------------------------ flags

    uint32 internal constant F_FEMALE = 1 << 0;
    uint32 internal constant F_COUNTER_RECON = 1 << 1; // away-window returns as a noisy band
    uint32 internal constant F_UNSCOUTABLE = 1 << 2; // never appears in a Scout report at all
    uint32 internal constant F_SCOUT_LITE = 1 << 3; // produces free Scout-lite reports (Hawk/Bird)
    uint32 internal constant F_ANALYST_HUD = 1 << 4; // AR HUD (UI perk)
    uint32 internal constant F_WILDCARD = 1 << 5; // Joker suit — dealt a Calling each season
    uint32 internal constant F_TRICKSTER = 1 << 6; // Jester face mod — weekly brief swap
    uint32 internal constant F_PHOENIX = 1 << 7; // 1x/season free repair after a big score
    uint32 internal constant F_ZOMBIE = 1 << 8; // mythic body
    uint32 internal constant F_GOLDEN = 1 << 9; // mythic body — own-sale royalty waived
    uint32 internal constant F_GLITCH = 1 << 10; // mythic body — 1x/season brief re-seed
    uint32 internal constant F_QUEEN = 1 << 11; // +1 Outfit-perk cap slot
    uint32 internal constant F_HOUSE_SUIT = 1 << 12; // a female house Calling (Estate/Crown key)
    uint32 internal constant F_MVHQ_BG = 1 << 13;
    uint32 internal constant F_MVHQ_AR = 1 << 14;
    uint32 internal constant F_MVHQ_KIT = 1 << 15;
    uint32 internal constant F_SNAKE = 1 << 16;
    uint32 internal constant F_HAWK = 1 << 17; // Hawk (m) or Bird (f) — the Vanish's third leg
    uint32 internal constant F_GHOST_BG = 1 << 18;
    uint32 internal constant F_DOGGY = 1 << 19;
    uint32 internal constant F_CEASAR = 1 << 20;
    uint32 internal constant F_JOKER_SUIT = 1 << 21;
    uint32 internal constant F_JESTER_MOD = 1 << 22;
    // set capstones (Part D)
    uint32 internal constant F_SET_BLOODLINE = 1 << 23;
    uint32 internal constant F_SET_MVHQ = 1 << 24;
    uint32 internal constant F_SET_MOTLEY = 1 << 25;
    uint32 internal constant F_SET_VANISH = 1 << 26;
    uint32 internal constant F_SET_ESTATE = 1 << 27; // trait side only; the Row-House deed is deed-side
    uint32 internal constant F_SET_CROWN = 1 << 28;

    // ------------------------------------------------------------------ working accumulator

    /// Wider than `Stats` so the table can over-shoot before the per-stat caps bite.
    struct Raw {
        uint256 rp;
        uint256 hdPct;
        uint256 hdFlat;
        uint256 nrv;
        uint256 lck;
        uint256 cmdGarrison;
        uint256 cmdFaction;
        uint256 cmdCooldown;
        uint256 fee;
        uint256 resHosp;
        uint256 resPetrify;
        uint256 resAmbush;
        uint256 gui;
        uint256 yld;
        uint32 flags;
        uint8 family; // 1..3 Mogul/Baron/Tycoon, 4..6 Executive/Financier/Industrialist, 0 none
        uint8 noseFamily;
        uint8 faceFamily; // female only (Magnate/Oligarch/Heiress); males have no family-named face group
    }

    error BadPreimage();

    // ==================================================================== the commitment

    /// The exact commitment the Don collection stores: keccak256 over the lowercase hex text of the
    /// sha256 of the preimage. Mirrors `comboHash(resolve(...).key)` byte-for-byte.
    function commitmentOf(bytes memory preimage) internal pure returns (bytes32) {
        return keccak256(_hexLower(sha256(preimage)));
    }

    function _hexLower(bytes32 v) private pure returns (bytes memory out) {
        bytes16 sym = "0123456789abcdef";
        out = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(v[i]);
            out[2 * i] = sym[b >> 4];
            out[2 * i + 1] = sym[b & 0x0f];
        }
    }

    // ==================================================================== the decoder

    /// Walk the verified preimage and accumulate the raw stat sheet.
    /// Layout: `gender \n path \n path ... \n path`, paths lexicographically sorted by the resolver.
    function decode(bytes memory p) internal pure returns (Raw memory r) {
        uint256 n = p.length;
        if (n == 0) revert BadPreimage();

        // -- line 0: gender. Only the two the collection has.
        uint256 i = _eol(p, 0);
        bytes32 g = _hashRange(p, 0, i);
        if (g == keccak256("female")) {
            // W1, the population-wide female identity floor: every woman carries counter-recon.
            r.flags |= F_FEMALE | F_COUNTER_RECON;
        } else if (g != keccak256("male")) {
            revert BadPreimage();
        }

        // -- remaining lines: leaf paths, folded to group grain and de-duplicated.
        // Upper bound on keyed lines: each costs at least a '\n' and one character, and the gender line
        // costs at least 4 ("male"). Sized generously so no crafted blob can overrun the buffer.
        bytes32[] memory seen = new bytes32[](n / 2 + 1);
        uint256 nSeen;
        while (i < n) {
            uint256 start = i + 1;
            uint256 end = _eol(p, start);
            i = end;
            if (end <= start) continue;

            (bytes32 key, bool ok) = _groupKey(p, start, end);
            if (!ok) continue; // a bare, category-less base layer — cosmetic by construction

            bool dup;
            for (uint256 j = 0; j < nSeen; j++) {
                if (seen[j] == key) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            seen[nSeen++] = key;

            _apply(r, key);
        }

        _applySets(r);
    }

    /// Index of the next '\n' at or after `from` (or the end of the buffer).
    function _eol(bytes memory p, uint256 from) private pure returns (uint256 i) {
        i = from;
        uint256 n = p.length;
        while (i < n && p[i] != 0x0a) i++;
    }

    /// The group key for a leaf path: everything up to the SECOND '/', e.g. "5 Suit/The General".
    /// `ok` is false for a path with no '/' at all (an uncategorised base layer).
    function _groupKey(bytes memory p, uint256 start, uint256 end) private pure returns (bytes32, bool) {
        uint256 slashes;
        uint256 stop = end;
        for (uint256 i = start; i < end; i++) {
            if (p[i] == 0x2f) {
                slashes++;
                if (slashes == 2) {
                    stop = i;
                    break;
                }
            }
        }
        if (slashes == 0) return (bytes32(0), false);
        return (_hashRange(p, start, stop), true);
    }

    function _hashRange(bytes memory p, uint256 start, uint256 end) private pure returns (bytes32 h) {
        assembly {
            h := keccak256(add(add(p, 0x20), start), sub(end, start))
        }
    }

    // ==================================================================== the frozen table
    //
    // Every entry below is DON-TRAITS-AS-GAMEPLAY Part B, at the group names that actually exist in
    // app/web/public/builder/data_{male,female}.json. Groups absent from this function are cosmetic and
    // contribute exactly zero — stated out loud so no rarity-meta lawyer can claim otherwise.

    function _apply(Raw memory r, bytes32 k) private pure {
        // ---------------------------------------------------------------- MALE (26 categories)

        // 4 Body — family is cosmetic alone, but is the set-bonus key; the three mythic bodies are loaded.
        if (k == keccak256("4 Body/Mogul")) return _fam(r, 1);
        if (k == keccak256("4 Body/Baron")) return _fam(r, 2);
        if (k == keccak256("4 Body/Tycoon")) return _fam(r, 3);
        if (k == keccak256("4 Body/Zombie")) {
            r.resHosp += 5000;
            r.flags |= F_ZOMBIE;
            return;
        }
        if (k == keccak256("4 Body/Golden")) {
            r.fee += 1000; // own-sale royalty waived (fee-side)
            r.flags |= F_GOLDEN;
            return;
        }
        if (k == keccak256("4 Body/Glitch")) {
            r.lck += LCK_SP;
            r.flags |= F_GLITCH;
            return;
        }
        if (k == keccak256("10 Nose/Mogul Nose")) return _nose(r, 1);
        if (k == keccak256("10 Nose/Baron Nose")) return _nose(r, 2);
        if (k == keccak256("10 Nose/Tycoon Nose")) return _nose(r, 3);

        // 5 Suit — the Calling card.
        if (k == keccak256("5 Suit/The General")) {
            r.rp += 2 * RP_SP;
            r.nrv += NRV_SP; // siege family
            return;
        }
        if (k == keccak256("5 Suit/Windsor") || k == keccak256("5 Suit/Scholar")) {
            r.nrv += 2 * NRV_SP; // finance family
            r.fee += 300; // -3% dispatch
            return;
        }
        if (k == keccak256("5 Suit/Bladerunner")) return _gui(r);
        if (k == keccak256("5 Suit/Pimp") || k == keccak256("5 Suit/Couture") || k == keccak256("5 Suit/Duke")) {
            r.nrv += 2 * NRV_SP; // con family
            return;
        }
        if (k == keccak256("5 Suit/Cas") || k == keccak256("5 Suit/Designer")) {
            r.rp += RP_SP;
            return;
        }
        if (k == keccak256("5 Suit/Joker")) {
            r.flags |= F_WILDCARD | F_JOKER_SUIT;
            return;
        }

        // 17 Face Mod — the aggression signature, and the Jester.
        if (
            k == keccak256("17 Face Mod/Terminator") || k == keccak256("17 Face Mod/Bane")
                || k == keccak256("17 Face Mod/Doom") || k == keccak256("17 Face Mod/Samurai")
                || k == keccak256("17 Face Mod/Cthulu")
        ) {
            r.rp += 2 * RP_SP;
            return;
        }
        if (k == keccak256("17 Face Mod/Jester")) {
            r.lck += LCK_SP;
            r.flags |= F_TRICKSTER | F_JESTER_MOD;
            return;
        }

        // 15 Eye Mod / 24 Laser Eye / 26 AR — the Eyes surface.
        if (
            k == keccak256("15 Eye Mod/Spider") || k == keccak256("15 Eye Mod/Cyclops")
                || k == keccak256("15 Eye Mod/Hardboiled") || k == keccak256("15 Eye Mod/Cyberpunk")
                || k == keccak256("15 Eye Mod/Monocle") || k == keccak256("15 Eye Mod/Monocyber")
                || k == keccak256("24 Laser Eye/Laser Eye")
        ) {
            return _gui(r);
        }
        if (
            k == keccak256("26 AR/Wash Trade") || k == keccak256("26 AR/Whale") || k == keccak256("26 AR/Stonks")
                || k == keccak256("26 AR/The Dev")
        ) {
            r.flags |= F_ANALYST_HUD;
            return _gui(r);
        }
        if (k == keccak256("26 AR/MVHQ AR")) {
            r.yld += 1;
            r.flags |= F_MVHQ_AR;
            return;
        }

        // 18 Canes — the command aura.
        if (k == keccak256("18 Canes/The Bull")) {
            r.cmdGarrison += 5 * CMD_SP;
            return;
        }
        if (k == keccak256("18 Canes/Swift")) {
            r.cmdCooldown += 500;
            return;
        }
        if (k == keccak256("18 Canes/Cobra")) {
            r.resAmbush += 500;
            return;
        }
        if (k == keccak256("18 Canes/Claw")) {
            r.fee += 1000; // -10% fence royalty
            return;
        }

        // 25 Snake / 2 The hawk / 23 Ceasar / 21 Wrist / 1 Background / 3 Chair / 19 Hand Grip.
        if (k == keccak256("25 Snake/Snake Red") || k == keccak256("25 Snake/Snake Green")) {
            r.flags |= F_SNAKE | F_COUNTER_RECON;
            return;
        }
        if (k == keccak256("2 The hawk/Hawk") || k == keccak256("2 The hawk/Hawk Attack")) {
            r.hdFlat += 10; // field warning
            r.flags |= F_HAWK | F_SCOUT_LITE;
            return;
        }
        if (k == keccak256("23 Ceasar/Ceasar")) {
            r.cmdFaction += CMD_SP;
            r.flags |= F_CEASAR;
            return;
        }
        if (k == keccak256("21 Wrist/Rolex")) {
            r.fee += 1000; // -10% dispatch
            return;
        }
        if (k == keccak256("21 Wrist/Prayer Bead")) {
            r.lck += LCK_SP;
            return;
        }
        if (k == keccak256("1 Background/Ghost")) {
            r.flags |= F_GHOST_BG | F_UNSCOUTABLE | F_COUNTER_RECON;
            return;
        }
        if (k == keccak256("1 Background/MVHQ")) {
            r.flags |= F_MVHQ_BG;
            return;
        }
        if (k == keccak256("3 Chair/Knowledge Throne")) {
            r.nrv += NRV_SP;
            return;
        }
        if (k == keccak256("19 Hand Grip/MVHQ Martini")) {
            r.flags |= F_MVHQ_KIT;
            return;
        }

        // ---------------------------------------------------------------- FEMALE (17 categories)

        if (k == keccak256("3 Body/Executive")) return _fam(r, 4);
        if (k == keccak256("3 Body/Financier")) return _fam(r, 5);
        if (k == keccak256("3 Body/Industrialist")) return _fam(r, 6);
        if (k == keccak256("5 Face/Magnate")) return _face(r, 4);
        if (k == keccak256("5 Face/Oligarch")) return _face(r, 5);
        if (k == keccak256("5 Face/Heiress")) return _face(r, 6);
        if (k == keccak256("6 Nose/Magnate Nose")) return _nose(r, 4);
        if (k == keccak256("6 Nose/Oligarch Nose")) return _nose(r, 5);
        if (k == keccak256("6 Nose/Heiress Nose")) return _nose(r, 6);

        // 4 Suits — the female Calling card.
        if (
            k == keccak256("4 Suits/Leadership") || k == keccak256("4 Suits/BossB")
                || k == keccak256("4 Suits/Duchess") || k == keccak256("4 Suits/Opera")
        ) {
            r.cmdFaction += CMD_SP;
            r.hdFlat += 1;
            r.flags |= F_HOUSE_SUIT;
            return;
        }
        if (k == keccak256("4 Suits/Badass")) {
            r.rp += 2 * RP_SP;
            return;
        }
        if (
            k == keccak256("4 Suits/Scarlet White") || k == keccak256("4 Suits/Jennifer")
                || k == keccak256("4 Suits/Riviera") || k == keccak256("4 Suits/Hotlanta")
        ) {
            r.nrv += 2 * NRV_SP; // con family
            return;
        }
        if (k == keccak256("4 Suits/Weeb")) return _gui(r);

        if (k == keccak256("1 Chairs/Queen")) {
            r.flags |= F_QUEEN;
            return;
        }
        if (k == keccak256("13 Hand Grip/Doggy")) {
            r.hdFlat += 20; // a garrison in a token
            r.flags |= F_DOGGY;
            return;
        }
        if (k == keccak256("13 Hand Grip/Bird")) {
            r.flags |= F_HAWK | F_SCOUT_LITE;
            return;
        }
        if (k == keccak256("9 Hair/Medusa")) {
            r.resPetrify += 5000;
            return;
        }
        if (k == keccak256("18 phoenix eyes/Phoenix")) {
            r.flags |= F_PHOENIX;
            return;
        }
        if (k == keccak256("11 Devilish/Devilish")) {
            r.fee += 2000; // Moonshot fee leg -20%
            return;
        }
        if (
            k == keccak256("16 Neko/Neko") || k == keccak256("16 Neko/Neko Lush")
                || k == keccak256("16 Neko/Neko Boss") || k == keccak256("16 Neko/Neko Updo")
        ) {
            r.resAmbush += 1000;
            return;
        }
        if (
            k == keccak256("17 AR/Wash Trade") || k == keccak256("17 AR/Whale") || k == keccak256("17 AR/Stonks")
                || k == keccak256("17 AR/The Dev")
        ) {
            r.flags |= F_ANALYST_HUD;
            return _gui(r);
        }
        if (k == keccak256("17 AR/MVHQ AR")) {
            r.yld += 1;
            r.flags |= F_MVHQ_AR;
            return;
        }
        if (k == keccak256("12 Wrist dec/Watch")) {
            r.fee += 1000;
            return;
        }
        if (k == keccak256("12 Wrist dec/Horseshoe") || k == keccak256("12 Wrist dec/Black Pearl")) {
            r.lck += LCK_SP;
            return;
        }
        // everything else: cosmetic, zero load.
    }

    function _gui(Raw memory r) private pure {
        r.gui += 1;
    }

    function _fam(Raw memory r, uint8 f) private pure {
        r.family = f;
    }

    function _nose(Raw memory r, uint8 f) private pure {
        r.noseFamily = f;
    }

    function _face(Raw memory r, uint8 f) private pure {
        r.faceFamily = f;
    }

    // ==================================================================== set capstones (Part D)
    //
    // Every capstone is HORIZONTAL: it deepens ONE spec's strategy. None grants flat cross-strategy
    // power, and all of them land INSIDE the Edge Budget (a set is a route to the cap, never past it —
    // the clamp in AffinityRegistry is what makes that true rather than merely intended).

    function _applySets(Raw memory r) private pure {
        bool female = r.flags & F_FEMALE != 0;

        // FULL BLOODLINE — the family-driven categories all read one house. On-chain form: the body
        // family plus the family-matched nose (and, for women, the family-matched face, which the male
        // surface has no equivalent of: male face groups are body-types, not houses).
        if (r.family != 0 && r.noseFamily == r.family && (!female || r.faceFamily == r.family)) {
            r.flags |= F_SET_BLOODLINE;
            // +2 sp to the family's signature stat. The doc names three (Mogul->RP, Tycoon->YLD,
            // Executive->HD); the other three are filled in here so each of the six houses points at a
            // DIFFERENT stat — no family gets a strictly better capstone, which is the horizontality law.
            if (r.family == 1) r.rp += 2 * RP_SP; //             Mogul        -> RP
            else if (r.family == 2) r.cmdGarrison += 2 * CMD_SP; // Baron     -> CMD
            else if (r.family == 3) r.yld += 2; //               Tycoon       -> YLD
            else if (r.family == 4) r.hdPct += 2 * HD_SP; //     Executive    -> HD
            else if (r.family == 5) r.nrv += 2 * NRV_SP; //      Financier    -> NRV
            else r.resHosp += 1000; //                           Industrialist-> RES
        }

        // MVHQ SET — three ultra-rares; the trophy is CAPACITY, not raw power.
        if (r.flags & F_MVHQ_BG != 0 && r.flags & F_MVHQ_AR != 0 && r.flags & F_MVHQ_KIT != 0) {
            r.flags |= F_SET_MVHQ;
            r.yld += 1;
        }

        // FULL MOTLEY — Joker suit + Jester face mod. Adaptability, not power: flag only.
        if (r.flags & F_JOKER_SUIT != 0 && r.flags & F_JESTER_MOD != 0) r.flags |= F_SET_MOTLEY;

        // THE VANISH — Ghost background + Snake + (Hawk or Bird): total information dominance.
        if (r.flags & F_GHOST_BG != 0 && r.flags & F_SNAKE != 0 && r.flags & F_HAWK != 0) {
            r.flags |= F_SET_VANISH;
            r.gui = GUI_TIER_CAP;
            r.flags |= F_UNSCOUTABLE;
        }

        // THE ESTATE — Queen chair + a house suit + Doggy (trait side). The Row-House deed is the
        // fourth leg and lives on HouseDeed, so a reader that wants the full set checks both.
        if (r.flags & F_QUEEN != 0 && r.flags & F_HOUSE_SUIT != 0 && r.flags & F_DOGGY != 0) {
            r.flags |= F_SET_ESTATE;
            r.hdPct += HD_PCT_CAP; //   the W2 +15% D ceiling
            r.cmdFaction += CMD_SP; //  stacking with the house suit's +1% to the ruled +2%
        }

        // THE OUTFIT CROWN — Ceasar (m), or Queen + a house suit (f). Leadership as a collectible.
        if (r.flags & F_CEASAR != 0 || (r.flags & F_QUEEN != 0 && r.flags & F_HOUSE_SUIT != 0)) {
            r.flags |= F_SET_CROWN;
        }
    }

    // ==================================================================== raw -> Stats (per-stat caps)

    function toStats(Raw memory r) internal pure returns (IAffinityRegistry.Stats memory s) {
        s.rpBps = uint16(_cap(r.rp, RP_CAP));
        s.hdBps = uint16(_cap(r.hdPct, HD_PCT_CAP));
        s.hdFlat = uint16(_cap(r.hdFlat, HD_FLAT_CAP));
        s.nrvBps = uint16(_cap(r.nrv, NRV_CAP));
        s.lckBps = uint16(_cap(r.lck, LCK_CAP));
        s.cmdGarrisonBps = uint16(_cap(r.cmdGarrison, CMD_GARRISON_CAP));
        s.cmdFactionBps = uint16(_cap(r.cmdFaction, CMD_FACTION_CAP));
        s.cmdCooldownBps = uint16(_cap(r.cmdCooldown, CMD_COOLDOWN_CAP));
        s.feeDiscBps = uint16(_cap(r.fee, type(uint16).max));
        s.resHospBps = uint16(_cap(r.resHosp, RES_HOSP_CAP));
        s.resPetrifyBps = uint16(_cap(r.resPetrify, RES_PETRIFY_CAP));
        s.resAmbushBps = uint16(_cap(r.resAmbush, RES_AMBUSH_CAP));
        s.guiTier = uint8(_cap(r.gui, GUI_TIER_CAP));
        s.yldCapSteps = uint8(_cap(r.yld, YLD_STEP_CAP));
        s.flags = r.flags;
        s.archetype = uint8(archetypeOf(s));
    }

    function _cap(uint256 v, uint256 c) private pure returns (uint256) {
        return v > c ? c : v;
    }

    // ==================================================================== archetype resolution (Part C)
    //
    // Deterministic and pure: each stat is normalised to its own soft cap (so the eight are comparable),
    // scored against the six specs' 3/2/1 priority vectors, highest wins, ties break to the lower enum.
    // Computed from the RAW sheet so the Edge-Budget knob can never move a Don's identity.

    function archetypeOf(IAffinityRegistry.Stats memory s) internal pure returns (IAffinityRegistry.Archetype) {
        uint256 rp = _frac(s.rpBps, RP_CAP);
        uint256 hd = (_frac(s.hdBps, HD_PCT_CAP) + _frac(s.hdFlat, HD_FLAT_CAP)) / 2;
        uint256 yld = (_frac(s.yldCapSteps, YLD_STEP_CAP) + _frac(s.feeDiscBps, 2500)) / 2;
        uint256 gui = (_frac(s.guiTier, GUI_TIER_CAP) + (s.flags & F_COUNTER_RECON != 0 ? 10_000 : 0)) / 2;
        uint256 nrv = _frac(s.nrvBps, NRV_CAP);
        uint256 res = (_frac(s.resHospBps, RES_HOSP_CAP) + _frac(s.resPetrifyBps, RES_PETRIFY_CAP)
            + _frac(s.resAmbushBps, RES_AMBUSH_CAP)) / 3;
        uint256 cmd = (_frac(s.cmdGarrisonBps, CMD_GARRISON_CAP) + _frac(s.cmdFactionBps, CMD_FACTION_CAP)) / 2;
        uint256 lck = _frac(s.lckBps, LCK_CAP);

        uint256[6] memory score;
        score[0] = 3 * rp + 2 * nrv + cmd; //                  ENFORCER    RP > NRV > CMD
        score[1] = 3 * hd + 2 * yld + 2 * res + cmd; //        MATRIARCH   HD > YLD > RES > CMD
        score[2] = 3 * gui + 2 * res + cmd; //                 GHOST       GUI > RES > CMD
        score[3] = 3 * nrv + 2 * yld + lck; //                 BROKER      NRV > YLD > LCK
        score[4] = 3 * cmd + 2 * hd + nrv; //                  BOSS        CMD > HD > NRV
        score[5] = 3 * lck + 2 * nrv + rp; //                  HIGH_ROLLER LCK > NRV > RP

        uint256 best;
        for (uint256 i = 1; i < 6; i++) {
            if (score[i] > score[best]) best = i;
        }
        if (score[best] == 0) return IAffinityRegistry.Archetype.UNSPECIALIZED;
        return IAffinityRegistry.Archetype(best + 1);
    }

    function _frac(uint256 v, uint256 cap) private pure returns (uint256) {
        if (cap == 0) return 0;
        if (v > cap) v = cap;
        return (v * 10_000) / cap;
    }
}
