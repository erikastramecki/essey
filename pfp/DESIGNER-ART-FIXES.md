# Essey PFP — Designer art-fix list

These are **source-art defects** found by the visual-QA fleet that the **engine cannot fix with
layering rules** (they're mis-coloured / misplaced / clipped pixels baked into the PSD layers).
Fix at the source, re-run `extract_leaves.py` + `extract_structure.py`, and regenerate — the engine
composites them correctly, so once the layer art is clean the render is clean.

Each item lists an example token from the QA batches. Everything the engine *could* fix (couplings,
conflicts, AR blend, cane collisions, the broken 'Bar' ring, the swollen eye) is already handled in
`engine.py` / `RULES-GRID.md` and is NOT in this list.

## 1. Mis-coloured / incomplete-fill layers (highest priority — common traits)
- **Bowler `Red` hat** — the red crown fill doesn't cover the whole crown; the left half shows the
  cream/skin base as a hard diagonal split. (#198) → re-fill the crown.
- **Hat-hair `Fade` base** — renders a warm tan under **light/white** hair, so white-haired + hatted
  tokens show tan hair at the brim. (#4) → recolour the Fade base to a neutral/hair-tone, or make it
  a proper multiply-shadow so the colour layer reads through.
- **`Red` hair** — a highlight/flyaway strand sub-layer is painted **lavender/purple**, leaving a
  purple patch on an otherwise maroon head. (#150) → recolour that strand layer to the red family.
- **Jester mask** — a tan skin wedge shows at the temple/sideburn where the mask meets the ear
  (mask art doesn't carry cleanly across that seam). (#4) → extend mask coverage at the temple.

## 2. Floating fragments / orphaned elements
- **Cane** — a thin gold needle/spike floats detached near the handle, and the ornate collar renders
  over the knuckles ("hand clamped by a floating gold piece"). (#91) → re-anchor / clean the cane
  handle art. (Canes are now hand-exclusive in the engine, so they only appear held alone.)
- **Devilish tail** — the red spade tail floats disconnected behind the shoulder (the horn is fine).
  (#5001) → anchor the tail to the lower back / shoulder.

## 3. Misplaced / orphaned effects
- **Cigar smoke plume** — drifts to the top-left corner, disconnected from the cigar tip, and even
  appears on non-cigar tokens (helmet/shotgun) as a sourceless wisp. (#47, #462, #440) → shorten the
  plume and anchor it to the cigar tip; ensure it's part of the cigar asset only.
- **Cthulu tentacle-beard** occludes a held cigar, leaving its smoke with no visible source. (#440)
- **Mouth** — a toothpick + red daub pokes through the mouth on a token with no mouth accessory
  trait. (#1522) → remove the stray element from that mouth/face variant.

## 4. Hair ↔ hat clipping
- **Tall hairstyles poke above hats** — e.g. `Lush` (female) and a black spike above `Arlington`
  (#6452, #5462, #5429-area). Females have no hat-hair swap, so a tall style clips the crown.
  → either add hat-hair variants for female tall styles, or lower/trim the crown of those styles.

## 5. Layering gaps & stray strokes
- **Snake + Joker suit** — a flat blue triangular patch shows on the chest inside the snake coil
  (a gap in the suit/collar art or a stray unmasked shape). (#611)
- **`Carmen` hat** — a stray vector wisp trails off the brim tip. (#7673)
- **CEO-G chair** edge alpha speckle (engine bakes a clean alpha at composite time, but the source
  asset should be re-exported with a clean 1px edge).

---
_Compiled from QA rounds 1–6. When these are re-cut, regenerate and re-run the QA fleet to confirm._
