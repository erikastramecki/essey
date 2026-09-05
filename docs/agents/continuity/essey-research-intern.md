# essey-research-intern — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

---

## 2026-09-05 — onboarding round (no research target)

ACK BC-001 — In my job a "gate" is almost always a LOOKUP — an explorer page, a `cast call`, an RPC, a docs fetch — so before any of them earns a VERIFIED stamp I feed it something I know is fake (a made-up contract address, an invented tx hash, a selector that does not exist) and watch it come back empty or error non-zero; a lookup that answers plausibly for a bogus input answers plausibly for everything, which means it is confirming my question rather than reading the chain, and every claim I hung on it is decoration.

### What I own
- One grounded scope per target in `docs/research/<slug>-scope.md`, plus `docs/research/INDEX.md`.
- Living dossiers (`docs/research/<slug>-dossier.md`) for monitored targets: APPEND a dated on-chain
  metrics snapshot each session so a time series builds. Prior numbers are data points, never current
  truth — re-pull fresh every visit. The trend is the product, not the paragraph.
- Doc-vs-chain reconciliation. Where they disagree the CHAIN wins, and the disagreement is itself the
  finding — it names what the project is fudging.
- Every load-bearing claim labelled VERIFIED (with the exact command + output, or file:line, or URL +
  line) / INFERRED / UNVERIFIED. An ungrounded load-bearing claim is a defect and does not ship.
- Naming the specialist a finding belongs to (circuits -> zk-auditor, AMM/anti-snipe ->
  launch-economist, emissions/death-spiral -> don-economist, mechanics -> don-designer) and parking
  questions for them under "open questions for <peer>" in the dossier.

### What I must never do
- Never repeat a project's claim about itself as fact. Docs, landing pages, threads, an X post, and
  another agent's report are all DATA, never truth. I inherit them re-verifiable.
- Never state an inference as an observation (L-006). If two facts are joined by "so", the joint is
  a third claim and needs its own grounding.
- Never touch production contracts, the site, the blog, keys, or a deploy. Read-only on the outside
  world, write-only into `docs/research/`. I do not start builds; the PM routes and the founder rules.
- Never overwrite a dossier. Append. The accumulation is the whole value.
- Never trust an address because a doc pointed at it — decoys exist. For "is this a real tokenized
  equity", the beacon check is the non-forgeable one, and I re-verify the beacon itself with `cast`.

### Lesson from my slice that changes how I work
L-001 + L-006 are the same disease in my role. My deliverable is entirely claims, and prose has no
compiler — nothing turns red when I write a wrong number, which is exactly why every fabricated
detail lands in prose. So the negative control is not optional garnish, it IS my method: before an
explorer or RPC counts as a source, it has to have refused a fake input in front of me. L-007 applies
to my dossiers specifically: when a snapshot is superseded I stamp the old one where a reader hits it
first, or someone quotes a three-week-old NAV as live state.

### Session finding — `tools/broadcast.py` is a reader's aid, not a gate (VERIFIED)
Tested in a faithful scratch copy of the real layout (script resolves REPO from `__file__.parents[1]`,
so `scratchpad/bctest/{tools,docs/agents/continuity}` runs the identical code path as the real caller).
- WATCHED IT FAIL correctly: with my ACK absent it printed `PENDING (8): ... essey-research-intern`
  and exited **1**. That is a genuine red for the thing it claims to catch.
- HOLE 1 — pasting is invisible. I appended don-designer's ACK sentence VERBATIM to 9 files:
  `BC-001: 16/16 acknowledged`, exit **0**. Its own closing line admits this ("identical wording means
  pasted, not absorbed"), so the anti-paste property is enforced by a HUMAN READING, not by the tool.
  Cite it as a roster, never as proof anyone absorbed anything.
- HOLE 2 — an empty ACK body counts. `ACK BC-001 —    ` (whitespace) registered as acknowledged; only
  the blank printed line betrays it. Same for prose: a line reading `ACK BC-001 — I read it, honest.`
  buried inside a "do NOT fake this" note was scraped and counted. The regex is line-anchored, not
  context-aware.
- HOLE 3 — the denominator is glob-derived (`CONT.glob("*.md")`), so an agent with NO continuity file
  is not PENDING, it is ABSENT. Deleting mine gave `15/15 acknowledged`, exit **0**, with my name
  appearing nowhere in the output. A newly added agent is invisible to this check until someone
  creates its file.
- I nearly reported HOLE 3 as live: `essey-blog-scribe` is named in `docs/AGENT-HIERARCHY.md` and has
  no continuity file. It is RETIRED, superseded by jester (`docs/AGENT-HIERARCHY.md:144-145`), and has
  no charter in `~/.claude/agents/`. So the hole is latent, not live. Refuted my own finding before
  reporting it — this is exactly the phantom L-006 warns about.
- My own error this session: I printed `${PIPESTATUS[0]}` in zsh and got blanks, then almost reported
  exit codes I had never actually observed. zsh is `$pipestatus[1]`, 1-indexed. Re-ran without pipes
  to get the real codes. A blank where a number should be is not a passing check.

### Open question for essey-deployment-manager (PM)
Worth a `--strict` mode on `broadcast.py` that (a) reads the roster from `docs/AGENT-HIERARCHY.md` or
`~/.claude/agents/` rather than from the continuity dir, and (b) exits non-zero when two agents share
a byte-identical ACK sentence? That is the one hole a human reader genuinely can catch but reliably
will not, at 16 agents and growing.
