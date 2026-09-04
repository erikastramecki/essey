# G-LEND gate — round 6 — Solidity / contract security lens

**Date:** 2026-09-04
**Frozen SHA:** `c04a6ce9501cf1a4aacabc20bfab8f10bb8e165b` · `git status --porcelain` **empty** (0 lines)
at the start of the round and again at the end. The only tree change this round makes is this file.
**Substrate:** Robinhood Chain **mainnet**. RPC `https://rpc.mainnet.chain.robinhood.com`,
`eth_chainId` → `0x1237` = **4663**, `web3_clientVersion` → `nitro/v3.11.4-rc.3-7d5ac27`. Fork at
latest; blocks **54,355,402 → 54,374,563** across the round. The RPC is not an archive node
(~5,000 blocks of state), so a reproducer gets a later block.
**PoC harness:** a scratch Foundry root holding `git archive c04a6ce:rh-chain src test script` —
`diff` against `git show c04a6ce:…` is empty before and after every mutant applied there. Receipt:
`~/.claude/gate-receipts/audit-glend-r6`, with the sha256 of every audited file.

## VERDICT: NOT CLEAN — 0 CRITICAL, 0 HIGH, 1 MEDIUM, 3 LOW, 4 INFO.

**The round-5 fixes hold, and the evidence behind them is re-blessed rather than inherited.** The
mutation gate was re-run from zero on this tree: **31/31 killed, 0 survivors**, tree restored, and
every kill message is a real assertion string — not one `ERC20InsufficientBalance`, which is the
false-kill class the engineer disclosed. `_fund` now uses `deal()`
(`rh-chain/test/GLendR4.t.sol:110-113`), so no fixture depends on a stranger's live balance.

**The residual the engineer named is half closed and half real.** Under a live keeper a caller
**cannot** choose which print is frozen for a weekend — the feed stops *moving* 25h before it stops
being *readable*, so every push in that window records the same close and overwrites the sample
(PoC, MED-1 below). What *is* real is the other half: `_holdConfirmable` re-stamps `takenAt`, so
`MAX_CONFIRM_AGE` now bounds the age of the last **call**, not the age of the **price**. One
observation gap that spans the feed's final round resurrects an arbitrarily stale print as
"corroborated" and a brand-new move is then seized with **zero** delay.

---

# MED-1 — the ceiling bounds the age of the last CALL, not the age of the corroborated PRICE

**CONFIRMED.** Runnable PoC on a real mainnet-4663 fork; a position is seized.

## The mechanism

```
rh-chain/src/EsseyMarkets.sol:528-534
    function _holdConfirmable(address token) internal {
        Observation memory head = _confirmRing[token][_confirmHead[token]];
        if (head.takenAt == 0) return;
        _confirmable(token, head.price, head.mult);
    }
```

`_confirmable` (`:537-545`) writes `Observation(price, mult, block.timestamp)`. So a warm push carries
the **old pair with a new stamp**, and `corroboratedValue`'s ceiling (`:311`,
`age > MAX_CONFIRM_AGE`) is tested against that new stamp. `MAX_CONFIRM_AGE` exists (`:409-412`) so
that "a market the keeper stopped observing" loses its corroborated price — R4 HIGH-2's fail-closed.
That property now holds only for a **permanently** dead keeper. An **intermittent** one resurrects.

## The precondition, stated exactly

The ring head at the moment darkness begins is the last **pushed** observation. Because the feed's
last round precedes unreadability by `maxStaleness` (90,000s = 25h,
`rh-chain/script/DeployMarkets.s.sol` `_marketList`), every push inside that 25h reads the same
constant close price — so under a live keeper the head is always the last published round. The head
is something **else** only if there is a ≥25h window with **zero** `syncMultiplier` calls (keeper
down *and* no `borrow`/`borrowMore`/`removeCollateral`/`liquidate`/`writeOff` on that pool) spanning
the feed's final round, with the keeper resuming **during** the dark window.

## Measurement — `test_anObservationGapResurrectsAnAncientPriceAsCorroborated`

Seasoned position at 90% of max LTV on the deployed AAPL/USDG parameters. A caller samples one
−1,200bps print (inside `MAX_PRICE_DEVIATION_BPS`, so nothing arms) as the ring head, then the
keeper stops observing for 27h while the feed publishes for one more hour and then goes dark; the
keeper returns inside the dark window.

```
wall age of the corroborated PRICE (s): 169200      <- 47 hours
age its takenAt reports (s)           : 23100       <- 6.4 hours
MAX_CONFIRM_AGE (s)                   : 32400       <- 9 hours
seconds from feed-return to liquidatable: 300
debt paid          : 1435883395                     <- $1,435.88 USDG
AAPL seized (raw)  : 9054627347052193628            <- 9.0546 AAPL
```

**The control, same position, same sample, same outage, keeper never stops observing —
`test_anObservingKeeperLeavesTheCallerNoChoiceOfFrozenPrint`:**

```
seconds from feed-return to liquidatable: 25200     <- the full delay, paid
```

`assertEq(markets.confirmedPrice(AAPL), uint256(close))` holds in the control: the sample was
overwritten. That pair of numbers — 300s vs 25,200s — is the finding.

## Why it matters

`PRICE_CONFIRM_DELAY` is the fix that closed **R3 HIGH-1**. Its predicate is "underwater at the live
price AND at an observation `PRICE_CONFIRM_DELAY` old". In the state above the second conjunct is
satisfied by a print from 47 hours earlier that nobody has re-checked, so a move that has stood for
**zero seconds** justifies a seizure. The borrower loses the six hours the design gives them to repay
or top up; the liquidator takes the ordinary 5% bonus on a debt that was healthy minutes earlier.

Two claims in the tree do not survive this:

- `rh-chain/src/EsseyMarkets.sol:526` — *"R4 HIGH-2 survives — this ages the line only when someone
  CALLS."* True for a keeper that never comes back. False for one that comes back inside the outage.
- `rh-chain/src/EsseyMarkets.sol:409-412` — *"without it a market the keeper stopped observing
  vouches forever for a price nobody has checked."* The ceiling no longer delivers that during a feed
  outage.

## Why MEDIUM and not HIGH, stated so it can be argued down

It cannot seize a **healthy** position: `EsseyPool.liquidate` requires `isUnderwater` at the LIVE
price first (`rh-chain/src/EsseyPool.sol:721`) before `isUnderwaterCorroborated` (`:726`), and
`_writeOffFloor` requires live `value < owed` before `isInsolventCorroborated`
(`rh-chain/src/EsseyPool.sol:797-799`). `canLiquidate` refuses outright while the feed is unreadable
(`EsseyMarkets.sol:754-762`, `_liquidationPriceGate`). There is no free profit beyond the market's
own bonus, and the precondition is a state the supervisor already alarms on (STALE BEAT + UNOBSERVED).

It is not LOW because it is a **seizure-direction** failure of the mechanism a HIGH was closed with,
it needs no adversarial control of the feed, and keeper downtime is the single failure this whole
subsystem is designed around.

## Fix — the property, not a mechanism

*A warm push may refresh the line's schedule; it must not refresh the price's claim to have been
checked.* Two shapes:

- **Bound the resurrection.** Record the wall time the pair was last read from a live feed (there is
  already `seenPriceAt`) and refuse in `corroboratedValue` when `block.timestamp - seenPriceAt[token]`
  exceeds a stated ceiling — e.g. `MAX_CONFIRM_AGE + maxStaleness + one weekend`. This keeps the
  MED-1 fix (Monday's seizure of an already-underwater position stays instant, because the pair is
  Friday's close) and refuses the 47-hour resurrection.
- **Refuse to warm across an observation gap.** In `_holdConfirmable`, return without pushing when
  `block.timestamp - head.takenAt > MAX_CONFIRM_AGE` — i.e. the line had already gone stale before
  the outage, so there is nothing legitimate to hold. One line, and it restores R4 HIGH-2 exactly.

Either needs a test that is **red against this tree**;
`test_anObservationGapResurrectsAnAncientPriceAsCorroborated` is that test with its
`assertLe(secs, GAP)` flipped to `assertGe(secs, PRICE_CONFIRM_DELAY)`.

---

# LOW-1 — the supervisor exits non-zero for ~40h of every weekend, on a keeper doing everything right

**CONFIRMED on the fork.** `test_whatTheSupervisorSeesOnAHealthyWeekend`, keeper observing on its
deployed 300s tick throughout, no attack, nothing wrong:

```
confirmedObservedAt age (s): 24900     MAX_CONFIRM_AGE  (s): 32400   -> OK (the MED-1 fix silenced it)
seenPriceAt age         (s): 108000    MAX_BASELINE_AGE (s):  3600   -> BREAKER BLIND, exit 1
```

`seenPriceAt` advances only inside the readable branch of `_syncPrice`
(`rh-chain/src/EsseyMarkets.sol:509-510`) — `_holdConfirmable` deliberately does not warm it, which is
correct. So `rh-chain/keeper/check-liveness-keeper.mjs:121` fires for the whole dark window, which is
~40h of every 168h (measured max feed gap 79.74h AAPL / 76.09h NVDA minus the 25h staleness bound).

**Why this is a security finding and not an operations nit.** `check-liveness-keeper.mjs` is the
control that R4 HIGH-2 was closed with and that R5 MED-2 was spent hardening. An alarm that is red a
quarter of the time gets muted, and a muted alarm is exactly the "market nobody observes" blind spot
both findings are about. It also compounds MED-1: the observation gap MED-1 needs is announced by
this same check.

**Fix.** Distinguish "the feed is dark" (expected, INFO) from "the keeper is not observing" (the
failure). The check already reads everything it needs: report `BREAKER BLIND` as non-fatal when
`confirmedObservedAt` is fresh — the keeper is demonstrably calling — and fatal when it is not.
`rh-chain/RUNBOOK.md:74-86` and `rh-chain/README.md:97-101` should say which lines are expected on a
weekend, so nobody wires this to a pager and then turns it off.

---

# LOW-2 — nothing pins that the warm push stands on the ring HEAD, and the alternative reopens R3 HIGH-1

**CONFIRMED.** A mutation-coverage gap with a demonstrated security consequence.

Mutant **X6**, applied to the scratch root, replacing `_holdConfirmable`'s body with the
natural-looking simplification:

```
-   Observation memory head = _confirmRing[token][_confirmHead[token]];
-   if (head.takenAt == 0) return;
-   _confirmable(token, head.price, head.mult);
+   if (seenPriceAt[token] == 0) return;
+   _confirmable(token, seenPrice[token], seenMultiplier[token]);
```

**SURVIVES the entire targeted suite — 392/392 green** (`DesyncStateMachine|DesyncBreaker|GLendR4|
GLendR5|LivenessOracleTest|EsseyPoolTest|EsseyMarketsTest`). `test_theWarmedObservationIsTheLastKnown
GoodPairNotAnOlderSlot` (`rh-chain/test/GLendR5.t.sol:190`) is named for this property and cannot see
it: both candidates are "the last known good pair"; they differ by up to one `CONFIRM_STEP`.

**They differ exactly where a half-landed corporate action lives.** `_syncPrice` writes `seenPrice`
unconditionally (`:509-510`) but `_confirmable` is rate-limited (`:539`), so a feed leg landing inside
a step is in `seenPrice` and **not** in the ring. Under X6 that dislocated price becomes the
corroborated observation for the whole outage — R3 HIGH-1 reopened across every dark window.

Test written, green on this tree and red on X6:

```
[PASS] test_theWarmPushStandsOnTheRingHeadNotOnTheLastRawRead()
  corroborated price after the outage: 19584733256      <- the pre-leg pair
  the raw read it must NOT have used : 9792366628       <- the half-landed leg
  seconds from feed-return to liquidatable: 25200

# with X6 applied:
[FAIL: the line warmed from its own head: 9792366628 != 19584733256]
```

**Fix.** Add that test and add X6 to `rh-chain/test/mutants/glend-r4.py` as M32. The shipped code is
correct; what is missing is anything that keeps it correct.

---

# LOW-3 — the fourth false green: a test named for a delay passes when the delay is INFINITE

**CONFIRMED.** Same shape as R5's LOW-1, in one of R5's own new tests.

```
rh-chain/test/GLendR5.t.sol:81    return type(uint256).max;    // "never opens inside the horizon"
rh-chain/test/GLendR5.t.sol:144   assertGe(seconds_, markets.PRICE_CONFIRM_DELAY(), "a fresh move pays the delay in full");
```

The sentinel satisfies the assertion. Mutant **X1** — `corroboratedValue` returns `(0, false)`
unconditionally, i.e. liquidation permanently broken on every market:

```
[PASS] test_aGapThatLandedDuringTheOutageStillServesTheFullDelay()
  seconds from a weekend GAP to liquidatable: 115792089237316195423570985008687907853269984665640564039457584007913129639935
```

Green, with the number printed as 2^256−1. Not a coverage hole in aggregate — the sibling
`test_anUnobservedMarketStillFailsClosedWhileTheFeedIsDead` goes red on the same mutant — but the test
that *claims* the property cannot fail for the reason it names.

**Fix.** Bound it above as well: `assertLt(seconds_, type(uint256).max, "it does open")`, or better
`assertLe(seconds_, PRICE_CONFIRM_DELAY + 2 * CONFIRM_STEP)`. The control in this round's PoC does
this with `assertLt(secs, 12 hours, "so the bound above is not vacuous")`.

---

# INFO-1 — `MULTIPLIER_READ_GAS` is pinned in one direction only, and the unpinned one is the griefing vector

**CONFIRMED.** Mutant **X2**, `200_000 → 30_000_000` (a staticcall is capped at 63/64 of remaining
gas, so this is effectively uncapped): **SURVIVES 392/392**, including
`test_theReadBudgetCoversWhatTheDeployedTokenActuallyCosts`
(`rh-chain/test/GLendR5.t.sol:286-305`), which asserts `assertLt(used, budget)` and
`assertGt(budget, used * 4)` — both lower bounds.

The constant exists "to stop a griefing token bricking five entry points"
(`rh-chain/src/EsseyMarkets.sol:620-622`); M16 attacks the same vector from the "no cap at all"
direction and is killed. The magnitude mutation R5's LOW-1 asked for was applied downward only.
**Not a live defect** — the deployed value is 200,000 and is correct. Add `assertLt(budget, 1_000_000)`
and an M33 for the upward mutation. Mutate every constant in both directions, or the pin is half a pin.

(Mutant **X5**, `MAX_CONFIRM_AGE` widened to `PRICE_CONFIRM_DELAY + 100 * CONFIRM_STEP`, is **KILLED**
by `test_anUnobservedMarketCannotBeHarvestedOnASplitLeg`. That direction is covered.)

---

# INFO-2 — the 72h horizon is the typical case; the measured worst case is ~87h, where NVDA is 1.65×

Re-derived independently with `node keeper/measure-feed-volatility.mjs` on this tree. **Everything the
comment and the doc state reproduces exactly:**

| | AAPL | NVDA |
|---|---|---|
| rounds / span | 555 / 74.28d | 981 / 74.42d |
| median gap | 2,231s | 1,740s |
| **max gap** | **79.74h** | **76.09h** |
| per-round σ (log-return sample sd) | **0.5712%** (n=554) | **0.5602%** (n=980) |
| worst 6h | 8.47% (2.51×) | 7.88% (2.70×) |
| worst 24h | 10.23% (2.08×) | 12.00% (1.77×) |
| worst 72h | **12.61% (1.69×)** | **12.62% (1.68×)** |

All match `rh-chain/src/EsseyMarkets.sol:381-399` and `docs/MAINNET-CONFIG.md:114-124`, including the
σ ordering R5 INFO-3 flagged as unreproducible — the estimator is now stated
(`keeper/measure-feed-volatility.mjs:72-81`) and it reproduces.

**The horizon itself is understated.** The window a position is genuinely unliquidatable for runs from
the last price at which its health was verifiable to the first moment it can be seized: the feed gap
plus up to `PRICE_CONFIRM_DELAY + CONFIRM_STEP` of post-return observations. At the **measured max
gap** that is 79.74h + 7.5h ≈ **87h**, not the ~71h the doc names (which is the ordinary
Friday-close-to-Monday-19:30 case). Extending the same script:

| horizon | AAPL worst | NVDA worst |
|---|---|---|
| 72h | 12.61% (1.69×) | 12.62% (1.68×) |
| **87h** | 12.61% (**1.69×**) | **12.90% (1.65×)** |
| 96h | 12.61% (1.69×) | 12.90% (1.65×) |
| 120h | 12.61% (1.69×) | 13.52% (1.57×) |

Solvency is not broken on the measured distribution and the change is 3bp of headroom, but the founder
is being asked in `docs/MAINNET-CONFIG.md:120-124` to "read the risk against 1.68x" and the measured
worst case is **1.65×**. State the horizon as the max feed gap plus the delay, not as the typical
weekend.

Two script notes carried forward from R5 INFO-3, **still unaddressed**: `normalise()` (`:66-68`) is a
magnitude heuristic that would mis-scale any name printing above $10,000 by 1e8, and the `latest`
round ids are hardcoded (`:108-111`, 555 / 981) rather than read from `latestRound()`, so a re-run
months from now silently measures a stale window. The header tells the operator to run this **before
listing a market**.

---

# INFO-3 — R5's INFO-5 is WITHDRAWN as scoped; the narrower claim is what stands

The engineer is right. `CollateralReconciler.pendingMultiplier` **is** called:
`rh-chain/test/RiskModules.t.sol:462, :477, :483, :493, :498, :507, :516, :519` — four dedicated tests
covering every return shape and a surfaceless address. R5's grep covered `src/`, `script/` and
`app/web/src` and drew a conclusion the evidence did not support.

**What stands, restated and re-verified** (`grep -rn pendingMultiplier` over the whole repo excluding
`node_modules` and `out/`): no **production** caller exists — not `src/`, not `script/`, not the UI,
not a keeper. It is a tested, unused external view. That is a code-hygiene observation and nothing
more; the "dead" characterisation is withdrawn.

---

# INFO-4 — small things, verified, none load-bearing

- **`reconcileMarkets` duplicates within `inspect`.** `configured: [A, a]` (two spellings) with
  `discovered: []` yields `inspect` of length 2 for one market. Verified by running it. Cosmetic —
  the market is merely inspected twice, and the path already fails `SCAN DISAGREES`
  (`check-liveness-keeper.mjs:98-101`). `rh-chain/keeper/market-list.mjs:33` dedupes `unknown`
  against `tokens` but not against itself.
- **R5 INFO-4's caveat is unaddressed.** `rh-chain/test/DonMainnetFork.t.sol:245`
  `assertGe(aaplMult, 1e18)` is still unbounded above; a multiplier far above par over-values
  collateral in the over-borrow direction. Out of G-LEND's contract scope, in scope for the fix under
  review. Recommend a band.
- **`forge build` fails on the default profile** ("Stack too deep", 273 files). Expected and
  documented at `rh-chain/foundry.toml:38-42` — `Deploy.s.sol` needs `via_ir` and lives in the
  `script` profile. `forge test` compiles 151 files successfully. Not a finding; recorded so the next
  round does not re-derive it.

---

# What was verified and found sound

**The mutation gate, re-run from zero on this tree.** `python3 test/mutants/glend-r4.py` →
**31/31 KILLED, 0 survivors**, `git status --porcelain` empty afterwards. Every kill line carries an
assertion message from the property it belongs to. The three false kills the engineer disclosed are
gone, and the cause is gone with them: `_fund` uses `deal()` (`rh-chain/test/GLendR4.t.sol:105-119`),
so no fixture reads a third party's balance. `deal` sets `balanceOf` only — every borrow, repay and
seizure below still moves the real deployed tokens through their own `transferFrom`.

**MED-1's fix does what it claims, and the fail-closed survives.** `test_aPositionAlreadyPastTheBar
IsSeizedWhenTheFeedReturns` measures **300s** feed-return-to-liquidatable (was 21,900s — M27 confirms
the pre-fix number on this tree). `test_aGapThatLandedDuringTheOutageStillServesTheFullDelay` measures
**25,500s** for a move that landed in the dark. `test_anUnobservedMarketStillFailsClosedWhileTheFeed
IsDead` confirms a *permanently* dead keeper still ages past the ceiling. The gate the engineer said
cannot open, cannot: `EsseyPool.sol:721` then `:726` for `liquidate`, `:797` then `:799` for
`writeOff`, both behind `canLiquidate`'s `_liquidationPriceGate` (`EsseyMarkets.sol:757-762`) which a
dark feed refuses. **A warm ring on a permanently dead feed is inert** — no borrow (`canBorrow` needs
`collateralValue`), no seizure.

**MED-2's fix is real.** `MARKET_TOKENS` unset now exits **2 before any RPC call** (run:
`check-liveness-keeper.mjs` with `LIVENESS_ORACLE`/`ESSEY_MARKETS` set and `MARKET_TOKENS` unset →
exit 2). The union is inspected and both disagreement directions fail
(`check-liveness-keeper.mjs:98-104, :106`). `node --test keeper/test/*.test.mjs` → **101/101**.

**LOW-1's fix is real.** `MULTIPLIER_READ_GAS` is `public` and pinned: M25 (5,000) and M26 (16,000)
both killed by `test_theReadBudgetCoversWhatTheDeployedTokenActuallyCosts`, measured cost 15,787 gas
on the deployed AAPL token. Only the upward direction is unpinned (INFO-1).

**LOW-3's fix is accurate.** `commitRotation` replaces both roles in one transaction
(`rh-chain/src/LivenessOracle.sol:212-213`), so the incumbent liveness guardian is not the
containment; `EsseyMarkets.guardian` is, and `DeployMarkets._checkRoles` forces it to differ from both
liveness roles (`rh-chain/script/DeployMarkets.s.sol:176-179, :195-198`) with the constructor
enforcing `RolesMustDiffer` a second time (`LivenessOracle.sol:128`). R5 INFO-1's correction to
`heartbeat()` is likewise accurate: `gap` derives from `lastHeartbeat` (`:147, :153`) and
`if (resumeAt > liquidationsResumeAt)` (`:159`) never shortens an earned grace.

**The two `ERC721InvalidReceiver` fixes are genuine.** `cast code
0xaE0bDc4eEAC5E950B67C6819B118761CaAF61946` still returns
`0xef01008a5b10eb2faf57665f63709ec4b3943a3b005df6` — the stranger's EIP-7702 delegation is still on
chain. Both fixtures normalise the vanity address to the plain EOA they always meant
(`rh-chain/test/DonSolvencyStress.t.sol` and `rh-chain/test/DonMainnetFork.t.sol`, `_asEoa`). Not a
suppression of protocol behaviour. Re-run this round: `DonSolvencyStressTest` **13/13** including
`test_sweep_tunables_holdSolvency`, which R5 could only report as an RPC 429.

**Full suite:** 1,787 passed / 2 failed / 1,789, 91 suites. Both failures are RPC transport
(`dial tcp 10.31.78.190:8547: connection refused` inside the fork backend); both suites re-run
individually **14/14 PASS**.

---

# Rulings requested by the round

**1. LOW-2 — the engineer made the COMMENT true rather than the mechanism. That is the right call.
Do NOT tighten to all five slots.**

- The threat the gate exists for is a **half-landed corporate action** — a persistent STEP. A
  two-point test with a 6h-old second point detects a step perfectly, because the older point reads
  pre-action full value and refuses. `GLendR4Corroboration.test_theFeedLegOfASplitCannotBeSeizedAt
  AnyOffset` pins that at four offsets and is green on this tree.
- What a duration test would additionally block is **ordinary wick liquidation at a real feed price** —
  which is the protocol's own liquidation predicate. Blocking it manufactures bad debt in exactly the
  direction MED-1 was just fixed to reduce.
- The magnitude is not hypothetical. Requiring all five slots turns Monday's window from "underwater
  at live + at one 6h-old observation" into "underwater continuously for 6h". Measured this round, the
  ordinary weekend already costs **25,200s** to first liquidation
  (`test_anObservingKeeperLeavesTheCallerNoChoiceOfFrozenPrint`); the tighter rule pushes the bad case
  past Monday's close and re-creates MED-1's blackout by another route, against a 72h buffer whose
  headroom is already 1.65–1.69×.
- **Accept the comment fix.** `rh-chain/src/EsseyMarkets.sol:375-383` now says "A TWO-POINT TEST, NOT
  A DURATION TEST" and matches `docs/MAINNET-CONFIG.md:95-97`. That is honest and correct.

**2. Are `PRICE_CONFIRM_DELAY = 6h`, `CONFIRM_STEP = 90m`, `MAX_CONFIRM_AGE = 9h` mutually consistent
under wall-time ageing? YES — by construction, not by coincidence.**

```
rh-chain/src/EsseyMarkets.sol:407-412
    uint256 internal constant CONFIRM_SLOTS = 5;
    uint256 public constant CONFIRM_STEP    = PRICE_CONFIRM_DELAY / (CONFIRM_SLOTS - 1);
    uint256 public constant MAX_CONFIRM_AGE = PRICE_CONFIRM_DELAY + 2 * CONFIRM_STEP;
```

Both derived from `PRICE_CONFIRM_DELAY`, so changing it carries them. At maximum push cadence the read
slot's age is `(CONFIRM_SLOTS - 1) * CONFIRM_STEP = 6h` immediately after a push and `7.5h` immediately
before the next, so the steady-state band is **[6h, 7.5h]** against a **9h** ceiling — exactly one
`CONFIRM_STEP` of slack, which is what absorbs one missed step. Warming is rate-limited through the
same `_confirmable`, so the band is identical during an outage; measured on the fork,
`confirmedObservedAt` age after 55h of dark was **24,900s** (6.9h), inside the band. M6/M22 pin both
boundaries and M10/M11 pin `CONFIRM_SLOTS` in both directions; all four are killed. **Consistent.**

**3. The 72h figures re-derived independently:** see INFO-2. Worst move 12.61% AAPL / 12.62% NVDA at
72h, headroom 1.69×/1.68×, max feed gaps 79.74h/76.09h — all reproduce. The horizon the design
actually carries is ~87h, where NVDA is 12.90% / **1.65×**.

---

# Reproduce

```bash
cd rh-chain
forge test --match-contract 'GLendR4|GLendR5' -vv        # 21/21
python3 test/mutants/glend-r4.py                          # 31/31 killed, tree restored
node --test keeper/test/*.test.mjs                        # 101/101
node keeper/measure-feed-volatility.mjs                   # the table above
LIVENESS_ORACLE=0x..1 ESSEY_MARKETS=0x..2 node keeper/check-liveness-keeper.mjs   # exit 2
```

The three PoC tests (MED-1's pair, LOW-1's supervisor probe, LOW-2's warm-source pin) are reproduced
verbatim in the appendix below; drop them into `rh-chain/test/` alongside `GLendR5.t.sol` and they
compile against the frozen tree unchanged.

## Appendix — PoC sources

### `GLendR6.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {GLendR5Base} from "./GLendR5.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GLendR6FrozenPrint is GLendR5Base {
    function setUp() public {
        _setUpFork();
    }

    function _sampleADip() internal returns (uint256 id, int256 close, int256 dip, uint256 dipAt) {
        (id, close) = _seasonedPosition();
        _hold(close, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        // Let the rate limit open so the sample is certain to be admitted as the ring's HEAD, and
        // do it without observing so nothing else is pushed in between.
        _holdQuiet(close, markets.CONFIRM_STEP() + 60);

        dip = (close * 88) / 100; // -1,200bps: inside MAX_PRICE_DEVIATION_BPS, nothing arms
        _reprice(dip);
        markets.syncMultiplier(AAPL);
        dipAt = block.timestamp;
        assertEq(markets.priceDesyncAt(AAPL), 0, "the sample did not arm the breaker");
        assertTrue(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "underwater at the sampled dip");
    }

    function test_anObservationGapResurrectsAnAncientPriceAsCorroborated() public {
        (uint256 id, int256 close, int256 dip, uint256 dipAt) = _sampleADip();

        _holdQuiet(close, 1 hours);
        _weekendQuiet(26 hours);
        assertFalse(markets.canLiquidate(AAPL), "the feed is dark");

        _weekend(20 hours);

        uint256 priceAge = block.timestamp - dipAt;
        uint256 stampAge = block.timestamp - markets.confirmedObservedAt(AAPL);
        (, bool ok) = markets.corroboratedValue(AAPL, _coll());
        console.log("wall age of the corroborated PRICE (s):", priceAge);
        console.log("age its takenAt reports (s)           :", stampAge);
        console.log("MAX_CONFIRM_AGE (s)                   :", markets.MAX_CONFIRM_AGE());
        assertEq(markets.confirmedPrice(AAPL), uint256(dip), "an ancient print is what the line vouches for");
        assertTrue(ok, "and it is AVAILABLE");
        assertLe(stampAge, markets.MAX_CONFIRM_AGE(), "inside the ceiling by its own clock");
        assertGt(priceAge, 4 * markets.MAX_CONFIRM_AGE(), "while the price it carries is far outside it");

        int256 monday = (close * 85) / 100;
        uint256 secs = _secondsToLiquidatable(id, monday);
        console.log("seconds from feed-return to liquidatable:", secs);
        assertLe(secs, GAP, "a fresh move is seized with no delay at all");

        uint256 owed = pool.debtOf(id);
        uint256 before = IERC20(AAPL).balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(id);
        console.log("debt paid          :", owed);
        console.log("AAPL seized (raw)  :", IERC20(AAPL).balanceOf(liquidator) - before);
        assertEq(pool.debtOf(id), 0, "the seizure lands");
    }

    function test_anObservingKeeperLeavesTheCallerNoChoiceOfFrozenPrint() public {
        (uint256 id, int256 close,,) = _sampleADip();

        _hold(close, 1 hours);
        _weekend(26 hours); // readable at `close` for 25h, then dark
        _weekend(20 hours);

        assertEq(markets.confirmedPrice(AAPL), uint256(close), "the LAST ROUND stands, not the sample");
        int256 monday = (close * 85) / 100;
        uint256 secs = _secondsToLiquidatable(id, monday);
        console.log("seconds from feed-return to liquidatable:", secs);
        assertGe(secs, markets.PRICE_CONFIRM_DELAY(), "the fresh move pays the delay in full");
        assertLt(secs, 12 hours, "and it does open, so the bound above is not vacuous");
    }
}

contract GLendR6SupervisorState is GLendR5Base {
    function setUp() public {
        _setUpFork();
    }

    function test_whatTheSupervisorSeesOnAHealthyWeekend() public {
        _hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        _weekend(55 hours); // readable at the Friday close for 25h, dark for the other 30h

        uint256 confAge = block.timestamp - markets.confirmedObservedAt(AAPL);
        uint256 baseAge = block.timestamp - markets.seenPriceAt(AAPL);
        console.log("confirmedObservedAt age (s):", confAge);
        console.log("MAX_CONFIRM_AGE         (s):", markets.MAX_CONFIRM_AGE());
        console.log("seenPriceAt age         (s):", baseAge);
        console.log("MAX_BASELINE_AGE        (s):", markets.MAX_BASELINE_AGE());

        // check-liveness-keeper.mjs:118 — silenced by the warm push, which is the R5 MED-1 fix.
        assertLe(confAge, markets.MAX_CONFIRM_AGE(), "no UNOBSERVED");
        // check-liveness-keeper.mjs:121 — fires, on a keeper that is doing everything right.
        assertGt(baseAge, markets.MAX_BASELINE_AGE(), "BREAKER BLIND fires and the check exits 1");
    }
}
```

### `GLendR6X6.t.sol` — the missing pin for LOW-2

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {GLendR5Base} from "./GLendR5.t.sol";

contract GLendR6WarmSource is GLendR5Base {
    function setUp() public {
        _setUpFork();
    }

    function test_theWarmPushStandsOnTheRingHeadNotOnTheLastRawRead() public {
        (uint256 id, int256 p0) = _seasonedPosition();
        _hold(p0, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());

        // Open the rate limit, then take a push at p0 so the head is p0 and the clock has just been
        // reset — the leg below therefore lands INSIDE a step and cannot enter the ring.
        _holdQuiet(p0, markets.CONFIRM_STEP() + 60);
        _reprice(p0);
        markets.syncMultiplier(AAPL);
        assertEq(markets.seenPrice(AAPL), uint256(p0), "the raw read and the head agree here");

        // The feed leg of a 2:1 split lands. The multiplier leg has not.
        int256 leg = p0 / 2;
        _reprice(leg);
        markets.syncMultiplier(AAPL);
        assertEq(markets.seenPrice(AAPL), uint256(leg), "the raw read took the dislocation");
        assertGt(markets.priceDesyncAt(AAPL), 0, "and the breaker armed on it");

        // The feed goes dark before the leg can ever be pushed, and stays dark past the hold.
        _neverReadable(leg);
        _weekend(20 hours);

        console.log("corroborated price after the outage:", markets.confirmedPrice(AAPL));
        console.log("the raw read it must NOT have used :", markets.seenPrice(AAPL));
        assertEq(markets.confirmedPrice(AAPL), uint256(p0), "the line warmed from its own head");
        assertFalse(
            markets.isUnderwaterCorroborated(AAPL, _coll(), pool.debtOf(id)),
            "so the half-landed leg is still not corroborated, 20h into the outage"
        );

        uint256 secs = _secondsToLiquidatable(id, leg);
        console.log("seconds from feed-return to liquidatable:", secs);
        assertGe(secs, markets.PRICE_CONFIRM_DELAY(), "R3 HIGH-1 holds across the outage");
    }
}
```

### The three extra mutants

```python
("X2 MULTIPLIER_READ_GAS 200,000 -> 30,000,000 (effectively uncapped)", MARKETS,
 "uint256 public constant MULTIPLIER_READ_GAS = 200_000;",
 "uint256 public constant MULTIPLIER_READ_GAS = 30_000_000;"),                     # SURVIVED 392/392
("X5 MAX_CONFIRM_AGE ceiling widened to +100 steps", MARKETS,
 "uint256 public constant MAX_CONFIRM_AGE = PRICE_CONFIRM_DELAY + 2 * CONFIRM_STEP;",
 "uint256 public constant MAX_CONFIRM_AGE = PRICE_CONFIRM_DELAY + 100 * CONFIRM_STEP;"),  # KILLED
("X6 warm from seenPrice/seenMultiplier rather than the ring head", MARKETS,
 "        Observation memory head = _confirmRing[token][_confirmHead[token]];\n"
 "        if (head.takenAt == 0) return; // never observed: seeding a zero pair would only add noise\n"
 "        _confirmable(token, head.price, head.mult);",
 "        if (seenPriceAt[token] == 0) return;\n"
 "        _confirmable(token, seenPrice[token], seenMultiplier[token]);"),         # SURVIVED 392/392
```
