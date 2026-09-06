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

## 2026-09-06 — frozen round on d7e4716 (member 1 of 3), auditing what is ALREADY LIVE

Charter on disk matched my spawn copy. Round pinned with the new `tools/audit-round.py`; I am its
first user and I did not take it on trust.

### CHECKPOINT 1 — the freeze tool itself
Watched it go red: appended one line to `rh-chain/src/EsseyPool.sol` (tracked, dirty) → `ROUND VOID
(work)` exit 1; restored from a scratch copy, sha256 identical, `round INTACT` exit 0. So I may cite
it for TRACKED content.
It has a hole: `subject()` compares only `head`, `tree` (= sha of `git ls-files -s`, the INDEX) and
`work` (= sha of `git diff` + `git diff --cached`). It RECORDS `dirty` (`git status --porcelain`) and
never compares it. Proven: `echo … > rh-chain/src/PlantedMidRound.sol` (untracked) → still
`round INTACT`, exit 0. An entire new contract can be dropped into the audited tree mid-round without
voiding it — and untracked `.sol` files are exactly what this repo's working tree carries between
rounds. Fix: add `"dirty"` to the compared key list, or hash `git status --porcelain` into `work`.

### CHECKPOINT 2 — the subshell fix is three shapes wide, and its commit message is wrong
`e032187` fixed `git_segments()` by stripping `^[(){}\s]+`. Measured against the real script with the
real payload shape: `( )`, `(( ))`, `{ ; }` now exit 2. TWELVE other shapes still exit 0 —
`sh -c`, `bash -c`, `eval`, `env`, `command`, `time`, `\git`, `$(…)`, backticks, `if …; then`,
`xargs`, `nohup`.
The commit message states, in public, that `sh -c "git push"` "against this hook it already exits 2,
so I am recording that half as not reproduced." It does not. Both registered PreToolUse guards
(guard-git.py AND guard-deploy.py) return 0 for `sh -c "git push"` and for
`sh -c "git push origin main"`, while bare `git push` returns 2.
Confirmed through the REAL caller, not a harness: bare `git push audit-probe-nonexistent-remote main
--dry-run` → hook BLOCKED it; `sh -c "git push audit-probe-nonexistent-remote main --dry-run"` →
reached git and returned git's own exit 128. With `origin` in place of the probe remote that is an
unapproved production push.
**Lesson for me: when a fix closes a bypass CLASS, the fix must be measured against the class, not
against the one example in the report.** A leading-character strip is a whitelist of three
characters; the class is "git not in command-initial position".

### CHECKPOINT 3 — the Supercycle checksum fix works, and it did not generalise
`app/web/check-reserve-basket.mjs` now asserts every BASKET entry through viem's `getAddress`, and
the assertion sits BEFORE the RPC call so the L-017 SKIP path cannot swallow it. Watched red twice:
replanting the exact shipped address `0x8fA1248c…` → exit 1 naming it; the all-lowercase form → exit
1. Restored byte-identically (sha256 `61703c6a…`), round re-checked INTACT.
Measured viem's actual contract so I was not guessing at severity: `isAddress(lowercase)` true and it
ENCODES fine; `isAddress(bad mixed case)` false and `encodeFunctionData` throws `InvalidAddressError`.
So the gate is STRICTER than the consumer (it also rejects lowercase). False-positive-only direction;
accepted, and worth it because it forces a canonical form.
The commit's own "NOT PINNED BY ANY TEST" said only BASKET is checked. I checked the rest: 84 address
literals across `app/web/src` + the gates, and **2 fail viem**. One is a test sink. The other is
`app/web/src/live.ts:69` `BUNDLE = "0x…B0B1"`, reached by `live-ui.tsx:551` and `:862` →
`flows.setPayoutToken` (`live.ts:678`) → `send()` → `writeContract`. Proven by encoding the real
`setPayoutToken(uint256,address)` ABI with the real literal: `InvalidAddressError`. Correct form is
all-lowercase `…b0b1`. The "Get paid in → Bundle" button on the live site cannot ever build a
transaction.
**Lesson for me: when a fix is scoped to one list, the audit job is to enumerate the rest of the
class in the same pass — it cost one `node -e` over 84 literals and it found a live one.**

### CHECKPOINT 4 — the frozen lending changeset (`_growth` / MAX_FORGIVEN_GAP)
Audited from an isolated copy of the EXACT frozen subject, not the worktree: `git archive HEAD` →
`git apply` of `git diff` → copied `rh-chain/lib` (55M, untracked, and I may not symlink it because
guard-git RULE 0 blocks a link into ~/Developer). Verified the copy by sha256 against the live file
before running anything. This is now my standard rig when the subject includes uncommitted work.
Verified the comment's own claim rather than believing it: `EsseyMarkets.MAX_BASELINE_AGE = 1 hours`
(`rh-chain/src/EsseyMarkets.sol:370`) really does match `MAX_FORGIVEN_GAP` (`EsseyPool.sol:100`), and
`kinkBps` really exists (`EsseyPool.sol:124`) — the DeployMarkets diff swapped a line-number citation
for that symbol, which is the right direction and the exact fix H-3 needs.

**8 mutants, 7 killed, and the survivor is NULL — I checked before reporting it.**
`dt <= MAX_FORGIVEN_GAP` → `dt <` survives all four pause tests. It is not a test gap: at
`dt == gap` the `<` form falls through, `dt -= gap` makes dt 0, and the very next line
`if (dt == 0 || totalBorrows == 0)` returns the same forgiven result. Provably equivalent at every
input. **Nearly reported this as a finding.** New habit: before writing up a surviving mutant, trace
the mutated path to an OBSERVABLE difference; if there is none, the mutant is null and saying so is
the finding.
Killed: bound→0, bound→24h, bound→30min (all three caught by the literal-span fixtures — the author
had already been bitten by parameterising fixtures on the constant under test, and says so in the
test), `&&`→`||`, dropping the current-read half, reverting to the unbounded pre-fix return, and
latching `pauseObserved = true`.

**Residual I proved with a PoC, then talked DOWN myself.** MAX_FORGIVEN_GAP bounds what ONE witness
pair buys; it does not bound total forgiveness against actual paused time. PoC in the isolated tree:
12 hours elapsed, **12 seconds actually paused**, borrower witnesses each brief pause →
charge 0 vs 95,890 (6-dec) unpaused. Then I went to the chain instead of stopping at a scary number:
`cast logs` for `Paused(address)`/`Unpaused(address)` on USDG `0x5fc5360D…d168` over all 56,147,495
mainnet blocks returns **0 and 0**, and `paused()` is false. So the precondition has no historical
basis → LOW, accepted with the rationale written down.
Honest caveat I am recording rather than burying: USDG is a proxy and I did NOT prove its pause path
emits OZ `Pausable` events, so a zero event count is weaker evidence than it looks. What would settle
it: the issuer's implementation source, or a storage-slot read of the paused flag across history.

### CHECKPOINT 5 — the round protocol and MY charter are in direct conflict, and I hit it
I appended checkpoints 1-3 to THIS FILE mid-round. It is tracked, so `work` moved and
`audit-round.py check` returned **ROUND VOID** — by my own hand, doing exactly what my charter
orders ("WRITE YOUR MEMORY BEFORE YOU REPORT"). A peer's sweep caught it before I did; credit to it,
because I would have reported a verdict that did not count.
Recovery: `git diff docs/agents/continuity/essey-auditor.md > scratchpad/my-continuity.patch`,
`git show HEAD:<path> > <path>`, re-check → INTACT, audit finished against the frozen bytes, patch
re-applied at the end. **Every auditor in every future round will hit this**, so it is a tool defect,
not my mistake alone. Recommended fix is in my report.
**Rule for me: the FIRST thing I do in a frozen round is ask which files my own process will touch,
and stage those writes outside the subject.** Scratchpad first, repo last.

### CHECKPOINT 6 — the biggest finding of the day was a fix that was scoped to its example
`9e45758` is titled "stop telling the public that lending is audited." It corrected `BASE-LAYER.md`
— the file I named yesterday — and left the same false claim live in `docs/TOKENOMICS-v3.md:178`,
which `app/web/gen-docs.mjs:47` publishes to the site. I did not stop at the repo: I pulled the LIVE
bundle, `https://essey.xyz/assets/index-DPnMhTNW.js`, and grepped it. The string
*"provably-solvent RWA lending protocol (AAPL/NVDA borrow markets already built + audited)"* is in
production right now. `MAINNET-ACTIVATION.md:129` also still reads "BUILT + AUDITED + PUSHED" against
the standing retraction at `:1582` and `:1841` of the same file.
**The pattern, and it repeated four times today:** a fix closes the INSTANCE the auditor named, not
the CLASS. BASE-LAYER but not TOKENOMICS-v3. BASKET but not `BUNDLE`. `( )` but not `sh -c`. The
literal `/Users/` form but not `~`, `$HOME` or `Downloads`.
**So my re-audit method is now: for every fix, name the class it belongs to, enumerate the class
mechanically, and check the remainder.** Every one of those four cost a single command.

### CHECKPOINT 7 — verify a commit message's negative claims, not just its positive ones
`e032187` states in public that `sh -c "git push"` "against this hook it already exits 2, so I am
recording that half as not reproduced." I ran it. Both registered PreToolUse guards return 0. I had
been reading commit messages for what they CLAIM TO HAVE FIXED; the false statement was in what the
author claimed he did NOT need to fix. A "not reproduced" is an experimental result and it expires
exactly like a green test.

### Game contracts, Wolf Game lens (new source in this push, NOT deployed)
`HitterNFTV2` PASSES lens 1: `favorOf` is written only in `entropyCallback` (`:198-205`), a provider
callback, never in a player tx; `forceRevealFloor` (`:209-217`) hands out the FLOOR band so forcing
can never be gamed upward. Good design and the comments show they knew why.
The gap I did find is lens 5 + griefing: `forceRevealFloor` does not check `revealPending[id]`.
`favorCommit` is a public mapping (`:64`) and also emitted at mint (`:152`), so once the entropy
callback is in the pending block — and RH 4663 has a PUBLIC MEMPOOL — anyone can compute
`_bandFor(keccak(randomNumber, favorCommit[id]))` before it lands and, for any Hitter past the 30-day
`FORCE_REVEAL_TIMEOUT`, front-run a Rare/Legendary down to Common for gas. Fix: revert
`forceRevealFloor` while `revealPending[id]`. Pre-deployment, so it is cheap to fix now.

### CHECKPOINT 8 — I RETRACT the USDG evidence in checkpoint 4, and a peer's lesson is why
In checkpoint 4 I wrote that `cast logs` for `Paused`/`Unpaused` on USDG returned 0 over all
56,147,495 mainnet blocks, and used that to talk the flapping-pause residual down to LOW. Then I put a
POSITIVE CONTROL under it — `Transfer` logs on the same address, which cannot be zero for a live
stablecoin — and it also returned 0. The raw output was
`Error: Max retries exceeded HTTP error 429 ... Too Many Requests` from Cloudflare; my
`| grep -c blockNumber` counted zero lines and I read it as zero events. **The bug was in the probe,
not the chain**, which is the exact failure my own CLAUDE.md records from a JSON-encoded Redis key.
essey-harness's L-023 (grep/ugrep exits 0 on a search it refused to run) is the same shape one layer
up and is what made me go back and check.
So: the flapping-pause residual's severity is **UNSETTLED, not LOW-because-measured**. What would
settle it: USDG's pause history read when the RPC is not rate-limiting — a narrow-range
`cast logs` sweep with a Transfer positive control passing FIRST, or the issuer's implementation
source to confirm the pause path even emits OZ `Pausable` events (USDG is a proxy; it may not).
**Rule I am adopting: a negative result about the chain is not evidence until a positive control on
the SAME query path has passed in the same session.** Run the control first, not after.

### The handoff, and what I would look at first if I were them
- **essey-protocol-engineer** gets the two contract-side items: the `BUNDLE` checksum one-liner
  (`app/web/src/live.ts:69` → all-lowercase `…b0b1`) and `forceRevealFloor` needing a
  `revealPending[id]` guard before HitterNFTV2 is ever deployed. The BUNDLE fix is 1 character-class
  wide but the REAL work is the gate that would have caught it: extend the viem assertion beyond
  `BASKET` to every address literal in `app/web/src`.
- **essey-web-designer / jester** get the live-site one: `docs/TOKENOMICS-v3.md:178` is rendered to
  production and says lending is audited. Fixing the file is not enough — the site must be REBUILT and
  the served bundle re-grepped, which is how I confirmed it (fetch `/`, extract
  `/assets/index-*.js`, `grep -F`).
- **essey-deployment-manager** gets `MAINNET-ACTIVATION.md:129` contradicting `:1582`/`:1841` in his
  own register, and the fact that the H-2/H-3 corrections exist ONLY in an uncommitted working tree —
  so nothing about the public repo has actually changed yet.
- **The founder** gets the guard-git hole, because it is his deploy gate and the fix is his call.
- **What I would look at first if I were any of them:** not my finding, but the CLASS behind it
  (L-024). Every one of these was the second member of a class whose first member was already fixed.
- **Feedback I still owe myself to collect:** I have not yet asked the engineer or the web designer
  what form they actually want findings in (patch-ready diff vs file:line + repro). Ask next round and
  record the answer here — my reports assume file:line is enough and I have never checked.

## 2026-09-06 (round 2) — frozen round on 017f0d8e89c6, member 1 of 3

Charter on disk matched my spawn copy again. Verified BEFORE trusting: `audit-round.py` now excludes
`docs/agents/continuity` + `LESSONS.md` from the work hash AND hashes untracked files. Watched both:
planting `rh-chain/src/AuditProbePlanted.sol` (untracked) → `ROUND VOID (work)` exit 1 (my checkpoint-1
hole from last round is CLOSED); appending to my own continuity file → `round INTACT` exit 0; appending
to `rh-chain/src/EsseyPool.sol` → VOID exit 1. So I can write memory mid-round now, and L-022 is real.

### CHECKPOINT A — the guard-git fix moved the hole, it did not close it
The widened `MUTATING` regex genuinely fixed SEGMENT DETECTION. It did not touch TARGET DETECTION, and
RULE 2b (`0 of 3 clean audit rounds`) was MASKING that the whole time — every bypass I tried on the live
repo returned exit 2 with the audit-receipt message, not the production message. **That mask lifts the
moment this round closes**, which is the only moment RULE 1 matters.
Method that found it: drive the hook in a throwaway repo with a forged 3-CLEAN receipt for THAT repo's
sha, so RULE 2b is satisfied and RULE 1 stands alone. 13 of 17 push-to-main shapes then exit 0, incl.
bare `git push` (branch main, upstream origin/main, push.default unset = simple), quoted `'main'`,
`origin HEAD`, `--all`, `refs/heads/main`, `main:main`, and any line-continuation.
Real-caller confirmation, zero risk, nonexistent remote: `... push audit-probe-nonexistent main
--dry-run` → hook exit 2; the same with `'main'` quoted → reached git, exit 128.
**Lesson: when a rule never fires because an EARLIER rule blocks everything first, that rule is
untested, not working. Satisfy the earlier gate and re-run before believing the later one.**

### CHECKPOINT B — guard-deploy was widened on the wrong axis
The `docs/` widening is correct and I watched it work (dirty `docs/BASE-LAYER.md` → `vercel --prod`
exit 2). But the gate only ever fires when the literal string `vercel` is in the command, and this
project's real deploy is `bash app/deploy.sh --web`, which reaches `vercel deploy --prod --yes` inside
`app/lib-operator-env.sh:24`. Driven against a dirty served surface it exits 0. The SCOPE axis was
widened; the INVOCATION axis was never audited.
**Lesson for me: for any gate, enumerate BOTH axes — what it inspects, and what it is triggered by. A
trigger condition is a whitelist too.**

### CHECKPOINT C — HIGH-1 recurred, in the place it does the most damage
The six lending "audited" surfaces really were fixed — I proved it on the SERVED artifact, not the repo:
new bundle `/assets/index-CyLBkAtV.js`, positive control `grep -c -F "Essey"` = 137 first, then
"built + audited" = 0 and seven surfaces reading "built-not-audited (gate 0 of 3)". Good fix.
Two classes were missed, both confirmed live in that same bundle:
1. `docs/SCOPE-robinhood-chain.md` — the retraction hit the TABLE ROW (`:261`) and not the PROSE eight
   lines above it (`:253`, still "audited (three consecutive clean 3-agent rounds)"), nor the next row
   (`:262`, "✅ Built + audited — CollateralReconciler", which is a base class of EsseyPool). And the
   "fixed" line now self-contradicts inside one table cell: "BUILT, NOT AUDITED (gate 0 of 3) (ported
   to rh-chain, 3 clean rounds)". A fix that edits the badge and not the clause beside it.
2. `docs/audits/esseyreservehook-gate-2026-08-31.md:6` — a PUBLISHED audit receipt, one of the 17 docs
   `gen-docs.mjs` PICKs, still reads "Verdict: MET. Three consecutive complete-clean rounds". The
   register's own reconciliation table says G1 is "REOPENED — round counter ZERO, two HIGHs (A-1/A-3)
   in the shipping bytes, accept-in-writing withdrawn" (`MAINNET-ACTIVATION.md:1344`, `:1355`) and
   notes the stale MET was "cited ~15 places". `:919` is one of those places, uncorrected.
   `grep -c -F "REOPENED" bundle.js` = 0.
**Lesson: I scoped my own HIGH-1 to the word "lending" and the class is "any published audit verdict
that the register has since reopened." Next round I enumerate by GATE NAME (G1/G2/G3/G-LEND), not by
product word, and diff every published receipt against the register's current state of that gate.**

### CHECKPOINT D — a peer's fan-out was right on volume and wrong on discrimination
The subagent sweep found `SCOPE-robinhood-chain.md:253` independently, which is the finding of the
round, and its Class B/C/D enumeration is better than mine would have been alone (it derived
`loop.sh:49 DUMMY_PK` to the RFC 8032 test-vector-1 Ed25519 PUBLIC key rather than reporting a scary
name — exactly right). But it flagged `README.md:35`, `market.tsx:339` and `GAME-OUTSTANDING.md:17,21`
as class-A hits. Those say the MARKET LAYER is audited, which is TRUE (rounds 1-6 are published), and
`market.tsx:416` explicitly scopes it away from lending. I checked each before repeating it.
**Rule I am keeping: a fan-out agent finds STRINGS; deciding which string is a false CLAIM is mine and
cannot be delegated. Verify every inherited hit against what the claim actually asserts before it
enters a verdict.** Delegate the enumeration, never the adjudication.

### MED-4 re-derived → LOW, and MED-5 re-derived → LOW
MED-4: drove the repo's OWN `.githooks/pre-commit` in a throwaway repo, one notation per commit.
Controls blocked (Developer/Documents/Desktop, exit 1); 11 other notations of the SAME private path
passed exit 0 — `~/`, `$HOME/`, `${HOME}/`, `Downloads/`, `.foundry/`, `.claude/`, bare `/Users/<n>/`,
`/home/`, `C:\Users`, `src/`, `Projects/`. 3 of 14. Also `:13` scans only
`git diff --cached --name-only --diff-filter=ACM`, so leaks already in the tree are never re-surfaced —
which is why `rh-chain/xyz.essey.game-keeper.plist` sits public carrying the very form the gate blocks.
Severity DOWN to LOW and here is the reasoning, not a shrug: the username is already public in the repo
URL itself (`github.com/erikastramecki/essey`), nothing leaked is a credential, key or unpublished
address, and private repo NAMES are not a security control. It goes back up the moment a leaked path
points at a secrets file.
MED-5: DOWN to LOW. `snipeSeconds` and `snipeStartBps` are `public immutable` with a public
`surchargeBpsAt(uint256)` view (`rh-chain/src/market/EsseyReserveHook.sol:67-69, :210`), and the whole
contract is already public on origin/main. The schedule is readable on chain BY DESIGN — a decaying
surcharge only deters if it is known. The continuity file's incremental disclosure is one soft signal
("the team has an open ask about raising it"), and the parameter is not yet deployed, so it is still
the founder's to set. I over-rated this last round by treating an open-source deterrent as a secret.
