# G-LEND gate — round 7 — Solidity / contract security lens

**Date:** 2026-09-04
**Frozen SHA:** `2309cb0e0cc2ae0d18921657d855c6bb16d82324` · `git status --porcelain` **empty** (0 lines)
at the start of the round. The only tree change this round makes is this file.
**Tree note, recorded rather than assumed:** by the end of the round `git status --porcelain` showed
two further untracked files that are **not this audit's** — `docs/RUNBOOK-EX-DATE-PAUSE.md` and
`rh-chain/keeper/measure-halt-baddebt.mjs` (mtimes 10:28 / 10:30), evidently a concurrent session
writing into the audited `keeper/` surface mid-round. Neither existed at 2309cb0 and neither is in
scope here. `git diff --stat 2309cb0 -- .` is **empty**, and every audited file's sha256 was re-taken
at the end of the round and is **identical** to the start-of-round set, so nothing under audit moved.
It is flagged because a second writer in the audited tree during a frozen-SHA round is exactly the
condition that makes a receipt untrustworthy the one time it matters.
**Substrate:** Robinhood Chain **mainnet**. RPC `https://rpc.mainnet.chain.robinhood.com`,
`eth_chainId` → `0x1237` = **4663**, `web3_clientVersion` → `nitro/v3.11.4-rc.3-7d5ac27/linux-arm64/go1.25.14`.
Fork at latest; `eth_blockNumber` → `0x33e7583` = **54,426,499** at the start of the round.
**The lending stack is NOT deployed on 4663** — VERIFIED: `rh-chain/broadcast/DeployMarkets.s.sol/`
does not exist. What the fork supplies is the real deployed collateral, feed and asset: the AAPL
Stock Token `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` returns non-empty `eth_getCode`, and
`keeper/measure-feed-volatility.mjs` walked 555 real AAPL rounds and 981 real NVDA rounds this round.
`EsseyMarkets`/`EsseyPool` are constructed inside the fork.
**PoC harness:** two scratch Foundry roots holding `git archive 2309cb0 rh-chain`, `lib/` copied (no
symlink into the working tree). Every file under `src/`, `test/`, `script/` and `keeper/` was verified
byte-identical to `git show 2309cb0:…` before and after every mutant, with the source restored from
the git object after each run. Receipt: `~/.claude/gate-receipts/audit-glend-r7`.

## VERDICT: CLEAN of CRITICAL / HIGH / MEDIUM — 0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW, 3 INFO.

**The round-6 fix is correct, complete and correctly pinned.** The chokepoint enumeration behind it
holds under an independent check; the deleted seed guard is genuinely dead and its property is
enforced and falsifiable where it now lives; the two survivors are killed; the mutation gate is
**37/37, 0 survivors**, re-run from zero rather than inherited.

**The behaviour change was quantified and it is not a problem.** The new fail-closed **never fires on
a keeper doing its job**, at any feed-outage length — measured across the full 79.74h max gap on the
deployed 300s cadence with zero refusals. It requires a keeper observation gap of roughly 7.4h, which
is an operational failure the supervisor already reports as fatal, and it does not lock a borrower out
of curing.

**The two LOWs are both about knowing, not about losing.** Neither moves value, opens a gate or is
attacker-triggerable. One is a supervisor that now under-reports; one is a mutation-coverage gap on
code that is correct. Neither is promoted, and neither is a reason to withhold the round.

---

# What the fix does, measured

## The chokepoint enumeration is complete — checked independently, not taken on the note

The claim under review is that the ring is written from exactly two places and `_syncPrice` has one
caller, so a guard in `_holdConfirmable` cannot be bypassed. Re-derived from the source:

| what | where | count |
|---|---|---|
| `_confirmRing[...] = ` assignments | `EsseyMarkets.sol:570` (in `_confirmable`), `:576` (in `_seedConfirmRing`) | 2 |
| `_seedConfirmRing` callers | `EsseyMarkets.sol:568` | 1 |
| `_confirmable` callers | `:520` (readable branch), `:551` (warm branch) | 2 |
| `_holdConfirmable` callers | `:512` | 1 |
| `_syncPrice` callers | `:686` | 1 |
| `_confirmHead[...] = ` assignments | `:571` | 1 |
| `syncMultiplier` callers in `src/` | `EsseyPool.sol:431, :502, :677, :707, :809` | 5, matching the doc block |

And the enumeration is only sound if nothing can write that storage outside Solidity's own statements:
`grep -n "assembly\|delegatecall\|sstore\|selfdestruct" src/EsseyMarkets.sol` returns **nothing**, and
the contract is `contract EsseyMarkets is StaleFeedGuard` with no `initialize`, no `Initializable`,
no proxy — non-upgradeable, so the storage layout has one set of writers forever.

**Conclusion: every ring write in the contract's life passes through `_confirmable`, and every warm
write passes through the new guard at `:550`. There is no second path.** The enumeration the fix was
justified with is correct.

## The deleted seed guard is genuinely dead, and its property is enforced and falsifiable

`_holdConfirmable` now reads:

```
rh-chain/src/EsseyMarkets.sol:548-552
    function _holdConfirmable(address token) internal {
        Observation memory head = _confirmRing[token][_confirmHead[token]];
        if (block.timestamp - head.takenAt > MAX_CONFIRM_AGE) return;
        _confirmable(token, head.price, head.mult);
    }
```

With `head.takenAt == 0` the expression is `block.timestamp`, which on this chain is ~1.79e9 against a
32,400s ceiling. The old `if (head.takenAt == 0) return;` was therefore unreachable — a second reason
to refuse standing in front of the first, which is exactly the shape `:307-309` warns against, and the
reason M30 had stopped being killable. No underflow is possible: `takenAt` is only ever written
`block.timestamp` (`:570`, `:576`).

**And the property still bites.** M30 as repointed re-adds the zero exemption
(`head.takenAt != 0 && …`) and is **KILLED** by `test_aMarketWhoseFeedWasNeverReadableIsNotSeededAtAll`:

```
KILLED      M30 warm a never-observed market too, seeding a zero pair
            [FAIL: nothing was ever pushed: 1790223811 != 0]
```

Worth stating why that mutant matters, because it is not cosmetic: seeding `(0, 0, now)` makes
`corroboratedValue` return `available = true` with `value = 0` once the line ages in, so
`isUnderwaterCorroborated` reduces to `debt > 0` and `isInsolventCorroborated` to `debt > 0`. A market
listed on a Friday and warmed over its first weekend would have delivered **no corroboration delay at
all** on Monday. The ceiling is what refuses that, and M30 now attacks it there.

## The R6 regression tests kill the R6 bug — not just some incidental test

The gate reports only the first failing line, and for M34 that is the seeding test above, which could
have meant the fix was pinned by accident. It is not. M34 applied, `GLendR6ObservationGap` alone:

```
[FAIL: a move that has stood zero seconds pays the delay in full: 300 < 21600]
      test_aMoveThatFollowsAnObservationGapStillPaysTheFullDelay
[FAIL: the sample never becomes the corroborated price]
      test_anObservationGapCannotResurrectAnAncientPriceAsCorroborated
        wall age of the corroborated PRICE (s): 129600
        age its takenAt reports (s)           : 26700
[FAIL: one second past it, nothing does]
      test_theWarmCeilingIsTheSameCeilingTheReadApplies
[PASS] test_anObservingKeeperLeavesTheCallerNoChoiceOfFrozenPrint   <- 27000s, the control
```

Three of four red, reproducing R6 MED-1's exact numbers (300s, 36h), and the control correctly stays
green because the bug does not touch it. The tests discriminate.

## The mutation gate: 37/37, re-run from zero

`python3 test/mutants/glend-r4.py` in a scratch root at 2309cb0 → **37/37 KILLED, 0 SURVIVED, 0
ANCHOR-MISS, 0 NO-COMPILE**. The four new warm-ceiling mutants are all killed by property-named
assertions, and the two R6 survivors are dead:

```
KILLED  M32 warm from the last RAW read instead of the ring head (R6 LOW-2)
        [FAIL: every warm push stands on the ring head: 25962252698 != 32052163825]
KILLED  M33 MULTIPLIER_READ_GAS 200,000 -> 30,000,000 (effectively uncapped)
        [FAIL: and a cap that is still a cap: 30000000 >= 631480]
KILLED  M34 drop the warm ceiling            [FAIL: nothing was ever pushed: 1790223967 != 0]
KILLED  M35 warm ceiling inverted            [FAIL: seized on the first ticks back…: 16500 > 900]
KILLED  M36 warm ceiling > -> >=             [FAIL: a head AT the ceiling still warms]
KILLED  M37 warm ceiling vs a DIFFERENT constant  [FAIL: a head AT the ceiling still warms]
```

M36 and M37 are both killed by the same two-sided test, which is the right shape: a comparison pinned
on one side is half a pin, and this one decides between a silent unliquidatable market and a market
vouching for a price nobody re-read.

---

# The behaviour change, quantified

The fix is fail-closed in a state that did not exist before: a feed dark plus a keeper observation gap
now freezes corroboration until the feed returns. Three questions were asked of it. All three were
measured on the fork rather than reasoned about.

## How often does it fire? On a healthy keeper: never, at any outage length

`test_Q1_aHealthyKeeperNeverFreezesAcrossTheMeasuredMaxDarkWindow` — the deployed 300s tick, the feed
frozen, run across the **measured max AAPL gap of 79.74h (287,064s)**, sampling every tick:

```
dark window ticked (s)                : 287064
worst confirmedObservedAt age (s)     : 26700
MAX_CONFIRM_AGE (s)                   : 32400
ticks where corroboration was refused : 0
```

**Zero refusals over 957 ticks.** The mechanism is why: `_confirmable` pushes one slot per
`CONFIRM_STEP`, so a warm push refreshes the ring head every 5,400s and the head's age at any call is
at most `CONFIRM_STEP + one tick` = 5,700s against a 32,400s ceiling. The read slot trails the head by
four steps, hence the 26,700s figure — which is exactly the "one `CONFIRM_STEP` above the steady-state
maximum" the comment at `:410-416` claims, and it reproduces.

**The precondition is therefore a keeper gap of ≈7.4h or more (32,400 − 5,700) that ENDS while the
feed is unreadable.** That is not the weekend; it is a keeper outage. And it is alarmed: during the
freeze `confirmedObservedAt` stops advancing, so `classifyMarket` raises `UNOBSERVED` **fatal** for the
whole of it (`keeper-health.mjs:47-48`). A fail-closed that fires only on an already-fatal operational
alarm is not the "routinely triggering" class of problem.

## How long does it persist, and what bad debt does it manufacture?

Recovery is a **constant** `PRICE_CONFIRM_DELAY + one tick` after the feed returns, measured at
21,900s across every scenario, because the ring refills one slot per `CONFIRM_STEP` and the read slot
is four slots behind. That is the same 6h a move that landed during the outage already owes — the
freeze does not add a new delay, it removes the R6-MED-1-era fast path for a position that was already
past the bar. And it cannot trap a borrower: `EsseyPool.repay` (`:526`), `repayPartial` (`:606`) and
`addCollateral` (`:642`) carry **no** `canBorrow` / `canLiquidate` / corroboration gate, so curing
stays open throughout. The risk-increasing direction is correctly shut — `removeCollateral` (`:678`)
is `canBorrow`-gated.

`writeOff` shares the gate and is refused during the freeze (`EsseyPool._writeOffFloor:794, :799`),
with one carve-out that matters: `_writeOffFloor` is only called `if (effective != 0)` (`:817`), so a
position whose collateral was burned to nothing can still be written off while frozen. The remaining
delay in recognising a priced loss is `A-L2`, already accepted in the code
(`EsseyPool.sol:786-788` — "loss-recognition latency … is inherent to manual recognition and bounded
per-market by isolation"). The freeze extends an accepted latency; it does not create a new class.

---

# LOW-1 — the supervisor's new quiet state has no upper bound, and it does not ask WHY the price is unreadable

**CONFIRMED.** Two runnable PoCs. Read-only; nothing here moves value.

R6 LOW-1 was that `BREAKER BLIND` fired for ~40h of every 168h on a healthy keeper, and a muted alarm
is the blind spot. The fix is right in direction. What it did not carry across is a **bound**: the
contract was fixed by ADDING one (`MAX_CONFIRM_AGE` on the warm push); the supervisor was fixed by
REMOVING one and substituting nothing.

## A. `FEED DARK` never becomes an alarm, however long it lasts

```
rh-chain/keeper/keeper-health.mjs:53-60
    const baseAge = now - seenAt;
    if (baseAge <= maxBaseline) return out;
    if (priceReadable) { say(true,  `BREAKER BLIND …`); }
    else if (observing) { say(false, `FEED DARK … so this is the 24/5 feed's own schedule, and every gate behind it is already closed`); }
```

`baseAge` appears only in the message. PoC (`classifyMarket` is exported and pure):

```
  feed unreadable for    40h  ->  exit 0 (OK)
  feed unreadable for    80h  ->  exit 0 (OK)
  feed unreadable for   168h  ->  exit 0 (OK)
  feed unreadable for   720h  ->  exit 0 (OK)
  feed unreadable for  8760h  ->  exit 0 (OK)
      "FEED DARK  the price is unreadable and the baseline is 31536000s old — the keeper IS calling
       (corroborated observation 21600s old), so this is the 24/5 feed's own schedule, and every gate
       behind it is already closed"
```

A **year** of unreadable price is reported as the feed's own schedule, at exit 0. The measured max gap
is 79.74h. Anything past that is definitionally not the schedule.

## B. Four different reverts are all read as "the schedule", and three of them are not

`priceReadable` (`keeper-health.mjs:24-32`) treats *any* revert as "dark". `StaleFeedGuard.priceOf`
reverts six ways — `FeedNotConfigured` (`:120`), `SequencerDown` (`:105`), `SequencerGracePeriod`
(`:108`), `PriceNotPositive` (`:127`), `RoundIncomplete` (`:130`), `PriceStale` (`:136`). The contract's
own comment enumerates them (`EsseyMarkets.sol:625-626`, "priceOf reverts on stale, silent,
sequencer-down and unconfigured"); the classifier collapses them to one:

```
  PriceStale(a,b,c)        readable=false exit 0 (OK)   the ordinary weekend — the ONE case the downgrade is for
  PriceNotPositive(-1)     readable=false exit 0 (OK)   the aggregator is answering a NEGATIVE price
  RoundIncomplete()        readable=false exit 0 (OK)   answeredInRound < roundId
  FeedNotConfigured(t)     readable=false exit 0 (OK)   the registry has no feed for this market at all
  SequencerDown() / SequencerGracePeriod(x)             UNREACHABLE on 4663 (sequencerCheckDisabled,
                                                        StaleFeedGuard.sol:93, :102)
```

`PriceNotPositive` and `RoundIncomplete` are the signature of a **silent or broken oracle** — the exact
failure `StaleFeedGuard` exists to catch.

## C. On chain, a broken aggregator is indistinguishable from Saturday

`test_Q3_aBrokenAggregatorLooksExactlyLikeTheWeekendToEveryOnChainSignal`, mainnet-4663 fork, a feed
answering `int256(-1)` with `updatedAt` advancing normally (so this is *not* staleness by any clock),
keeper on its deployed 300s tick for a fortnight:

```
after 14 days of a NEGATIVE-price aggregator, keeper healthy throughout:
  confirmedObservedAt age (s)  : 26700     MAX_CONFIRM_AGE  (s): 32400   -> UNOBSERVED cannot fire
  worst over the fortnight (s) : 26700
  seenPriceAt age (s)          : 1209600   MAX_BASELINE_AGE (s):  3600   -> the only trip, downgraded
  canLiquidate                 : false                                   -> the market is frozen
```

Those three numbers are precisely `classifyMarket`'s inputs. **Two weeks of a frozen market with a
negative-price oracle, and the only supervisor exits 0 saying it is the feed's own schedule.**

## Why it matters more than the noisy alarm it replaced

The feed is **append-only per market**: `commitMarket` reverts `FeedIsImmutable` on any attempt to
swap a live market's feed (`EsseyMarkets.sol:774-776`), deliberately. So the remedy for a broken
aggregator is not a repoint — it is onboarding a new token entry behind `PARAM_TIMELOCK = 2 days`.
The operator needs the maximum possible warning, and this is the surface that was supposed to give it.

## Why LOW and not MEDIUM, stated so it can be argued up

- **No value moves and no gate opens.** Every on-chain gate is fail-closed for the whole state:
  `canLiquidate` refuses via `_liquidationPriceGate` (`EsseyMarkets.sol:715-722`), `canBorrow` refuses,
  `writeOff` refuses. The PoC measures `canLiquidate == false` throughout.
- **Not attacker-triggerable.** It needs the Chainlink aggregator itself to malfunction; the two
  sequencer reverts are unreachable on 4663.
- **Borrowers are not trapped** — `repay` / `repayPartial` / `addCollateral` stay open.
- **The stack is not deployed**, so there is no live exposure today.
- The transport half of the fail-open is partly covered: viem's `http` transport defaults to
  `retryCount = 3` (`viem/_esm/clients/transports/createTransport.js:6`), so a single hiccup is retried
  before it throws.

## Fix — the property, not a mechanism

*"Unreadable" is only the schedule while it is inside the schedule, and only when the registry
refuses for the schedule's reason.* Two independent halves, either of which closes most of this:

- **Bound the duration.** `FEED DARK` becomes fatal once `baseAge` exceeds a stated ceiling. The
  number is already measured and already printed by `measure-feed-volatility.mjs`: each feed's own max
  gap. Below it, report; above it, alarm. This needs no new on-chain read.
- **Match the revert, not the throw.** `priceReadable` should classify only `PriceStale` as dark, and
  treat `PriceNotPositive` / `RoundIncomplete` / `FeedNotConfigured` as fatal. viem surfaces the
  decoded error name on `ContractFunctionRevertedError`, and the ABI can carry the four error
  definitions so the name is decodable rather than string-matched.

A caution on the second, because the same trap that produced this finding is available here: the
existing pin `priceReadable(transport, probe-that-also-fails)` (`keeper-health.test.mjs:110-117`) does
**not** cover the asymmetric case — the heavy `priceOf` failing on transport while the cheap
`seenPriceAt` probe succeeds. That case returns `false` today and is untested. `priceOf` executes a
nested aggregator call; `seenPriceAt` is one `SLOAD`. They are not interchangeable evidence that "the
node is answering", and a per-call gas cap or timeout separates them. Add
`priceReadable(transport, async () => 1n)` to the test file whichever fix is chosen.

---

# LOW-2 — the fifth false green: the test named for the matched pair cannot see half the pair

**CONFIRMED.** A mutation-coverage gap with a demonstrated security consequence, proven in both
directions. Same shape and same grade as R6 LOW-2: **the shipped code is correct; what is missing is
anything that keeps it correct.**

## The survivor

Mutant **X-A**, applied to the scratch root at 2309cb0 — the multiplier half taken from the last raw
read while the price half still comes from the ring head:

```
-   _confirmable(token, head.price, head.mult);
+   _confirmable(token, head.price, seenMultiplier[token]);
```

**SURVIVES the entire targeted suite — 397/397 green** (`DesyncStateMachine|DesyncBreaker|GLendR4|
GLendR5|GLendR6|LivenessOracleTest|EsseyPoolTest|EsseyMarketsTest`, 16 suites, 0 failed).

## Why the test named for the property cannot see it

`test_theWarmedObservationStaysAMatchedPair` (`test/GLendR5.t.sol:175-193`) is exactly the right test,
in the wrong order. It takes the feed dark at `:185-186` and *then* mocks the reverse split at `:187`.
But a dark feed is precisely the state in which `seenMultiplier` cannot advance: `_syncPrice` returns
`false` (`EsseyMarkets.sol:511-513`) and `syncMultiplier` only writes the multiplier half when it
returned `true` (`:686`). So in that fixture `head.mult == seenMultiplier[token]` **by construction**,
and the mutant is invisible.

`confirmedMultiplier` is asserted in exactly two places in the whole repo — `GLendR5.t.sol:180` and
`:191`, both inside that one test (`grep -rn confirmedMultiplier test/ src/`). The catalogue brackets
this mutant without covering it: **M28** warms with `_liveMultiplier(...)` and is killed at `:191`
because the live value is `m0/2`; **M32** takes *both* halves from the raw read and is killed on the
price half by `GLendR6.t.sol:189`. The multiplier-only variant falls between the two.

## It is not equivalent, and the state it needs is a real one

The leg order that separates them is a corporate action landing while the feed **still reads**, inside
a `CONFIRM_STEP` of the last push — so `_confirmable` rate-limits it out of the ring (`:568`) while
`_syncPrice` returns `true` and `seenMultiplier` takes it (`:686`). Then the market closes. Under X-A
every warm push for the whole dark window vouches for a `(price, mult)` pair that never coexisted —
the R4 MED-1 shape, feeding a ~2x mis-scaled `o.mult` into `_valueAt`. A 1:2 reverse split halves the
corroborated collateral value, which reduces `isUnderwaterCorroborated` to a formality: the six-hour
delay stops being served for the rest of the outage, which is R3 HIGH-1's harm.

## The test that discriminates, verified in all three directions

Written and run against the scratch root. **Green on 2309cb0, red on X-A, and red on M27** (the warm
push deleted entirely) so that it cannot pass vacuously:

```
1. clean tree  [PASS] test_theWarmedMultiplierIsTheRingHeadsNotTheLastRawRead
                 corroborated multiplier after the outage: 1000566080061092436
                 the raw read it must NOT have used      :  500283040030546218
2. X-A applied [FAIL: every warm push carries the ring head's OWN multiplier:
                 500283040030546218 != 1000566080061092436]
3. M27 applied [FAIL: and the line really did warm: 1790056597 <= 1790056597]
```

The body is the mirror of `GLendR6WarmSource`, with the leg mocked **before** the feed goes dark:

```solidity
uint256 m0 = IScaledUI(AAPL).uiMultiplier();
_hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
assertEq(markets.confirmedMultiplier(AAPL), m0, "the whole ring holds the pre-leg pair");

// the split lands while the feed STILL READS, inside a CONFIRM_STEP of the last push
vm.mockCall(AAPL, abi.encodeWithSelector(IScaledUI.uiMultiplier.selector), abi.encode(m0 / 2));
markets.syncMultiplier(AAPL);
assertEq(markets.seenMultiplier(AAPL), m0 / 2, "the raw read took the leg");
assertEq(markets.confirmedMultiplier(AAPL), m0, "and the ring did not");

_neverReadable(realPrice);
uint256 observedAtBefore = markets.confirmedObservedAt(AAPL);
for (uint256 i = 0; i < 6; i++) {
    _weekend(markets.CONFIRM_STEP() + 300);
    assertEq(markets.confirmedMultiplier(AAPL), m0, "every warm push carries the ring head's OWN multiplier");
}
assertGt(markets.confirmedObservedAt(AAPL), observedAtBefore, "and the line really did warm");
(, bool ok) = markets.corroboratedValue(AAPL, _coll());
assertTrue(ok, "with a corroborated price still standing at the end of the outage");
assertEq(markets.seenMultiplier(AAPL), m0 / 2, "and the raw read still differs, so the test discriminates");
assertEq(markets.confirmedPrice(AAPL), uint256(realPrice), "the price half is untouched either way");
```

**Fix.** Add that test, and add X-A to `test/mutants/glend-r4.py` as M38. The general rule this is the
third instance of: a call forwarding two sibling values needs each argument mutated **independently**,
not only together — M32 mutating both halves at once left the one-half variants unattacked.

---

# INFO-1 — the horizon the founder is told to size against no longer has a term the R7 fix introduced

**CONFIRMED, and not a mechanism defect.** The R6 INFO-2 correction reproduces **exactly** — re-run
independently this round with `node keeper/measure-feed-volatility.mjs` against the live feeds:

| | AAPL | NVDA |
|---|---|---|
| rounds / span | 555 / 74.28d | 981 / 74.42d |
| median gap | 2,231s | 1,740s |
| max gap | **79.74h** | **76.09h** |
| per-round σ | 0.5712% (n=554) | 0.5602% (n=980) |
| derived horizon | **88h** | **84h** |
| worst move at the horizon | **12.61% (1.69×)** | **12.90% (1.65×)** |

Every number in `EsseyMarkets.sol:396-399` and `docs/MAINNET-CONFIG.md:125-136` reproduces, including
the 1.65× the founder is now asked to read the risk against. The script derives the horizon from each
feed's own `max gap + 7.5h` rather than assuming a weekend (`measure-feed-volatility.mjs:120-122`),
which is the right change.

**What is missing is the keeper term.** The doc defines the horizon as running "from the last print
whose health was verifiable" but then computes it as the *feed's* gap. After R7 those differ: the last
print whose health was verifiable is the last **observation**, and a keeper gap that begins while the
feed is still live pushes that back with no on-chain bound.
`test_Q2_theKeeperGapAddsToTheHorizonTheCommentStatesAsFeedGapPlusDelay`, same fixture, varying only
how long before the feed's final round the keeper stopped observing:

```
pre-dark keeper gap (s)      : 0        FULL horizon (s) : 151500   ( 42h)
pre-dark keeper gap (s)      : 28800    FULL horizon (s) : 180300   ( 50h)
pre-dark keeper gap (s)      : 86400    FULL horizon (s) : 237900   ( 66h)
pre-dark keeper gap (s)      : 259200   FULL horizon (s) : 410700   (114h)
    seconds after feed return : 21900 in every case
```

The slope is exactly 1:1 — the doc's formula has no term for it. (The 42h base is this fixture's 27h
dark window, not the measured 79.74h; the finding is the slope, not the base.)

**Why INFO and not LOW.** The term is bounded only by keeper downtime, which is not attacker-
controllable and is fatal-alarmed as `UNOBSERVED` from ~7.4h in. It is also the *correct* trade — the
pre-fix alternative was seizing at a price nobody had re-read, which is what R6 MED-1 was. And the
buffer absorbs it on the measured distribution: at 120h the worst moves are 13.52% AAPL / 13.52% NVDA,
still 1.57× inside 21.25%. **Recommendation:** state the horizon as *max feed gap + longest tolerated
keeper gap + `PRICE_CONFIRM_DELAY` + `CONFIRM_STEP`*, and name the operational SLO that bounds the
middle term, so the founder's 1.65× is conditioned on something rather than assumed.

---

# INFO-2 — two tests that pin "not the wrong value" without pinning "a value at all"

**CONFIRMED by direct measurement.** Neither is a live defect; both mutants are killed elsewhere in
the gate. Recorded because it is the same one-sidedness that produced four previous false greens.

- **`test_theWarmPushStandsOnTheRingHeadNotOnTheLastRawRead` (`GLendR6.t.sol:171-194`) passes with the
  warm push deleted entirely.** M27 applied, that suite alone:
  `[PASS] test_theWarmPushStandsOnTheRingHeadNotOnTheLastRawRead (gas: 2893684)`. Every assertion is an
  equality against the *pre-outage* value, which also holds if the ring never moved; nothing reads
  `confirmedObservedAt` or asserts `corroboratedValue(...).available`. M27 is killed by
  `test_theWarmCeilingIsTheSameCeilingTheReadApplies`, so the property is covered in aggregate — but
  the test named for it is one-sided. Fix: the two lines added to the LOW-2 test above.

- **`GLendR6.t.sol:126` asserts something it cannot read.**
  `assertEq(markets.confirmedPrice(AAPL), uint256(friday), "the sample was overwritten by the close")`
  is character-for-character the same assertion on the same quantity as `GLendR6.t.sol:81`, which runs
  in the world where the sample was **not** overwritten. The overwrite happens at the ring **head**;
  `confirmedPrice` reads the **read slot**, four slots away (`EsseyMarkets.sol:278-279`). Both worlds
  read `friday`. The discriminating half of that control rests on the `_secondsToLiquidatable` number
  below it, not on this line. Fix: read the head — `markets.confirmedObservation(AAPL).price`.

- **Minor, same family:** `GLendR6.t.sol:118` and `:132` bound with `assertLt(secs, 12 hours)` where
  the sibling hardened for this exact reason uses `PRICE_CONFIRM_DELAY + 2 * CONFIRM_STEP` = 32,400s
  (`GLendR5.t.sol:148-152`). 12h leaves 10,800s of unpinned slack — two extra confirm steps of
  delivered delay would survive here that R5 would catch. One constant, pinned two ways in adjacent
  files.

---

# INFO-3 — a correction to this auditor's own round-6 prescription, recorded so it is not repeated

R6's fix suggestion offered two shapes and listed the `seenPriceAt` ceiling first. **It was wrong, and
the engineer refuted it with a measurement rather than an argument.** The state the finding is about
reports `seenPriceAt` at 129,600s (36h) against a ceiling that would have had to be 295,200s to avoid
refusing an ordinary weekend — so it does not catch the resurrection at all. The shipped shape,
bounding the observation GAP, is the correct one, and it is now the only one the tree documents
(`GLendR6.t.sol:85-90` carries the refutation next to the number that proves it).

**The lesson taken.** Both refuted prescriptions were bounds proposed against a *model* of the state
rather than against the state's *measured* values. Every prescription in this round is instead
verified before it is written: LOW-2's test was run green on the tree, red on the mutant it targets,
and red on a second mutant chosen to prove it is not vacuous, before it appeared in this report.

---

# What was verified and found sound

- **Mutation gate: 37/37 killed, 0 survivors**, re-run from zero in a scratch root at 2309cb0, tree
  restored and verified byte-identical to the git objects afterwards. Every kill line carries a real
  assertion message.
- **Full suite:** `forge test` → **1,801 passed / 2 failed / 1,803, 93 suites**. Both failures are
  RPC transport inside the fork backend (`Max retries exceeded HTTP error 429`), in
  `DonSolvencyStress.t.sol:DonSolvencyStressTest` and `GLendR6.t.sol:GLendR6ObservationGap`; re-run
  individually both are **17/17 PASS**, including `test_sweep_tunables_holdSolvency` and all five Don
  invariants. **Keeper units:** `node --test keeper/test/*.test.mjs` → **115 passed / 0 failed**, of
  which `keeper-health.test.mjs` is 14/14.
- **`docs/MAINNET-CONFIG.md`'s three new claims all reproduce**: the 36h resurrection (129,600s), the
  300s-to-seizure figure, and the 27,000s control — all three re-derived by applying M34 and running
  `GLendR6ObservationGap`. The 1.65× / 84h and 1.69× / 88h figures reproduce from the live feeds.
- **`RUNBOOK.md:87-97`'s central claim reproduces.** "`confirmedObservedAt` stays inside
  `MAX_CONFIRM_AGE`, because the delay line is warmed through the outage" — measured at 26,700s
  against 32,400s across the full 79.74h max gap, with 0 refusals.
- **No new authority.** The diff adds one comparison inside an `internal` function on a permissionless
  path. No privileged key gains or loses anything; no value destination changes; no rounding changes.
- **No reentrancy through the price path.** `_readablePrice` reaches the aggregator via
  `try this.priceOf(token)`, and `priceOf` is `public view`, so the self-call is a `STATICCALL`;
  `_liveMultiplier` and `_scheduledEffectiveAt` use explicit `staticcall` with an explicit gas budget.
  The pool's entry points are `nonReentrant` besides.
- **Fail-closed cannot be induced.** `syncMultiplier` is permissionless, and every call can only make
  the ring head *fresher*. There is no way for an attacker to age the head, and the rate limit
  (`:539`) gives a front-running caller nothing: during darkness every warm push carries the same head
  pair, and once the feed returns every push carries the same live price whoever lands it.
- **`_confirmRing` cannot underflow.** `takenAt` is only ever assigned `block.timestamp` (`:570`,
  `:576`), so `block.timestamp - head.takenAt` is non-negative on any real chain.

---

# Receipt

`~/.claude/gate-receipts/audit-glend-r7` carries the SHA, RPC, chain-id, block, and the sha256 of
every audited file.

---

## Publication note (fix-first rule)

Per `[[public-audit-trail-fix-first]]`, a confirmed finding's full detail publishes only after its fix
is committed. **This report contains full detail on two open LOW findings.** The rule's stated reason —
"publishing a live unfixed finding hands attackers a working exploit next to the vulnerable code" —
does not appear to bind here: LOW-1 is an alarm-fidelity gap that requires an independent oracle
malfunction and moves no value, LOW-2 is a coverage gap on code that is *correct*, and the lending
stack is not deployed on any chain. That is a judgement for the founder, not for the auditor. **If
this round is pushed before the two fixes land, reduce LOW-1 and LOW-2 to placeholders** (round,
severity, surface, status `open`) and restore the detail with the fixes.
