# Essey PFP — generative engine, QA pipeline & trait rules

The conflict-aware compositing engine and quality pipeline behind the Essey PFP collection.
This directory is **code + rules only**. The proprietary art library, the rendered 10,000-piece
collection, the metadata, and the rarity report are **private** (kept out of this public repo until
mint — see `.gitignore`). The engine therefore documents the pipeline but needs the private trait
library to render.

## What's here
| File | Role |
|---|---|
| `engine.py` | The engine: samples traits by authored rarity, resolves **couplings** (face↔body, nose↔face, beard↔hair, tattoo↔suit, snake-tail↔snake, hat-hair↔hat) and **conflicts** (mask covers, laser, hat↔crown, full-helmet, special bodies, hand-object overlap), and composites with faithful normal/multiply/screen blends. |
| `RULES-GRID.md` | **Authoritative if-then trait matrix** — every coupling, cover/conflict, spatial-exclusion, z-override and rarity rule, tagged enforced/deferred. Consumed by the renderer *and* the builder. |
| `collection.py` | Dedup (on the **rendered result**), OpenSea metadata, rarity report, batch render. |
| `validate_render.py` | **Objective pre-mint gate:** asserts every declared trait paints visible in-canvas pixels. |
| `compute_conflicts.py` | Precomputes pairwise hand-object overlap (which held items may co-render). |
| `verify.py` / `verify_f.py` / `structcheck.py` / `overlapcheck.py` | Invariant checkers (eyes/nose present once, couplings hold, no region crowding). |
| `render_review_batch.py` | Renders a risk-oversampled batch for the visual-QA fleet. |
| `extract_leaves.py` / `extract_structure.py` | Extract the trait library + z-ordered structure from the source PSDs. |

## Quality campaign (summary)
A multi-agent visual-QA fleet reviewed risk-oversampled batches over three rounds, each finding
adversarially verified, then synthesized into error classes with proposed rules:

- **Round 1:** 18 confirmed → 8 classes (systemic pipeline bugs) — all fixed.
- **Round 2:** 10 → 5 classes (mostly single-asset) — systemic ones fixed.
- **Round 3:** 3 → **0 systemic** (1 false positive, 2 borderline/art).
- **Objective validator:** **0 / 10,000** tokens have a declared trait that fails to render.

Result: the ruleset is trusted; remaining open items are art-asset polish, not rule logic.

## Uniqueness (mint reservation)
`key = md5( gender + "\n".join(sorted(visible-leaf paths after conflict-resolution)) )`.
Keyed on the **rendered result**, so two selections that resolve to the same image are the same
1-of-1 and cannot both mint. This key locks a reservation in the builder.

## Builder
`RULES-GRID.md` §7–8 defines the front-end constraint model (per partial selection: which traits are
FORCED / BLOCKED / FREE) and the block rules. The live builder UI is a separate front-end (not yet built).
