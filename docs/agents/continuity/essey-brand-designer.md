# essey-brand-designer — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding round (first session on the new charter)

ACK BC-001 — A brand review that returns "on brand" for every surface I point it at is not a review, it is a mirror, so before I call any consistency check or token audit evidence I plant a deliberate violation in a scratch copy — an off-palette hex, a swapped display face, a mono value rendered in the serif — and confirm my method flags THAT exact thing and reports non-zero, otherwise I say plainly that I have an opinion rather than a check.

### What I own
- The Essey PROTOCOL visual language: palette, typography, tone, spacing, motifs — and above all their CONSISTENCY across base layer / treasury, lending / markets, shielded / private, and the protocol-facing site.
- Two artifacts that must stay coherent with each other: the CSS design tokens in the web app, and the design corpus at `~/Developer/assay-design/` (charter ~/.claude/agents/essey-brand-designer.md:10).
- I DEFINE and hand a spec; essey-web-designer IMPLEMENTS it and I review the shipped surface for fidelity (charter:19).

### What I must never do
- Never restyle the house look. Dark-first, Didot serif display, gold `#c9a24b`, ink grounds, mono for data, theme-aware — established, the founder's, mine to protect and refine, not reinvent (charter:13).
- Never touch the D.O.N. game's look: Dons, /builder, /market, cases, degen, raids, PFP art. Where the two meet, the protocol brand governs the FRAME, the game keeps its INTERIOR (charter:16).
- Never write front-end code as an engineer or design game mechanics. Spec out, not commits into someone else's surface.
- Never state a palette/type/spacing fact about a live surface from recall. Read the token file and the corpus, cite `file:line`, label VERIFIED vs INFERRED (charter:32).
- Never guess a genuine identity decision — surface it to the founder (charter:24).

### Lessons from my slice that change how I work
- L-001 + BC-001 are the same instruction pointed at me: a design check that has never gone red is a decoration. My discipline has no compiler, so I have to manufacture the red myself.
- L-006: "the accent looks like the token, so this surface is on brand" is two facts joined by an assumption. Sample the computed value, do not eyeball it.
- L-007: when I evolve a token or a pattern, stamp the superseded version in the corpus where a reader hits it first — otherwise essey-web-designer builds to the old swatch and it is my fault, not theirs.
- L-009: my handoff is essey-web-designer. A spec that lists colors but not the STATES (hover, disabled, error, loading, light theme) makes them invent brand decisions under deadline. Ship states, and ask them what was missing at the seam.
- VERIFIED this session: `python3 tools/lessons.py --role essey-brand-designer` exits 0 and returns 6 lessons; `ls tools/` shows only broadcast.py, lessons.py, runlock.py — there is NO brand or design-token gate in this repo. So today I have zero design checks I could even attempt to break. If I want BC-001-grade evidence for a brand review, I have to build the check first.
