# G-LEND gate — round 3 of 3 — Solidity/contract security lens

**Date:** 2026-09-04
**Frozen SHA:** `0cf6831f62d01ba4074506e7066cc7a42a35322c` · `git status --porcelain` **empty** at start and end
**Substrate:** Robinhood Chain **mainnet**, `https://rpc.mainnet.chain.robinhood.com`, chain-id **4663**,
blocks **54120413 → 54126213** (the RPC is not an archive node, so runs are at latest and the block is
logged from inside the EVM; a reproducer will get a later one)

## VERDICT: NOT CLEAN — 1 CRITICAL, 1 HIGH, 3 MEDIUM, 2 LOW, 3 INFO. The counter resets to zero.

Round 2's HIGH-1 is closed **in the case it was written for** — `B_Desync::test_B2`, the round-2 PoC, now
FAILS with `LiquidationNotAllowed`, and the repo's own `DesyncBreakerTest` is a genuinely good suite. The
CRITICAL below is not that bug returning by accident. It is a **second state in the breaker's own state
machine** that the suite never enters: once armed, `desyncRefProduct` is released **only** on agreement,
so the first >20% product move that does *not* mean-revert leaves the reference stuck at a stale value
and the breaker can never arm again. R2 HIGH-1 is then fully restored, at the same magnitude — measured
at **110% of the debt in free profit against a healthy borrower**, on real AAPL, real feed, real USDG.

The engineer's own replacement harness walks into that state and does not notice:
`G_EngineerProof::_crashAndSettle` arms the breaker and waits out the hold, leaving `desyncRefProduct`
permanently set, and every test built on it runs against a market whose breaker is already dead.

---

## What round 2 found, re-checked at `0cf6831`

| R2 finding | Status | Evidence |
|---|---|---|
| HIGH-1 feed-first split liquidates healthy positions | **CLOSED for the single-event case, REOPENED by CRIT-1** | `B_Desync::test_B2` now FAILS `LiquidationNotAllowed`. `H_StaleRef::test_H1a` (control) confirms a fresh breaker arms and refuses. `test_H1b` restores the exploit with one prior event. |
| MED-1 liveness amplification ceiling | **CLOSED** | `LivenessOracle.sol:109` grants `min(gap, resumeGrace)`; `G_EngineerProof::test_G3` measures a 901s gap costing < 4×`gapThreshold`. Amplification ≤ 2× for any parameter pair. |
| MED-2 four of five roles may be one key | **PARTIALLY closed — see MED-2 below** | `DeployMarkets.s.sol:164-179` separates `RESERVE_TREASURY` from all four and forbids `GUARDIAN == LIVENESS_KEEPER`. `GUARDIAN == LIVENESS_GUARDIAN` is still accepted and reaches the same union in one transaction. |
| LOW-1 liquidate/writeOff revert under a collateral freeze | **CLOSED, and correctly** | `J_Escrow` ×6 and `C_Escrow` ×7 on the real token: one deed, one claimant, solvency held, pro-rata burn sharing during escrow, and `writeOff` closing a wiped position under the freeze. |
| LOW-2 MAINNET-CONFIG contradicts the script | **CLOSED** | `docs/MAINNET-CONFIG.md:47-68` now matches `DeployMarkets.s.sol` on arity, curve, risk params and Bell wiring. One residual overstatement — see INFO-2. |
| LOW-3 testnet USDG mock is 18 decimals | **CLOSED** | `DeployMarkets.s.sol:251` passes `prof.usdgDecimals`. |
| LOW-4 "two independent keepers" not implementable | **CLOSED in text** | `EsseyMarkets.sol:118-121` now states the bound that exists. |
| INFO-1 `v4DiscountBps` dead storage | **CLOSED** | `grep -rn v4DiscountBps rh-chain/` returns **zero** source hits; `Params` is four fields (`MarketHealthOracle.sol:58-63`). One stale doc citation remains — INFO-3. |

**Repo suite at the frozen SHA:** `forge test` over the 20 lending suites — **864 passed, 0 failed, 23
suites.** Every finding below is live while all 864 are green.

---

# CRIT-1 — one unresolved >20% price move permanently disarms the corporate-action breaker, restoring R2 HIGH-1 in full

**CONFIRMED.** `src/EsseyMarkets.sol:347-365` (`_breaker`), `:300-317` (`_desyncGuard` branch (c)).
PoC: `test_H1b_aPriorCrashPermanentlyDisarmsTheBreaker`, control `test_H1a`.

## The state machine

```solidity
// EsseyMarkets.sol:347-365
function _breaker(address token, uint256 prev, uint256 observed) internal {
    uint256 ref = desyncRefProduct[token];
    if (ref != 0) {
        if (_deviates(ref, observed)) return;      // <-- still apart: returns, does NOT re-stamp
        delete desyncRefProduct[token];
        delete priceDesyncAt[token];
        ...
    }
    if (!_deviates(prev, observed)) return;
    desyncRefProduct[token] = prev;
    priceDesyncAt[token] = block.timestamp;
    ...
}
```

`desyncRefProduct` is deleted in **exactly one place**: the agreement branch. The 6-hour hold, by
contrast, is read off `priceDesyncAt` and expires on the clock (`:315-316`). So the two halves of the
armed state have different lifetimes:

| after `PRICE_DESYNC_HOLD` with no agreement | value |
|---|---|
| `_desyncGuard` branch (c) | `false` — the gates reopen (intended, and correct) |
| `priceDesyncAt[token]` | **unchanged, non-zero, hours or months old** |
| `desyncRefProduct[token]` | **unchanged — the pre-event product, now permanently wrong** |

Every later observation takes the `ref != 0` branch and returns. `priceDesyncAt` is never re-stamped, so
branch (c) is `false` forever. **The market's breaker is dead, permanently, and nothing on chain says so.**

The only exit is an observation whose product comes back within 2,000bps of that stale reference. After a
crash or a rally that holds, that never happens.

## What arms it — and why an attacker chooses the moment

Arming does not require a corporate action. `_breaker` compares the current observation against the
**previous observation**, and `syncMultiplier` is permissionless and non-reverting, so:

- an ordinary >20% single-name move arms it (a real gap that does not recover), **and**
- so does ordinary drift measured across a sparse observation gap — see MED-1.

A borrower or a would-be liquidator can therefore **choose** when it arms, for one transaction of gas:
call `markets.syncMultiplier(token)` at a local high, wait for a ≥20% adverse move, call it again. They
buy 6 hours of liquidation immunity *and* permanently disable the breaker for that market.

## PoC — real AAPL, real feed, real USDG, deployed risk params (50/75/500)

`H_StaleRef::test_H1b`. No corporate action in step 1; the only special act is one standalone
`syncMultiplier`.

```
1. baseline observed at the live AAPL feed price P
2. a 30% single-name gap: price -> 0.70P, one standalone syncMultiplier
       priceDesyncAt  != 0                    armed (a false positive, but bounded)
3. serve out PRICE_DESYNC_HOLD + 1h  (exactly G_EngineerProof._crashAndSettle)
       canLiquidate    == true                the hold is bounded  -- correct
       priceDesyncAt   == unchanged           never cleared
       desyncRefProduct== unchanged           never released
4. a healthy position opens at 45% LTV against a 75% threshold
       isUnderwater    == false
5. the ex-date: the FEED halves (0.35P); uiMultiplier has not moved
       priceDesyncAt   == unchanged           <-- THE BREAKER DOES NOT RE-ARM
       canLiquidate    == true
       isUnderwater    == true                a healthy position reads underwater
6. liquidate
       debt repaid by the liquidator (USDG)  1 030 853 851     $1,030.85
       true value of seized units  (USDG)    2 164 793 101     $2,164.79
       free profit                 (USDG)    1 133 939 250     $1,133.94
       profit as bps of the debt                    11 000     110% of the debt
```

Control, same fixture, step 2–3 removed: `test_H1a` — the breaker arms on the split leg and
`pool.liquidate` reverts `LiquidationNotAllowed`. **The asymmetry is the finding.**

Scaled to the deployed `cap = 250,000e6` per market, the extractable value is of the order of the whole
market's collateral, taken from borrowers, on a date that is public months in advance — the same
magnitude round 2 measured, with a precondition that occurs naturally and can also be manufactured.

## Why the repo suite misses it

`test/DesyncBreaker.t.sol` is thorough and covers arming, the arm-and-revert rollback, the standalone
observation, clearing on agreement, the exact deviation boundary and the exact hold boundary. It never
runs **two events on one market.** `test_aStandaloneSyncCommitsTheArmAndTheHoldExpires:69-85` leaves the
market in exactly the poisoned state and then ends.

## Fix

Release the reference when the hold expires, not only on agreement — the same observation that finds the
hold elapsed should re-baseline:

```solidity
if (ref != 0) {
    if (!_deviates(ref, observed)) { /* cleared on agreement, as today */ }
    else if (block.timestamp - priceDesyncAt[token] >= PRICE_DESYNC_HOLD) {
        // the hold is spent and the legs never agreed: this IS the new level. Re-baseline so a
        // LATER dislocation can arm against it, and re-arm if `observed` deviates from `prev`.
        delete desyncRefProduct[token];
        delete priceDesyncAt[token];
        // fall through to the un-armed path below, judged against `prev`
    } else return;
}
```

Then pin it with a test that runs **two** events on one market: arm, expire, and assert the next
dislocation arms again. Any fix that leaves `desyncRefProduct` set past the hold has the same bug.

---

# HIGH-1 — the 2,000bps bound is derived against a freshly-opened position, so every seasoned position is harvestable by a sub-bound corporate action

**CONFIRMED.** `src/EsseyMarkets.sol:264-270`, `test/DesyncBreaker.t.sol:121-129`.
PoC: `test_H2_subBoundCorporateActionHarvestsSeasonedPositions`.

## Re-deriving the stated bound

The comment claims:

> *"The harm is a price under-read big enough to flip a position opened at max LTV to underwater, which
> needs `1 - ltvBps / liqThresholdBps`. The most fragile market `_validate` can admit is liqThreshold
> 9,000 over ltv 7,000 … = 2,223bps, so 2,000 sits below it for EVERY listable market."*

**The arithmetic is right.** `_validate` (`:600-614`) caps `liqThresholdBps ≤ 9,000` and requires
`liqThresholdBps - ltvBps ≥ 2,000`, so `ltv/liqT ≤ 1 - 2000/liqT`, maximised at `liqT = 9,000` → `7/9`,
giving `1 - 7/9 = 2,222.2 → 2,223bps`. The over-read direction is looser (`liqT/ltv - 1 = 2,857bps`), so
the under-read binds. `MarketHealthOracle.Params` (`:58-63`) carries no LTV or threshold, so the bound
does **not** move under health-oracle param changes — that part of the claim holds.

**The worst case is the wrong one.** The harm surface is not a freshly-opened position; it is every
**open** position, and a position's cushion shrinks the moment the price moves against it. A position
opened at 45% LTV against a 75% threshold has 40% of cushion on day one and roughly **13%** after an
ordinary 15% adverse move — well inside `MAX_PRICE_DEVIATION_BPS`. The stated property, *"no listable
market can be flipped un-armed"* (`DesyncBreaker.t.sol:127`), is false for the ordinary state of a loan.

## The event that exercises it

A small-ratio corporate action. A 6:5 split moves the feed by `1 - 5/6 = 16.67%` — **inside the bound**,
so the breaker never arms; and `multiplierMovedAt` is 0 while the feed leg leads, so branch (b) is silent
too. 5:4 (exactly 2,000bps — admitted, the comparison is strictly greater, pinned at
`DesyncBreaker.t.sol:134-146`), 6:5, and stock dividends of 5–20% are all under or at the bound.

## PoC — real AAPL, deployed params

```
position opened at 45% LTV, then seasoned to ~65% LTV in observed steps that each stay under the bound
  no step arms the breaker              priceDesyncAt == 0
  pre-action: owed 1 472 648 358 / collateral value 2 258 060 817     healthy, not liquidatable

6:5 split, feed leg first (-16.67%):
  priceDesyncAt == 0                    a 16.67% leg never arms the breaker
  canLiquidate  == true
  isUnderwater  == true                 the healthy position reads underwater

  paid           1 472 648 358   $1,472.65
  true value     1 855 536 937   $1,855.54
  free profit      382 888 579   $382.89   = 2,600bps of the debt
```

`test_H2b` pins the boundary from the other side: 1,900bps is admitted, 2,100bps arms.

## Also: the product is invariant across SPLITS, not across every corporate action

The premise at `:319-323` — *"a corporate action rescales both legs in opposite directions"* — is exact
for forward and reverse splits (rounding on an 18-decimal multiplier and an 8-decimal feed is ~1e-8
relative, six orders of magnitude below the bound; a partial or rounded multiplier update is a non-event
for this breaker). It is **not** true for a special cash dividend, a spin-off, or a redenomination, where
the price leg moves and the multiplier leg does not. Those are single-leg events: the breaker reads them
as a dislocation, holds for 6h (a false positive), and — via CRIT-1 — poisons the reference permanently.
Whether Robinhood expresses dividends through `uiMultiplier` at all is **UNVERIFIED**; it is the issuer's
operational choice and not observable from chain. What *is* verified is that a single-leg product move of
any origin produces the CRIT-1 state.

## Fix

State the bound honestly and make the fixture cover the case: `MAX_PRICE_DEVIATION_BPS` protects a
position holding at least that much cushion; below it, the protocol is exposed to a sub-bound corporate
action. Either accept that explicitly at `:264-270` and rename
`test_theBoundSitsBelowTheWorstListableMarketsHarmThreshold` to what it checks, or add a second,
independent signal for the case the price side cannot resolve — e.g. treat any observed `uiMultiplier`
move as arming for `PRICE_DESYNC_HOLD` rather than `MULTIPLIER_GUARD_WINDOW`, so a small-ratio action is
caught by its *other* leg regardless of order.

---

# MED-1 — the breaker measures the change between OBSERVATIONS, not between feed rounds, and nothing observes

**CONFIRMED.** `src/EsseyMarkets.sol:338-345`, `:416-425`. PoC: `test_H1c`.
`grep -rn syncMultiplier` over `keeper/` returns **zero hits**.

`_syncPrice` compares `seenPrice[token] * prevMult` against `price * curMult`, and `seenPrice` advances
only when someone calls `syncMultiplier`. The five pool paths that call it (`EsseyPool.sol:430, 501, 676,
706, 789`) all **revert when the guard fires**, taking the arming write with them, so the only durable
observer is a standalone permissionless call — which no keeper makes.

On a quiet market the interval between observations is unbounded, and the breaker therefore fires on
cumulative drift rather than on a discontinuity:

```
test_H1c: three weeks with nobody borrowing, liquidating or observing; -22% cumulative drift
   priceDesyncAt != 0      an ordinary 22% drift arms the breaker
   canLiquidate  == false  6 hours of liquidation blackout for a real, gradual move
```

Two consequences, and the second is the serious one:

1. **False-positive liquidation blackouts** on exactly the markets least able to afford them — thin,
   quiet ones, during a real repricing.
2. **It is CRIT-1's precondition**, and it makes it cheap. The rarer the observation, the likelier the
   next one exceeds the bound, and the first one that does kills the breaker for good.

`docs/MAINNET-CONFIG.md:64-68` describes the mechanism as *"a one-step move of `price x uiMultiplier`"*.
It is not a one-step move; it is a between-observations move.

## Ruling on the disclosed operational gap

The engineer disclosed it at `EsseyMarkets.sol:330-331` — *"NOTHING IN keeper/ CALLS IT TODAY: an
operational gap, not a covered one"* — and asked whether it is a documentation, keeper or design problem.

**It is a design problem first and a keeper problem second, and it is deploy-blocking as part of CRIT-1.**
Documentation is the least of it: the contract's stated semantics ("a single-round move") are only true
when observations are dense, and nothing in the system makes them dense. A `syncMultiplier` cron is
necessary but not sufficient — a keeper outage silently converts the breaker back into a drift detector,
and CRIT-1 turns the first such false positive into a permanent disarm. Whatever ships must either (a)
make the comparison independent of caller cadence, or (b) treat a stale `seenPrice` as "no baseline"
(return without arming when `block.timestamp - seenPriceAt > maxStaleness`) so an unobserved market fails
*open on arming* rather than arming on drift — and, either way, land the CRIT-1 re-baseline so a false
positive costs 6 hours instead of forever.

---

# MED-2 — `GUARDIAN == LIVENESS_GUARDIAN` is unconstrained, and reaches the forbidden union in one un-timelocked transaction

**CONFIRMED.** `script/DeployMarkets.s.sol:152-179`, `src/LivenessOracle.sol:139-144`.
PoC: `test_K1_guardianMayBeTheLivenessGuardianAndBecomeTheKeeper`, run against a copy of
`DeployMarkets.s.sol` that is byte-identical apart from import depth (`diff` output: identical).

`_checkRoles` now enforces four rules. The one added for R2 MED-2 is:

```solidity
// DeployMarkets.s.sol:176-179
require(testnet || r.guardian != r.livenessKeeper,
        "GUARDIAN must not be the liveness keeper - refusing to deploy");
```

with the reasoning at `:172-175` that their union is *"halt everything, indefinitely"*. But
`LivenessOracle.setKeeper` is **guardian-only, immediate, and un-timelocked** (`LivenessOracle.sol:139`),
and nothing constrains `GUARDIAN` against `LIVENESS_GUARDIAN`:

```
h.check(false /* mainnet */, {guardian: 0xB0B, livenessKeeper: 0xCAFE,
        livenessGuardian: 0xB0B, depthKeeper: 0xB0B, reserveTreasury: 0xC01D})   -> ACCEPTED

liv.setKeeper(0xB0B)  as 0xB0B                    -> keeper == 0xB0B
warp(gapThreshold + 1); liquidationsAllowed()     -> false
```

One key then holds: `disableMarket` on every market, `pauseLiquidation` on every market (MED-3, chainable
indefinitely), the depth keeper, **and** the liveness keeper — i.e. exactly "halt everything,
indefinitely", reached in one transaction with no notice. `EsseyMarkets.guardian` is `immutable`
(`:122`), so the posture cannot be rotated afterwards.

**Fix.** One more line, the same shape as the others:

```solidity
require(testnet || r.guardian != r.livenessGuardian,
        "GUARDIAN must not be the liveness guardian - refusing to deploy");
```

`test/DeployMarketsRoles.t.sol` tests the rules that exist and is honest to them; the rule is the gap.

---

# MED-3 — `pauseLiquidation` chains into the permanent freeze it is documented to make impossible

**CONFIRMED.** `src/EsseyMarkets.sol:582-588`. PoC: `test_H3_pauseLiquidationChainsIntoAPermanentFreeze`.

The cap is **per call**, and the storage is an absolute deadline that each call overwrites:

```solidity
uint256 ceiling = block.timestamp + MAX_LIQUIDATION_PAUSE;   // now + 24h
if (until > ceiling) revert PauseTooLong(until, ceiling);
liquidationPausedUntil[token] = until;
```

So a guardian calling it once a day holds liquidation off indefinitely. Measured, on the real market with
a deeply underwater position:

```
60 chained daily pauses:
   canLiquidate  == false throughout, never reopens
   pool.liquidate -> LiquidationNotAllowed
   owed  1 472 648 358 -> 1 484 446 725     debt compounds through the freeze
```

The comment at `:276-278` claims the cap makes *"a forgotten pause not the permanent freeze the missing
`enabled` conjunct on canLiquidate exists to prevent"*, and `DesyncBreaker.t.sol:197-198` asserts *"the
pause must never become the permanent freeze"* — a test whose name is broader than what it checks
(`test_thePauseIsBoundedAndClearable` tests one call, not two).

**Partially disclosed, and that is why this is MEDIUM not HIGH:** `EsseyMarkets.sol:111-114` does say
*"THE SECOND ONE IS A LIQUIDATION KILL SWITCH while it holds, and repeated calls extend it"*. Three
documents in the same repo now disagree about the same property. Given MED-2, the key that holds it can
also be the liveness keeper, so the two independent liquidation kill-switches collapse onto one address.

**Fix (pick one).** Either bound the *cumulative* pause per market (a budget that refills slowly), or
accept it explicitly, remove the contradicting comment at `:276-278`, correct
`test_thePauseIsBoundedAndClearable`'s claim, and fix MED-2 so the key is at least separated from the
liveness keeper's power.

---

# LOW-1 — `test_C7` is a false green, and the replacement does prove what C7 was for

**CONFIRMED.** PoC: `test_K2_c7RevertsOnTheBreakerNotTheFreeze`.

Round 2's `C_Escrow::test_C7` still passes at this SHA. It reprices −60% in one step, freezes transfers,
and asserts a bare `vm.expectRevert()`. The −60% arms the breaker, so `liquidate` reverts on
`LiquidationNotAllowed` at `EsseyPool.sol:707` and never reaches the frozen transfer the test is named
for. Measured both ways:

```
frozen token     -> LiquidationNotAllowed(0xaF3D...93f9)
NOT frozen       -> LiquidationNotAllowed(0xaF3D...93f9)     identical, so the freeze was never reached
```

The replacement is sound. `G_EngineerProof::test_G1/test_G2` settle the breaker first
(`_crashAndSettle`) and then exercise the escrow, and they prove the property C7 was written to hold —
independently re-derived here by `J_Escrow` ×6 (below). C7 itself should be deleted or given the exact
revert selector; a bare `expectRevert` in a suite that now has a gate above the transfer will keep doing
this.

**Swept for other false greens.** The 864-test repo suite was checked for the same shape: the only
`vm.expectRevert()` calls without a selector on a path the breaker gates are
`DesyncBreaker.t.sol:63` and `:78`, and both are deliberate and correct (they assert *that* the arming
transaction reverts, which is the property under test). No other repo test changed meaning.

---

# LOW-2 — the views stay optimistic, and nothing forces an external consumer to be safe

**RE-FLAGGED from the prompt, CONFIRMED, and accepted with the rationale recorded.**

`canBorrow` and `canLiquidate` are `view`, so they cannot call `syncMultiplier`. During a dislocation that
no transaction has yet observed, both answer `true` while the pool's own gate answers `false`. The repo
states this honestly (`DesyncBreaker.t.sol:58-60`), and the pool is safe because it syncs above its own
gate. The residual is that any *external* consumer — the web app, the MCP `essey_health` / `essey_quote`
tools, a third-party liquidation bot — reading only the view gets an answer the chain will refuse.

**Accepted.** The failure mode is a reverted transaction, not a loss, and making the views non-view would
cost every read-only consumer. Recorded here rather than silently passed. The one thing it should get is
a documented companion: publish `priceDesyncAt`/`desyncRefProduct` in whatever the UI and MCP call, so a
consumer can at least see the market is unobserved.

---

# INFO

**INFO-1 — a stale comment about a constraint that no longer exists.** `DeployMarkets.s.sol:258-259`:
*"resumeGrace 1h is Chainlink's recommended sequencer grace and exactly the 4x gapThreshold ceiling the
constructor enforces."* `LivenessOracle.sol:64-69` replaced that ratio with absolute ceilings
(`MAX_GAP_THRESHOLD = 1 hours`, `MAX_RESUME_GRACE = 6 hours`) and says so explicitly. The deploy script
now justifies its parameters by a rule the contract does not have.

**INFO-2 — `MAINNET-CONFIG.md` overstates the breaker on the two points MED-1 and CRIT-1 are about.**
`:64-68` says a move past the bound *"holds both gates until the two legs agree again, or for the hold"*
and calls it *"a one-step move"*. Neither is accurate: it is a between-observations move (MED-1), and
after the hold expires without agreement the reference is never released (CRIT-1).

**INFO-3 — one stale register citation.** `docs/MAINNET-ACTIVATION.md:1448` lists
`Params = capFractionBps, hysteresisBps, maxRaisePerDayBps, v4DiscountBps, raiseDelay` at
`src/MarketHealthOracle.sol:59-65`. `v4DiscountBps` was deleted at this SHA and `Params` is four fields
(`MarketHealthOracle.sol:58-63`). R1/R2 INFO-1 is closed; the row that tracks it is not.

**Not re-flagged: `EsseyMarkets.admin` / `MarketHealthOracle.admin` are still the deploy key.** Verified
still true (`DeployMarkets.s.sol:262, 264` both pass `msg.sender`). Both powers are timelocked 2 days and
the admin cannot swap a feed, a multiplier source or the freshness pair (all append-only,
`EsseyMarkets.sol:508-527`). Round 1 enumerated the blast radius and it is unchanged. This is a standing,
recorded posture, not a new finding.

**Not re-flagged: `BorrowFlow.t.sol` runs an internally-consistent 18-decimal stack.** Still true, and
still weaker than a fork test — but `test/ForkMvp.t.sol` and this round's harness both execute the
production call shape against the production addresses, which is the gate round 1 asked for.

---

# Verified clean this round (asserted on the fork, not assumed)

**The lender-side escrow holds under every ordering I could construct.** `J_Escrow` ×6, real AAPL, real
USDG:

- **One escrow, one deed, one claimant.** The borrower's deed is burned and re-issued to the liquidator
  atomically (`EsseyPool.sol:756-757`, plain `_mint`, no `onERC721Received` surface —
  `Note.sol:36-41`). The borrower cannot claim, cannot repay, cannot top up, and the position cannot be
  re-liquidated or written off. `claimCollateral` is single-use and pays exactly the seizure. *(J1)*
- **The escrowed deed is bearer.** Transferred mid-escrow, only the new holder can claim. *(J2)*
- **A burn during the escrow is shared, not absorbed.** A third of the pool's AAPL destroyed while one
  position is escrowed and one is open: escrow claim `6 666 666 666 666 666 660`, open-position return
  `3 999 999 999 999 999 996` against `coll1 = 10e18` / `coll2 = 6e18` — both lost exactly one third, and
  the sum fits inside the surviving balance. *(J3)*
- **Two escrows, two deeds, two claimants**, and nothing stranded: `recordedRaw == 0` and
  `balanceOf(pool) == 0` after both claims. *(J4)*
- **A borrower's repay escrow and a liquidator's seizure escrow coexist** without either paying out of the
  other's collateral. *(J5)*
- **`writeOff` closes a zero-collateral position under the freeze** — `_tryReturnCollateral` returns true
  at `amount == 0` (`EsseyPool.sol:597`), so the deed is burned outright with no escrow, which is the
  R2 LOW-1 case. *(J6)*
- **The solvency invariant held at every step**: `scaledCollateral * collateralIndex / 1e18 <=
  balanceOf(pool)`, asserted after each escrow, each burn and each claim.

**The arming property is real, in both directions the prompt asked about.**

- *Arm-and-bypass in one transaction:* impossible. `syncMultiplier` runs above the gate on all five pool
  paths, so the transaction that first observes the dislocation is refused by it and the write rolls back
  (`DesyncBreaker.t.sol:55-66`, re-derived by `test_H1a`).
- *Denying arming:* impossible. `syncMultiplier` is `public`, non-reverting and permissionless
  (`:416-425`), so anyone can commit the arm standalone. There is no griefing vector that prevents it.
- *Keeping a market permanently armed:* impossible. The stamp is written once and a further gap does not
  extend it (`:361-363`), and re-arming requires the reference to be released first. **This is exactly the
  property that produces CRIT-1** — the mechanism that makes a permanent freeze impossible is the one that
  makes permanent disarming inevitable.
- *Forging agreement:* not reachable. Clearing requires `price * uiMultiplier` to come back within
  2,000bps of the reference. `price` is the Chainlink feed and `uiMultiplier` is the issuer's; no third
  party can move either, and the pool's own state contributes nothing to the comparison.

**A completed corporate action self-heals, in either leg order.** Multiplier-first: branch (b) stamps and
branch (c) arms with `ref = prev`; when the feed leg lands the product returns to `ref` and clears.
Feed-first: branch (c) arms; the multiplier leg clears it. Verified by reading `_syncPrice`/`_breaker`
and by `DesyncBreaker.t.sol:90-107`. The stale-reference bug (CRIT-1) is reachable only from an
*unresolved* single-leg move.

**The liveness rewrite is sound.** One predicate serves the view and the beat
(`LivenessOracle.sol:107, 126`), the grace granted is `min(gap, resumeGrace)` (`:109`), and amplification
is ≤ 2× for any parameter pair. `test_G3` measures a 901s gap costing under 4×`gapThreshold`, where R2
MED-1 measured 4,501s.

**`MarketHealthOracle` still has zero liquidation authority.** `effectiveCap` is read at
`EsseyMarkets.sol:205, 250` and `EsseyPool.sol:476` only — all borrow-side. Its `Params` carry no LTV or
threshold, so HIGH-1's derivation does not move under a health-oracle param change.

**Repo suite:** 864 tests, 23 suites, 0 failures at the frozen SHA.
**Round-2 harness re-run at the frozen SHA:** `B_Desync::test_B2` FAILS (the R2 HIGH-1 PoC is closed for
the single-event case), the other 15 pass.

---

## Harness

Written outside the repo so the frozen tree stayed untouched
(`…/scratchpad/r3root/test/{Base,H_StaleRef,J_Escrow,K_RolesAndGreens}.sol`, plus the round-2
`{B_Desync,C_Escrow,G_EngineerProof}` re-pointed at the frozen `src/`). Consolidated run: **31 tests,
7 suites, 30 passed / 1 failed** against `--fork-url https://rpc.mainnet.chain.robinhood.com`. The single
failure is round 2's own PoC, and its failure is the fix working. Every finding above is a test that
PASSES while asserting the broken behaviour.

The role PoC runs against a copy of `script/DeployMarkets.s.sol` that `diff` reports identical to the
frozen file apart from import depth.

## Audited bytes

sha256 at `0cf6831f62d01ba4074506e7066cc7a42a35322c`, tree clean:

| sha256 | file |
|---|---|
| `3b9ad62151e922dd2eec1c5c6831d4d2898e90c4e0dad3a1449c03bb2cebbeed` | `rh-chain/src/EsseyMarkets.sol` |
| `226b8395e2e5b90ba5d432ec6049ca82567fae8b28df6cb378fe8e1e5a810fa4` | `rh-chain/src/EsseyPool.sol` |
| `c2665ee3a2f22ea84c3f33cfc4b390a4df4aa9a5e530b9a7bbd90d22c6e336d8` | `rh-chain/src/LivenessOracle.sol` |
| `1738944dc76842be1c02dc7d2ee8c9a85014dfe8a49b3e8d46c42e35bb058f08` | `rh-chain/src/StaleFeedGuard.sol` |
| `bc1c9f060975d0bfa7164021238cc9c1bd0817fc034d9f15be658301be93b174` | `rh-chain/src/MarketHealthOracle.sol` |
| `9f6926a6c068bdc1ab8f3e6af1f5cc52dc949b8e8133c53abec66011735e8e93` | `rh-chain/src/CollateralReconciler.sol` |
| `c703b6de05d924909daf5e4529e6228cfbe23cf274ace8a3ff069eae04337a92` | `rh-chain/src/market/Note.sol` |
| `819de34810afdb9dbfde4fcd14129547ac7a2609273991cd3423a2648d75c4b1` | `rh-chain/src/interfaces/IScaledUI.sol` |
| `74a504e38e8b92cacd257039adffb805869f18ff780a198009e76d975703511d` | `rh-chain/src/adapters/ConstantMultiplier.sol` |
| `1d4583ace1e61dba56f31bd599458e9cb7347bb0ae81e00f4f18d94f654a6c0e` | `rh-chain/src/market/EsseyMultiply.sol` |
| `d7865ea0ea16b15f77abdd5c07e106ba1421ed711bd3feb8c6038534d1ae49fc` | `rh-chain/src/RobinhoodFeeds.sol` |
| `5ca059a6fb1addc1ccc33098b7891f8a266c19d96c1fda12cc4aa5f686d22404` | `rh-chain/src/testnet/ScaledUIStockMock.sol` |
| `fdc23a2e866dbc96388bfbf7f44986361017da6a1dfc2371ecb388abf77df33e` | `rh-chain/script/DeployMarkets.s.sol` |
| `c73ae583a738ee7a126e1627564f255a229add57018d590afeb542ce52f07a64` | `rh-chain/test/DesyncBreaker.t.sol` |
| `c33939c3f9efe00626f12eefbae73b9cce91d8a121c4d0eb4ee7032a6e762cd6` | `rh-chain/keeper/liveness-keeper.mjs` |
| `1bf24cccd11d2500151b8e47d64a07e95d63594723c0830c89182da3fccbaff5` | `docs/MAINNET-CONFIG.md` |
