# Gap-closure program — the map

**Founder directive, 2026-09-05.** Six organisational gaps were identified on the agent org chart.
This document maps each one: who builds the fix, who owns it afterwards, what mechanism must exist,
who notices when it breaks, what "green" means, and in what order.

**This is a MAP. Nothing here is built.** No agent is created, no charter edited, no mechanism
written by this document. The founder rules on the map first.

**Owner of this program:** `essey-deployment-manager` (sequence + dispatch).
**Acceptance authority on "is this gap green":** `essey-product-manager`. See [Gap 6](#gap-6).

---

## Grounding note — read this before you trust a row

Every claim below carries a `file:line`, a command and its result, or is labeled **INFERRED** /
**UNVERIFIED** in plain sight. I was told to verify the brief rather than accept it, and three of its
factual claims did not survive. Those corrections are in [What the brief got wrong](#corrections).

**Every "definition of green" below requires the mechanism to be WATCHED GOING RED** before it counts.
That is not my preference; it is broadcast **BC-001** (`docs/agents/BROADCASTS.md:19-24`, founder
ruling 2026-09-05): *"You may not cite any gate, check, test, tool or command as EVIDENCE unless you
have personally watched it FAIL at the exact thing it claims to catch. Check the exit code, not the
message."* A gap closed with an unfalsified check is not closed.

Commands whose output this document rests on, all run 2026-09-05:

```
launchctl list | grep -i essey          # 7 units loaded; 0 matches for "liveness"
ls ~/Library/LaunchAgents/ | grep essey # 7 plists, none tracked in this repo
crontab -l                              # no crontab for this user
git config --get core.hooksPath         # .githooks
node app/web/check-agent-wiring.mjs     # 16 charter(s), 0 problem(s), exit 0
python3 tools/runlock.py --list         # in flight: nothing
grep -rn "npm run build" <repo>         # exactly ONE hit: app/web/vercel.json:3
```

---

<a name="finding-zero"></a>
## FINDING ZERO — the thing that is not on the gap list and changes every row

**Every `check-*.mjs` build gate is dead on the production deploy path. VERIFIED.**

| Fact | Evidence |
|---|---|
| Four gates are wired into `npm run build` | `app/web/package.json:8` — `check-agent-wiring`, `check-custody-audit`, `check-reserve-basket`, `check-blog-cadence` |
| The deploy script does not call `npm run build` | `app/deploy.sh:39` — `( cd "$WEB" && node gen-docs.mjs >/dev/null && npx vite build >/dev/null 2>&1 )` |
| Vercel would run it, but Vercel never builds | `app/web/vercel.json:3` sets `"buildCommand": "npm run build"`; `vercel.json:7` sets `deploymentEnabled.main = false`; `deploy.sh` uploads the prebuilt `dist/`, which has no `package.json`, and `deploy.sh:44` writes it a derived `dist/vercel.json` carrying only `rewrites` + `headers` |
| Nothing anywhere invokes it | `grep -rn "npm run build"` across the repo returns exactly one hit — the unused config line above |

**Why this reframes the whole program.** Three of the six gaps' proposed mechanisms are, in this
team's established idiom, build gates. That idiom currently means *"runs when a developer types
`npm run build` by hand."* It does not mean *"runs before the page ships."*

Concretely, today:

- `check-reserve-basket.mjs` — written 2026-09-04 (`515ca38`) specifically to catch the understated-
  backing miss — **does not run when the treasury page deploys.**
- `check-custody-audit.mjs` — written because real stock went to an address with no audit doc —
  **does not run when the page that publishes that address deploys.**
- `check-agent-wiring.mjs` — the gate I was told "trips when you add an agent" — is a
  developer-discipline gate, not a shipping gate.

This is [L-004](agents/LESSONS.md) ("grade a fix by what is SERVED, not what is committed") applied
to the gates themselves, and it is [L-001](agents/LESSONS.md) ("a check you have never seen fail is a
decoration") one level up: these checks *can* fail, they simply are not in the path.

**The fix is one line** — `app/deploy.sh:39` calls `npm run build` instead of `npx vite build`. It is
the cheapest high-value item in this entire program and it is a precondition for Gaps 1, 2 and 3.
Sequence it first. **It is not free:** turning it on will make the next deploy fail if any of the four
gates is currently red, which is the point, and someone must be there to read the failure.

---

<a name="corrections"></a>
## What the brief got wrong

I was asked to flag this, and I would rather be corrected now than build to a bad map.

**1. "Four deploy outages in one night" — it was THREE.**
`docs/DEPLOY-CHECKLIST.md:3-5`: *"a night where a stack redeploy broke **three** things one at a
time"*; section header at `:198` reads "The three that would have caught all of tonight". A fourth
silent-deploy failure is documented in the same file at `:174-177` (gitignored art → the SPA rewrite
answers every missing asset with a 200 serving `index.html`), but it is a separate site-deploy
incident, not part of that night. The common cause of the three is quoted at `:4-5`: *"something was
still pointing at the old stack, and nothing said so."* The count does not change the gap; carrying an
uncheckable number into a founder-facing doc does.

**2. "A runbook described the liveness keeper as live" — the runbook was honest. The REGISTER lied.**
`rh-chain/RUNBOOK.md:121` says plainly: *"this check shipped with the R4 HIGH-2 fix and nothing in the
repo ever ran it — no plist, no cron, no timer."* The false claim — *"the on-chain symptom check now
actually RUNS … a second unit runs it every 900s and pages on any non-zero exit"* — was in
`docs/MAINNET-ACTIVATION.md`, quoted verbatim at `docs/audits/glend-round-9.md:410-411` and corrected
at `MAINNET-ACTIVATION.md:1964`.

**MAINNET-ACTIVATION.md is my document.** The gap-3 evidence indicts the register and its owner, not
a technical writer who does not exist yet. I am recording that here rather than letting it sit on an
unfilled role, and it changes gap 3's diagnosis: the failure was not "nobody owns runbooks," it was
"the register asserts operational state it never checked." A technical writer would not have caught
it. A liveness check would have.

**3. "The treasury page understated backing for eight hours" — no source states any duration.**
The verified anchors are: AMZN landed in the reserve at 03:20 UTC (`515ca38` commit message) and the
fix committed 03:54Z 2026-09-05. The day AMZN landed is not stated, so the true window is either ~34
minutes or ~24.5 hours. Everything else about the incident is verified — including *"Erik, 2026-09-05:
sent AMZN to the reserve and bet that we would not notice. He was right."*
(`app/web/check-reserve-basket.mjs:4`). **Do not repeat the eight-hour figure.**

---

## The two questions every gap answers

Per the founder's ruling and [L-012](agents/LESSONS.md), headcount is a cost that must be earned, and
each gap answers two separate questions that often have different answers:

- **BUILDS** — who scopes and writes the fix. May be a temporary agent, which then retires.
- **OWNS** — who holds it forever afterwards. Must be a **standing** agent, and should almost always
  be an existing one.

A permanent new agent needs the argument that the work demands a **fundamentally different mode of
reasoning** from anything an existing department holds. "It is a lot of work" is not that argument.

**Recommendation summary — one line per gap:**

| # | Gap | BUILDS | OWNS FOREVER | New permanent agent? |
|---|---|---|---|---|
| 0 | Deploy path bypasses every gate | `essey-protocol-engineer` | `essey-protocol-engineer` | No |
| 1 | Site reliability / infrastructure | **temporary `essey-sre` (retires)** | `essey-protocol-engineer` | **No** |
| 2 | Published truth / data integrity | `essey-web-designer` | `essey-web-designer` | No |
| 3 | Technical writer / runbooks | `essey-deployment-manager` (me) | me + `essey-web-designer` | **No** |
| 4 | Community & inbound support | `essey-social` | `essey-social` | **No — and it is not yet a gap** |
| 5 | Integrations / MCP owner | `essey-protocol-engineer` | `essey-protocol-engineer` | No |
| 6 | Product manager | done | `essey-product-manager` | Already created |

**Net roster change if the founder approves this map in full: zero permanent agents added, one
temporary agent created and retired.**

---

<a name="gap-1"></a>
## GAP 1 — SITE RELIABILITY / INFRASTRUCTURE  · severity HIGHEST · cost REAL WORK

### The evidence, re-grounded (worse than the brief said)

| Fact | Evidence |
|---|---|
| **13 keeper/check executables exist. 1 has a working scheduler. 12 have none.** | Only `rh-chain/game-keeper.sh` is scheduled (`~/Library/LaunchAgents/xyz.essey.game-keeper.plist`, `launchctl list` → pid 53837). `feed-keeper.sh:6`, `degen-keeper.sh:6`, `dca-keeper.sh:8`, `cases-keeper.sh:7` each carry the schedule **as a comment** |
| The liveness keeper is an unfilled template and has never run | `rh-chain/keeper/xyz.essey.liveness-keeper.plist:22,48,50` = `__REPO__/rh-chain`; `launchctl list` (545 units) → **0** matches for "liveness"; `ls ~/Library/LaunchAgents/ \| grep liveness` → 0 files; no `liveness-keeper.log` exists anywhere on disk |
| **The repo's only pager is attached to a job that has never been installed** | `rh-chain/keeper/page-liveness-keeper.sh:41-43` (webhook `curl --fail`), `:50-51` (banner), `:54-55` (explicitly says *"This unit is NOT paging anyone. Configure it or stop trusting it."*). Its plist is also a `__REPO__` template |
| **The one job that IS running has no alerting at all** | grep for `webhook\|curl\|notify\|osascript\|alert` in `rh-chain/game-keeper.sh` → nothing. `docs/DEPLOY-CHECKLIST.md:99-100`: *"launchd only catches a crash; it cannot see the failure that actually happened on 2026-08-15, where the process was up and logging while resolving nothing"* |
| No CI, no cron, no Vercel cron | No `.github/` directory exists in this repo (every workflow YAML on disk is a vendored Foundry dep); `crontab -l` → *"no crontab for erikastramecki"*; no `crons` key in `app/web/vercel.json` or `app/operator-api/essey-operator/vercel.json` |
| The testnet feed keeper is still an open op item | `docs/DEPLOYMENT-testnet.md:139` *"the feed-keeper cron is still not installed"*; `docs/GAME-OUTSTANDING.md:29` *"Feed keeper is not running (game payouts)"*; `docs/MAINNET-DEPLOY-CHECKLIST.md:222` unchecked box: *"a dead keeper is an outage"* |

### Two things nobody had named, found while mapping this gap

**A. There is a live, unnoticed keeper failure right now. VERIFIED.**
`~/Developer/essey-markets/keeper/.state/keeper.err` shows the markets keeper's
heartbeat failing continuously — failure #1 at `2026-09-05T04:13:14Z`, still failing at `15:43:14Z`
(**~11.5 hours**), writing `ALERT consecutive heartbeat failures — grace will re-arm past gapThreshold`
every 5 minutes. The file holds **2582 ALERT lines**, so this is not the first occurrence.
`launchctl list` shows the process **UP** (pid 25432). This is precisely the failure the script's own
header warns about (`essey-markets/keeper/run-keeper.sh:3`: *"every chain call fails silently while
the process looks alive"*).

**It is TESTNET, so no real money is at risk** — `essey-markets/keeper/run-keeper.sh:10` defaults
`RH_RPC` to `https://rpc.testnet.chain.robinhood.com/rpc`. Saying that in the same breath as the alarm
is deliberate; an alarm without its blast radius is its own kind of damage.
The error text is `Nonce provided for the transaction is lower than the current nonce of the account`,
which is consistent with the three loaded `markets-keeper*` units sharing one key — but **I did not
confirm the key, so that half is INFERRED.** A `cast` read of the keeper address's nonce against the
three units' configured keys would settle it.

**B. The production keeper fleet runs out of the ARCHIVED fork.**
6 of the 7 loaded `xyz.essey.*` units execute scripts under
`~/Developer/essey-markets/keeper/` (`plutil -p` on each installed plist).
`docs/PRODUCT-TRACKER.md:772` calls that repo *"the archived fork … must not be copied from or built
into."* Nobody had connected the archive ruling to the fact that live keepers execute from there —
**archiving or deleting it silently kills six units.** Separately,
`xyz.essey.markets-rehearsal-v2` is configured `StartCalendarInterval Day 31`, which does not exist
in five months of the year.

**None of the seven installed plists is tracked in this repo.** The repo cannot tell you what is
actually running; only `launchctl` can, and only on the founder's laptop.

### OWNER

- **BUILDS: a TEMPORARY agent, `essey-sre`, which RETIRES when the work lands.**
- **OWNS FOREVER: `essey-protocol-engineer`.**

**Why a temporary agent and not a permanent one.** The build is genuinely a chunk of specialised
work — triage 13 executables into live/dead, replace two `__REPO__` templates with a real installer,
stand up one alert path and prove it fires, reconcile the fleet off the archived fork, and write the
job registry. That is focused capacity, not a standing mode of reasoning. Once the registry and the
alarm exist, holding them is *reading a check's output and fixing a keeper* — which is exactly what
the protocol engineer already does.

**Why the protocol engineer owns it afterwards, and this is the strongest absorption case on the
list:** its charter already names the directory. `~/.claude/agents/essey-protocol-engineer.md:10` —
*"The Foundry project at `…/rh-chain` — `src/`, `test/`, `script/`, `keeper/`."* It already owns the
keeper CODE. What no charter says is that it owns the keeper **RUNNING**. That one missing sentence is
the entire gap; we do not need a person for it, we need the sentence plus a signal.

**Why NOT a permanent SRE agent.** The argument would have to be that reliability requires a
fundamentally different mode of reasoning from contract engineering. It does not, here: every job in
the fleet is a script that sends transactions against contracts the engineer wrote, and diagnosing a
stuck keeper is diagnosing a nonce, an ABI, or a stale address. Splitting that from the engineer puts
the diagnosis and the code in two different heads for no gain.

### WHAT MUST BE BUILT

1. **`rh-chain/keeper/jobs.json` — a declared registry.** One entry per job: name, what it does, the
   unit that schedules it, its log path, its **liveness predicate** (what "healthy" means as a
   checkable statement), and whether it is LIVE, DEAD, or MANUAL-ONLY. A job absent from the registry
   is a job nobody decided on. This is the artifact that makes the other 12 visible.
2. **`rh-chain/keeper/check-jobs.mjs`** — reads the registry, and for every LIVE job asserts (a) the
   unit is loaded in `launchctl list`, (b) its log has been written within its expected interval, and
   (c) its own liveness predicate holds. Exits non-zero and names the job. This is the check that
   would have caught A above at minute 10 instead of hour 11.
3. **A real installer, replacing the `__REPO__` templates** — `keeper/install.sh` that seds the repo
   path, `launchctl bootout`s and `bootstrap`s each unit, and prints what is loaded. The template was
   never filled because filling it was a manual step nobody owned.
4. **ONE alert path, wired and PROVEN to fire.** `page-liveness-keeper.sh` already has the webhook and
   the banner. It needs `PAGER_WEBHOOK_URL` configured and — per [L-001] — **it must be watched
   sending a real page before it counts.** Its own text (`:54-55`) says it is currently paging nobody.
5. **A ruling and a move on the archived fork.** Either the six markets units move into this repo, or
   `PRODUCT-TRACKER.md:772` is amended to record that the fork is archived-for-source but live-for-
   keepers. Today the docs and the machine disagree.

### MAINTENANCE JOB — who notices, and how

Two layers, because the honest problem here is *who watches the watcher*:

- **Layer 1 (continuous):** `check-jobs.mjs` runs as its own launchd unit every 15 minutes and pages
  through the one wired alert path. Owner: `essey-protocol-engineer`.
- **Layer 2 (deploy-time):** the same script runs inside `npm run build`, so a deploy fails if the
  watcher itself is not loaded. **This layer only works after [Finding Zero](#finding-zero).**

Layer 2 exists specifically because layer 1 cannot detect its own absence. That is the whole reason
the liveness pager has never paged: it was a single layer, and its single layer was never installed.

### DEFINITION OF GREEN

- [ ] `jobs.json` exists and every one of the 13 executables is classified LIVE / DEAD / MANUAL.
- [ ] `check-jobs.mjs` exists **and has been watched going red** — stop a LIVE unit and see it fail.
- [ ] The alert path has been watched delivering one real page.
- [ ] All units the registry calls LIVE are actually loaded; DEAD ones are deleted, not left lying.
- [ ] The essey-markets fork question is ruled on and the docs match the machine.
- [ ] `essey-protocol-engineer.md` names **operating** the keeper fleet, not just writing it.
- [ ] `docs/agents/continuity/essey-protocol-engineer.md` records the handover and the fleet's shape.
- [ ] `docs/agents/LESSONS.md` carries the "a job with no registry entry is a job nobody decided on"
      lesson, routed to engineer + harness + PM.
- [ ] `AGENT-COMPANY-FOUNDATION.md` + `AGENT-HIERARCHY.md` reconciled and **re-stamped**.
- [ ] **RETIREMENT:** `~/.claude/agents/essey-sre.md` deleted, its continuity file archived into the
      engineer's, roster back to 16, gate re-stamped at the smaller roster.

---

<a name="gap-2"></a>
## GAP 2 — PUBLISHED TRUTH / DATA INTEGRITY · severity HIGH · cost MEDIUM

### Correction to the brief's framing

The brief says *"no role owns 'does what we publish still match the chain.'"* **A role does own it, in
writing.** `~/.claude/agents/essey-web-designer.md:24`:

> *"Copy must match the deployed contracts — cite, don't infer. Every factual claim on a page (an
> address, a number, a mechanism, 'adminless', '5% fee') must be grounded in a `file:line` or a live
> on-chain read."*

And a mechanism already exists: `app/web/check-reserve-basket.mjs` (125 lines, committed `515ca38`,
2026-09-04) reconciles the published basket against inbound `Transfer` logs and **fails on unlisted
tokenized equity** (`:117-125`), warning only on non-equity (`:96-105`).

So this gap is **partially closed already**. Reporting it as unowned would be reporting it redder than
the evidence, which is the same sin as reporting it greener. What is actually missing is four things:

| Missing | Evidence |
|---|---|
| **It does not run when the page ships** | [Finding Zero](#finding-zero) |
| **It fails OPEN on the exact condition CI is most likely to hit** | `check-reserve-basket.mjs:78-84` — `if (logs === null) { console.log("...SKIP..."); process.exit(0); }`. A sustained RPC outage makes it silently green. The commit message itself declares this |
| **It covers ONE constant out of roughly forty** | Unchecked and published live: `reserve.ts:35-36` (reserve + $ESSEY addresses), `prices.ts:17-32` (7 Chainlink feeds), `:34,40,45,50-59`, `lending.ts:34,48-49,53-54` (USDG + AAPL/NVDA token+feed pairs), `live.ts:27-69` (~24 game addresses). Zero `import.meta.env` usage in `app/web/src` — every one is baked into the bundle |
| **Published DOCS assert addresses that nothing checks** | `app/web/gen-docs.mjs:39-56` renders `docs/BASE-LAYER.md` to the live site; `BASE-LAYER.md:11-12` publishes `$ESSEY 0x315790B5…` and `EsseyReserve 0xd970Ca72…` with nothing tying them to `reserve.ts:35-36` or to chain |

### OWNER

- **BUILDS: `essey-web-designer`. OWNS FOREVER: `essey-web-designer`.** No new agent, temporary or
  permanent.

It owns `app/web/src`, it owns the constants, it owns the pages that publish them, and its charter
already asserts the duty. Handing published-truth to anyone else would split the assertion from the
person who writes it — which is the arrangement that produced the miss in the first place.

### WHAT MUST BE BUILT

1. **Generalise the one check into `check-published-truth.mjs`** covering every hardcoded on-chain
   constant the site publishes: each address resolves to a contract with the expected `symbol()` /
   `decimals()` / beacon; each Chainlink feed answers and is fresh; the two addresses in
   `BASE-LAYER.md:11-12` equal `reserve.ts:35-36`.
2. **Make it fail CLOSED.** Retry, then `exit 1` — never `exit 0` — on RPC failure.
   **Name the cost honestly:** a fail-closed network check blocks deploys during an RPC outage. The
   escape hatch must be an explicit, logged `PUBLISHED_TRUTH_SKIP=1`, never a silent SKIP. A skip
   somebody typed is a decision; a skip the script took is a lie.
3. **A doc-address check** folded into the same script, since `gen-docs.mjs` publishes those files.

### MAINTENANCE JOB

The script's exit code on every deploy (**after [Finding Zero](#finding-zero)**), plus the same script
in the layer-1 launchd sweep from Gap 1 so drift is caught between deploys rather than at the next
one. Owner: `essey-web-designer` for the content, `essey-protocol-engineer` for the sweep that runs it.

### DEFINITION OF GREEN

- [ ] Every published on-chain constant is covered; the list of covered constants is in the script.
- [ ] The check has been **watched going red** — point one constant at a wrong address (L-001).
- [ ] It fails closed on RPC failure; the skip is explicit and logged.
- [ ] It runs on the real deploy path.
- [ ] `essey-web-designer.md` names the standing check by filename, so a stateless spawn runs it.
- [ ] Its continuity file records what is covered and what is deliberately not.
- [ ] Blueprint + org chart reconciled and re-stamped.

---

<a name="gap-3"></a>
## GAP 3 — TECHNICAL WRITER / RUNBOOKS · severity MEDIUM · **MISCATEGORISED**

### I think this one is wrong, and here is the argument

Both pieces of evidence are real. Neither is a writing problem, and a technical writer would have
caught neither.

**Evidence 1 — the runbook that omitted a required dependency. VERIFIED.**
`rh-chain/RUNBOOK.md:59-61` (pre-fix) and `rh-chain/README.md:85` gave a launch command for the
liveness keeper that omitted `ESSEY_MARKETS`. The keeper declares it required at
`rh-chain/keeper/liveness-keeper.mjs:31,40` — *"ESSEY_MARKETS is required — without it no market is
observed and liquidation halts."* The fix commit `2804b2e` states it plainly: *"README.md:85 and
RUNBOOK.md:59-61 both OMITTED the required settings, so following our own runbook produced the
vulnerable state on every market."* A second instance of the identical class (`MARKET_TOKENS`) was
fixed at `RUNBOOK.md:75,82-88`.

That is **doc-drifting-from-code**. The truth was in the source the whole time. A checker that reads
the keeper's own required-var list and asserts the runbook's command contains them catches it in a
second; a careful human writer catches it only if they happen to read both files.

**Evidence 2 — duplicated audit-gate definitions. VERIFIED, and worse than reported: there are
THREE, and the third is inside the enforcement mechanism.**

| # | Definition | Where |
|---|---|---|
| A | *all three auditors clean in the SAME round* (n=1) | `~/.claude/agents/essey-auditor.md:9-10` (which calls itself "the standing gate (founder law)"), **`~/.claude/agents/essey-deployment-manager.md:19` — my own charter**, `docs/MAINNET-LENDING-SCOPE.md:301-302`, `docs/MAINNET-SHIELDED-SCOPE.md:176`, `docs/MAINNET-ACTIVATION.md:25,176` |
| B | *three CONSECUTIVE clean rounds, any finding resets* | `docs/AGENT-HIERARCHY.md:39-40`, `~/.claude/agents/essey-protocol-engineer.md:14`, `docs/OPTION-B-V4-BUILD.md:269`, `docs/OUTSTANDING.md:18,22` |
| C | **the current ruling** — *three consecutive rounds with 0 CRIT/HIGH/MED; LOWs logged, not fixed mid-gate* | Founder 2026-09-04, recorded `docs/PRODUCT-TRACKER.md:27-30` |

A and B are not paraphrases of each other; they are **different requirements** (one round vs three).
C replaced B on 2026-09-04 because B was unreachable — a competent adversarial auditor always finds
something at LOW, so the counter could never close.

**And the enforcement mechanism now contradicts itself in a single message.** `~/.claude/bin/guard-git.py`
is real and registered (`~/.claude/settings.json:10`), and its block text reads:

```
221:  "Erik's rule (2026-09-04): THREE CONSECUTIVE rounds with no CRITICAL/HIGH/",
222:  "MEDIUM gate every deploy. LOWs are logged and scheduled, not blocking —",
223:  "but ANY change to the audited surface resets the count, so LOWs are not",
224:  "deploy, acceptance included. A finding resets the count to zero.",
```

Line 223 stops **mid-clause** and line 224 is a surviving fragment of the OLD message — so an operator
who is blocked reads the new rule and then the retracted rule "A finding resets the count to zero",
last, as if it were the conclusion. **The gate's BEHAVIOUR is correct** (it counts `VERDICT: CLEAN`
lines and requires ≥3, `guard-git.py:213-218`); only the guidance is wrong. And `PRODUCT-TRACKER.md:30`
cites this as the enforced wording at *"guard-git.py:221-223"* — the citation stops exactly one line
before the contradiction.

**Also, the brief's attribution is wrong and it points at me.** The false *"the on-chain symptom check
now actually RUNS … pages on any non-zero exit"* was in `docs/MAINNET-ACTIVATION.md` — quoted at
`docs/audits/glend-round-9.md:410-411`, corrected at `MAINNET-ACTIVATION.md:1964`. The runbook was
honest throughout: `rh-chain/RUNBOOK.md:121` says *"nothing in the repo ever ran it — no plist, no
cron, no timer."* **The register is my document.** The failure was not an unowned writer; it was the
program manager asserting operational state he had not checked.

### OWNER

- **BUILDS + OWNS: `essey-deployment-manager` (me)** for canonical rule definitions and the register's
  operational claims. **`essey-web-designer`** for rendered docs, which it already owns via
  `gen-docs.mjs`.
- **No technical writer, temporary or permanent.** The mode of reasoning this needs is *"does the prose
  still match the source"* — which is the grounding gate every charter already carries — not
  editorial craft. Hiring a writer for it would put the person who checks the claim in a different
  head from the person who makes it, again.

### WHAT MUST BE BUILT

1. **`check-runbook-env.mjs`** — for each keeper, parse the env vars its source declares required
   (the `X is required` pattern at `liveness-keeper.mjs:31,40`) and assert every one appears in the
   runbook command block that launches it. This catches the exact bug, twice over.
2. **One canonical definition per standing rule, and a check that enforces singularity.**
   `docs/RULES.md` holds each standing rule once; `check-canonical-rules.mjs` greps for restatements
   of a rule's key phrases outside it and fails, requiring a link instead. Start with the audit gate,
   which currently has three live versions across nine files and two charters.
3. **Fix `guard-git.py:223-224`** — delete the orphaned old line. Two-line change, and the highest
   damage-per-character item in this document: it is the text an operator reads at the exact moment
   they are deciding whether they may deploy.
4. **Retire definitions A and B**, including from **my own charter at line 19**.

### MAINTENANCE JOB

`check-canonical-rules.mjs` and `check-runbook-env.mjs` on the deploy path (after Finding Zero).
Plus a standing PM duty already in my charter — the grounding checkpoint — extended explicitly to
*operational* claims in the register: a claim that something RUNS requires a command and its output,
not a commit. Signal: the checks' exit codes; owner: me.

### DEFINITION OF GREEN

- [ ] `docs/RULES.md` exists; the audit gate is defined exactly once and every other mention links.
- [ ] `check-canonical-rules.mjs` has been **watched going red** on a deliberate duplicate.
- [ ] `check-runbook-env.mjs` has been watched going red by deleting a var from a runbook command.
- [ ] `guard-git.py:223-224` fixed; the block message reads as one coherent rule.
- [ ] Definitions A and B removed from all nine files and both charters, mine included.
- [ ] `essey-deployment-manager.md` names the operational-claim rule; my continuity records it.
- [ ] `LESSONS.md` entry routed to PM + auditor + engineer: *a rule that exists in two places has no
      canonical version, and the enforcement text is a place.*
- [ ] Blueprint + org chart reconciled and re-stamped.

---

<a name="gap-4"></a>
## GAP 4 — COMMUNITY & INBOUND SUPPORT · **NOT YET A GAP — DEFER**

### The finding

There is **no inbound surface of any kind.** Verified across `app/`:

- **No `<form>` element anywhere** in `app/web/src`.
- No `mailto:`, no support/contact/hello address. The two incidental hits are a regex excluding
  `mailto:` in `app/web/gen-docs.mjs:80` and the string `Discordbot` as a crawler user-agent in
  `app/web/prerender-blog.mjs:4`.
- No Discord, no Telegram link.
- The footer has three columns, all internal routes (`app/web/src/App.tsx:1006-1116`).
- Five API routes exist; **none receives a user report.** `api/relay.ts` is a zk relayer to a
  hardcoded 4-pool allowlist (`:20-25`); `api/don-reveal.ts` writes an NFT preimage to Redis; the
  other three are chain reads and image renders. `app/operator-api/essey-operator/api/` is an **empty
  directory**.
- **The site's own CSP forbids form submission** — `app/web/vercel.json:22` sets `form-action 'none'`.
  A contact form added today would be blocked by our own header.

The only reachable channel is replying to `@EsseyMarkets` on X, which is wired to nothing in code.

### Why I am calling this miscategorised

The brief frames it as *"two agents publish, none reads."* That is true, and it is **not yet costing
us anything**, because there is no channel for a user to be ignored on. Naming an owner for inbound
replies today means naming an owner for an empty queue. That is headcount ahead of demand, and it is
the precise thing [L-012] warns against.

The ordering is also backwards. Before anyone owns replies:

1. **The founder must rule which channel** (X DMs, a Discord, an inbox). That is a decision, not a
   build, and nobody else can make it.
2. The CSP must change if the answer is a form (`vercel.json:22`).
3. Most flows are still pre-mainnet. Inbound support for a protocol whose contracts are not yet
   deployed is support for a demo.

### OWNER — when it is time

- **BUILDS: `essey-web-designer`** (the surface — it owns the footer, the CSP, and the pages), after
  the founder's channel ruling.
- **OWNS FOREVER: `essey-social`.** It already owns the `@EsseyMarkets` seam, and inbound is the same
  channel read backwards. Its charter would gain a listening duty and an **inbound dossier** —
  append-only, dated, using the pattern already proven at
  `~/.claude/agents/essey-research-intern.md:82-97` (read first, append never overwrite, dated
  snapshots so a trend is visible). Reuse that; do not invent a second format.
- **No new agent.** The mode of reasoning — *what are people actually saying about us, and what does
  it mean* — is the social role's own question, pointed inward.

### TRIGGER TO OPEN THIS GAP

Both of: (a) the founder rules on a channel, **and** (b) one flow is verified live on 4663 with real
assets. Until then this stays on the map as DEFERRED with its reason, per the product manager's rule
that a deferral is a decision that gets written down.

### DEFINITION OF GREEN (for when it opens)

- [ ] One channel exists and is linked from the site; CSP updated if it is a form.
- [ ] `essey-social.md` names the listening duty and the dossier path.
- [ ] `docs/research/inbound-dossier.md` exists with its first dated entry.
- [ ] A named cadence for reading it, and a signal when it goes unread (the shape of
      `check-blog-cadence.mjs`, which exists precisely because a comms duty failed silently).
- [ ] Blueprint + org chart reconciled and re-stamped.

---

<a name="gap-5"></a>
## GAP 5 — INTEGRATIONS / MCP OWNER · severity MEDIUM · cost CHEAP

### The evidence — the rule has never once been honoured

The standing rule is written in three places, all prose:
`mcp/essey-game.mjs:9-17` (*"SHIPS WITH EVERY GAME CHANGE … in the same commit"*),
`docs/DEPLOY-CHECKLIST.md:131`, `docs/SCOPE-h1-redeploy.md:68`.

**Compliance is 0 out of 5 eligible commits, and the commit sets are literally disjoint:**

```
comm -12 <(git log --format=%H -- rh-chain/src/game/ | sort) \
         <(git log --format=%H -- mcp/            | sort)   →  EMPTY
```

Six commits ever touched `rh-chain/src/game/`; twelve ever touched `mcp/`; **zero overlap.**

| Commit | Game-contract change | MCP in same commit |
|---|---|---|
| `c7d0e60` 2026-09-01 | `MissionBoard.sol` **payout semantics rewritten** — provision-only briefs `scrip.move` (HELD) instead of `scrip.burn` | **NO** — last MCP commit was 16 days earlier |
| `97196c1` 2026-08-21 | `RaidEngine.sol`, `HouseEscrow.sol` — H-1 fix | **NO** |
| `8ebeaa1` 2026-08-15 | traits become live gameplay in `MissionBoard`/`RaidEngine` | **NO** — patched by a *separate* later commit `87c7433` |
| `fbf755f` 2026-08-15 | new `AffinityRegistry.sol` (380 L), `AffinityTraits.sol` (602 L) | **NO** |
| `0e8b869` 2026-08-13 | round-2 gate fixes across 7 game contracts | NO — but predates the MCP game half; excusable |

**Enforcement: none exists.** `.githooks/pre-commit` is real and active
(`git config --get core.hooksPath` → `.githooks`), but it is
purely a secret/private-path/template gate — `grep -rn "mcp\|essey-game" .githooks/` returns nothing.
No CI. No pre-push hook covering it.

**Live divergence, flagged UNVERIFIED:** `mcp/essey-game.mjs:221` still tells players *"Provision is
BURNED at dispatch"*, which `c7d0e60`'s V2 `MissionBoard` makes conditionally false. Whether players
are being misinformed depends on whether V2 is deployed at the board the MCP actually queries
(`0x15D6…CDF1`). **A `cast call` on that board settles it and should be step one.**

**Credit where due:** the MCP is *not* currently drifted on addresses or ABI. `mcp/essey-game.mjs:25-32`
matches `docs/DEPLOYMENT-testnet.md:112,162`, and the `briefs` tuple at `:60-65` still matches
`struct Brief` at `rh-chain/src/game/MissionBoard.sol:39-52`. The rule has been broken five times and
got away with it; that is luck, not health.

### OWNER

- **BUILDS + OWNS: `essey-protocol-engineer`.** No new agent, temporary or permanent.

The MCP hardcodes the same addresses and ABI fragments the engineer already maintains, and the rule's
**trigger is a contract change — which is the engineer's own commit.** Giving this to a separate
"integrations owner" would mean the rule fires on one agent's commit and lands in another agent's
inbox, which is how it got skipped five times. Put the duty where the trigger is.

### WHAT MUST BE BUILT

1. **Extend `.githooks/pre-commit`**: if the staged set touches `rh-chain/src/game/` (or the address
   book) and `mcp/` is not in the same staged set, **block**, naming the coupling map at
   `mcp/essey-game.mjs:9-17`. Explicit escape `MCP_OK=1` for the genuinely-unaffected change — a
   typed exception is a decision, a silent pass is not. This extends a working, active mechanism
   rather than adding a new one, which is why it is the cheapest item here.
2. **`check-mcp-drift.mjs`** — assert each MCP ABI fragment matches the current Solidity struct/
   signature, and each MCP address matches the canonical address book. It would pass today, so per
   [L-001] it must be **broken deliberately and watched going red** before it counts.
3. **Settle the `"Provision is BURNED"` string** against the deployed board and fix or keep it.

### MAINTENANCE JOB

The pre-commit hook fires at the moment of the coupled change — the only moment the author has the
context to comply. `check-mcp-drift.mjs` runs on the deploy path as the backstop for anything that
took the `MCP_OK=1` exception. Signal: hook exit 1, then check exit 1. Owner:
`essey-protocol-engineer`.

### DEFINITION OF GREEN

- [ ] Hook rule live and **watched blocking a real game-contract commit with no `mcp/` change.**
- [ ] `check-mcp-drift.mjs` watched going red on a deliberately mismatched ABI fragment.
- [ ] The `"Provision is BURNED"` claim settled against chain.
- [ ] `essey-protocol-engineer.md` names the MCP as part of its owned surface — today no charter
      mentions the MCP at all.
- [ ] Its continuity file records the coupling map.
- [ ] `LESSONS.md` entry routed to engineer + PM + dons-director: *a coupling rule enforced by memory
      has a measured compliance rate, and ours was zero.*
- [ ] Blueprint + org chart reconciled and re-stamped.

---

<a name="gap-6"></a>
## GAP 6 — PRODUCT MANAGER · **created, NOT green.** Three things remain.

`~/.claude/agents/essey-product-manager.md` exists, the wiring gate accepts it (`node
app/web/check-agent-wiring.mjs` → *16 charter(s), 0 problem(s)*, exit 0), and
`AGENT-COMPANY-FOUNDATION.md:110` shows the program/product split. That is **built**. It is not green.

### 1. The new peer is structurally invisible to all fifteen others

- `grep -c "essey-product-manager" ~/.claude/agents/*.md` matches **exactly one file — its own**
  (line 4). No other charter mentions it. Not mine.
- `docs/AGENT-HIERARCHY.md` — which is **read-first item #1 in every charter** — does not contain the
  string at all, and `:20` still reads *"Roster = 13 specialists + the PM."* Sixteen owned charters
  exist on disk.

Every peer spawns stateless, reads the org chart, and concludes the role does not exist.

**This is the identical failure recorded three days ago** in that same file's legal-advisor addendum:
*"the charter had existed since 2026-08-31 but was never listed here, so the agent was invisible to
the org and to every other agent's read-first."*

### 2. The gap list is double-owned — the same defect Gap 3 is about

| Claimant | Text |
|---|---|
| me | `docs/AGENT-HIERARCHY.md:10` — the PM *"keeps the gap list"* |
| product manager | `~/.claude/agents/essey-product-manager.md:3` and `:22` — *"owns the gap-closure program … You keep that list and you keep it honest"* |
| me, again | the founder dispatched me to own it today |

Three claims, two documents, one job. **Proposed resolution, mirroring the program/product split
exactly:** I own the **sequence** — which gap runs when, who is dispatched, what blocks what.
The product manager owns **acceptance** — whether a gap is genuinely green, which is already the
strongest and most specific section of its charter. Both charters get amended to say so; neither keeps
the ambiguous phrase "keeps the gap list."

### 3. The wiring gate cannot catch #1, and one line fixes that forever

`check-agent-wiring.mjs:79-85` lists the mechanism files it fingerprints — `tools/lessons.py`,
`tools/runlock.py`, `tools/broadcast.py`, itself, `docs/agents/LESSONS.md`,
`docs/agents/BROADCASTS.md` — and it diffs the resulting hash only against
`docs/AGENT-COMPANY-FOUNDATION.md` (`:138-152`). **`docs/AGENT-HIERARCHY.md` is unfingerprinted.**

So the gate is green right now (`node app/web/check-agent-wiring.mjs` → *16 charter(s), 0 problem(s)*)
while the org chart every agent reads first is a roster short. Adding `docs/AGENT-HIERARCHY.md` to
`MECHANISMS` — one line — should make every future roster change fail the build until *both* documents
are reconciled. **After [Finding Zero](#finding-zero), this is probably the highest-leverage single
line in the program**, because it converts "remember to update the org chart" from a note into a rule.

**Labelled honestly, per BC-001: that last claim is INFERRED, not verified.** I have read the
fingerprint function; I have not added the line and watched the gate go red on a deliberate
chart/roster mismatch. Whoever implements it must do exactly that before citing it as a mechanism.

### 4. Use the broadcast surface that already exists — do not invent a second one

`docs/agents/BROADCASTS.md` and `tools/broadcast.py` landed today and are already fingerprinted by
the gate (`check-agent-wiring.mjs:82,85`). A broadcast is precisely the mechanism for *"a rule that
went to EVERY agent at once,"* with per-agent acknowledgement in the agent's own words
(`BROADCASTS.md:7-14`), and `python3 tools/broadcast.py` reports who has not absorbed it.

**"`essey-product-manager` exists, here is the seam, here is when to route to it" is a broadcast, not
fifteen charter edits.** That is the cheapest correct fix for item 1 above and it reuses a working
mechanism rather than building a sibling. The org-chart entry is still required — the broadcast tells
the fifteen agents alive today, the chart tells every agent spawned after.

### OWNER

**BUILDS + OWNS: `essey-deployment-manager` (me)** for the org-chart reconcile and the gate line;
the seam definition is agreed jointly with `essey-product-manager`, since it constrains us both.

### DEFINITION OF GREEN

- [ ] `AGENT-HIERARCHY.md` lists `essey-product-manager` with its seam, and `:20`'s roster count is
      correct.
- [ ] A broadcast announcing the role and the seam is pushed, and `python3 tools/broadcast.py` shows
      every standing agent acknowledging it **in its own words** — the file is explicit that counting
      the lines is not certifying them (`BROADCASTS.md:12-13`).
- [ ] `check-agent-wiring.mjs` fingerprints `AGENT-HIERARCHY.md`, and it has been **watched failing**
      on a deliberate roster/chart mismatch.
- [ ] The gap-list ambiguity is resolved in both charters — sequence vs acceptance, named explicitly.
- [ ] At least one other charter references the product manager, so the seam is discoverable from the
      other side.
- [ ] `docs/agents/continuity/essey-product-manager.md` has a first real entry (it is currently the
      6-line seed, and the gate prints *"has never written to its continuity file"* for it — along
      with all 15 others).
- [ ] Blueprint + org chart reconciled and re-stamped.

---

## SEQUENCE AND DEPENDENCIES

### The dependency that dominates everything

```
FINDING ZERO  (app/deploy.sh:39 → npm run build)
      │
      ├──► Gap 1 layer-2 (deploy-time job check)
      ├──► Gap 2 (published-truth check)
      ├──► Gap 3 (canonical-rules + runbook-env checks)
      └──► Gap 5 backstop (mcp-drift check)
```

**Every build-gate mechanism proposed in this document is decorative until Finding Zero lands.**
Only two mechanisms here are independent of it: the Gap 5 **pre-commit hook** (git-hook path, already
active) and the Gap 1 **layer-1 launchd sweep**.

### A friction cost to budget for, which is easy to miss

`check-agent-wiring.mjs` fingerprints `LESSONS.md` **including its bodies** (`:104-110` — *"an
id-and-tags fingerprint let a rewritten lesson through"*). So **appending a lesson breaks the build**
until `AGENT-COMPANY-FOUNDATION.md` is reconciled and `--stamp`ed. Four of the six gaps have a
`LESSONS.md` entry in their definition of green.

**Therefore: batch the blueprint reconcile once per phase, not once per gap.** Four separate
reconcile-and-stamp cycles is four times the cost for one document's worth of prose. This is
deliberate friction working as designed — but it should be paid deliberately.

### Phase 1 — CHEAP. Hours, not days. One phase, one reconcile.

| Order | Item | Who | Why first |
|---|---|---|---|
| 1 | **Finding Zero** — `app/deploy.sh:39` → `npm run build` | `essey-protocol-engineer` | One line; unblocks four gaps. Expect the first run to fail — that is the point |
| 2 | **Gap 6.3** — add `AGENT-HIERARCHY.md` to the gate's `MECHANISMS` | me | One line; makes every future roster drift self-enforcing |
| 3 | **Gap 6.1/6.2** — org chart reconcile + the sequence/acceptance seam | me + `essey-product-manager` | ~30 min; the peer is invisible until it lands, and item 2 will now fail the build until it does |
| 3b | **Gap 6.4** — broadcast the new peer + seam; collect ACKs | me | Reuses `tools/broadcast.py`; tells the fifteen agents already alive, which the chart edit alone does not |
| 4 | **Gap 3.3** — fix `guard-git.py:223-224` | me | Two lines; it is the text an operator reads while deciding whether to deploy |
| 5 | **Gap 5.1** — the pre-commit MCP coupling rule | `essey-protocol-engineer` | Extends an active hook; independent of Finding Zero |

### Phase 2 — REAL WORK. Days.

| Order | Item | Who | Notes |
|---|---|---|---|
| 6 | **Gap 1** — the whole fleet | temp `essey-sre` → `essey-protocol-engineer` | The largest item in the program. Start with the live testnet keeper incident and the archived-fork ruling, which are decisions, not builds |
| 7 | **Gap 2** — generalise published-truth | `essey-web-designer` | Can run in parallel with 6; different files, different agent. **Take the runlock if either mutates the tree** (L-003) |
| 8 | **Gap 5.2 / 5.3** — MCP drift check + settle the BURNED string | `essey-protocol-engineer` | Queued behind 6 — same agent, do not split its attention |

### Phase 3 — MEDIUM, and honest about being second-order.

| Order | Item | Who |
|---|---|---|
| 9 | **Gap 3.1/3.2/3.4** — canonical rules, runbook-env check, retire definitions A and B | me + `essey-web-designer` |

### DEFERRED, with its reason recorded

| Item | Trigger to open |
|---|---|
| **Gap 4** — community & inbound | Founder rules on a channel **AND** one flow is verified live on 4663 with real assets |

### Founder decisions on the critical path

These are the real blockers; none of them is a build.

1. **Approve or reject the temporary-agent pattern for Gap 1** (`essey-sre`, retiring to the protocol
   engineer). Everything in Phase 2 waits on this.
2. **Rule on the archived fork** — six live launchd units execute from
   `~/Developer/essey-markets/keeper/`, which `PRODUCT-TRACKER.md:772` says must not be built from.
   Move them, or amend the ruling. Today the docs and the machine disagree.
3. **Rule on Gap 4's channel**, or confirm the deferral.
4. **Confirm the Gap 6 seam** — PM owns sequence, product manager owns acceptance.
5. **Acknowledge the Phase-1 deploy risk** — after Finding Zero, the next deploy fails if any of the
   four gates is red. That is desirable and it needs somebody present.

