# Essey PFP — ART-DEFECT LEDGER

*(formerly "Designer art-fix list" — SUPERSEDED 2026-08-11: there is **no art designer**; the
layer art is **FINAL**. Every source-art defect below is now neutralized **in code** or
explicitly accepted. Pixel fixes live in `art_mitigations.py` (deterministic, idempotent,
originals backed up to `{SP}/art_originals_backup/` in the private workspace — never in the
repo); rule fixes live in `engine.py` and are tagged in `RULES-GRID.md`.)*

Status legend: **[FIXED-ART]** pixel fix via `art_mitigations.py` · **[FIXED-RULE]** engine
rule · **[EXCLUDED]** combo removed from the pool · **[ACCEPTED]** kept as-is, reads as style.

## Re-run / regenerate
```
python3 pfp/art_mitigations.py <SP>                       # pixel fixes (idempotent via marker)
python3 <SP>/optimize_web_art.py <SP> app/web/public      # re-derive builder WebPs from fixed PNGs
python3 pfp/export_builder_data.py <SP> app/web/public/builder   # rules + webp map -> data_{m,f}.json
```
`<SP>` = the private art workspace holding `traits/{male,female}` + `engine2.py` (a copy of
`engine.py` — keep them identical).

## 1. Mis-coloured / incomplete-fill layers
- **Bowler `Red` hat — crown "half unfilled", hard diagonal split (#198)** → **[FIXED-ART]**
  Root cause was NOT the red fill (it is complete): every `Bowler Shadow` layer is an opaque
  cream-painted light-wash in **normal** blend that covered the left half of any crown (all 4
  colours, red just contrasted most). `bowler_shadow_overlay` converts all 16 copies into a
  neutral translucent shade/highlight overlay (dark→black α, light→white α around the layer's
  median luminance). The old `SUPPRESS_IN "22 Hat": {"bowler red"}` exclusion is **removed** —
  the Red bowler is back in the pool and all bowler colours render clean.
  Proof: `art-mitigation/before/bowlerred_male_s67.png` vs `after/bowlerred_male_s67.png`.
- **Hat-hair `Fade` tan base under light hair (#4)** → **[FIXED-RULE]** double-covered:
  `HIDE_LEAF "Hair Fade"` drops the leaf if ever emitted, and the colour-coupling logic never
  selects it (0 occurrences in a 20,000-seed sweep even with mitigations disabled). A hatted
  fade-cut head shows no hat-hair — consistent with a shaved fade.
- **`Red` hair — lavender/purple strand patches (#150)** → **[FIXED-ART]** the highlight
  strand sub-layers of every male Red hairstyle are painted violet (hue ≈ 261–350°).
  `red_hair_violet_remap` soft-remaps the violet window onto the warm-red family (S/V kept, so
  the sheen survives) across **34 files**: 8 styles + Rooster shadow + all nested hat-hair Red
  copies. Female reds measured clean — untouched.
  Proof: `before/redhair_male_s23.png` (Wolf, half-lavender) vs `after/redhair_male_s23.png`.
- **Jester mask — tan wedge at temple/sideburn (#4)** → **[ACCEPTED]** the wedge is the face's
  own temple skin between mask edge and ear; on-token it reads as a shaved temple. Auto-
  extending mask art across 7 variants × every hairstyle risks far worse artifacts than this
  subtle seam. Proof: `before/jester_male_s3.png`, `before/jester_male_s20.png`.

## 2. Floating fragments / orphaned elements
- **Cane — detached shard over the knuckles (#91)** → **[FIXED-ART]** each of the 4 canes (+
  shadows) carried a small orphan shard floating in the head↔shaft gap where the hand grips.
  `cane_floating_shards` prunes every component but the gold head and the shaft (8 files).
  The gold needle piercing the orb is part of the topper design — kept. (Canes are already
  hand-exclusive in the engine, so the collar never fights a held item.)
  Proof: `after/layer_zoom_pairs.png`, `after/cane_s5.png`, `after/cane_s12.png`.
- **Devilish tail — floating red spade behind the shoulder (#5001)** → **[FIXED-RULE]**
  existing `HIDE_LEAF "Devilish Rear"` + `CROP_BOTTOM "11 Devilish/Devilish": 400` keep the
  horn and drop the disconnected tail. Proof: `before/devilish_female_s16.png` vs
  `after/devilish_s16.png`.

## 3. Misplaced / orphaned effects
- **Cigar smoke plume drifting to the corner (#47, #462, #6056)** → **[FIXED-RULE]** existing
  `CROP_TOP` (300) on `19 Hand Grip/Cigar` + `13 Hand Grip/Havannah` clips the runaway plume.
  Smoke on 357/Shotgun tokens is the **gun's own muzzle smoke** — intentional, kept.
  Proof: `after/cigarsmoke_s1.png`.
- **Cthulu tentacle-beard occludes a held cigar (#440)** → **[ACCEPTED]** the cigar stays
  visible in the hand below the beard and the (now cropped) smoke passes behind the tentacles;
  reads as smoking through the beard. Proof: `before/cthulucigar_male_s154.png`.
- **"Toothpick + red daub" through the mouth (#1522)** → **[FIXED-ART]** this is the `Thirsty`
  **vampire** mouth (fangs + blood drip) — the drip is style and stays. What was broken: a
  detached droplet speck floating beside the drip. `thirsty_droplet_specks` prunes the orphan
  specks in all 8 Thirsty files. Proof: `after/zoom_pairs.png` (middle row).

## 4. Hair ↔ hat clipping (female — hats keep the full `9 Hair`)
- **Gem spikes / Updo curls / Lush tip poke above the hat crown (#6452-class, #5429-area)** →
  **[FIXED-RULE]** `FEMALE_HAT_HAIR_CROP` crops those three styles' hair at the same per-hat
  crown line the PSD's own baked `Hat Hair` variants are cut at (Carmen 207 / Arlington 177 /
  Labrea 256). All other styles verified clean across all 3 hats (34-combo visual sweep) and
  keep their intentional hat-in-big-hair look (Afro, Boss, Curl…).
  Proof: `before/tallhair_grid.png`, `before/female_style_hat_grid.png` vs
  `after/female_fix_grid.png`.
- **Medusa × any hat** → **[EXCLUDED]** the snake-crown pierces every brim; no crop can fix a
  nest of snakes wider than the hat (art defect, no designer). `FEMALE_HAT_BLOCK = {"Medusa"}`
  skips hat selection for Medusa — the narrowest possible exclusion; every other style keeps
  every hat. Founder can veto by deleting the entry in `engine.py`.
  Proof: `before/tallhair_grid.png` (medusa tiles) vs `after/medusa_s24.png`.
- ⚠ **Client gap:** the TS builder resolver (`pfp-resolve.ts`) already consumes `HIDE_LEAF` /
  `CROP_TOP` / `SUPPRESS_IN` from the exported data, but the two new `FEMALE_*` tables are
  exported **advisory-only** — the resolver needs a ~5-line wiring pass (site untouched by
  this mitigation pass, per scope).

## 5. Layering gaps & stray strokes
- **Snake + Joker suit — flat blue patch on the chest (#611)** → **[ACCEPTED]** not
  reproducible in the current ruleset (probe `before/jokerblue_male_s771.png` renders clean);
  the flat dark region baked into the Joker suits sits where the forearm crosses and reads as
  a waistcoat. Monitor in the next QA fleet round.
- **`Carmen` hat — stray vector wisp off the brim tip (#7673)** → **[FIXED-ART]**
  `carmen_brim_wisp` erases the thin trailing stroke below the brim tip (morphological
  opening in the tip ROI, two passes) in Carmen Red + Black, and prunes the detached slivers
  in `Carmen Rear`. Proof: `after/carmen_wisp_v2.png`.
- **CEO-G chair edge alpha speckle** → **[FIXED-RULE]** existing composite-time clamp (chair
  alpha < 0.9 → 0) in both the engine and the client compositor.

---
_No open designer items remain. Every defect above is neutralized in code or accepted with
reasoning; re-running the QA fleet post-regeneration is the remaining verification step._
