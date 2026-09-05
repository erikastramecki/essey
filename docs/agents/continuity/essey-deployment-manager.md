# essey-deployment-manager — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — gap-closure program, checkpoint 1: the build gates are not on the deploy path

Dispatched to map the six org-chart gaps. Told to verify the brief rather than accept it. The single
biggest thing I found is not on the gap list at all, and it invalidates a premise I was handed.

**VERIFIED — every `check-*.mjs` build gate is dead on the production deploy path.**
- `app/web/package.json:8` wires four gates into `npm run build`: `check-agent-wiring`,
  `check-custody-audit`, `check-reserve-basket`, `check-blog-cadence`.
- `app/deploy.sh:39` runs `node gen-docs.mjs && npx vite build` — **not** `npm run build`.
- `app/web/vercel.json:3` sets `"buildCommand": "npm run build"`, but `vercel.json:7` sets
  `deploymentEnabled.main = false`, and `deploy.sh` uploads the prebuilt `dist/` (no `package.json`
  there; `deploy.sh:44` writes a derived `dist/vercel.json` carrying only `rewrites` + `headers`).
  So Vercel never executes that buildCommand.
- `grep -rn "npm run build"` across the repo returns exactly one hit: `app/web/vercel.json:3`.

So the gate written the same day to catch the AMZN-backing miss (`check-reserve-basket.mjs`) does not
run when the page ships. Neither does the custody-audit gate, which exists because real stock went to
an unaudited address. This is L-004 ("grade a fix by what is SERVED") applied to the gates themselves.

**Correction to my own brief:** I was told "adding an agent trips a build gate." True only for whoever
runs `npm run build` by hand. It is a developer-discipline gate, not a shipping gate. I nearly wrote
the map treating it as enforcement. Factor that everywhere I lean on a build gate as a mechanism.

**Also verified this pass:**
- `docs/AGENT-HIERARCHY.md:20` still says "Roster = 13 specialists + the PM"; 16 owned charters exist
  on disk. `essey-product-manager` appears nowhere in that file. The wiring gate cannot catch this —
  its `MECHANISMS` list (`check-agent-wiring.mjs:69-74`) covers LESSONS + tools + itself and diffs
  only against `AGENT-COMPANY-FOUNDATION.md`. AGENT-HIERARCHY.md, which is read-first item #1 in every
  charter, is unfingerprinted. This is the exact legal-advisor invisibility failure of 2026-09-02,
  recurring, with a new gate that does not cover it.
- `xyz.essey.liveness-keeper.plist` exists at `rh-chain/keeper/` but is NOT in `~/Library/LaunchAgents/`
  and `launchctl list` (545 jobs) has 0 matches for "liveness". Never scheduled. Independent of any
  runbook claim.
- 7 essey launchd jobs ARE loaded, all resident in `~/Library/LaunchAgents/` on the founder's laptop,
  none tracked in git. The repo cannot tell you what is actually running.
- Lessons routing is a real router, verified by difference: engineer gets L-002/003/011, jester
  L-004/005, product-manager L-012, an unknown role gets only the six universals.

**Technique that worked:** I verified the deploy-path bypass myself instead of forwarding the
subagent's claim. It was right, but its line number was off by one (`deploy.sh:38` vs `:39`), and the
whole finding is load-bearing. Re-deriving cost one command.

## 2026-09-05 — checkpoint 2: a live keeper incident, and three brief errors

**A LIVE INCIDENT found while mapping the gap that describes it.** `essey-markets` markets-keeper has
failed its heartbeat 139 consecutive times, starting `2026-09-05T04:13:14Z` and still failing at
`15:43:14Z` — ~11.5 hours — writing `ALERT consecutive heartbeat failures — grace will re-arm past
gapThreshold` every 5 minutes into
`~/Developer/essey-markets/keeper/.state/keeper.err`. The file holds 2582 ALERT
lines, so this is not the first time. Cause per the message: `Nonce provided for the transaction is
lower than the current nonce` — consistent with three markets-keeper units sharing one key, but I did
NOT confirm the key, so that half is INFERRED.
**It is TESTNET** (`essey-markets/keeper/run-keeper.sh:10` defaults `RH_RPC` to
`rpc.testnet.chain.robinhood.com`), so no real money. Say that in the same breath as the alarm — an
alarm without the blast radius is its own damage.
`launchctl` shows the process UP (pid 25432). Exactly the failure `run-keeper.sh:3` warns about:
"every chain call fails silently while the process looks alive."

**The keeper fleet runs out of the ARCHIVED fork.** 6 of the 7 loaded `xyz.essey.*` launchd units
execute scripts under `~/Developer/essey-markets/keeper/`, which
`docs/PRODUCT-TRACKER.md:772` calls the archived fork that "must not be copied from or built into."
Nobody had connected the archive ruling to the fact that production keepers live there. Archiving it
silently kills 6 units. Also `xyz.essey.markets-rehearsal-v2` fires on `StartCalendarInterval Day 31`
— which does not exist in 5 months of the year (`plutil -p` on the installed plist).

**Three errors in the brief I was given — all in my favour to catch, none fatal:**
1. "Four deploy outages in one night" — `docs/DEPLOY-CHECKLIST.md:3-5` and `:198` say **three**. A
   fourth silent-deploy failure exists at `:174-177` but is a separate site-deploy incident.
2. "A runbook instructed operators..." for the liveness keeper — the runbook was HONEST
   (`rh-chain/RUNBOOK.md:121` says plainly nothing ever ran it). The false "now actually RUNS" claim
   was in **MAINNET-ACTIVATION.md**, which is MY document. The gap-3 evidence indicts the register,
   not the runbook. Own that rather than let it sit on a writer.
3. "The treasury page understated backing for eight hours" — no source states any duration. The only
   anchors are AMZN landing 03:20 UTC and the fix at 03:54Z 2026-09-05. Do not repeat "eight hours."

**The magnitude number for gap 1:** 13 keeper/check executables in this repo, **1** has a working
scheduler (`game-keeper.sh`), 12 have none. The repo's only pager (`page-liveness-keeper.sh`, with a
real webhook + banner) is attached to a unit that has never been installed. The one job that IS
running has no alerting at all.

**Gap 6 is not structurally closed, and I can name exactly why.** `essey-product-manager` is named in
exactly one charter — its own (`grep -c essey-product-manager ~/.claude/agents/*.md` → 1 file, line 4).
It is absent from `docs/AGENT-HIERARCHY.md`, which is read-first item #1 in all 16 charters and still
says "Roster = 13 specialists + the PM" at `:20`. Fifteen stateless peers will never learn it exists.
And the gap list is double-owned: `AGENT-HIERARCHY.md:10` gives it to me, `essey-product-manager.md:3,22`
gives it to them, and the founder dispatched me today. Two documents, one job — the same shape as the
duplicated audit-gate definition this program is supposed to fix.

## 2026-09-05 — checkpoint 3: BC-001, and what the gap map actually concluded

ACK BC-001 — I sequence work and I write the register, so my characteristic failure is not writing a
bad check, it is laundering somebody else's green into program state: a gate receipt, a "3 clean
rounds", a specialist's CLEAN, a keeper that "now runs" — and from now on a register row may not
advance a gate on the strength of any of those unless I have watched that specific check fail at the
exact thing it claims to catch and seen the exit code, otherwise the row says UNVERIFIED and names
what would settle it. The proof that I needed this: I published "the on-chain symptom check now
actually RUNS ... pages on any non-zero exit" into MAINNET-ACTIVATION.md about a launchd unit that has
never been installed, and it took an auditor (glend-round-9.md:429) to catch it, not me.

**Delivered:** `docs/GAP-CLOSURE-PROGRAM.md` — the six-gap map. Recommendation: **zero permanent
agents added**, one temporary `essey-sre` that retires into `essey-protocol-engineer`.

**Two of the six I pushed back on, and I would do it again:**
- **Gap 3 (technical writer) is miscategorised.** Both cited failures are doc-drifting-from-code, not
  bad prose. The runbook omitted `ESSEY_MARKETS` while `liveness-keeper.mjs:31,40` declared it
  required — a checker catches that, a writer probably does not. Do not hire for a checking problem.
- **Gap 4 (community/inbound) is not yet a gap.** There is no channel at all to be ignored on, and
  `app/web/vercel.json:22` (`form-action 'none'`) would block a form anyway. Naming an owner for an
  empty queue is headcount ahead of demand. Deferred with a written trigger, which is itself the
  product manager's rule about deferrals being decisions.

**The audit-gate duplication is worse than "two documents."** There are THREE live definitions, and
the third is inside `~/.claude/bin/guard-git.py` itself: lines 221-224 splice the new 2026-09-04
wording onto a surviving fragment of the old, so line 223 stops mid-clause and line 224 re-asserts the
RETRACTED rule ("A finding resets the count to zero") as the last thing a blocked operator reads. The
gate's behaviour is fine (`:213-218` counts VERDICT: CLEAN >= 3); the guidance is wrong. And
`PRODUCT-TRACKER.md:30` cites ":221-223" — stopping one line before the contradiction. My own charter
at line 19 still carries the OLDEST definition ("all clean same round"). I am part of this defect.

**Method note worth keeping.** I fanned three Explore agents at the evidence and re-verified every
load-bearing claim myself before it entered the doc. Worth it twice over: one agent's line number was
off by one on the deploy-path finding, and two of their "could not verify" items I settled in one
command each (`guard-git.py` exists at `~/.claude/bin/`, outside the repo they could see;
`core.hooksPath` IS set). Tell subagents explicitly that things may live outside the repo — they
scoped themselves to the tree and reported real mechanisms as NOT FOUND.

**Hazard: the tree moved under me mid-task.** `app/web/check-agent-wiring.mjs` gained
`tools/broadcast.py` + `docs/agents/BROADCASTS.md` while I was writing, shifting every line number I
had cited from it by six. I re-derived all three citations before finalising. On any doc that cites
line numbers in a file another session is editing, re-grep the anchors immediately before you ship —
do not trust the numbers you took at the start of the session.

**Reuse catch.** I had drafted a bespoke "tell every agent the new peer exists" step for Gap 6 before
noticing `tools/broadcast.py` had landed that morning and does exactly that, with per-agent ACKs in
their own words. Replaced mine with it. Grep for the mechanism before proposing a sibling — this team
ships mechanisms faster than a stateless agent can assume they exist.
