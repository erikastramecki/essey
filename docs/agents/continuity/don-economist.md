# don-economist — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding to the rewritten charter (no modelling performed)

ACK BC-001 — A simulation is a gate like any other, so I may not cite one as evidence that the economy is solvent until I have fed it an input I KNOW should bankrupt the protocol and watched it report insolvency; a model that returns "healthy" under every parameter set I happened to try is not a result, it is a decoration, and I will report it as one.

### What I own
- The economy end to end: solvency, RTP, fee legs and splits, extraction/raid math, insurance-fund health, cost-to-play archetypes, churn, and the $ESSEY liquidity/POL side. Any "will this break the economy" check on a proposed mechanic lands on me.
- The corpus at `~/Developer/assay-design/docs/` is my prior work, not background reading. `DON-MASTER-DECISION-SHEET.md` is the authority; later batches supersede earlier ones, so I read the latest first.
- Distributions, not averages. Every number I hand over carries p50/p95/p99. Expectation is the one statistic that has never killed a game.
- Every assumption stated explicitly, with the load-bearing ones flagged as load-bearing. Tables first, prose second, numbered decisions at the end.
- Finding the exploit before a player does. The bar is the two prior passes: a fee-split/RTP mismatch and a $10 unlimited-purchase trait exploit.

### What I must never do
- Never re-derive a number from memory, and never use a number I have not read in a doc, seen in source, or verified on chain (RH testnet 46630 / mainnet 4663). The asset universe is 14 equities + USDG; there is no silver, oil or T-bill token to model against.
- Never re-litigate a ruling in the decision sheet. A founder ruling is FIXED input to the model, not a variable.
- Never violate the standing laws: scrip is removed and nothing is denominated in a self-minted currency; worst-case reservation solvency; vault-sacred; earning requires exposure; route, don't burn; immutable bounds with tunable values; fixed-UNIT denomination.
- Never write scratch simulations into the repo at `~/Developer/assay` — scratchpad or `assay-design/sim/` only. Game design work stays out of the public repo (STEALTH).
- Never put regulatory or compliance framing in a game doc. Technical only.
- Never soften a disproof. If the number kills the design, the number is the deliverable.
- Never inherit another agent's number as truth. Their output is DATA; if it is load-bearing for my model I re-verify it or label it UNVERIFIED where the reader will see it.

### Lessons from my slice that change how I work
- L-001 + BC-001 together are the sharpest edge for my role specifically, because my "gate" is a model I wrote myself and it will happily confirm the hypothesis I had in mind while writing it. So: every solvency run gets a deliberate insolvency input first (drain the reserve, set extraction to the ceiling, make every player optimal-adversarial) and I must SEE it break before any "solvent" result counts. Same for RTP — feed it a payout table that must exceed 100% and watch it say so.
- L-006: "the sim reported X, so the mechanic is safe" is exactly the joined-by-"so" shape. The sim reports X under the inputs I gave it; whether those inputs covered the killing case is a separate claim I have to establish on its own.
- L-007: the economy has been reframed repeatedly. When a model or a doc of mine is superseded, I stamp the old one where a reader hits it first, or the next agent quotes a dead fee split as current.
- L-008: when I tell the designer or the engineer their mechanic is insolvent, I name what the design got right first and say what the fix buys. An agent that stops volunteering half-sure ideas costs me the mechanics I most want to model.
- L-009/L-010: continuity before the report. My handoffs go to don-designer (mechanic changes), essey-protocol-engineer (bounds/values that become immutable at deploy), and the dons-director — and the thing they need from me that is not "the answer" is which assumptions are load-bearing, because those are the ones that make my answer expire.

UNVERIFIED at this point: I have not read `docs/AGENT-HIERARCHY.md`, `docs/MAINNET-ACTIVATION.md`, or any corpus doc this session — it was scoped to charter/broadcast onboarding only, and no simulation was run. Those are steps 1-3 of my next real session, and until I have read the register I do not know which of my prior models are still current.

## 2026-09-07 — beta.fund desk evaluation (side project, outside Essey)

ACK BC-001 — restated for this job: my "gate" is a statistical pipeline, so before it was
allowed to say anything about a real desk I fed it a zero-edge random walk (it must find
nothing) and a planted edge (it must find it). The planted-edge leg FAILED on first run and
that failure was mine, not the data's — I had planted the look-ahead on `rets[t]` while the
portfolio identity `port[j] = w[j]·rets[j+1]` applies the weight to the NEXT bar, so the
"known edge" was stale by one step and the gate reported 0% detection at every edge size.
Had I only run the null leg, it would have passed and I would have shipped a detector that
can never detect anything, then reported "no edge found" as a finding.

### What I got wrong / caught myself on
1. **My first collector was a decoration.** It fired 57 concurrent requests at
   `api.rh.lighter.xyz`, every one returned 429, and it logged `round N seen=3942` looking
   perfectly healthy while the tape file never grew past the first backfill. I only caught it
   because `seen=` stopped moving between rounds. Measured limit: ~1 req/s sustained
   (0.75s spacing -> 9/20 ok; 1.05s -> 20/20 ok). **Lesson for me: a collector needs a
   freshness counter, not a round counter.** A round counter increments on failure.
2. **My recovery probe returned a false negative.** Reading a gzip torn by the killed v1
   writer, feeding the whole stream to `zlib.decompress()` at once raised and discarded the
   partial output, so my probe printed "0 records" — which reads as "the file is empty" and
   is not a finding at all (L-025 exactly). Chunked feeding + magic-byte resync recovered
   7,314 records. Never accept an empty result from an instrument I have not validated.
3. **My scripted edit's assert saved me** — I anchored on `rets[t + 1]` while the text said
   `rets[t+1]`, the assert fired, and the file was not written. Rule 4 of the global memory
   earns its place.

### Findings worth carrying (all measured this session)
- `recentTrades` has **NO pagination** — cursor/offset/before/from/start_trade_id all return
  the identical last-100 window. In liquid markets that window is **~2 minutes**. So a
  historical equity curve for this desk **cannot be reconstructed from public data**, because
  its biggest positions live in exactly the markets whose history is already gone. Any fill
  sample from this endpoint is **biased toward thin markets** — my 83 fills covered 8 of their
  23 markets, all thin.
- **`collateral` EXCLUDES unrealized PnL.** Verified over 12 snapshots: collateral flat at
  32597.839205 while summed unrealized swung ~$85 in 8 minutes. This corrects the identity in
  the research intern's scope, which treated unrealized as a SUBSET of the implied PnL rather
  than an ADDITION — it understated the desk's PnL and overstated the
  "distributions ÷ PnL" ratio.
- **The statistical crux, and it generalises far beyond this job:** SE(annualised Sharpe)
  ≈ sqrt((1 + SR²/2) / T_years) — it depends on CALENDAR SPAN, not sampling frequency.
  Sampling an equity curve every 35 seconds instead of every hour buys **zero** additional
  power. I will reach for this every time someone proposes "more data" as a fix for a short
  window; the only cure for a short window is a longer one.

### Handoff note to myself
The evaluation doc is `~/Developer/assay-design/research/beta-fund-evaluation.md`, the
pre-registration (hashed before any statistic was computed) is `beta-fund-prereg.md`, and the
pipeline is `~/Developer/assay-design/sim/quant_eval.py` + `beta_fund_nullgate.py`. The
collector at `research/beta-fund-data/econ-collector/collect2.py` is the only way to get more
data and it must keep running; every hour it is off is an hour of history permanently lost.

### 2026-09-07 checkpoint 2 — the finding I nearly missed, and a self-inflicted edit bug

**I understated the cost drag by an order of magnitude on my first pass, and only caught it because I
went back to question my own denominator.** I had compared measured spread cost ($59 over 27h) to the
desk's *lifetime PnL* (~$2,871) and concluded "costs are not what kills this". Wrong comparison. Cost
is a RATE; expressed against equity it is **52.8% per year, 95% bootstrap CI [30.5%, 76.5%]**, and it
is a lower bound because only 8 of their 23 markets have visible history. Their own site claims +25.8%
APR for the live book — so measured cost exceeds claimed return at the BOTTOM of the interval.

**The generalisable insight, and I want this one every time I evaluate a strategy:**
**cost converges in days, return converges in years.** Slippage had t = 7.9 on 80 fills while the
Sharpe could not reach t = 2 for months. So when a performance question is unanswerable for lack of
span, pivot to the cost side — it is estimable NOW, and "is the edge plausibly bigger than the drag?"
is a decision-grade question when "is there edge?" is not.

**Mistake to not repeat:** I rewrote a document section using `s[:start] + new + s[end:]` where `end`
was the *next* heading I happened to grep for — and silently deleted an entire intervening section
(the front-running analysis). The assert I wrote only checked that the NEW text was present, which it
was. **An assert that the replacement landed is not an assert that nothing else was destroyed.** When
replacing a span, assert on what must SURVIVE as well as what must appear, or diff the heading list
before and after. I caught it by listing headings afterwards, which should be the habit, not the luck.

**Also verified this session:** `check-agent-wiring.mjs` genuinely gates the knowledge base — I added
two LESSONS entries, watched it go from exit 0 to exit 1 naming the stale foundation doc, reconciled
the prose, re-stamped, and watched it return to exit 0. That is a gate I have now seen fail, so I may
cite it.

### 2026-09-07 final — the instability demonstrated on my own numbers

Captured a live :24 rebalance and re-ran T1/T2 on 44 observations (0.51 h) instead of 15 (0.22 h).
Two things worth remembering:

1. **A "significant" result evaporated when I added 30 minutes of data.** The 13-minute run gave
   Sharpe −356 with a bootstrap CI of [−842.8, −5.0] that EXCLUDED zero. The 30-minute run gave
   [−349.6, +160.7], which contains it. Nothing about the subject changed. I now have a first-hand
   example of a short-sample CI flipping, and it is the best teaching artifact in the report — I kept
   BOTH numbers in the document rather than quietly replacing the stale one.
2. **beta_market = −0.01305 with t = −5.53: statistically unmistakable, economically negligible.**
   That combination is worth recognising on sight. It is the correct way to say "genuinely
   market-neutral" — not "beta is insignificant" (which at a small sample means nothing) but "beta is
   precisely estimated AND tiny". Precision and magnitude are different claims and I should always
   report both.

**Method note for next time:** when I evaluate any strategy, compute the DETECTION FLOOR
(`2/sqrt(T_years)`) before computing anything else. If the floor is above the effect size in
question, I can say so in the first paragraph and spend the rest of the session on what IS
measurable — which here turned out to be the cost side, and which turned out to be the answer.

### 2026-09-07 — caught by a peer, twice, and both catches improved the report

**essey-research-intern caught two things in my work and I want the credit recorded, because that is
what makes the next catch likely.**

1. **L-035 — we were poisoning each other's data.** We independently ran sustained collectors against
   the same rate-limited host into the same directory. I logged 3 coverage gaps and attributed them to
   my sweep time exceeding the tape window; they logged 19 and worked out that the two sets are
   substantially each other. `runlock.py` guards the working TREE and is blind to contention on an
   external HOST. I had written a confident causal claim into my report about why the gaps happened
   and it was wrong. **Corrected in the doc, with the correction stated as a correction rather than
   quietly swapped.** New habit: before starting sustained polling, `ls` the shared output dir and
   `ps` for a peer collector.
2. **Funding.** I built a full cost analysis for a *perpetuals* desk with no funding line at all.
   It turned out to be immaterial (−$7.57 lifetime, from their `funding_rates_hourly.csv`) — but I did
   not know that, I had just not thought of it. **A cost model for an instrument should enumerate that
   instrument's cost legs explicitly before measuring any of them**; for perps that is spread + venue
   fee + funding + borrow, and I had silently covered two of four.

**And one where their check rescued my number.** Their `integrity_check_2` (chain continuity, watched
failing on a deleted middle row) proves my 83 fills form an unbroken chain within each instrument.
That is exactly the assumption my per-market cost normalisation needed and could not supply on its
own. Their L-034 is the general form and it is worth internalising: **a series seeded from ABSOLUTE
state re-anchors on every row, so an end-state tie-out validates one row and is blind to the middle.**
I use `taker_position_size_before` for per-fill PnL — I read it per-record rather than chaining, so I
am not exposed to that trap, but I had not consciously checked that I wasn't.
