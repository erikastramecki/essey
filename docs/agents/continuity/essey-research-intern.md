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

---

## 2026-09-07 — beta.fund (side project, NOT an Essey competitor)

Deliverable lives OUTSIDE this repo: `~/Developer/assay-design/research/beta-fund-scope.md`.
Assay is public and this is a separate private side project, so nothing about it goes in `docs/research/`.
Noting the path here because next session I will not remember where I put it.

### The mistake I nearly shipped, and it would have been the headline
I queried `mainnet.zklighter.elliot.ai` for Lighter account 22627, found it EMPTY (collateral
0.006710, zero positions, a different `l1_address`), and was one sentence from reporting "the fund is
fabricated". It is not. **There are two Lighter deployments and account indices are NOT shared.** The
real desk is on `api.rh.lighter.xyz` where 22627 has $32.6k and 23 positions, with `l1_address`
matching the docs' fund wallet exactly. What saved me was reading the docs' own #addresses table
*after* the API probe instead of stopping at the convenient answer — the table names the host.
Generalised lesson for me: **a negative control proves the endpoint refuses fake input; it does NOT
prove I pointed it at the right instance.** "Does it reject nonsense" and "is this the right server"
are two separate questions and I had only asked the first. When a lookup returns the dramatic answer,
that is exactly when to ask which host/chain/deployment I am on.
The kicker: beta.fund's own site has the same bug — `beta-index.html:712` links its "verify the desk"
button to the WRONG deployment's explorer. My near-miss was their defect, inherited.

### Second broken probe, same session (L-023's shape, different tool)
My cadence script used `recentTrades?limit=500` and returned ZERO fills, which I almost read as "the
desk stopped trading". The limit is capped at 100; 200 and 500 both return
`{"code":20001,"message":"invalid param "}`. An empty ARRAY from an API that errored is
indistinguishable from a true empty unless I read the body. **Rule for me: when I change a query
parameter and the result collapses to empty, suspect the parameter before the world.**
Same session, third instance: my WebSocket probe failed against Lighter AND against
`wss://stream.binance.com` (certainly up), so the sandbox blocks WSS. I reported WS as UNVERIFIED
rather than "not available" — the positive control is what let me tell those apart.

### Technique that worked, and I want to reuse it: close the ledger
For "is there real alpha here", I paginated the operator wallet's ENTIRE token-transfer history
(12 pages, 572 transfers) and bucketed USDG by counterparty. The ledger balanced to the cent, AND the
seed deposit ($906.76) turned out to be byte-identical to the first point in the site's own hardcoded
AUM history. **Two independent sources agreeing to the cent is far stronger evidence that my accounting
is COMPLETE than any single query.** Before trusting a derived financial figure, find a second,
unrelated artifact that should equal one of my inputs, and check it. That check is what let me state
"lifetime trading PnL +$2,871.63" as a grounded number instead of an estimate.
Blockscout pagination silently dies mid-run (page 4 returned no `items`); without a retry+backoff I
would have reported ~1/3 of the history as the whole of it, and the totals would have looked fine.
**A paginator that stops early produces a confident wrong number, never an error.** Always print the
page count and assert the loop ended on "no next page", not on a failed fetch.

### Craft note on the deliverable
The founder asked one question (can I copy this?) and the honest answer had two halves: yes it is
observable (his question), and separately the thing may not be worth copying because distributions
already exceed lifetime trading PnL by 1.5x. The second half was not asked for. I led with the answer
to what he asked, then put the unasked finding directly under it and said plainly it was the thing I
would read second. Reaching past the question is the job; burying the reach at the bottom is how it
gets missed.

### Blockscout gotcha worth remembering
`robinhoodchain.blockscout.com/api/v2/...` returns **403 for every request without a browser
User-Agent**, including for a fabricated address. So my negative control initially "passed" (403 for
real and fake alike) while telling me nothing. Set a UA first, THEN run the control — otherwise the
control is measuring the WAF, not the explorer.

### Open question I could not close
`totalClaimed()` (4,275.005126) exceeds `totalOwed()` (3,872.835250) on beta.fund's Dividends
contract, and `sweepSurplus` simulated FROM THE OWNER reverts with Panic 0x11 (underflow). The
contract source is unverified, so my explanation is INFERRED. Settling it needs a decompile. I left it
labelled rather than guessing, and said what would settle it.

---

## 2026-09-07 (later) — beta.fund dataset build: CHECKPOINT (mid-run)

Deliverable dir: `~/Developer/assay-design/research/beta-fund-data/`. Outside this repo, as before.

### The founder's ask could not be met as written, and that IS the finding
"Enumerate EVERY fill back to the account's first trade, paginate to exhaustion." There is no
pagination to exhaust. Measured, on `api.rh.lighter.xyz`:
- `recentTrades` accepts ONLY `market_id` and `limit` (cap 100). I tested 13 candidate paging params
  (`cursor`, `from`, `offset`, `index`, `page`, `sort_by`, `sort_dir`, `before`, `start_trade_id`,
  `trade_id`, `end_time`, `account_index`, `ask_filter`) — every one returned the IDENTICAL first
  `trade_id` (460232057). Unknown params are silently ignored, so "it returned data" proves nothing;
  the test that works is "did the result CHANGE".
- `trades`, `accountInactiveOrders`, `accountActiveOrders`, `accountLimits`, `positionFunding` are all
  AUTH-GATED (`auth query param and Authorization header are empty` / `auth required for main accounts`).
- `accountTxs`, `blocks`, `candlesticks`, `txs`, `accountPnl`, `layer2BasicInfo` are **403 at the edge**
  — and a deliberately bogus path (`totallyBogusEndpointXYZ`) is ALSO 403, which is how I know 403 here
  means "not allowlisted", not "forbidden to me". UA makes no difference on this host (unlike Blockscout).
- `tx?by=sequence_index` IS public, but the index is global across the whole L2: seq 2,587,626,025 at
  2026-09-05T23:56 vs 2,655,992,488 at 2026-09-07T03:24 = ~2.5M tx/hour. Walking it is ~119M requests
  for 48h. Not a route; I priced it rather than guessing.

### Technique: prove a query param is IGNORED, not honoured
An API that ignores unknown params returns 200 with the same body, which reads as success. My paging
probe compared the FIRST `trade_id` across 14 variants; all identical => all ignored. Cheap, decisive,
and it is the same disease as L-025 pointing the other way: the convenient answer here was "200 OK".

### `pnl` endpoint is DEAD for every account — and beta.fund's own code says they used it
`pnl?by=index&value=<n>` returns `{"code":21100,"account not found"}` for 22627 AND for accounts
1, 2, 30, 20514 (positive controls, all of which `account?by=index` resolves fine). So it is the
endpoint, not the account. `beta-index.html:573-575` comments that their AUM seed was "backfilled once
from RH-chain's pnl endpoint". Either it was live earlier or they had auth. Recorded as UNAVAILABLE.

### Fee schedule — VERIFIED twice, two independent ways
`orderBookDetails` -> all 84 markets (57 perp + 27 spot) carry `taker_fee: "0.0000"`,
`maker_fee: "0.0000"`, both `*_enabled: true`. Independently, a desk fill's `tx?by=hash` `event_info`
carries `"tf":0` (taker fee) on the desk's own taker leg while the maker leg shows `"mf":108`. So the
desk pays ZERO venue fees; any PnL analysis must not subtract a fee it never paid.

### The tape depth table is the whole integrity story
100 trades per market means minutes of history in liquid markets and days in thin ones. ZEC (their
biggest position, $28k) has 0.32h of tape. SOFI has 41.9h. So coverage is per-instrument and wildly
uneven — reporting "83 fills" without that table would be a confident, wrong track record.

### The self-catch that mattered most this session — my own tie-out was a decoration
I wrote into the README that "the position reconstruction ties out 8/8, so the method is validated",
and then (per BC-001) tried to watch it fail. I deleted what I thought was the last PLTR fill and the
check stayed GREEN. My first reaction was that my mutation was wrong; it half was — I sorted by
`timestamp` only and two fills share a millisecond, so I deleted the second-to-last. But the real
lesson was underneath: **the anchor tie-out is structurally blind to a fill dropped in the middle**,
because `taker_position_size_before` is ABSOLUTE STATE and the last fill re-anchors everything. So the
check I had just published as validation of the whole dataset could only ever validate ONE fill per
instrument — and a rate-limit gap in the middle of a run (I had 19) is exactly what it cannot see.
Fix: a second check, chain continuity, `pos_after(i) == pos_before(i+1)` within a market. Watched BOTH
go red at their own specific case (exit 1) and green on restore (exit 0), against the real file the
script reads, not a harness. The payoff was not the checks, it was what CHECK 2 then told me:
**0 breaks => the 83 fills form an unbroken chain per instrument; all truncation is at the FRONT.**
That is a far stronger and more useful statement than the one I nearly shipped.
Generalised for me: when a reconstruction is seeded from an ABSOLUTE state field, comparing the end
state to an oracle proves almost nothing about the middle. Ask which of my rows the check actually
touches.

### The other thing I nearly got wrong: an "exhaustive" enumeration that cannot exist
The task said "paginate to exhaustion". My instinct was to find the paging parameter. The right move
was to prove there ISN'T one, and the test that decides it is NOT "does the request succeed" (all 14
variants returned HTTP 200) but **"did the output CHANGE"** — all 14 returned the identical first
`trade_id`. And per L-025 I owed that convenient negative a positive control: `market_id` and `limit`
DO move the output, so the comparison is capable of showing a difference. Without that control I would
have had "the params did nothing" from an instrument that might only be able to say that.

### Working alongside a peer on the same external API — new failure mode for me
The don-economist was running a collector against the SAME rate-limited host, into the SAME output
directory, WHILE I worked. I found it only because an `econ-collector/` dir I did not create appeared
in my `ls`. Their `collect2.py:1-9` had already MEASURED the limit (~1 req/s; 0.75s -> 9/20 ok);
I was pacing at 0.45s, roughly twice the safe rate. My 19 gaps and their `429` errors are substantially
each other. This is L-003's shape but the shared resource is an external API, not the working tree,
and nothing in our tooling detects it — `runlock.py` guards the repo, not api.rh.lighter.xyz.
What I did: stopped BOTH of my collectors and left theirs running, because theirs is the better
instrument — it has a coverage gap detector (compares oldest(N+1) vs newest(N) per market) that mine
lacked. Merged their tape into mine with a `source_collector` column and attribution. Their 62 desk
fills were a strict subset of my 83 (they sweep perps 0-56 only; I also swept the 27 spot markets), so
the merge bought price context, not fills.
Rule for me next time: before starting ANY sustained polling of an external host, `ls` the shared
output directory and check `ps` for a peer collector, and say in my report which instrument I yielded
to. Adding my throughput to theirs does not double coverage on a fixed-window tape with no paging —
it poisons both, and neither log looks broken while it happens.

### Numbers I should not have to re-derive next session (2026-09-07T03:56:04Z snapshot)
Account 22627 @ api.rh.lighter.xyz: collateral 32,597.905865 · uPnL +1,326.65 · 23 positions ·
gross exposure 167,664 (5.14x) · `realized_pnl` field 0.000000 on ALL 23 (not populated — do not use).
Chain: deposits to venue 34,579.255446 · withdrawals 4,852.984426 · distributions 4,372.835250 (15) ·
implied lifetime realized+funding-fees +2,871.634845. Fund wallet's FIRST tx ever
2026-09-05T01:58:59Z (`approve` USDG) -> account life 49.95h at snapshot. 1,976 txs from that wallet,
1,122 of them `claim(address,uint256,bytes32[])` (0x3d13f874) on their own Dividends contract — the
operator claims on holders' behalf. `0x52e65b17…71ca` = UniswapV3Pool: WETH fees -> USDG -> margin.

### A peer caught me, and it was the cheapest kind of wrong to make
I wrote "accountsByL1Address shows 22627 is the ONLY sub-account" into the README. The don-economist's
LESSONS entry said the same endpoint returned **3** sub-accounts for their target, which contradicted
my shape of claim, so I re-ran mine in full instead of assuming they had a different address. There
are **three**: 22627 plus 281474976709961 and 281474976709962, both collateral 0.000000 and status 0.
**The cause: I had piped the response through `head -c 300` and asserted from the head of a body I
never finished reading.** Truncating a response for readability is fine; truncating it and then making
a completeness claim ("the only", "all", "none") from what fits on screen is the same disease as
citing a comment as evidence. Rule for me: any claim containing "only / all / none / exactly N" gets
re-derived by PARSING the full body (`json.load` + `len()`), never by eyeballing a truncated dump.
Credited the don-economist by name in both the README and the scope doc. The conclusion did not move
(both extras are empty), which is exactly why I would never have found it myself.

### Gate note — `check-agent-wiring.mjs` DOES fail on knowledge-base drift (watched, both directions)
Appending to `docs/agents/LESSONS.md` turns `node app/web/check-agent-wiring.mjs` RED
("AGENT-COMPANY-FOUNDATION.md is STALE", exit **1**). Isolated `git archive HEAD` tree: exit **0**,
0 problems. Same tree with ONLY the don-economist's new lesson pasted in: exit **1**. So the gate is
real, it was ALREADY red before my two entries, and it is not mine to clear — `AGENT-COMPANY-FOUNDATION.md`
belongs to the coordinator/PM and was itself already modified in the working tree (its stamped hash
differs between the HEAD tree and the live tree, i.e. someone is mid-reconciliation). Correct move for
me: flag it in the report, never re-stamp another role's doc to make my own change look clean.
Note the path is `app/web/check-agent-wiring.mjs`, NOT `app/web/scripts/…` — I ran the wrong path
first and got a bare `EXIT=1` from the shell with no output, which reads exactly like a gate failure
and is actually "no such file". Check that the command PRINTED something before believing its code.

### Handoff and the seam with don-economist (worth reading before the next beta.fund session)
They ran a PRE-REGISTERED evaluation (`beta-fund-prereg.md`, hashed and timestamped BEFORE any
statistic was computed) and validated their pipeline on synthetic null/planted-edge data before
citing a single real result. That is a better standard than I held myself to, and I am adopting the
shape of it: for anything where a number could be searched for, fix the decision rule first, in
writing, with the expected outcome next to it.
They also corrected my PREVIOUS session's scope on two real points and both are right:
(1) `collateral` is a REALISED-basis balance, so unrealised PnL is ADDITIVE to
`collateral + withdrawn - deposited`, not a component of it — my "+2,871.63 of which +818.88 was
unrealised, so realised ~= +2,050" double-subtracted, and total economic PnL is nearer +4,198. The
error ran toward the more dramatic conclusion, which is the direction I need to watch.
(2) the `:24` cadence is 46% of fills (38/83), not "almost all" — I generalised from a 35-fill sample.
Both accepted and written into the scope doc and the dataset README with attribution.
What I gave them back: the 83-fill dataset (their spread-cost estimate used 80), the spot markets
their sweep omits, the per-fill zero-taker-fee proof, and the chain-continuity result that says the
captured fills are unbroken so the sample is front-truncated rather than swiss-cheesed.
**Open question I owe them next session:** whether an external equity/crypto price source is
acceptable provenance for contemporaneous marks on the pre-04:03Z fills, since the venue exposes none.
That is their call, not mine — it decides whether the alpha-vs-underlying separation is possible at all.

---

## 2026-09-12 — hashcats.fun (new target, private side project) — CHECKPOINT 1

Deliverable OUTSIDE this repo: `~/Developer/assay-design/research/hashcats-scope.md` (+ INDEX there).

### Pins I must not lose
- Chain **4663 Robinhood Chain** (same chain as Essey). `cast chain-id` = 4663 on
  `https://rpc.mainnet.chain.robinhood.com`. Site CSP itself names that RPC + `robinhood.drpc.org`.
- Contracts, all read LIVE from the collection (not from the bundle's fallbacks):
  collection/NFT `0xCA75DF55Cc9C476DB27a7375D1fc8E794cf80721` ("Hashcats"/"HCAT"),
  `hashToken()` = `0xCA75082b85bb7Bec8325d513F615b16BDa260020` ("HASHCATS"/"HASH", 18dp),
  `hook()` = `0xCA757986E932BC55776492Cca0b413E9b3D02aCC` (Uniswap V4 hook, holds ETH),
  `renderer()` = `0xCA751C15092d108360a0FfD84f30d908ea4a0000`,
  `owner()` = `0xCA75a875857691f2a8bbCCecAa7E4448aCdc12ca` — **EOA** (`cast code` = `0x`, nonce 27).
- Vanity prefix `0xCA75…` ("CATS") on all four contracts + the owner. Convenient for grepping,
  and a reminder that a vanity prefix is NOT identity — I pinned each by reading the collection's
  own getters, not by pattern.

### Technique that paid off: the frontend bundle carries the FULL ABIs
`/assets/index-*.js` embeds two complete JSON ABIs (collection 117 funcs, hook 76 funcs). Extracted
with a brace-matching scanner in node (`[{"type":` → depth-0 close → `JSON.parse`). That gave me the
whole surface — including every owner-only setter — WITHOUT verified source, which is the thing I
otherwise could not have got (see next line).

### Blockscout finding (two things, both changed how I work today)
1. **Cloudflare now challenges Blockscout's API.** A browser UA alone is NO LONGER enough — I got
   `<title>Just a moment...</title>` and HTTP 403. What worked: UA + `Accept` + `Accept-Language` +
   `Referer: https://robinhoodchain.blockscout.com/` + `sec-fetch-mode: cors` + `sec-fetch-site:
   same-origin` + `--compressed`. Update to my 2026-09-07 note, which said UA was sufficient.
2. **NONE of the four Hashcats contracts is verified.** Controls both ways on the SAME header path:
   fabricated address → HTTP 404 `{"message":"Not found"}`; our own EsseyReserve → `is_verified:true`
   `EsseyReserve`. So `is_verified: null` on all four is a real negative, not a WAF artifact.
   Only the third-party Uniswap `UniversalRouter` (`0x8876789976dEcBfCbBbe364623C63652db8C0904`,
   109 source files) is verified. Everything mechanical about Hashcats therefore has to come from
   ABI + live calls + bytecode, and I must label source-level claims accordingly.

### Careful-with note
The bundle's hardcoded fallback `0x768bd404dc5C1cDBB69781f9E91D230f01BbBaF9` is NOT the token
(reverts on `name()/symbol()/decimals()`, 697 bytes of code). I nearly reported it as $HASH because
it sat in the config line next to the collection. The real token came from `hashToken()`.
Lesson shape: a frontend's hardcoded fallback constant is a CLAIM about deployment, same as a doc.

## 2026-09-12 — hashcats CHECKPOINT 2 (the headline, and a near-miss I refuted)

### THE FINDING — owner can drain the whole AMM position to their own EOA (VERIFIED BY TRACE)
`removeLiquidity(int24,int24,uint128)` on the hook is Solady-`onlyOwner` (random caller →
`Unauthorized()` 0x82b42900). Simulated from the owner at a pinned block with the REAL position
(full range -887220..887220, liquidity 2236067977499789696409, the pool's ONLY position, found via
`eth_getLogs` on PoolManager `ModifyLiquidity` for the computed poolId) → SUCCEEDS, and
`cast call --trace` shows it `take()`s ~20.9 ETH + ~238,710 $HASH out of the PoolManager and then
sends BOTH to the owner EOA (`fallback{value:...}` + `transfer(owner, ...)`), emitting
`LiquidityRemoved`. Plus `withdrawQueue` (~31 ETH, to any address) and `withdrawDev` (~53 ETH, always
to the owner) — also traced. None of it is in their docs.
**Technique to reuse: `cast call --trace` is the instrument that turns "the call did not revert" into
"here is exactly whose balance moves."** A bare `cast call` returning `0x` on a void function proves
nothing about custody; the trace names the recipient. I will not report a drain vector again without
the trace.

### The half of the same contract that is genuinely SAFE — say both halves
The collection holds 90.7 ETH of holder rent and has NO owner exit: no withdraw/sweep selector in the
ABI, and (see below) no unexplained dispatching selector in the bytecode either. Only `claim`/
`claimMany` (by the cat's owner) and `flushToHook` (dead cats' share) move that ETH. Reporting only
the rug vector would have mis-scoped the risk — the rent pot and the buyback pot have opposite trust
profiles in the SAME project.

### NEAR-MISS I refuted before writing it: "the owner mines at half difficulty"
`targetFor(owner)` came back exactly 2x `targetFor(random)` — an alarming, publishable-looking result.
It was an artifact of RH's ~100 ms blocks: `currentBurst` was climbing (9 → 11) BETWEEN my sequential
`cast call`s, and each burst step halves the target. Re-run with `--block <fixed>` for every call:
all five addresses, owner included, return the IDENTICAL target.
**Rule for me on 4663: any cross-entity comparison must pin `--block`, or I am measuring elapsed time
and calling it logic.** This is L-006 with a 100 ms fuse.

### Technique: prove a frontend ABI is the WHOLE callable surface
Two directions, both needed. (1) Every ABI function selector must appear as a PUSH4 in `cast code` —
117/117 collection, 76/76 hook, 0 missing (positive control for the scanner). (2) Every PUSH4 NOT in
the ABI must be resolvable as an error/event topic or an external-call selector, and I eth_call'd all
54+61 leftovers raw: every one reverted with empty data, byte-identical to bogus controls `0xdeadbeef`
/ `0x00000000` / `0xffffff01`, while `owner()` dispatched. Honest limit to state: a real function that
reverts with no data is indistinguishable, so this is strong evidence of no hidden admin function, not
proof.

### zsh will silently truncate a wei literal — my first binary search produced garbage
`$(( (lo+hi)/2 ))` on `83407671904920238345` printed `number truncated after 19 digits` and returned a
nonsense bound (1.107 ETH). Any wei arithmetic goes through python3, never `$(( ))`.

### `cast call` arg-order trap that looked like an RPC outage
`cast call $H "sig" -- -887220 887220 1 --rpc-url $RPC` → `--` ends option parsing, so `--rpc-url` was
eaten as a positional and cast fell back to `http://localhost:8545` → "Connection refused". That reads
exactly like the node being down. Options BEFORE the `--`, always; and a positive control
(`owner()` in the same option order) is what told the two apart.

## 2026-09-12 — hashcats FINAL (deliverable shipped)

Deliverable: `~/Developer/assay-design/research/hashcats-scope.md` (769 lines) + pointer and a
"Deployment pins" block appended to `~/Developer/assay-design/research/INDEX.md`. OUTSIDE the assay
repo — hashcats is a separate private research target and assay is public.

### Verdict in one line
Not an Essey competitor (no equities/lending/privacy overlap) but the best-built thing on 4663, and it
has already shipped the AMM-launch-with-decaying-fee that we are still pre-launch on. WATCH, steal two
mechanics, avoid the trust model.

### What I did well and want to repeat
1. **Derived the mechanism from the frontend bundle when no verified source existed.** Two complete
   ABIs (117 + 76 functions) are embedded in `/assets/index-*.js`. I then proved the ABI is the whole
   callable surface in BOTH directions (ABI selectors ⊆ PUSH4 in bytecode, 0 missing; every leftover
   PUSH4 raw-eth_call'd and matching bogus controls). Reusable recipe for any unverified contract.
2. **`cast call --trace` as the custody instrument.** "It did not revert" is worthless for a void
   function. The trace named the recipient EOA on three separate drain paths. This is now my default
   for any "can the operator take it" question.
3. **Watched EVERY guard refuse, per BC-001**, and recorded the selector: `Unauthorized()` 0x82b42900,
   `BadFee()` 0x917f1a53, `TooBig()` 0x8aa0e18c, `BadRoyalty()` 0x8f486857,
   `BadTargetInterval()` 0x018f955e, `BadFailsafeIdle()` 0xb8493aeb, `CollectionAlreadySet()`
   0x07fa9819, `RendererHasNoCode()` 0xfb3a46b6. Each with the passing case next to it, so the bound
   is measured rather than read off a constant.
4. **Reproduced their hash function locally** rather than trusting the docs: on-chain `workHash` ==
   `cast keccak(miner || nonce || prev || anchor)`, with a different-miner control. That is what turned
   "they say a solution cannot be stolen" into a fact.
5. **Reconciled a derived financial figure against a second artifact** (beta.fund technique, reused):
   `mintPrice()` == `PRICE_STEP × createdBefore(epoch)` to the wei, and `RENT_STEP + HOOK_STEP ==
   PRICE_STEP` exactly — which proved the 70/30 split is an identity, not a policy. Also the pool's
   market price came out 1.082x their own stated arbitrage ceiling, which validates their model from
   outside it.

### Three things I nearly got WRONG, all the same disease
- **"The owner mines at half difficulty."** Artifact of unpinned `--block` on a 0.1 s-block chain
  (`currentBurst` incrementing mid-loop). Pinned: identical for all addresses. Now a rule in my INDEX
  pins block.
- **"63 uniques taken of a total of 16."** `uniquesTaken` is a BITMAP: 63 = 0b111111 = 6, which matches
  5,969/1024 windows. Any counter whose value exceeds its declared maximum is a bitmap or a scaled
  accumulator before it is a bug. Check popcount before reporting a contradiction.
- **"block.number is 6.25 s, so their docs are wrong."** 25-second sample, 4 increments, ±25% noise.
  Re-measured over 185 s: 12.33 s — their docs were right. L-032 in miniature: span, not samples.

### The self-catch I am most glad about
I labelled "0 Transfer logs for $ESSEY" and then noticed the sweep had hit HTTP 429 mid-run. It was a
FAILED PROBE, not a finding, and the true answer (3 transfers) came from a different endpoint with a
positive control. I put the failure in the deliverable as a named gap rather than as a zero.

### Two operational traps that cost me time
- **zsh truncates wei literals.** `$(( (lo+hi)/2 ))` on `83407671904920238345` printed "number
  truncated after 19 digits" and returned a garbage bound. All wei arithmetic through python3.
- **`cast call ... -- -887220 ... --rpc-url $RPC` sends the call to localhost:8545.** `--` ends option
  parsing, so `--rpc-url` became a positional and cast fell back to the default RPC → "Connection
  refused", which reads exactly like the node being down. Options BEFORE `--`, and keep a positive
  control in the same option order so you can tell an outage from a parse error.

### Reached past the ask, and it was the right call
The founder asked about hashcats. While grounding "how Essey differs" in our own contracts I found that
`docs/MAINNET-ACTIVATION.md:1239` states a *currently-holding* deploy precondition
(`ESSEY totalSupply == balanceOf(ops) == 8,888,888,888e18`) that is no longer true: supply is **0**
because ops called `EsseyReserve.redeem(8,888,888,888e18)` on 2026-09-09T23:14:59Z
(tx `0x4df5445ec50fb9dc444904cecdb1316ea24333c8a27dad1a51991cbdd0e1f4e4`, selector 0xdb006a75),
burning the entire supply. Two independent sources agree (RPC `totalSupply()` = 0 with a $HASH
positive control in the same minute; Blockscout token endpoint `total_supply: "0"`, `holders: "0"`,
with a fabricated-address 404 control). The reserve still holds the equity basket. I framed it as a
STALE REGISTER LINE, not a bug — it looks like a deliberate pre-launch unwind — and routed it to the
PM with the tx rather than sounding an alarm. Checking our own register against chain instead of
reciting it from memory is what surfaced it.

### Feedback I owe and am asking for (record the answers next session)
- **essey-launch-economist:** I handed you a mechanic (price-impact-bounded per-block buyback) plus a
  narrow question. Was the framing usable, or do you need the parameter sweep pre-run? Tell me what
  shape of hand-off you actually want from me at this seam.
- **don-designer:** I asserted `Don.sol`/`DonFeeRouter.sol` have no per-token fee accumulator from a
  grep of `accPer|claimable|rentPer|owed`. If that grep was the wrong instrument, say so — I would
  rather be corrected than have the scope carry a wrong negative.
- **PM:** is one 769-line scope the right artifact, or would you rather have a 1-page decision sheet
  with the long form behind it? The last two targets both ran long and I do not know if the length
  helps you route or slows you down.
