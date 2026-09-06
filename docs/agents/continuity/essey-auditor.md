# essey-auditor — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding to the rewritten charter (no audit performed)

ACK BC-001 — I will not sign a round clean on the strength of a green suite, a passing gate, or a prior audit's verdict; if I mean to lean on a test as evidence that an invariant is pinned, I first break that exact invariant in the source, watch that test go red and check its exit code, and put it back — and if I cannot make it fail, I report the invariant as UNPINNED rather than citing the test.

### What I own
- One lens of the standing 3-agent gate. Three independent auditors clean in the SAME round before any deploy or push; any finding resets all three. My clean does not carry over to the next round.
- Seven lenses: NO INLINE OUTCOMES (Wolf Game rule) first, then custody/value flow, authority blast radius, solvency invariants, game-theoretic exploits, fog integrity, and pre-push public-repo hygiene.
- Scope: `rh-chain/src/game/` and `rh-chain/src/market/`. Design docs in assay-design are INTENT ONLY, never ground truth about behaviour.
- Every finding carries severity, exact code path, a numeric exploit scenario, and a specific fix, and is labelled CONFIRMED (traced) vs PLAUSIBLE (suspected, unproven).

### What I must never do
- Never approve on tests passing. Tests encode assumptions and the bug is usually in the assumption.
- Never trust a comment, a doc, a commit message, or a previous auditor's clean. Read the source; verify against chain state.
- Never state an ungrounded load-bearing claim as fact — file:line, the command I ran plus its output, or the label INFERRED/UNVERIFIED in plain sight (L-006: check the joint before the word "so" leaves my mouth).
- Never manufacture findings to look thorough, and never silently pass a low — accepting one is legitimate, but the rationale gets written down.
- Never start an audit run against a tree another run is already mutating (L-003) — `python3 tools/runlock.py --list` first, or work from `git archive HEAD`.
- Never treat "adminless" as established because a doc or a contract name says so.

### Lessons from my slice that change how I work
- L-001 + BC-001: my whole evidence standard inverts. "The suite is green" is now worth zero in a report. The unit of evidence is a watched red.
- L-002: authorship is not evidence of content. When I hash a baseline for a round, hash against `HEAD` or rebuild from `git archive HEAD` — a file being "the engineer's own" says nothing about whether a live access-control mutant is sitting in it. This is directly load-bearing for me: an audit scored against a contaminated baseline is worse than no audit.
- L-011: test the gate in the configuration it actually runs in. Applies to contracts too — proving a guard reverts for my test harness proves nothing about the real caller's path.
- L-008: when I hand a peer a finding, name what the design got right first and say what the fix buys. An engineer who stops volunteering the thing they are unsure about costs me more findings than my correction ever saved.
- L-009/L-010: continuity before the report, and the handoff is part of the job — the engineer who receives my findings needs to know what is sharp, not just what is broken.

UNVERIFIED at this point: I have not yet read `docs/AGENT-HIERARCHY.md` or `docs/MAINNET-ACTIVATION.md` — this session was scoped to charter/broadcast onboarding only. Both are step 1 and 2 of my next real session.

## 2026-09-05 — pre-push gate, round member 1 of 3 (43 commits, origin/main..HEAD 5c42f14)

Charter on disk matched my spawn snapshot this time — no divergence to report, but I checked, and
L-014 says I always must.

### Technique that worked: audit from `git archive HEAD`, never the worktree
The tree was dirty with uncommitted lending work that was explicitly OUT of scope. Every grep I ran
against the working directory would have mixed it into the result. I built
`scratchpad/head/` from `git archive HEAD | tar -x` and scanned THAT. Cheap, and it makes the
provenance of every hit correct by construction (L-002/L-003).

### BC-001 applied to the pre-commit hook, and it is a real gate
I did not take `.githooks/pre-commit` on trust. I built a scratch repo with `core.hooksPath=.githooks`
— the configuration it actually runs in — and planted each thing it claims to catch, one at a time,
checking the EXIT CODE:
  benign file → exit 0 · filled webhook in a `.example` → exit 1 · `OPERATOR_PK=<64hex>` in a
  `.example` → exit 1 · genuine placeholders (`FOO=`, `BAR=<your-token>`, `BAZ=CHANGEME`) → exit 0 ·
  `/Users/<me>/Developer/...` → exit 1 · PEM header → exit 1 · `api_key = "<28 chars>"` → exit 1.
It blocks, and it does not cry wolf. That is now evidence I am allowed to cite.

### The finding I would have missed by trusting a green gate
The hook's absolute-path rule is `/Users/[A-Za-z0-9._-]+/(Developer|Documents|Desktop)/`. The founder
scanned for the same shape, found zero, and said so. Both are correct AND both miss the leak, because
the leak is in TILDE form: `~/Developer/essey-markets`, `~/Developer/assay-design`,
`~/Developer/essey-ceremony`, `~/.claude/agents/*.md`. The hook's own header says the 2026-09-02
incident that forced a history rewrite was "another private repo, and the ceremony checkout" — and
`essey-ceremony` is back in this push, in the one form the hook it motivated cannot see.
Baseline check that made this scoreable: `git grep -c <pat> origin/main` → essey-markets 34 (already
public), assay-design 0, essey-ceremony 0, .claude/agents 0. Three of the four are NEW exposure.

**Rule for my next run:** when a path-leak gate exists, the FIRST thing to test is the notation it
does not normalise. `~`, `$HOME`, `%USERPROFILE%`, and the Claude project-slug form
`-Users-<name>-Developer-<repo>` all denote the same path and none match a `/Users/` literal.

### Secrets: clean, and here is what I actually ran
PEM blocks, key-name-adjacent 64-hex, bare 64-hex in every non-Solidity file type, 12-word mnemonic
shapes, Slack/Discord webhooks, URLs with embedded creds or `?api_key=`, and the provider prefixes
(`sk-`, `ghp_`, `github_pat_`, `AKIA`, `xox*-`, `AIza`, `eyJ…`). Zero hits. The 64-hex literals that
DO appear in new files are `keccak256("Transfer(address,address,uint256)")` — confirmed by running
`cast keccak` — and the EIP-1967 beacon slot. Both are public constants, not keys.
`PAGER_WEBHOOK_URL=` and `KEEPER_PRIVKEY=` in the two `.example` files are both empty.

### The round was overtaken by the push — record this, it is the biggest thing I learned today
I was convened as 1 of 3 on `origin/main..HEAD` = 43 commits at `5c42f14`. Mid-audit the baseline
moved twice and then the branch shipped:
  `git reflog show origin/main` → `a48216c … update by push`, `58fff0b … update by push`
  `git ls-remote origin refs/heads/main` → `a48216c` (authoritative, hits GitHub)
  `git rev-list --count origin/main..HEAD` → 0
Two commits I had never seen (`58fff0b`, two blog posts; `a48216c`, a CI fix) entered the range after
my baseline, and the whole thing is public.

**What I will do differently, first thing, every gate run:** record `git rev-parse HEAD` AND
`git ls-remote origin refs/heads/main` at the START, and re-check BOTH at the end; report the pair in
the verdict. A verdict without a frozen SHA is not a verdict — the memory note on the gate definition
says "the SAME frozen bytes" and I nearly wrote a clean against bytes that had already changed under
me twice. I only caught it because a `git diff -- .gitignore` came back empty when the same command
had listed `M .gitignore` an hour earlier. Chase that kind of inconsistency; do not explain it away.

### Findings worth carrying (2026-09-05)
- **Tilde-form private paths are invisible to the `/Users/` gate.** `~/Developer/essey-markets` (8),
  `~/Developer/assay-design` (3), `~/Developer/essey-ceremony` (1), `~/.claude/agents/*` (many).
  `git grep -c` at the old origin/main: assay-design 0, essey-ceremony 0, .claude/agents 0 — so three
  of the four are NEW public exposure, and `essey-ceremony` is the very repo the 2026-09-02 history
  rewrite existed to remove. Also found the slug form `-Users-erikastramecki-Developer-assay` in
  `docs/agents/continuity/jester.md:14`, which encodes the home path with no `/` in it at all.
- **`app/web/check-blog-cadence.mjs` cannot fail in any clone.** It reads
  `docs/JESTER-BUILD-LOG.md`, which is gitignored (`.gitignore:58`) and untracked. I stripped a post's
  `date:` line and it still printed `SKIP` and exited 0. It enforces only on the founder's laptop.
  Same shape as the style gate the blog post in this very push is about.
- **`docs/CUSTODY-AUDIT-STATUS.md` understates its own gate.** Its "What this gate does NOT do"
  section says a stale `UNAUDITED` line "passes the build exactly as well as a clean receipt does" and
  cites `check-custody-audit.mjs:52-53`. I planted exactly that: exit 1, with a message specifically
  rejecting UNAUDITED. The gate was hardened in `0479993`; the disclaimer was not updated. False in
  the SAFE direction, but false, in the doc whose whole job is honesty about custody.
- **The anti-scam post asks for a check that cannot be run.** `only-real-essey-contract.md` says
  "confirm the reserve address above is the one the token points at". The token points at nothing —
  `reserve()`, `essey()`, `vault()` all revert on `0x3157…071610`, and `EsseyToken.sol` declares no
  functions. The link is one-way: `EsseyReserve.essey` (`rh-chain/src/market/EsseyReserve.sol:56`)
  → the token, and `cast call` on the RESERVE returns `0x3157…071610` correctly. This post had
  already been corrected once (`efe34aa`) for its verification steps confirming the wrong token.
  **Lesson for me: when a doc gives a user a verification procedure, RUN THE PROCEDURE.** Reading it
  and finding it plausible is what let the first wrong version ship.
- **Blog counts go stale between writing and publishing.** `fourteen-could-not-remember.md` says
  "fifteen of us" and quotes the gate as printing `15 charter(s), 0 problem(s)`; at its own commit the
  gate prints `16 charter(s), 0 problem(s)` (the 16th landed 7 commits earlier in `9e47e01`), and
  LESSONS.md holds 15 entries where the post says nine. Every one of those is falsifiable by a reader
  in one command, on a blog whose entire pitch is "check every word."

### Gates I watched go red today, so I am allowed to cite them
`.githooks/pre-commit` (4 plants, exit 1 each; 2 benign controls, exit 0) ·
`app/web/check-reserve-basket.mjs` (FAIL branch exit 1 naming AMZN; WARN branch exit 0 naming
Supercycle) · `app/web/check-custody-audit.mjs` (name removed → exit 1; verdict flipped to UNAUDITED
→ exit 1) · `app/web/check-agent-wiring.mjs` (absent charter dir → SKIP exit 0; dir present but empty
→ exit 1; HARD RULE stripped from a charter COPY → exit 1 naming the agent; real charter left intact,
re-grepped after).
And one I could NOT make fail, so I am calling it a decoration rather than citing it:
`app/web/check-blog-cadence.mjs`.

### Two more, and the second is the one I nearly did not look for
- **Private-corpus citations are shipped, at scale.** 70 `[[memory-slug]]` wiki-links to the founder's
  private memory directory sit in the public tree (`git grep -ohE '\[\[[a-z0-9-]+\]\]' HEAD | wc -l`),
  across `docs/MAINNET-*.md`, `docs/audits/glend-round-{4,5,7}.md` and a continuity file. Only 8 came
  from this push; the other 62 were already public. They name internal topics —
  `essey-competitor-netnet-capital`, `essey-liquidity-launch-plan`, `essey-fiat-mint-coinvoyage`,
  `essey-reserve-deposit-address` — and one carries a line range (`:33-36`) into a file no reader can
  open. This is my charter's lens 6 verbatim and I should check it FIRST next time, not last.
- **`a48216c` (the last commit pushed, which no auditor in this round saw) regressed a gate.** Its
  early `process.exit(0)` for an absent charter dir now discards problems the gate had ALREADY
  collected. essey-zk-auditor found this and logged L-017; I re-verified it independently rather than
  inheriting it — same broken LESSONS.md, exit 1 with the real HOME, exit 0 with a HOME lacking the
  charter dir — and can add the provenance they did not have: the discard did not exist before
  `a48216c`; the prior form was `existsSync(AGENTS) ? … : []` followed by a `problems.push`, which
  failed the build rather than skipping. Credit to them; my own first pass tested only the absent-dir
  case and would have called it fine.

### Housekeeping I did, so the next agent is not surprised
Adding L-018 changed the roster/lessons fingerprint and correctly turned `check-agent-wiring.mjs`
red. I did NOT silently re-stamp — the gate's own comment warns that regenerating the stamp lets the
prose rot while the gate stays green. I added a matching honest paragraph to
`docs/AGENT-COMPANY-FOUNDATION.md` (anchor asserted in the edit script), THEN re-stamped, and all
four build gates are exit 0 again. Uncommitted after my run:
`docs/AGENT-COMPANY-FOUNDATION.md`, `docs/agents/LESSONS.md`,
`docs/agents/continuity/essey-auditor.md`. The lending files and two peers' continuity files in the
tree are not mine.

### The parallel sweep paid for itself — and the lesson is about how I USED it
I dispatched a doc-consistency sweep and it came back with 6 HIGH + 15 MED that my own targeted
passes (paths, secrets, competitor names, on-chain claims) would never have found, because they were
CROSS-DOCUMENT contradictions — doc A vs doc B, never wrong on its own page. I inherited none of it
as truth. Every load-bearing claim I re-derived myself, and re-deriving CHANGED two of them:

- Its **MEDIUM-G** flagged an open pre-push history-scrub blocker (`MAINNET-ACTIVATION.md:1388-1394`,
  commit `04e763d` allegedly still carrying another private repo's name) and labelled it SUSPECTED,
  unresolvable from a file snapshot. It IS resolvable, from git. `git branch -r --contains 04e763d`
  → nothing, and pickaxe over all 336 public commits
  (`git log -S'essey-ceremony' --oneline origin/main`) returns exactly ONE commit: `52667c3`, which
  is in this push. **So the old scrub DID run; what is public is the NEW leak I found, not a
  residual.** Same for `assay-design`. That converts a scary unknown into a precise, bounded fix and
  it strengthens my M-1 rather than duplicating it.
- Its **HIGH-1** (a pager described as running every 900s) I did not take from the three docs it
  quoted. `launchctl list | grep -ci liveness` → **0**, `ls ~/Library/LaunchAgents | grep -ci
  liveness` → **0**. Ground truth, from the machine, not from a doc agreeing with another doc.

**Technique to keep:** a subagent is excellent at the fan-out that is expensive for me (24 docs,
pairwise) and I am the one who must close each finding against the SYSTEM — git, the chain, launchctl.
Split it that way deliberately next time instead of treating delegation as all-or-nothing. And when a
sweep says "cannot be verified from this snapshot," that is usually a statement about the snapshot,
not about the world: ask what OTHER instrument answers it.

**What I would have shipped without it:** a NOT-CLEAN verdict missing the fact that `BASE-LAYER.md:142`
calls lending "audited" on a doc `gen-docs.mjs:39` renders to essey.xyz as "if you read one protocol
doc, read this," against a standing retraction at `MAINNET-ACTIVATION.md:1582`. That is the worst
finding of the round and it is not in a contract.

### The disclosure class I under-weighted and will lead with next time
`docs/agents/continuity/essey-launch-economist.md:39-50` publishes, on a public repo, the anti-snipe
economics of an UNLAUNCHED token: the rejected design's front-run profit (+$6,611) vs the shipped
surcharge (-$302), that `snipeSeconds` is **immutable at deploy**, and that raising it is an OPEN
founder ask. Read by the adversary it defends against, on a chain whose mempool is public, that says:
the parameter is at a value the team itself suspects is too low, and it can never be changed.
**Continuity files are a disclosure surface, not scratch paper.** Their whole content is an agent
narrating internal state — open decisions, gaps, where the guards are not. I audited them for PATHS
and did not, at first, audit them for STRATEGY. Next pre-push: read every continuity file as if the
adversary is the reader, before any grep.
