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
