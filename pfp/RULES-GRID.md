# Essey PFP — Trait Rules Grid (authoritative)

The single source of truth for how traits combine. The renderer (`engine2.py`) and the future
**builder / mint-reservation** product both consume these rules. Every rule is either
CODE-ENFORCED (live in the engine) or PENDING (found by QA, not yet coded).

Status legend: ✅ enforced · 🔬 under QA review · ⬜ proposed/not yet coded.

---

## 1. Categories & roles

**Drivers** (selected first; they determine dependents):
| Driver | Sets | Notes |
|---|---|---|
| Body | `family` (Mogul/Baron/Tycoon + specials Zombie/Golden/Glitch), `build` (Chad/Giga/Chiseled/Chet) | build lives at the body **sub-level** (`Tycoon Chad`) ✅ |
| Suit | `suit` | drives tattoos |
| Hair | `hair_color`, `hair_style` | order-agnostic extraction (male=color→style, female=style→color) |
| Eye Mod | `eyemod` | scanned from nested wrapper ✅ |
| Hat | `hat` | |
| Face (female) | `faceid` (Magnate/Oligarch/Heiress) | drives female nose/eyes/mouth |

**Dependents** couple to a driver. **Accessories** are optional/rarity-gated. **Base** always render.

---

## 2. COUPLING rules (must-match, else absent)

| Dependent | Couples to | No-match behavior | Status |
|---|---|---|---|
| Face (build) | Body.build | mandatory — always a valid build | ✅ |
| Face (skin/family) | Body.family | Chad/Chiseled have per-family faces; Giga/Chet single-tone | ✅ (build match) |
| Nose | Face family (M) / faceid (F) | mandatory | ✅ |
| Beard | Hair color | **absent** (e.g. Fire/Flame hair → no beard) | ✅ |
| Tattoos | Suit | **absent** (unused suit → no tattoo) | ✅ |
| Hat Hair | Hat present | only renders with a hat | ✅ |
| Snake Tail | Snake head | render both (matched color) or **neither** — no orphan tail | ✅ |
| Doom variant | Hair style | helmet bakes in the matching hair | ✅ |
| Eye-Mod Hat | Eye Mod | nested special hat | 🔬 |

---

## 3. COVER / CONFLICT rules (one trait hides regions of others)

| Trigger | Hides | Status |
|---|---|---|
| Face Mod = Terminator | eyes region (Glasses, Eye Mod) | ✅ |
| Face Mod = Bane / Doom / Samurai / Cthulu | lower face (Mouth, Beard) | ✅ |
| Face Mod = Jester | full face (Eyes, Nose, Mouth, Eyebrow, Beard, Glasses) | ✅ |
| Face Mod = **Doom** | **also Hat + Hat Hair + Hair + Ceasar** (full helmet) | ✅ |
| Laser Eye present | Glasses, Eye Mod | ✅ |
| Hat present | Ceasar (laurel crown) | ✅ |
| Hair vs Hat Hair | hat→hide full Hair; no hat→hide Hat Hair | ✅ |
| Body = Zombie/Golden/Glitch (1/1) | all face/head parts | ✅ |

---

## 4. SPATIAL EXCLUSION — the hand slot

Categories that place an object in the hands: **Hand Grip, Canes, Snake.**
Rule: keep the Hand Grip; **two objects may co-render UNLESS their opaque areas overlap ≥ 0.30**
(pairwise overlap precomputed → `traits/male/hand_conflicts.json`). A colliding cane/snake is dropped. ✅

- Large grips (Sword, Knife, Shotgun, Billfold) conflict with every cane → cane dropped.
- Small grips (Cigar, Whiskey, Poker Chips) never conflict → cane co-renders.

---

## 5. Z-ORDER overrides (render order, not selection)

| Element | Rendered | Status |
|---|---|---|
| Earring | just **beneath** Hair (down-hair covers, updos reveal) | ✅ |
| Snake Tail | behind head/hair (z≈104); Snake head/body in front (z≈1719) | ✅ |
| AR hologram | dark backing (0.9·α) then SCREEN → visible on ANY background | ✅ |

---

## 6. RARITY / OPTIONAL / SUPPRESSED

| Trait | Rate / rule | Status |
|---|---|---|
| Neko (fox mask, F) | 5%, gated on a hairstyle-matched variant | ✅ |
| Snake (+tail) | ~2.7% (male), matched color | ✅ |
| Ceasar / Hawk / Phoenix eyes | rare 1/1-ish | ✅ |
| AR | ~16% | ✅ |
| **Swollen** eye variant | **SUPPRESSED** (bruised/red-rim eye removed from pool) | ✅ |

---

## 7. Uniqueness key (for mint-reservation)

`key = md5( gender + sorted(visible-leaf paths after conflict-resolution) )`.
Keyed on the **rendered result**, not raw trait-strings — so two selections that resolve to the
same image are the same 1/1 and cannot both mint. Implemented in `collection.py::signature`. ✅

**Builder implication:** given a partial trait selection, the rules above classify every remaining
trait as FORCED (coupled), BLOCKED (would be fully hidden/conflict), or FREE — this constraint
map is what the front-end grays-out / auto-resolves against, and it must be exported from this grid.

---

## 8. QA sweep log

### Round 1 — 300 images (150M/150F), 75 agents, 18 confirmed defects → 8 classes

**FIXED (engine):**
| Class | Root cause | Fix | Status |
|---|---|---|---|
| Headless Zombie/Golden 1/1 (MAJOR, 5) | special-body rule hid ALL of `7 Face`, deleting the dedicated `7 Face/Zombie|Golden` face | couple face to `family` for Zombie/Golden (build=family); keep `7 Face`; only Glitch (head baked in body) hides it | ✅ |
| Female AR invisible (moderate, 2) | all `17 AR` variants authored **off-canvas left** (x −544…106) | `POS_OFFSET["17 AR"]=+1004` → shift onto right side like male AR | ✅ |
| Beard/brow colour mismatch on bald (moderate, 1) | bald → `hair_color=None` → beard & brows pick colour independently | bald → set one shared grooming colour (Black/Red/White) driving both | ✅ |
| Metadata lists suppressed traits (moderate, 3) | `attrs_of` emitted Hat/Eye-Mod from drivers even when hidden (Doom hides hat, laser hides eye-mod) | gate Hat/Eye-Mod/Hair on `visible_cats` → metadata == render | ✅ |

**ACCEPTED / deferred (not engine bugs, or art-side):**
- Weapon smoke on 357/Shotgun tokens reads as "orphaned" but is the **gun's own smoke** — intentional. ⬜ monitor
- Cane + cigar "collision" (#858): real overlap only ~0.11 (cigar's tall smoke inflates the bbox) — spatial rule working as designed. ⬜ monitor
- `Thirsty` mouth variant renders a red tongue + a red neck fleck — specific mouth art; flag for art review. ⬜
- CEO/CEO-G chair edge **alpha speckle** + `Royalty` chair mis-scaled off-canvas — **art-side asset fixes**; add a build-time chair-silhouette/coverage validator. ⬜

### New BUILDER constraints derived (BLOCK rules the front-end enforces)
- **Doom** ⟹ BLOCK Hat, Hat-Hair, Hair, Ceasar (full helmet)
- **Laser Eye** ⟹ BLOCK Eye Mod, Glasses
- **Jester / Terminator / Bane / Samurai / Cthulu** ⟹ BLOCK the face regions they cover (see §3)
- **Special body (Zombie/Golden/Glitch)** ⟹ BLOCK all normal head accessories

### Round 2 — fresh 300 images, 54 agents, 10 confirmed → 5 classes
**All 8 round-1 classes GONE** (zombie heads, female AR, beard-bald, metadata all verified fixed). New:

**FIXED (engine):**
| Class | Root cause | Fix | Status |
|---|---|---|---|
| Female face/body skin mismatch (MAJOR, 2) | female body family {Executive/Financier/Industrialist} and face id {Magnate/Oligarch/Heiress} are **disjoint dims, chosen independently** | measured skin tones → couple by lightness: Executive↔Magnate, Financier↔Oligarch, Industrialist↔Heiress (`FAMILY_TO_FACEID`) | ✅ |
| CEO-G chair edge alpha-bleed speckle (moderate, 5) | chair asset has semi-transparent stray pixels past its silhouette | composite-time: chair alpha `< 0.9 → 0` (kills the bleed) | ✅ |

**DEFERRED (minor / art-side):**
- Necklace visible through a translucent held glass (#6419): the glass is see-through and a long necklace hangs behind it — borderline translucency, low severity. ⬜ (option: shorten necklace clip or opacity)
- `Punk Red` hair renders magenta but is labelled "Red" (#8399): per-hairstyle colour-name drift. ⬜ relabel that variant (art/metadata), or accept
- `Carmen` hat stray vector stroke at brim tip (#5396): one broken asset path. ⬜ art re-export

**Trend:** round 1 = systemic pipeline bugs; round 2 = mostly single-asset defects. Converging. Remaining
open items are art-asset fixes (chair source, Carmen path, Punk-Red label) rather than rule logic.

### Round 3 — fresh 300 images, 48 agents, 3 confirmed → 0 systemic bugs
Convergence: **18 → 10 → 3 confirmed.** The three:
- **AR-missing (#759): FALSE POSITIVE** — the AR panel renders clearly (89% on-canvas); both agents missed it at thumbnail scale. Proves we need an *objective* gate, not just eyes.
- Poker-chip floats beside a cane + a stray grey drip at the cane joint (#38): borderline composition + minor cane-asset seam artifact. ⬜
- Cigar smoke wisp reaches the corner, disconnected from the tip (#6056): atmospheric/art-side smoke-plume length. ⬜

### OBJECTIVE VALIDATOR — `validate_render.py` (the build-time gate)
Asserts every declared metadata trait paints ≥40 in-canvas non-transparent px (catches off-canvas /
hidden / dropped traits that agents can miss or falsely flag). **Result: 0 / 10,000 fail.**
Every accessory (AR, Hat, all masks, Hand Grip, Canes, Snake, Necklace, Earring, Devilish, Neko,
Ceasar, Laser, Wrist, Ring, Beard, Tattoos, phoenix eyes, hawk) renders on every token. ✅
→ This is a required pre-mint check for the builder: **no token ships a trait that didn't render.**

### STATUS: engine ruleset TRUSTED
3 agent-QA rounds + a full-collection objective validator: **no systemic or missing-trait defects remain.**
Open items are all **art-asset** (need the designer, or accept as sub-1% cosmetic):
Carmen-hat stray stroke · Punk-Red colour label · cigar smoke-plume length · cane-joint drip ·
poker-chip-beside-cane · necklace-through-translucent-glass. None block the builder logic.

### DEFERRED — iterative image-perfection passes (post-build)
The **AR holographic screen** still doesn't render perfectly on some tokens (the darken-then-screen
backing reads heavy — dark holo rings; flagged on a Cthulu token). This and the art-asset items above
are **cosmetic, not rule/pipeline defects**. Plan (owner's call): once the **builder (A/B/C) is done**,
run repeated agent QA passes over the images, fixing/tuning until they're pixel-perfect — the AR blend
(darken factor / per-variant tuning) is the top candidate. Tracked so we don't lose it. ⬜

### Round 4 — fresh 300, 5 confirmed
**FIXED (engine):**
| Class | Fix |
|---|---|
| **AR gauge → opaque black blob** (moderate; the flagged AR issue) | AR blend reworked: dark backing now **luminance-weighted** (`0.85·luminance·alpha`) for both `26 AR`+`17 AR`, so bright glow pops on any bg while dark structural pixels stay translucent — no black blobs. Client compositor mirrored. ✅ |
| Cigar + cane collision (#230) | tightened hand-object overlap threshold **0.30 → 0.15** (`compute_conflicts.py`). ✅ |
| **'Bar' ring = broken oversized gold-bird asset over the glass** (#6485, ~14% of females) | `SUPPRESS_IN={"14 Ring":{"bar"}}` — dropped from the female ring pool until the art is re-cut. ✅ |

**DESIGNER (art re-anchor/re-export, can't fix via rules):**
- Devilish **tail floats** disconnected from the shoulder (#5001) — needs a body anchor (the horn is fine).
- `Carmen` hat **stray brim wisp** (#7673) — leftover vector stroke at the brim tip.

_Round 5 (confirm AR + Bar fixes) running._
