# G-LEND gate — round 5 — Solidity / contract security lens

**Date:** 2026-09-04
**Frozen SHA:** `2804b2e9a40e7e59d8c459654db3afd5e1621a46` · `git status --porcelain` **empty** at the
start of the round and again at the end. The only tree change this round makes is this file.
**Substrate:** Robinhood Chain **mainnet**. RPC `https://rpc.mainnet.chain.robinhood.com`
(`eth_chainId` → `0x1237` = **4663**), fork at latest, block **54284628** at the first fork and
**54285885 → 54286090** across the RPC probes. The RPC is not an archive node — state older than
roughly 5,000 blocks answers `metadata is not found` — so every run is at latest and a reproducer
will get a later block.
**PoC harness:** a byte-identical copy of `rh-chain/src` (`diff -r` clean) in a scratch Foundry root,
plus `rh-chain/test/GLendR4.t.sol` verbatim. Sources are in the appendix; the scratch root is
ephemeral and the appendix is the durable copy.

## VERDICT: NOT CLEAN — 0 CRITICAL, 0 HIGH, 2 MEDIUM, 3 LOW, 6 INFO.

**The delay line itself holds.** I attacked it directly — phase control, starvation, gas starvation,
the seed, the boundaries at 1/4/5 observations — and found no way to place an observation younger
than `PRICE_CONFIRM_DELAY` into the read slot, no way to stop the ring while the keeper runs, and no
way to open a gate by making `syncMultiplier` silently record nothing. The round-4 mutation gate runs
**24/24 killed** on this tree. The round-4 PoCs are **12/12 green and green for the right reason** —
every one of them asserts a specific selector (`PriceNotCorroborated`, `PositionHealthy`,
`LiquidationNotAllowed`, `NotAdmin`), not a bare revert, and two of them assert the *other* gates are
open first so the refusal cannot be the liveness bound in disguise. That is the discipline rounds 3
and 4 were missing.

**What the fix introduced is a clock it cannot wind.** The delay line ages only when a price is
readable, and the AAPL feed is unreadable for ~40h of every weekend by construction. So the six-hour
clock does not run through the outage — it **restarts when the feed comes back**. Measured on the
fork: **21,900 seconds** from the feed returning to the first liquidation of a position 60% underwater.
That is a recurring, calendar-predictable, operator-unoverridable liquidation blackout at the one
moment the design was most worried about, and it contradicts what `docs/MAINNET-CONFIG.md:88-90`
tells the founder.

**The MED-2 trade is better than the documentation says it is,** and one of the three sentences
describing it is simply false. Both are settled with PoCs below, because the founder is being asked
to rule on it.

---

# MED-1 — the delay line cannot age while the feed is unreadable, so every weekend adds a ~6h liquidation blackout after the feed returns

**CONFIRMED.** Measured on a real mainnet-4663 fork against the deployed AAPL token, feed, USDG and
risk parameters.

## The mechanism

`_syncPrice` returns **before** `_confirmable` when the price cannot be read:

```
rh-chain/src/EsseyMarkets.sol:494-506
    function _syncPrice(address token, uint256 prevMult, uint256 curMult) internal returns (bool) {
        uint256 price = _readablePrice(token);
        if (price == 0) return false;   // <-- nothing is pushed onto the ring
        ...
        _confirmable(token, price, curMult);
```

`_readablePrice` (`:581-587`) returns 0 whenever `priceOf` reverts, and `priceOf` reverts
`PriceStale` past `maxStaleness` (`rh-chain/src/StaleFeedGuard.sol:136`). The deployed AAPL market is
`heartbeat = 86_400`, `maxStaleness = 90_000` (`rh-chain/script/DeployMarkets.s.sol` `_marketList`;
mirrored in `rh-chain/test/GLendR4.t.sol:102`), so Friday's last print ages out ~25h after the close
and the feed stays unreadable until Monday's open — the same ~55h window `GLendR4PairSplit`'s doc
block already names.

During that window the ring is frozen. The read slot ages past `MAX_CONFIRM_AGE` and
`corroboratedValue` (`:304-315`) refuses, which is correct while there is no price. But when the feed
returns, the ring holds five weekend-old observations, and the read slot only comes back into the
`[6h, 9h]` window after **four fresh pushes at `CONFIRM_STEP` apart** — `4 × 90m = 6h`.

## Measurement

`test_howLongIsCorroborationDeadAfterTheFeedReturns` (appendix): open a position, freeze the print,
hold 55h with the keeper beating and calling `syncMultiplier` on every 300s tick exactly as
`keeper/liveness-keeper.mjs:113` does, then republish at 40% of the pre-weekend price.

```
seconds from feed-return to corroboration available: 21900
seconds from feed-return to liquidatable            : 21900
PRICE_CONFIRM_DELAY                                 : 21600
4 x CONFIRM_STEP                                    : 21600
```

Both numbers are identical, which is the proof that the corroboration gate is what binds and not
liveness, session, depth or the breaker. A position **60% underwater** — far past liquidator
indifference — cannot be liquidated for 6h05m.

`writeOff` is no escape: `_writeOffFloor` requires `isInsolventCorroborated`
(`rh-chain/src/EsseyPool.sol:799`), the same gate. `pauseLiquidation` only closes further. There is
no operator override.

## Why it matters, and why it is MEDIUM and not HIGH

It fails **closed**: no wrongful seizure, no value leak, no path to free profit. It manufactures
bad-debt exposure, and it does so on a schedule an adversary can read off a calendar. Monday's US
session is 13:30–20:00 UTC; if the first fresh print lands at the open, corroboration returns at
~19:35 UTC, half an hour before the close. If the first print lands at 14:30, it returns **after**
Monday's close.

I re-derived the buffer at the horizon this actually implies. `keeper/measure-feed-volatility.mjs`
reproduces the shipped table exactly (AAPL 6.80/8.47/8.97/10.23% at 1/6/12/24h; NVDA
7.06/7.88/9.22/12.00%), and extended:

| horizon | AAPL worst | NVDA worst | headroom in the 21.25% buffer |
|---|---|---|---|
| 6h  | 8.47%  | 7.88%  | 2.51× / 2.70× |
| 24h | 10.23% | 12.00% | 2.08× / 1.77× |
| 72h | 12.61% | 12.62% | **1.68× / 1.68×** |

The genuinely unliquidatable window is no longer ~65h (the weekend) but **~71h**, and the derivation
in `docs/MAINNET-CONFIG.md:91-99` is stated against 6h. Headroom drops from 2.5× to 1.68× on a
74-day sample the document itself says "cannot BOUND a 21.25% tail, only miss it." Solvency is not
broken on the measured distribution; the margin is materially thinner than the number the founder
was given.

## The shipped claim it contradicts

```
docs/MAINNET-CONFIG.md:88-90
  ... require the position to be underwater / insolvent at an observation at least
  `PRICE_CONFIRM_DELAY` old. A position already past the bar is seized with no
  delay, and a COMPLETED corporate action costs nothing — only a position that the latest,
  uncorroborated move has just flipped waits.
```

"A position already past the bar is seized with no delay" is false every Monday, and false after
every market holiday. `rh-chain/RUNBOOK.md:68-70` discloses the 6h warm-up for a **fresh deployment**
only; nothing anywhere discloses the recurring one.

## Fix

I am not prescribing a mechanism — round 4's prescription was refuted with measurements, correctly.
The **property** a fix must have is: *the corroboration clock must run on wall time, not on
observation availability, so that an outage does not reset the delay a position has already served.*

Two shapes that satisfy it, for the engineer to weigh and measure:
- keep the line warm across an unreadable feed by pushing the last readable **pair** with a fresh
  `takenAt`, which preserves the security property (a Monday gap is still uncorroborated for 6h,
  because the corroborated price is still Friday's healthy one) while removing the restart; or
- exclude unreadable time from the age test, so the ring's `[6h, 9h]` window is measured in
  *readable* seconds.

The first is the smaller change and keeps `MAX_CONFIRM_AGE`'s fail-closed intact. Whichever is
chosen, **it needs a test that fails against the current tree**, and
`test_howLongIsCorroborationDeadAfterTheFeedReturns` is that test with `assertLe(firstUsable, ...)`
added. If the answer is to accept it instead, then `docs/MAINNET-CONFIG.md:88-90` must be corrected
and the risk gap re-derived at 72h, where the headroom is 1.68×.

---

# MED-2 — the keeper and the supervisor built to watch it derive the market list from the same unauthenticated query, so an incomplete scan is invisible to both

**CONFIRMED.** This is R4 HIGH-2's exact failure mode — a market nobody observes — and the control
shipped to catch it cannot see it.

## The two call sites

```
rh-chain/keeper/liveness-keeper.mjs:99      pub.getLogs({ address: MARKETS, event: marketCommitted, fromBlock: FROM_BLOCK, toBlock: "latest" })
rh-chain/keeper/liveness-keeper.mjs:105     const r = reconcileMarkets({ discovered, configured: envTokens });
rh-chain/keeper/check-liveness-keeper.mjs:53-55
                                            const logs = await pub.getLogs({ ... same query ... });
                                            const { tokens } = reconcileMarkets({ discovered: ..., configured: [] });
```

The supervisor passes `configured: []`. `reconcileMarkets` still computes `missing` and `unknown`
(`rh-chain/keeper/market-list.mjs:23-30`), but the checker destructures only `tokens` and never reads
them. Its only market-count failure branch is `tokens.length === 0`
(`check-liveness-keeper.mjs:60`). And `MARKET_TOKENS` is **optional** in the keeper
(`liveness-keeper.mjs:79`, `const envTokens = (process.env.MARKET_TOKENS || "")…`), so with it unset
the keeper's own `missing` alarm at `:108` is gated off too (`if (envTokens.length > 0 && …)`).

## Demonstration

```
$ cd rh-chain/keeper && node -e '…reconcileMarkets({ discovered: [AAPL], configured: [] })…'
tokens the supervisor will check : 1 [ '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9' ]
missing[] (never consulted there): [ '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9' ]
unknown[] (never consulted there): []
supervisor failure branches: tokens.length===0 ? false
=> it prints LIVENESS KEEPER: OK and exits 0, for 1 of 2 committed markets.
```

The registry committed AAPL and NVDA. The scan returned AAPL. The keeper observes AAPL only; NVDA's
delay line ages past `MAX_CONFIRM_AGE` and its baseline past `MAX_BASELINE_AGE`; NVDA becomes
unliquidatable and its breaker blind. `check-liveness-keeper.mjs` prints
`--- LIVENESS KEEPER: OK --- beat Ns ago, 1 market(s) observed and corroborated` and exits 0.

## The RPC, characterised on the real endpoint — the engineer's flagged unverified item, settled

The `getLogs` call **works**, and its limits are:

```
$ eth_getLogs {fromBlock:"0x0", toBlock:"latest", address:<AAPL token>}
{"error":{"code":-32000,"message":"logs matched by query exceeds limit of 10000"}}

$ eth_getLogs {fromBlock:"0x0", toBlock:"latest", address:<contract>, topics:[MarketCommitted]}
{"result":[]}

$ (under load)
{"error":{"code":429,"message":"Too Many Requests"}}
```

- **No block-range cap.** `fromBlock: 0 → latest` is accepted across 54M blocks. The keeper's
  `MARKETS_FROM_BLOCK` default of 0 is safe.
- **A 10,000-log result cap**, which **errors** rather than truncating. `MarketCommitted` on one
  registry will never approach it, and an error is handled fail-safe (`liveness-keeper.mjs:100-110`:
  ALERT, keep the previous list, or refuse to start when `required`).
- **HTTP 429 under load**, which viem raises as an error — also handled.

So the handled failure modes are handled. The unhandled one is a **short but successful** answer: a
lagging load-balanced replica whose `latest` predates a fresh `commitMarket`, a reindexing node, or
any provider that answers partially. Nothing in either process cross-checks the count against an
independent source.

## Severity

MEDIUM, and stated plainly: this is **off-chain and fails closed**. It cannot move funds or cause a
seizure — the on-chain consequence is that the unobserved market stops being liquidatable, which
manufactures bad debt. It is MEDIUM rather than LOW because it defeats the specific control that a
HIGH was closed with, and because the operator has no signal at all.

## Fix

Make the supervisor's market list independent of the keeper's, or make disagreement loud:
- require `MARKET_TOKENS` in `check-liveness-keeper.mjs` and pass it as `configured`, failing when
  `missing.length > 0` — this costs one env var and turns the existing, already-tested
  `reconcileMarkets` output into a real check; and/or
- persist the discovered set and fail when the count **drops** without a human acknowledgement, which
  catches the partial-answer case even with no env list.

`rh-chain/keeper/test/market-list.test.mjs` (5/5 green) tests `reconcileMarkets` against a *complete*
`discovered` list in every case. There is no test for an incomplete one, because the function cannot
detect that — which is the point.

---

# LOW-1 — `test_theValuationAndObservationReadsShareOneBudget` passes with the budget cut to a value that would brick the protocol

**CONFIRMED.** This is the "a test's NAME is a claim" shape that rounds 3 and 4 both landed on, found
by mutating the constant the test is named after.

```
$ sed -i 's/MULTIPLIER_READ_GAS = 200_000/MULTIPLIER_READ_GAS = 5_000/' src/EsseyMarkets.sol
$ forge test --match-test test_theValuationAndObservationReadsShareOneBudget -vv
[PASS] test_theValuationAndObservationReadsShareOneBudget() (gas: 104946)
Logs:
  AAPL uiMultiplier() gas: 15736
```

5,000 is **below the 15,736 gas the deployed AAPL token actually needs**, so `_liveMultiplier`
(`rh-chain/src/EsseyMarkets.sol:616-620`) would return 0 on every call, `collateralValue` would revert
`BadMultiplierSource` on every call, and every borrow and every liquidation on every market would
stop. The test named for that budget stays green.

It stays green because its assertions test the *revert-handling* branch — `vm.mockCallRevert` then
`vm.expectRevert(BadMultiplierSource)` (`rh-chain/test/GLendR4.t.sol:474-479`) — which behaves
identically whether the read failed from a revert or from starvation. The `console.log` of the real
gas cost is not an assertion.

**Not a coverage hole in aggregate**: the R4 mutation driver's M16 (the *other* direction, an
uncapped read) is killed, and the low-budget mutant is caught elsewhere in the suite because the
borrow fixtures stop working. It is a false green in the one test that claims the property.

**Fix.** Assert the deployed read's cost against the constant, in the direction that matters:
`assertLt(used, MULTIPLIER_READ_GAS)` with headroom, which requires exposing the constant (it is
`internal` at `:603`). Add `M25 MULTIPLIER_READ_GAS 200_000 -> 5_000` to
`rh-chain/test/mutants/glend-r4.py` so it stays killed.

---

# LOW-2 — the corroboration gate is a two-point sample, not a duration test, and a permissionless caller owns the earlier point

**CONFIRMED with a PoC that seizes a position.**

`syncMultiplier` is permissionless (`rh-chain/src/EsseyMarkets.sol:626`), and `_confirmable`
(`:518-526`) admits one push per `CONFIRM_STEP` — so whoever calls first after the limit opens chooses
which instant's price enters the line. Four pushes later that instant is the read slot, and it is the
**only** thing `corroboratedValue` consults.

The effective predicate is therefore: *underwater at the live price now, **and** underwater at one
caller-chosen print from a particular 90-minute window that ended 6–7.5h ago.* Not "underwater for
six hours."

`test_twoFlashDipsSixHoursApartSatisfyTheStoodForSixHoursGate` (appendix): a seasoned position sits
healthy; a single 300s print 12% below (well under `MAX_PRICE_DEVIATION_BPS`, so nothing arms) is
captured into the ring; the price recovers fully and stays healthy for six hours with the keeper
observing every 300s throughout; then one more 12% print, and the position is liquidated.

```
age of the corroborated observation (s): 21600
SEIZED on two one-block dips six hours apart. debt paid: 1472789422
  collateral seized (raw): 8743875474657647540
```

$1,472.79 of debt repaid, 8.7439 AAPL seized. At the recovered price that collateral is worth
`owed × 1.05 / 0.88 ≈ 1.19 × owed` — about **1,930 bps** of the debt, taken from a borrower who was
healthy before the print and healthy after it.

**Why LOW and not higher.** At the instant of seizure the position **is** underwater at a real feed
price, which is the protocol's own liquidation predicate; this is ordinary wick liquidation, not the
artifact-driven free profit rounds 3 and 4 found. The attacker cannot manufacture feed prints — they
can only sample real ones. And the threat the gate was built for is genuinely covered: a half-landed
corporate action is a **persistent step**, so a pre-leg observation reads full value and refuses,
which `GLendR4Corroboration` pins at four offsets.

**What is wrong is the framing, and the founder is ruling on the framing.**
`rh-chain/src/EsseyMarkets.sol:375-380` says "How long a price move must stand before it may justify a
SEIZURE" and "a real move stands"; `:379` says "Separation by TIME, not magnitude." Those describe a
duration test. `docs/MAINNET-CONFIG.md:88` states it correctly ("at an observation at least
`PRICE_CONFIRM_DELAY` old"). Make the contract comment match the config doc, not the other way round —
and if a duration property is actually wanted, it needs all five slots consulted (e.g. underwater at
the *max* of the ring), not the oldest alone.

---

# LOW-3 — `LivenessOracle`'s stated containment for the new rotation power does not hold

**CONFIRMED with a PoC.**

```
rh-chain/src/LivenessOracle.sol:76-80
    /// WHAT THIS COSTS ... it is bounded by the notice, by the event, and by the guardian's
    /// ability to rotate the keeper straight back the moment a hostile rotation commits.
```

`commitRotation` replaces **both** roles in one transaction:

```
rh-chain/src/LivenessOracle.sol:212-213
        keeper = pendingKeeper;
        guardian = pendingGuardian;
```

So there is no incumbent guardian left to rotate anything back. `test_theIncumbentGuardianCannotRotateTheKeeperBack`:

```
[PASS] test_theIncumbentGuardianCannotRotateTheKeeperBack()
  REFUTED: commitRotation replaces the guardian in the same transaction,
  so there is no incumbent guardian left to 'rotate the keeper straight back'.
```

The old guardian's `setKeeper` reverts `NotGuardian`. Nor can it act during the notice period —
`cancelRotation` is `rotationAdmin`-only (`:221-222`), which is deliberate and correct (M21 kills the
mutant that loosens it).

**The real containment, which is genuine and should be what the comment says:**
`EsseyMarkets.guardian` is a **different, immutable address** that `_checkRoles` forces to differ from
`LIVENESS_GUARDIAN` (`rh-chain/script/DeployMarkets.s.sol:193-196`) and from `LIVENESS_KEEPER`
(`:176-179`). A hostile liveness rotation does not touch it, so `pauseLiquidation` and
`disableMarket` (`rh-chain/src/EsseyMarkets.sol:809, :786`, both guardian-only since R4 MED-3) remain
available before, during and after the commit. That, plus the 2-day notice and the
`RotationProposed` event, is the bound.

---

# INFO-1 — the MED-2 cost is **overstated** in three places, and the founder should rule on the real trade

The stated price of the recovery path, in `rh-chain/src/LivenessOracle.sol:77-78`,
`rh-chain/script/DeployMarkets.s.sol:191-193` and `docs/MAINNET-CONFIG.md:74-75`, is: *"a keeper that
beats through a chain outage keeps liquidation open during one."*

**It cannot.** `heartbeat()` derives the gap from **stored state**, not from the caller:

```
rh-chain/src/LivenessOracle.sol:147,153
        uint256 prev = lastHeartbeat;
        uint256 gap = prev == 0 ? type(uint256).max : block.timestamp - prev;
```

During a genuine chain halt nobody transacts — the hostile keeper is as frozen as the borrowers and
the liquidation bots. On restart its own gap is the outage length, so it must serve the full
`resumeGrace` like anyone else, and `:159` never shortens a grace already earned.
`test_aHostileKeeperCannotSkipThePostOutageGrace`:

```
grace still owed (s): 3600
beats the hostile keeper had to serve before liquidation reopened: 12
```

A hostile keeper's only levers are (i) keep `lastHeartbeat` fresh while the chain is healthy, and
(ii) go silent — which is the halt the guardian already had.

**Assessment, plainly, since the founder has not ruled.** The change is **better** than what it
replaces, and by a wide margin:

| | before (R4 and earlier) | after |
|---|---|---|
| trigger | one `setKeeper` transaction | 2-day timelock + public `RotationProposed` event |
| holder | `LIVENESS_GUARDIAN` alone | `rotationAdmin` = the market admin, forbidden from being either liveness role (`LivenessOracle.sol:122`, `DeployMarkets.s.sol:124`) |
| effect | liquidation **and** borrowing off, every market | a keeper of the rotator's choosing |
| worst act | permanent | keep liquidation open while the chain is demonstrably healthy |
| exit | **none** — redeploy the registry and every pool, migrate every position | the incumbent `EsseyMarkets.guardian` still holds `pauseLiquidation` / `disableMarket` throughout |
| removes the post-outage grace? | n/a | **no** — contract-derived, PoC above |

The new power does not reach the thing the liveness gate exists to protect (the restart race), because
the contract's own arithmetic enforces it regardless of who holds the key. The removed liability was
unrecoverable. **Recommendation: accept it**, and correct the three sentences so the ruling is made
on the real trade rather than an overstated one. Correcting them costs nothing and removes an
argument for keeping the unrecoverable key.

Residual worth naming: `rotationAdmin` is the deploy broadcaster and is also `EsseyMarkets.admin`,
which is `immutable` with no setter. `docs/MAINNET-CONFIG.md:115-120` already carries the consequence
R4 raised (the multisig **must** be the broadcaster). That still holds and is still the load-bearing
deploy-time condition for this whole scheme.

---

# INFO-2 — the two UNVERIFIED items, settled as far as chain state allows

**(a) `uiMultiplier` does NOT drift.** The engineer's hypothesis — that a rolling multiplier would
block borrowing on a rolling basis — is **REFUTED**.

```
$ cast call <AAPL> "uiMultiplier()(uint256)"   → 1000566080061092436   (three consecutive reads)
$ cast call <NVDA> "uiMultiplier()(uint256)"   → 1000000000000000000
```

The RPC has no archive history, so I ran the token's **real deployed bytecode** in a forked EVM
against a moved clock, which answers the question directly:

```
[PASS] test_isTheMultiplierTimeDerived()
  AAPL uiMultiplier at fork      : 1000566080061092436
  AAPL +1h                       : 1000566080061092436
  AAPL +30d                      : 1000566080061092436
  AAPL +1y                       : 1000566080061092436
[PASS] test_isTheMultiplierBlockDerived()
  AAPL m1 (+10M blocks, +1y):      1000566080061092436
```

Invariant under both clocks. It is a stored value the issuer writes, not an accrual — the 5.66 bps
offset from par is consistent with one past adjustment, not with continuous accrual. There is
therefore **no rolling availability defect**, and the breaker plus the delay line remain the right
instruments for the case where the issuer does write it.

**(b) Whether Robinhood expresses dividends through `uiMultiplier` is STILL UNVERIFIED**, after five
rounds. It is not answerable from the chain state available: the RPC retains ~5,000 blocks of state
(~7 minutes at this chain's block rate) and there is no archive endpoint, so no historical
`uiMultiplier` read is possible. **What would settle it**, in order of cost: (1) watch
`uiMultiplier()` across a known AAPL ex-dividend date on 4663 — the next one is a scheduled,
publicly-known date; (2) get an archive endpoint and read it either side of one; (3) index
transactions from `MULTIPLIER_UPDATER_ROLE` `0x9290…8143` (`docs/MAINNET-CONFIG.md:19`) and correlate
with ex-dates. Until then nothing in the design may assume either answer — and nothing currently
does, which is the right posture.

**(c) A bonus verification, since it underpins `_desyncGuard` branch (a).** `newUIMultiplier()`
returns **32 bytes on both deployed tokens**, so `_scheduledEffectiveAt`'s `ret.length != 64` check
(`rh-chain/src/EsseyMarkets.sol:607`) returns 0 forever and branch (a) is **inert on every listed
market**, exactly as `:447-450` says. The comment is accurate and the code does not depend on it.

---

# INFO-3 — the volatility derivation reproduces, but the σ figures do not

`keeper/measure-feed-volatility.mjs` is runnable and its **worst-move table reproduces exactly** —
AAPL 6.80 / 8.47 / 8.97 / 10.23% and NVDA 7.06 / 7.88 / 9.22 / 12.00% at 1 / 6 / 12 / 24h, over
AAPL 555 rounds / 74.28d and NVDA 981 rounds / 74.42d. The arithmetic in
`docs/MAINNET-CONFIG.md:91-99` and `rh-chain/src/EsseyMarkets.sol:381-388` checks out.

The per-round σ does not. The report and commit cite **AAPL 0.5585% vs NVDA 0.5751%**. Log-return
sample standard deviation over the same walk gives **AAPL 0.5712% (n=554), NVDA 0.5602% (n=980)** —
the *ordering reverses*. The method behind the cited pair is not stated, so this may be a different
(equally defensible) estimator rather than an error. **Nothing depends on it**: the conclusion "NVDA
is not materially more volatile than AAPL" holds under both, and the binding numbers are the
worst-move table, which reproduces. Recorded so the number in the register is not treated as
reproduced when it has not been.

Two script notes, since its own header says to run it **before listing a market**:
- `normalise()` (`:60-62`) is a magnitude heuristic — `r.p > 10_000 ? r.p / 1e8 : r.p`. Correct for
  AAPL and NVDA; it would silently mis-scale by 1e8 any name printing above $10,000.
- the `latest` round ids are hardcoded (`:88-91`, 555 and 981) rather than read from `latestRound()`,
  so a re-run months from now measures a stale window without saying so.

---

# INFO-4 — the two `ERC721InvalidReceiver` failures are genuinely fixed, not suppressed

Full suite at the frozen SHA: **1,791 passed, 1 failed, 0 skipped, 1,792 total, 87 suites.** The one
failure is
`DonSolvencyStress::test_sweep_tunables_holdSolvency` with
`database error: … Max retries exceeded HTTP error 429 … Too Many Requests` — an RPC rate limit
during a fork read, not a logic failure. Both `ERC721InvalidReceiver` failures are gone.

The fix is real. `cast code 0xaE0bDc4eEAC5E950B67C6819B118761CaAF61946` **still returns**
`0xef01008a5b10eb2faf57665f63709ec4b3943a3b005df6` — the stranger's EIP-7702 delegation is still
there. What changed is that both fixtures normalise the account to the plain EOA they always meant:

```
rh-chain/test/DonSolvencyStress.t.sol:103-112, rh-chain/test/DonMainnetFork.t.sol:114-123
    function _asEoa(address a) internal returns (address) {
        if (a.code.length != 0) vm.etch(a, "");
        return a;
    }
```

That is a test-harness fix for test-harness pollution, not a suppression of protocol behaviour — the
delegation is a third party's on-chain artifact, not code under audit.

**One caveat.** `rh-chain/test/DonMainnetFork.t.sol:245` weakened
`assertEq(IStockToken(AAPL).uiMultiplier(), 1e18)` to `assertGe(aaplMult, 1e18)`. The change is
justified (the value genuinely is not 1e18 — INFO-2) but `assertGe` is unbounded above, and a
multiplier far above par over-values collateral in the direction that permits over-borrowing.
Recommend an upper bound: `assertLt(aaplMult, 2e18)` or similar, so the assertion pins a band rather
than a floor.

---

# INFO-5 — `CollateralReconciler.pendingMultiplier` is dead, and duplicates a read at the budget R4 concluded was too small

```
rh-chain/src/CollateralReconciler.sol:130-133
    function pendingMultiplier(address token) external view returns (uint256, uint256) {
        (bool ok, bytes memory ret) = token.staticcall{gas: 50_000}(abi.encodeWithSignature("newUIMultiplier()"));
```

`grep -rn pendingMultiplier` over `rh-chain/src`, `rh-chain/script` and `app/web/src` finds the
definition and one doc-block mention in `rh-chain/src/interfaces/IScaledUI.sol:14`. **Nothing calls
it** — not the UI, not a script, not a keeper.

It is harmless today (an unreachable `external view` on no gate path), but it is a trap of exactly the
shape R4 LOW-1 was: the fix raised `MULTIPLIER_READ_GAS` to 200,000 in `EsseyMarkets`
(`:600-603`, on the reasoning that 50,000 was only 3.18× headroom on a beacon-upgradeable contract
this protocol does not own) and left the sibling read here at **50,000**. If anything ever wires this
into a gate, it inherits the budget the round-4 finding rejected. Per the house delete-dead-code rule:
delete it, or raise it to the same constant and say why it exists.

---

# INFO-6 — public-repo hygiene: no secrets; round 4's leakage items are unchanged

`gh repo view --json visibility` → **PUBLIC**.

Swept all 37 files touched by `cb3e6aa..2804b2e`: **no private keys, no mnemonics, no API keys, no
private absolute paths.** The only 64-hex match is the EIP-1967 beacon slot
`0xa3f0ad74…35133d50` at `app/web/src/lending.ts:175` and `docs/MAINNET-ACTIVATION.md:1172` — a public
constant, benign. `keeper/xyz.essey.liveness-keeper.plist` correctly uses a `__REPO__` placeholder
rather than a home path, and holds no keys.

**R4 INFO-1's four items are still present** at the frozen SHA and are re-stated, not re-found:
- `[[wikilink]]`s into the private memory corpus at `docs/MAINNET-ACTIVATION.md:6, 44, 152, 821, 973`
  — each name discloses its memo's subject, and `:821` quotes its text.
- a competitor named in shipped contract source at `rh-chain/script/DeployMarkets.s.sol:22-25` and
  inside an assertion string at `rh-chain/test/RateModes.t.sol:164, 170` (assertion strings surface in
  CI output). The founder's no-competitor-names rule is scoped only to the site
  (`app/web/gen-docs.mjs`).

These are pre-push blockers under lens 6 whenever the next push happens; they are unchanged from
round 4's report and carry no new information.

---

# What I ran

| | |
|---|---|
| `git rev-parse HEAD` | `2804b2e9a40e7e59d8c459654db3afd5e1621a46` |
| `git status --porcelain` | empty, at start and at end |
| `eth_chainId` | `0x1237` = 4663 |
| `eth_blockNumber` | 54284628 → 54286090 across the round |
| full suite (`forge test`) | **1,791 passed / 1 failed / 1,792 total, 87 suites** — the failure is an RPC 429, not logic |
| `forge test --match-contract GLendR4` | **12 passed / 0 failed**, and green for the right reason (specific selectors, positive control on the other gates) |
| `python3 test/mutants/glend-r4.py` (isolated copy) | **24/24 killed** |
| `node --test keeper/test/market-list.test.mjs` | **5 passed / 0 failed** |
| `node keeper/measure-feed-volatility.mjs` | reproduces the shipped table exactly; extended to 48/66/72/96h |
| R5 probes (appendix) | 10 tests: ring envelope, weekend blackout, fresh-market warm-up, attacker phase control, gas starvation, multiplier drift ×2, return shape, authority ×3 |

**What I did NOT cover**, stated so the next lens can: the game layer (`rh-chain/src/game/`), the
market layer beyond `EsseyPool`/`EsseyMarkets` (`Don*`, `Essey*` in `rh-chain/src/market/`), the
shielded/private stack, and the V4 hook — all outside G-LEND's scope. Within scope I read
`EsseyMarkets`, `EsseyPool`, `LivenessOracle`, `MarketHealthOracle`, `StaleFeedGuard`,
`CollateralReconciler`, all four keeper scripts, `DeployMarkets.s.sol`'s role rules, and `GLendR4.t.sol`.

---

# Appendix — PoC sources

These ran against a byte-identical copy of `rh-chain/src` (`diff -r` clean) in a scratch Foundry root
with `rh-chain/test/GLendR4.t.sol` copied verbatim, forking `rh_mainnet` at latest. The scratch root
is ephemeral; this appendix is the durable copy. `R5Base` is the fixture from `R5Ring.t.sol`;
`R5Sampling` imports it.

## `R5Ring.t.sol` — the ring probes

`R5Base` mirrors `GLendR4Base` exactly (deployed USDG / AAPL / AAPL feed / whales, deployed risk
params 5000 / 7500 / 500, `heartbeat 86_400` / `maxStaleness 90_000`, `GAP 900` / `GRACE 1 hours`,
keeper beating and observing on a 300s tick) with two additions:

```solidity
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    /// FREEZE the print: the feed stops publishing (weekend). updatedAt stays put and ages out.
    function _freeze(int256 p, uint256 at) internal {
        vm.mockCall(AAPL_FEED, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), p, at, at, uint80(1)));
    }
```

### MED-1's measurement

```solidity
    function test_howLongIsCorroborationDeadAfterTheFeedReturns() public {
        uint256 id = _open();
        _freeze(realPrice, block.timestamp);

        // Age the print past maxStaleness and hold there — the keeper beats and calls syncMultiplier
        // on every 300s tick throughout, exactly as the deployed one does.
        uint256 end = block.timestamp + 55 hours;
        while (block.timestamp < end) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
            markets.syncMultiplier(AAPL);
        }
        _postDepth();
        assertFalse(markets.canLiquidate(AAPL), "an unreadable price already refuses");
        (, bool okDuring) = markets.corroboratedValue(AAPL, _coll());
        assertFalse(okDuring, "and the ring has aged out");

        // MONDAY. The feed publishes again, at a price that gapped down hard over the weekend.
        int256 monday = (realPrice * 40) / 100; // unambiguously underwater, not on the threshold
        uint256 open_ = block.timestamp;
        uint256 firstUsable;
        uint256 firstLiquidatable;
        for (uint256 i = 0; i < 200 && (firstUsable == 0 || firstLiquidatable == 0); i++) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
            _reprice(monday);
            markets.syncMultiplier(AAPL);
            _postDepth();
            (, bool ok) = markets.corroboratedValue(AAPL, _coll());
            if (ok && firstUsable == 0) firstUsable = block.timestamp - open_;
            if (firstLiquidatable == 0 && markets.canLiquidate(AAPL)
                && markets.isUnderwater(AAPL, _coll(), pool.debtOf(id))
                && markets.isUnderwaterCorroborated(AAPL, _coll(), pool.debtOf(id))) {
                firstLiquidatable = block.timestamp - open_;
            }
        }
        console.log("seconds from feed-return to corroboration available:", firstUsable);
        console.log("seconds from feed-return to liquidatable            :", firstLiquidatable);
    }
```

### The properties that HOLD (green, and worth keeping)

```solidity
    /// The steady-state envelope, sampled every 300s across a full day of the DEPLOYED cadence.
    /// -> beats 288 usable 288 · min age 21600 · max age 26700 (ceiling 32400)
    function test_theSteadyStateAgeEnvelope() public {
        uint256 minAge = type(uint256).max; uint256 maxAge; uint256 usable; uint256 beats;
        for (uint256 i = 0; i < 288; i++) {
            _hold(realPrice, GAP / 3);
            beats++;
            (, bool ok) = markets.corroboratedValue(AAPL, _coll());
            if (ok) usable++;
            uint256 age = block.timestamp - markets.confirmedObservedAt(AAPL);
            if (age < minAge) minAge = age;
            if (age > maxAge) maxAge = age;
        }
        assertEq(usable, beats, "every beat usable once the line is warm");
        assertGe(minAge, markets.PRICE_CONFIRM_DELAY(), "never younger than the delay");
        assertLe(maxAge, markets.MAX_CONFIRM_AGE(), "never older than the ceiling");
    }

    /// A freshly listed market: commit does NOT seed the ring, the first observation does, and
    /// nothing is corroborated for exactly PRICE_CONFIRM_DELAY after it. -> 21600
    /// (Borrowing is open the whole time; canBorrow does not consult corroboration.)
    function test_theWarmUpWindowOnAFreshlyListedMarket() public { /* second registry, listed now */ }

    /// A permissionless caller front-running every beat to own the ring's phase never gets an
    /// observation younger than the delay. -> minimum corroborated age 21600
    function test_anAttackerOwningThePhaseNeverGetsAYoungObservation() public { /* 720 ticks */ }

    /// `_liveMultiplier` returns 0 rather than reverting under gas starvation, so `syncMultiplier`
    /// silently records nothing. Sweeping the call's gas from 40k to 260k, no gate opens: any budget
    /// that starves the observation also starves `collateralValue`, and both refuse.
    function test_gasStarvingTheObservationCannotOpenAGate() public { /* snapshot per budget */ }
```

### INFO-2's probes

```solidity
contract R5MultiplierDrift is R5Base {
    function setUp() public { vm.createSelectFork(vm.rpcUrl("rh_mainnet")); }

    function test_isTheMultiplierTimeDerived() public {
        uint256 m0 = IScaledUI(AAPL).uiMultiplier();
        vm.warp(block.timestamp + 1 hours);
        vm.warp(block.timestamp + 30 days);
        vm.warp(block.timestamp + 365 days);
        assertEq(IScaledUI(AAPL).uiMultiplier(), m0, "not a function of block.timestamp");
    }

    function test_theScheduledMultiplierReturnShape() public view {
        (bool ok, bytes memory ret) = AAPL.staticcall(abi.encodeWithSignature("newUIMultiplier()"));
        // -> ok true, ret.length 32 on BOTH tokens; _scheduledEffectiveAt requires 64.
    }
}

contract R5MultiplierRoll is R5Base {
    function test_isTheMultiplierBlockDerived() public {
        uint256 m0 = IScaledUI(AAPL).uiMultiplier();
        vm.roll(block.number + 10_000_000);
        vm.warp(block.timestamp + 365 days);
        assertEq(IScaledUI(AAPL).uiMultiplier(), m0, "neither clock moves it");
    }
}
```

## `R5Sampling.t.sol` — LOW-2

```solidity
contract R5Sampling is R5Base {
    function setUp() public { _setUpFork(); _intoSession(); }

    /// Beat on the keeper's cadence AND observe, holding `p`.
    function _tick(int256 p, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.warp(block.timestamp + GAP / 3);
            _beat(); _reprice(p);
            vm.prank(attacker);
            markets.syncMultiplier(AAPL);
        }
        _postDepth();
    }

    /// One 300s tick at `dip`, captured by the attacker, then straight back to `p`.
    function _flash(int256 dip, int256 p) internal {
        vm.warp(block.timestamp + GAP / 3);
        _beat(); _reprice(dip);
        vm.prank(attacker);
        markets.syncMultiplier(AAPL); // the attacker's observation
        _reprice(p);
        _postDepth();
    }

    function test_twoFlashDipsSixHoursApartSatisfyTheStoodForSixHoursGate() public {
        vm.startPrank(borrower);
        IERC20(AAPL).approve(address(pool), _coll());
        uint256 id = pool.borrow(_coll(), (markets.maxBorrow(AAPL, _coll()) * 90) / 100);
        vm.stopPrank();

        int256 p = realPrice;
        for (uint256 i = 0; i < 3; i++) { p = (p * 85) / 100; _reprice(p); markets.syncMultiplier(AAPL); }
        assertEq(markets.priceDesyncAt(AAPL), 0, "nothing armed");
        _tick(p, 100);
        assertFalse(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "healthy at the seasoned price");

        int256 dip = (p * 88) / 100; // -1,200bps, under MAX_PRICE_DEVIATION_BPS

        // Walk to the instant the push rate limit opens, then take the dip in ONE 300s tick.
        uint256 before_ = markets.confirmedObservedAt(AAPL);
        while (markets.confirmedObservedAt(AAPL) == before_) { _tick(p, 1); }
        _tick(p, markets.CONFIRM_STEP() / (GAP / 3) - 1);
        _flash(dip, p);
        uint256 dipAt = block.timestamp;

        // SIX HOURS of a fully recovered, healthy price, observed every 300s throughout.
        _tick(p, (6 hours) / (GAP / 3));
        for (uint256 i = 0; i < 40 && markets.confirmedObservedAt(AAPL) != dipAt; i++) _tick(p, 1);
        assertEq(markets.confirmedObservedAt(AAPL), dipAt, "the attacker's dip is the corroborated observation");
        assertGe(block.timestamp - markets.confirmedObservedAt(AAPL), markets.PRICE_CONFIRM_DELAY());

        assertFalse(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "healthy live");
        assertTrue(markets.isUnderwaterCorroborated(AAPL, _coll(), pool.debtOf(id)), "but 'corroborated' underwater");

        _reprice(dip); // the second one-block dip
        vm.prank(liquidator);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0, "the position was liquidated");
    }
}
```

## `R5Authority.t.sol` — LOW-3 and INFO-1

```solidity
contract R5Authority is Test {
    LivenessOracle liveness;
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address rotationAdmin = makeAddr("rotationAdmin");
    uint256 constant GAP = 900;
    uint256 constant GRACE = 1 hours;

    function setUp() public {
        vm.warp(1_800_000_000);
        liveness = new LivenessOracle(keeper, guardian, rotationAdmin, GAP, GRACE);
        vm.prank(keeper); liveness.heartbeat();
        _settle(keeper);
    }

    /// LOW-3. LivenessOracle.sol:79-80 claims the hostile rotation is bounded by "the guardian's
    /// ability to rotate the keeper straight back the moment a hostile rotation commits."
    function test_theIncumbentGuardianCannotRotateTheKeeperBack() public {
        vm.prank(rotationAdmin);
        liveness.proposeRotation(makeAddr("hostileKeeper"), makeAddr("hostileGuardian"));
        vm.warp(block.timestamp + liveness.ROTATION_TIMELOCK());
        liveness.commitRotation();
        assertEq(liveness.guardian(), makeAddr("hostileGuardian"), "the incumbent guardian is GONE");
        vm.prank(guardian);
        vm.expectRevert(LivenessOracle.NotGuardian.selector);
        liveness.setKeeper(makeAddr("honestKeeper"));
    }

    /// INFO-1. During a real chain halt NOBODY transacts, and heartbeat() derives the gap from
    /// STORED state — so a hostile keeper cannot skip the grace it earned by being frozen.
    function test_aHostileKeeperCannotSkipThePostOutageGrace() public {
        address hostileKeeper = makeAddr("hostileKeeper");
        vm.prank(rotationAdmin);
        liveness.proposeRotation(hostileKeeper, makeAddr("hostileGuardian"));
        vm.warp(block.timestamp + liveness.ROTATION_TIMELOCK());
        liveness.commitRotation();
        vm.prank(hostileKeeper); liveness.heartbeat();
        _settle(hostileKeeper);
        assertTrue(liveness.liquidationsAllowed(), "holds it open in normal times");

        vm.warp(block.timestamp + 4 hours); // THE CHAIN HALTS. No transaction lands.
        assertFalse(liveness.liquidationsAllowed(), "closed during the halt, with no transaction");

        vm.prank(hostileKeeper); liveness.heartbeat(); // first in the block on restart
        assertFalse(liveness.liquidationsAllowed(), "STILL closed: the grace is contract-derived");
        assertEq(liveness.secondsUntilLiquidationsAllowed(), GRACE, "the full resumeGrace, capped");

        uint256 g;
        while (!liveness.liquidationsAllowed() && g++ < 100) {
            vm.warp(block.timestamp + GAP / 3);
            vm.prank(hostileKeeper); liveness.heartbeat();
        }
        assertTrue(liveness.liquidationsAllowed(), "only after the grace has actually run"); // g == 12
    }

    /// The residual: silence is the only other lever, and an earned grace can never be shortened.
    function test_aHostileKeeperCannotShortenAnEarnedGrace() public { /* short gap inside a long one */ }
}
```
