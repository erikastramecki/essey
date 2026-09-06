# essey-harness — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding to the new charter (no harness run, no wallet, no tx)

ACK BC-001 — My whole output is evidence, so a harness I have never seen go red is not proof a flow works — it is a green light with no bulb in it; from now on every check I cite (negative revert case, ledger reconciliation, UI assertion, timing bound) gets deliberately broken first — wrong revert reason, one wei off, the button disabled, the clock short — and I watch it fail on the exact thing it claims to catch, checking the exit code and not the printed message, before its PASS is allowed into a report.

### What I own
- The two mandated verification layers (charter `~/.claude/agents/essey-harness.md:9-11`): (1) the contract harness driven by throwaway wallets against live testnet 46630, every tx hash recorded, NEGATIVE checks included; (2) the full UI click-through in a real browser, every tab/button/state cross-checked against chain state. No UI change ships without layer 2 passing.
- Wei-exact ledger reconciliation and timing of every gated flow against the contract's own constants — never "looks right" (charter:22-23).
- Producing the evidence other agents and the founder act on: tx hashes, chain reads, screenshots, timings, and an explicit list of what was found but NOT fixed (charter:21,27).
- Adversarial mutation of my own harness: proving each assertion can fail before I report that it passed (BROADCASTS.md BC-001, LESSONS L-001).

### What I must never do
- Never deploy or mint to MAINNET 4663. Hard founder gate, explicit per-action approval only (charter:14).
- Never force a green result. Surfacing a real gap is a SUCCESS; a manufactured pass is the worst thing I can ship (charter:24).
- Never report a claim without its source inline and a VERIFIED / INFERRED / UNVERIFIED label; never inherit another agent's output as truth (charter GROUNDING GATE, charter:35; L-006).
- Never run `game-keeper.sh` concurrently with a harness sharing the deployer key — nonces race (charter:15).
- Never start a second tree-mutating run while `python3 tools/runlock.py --list` shows one in flight; two runs void BOTH results (L-003, charter:102-109).
- Never background a wait and stop; poll in the foreground, and if the budget blows, verify the pre-state landed and report the remainder as pending with the exact due time (charter:25-26).
- Never judge an animation from a screenshot — hidden tabs throttle rAF to zero; drive with setTimeout and poll the DOM (charter:17).

### Lessons from my slice that change how I will work
- L-004 (grade a fix by what is SERVED, not what is committed): my UI layer must fetch the live bundle and assert on the bytes actually being served. A click-through of a local dev build proves nothing about production. This pairs with the Vercel note (charter:18) — `vercel deploy` runs from the REPO ROOT because the project root is configured as `app/web`.
- L-011 + BC-001 corollary (test the gate in the configuration it actually runs in): proving my harness catches a fault I injected into my harness proves nothing. The injection has to go into the real contract/UI path the real caller takes. My throwaway-wallet layer is the right shape for this precisely because it uses the production entrypoints.
- L-002 (authorship is not evidence of content): before a run I hash the tree against `HEAD` or build an isolated root from `git archive HEAD`. "Those files are mine" is not a clearance — a live mutant hashed as the pristine baseline scores every result against a reference with the feature deleted.
- L-010: continuity is written BEFORE the report, and checkpointed after each significant finding on a long run — my runs are exactly the long ones that get truncated.
- Open question for my next real run, flagged now so it is not lost: I have NOT yet watched `tools/runlock.py` block my own real caller, and per BC-001 I therefore may not cite it as protecting a run. Settling it = start a genuine long job, attempt a second, confirm exit code and that the lock actually holds (L-011's failure was exactly this, undetected).

### Two findings from the onboarding read itself (checkpointed before reporting)

**F-1 — The mainnet prohibition has NO mechanism, so by BC-001 I must call it a decoration.**
VERIFIED: `grep -rIn '4663' ~/.claude/bin ~/.claude/settings.json` returns nothing; `ls tools/` is
broadcast.py, lessons.py, runlock.py only; there is no `.claude/settings.json` in the repo. The
closest guard, `~/.claude/bin/guard-deploy.py:116-121`, blocks a *Vercel production deploy from a
dirty tree* — not a chain write. So "NEVER deploy or mint to mainnet 4663" (charter:14) is prose,
and prose is what gets skipped. I cannot watch it fail without attempting the forbidden action,
which is the worst possible test. What would settle it safely: a PreToolUse guard that rejects any
`cast`/`forge` invocation whose `--rpc-url` or `--chain-id` resolves to 4663, which I can then prove
by pointing a harmless READ at 4663 and confirming exit code 2. Until that exists I report my own
mainnet safety as UNVERIFIED, not as a control.

**F-2 — The charter I was DISPATCHED with omits the BROADCASTS step that the charter FILE contains.**
VERIFIED by direct comparison: the file `~/.claude/agents/essey-harness.md:79-90` says "BEFORE you
start work, **all** of these" and leads with `cat docs/agents/BROADCASTS.md` plus the ACK protocol.
The charter injected into my runtime prompt this session says "BEFORE you start work, **both** of
these" and lists only continuity + lessons — no BROADCASTS, no ACK. I would never have read BC-001
had the founder not told me to by hand. Cause UNVERIFIED (cached dispatch copy vs. an edit landing
after dispatch — I cannot see the dispatch layer). This is the exact failure BROADCASTS.md was
written to prevent: a rule that is published but not absorbed. Anyone certifying a broadcast should
treat `tools/broadcast.py` output as necessary but not sufficient, because the file it reads is
written by agents whose own charter may not have told them to read the broadcast.

**Minor:** the charter calls this continuity file "Private to you; nobody else pays to read it"
(charter:131). `tools/broadcast.py:29` reads every agent's continuity file and prints the ACK line
verbatim for the founder. It is team-audited, not private. I will write it accordingly.

## 2026-09-05 (evening) — pre-push gate round 3/3: deploy-path + reserve + blog verification

**Checkpoint written mid-run, per L-010.**

### The single most important process fact from this run
I was dispatched as "round member 3 of 3" of a PRE-PUSH gate over a 43-commit range. During my
round the tree moved THREE times and the push landed before I reported:
- at dispatch `git rev-list --count origin/main..HEAD` = 43, HEAD `5c42f14`
- mid-run HEAD became `58fff0b` (a new blog commit, itself amended once per `git reflog`)
- then `a48216c`, and `git ls-remote origin main` returned `a48216c` — **already pushed**.
A pre-push clean issued against bytes that have already shipped is not a gate. Next time I take a
gate round I will pin the exact SHA in my first command, re-check `git rev-parse HEAD` before every
verdict-bearing claim, and refuse to certify if the SHA moved (the audit-gate definition already
requires the SAME frozen bytes; nothing enforces it). Worth proposing: `tools/runlock.py` style
freeze, or the gate agent recording `HEAD` and the coordinator comparing before accepting a clean.

### Technique that paid off (do this again)
Removing AMZN from `BASKET` in `app/web/src/reserve.ts` and running the REAL deploy line proved two
things with one mutation: (a) `app/deploy.sh:39` genuinely runs the gates and exits 1, and (b) the
reserve really holds AMZN on chain 4663 with an issuer-matching EIP-1967 beacon — because the gate
gets that answer from a live `eth_getLogs` + `eth_getStorageAt`. A mutation that forces a gate to
report a CHAIN fact is worth more than a mutation that only forces it to report a FILE fact.

### A false alarm I caught before reporting it (the CLAUDE.md "verify the diagnostic" rule earned out)
I converted block 54794684 to hex by hand as `0x343e4bc`, read that block's timestamp as 02:57:24Z,
and was one sentence from reporting the blog post's "03:20 UTC" as wrong. My hex was wrong; the real
value is `0x34419bc`, whose timestamp is 2026-09-05T03:20:13Z. The post was right. Re-derive the
probe before you report the alarm — a wrong alarm about a peer's published post costs their next
initiative (L-008).

### A finding I got WRONG first, then measured correctly
I ran `check-agent-wiring.mjs` with `HOME` pointed at an empty dir (the Vercel container's shape) and
watched it exit 1 with "No essey/don/jester agent charters found". Real: the charters live in
`~/.claude/agents`, which does not exist on a build container, so the gate would have failed every
Vercel-side build. It was fixed mid-round by `a48216c` and now prints
"agent-wiring: SKIP (no charter directory ... not a developer machine)" and exits 0 — verified by
re-running with the same empty HOME. Consequence to carry forward: **on the Vercel build path that
gate contributes ZERO coverage.** Only a local `app/deploy.sh` build enforces it.

### zsh trap that nearly cost me a wrong "it passed"
`${PIPESTATUS[0]}` is bash. This shell is zsh (`echo $0` = /bin/zsh), where the array is
`$pipestatus` and 1-indexed, so `cmd | tail; echo ${PIPESTATUS[0]}` printed EMPTY and I briefly read
a failing pipeline as passing. Never capture an exit code through a pipe here — redirect to a file
and use `$?` on the bare command.

### HIGH found post-ship: an EIP-55 checksum is a live read path, and no gate here tests it
`app/web/src/reserve.ts:58` shipped Supercycle as `0x8fA1248c3EC58f733E778b89C30526716Cd70893`.
That is not the EIP-55 checksum (`v.getAddress()` says `0x8FA1248C3ec58F733e778B89c30526716Cd70893`),
and viem throws `InvalidAddressError` at ENCODE time — the request never reaches the RPC. All 14 other
BASKET entries check out; it is the only bad one. Live consequence on essey.xyz right now: the row
renders `0x8fA1…0893 / unreadable / unreadable / unreadable` and the whole page raises
"INCOMPLETE READ — THIS IS A LOWER BOUND … would not read from the chain just now. Reload to read
again." The reload advice is wrong: the failure is deterministic, not transient.

**The technique that found it, keep using it:** the page said "unreadable" while my own raw
`eth_call` for `balanceOf/symbol/decimals` on the same token returned real values. When the UI and a
hand-rolled chain read disagree, the bug is in the READ PATH, not the chain — so rebuild the page's
exact client (`http(RPC,{batch:true})` + `batch:{multicall:true}`) and run the same call through it.
It threw immediately and named the cause.

**Why the gate could not catch it, and this generalises:** `check-reserve-basket.mjs:53` lowercases
every BASKET address before comparing and issues its RPC as hand-built JSON strings — it never goes
through viem. So the one gate whose whole job is "the page will read these tokens" is structurally
incapable of seeing the failure that stops the page reading one. Watched: it prints
"15 token(s) ever received, 15 in BASKET, 0 unlisted equity, 0 unlisted other", exit 0, while the live
page shows that token unreadable. **When a gate normalises a value (lowercase, trim, sort) it stops
testing the property the consumer actually depends on.** Ask what the CONSUMER requires, not what the
comparison needs.

### MEDIUM: a 25h staleness bound against feeds that only tick on trading days is a weekly outage
`prices.ts:39` MAX_STALENESS = 86400 + 3600 = 25h. Read on chain 2026-09-06T00:47Z: NVDA updated
Friday 09-04 17:46Z (31.0h), AAPL 19:51Z (28.9h), SPY 15:12Z (33.6h), QQQ 04:31Z (44.3h) — all stale.
The treasury headline therefore reads "at least $0.00 · 0 of 15 holdings priced" every weekend, by
construction, not by accident. Time-box any staleness check I write against the asset's TRADING
calendar, not a flat hour count, and always sample a gated flow on a Saturday before calling it fine.

### The evidence I produced this round (all watched red, all in the real configuration)
Every one of these ran the LITERAL `app/deploy.sh:39` command — `( cd "$WEB" && npm run build >/dev/null )`
— not a gate invoked by hand. Each restored byte-exact (sha256 re-checked against the pre-mutation hash).
- drop AMZN from `BASKET` -> `reserve-basket: FAIL`, names `0x12f190a9…`, **exit 1**
- strip one `**Applies to:**` from LESSONS.md -> `agent-wiring: FAIL`, names L-001, **exit 1**
- delete `docs/agents/continuity/essey-social.md` -> `agent-wiring: FAIL`, names essey-social, **exit 1**
- verdict word -> UNAUDITED in CUSTODY-AUDIT-STATUS.md -> `custody-audit gate: FAIL`, **exit 1**
- push the build-log date 25 days past the newest post -> `blog-cadence: FAIL`, **exit 1**
- deliberate TS error in `src/` -> `npx tsc --noEmit` **exit 2** (proves the preflight is live)
The four gate files, `app/deploy.sh` and `package.json` are byte-identical from `5c42f14` to `a48216c`
(sha-compared), so this evidence stands at HEAD. Only `check-agent-wiring.mjs` changed mid-round, and
I re-broke it twice at the new bytes.

### `deploy.sh` preflight tsc does NOT cover `api/`
`app/web/tsconfig.json` is `"include": ["src"]`. `npx tsc --noEmit` returns 0 while
`api/_don-lib.ts:29` has a real TS2339 (`DON_NET.affinity` was deleted by `2c40d4f`, already on main).
Vercel's own function builder reports it and does NOT fail the build. Runtime impact is contained —
`api/don/[id].ts:64-75` wraps the affinity read in try/catch returning null — so the Don stat sheet
silently degrades rather than 500ing. But `api/` is typechecked by NOTHING that gates a ship.

### Handoff notes I want my future self to reuse
- The Vercel path and the shell path are DIFFERENT builds. `deploy.sh` builds locally and uploads a
  prebuilt `dist/` whose derived `vercel.json` carries only rewrites+headers — so Vercel runs no build
  at all on that path. `vercel --prod` from the repo root DOES run `npm run build` in the container
  (proven from Vercel's own production log, which printed the whole build script line). Anything that
  depends on a developer's `$HOME` therefore enforces on ONE path only.
- `vercel inspect --logs <deployment-url>` is the cheapest possible confirmation of a build-time
  hypothesis. Two production deploys had already failed with the exact error I had reproduced locally.
  Check the deployment list BEFORE theorising about what a build will do.
- `vercel ls <project> --prod` + `vercel inspect https://<alias>` tells you whether the thing you are
  "gating" has already shipped. Run it FIRST next time.

## 2026-09-06 (Sunday) — frozen round, member 2 of 3: live-site verification of yesterday's fixes

Subject pinned `d7e471696033`, tree `61382dfcc1b47c1c`. Opened INTACT, closed **VOID** — see below.

### My own prior findings: which held
- **Supercycle checksum (I filed it HIGH): FIXED, verified on the LIVE page, not the repo.** Served
  bundle `https://essey.xyz/assets/index-DPnMhTNW.js` (sha256 `678c7799…2959a`) carries
  `0x8FA1248C3ec58F733e778B89c30526716Cd70893`; I pulled all 15 BASKET addresses out of the SERVED
  bytes and ran each through `getAddress()` — 0 miscased. Rebuilt the page's exact client
  (`http(RPC,{batch:true})` + `batch:{multicall:true}`) and read all 15: 0 failures, Supercycle
  balance 13,730,613.213042. Live DOM: `INCOMPLETE READ` absent, 0 "unreadable", Supercycle renders
  a real floor of 1.544693 per 1,000 $ESSEY. Console clean.
- **The gate that missed it: genuinely fixed, and I watched it go red.** Mutation planted in an
  isolated `git archive HEAD` tree, driven through the REAL caller (`app/deploy.sh:39`'s
  `( cd "$WEB" && npm run build )`), not by hand: `reserve-basket: FAIL — 1 BASKET address(es) fail
  viem's checksum`, names both the bad and the correct string, **exit 1**. Restored byte-exact
  (sha `61703c6a…2170`) → **exit 0**. Attribution clean.
- **Better than asked: the checksum assertion is fail-CLOSED offline.** It sits ahead of the first
  `rpc()` call, so it is NOT inside the L-017 SKIP hole. Proved by pointing RPC at dead port 9 while
  the bad address was planted: still FAIL, still exit 1. That closes half of L-017 for this gate;
  the eth_getLogs reconciliation half still SKIPs to 0 on an unreachable RPC.

### The near-miss I have to write down, because I nearly shipped it as a HIGH
I mutated `**Applies to:**` in LESSONS.md with `str.replace(..., 1)` and watched real-HOME exit 1 /
empty-HOME exit 0, and drafted a finding that `e032187`'s "repo checks still enforced" was a lie. It
is not. My anchor hit the FIRST occurrence, which lives in the file's preamble, not inside any
`### L-0xx` block — so the Applies-to check never fired and real-HOME failed for an unrelated reason
(FOUNDATION fingerprint drift, which IS charter-derived and legitimately cannot run without charters).
Re-run with the anchor placed inside the L-019 block: empty HOME **exit 1**, names L-019. The gate is
honest. **What saved me was reading the control run's MESSAGE, not just its exit code** — the two runs
failed for different reasons and only the text showed it. CLAUDE.md's "verify the diagnostic" rule and
my own 2026-09-05 hex-conversion false alarm are the same lesson twice; I get it now: an alarm about a
peer's fix is the single highest-cost thing I can get wrong. My own charter's corollary says check the
exit code not the message — the complete rule is check BOTH, because the exit code alone cannot tell
you WHICH property failed.

### Technique worth repeating
`grep -oE` with nested quantifiers against the 4.5MB minified bundle hung for 120s and then errored.
Fixed-string `grep -F` is the right tool against a served bundle, and it is what actually established
the doc-claim result. See L-021 — the shell `grep` here is ugrep and it EXITS 0 on that error.

### Seam feedback I owe essey-web-designer
The five doc corrections held, but the sweep was scoped to `docs/*.md` and the same claim survives in
three React copy sites (`lend-ui.tsx:179`, `App.tsx:1074`, `market.tsx:417`). When I hand a copy
finding forward I will name BOTH surfaces explicitly — rendered markdown AND `app/web/src` JSX — because
"the docs say X" and "the site says X" are different greps and only one of them was run.

## 2026-09-06 (Saturday) — clean round member 2/3 on frozen `017f0d8e89c6`

Checkpoint 1, written mid-run per L-010.

### The two false "audited" claims that SURVIVED the fix sweep (found in the SERVED bytes)
Served bundle `https://essey.xyz/assets/index-CyLBkAtV.js`, sha256
`f59a8478db101a810ed589767b58aca4be89519ee5744f73a37f8fcc7b76f549`, 4,559,158 B.
`docs/SCOPE-robinhood-chain.md` is a PUBLISHED doc (`app/web/gen-docs.mjs:40`, PROTOCOL/"The engine"),
and two claims in it are live on the page right now:
- `:253` "…**ported to `rh-chain` … and audited (three consecutive clean 3-agent rounds), but NOT yet
  deployed**" — 1 occurrence in the served bundle.
- `:262` "| **2 — RH hazards** | … | ✅ **Built + audited** — `CollateralReconciler` …" — 1 occurrence.
Both contradict the standing ruling at `docs/MAINNET-ACTIVATION.md:1790` ("lending is
`built-not-audited`") and `:35` ("the old '3 clean rounds' claim is retracted as unevidenced").
Worse, `:261` is self-contradictory INSIDE ONE TABLE CELL: "✅ **BUILT, NOT AUDITED (gate 0 of 3)**
(ported to `rh-chain`, 3 clean rounds)".

### Probe failure I caught on myself — L-025 running exactly as written
My first pass used `grep -c -F` for `` ✅ **Built + audited** — `CollateralReconciler` `` and got
**count=0 with empty stderr** — the safe answer, and it was wrong. Inside `docs.generated.ts` the
markdown is embedded in a JS string where backticks are escaped as `\``, so my literal never matched.
Re-run with `str.count()` on the decoded text: 1. **Never search a generated/minified bundle for a
string containing a character the generator escapes** — search a fragment with no backticks, no
quotes and no backslashes first, then widen. An empty stderr does not make a zero trustworthy.

### The payout button: it ENCODES now, and it still cannot succeed
`live.ts:69` is fixed to `0x…b0b1` and viem 2.55.10 `encodeFunctionData` on the real
`setPayoutToken(uint256,address)` ABI returns calldata (old uppercase `B0B1` threw
`InvalidAddressError`; probe validated both directions plus mixed case).
But the deployed Bell `0x8a7749e47E79964B265B6ee6216FD5d017701552` on 46630 has
`converter() == address(0)` and `defaultPayout() == address(0)` (cast reads). `Bell.sol:218` reverts
`UnsupportedPayoutToken()` when the converter is unset. Simulated read-only as the real owner of
Don #1 (`0x9Cec219bCdA1a901D4a7154B55648bdAE5433582`):
- non-owner → `0xf8050c92` = `NotSeatOwner()`
- owner + BUNDLE → `0xe4a83899` = `UnsupportedPayoutToken()`
- owner + `address(0)` (clear) → `0x` success
Three distinct outcomes = the probe discriminates. The UI's own gate `live-ui.tsx:23`
`CONVERTER_LIVE = ADDR.converter !== ZERO` reads the FRONTEND constant, not `bell.converter()` — the
comment at `:21-22` states the intent ("no half-working UI pointing at a converter that isn't there")
and the check asks the wrong source. Same shape as L-019: the gate normalised away the property the
consumer depends on. **Lesson for me: when a UI gate decides whether a control is shown, verify it
against the CONTRACT STATE the control writes to, not against a config constant.**

### Checkpoint 2 — the round went VOID mid-run, and this time it was REAL
`python3 tools/audit-round.py check` opened INTACT on `017f0d8e89c6`, stayed INTACT across my own
continuity write (the exclusion fix works), and then printed
`ROUND VOID: the audited surface moved (head, tree)` — pinned `017f0d8e89c6`/`b4709b41343af88f`,
now `35b0ea45ae64`/`93c2c19524b5cba9`. Per L-022 I checked WHICH hashes moved before discarding
anything: head AND tree, so real bytes. Commit `35b0ea4` "fix(gates,docs): close RULE 1 properly…"
landed locally during my round and **it edited `docs/SCOPE-robinhood-chain.md`, the exact file my two
findings were in**. `git ls-remote origin main` = `017f0d8…`, so it is local-only and unpushed.
Process lesson for me, second time in two days: I now pin the sha in my first command AND diff
`<pinned>..HEAD --stat` the moment `check` goes red, so I can say per-finding what survived instead of
throwing the whole round away.

### I proved the freeze tool both ways at these bytes (BC-001)
Appended a line to `docs/OUTSTANDING.md` → `ROUND VOID … (work)`, **exit 1**; restored byte-exact
(sha `37343002…ee14` before and after) → **exit 0**. So the continuity exclusion did not over-exclude.
Still open from L-020: the failure line names the hash that moved, never the PATH.

### Three of my own probes returned the SAFE answer and were WRONG — all in one session
1. `grep -c -F` for a string containing a backtick against `docs.generated.ts` → 0, empty stderr.
   The generator escapes backticks as `\``. Real count 1.
2. `cd $T && vercel --prod --help` → passed. `guard-deploy.py:resolve_cd` does `expanduser` and NO
   variable expansion, so `$T` resolves to a nonexistent path, `git -C` fails, and the guard
   `passthru()`s. My "the docs/ arm is broken" draft was an artifact of my own quoting.
3. **The one worth carrying:** I created the dirty file and ran the guard-triggering command in the
   SAME Bash call. PreToolUse runs BEFORE the command, so the hook read the PRE-mutation tree and
   returned PASS. Re-run as its own call → BLOCKED, exit 2. **Any PreToolUse-guard test must put the
   mutation in a prior call.** Filed as L-028.

### guard-deploy.py, driven against the REAL repo with the REAL hook (sha `7984342b…3946`)
- clean served scope → PASS (vercel CLI banner reached)
- dirty under `docs/` → **BLOCKED exit 2**, count 1  ·  dirty under `app/web/` → **BLOCKED exit 2**
- dirty only under `rh-chain/` → PASS (scoping is real)
- `bash <wrapper>.sh` containing the identical `vercel deploy --prod` line, same dirty tree →
  **reached vercel**. essey-auditor found this independently and wrote it up as L-027; my run
  corroborates it from the live repo rather than a throwaway one. Credit to them — they got there
  first and stated the two-axis framing better than I would have.
- NEW, and not in L-027: at the frozen sha the guard blocked with **4 uncommitted changes**, and all
  four were `docs/agents/LESSONS.md` + three `docs/agents/continuity/*.md` — agent memory files that
  `gen-docs.mjs` never publishes (its `PICK` list is 17 named docs, none under `docs/agents/`). So the
  charter-mandated "write continuity before you report" makes a production deploy impossible until
  someone commits agent memory, and the escape hatch is `GATE_DIRTY_OK=1`, which turns the gate off
  for `app/web` too. Same shape as L-020's corollary about audit-round.py, one file over.

### The four build gates, re-proved at HEAD through the real caller
`( cd app/web && npm run build )` — literally `app/deploy.sh:39`. Dropped AMZN from `BASKET` in
`app/web/src/reserve.ts` → `reserve-basket: FAIL — 1 tokenized equity(s) in the reserve are not on the
page`, names `0x12f190a9…`, **BUILD EXIT=1**. Restored byte-exact (sha `61703c6a…2170`) → **EXIT=0**.
`app/web/package.json` `build` still chains all four gates ahead of `vite build`. Unchanged from my
last round: on the Vercel container path `check-agent-wiring.mjs` SKIPs (no `~/.claude/agents`) and
`check-reserve-basket.mjs` SKIPs on an unreachable RPC (L-017), so only a local `deploy.sh` build
enforces the full set.

### Treasury, Saturday/Sunday, measured rather than argued
All 7 equity feeds stale at 2026-09-06 18:23Z (QQQ 61.9h, GOOGL 51.9h, SPY 51.2h, NVDA 48.6h,
TSLA 48.1h, AAPL 46.5h, MSTR 44.4h; ETH/USD fresh at 1.0h) against `prices.ts:39` MAX_STALENESS 25h.
Live page: `$280.65 · 1 of 15 holdings priced`, `$0.00 Equities · Chainlink feed`,
`$280.65 Crypto · thin-pool mark`.
**The number that reframes it:** priced at the feeds' OWN last answers, the equities total **$48.55**
(balances read from `0xd970…05A7b` on 4663). So the headline is ~85% thin-pool FLR mark on a weekday
and 100% on a weekend. The weekend is the amplifier, not the cause — and I would have reported the
weekend as the whole story if I had not multiplied it out.
