# G-LEND gate — round 4 — Solidity / contract security lens

**Date:** 2026-09-04
**Frozen SHA:** `cb3e6aac4214b3674a421808f7909f365b6f5814` · `git status --porcelain` **empty** at the
start of the round. The only tree change made by this round is this file.
**Substrate:** Robinhood Chain **mainnet**, `https://rpc.mainnet.chain.robinhood.com`, chain-id
**4663**, fork blocks **54192361 → 54199986** (the RPC is not an archive node, so every run is at
latest and the block is logged from inside the EVM; a reproducer will get a later one).
**PoC harness:** `scratchpad/r4root/test/{A_Corroboration,B_PairSplit,C_KeeperGap,D_MultiState,E_Authority,F_GasBudget}.t.sol`
over a byte-identical copy of `rh-chain/src` (`diff -r` clean). 12 PoC tests, 12 green.
**Repo suite at the frozen SHA:** `forge test` — **1,749 passed, 2 failed, 0 skipped, 1,751 total, 82
suites.** The two failures are the pre-existing Don-layer fork failures and are confirmed unrelated to
lending (LOW-6). Every finding below is live while all 1,749 are green.

## VERDICT: NOT CLEAN — 2 HIGH, 3 MEDIUM, 6 LOW, 1 INFO.

Round 3's CRIT-1 is **genuinely closed**, and it survives the cases three rounds of single-event
tests could not reach: four events on one market alternating both exits, a guardian pause interleaved
with an armed hold, and two markets in one registry sitting in different breaker states at once
(`D_MultiState`, 3/3 green). MED-3's pause cooldown is real and its three statements now agree.
MED-2's `GUARDIAN != LIVENESS_GUARDIAN` rule is present and genuinely pinned.

The blind spot moved, as expected. It moved to the **replacement** for the bound: corroboration.
`PRICE_CONFIRM_DELAY` does not deliver a delay. It delivers *whatever is left of a promotion clock
that any permissionless caller can position in advance* — measured at **one second** on real AAPL,
for **2,592 bps of free profit against a healthy borrower**. That is R3 HIGH-1 restored at the same
magnitude R3 measured it (2,600 bps), in the exact case the fix was written for.

---

## What round 3 asked me to verify, checked at `cb3e6aa`

| R3 item | Status | Evidence |
|---|---|---|
| **CRIT-1** permanent disarm | **CLOSED, structurally** | `desyncRefProduct` / `priceDesyncAt` have exactly **two** write sites — `EsseyMarkets.sol:473-474` (arm) and `:481-482` (`_disarm`) — and both write the pair together. `grep -n "desyncRefProduct\[\|priceDesyncAt\[" src/EsseyMarkets.sol` returns nothing else. `D1` runs four events alternating agreement-exit and expiry-exit and asserts the pair consistent at every transition; `D2` interleaves a 12h guardian pause across an armed hold; `D3` holds AAPL and NVDA in different states simultaneously. All green. |
| **HIGH-1** the bound | **REOPENED — see R4 HIGH-1** | The diagnosis (no bound can work) is correct. The replacement does not hold: the delay is bypassable to ~1 block. |
| **MED-1** stale baseline fails OPEN | **NOT closed — see R4 HIGH-2** | The engineer's ruling was that corroboration backstops the fail-open. It does not, per HIGH-1. `C_KeeperGap` prices the residual: a 5,000 bps feed leg on an unobserved market arms nothing and is harvested for **10,988 bps** one hour later. |
| **MED-2** `GUARDIAN == LIVENESS_GUARDIAN` | **CLOSED as written; the wrong thing was fixed — see R4 MED-2** | `DeployMarkets.s.sol:184-187` refuses the pair and `test_theGuardianMayNotBeTheLivenessGuardianEither` pins it (it is the sole revert source for that payload). But `LIVENESS_GUARDIAN` **alone** already is "halt everything, indefinitely", and unlike the pair it is unrecoverable. |
| **MED-3** chained pauses | **CLOSED** | `EsseyMarkets.sol:709-720`; cooldown `until + (until - now)`, only writer of both mappings, stand-down never shortens it. Duty cycle ≤ 50%, contiguous open window ≥ the pause before it. The three statements at `:114-118`, `:334-338`, `:703-708` now agree with the code and with `docs/MAINNET-CONFIG.md:81-82` and `docs/MAINNET-ACTIVATION.md:1593`. |
| **LOW-1** `test_C7` deleted | **CLOSED** | Absent from the suite. |

---

# HIGH-1 — `PRICE_CONFIRM_DELAY` is not a delay: it is the remainder of a clock the observer positions

**CONFIRMED.** `src/EsseyMarkets.sol:445-451` (`_corroborate`), `:274-280` (`corroboratedValue`),
`:249-257` (`isUnderwaterCorroborated`), consumed at `src/EsseyPool.sol:726` and `:799`.
PoC: `A_Corroboration::test_A1b_theCorroborationDelayCollapsesToOneSecond`, control `test_A1a`.

## The claim under test

`EsseyMarkets.sol:367-369`:

> Promoted from an EARLIER observation, never the current one, and at most once per
> PRICE_CONFIRM_DELAY — together, **a step change cannot reach it until a full delay after the
> observation that first saw it**, which is the property `isUnderwaterCorroborated` rests on.

That conjunction does not give the property. The rate limit is on `confirmedAt` — **the time of the
last promotion** — not on the age of the observation being promoted:

```solidity
// EsseyMarkets.sol:445-451
function _corroborate(address token, uint256 prevPrice, uint256 prevMult) internal {
    uint256 at = confirmedAt[token];
    if (at != 0 && block.timestamp - at < PRICE_CONFIRM_DELAY) return;
    confirmedPrice[token] = prevPrice;
    confirmedMultiplier[token] = prevMult;
    confirmedAt[token] = block.timestamp;
}
```

So a price becomes corroborated at the **first observation on or after `confirmedAt +
PRICE_CONFIRM_DELAY`**, regardless of when it was first seen. If the observation that records a step
change lands *inside* the current interval, it does not promote — and the very next observation, one
second later at the interval boundary, promotes it. The delivered delay is
`confirmedAt + PRICE_CONFIRM_DELAY − t_move`, anywhere in `[~1 block, 1 hour]`.

`syncMultiplier` is permissionless and non-reverting (`:536`), so the promotion clock is set by
whoever calls it. An ex-date and the opening print are public months ahead.

## PoC — real AAPL, real feed, real USDG, deployed risk params 5000 / 7500 / 500

`test_A1b`. A position opened at 90% of max LTV and seasoned in three −1,500 bps steps (each inside
`MAX_PRICE_DEVIATION_BPS`, so nothing arms) — an ordinary loan that has moved against its borrower.
Then the feed leg of a **6:5 split, −1,667 bps**, which is under the desync bound and is the exact
case R3 HIGH-1 named.

```
1. anchor the promotion clock          syncMultiplier at t0        confirmedAt == t0
2. wait out the interval but one second                            t = t0 + 3599
3. THE FEED LEG LANDS. one observation records it
       priceDesyncAt          == 0          sub-bound: nothing arms
       confirmedPrice         == seasoned   NOT yet corroborated
       isUnderwaterCorroborated == false    the gate is shut
4. ONE SECOND LATER: liquidate(). Its own syncMultiplier (EsseyPool.sol:707) promotes the
   split price inside the transaction that seizes on it.
       debt repaid by the liquidator (USDG)  1 472 665 373    $1,472.67
       true value of seized units    (USDG)  1 854 508 577    $1,854.51
       free profit                   (USDG)    381 843 204      $381.84
       profit as bps of the debt                     2 592    25.9% of the debt
       elapsed since the feed leg landed                 1    ONE SECOND
```

The control, `test_A1a`, is the repo's own arrangement — clock reset at the instant the leg lands —
and it correctly reverts `PriceNotCorroborated`. **The only difference between the two tests is where
in the interval the move falls.**

`test_A2` runs the same attack with the deployed keeper observing every 300 s throughout — the
configuration MED-1 was closed on. The keeper's own observations drive the promotion clock, so the
delivered delay is one keeper beat: **300 seconds, not 3,600.** No attacker cooperation at all.

## Why the suite is green

Every corroboration test in `DesyncStateMachine.t.sol` ends its setup with `_walkPriceAndSettle` /
`_corroborate` (`test/EsseyPool.t.sol:175-186`), which advances `PRICE_CONFIRM_DELAY + 1` **and then
observes** — resetting `confirmedAt` to the present. The move is then applied in the same block. Every
test therefore samples the one phase of the interval in which the gate is at full strength:

- `test_aSubBoundMoveCannotSeizeThePositionItJustFlipped:315` — full interval remaining.
- `test_corroborationCannotBeRushedByPackingObservations:378` — ten observations **in one block**; the
  rate limit is wall-clock, so this can never fail and says nothing about an attack that spends time.
- `test_thePromotedPriceIsNeverTheOneBeingObserved:394` — pins "not this one", stops before the next
  promotion, and so never asks "not for an hour".
- `test_theCorroborationDelayBoundaryIsExact:293` — **this test performs the bypass and blesses it.**
  It moves the price at `DELAY − 1`, observes (no promotion), advances one second, observes, and
  asserts `confirmedPrice == 190e8` with the message *"and on the second itself it promotes"*.

The suite pins the promotion **rule**. Nothing pins the security **property** the rule exists to
deliver.

## Independent corroboration, from the opposite direction: the delay's magnitude is not pinned at all

A mutation sweep of the new code (isolated copy, `src`/`test` `diff -rq` clean against the repo
afterwards) killed five of six mutants. **M6 survives.** Changing `EsseyMarkets.sol:346` from
`PRICE_CONFIRM_DELAY = MULTIPLIER_GUARD_WINDOW` (1 hour) to `1 seconds` gives, across the whole
1,751-test suite:

```
Ran 82 test suites: 1748 tests passed, 3 failed
  x2  ERC721InvalidReceiver ...   the two pre-existing Don-layer fork failures
  x1  test_close_afterLiquidationOfOneRung   "seed consumed by the cascade: 14674999939 != 14674999938"
```

The single kill is a **one-wei interest-accrual artifact** — `_corroborate()` warps
`PRICE_CONFIRM_DELAY + 1`, so a shorter delay accrues one unit less interest. It says nothing about
corroboration. `grep` confirms there is no `assertEq` anywhere in `test/` on `PRICE_CONFIRM_DELAY`,
`MAX_BASELINE_AGE`, or `MULTIPLIER_GUARD_WINDOW`; every corroboration test either reads the constant
back from the contract (`DesyncStateMachine.t.sol:298`) or attempts the seizure in the same block as
the move, where `0 < 1` holds exactly as `0 < 3600` does.

A probe under M6 — healthy seasoned position, the same sub-bound −1,000 bps leg, two observations
**two seconds apart**, then liquidate — **passes**, and reverts `PriceNotCorroborated` on the
unmutated tree. So the suite cannot tell a one-hour delay from a one-second one.

Killed, for the record: M1 (delete the rate limit) ×3, M2 (promote the current observation) ×1,
M3 (`baselineAge > 10 × MAX_BASELINE_AGE`) ×3, M4 (delete `_disarm` on hold expiry) ×4, M5 (delete
the `PauseOnCooldown` check) ×2. The mechanism is well pinned; **the magnitude is not pinned at
all** — which is the same defect this finding describes, reached by mutation instead of by timing.

## And the gate rests on one file

Hardwiring `isUnderwaterCorroborated` to `return true` fails **3** of the 726 lending tests
(`DesyncStateMachine.t.sol:315`, `:378`, `:409`). Hardwiring `isInsolventCorroborated` fails **2**
(`:409`, `:425`). **Every test that asserts a liquidation succeeds still passes with the gate
disabled.** That is expected of happy-path tests, but it means the entire R3 HIGH-1 defence is pinned
by one file: delete `DesyncStateMachine.t.sol` and 723/726 stay green with no corroboration at all.

## Fix

Gate on the age of the promoted observation, not on the promotion clock. The value needed is already
in storage one line earlier — `seenPriceAt` before it is overwritten (`:434-436`):

```solidity
mapping(address => uint256) public confirmedObservedAt;   // when the promoted observation was TAKEN

// in _syncPrice, pass the pre-overwrite seenPriceAt into _corroborate and store it.
// in corroboratedValue:
if (price == 0) return (0, false);
if (block.timestamp - confirmedObservedAt[token] < PRICE_CONFIRM_DELAY) return (0, false);
```

Then the guarantee is the one `:367-369` already claims: *the price this seizure rests on was
observed at least `PRICE_CONFIRM_DELAY` ago.* Keep the promotion rate limit as well — it is what stops
a fresh observation walking the confirmed pair forward inside a block — but it must not be the thing
the security property rests on.

**The test that must exist:** the move lands at every offset in the interval, not just at zero. A
parameterised test over `offset ∈ {1s, 300s, 1800s, 3599s}` from the last promotion, each asserting
`liquidate` reverts `PriceNotCorroborated`. Against the current tree, three of the four fail.

---

# HIGH-2 — the corporate-action breaker is load-bearing on an unsupervised off-chain keeper, an unvalidated env var, and fails OPEN — and the shipped run command does not enable it

**CONFIRMED.** `src/EsseyMarkets.sol:469`, `keeper/liveness-keeper.mjs:53-56,94-109`,
`rh-chain/README.md:85`, `rh-chain/RUNBOOK.md:59-61`.
PoC: `C_KeeperGap::test_C1_theUnobservedMarketNeverArmsOnASplitLeg`, control `test_C1_control_theObservedMarketArms`.

```solidity
// EsseyMarkets.sol:469 — R3 MED-1's fix
if (baselineAge > MAX_BASELINE_AGE) return;      // declines to arm, before the deviation test
```

The only thing that keeps a baseline inside `MAX_BASELINE_AGE = 1 hour` on a quiet market is the
keeper observing it. Three independent ways that stops being true, none of which raises an alarm:

1. **`MARKET_TOKENS` is a hand-typed comma-separated env var** (`liveness-keeper.mjs:54`). Nothing
   discovers markets from `MarketCommitted` logs, nothing cross-checks against
   `DeployMarkets._marketList` (`script/DeployMarkets.s.sol:200-205`, AAPL + NVDA), and a list
   holding *one* of two markets produces **no warning at all** — `:55` fires only when the list is
   empty, and the banner at `:117` prints a count nobody reads.
2. **Neither documented run command sets it.** `rh-chain/README.md:85` and `rh-chain/RUNBOOK.md:59-61`
   both show `RH_RPC` / `KEEPER_PRIVKEY` / `LIVENESS_ORACLE` only. **Following the runbook as written
   produces this state on every market**, announced by one `console.warn` at `:56`.
3. **`observe()` failures are logged and never escalated** (`:105-107`). `beat()` has a
   `consecutiveFailures` counter and an ALERT at two (`:86-88`); `observe()` has neither.

`grep -rn "liveness-keeper" --include=Dockerfile --include='*.service' --include='ecosystem.config*'`
over the repo returns nothing; there is no supervisor unit, no container, no CI, and no test for
`liveness-keeper.mjs`. Supervision exists only as prose at `:20-22`.

## PoC — the price of one quiet hour

`test_C1_theUnobservedMarketNeverArmsOnASplitLeg`. Identical to the control except that nobody
observed for the preceding hour. The keeper still beats, so liveness is fine.

```
feed leg of a 2:1 split: -5,000bps, two and a half times MAX_PRICE_DEVIATION_BPS
       priceDesyncAt   == 0        C-1: it does NOT arm - discarded as drift at line 469
       canLiquidate    == true     immediately, at the wrong price

one PRICE_CONFIRM_DELAY later (the only protection left):
       hours from the feed leg to the seizure          1
       debt repaid (USDG)                    1 472 665 375     $1,472.67
       true value seized (USDG)              3 090 847 627     $3,090.85
       free profit (USDG)                    1 618 182 252     $1,618.18
       profit as bps of the debt                    10 988     110% of the debt
```

The control confirms the same leg on an observed market arms the breaker and reverts
`LiquidationNotAllowed` for six hours. **The entire difference between a 6-hour refusal and a 1-hour
speed bump is whether an unsupervised Node process happened to have that token in an env var** — and
with HIGH-1, that 1 hour is itself as little as one block.

## Ruling on MED-1, as asked

**MAX_BASELINE_AGE and corroboration do NOT close it together.** The engineer's argument is sound in
shape — a stale baseline really does measure drift, and declining to arm really is the right call for
a sparse market — but it rests entirely on corroboration being a genuine `PRICE_CONFIRM_DELAY`
backstop. HIGH-1 shows it is not. Fix HIGH-1 and this becomes a defensible accepted trade-off with a
1-hour worst case; leave HIGH-1 and MED-1's fail-open has no floor.

## Structural mitigation, verified — and why it bounds the two findings apart

`confirmedAt ≤ seenPriceAt` always: `_corroborate` (`:450`) can only write `confirmedAt =
block.timestamp` from inside `_syncPrice`, which has already written `seenPriceAt = block.timestamp`
at `:436`. Therefore `now − confirmedAt ≥ baselineAge`, and **an attacker cannot simultaneously hold
a stale baseline (to suppress arming) and a fresh promotion clock (to rush corroboration)**. So:

- single-leg move **≥ 2,000 bps** — either the breaker arms (6 h) or corroboration costs a full hour.
- single-leg move **< 2,000 bps** — the breaker is irrelevant by design, and HIGH-1 reduces
  corroboration to ~1 block.

That is a real property and it is worth keeping. It is also exactly why HIGH-1 matters: the sub-bound
band is the band `PRICE_CONFIRM_DELAY` was introduced to cover ("at every magnitude",
`EsseyMarkets.sol:341-342`).

## Fix

- Make the keeper derive its market list from the registry rather than an env var, and refuse to
  start if a market it can see has no observation duty.
- Give `observe()` the same `consecutiveFailures` counter and ALERT that `beat()` has.
- Correct `rh-chain/README.md:85` and `rh-chain/RUNBOOK.md:59-61` to include `ESSEY_MARKETS` and
  `MARKET_TOKENS`. This is the highest-value single line in the fix: the runbook currently
  *instructs* the operator into the vulnerable state.
- Ship the supervisor unit. It has been "before mainnet" in `docs/OUTSTANDING.md:97-99` for three
  rounds and is now load-bearing for a seizure path, not just for uptime.

---

# MED-1 — an unreadable price splits the observation pair, and the split pair is what corroboration is built from

**CONFIRMED.** `src/EsseyMarkets.sol:429-440` (`_syncPrice` returns at `:431` without writing
`seenPrice`) versus `:536-545` (`syncMultiplier` writes `seenMultiplier` at `:544` unconditionally).
PoC: `B_PairSplit::test_B1_anUnreadablePriceSplitsTheObservationPair`, `test_B2`.

```solidity
// syncMultiplier:539-544
uint256 cur = _liveMultiplier(source);
if (cur == 0) return;
...
_syncPrice(token, prev, cur);     // returns early at :431 when the price is unreadable
seenMultiplier[token] = cur;      // written anyway
```

An "observation" is a `(price, multiplier)` pair, and the two halves are meant to be taken together —
`_corroborate` promotes `(prevPrice, prevMult)` as one, and `_breaker` multiplies them into the
baseline product. When the price is unreadable and the multiplier moves, only the multiplier half
advances. The next successful observation then treats **an old price and a new multiplier as one
matched pair**.

**The precondition is not exotic.** Measured on the real AAPL feed (0x6B22…2cD0), 500 consecutive
rounds spanning 2026-06-25 → 2026-09-04: **ten gaps exceed 24 hours and the longest is 79.74 hours**
(the July 4th weekend), every one of them a Friday→Monday closure. Against
`maxStaleness = 90,000 s = 25 h`, the feed is **unreadable for roughly 55 hours every single
weekend** — and that is precisely when an issuer applies a corporate action for a Monday ex-date.

## PoC

`test_B1` — a 1:2 reverse split whose multiplier leg lands while the feed is stale:

```
seenMultiplier  == m0/2      the multiplier half of the observation moved
seenPrice       == p         the price half did NOT: the pair is split

Monday, split-adjusted, product unchanged, guard window served out:
confirmedPrice      == p        Friday's price
confirmedMultiplier == m0/2     with Monday's multiplier
live collateral value (USDG)          3 272 551 909
corroborated collateral value (USDG)  1 636 275 954     EXACTLY HALF
isUnderwater             == false     healthy on every real price
isUnderwaterCorroborated == true      the R3 HIGH-1 gate is satisfied VACUOUSLY
```

The seizure is still stopped here — by the **live** read (`EsseyPool.sol:721`), which is correct. The
harm is that the second, independent bar has been reduced to a no-op for that market for a full
`PRICE_CONFIRM_DELAY`. During that hour, any live under-read — a feed wick, a bad round, the feed leg
of a *second* action — is seizable with **no corroboration delay whatsoever**, because the gate is
already open. That is the exact condition HIGH-1 exploits by timing, reached here without timing.

`test_B2` is the other direction: a 2:1 forward split over the same window over-values the
corroborated pair, and a genuinely insolvent position cannot be liquidated **or** written off
(`_writeOffFloor`, `EsseyPool.sol:799`) until the next promotion. Loss recognition is blocked while
interest compounds.

**Fix.** Make the pair atomic. Either move `seenMultiplier[token] = cur` inside `_syncPrice`, on the
same path that writes `seenPrice`, or have `_syncPrice` return a success flag and only write
`seenMultiplier` when it is true. A partial observation must record nothing, exactly as a failed
multiplier read already does (`:540`).

---

# MED-2 — `LIVENESS_GUARDIAN` alone is a permanent, unrecoverable kill switch for liquidation *and* borrowing

**CONFIRMED.** `src/LivenessOracle.sol:139-144`, `:53`, `src/EsseyMarkets.sol:127`, `:298`, `:558`.
PoC: `E_Authority::test_E1_theLivenessGuardianAloneIsAPermanentKillSwitch`.

R3 MED-2 was closed by forbidding `GUARDIAN == LIVENESS_GUARDIAN`, on the reasoning at
`DeployMarkets.s.sol:172-175` that *their union* is "halt everything, indefinitely". **One key
already is** — and unlike the union, there is no way back.

```
setKeeper(deadKeeper) as LIVENESS_GUARDIAN     one tx, immediate, un-timelocked, no notice
warp(gapThreshold + 1)
  liquidationsAllowed()   == false
  canLiquidate(AAPL)      == false
  canBorrow(AAPL)         == false             EsseyMarkets.sol:298 gates borrows on it too
warp(+365 days)
  canLiquidate(AAPL)      == false             still off a year later
liveness.guardian()       == guardian          immutable: no rotation exists
markets.liveness()        == liveness          immutable binding: no migration
```

Interest compounds on every open position throughout, and the only recovery is redeploying the whole
registry and every pool and migrating every position. R1 tabled this in its blast-radius table
(`docs/audits/glend-round-1.md:652`, powers `setKeeper`, timelock **none**, "Reaches the same state
actively") but never gave it a severity or an acceptance rationale, and R3's fix addressed only the
pair. Under the standing gate, silently passing it a fourth time is not available.

Two further pairs are still accepted with no comment (`_checkRoles` refuses seven of ten pairs):
`LIVENESS_GUARDIAN == DEPTH_KEEPER` (permanent unrecoverable freeze of both sides) and
`LIVENESS_KEEPER == DEPTH_KEEPER` (same, but recoverable). `GUARDIAN == DEPTH_KEEPER` is deliberately
allowed and is genuinely safe on this axis.

**Fix — pick one, and write down which:**
(a) a timelocked `proposeLiveness` / `commitLiveness` on `EsseyMarkets` with the same 2-day notice as
every other risk parameter, so a compromised liveness guardian can be routed around in 2 days and
nothing is atomic; or
(b) a cold rotation path for `LivenessOracle.guardian` itself; or
(c) accept it explicitly, in the contract's own doc block, naming it as the one un-timelocked
unrecoverable key in the system — which is a defensible answer, but it must be *written*, because the
deploy script's stated reasoning currently implies the opposite.

Note that (a) has its own cost: a mutable liveness binding lets a compromised admin install a
permissive oracle and re-enable liquidation during a real outage, 2 days after announcing it. That is
the trade-off the founder should rule on, not me.

---

# MED-3 — the deploy key holds the guardian's immediate levers, contradicting both the contract's doc block and the deploy script's own separation rule

**CONFIRMED.** `src/EsseyMarkets.sol:690`, `:710`, `script/DeployMarkets.s.sol:271,273`, `:121-126`.
PoC: `E_Authority::test_E2_theDeployKeyAlreadyHoldsTheGuardiansLevers`.

`_roleKey` (`:121-126`) refuses any of the five named roles being the deploy key. But
`EsseyMarkets.admin` and `MarketHealthOracle.admin` **are** the deploy key (`:271`, `:273`), and
`admin` natively holds both of the guardian's un-timelocked levers:

```solidity
function disableMarket(address token) external {
    if (msg.sender != admin && msg.sender != guardian) revert NotAdmin();     // :690
function pauseLiquidation(address token, uint256 until) external {
    if (msg.sender != admin && msg.sender != guardian) revert NotAdmin();     // :710
```

`EsseyMarkets.sol:114-118` describes `pauseLiquidation` as the guardian's "hot emergency key" and
never mentions that admin has it. `test_E2` runs both from `admin` on the fork and both succeed. So
the separation `_checkRoles` enforces is narrower than it reads: the deploy key already has the
emergency key's powers, and it cannot be rotated (`admin` is `immutable` with no setter — grep over
`src/` returns only the constructor assignment).

Verified as safe: the pause cooldown is per token and shared, so admin and guardian **cannot** double
the duty cycle — the second pause reverts `PauseOnCooldown`.

Related, and worth the founder's attention: `docs/MAINNET-CONFIG.md:92` says *"Assign all
admin/treasury/seeder/bankroll roles to the multisig; verify no EOA retains control."* For these two
contracts that is impossible post-deploy — `admin` is immutable, so the **multisig must be the
broadcaster**. And if it is, `_roleKey:124` then forbids the multisig from also being `GUARDIAN`, so
the emergency key must be a separate non-multisig address. That consequence is not written anywhere.

**Fix.** Either drop `admin` from `:690`/`:710` (the guardian is the emergency key; admin has the
timelocked pipeline) or correct `:114-118` to say both keys hold them. The first is better: it makes
`_checkRoles`'s separation mean what it says.

---

# LOW-1 — the observation read is capped at 50,000 gas; the valuation read of the same function is not

**CONFIRMED.** `src/EsseyMarkets.sol:527` (`staticcall{gas: 50_000}`) versus `:199`
(`IScaledUI(multiplierSource[token]).uiMultiplier()`, uncapped).
Measured: `F_GasBudget::test_F1` — `uiMultiplier()` on the deployed AAPL token costs **15,719 gas**
against a 50,000 budget, **3.18× headroom**.

The Stock Token is upgradeable through a beacon (an issuer power, R1 CRIT-1's second scenario). If a
future implementation pushes past 50,000, `_liveMultiplier` returns 0, `syncMultiplier` returns at
`:540` and records **nothing at all** — no `seenPrice`, no `seenPriceAt`, no corroboration, no
breaker — while `collateralValue` keeps working uncapped and every borrow and liquidation continues.
The breaker and corroboration die silently, with no on-chain signal, and the market falls into
exactly the HIGH-2 state. 3.18× is thin margin on a contract the protocol does not control.

**Fix.** Use the same budget on both paths, or raise the observation cap and cross-check the two reads
agree. The cap exists to stop a griefing token bricking five entry points; that goal is met at
200,000 as well as at 50,000.

# LOW-2 — the shipped UI understates the corporate-action closure by 6× and cannot name the real one

**CONFIRMED.** `app/web/src/lending.ts:470-475`; `grep -rn "priceDesyncAt\|confirmedPrice\|isUnderwaterCorroborated" app/web/` returns **zero hits**.

The borrow-block explainer reads only `multiplierMovedAt` against `MULTIPLIER_GUARD_WINDOW` — branch
(b) of `_desyncGuard`. Branch (c), the price-desync breaker, holds for `PRICE_DESYNC_HOLD = 6 hours`
(`EsseyMarkets.sol:333`, `:400-401`) and is never read, so an armed breaker falls through to
`"closed"`, `"feed-unreadable"`, or the `"unknown"` fallback at `:496-499`. The one corporate-action
message a user can see says *"Borrowing is closed for an hour"* when the code allows six.

# LOW-3 — the keeper's tick can overlap itself, and the collision takes the heartbeat down with it

**CONFIRMED by construction.** `keeper/liveness-keeper.mjs:111-119`.

`tick()` awaits `beat()` (one receipt, 60 s timeout) then `observe()` (N receipts, 60 s each,
sequential). Worst case `60 × (N + 1)` seconds. `setInterval(tick, INTERVAL)` at `:119` does not await,
so at `INTERVAL = 300 s` any `N ≥ 4` lets ticks overlap — and both functions send from the same
account, so viem resolves the same pending nonce twice and one transaction is replaced or dropped.
The heartbeat is in that race. **A slow RPC on one market's observation can therefore disable
liquidation protocol-wide**, which is the safe direction but is a self-inflicted outage during which
bad debt accrues.

Two markets ship today (`DeployMarkets.s.sol:200-205`), worst case 180 s < 300 s, so it is not live —
it is a scaling landmine that trips at the third or fourth listing. **Fix:** self-scheduling
`setTimeout` after the tick completes rather than `setInterval`, and an explicit nonce manager.

# LOW-4 — three shipped statements about the keeper and the liveness oracle no longer match the code

**CONFIRMED**, each read at the cited line:

- `docs/OUTSTANDING.md:97-99` and `rh-chain/README.md:89-90`: *"A silently dead keeper degrades to
  'liquidations off' — safe, but an outage."* Since `cb3e6aa` the same keeper is the only standalone
  caller of `syncMultiplier`, so a dead keeper is fail-**open** on the seizure path (HIGH-2). Neither
  file mentions the keeper's new observation duty at all.
- `docs/OUTSTANDING.md:90` cites *"constructor guard `resumeGrace ≤ 4× gapThreshold`"*. No such guard
  exists; `LivenessOracle.sol:64-69` replaced it with absolute ceilings, and
  `DeployMarkets.s.sol:267-268` records the removal. The correction reached the script and
  `MAINNET-CONFIG.md` but not the file the site renders (`app/web/gen-docs.mjs:44`).
- `keeper/liveness-keeper.mjs:13-15` credits `MAX_BASELINE_AGE` with making an observation outage
  "safe". `MAX_BASELINE_AGE` only prevents false-positive arming on drift; what tolerates an
  observation outage on the seizure side is corroboration — which per HIGH-1 does not hold either.

# LOW-5 — the seasoning idiom the whole corroboration test set is built on silently switches the breaker off

**CONFIRMED** by instrumenting `_breaker` in an isolated copy with a probe on each of its two exits.

`PRICE_CONFIRM_DELAY == MAX_BASELINE_AGE == 1 hours`, and the shared helper `_corroborate()`
(`test/EsseyPool.t.sol:175-178`) does `_advanceLive(PRICE_CONFIRM_DELAY + 1)` then one
`syncMultiplier`. `_advanceLive` (`:102-108`) re-stamps the feed and beats liveness but **never
observes the registry**, so `seenPriceAt` does not move and the observation lands at
`baselineAge = 3601` — one second past the gate at `EsseyMarkets.sol:469`. **140 of the 726 lending
tests take that early return**, and on every `_corroborate()` step the deviation check is skipped
entirely.

Nothing asserted today is wrong because of it — deleting the age gate outright fails exactly the three
tests written to pin it (`DesyncStateMachine.t.sol:171`, `:250`, `:284`) and nothing else, which
proves the other "did not arm" assertions stand on the deviation logic independently. One message
over-claims: `DesyncStateMachine.t.sol:319` says *"no step of the seasoning armed anything"*, but the
final seasoning step was never deviation-checked. Harmless there (the steps are sub-bound), wrong as
written.

It is a trap, and it is the same trap this whole round is about: **the idiom every corroboration test
uses to set up its scenario is the idiom that turns the breaker off.** Any future test that folds a
>2,000 bps move into `_walkPriceAndSettle` will silently not arm, and will look correct.

**Fix.** Make `_advanceLive` observe (`mk.syncMultiplier(...)`) on its keeper cadence, exactly as
`keeper/liveness-keeper.mjs:113` does. The fixture should model the deployed keeper, not a keeper that
beats but never looks.

# LOW-6 — the two Don-layer fork failures are unrelated to lending, and the reason they fail is worth its own fix

**CONFIRMED unrelated, as asked.** Baseline `forge test` at `cb3e6aa`: **1,749 passed, 2 failed, 0
skipped, 1,751 total, 82 suites.** Both failures are `ERC721InvalidReceiver(0xaE0b…1946)` in `setUp()`:
`test/DonSolvencyStress.t.sol:372` → `:171` and `test/DonMainnetFork.t.sol:102` → `:186`, both through
`src/market/DonDistributor.sol:359` → `src/market/Don.sol:122` (`_safeMint`). Neither file imports
`EsseyMarkets`, `EsseyPool`, `LivenessOracle` or `MarketHealthOracle`, and `-vvvvv` traces of both
mention none of them (`grep -icE` → 0).

The root cause is not a code regression. `makeAddr("deployer")` resolves to
`0xaE0bDc4eEAC5E950B67C6819B118761CaAF61946`, and on live mainnet that address now carries an
**EIP-7702 delegation designator**:

```
$ cast code 0xaE0bDc4eEAC5E950B67C6819B118761CaAF61946 --rpc-url https://rpc.mainnet.chain.robinhood.com
0xef01008a5b10eb2faf57665f63709ec4b3943a3b005df6
```

So it has code, `_safeMint`'s receiver check calls into it, and the call reverts. Both suites fork at
**latest**, so they will fail on every machine until the fixture stops using that address.

Flagged because the consequence is general: **any fork test that mints or transfers to a
`makeAddr(...)` vanity address at latest is hostage to whatever a stranger deploys or delegates
there** — cheaply, deliberately, by anyone. It is a test-integrity and reproducibility problem, not a
protocol vulnerability. **Fix:** use addresses derived from the test's own deployment, or pin a block.

# INFO-1 — public-repo hygiene

The repo is public (`gh repo view` → `"visibility":"PUBLIC"`). No secrets, no private keys, no
private absolute paths in anything the last three commits touched. Four items are leakage of a
different kind:

- `docs/MAINNET-ACTIVATION.md:6, 44, 152, 821, 973` carry `[[wikilink]]`s into the private memory
  corpus; each name discloses the memo's subject, and `:821` quotes its text verbatim.
- `script/DeployMarkets.s.sol:22` and `test/RateModes.t.sol:164,170` name a competitor and its
  incident in shipped contract source — including inside an assertion string, which surfaces in CI
  output. The founder's no-competitor-names rule is scoped only to the site
  (`app/web/gen-docs.mjs:58-60`).
- `docs/MAINNET-ACTIVATION.md:36` and `:318` name a separate private business relationship and an
  unannounced partner list with its exact size.

---

# The risk parameter the engineer would not set: `PRICE_CONFIRM_DELAY`

Asked for, and nobody has produced it. **Measured, not estimated** — the numbers below come from 500
consecutive rounds of the deployed AAPL feed `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0`, walked with
`getRoundData` on chain-id 4663, spanning **2026-06-25 15:45:54 → 2026-09-04 06:44:55 UTC (70.62
days)**.

## The buffer the delay spends, at the deployed params

`DeployMarkets.s.sol:378-383` — `ltvBps 5000`, `liqThresholdBps 7500`, `liqBonusBps 500`,
`cap 250,000 USDG`, `maxPositionBps 2,000` (so a 50,000 USDG maximum position).

- A position becomes liquidatable at `V = debt / 0.75 = 1.3333 × debt`.
- **Bad debt** (`V < debt`) needs a *further* fall of **25.00%**.
- **Liquidator indifference** (`V < 1.05 × debt`, the bonus stops being payable) needs a further fall
  of **21.25%**. That is the number the delay is spending.

The delay only ever applies to a position the latest move just flipped — one already underwater at the
corroborated price is seized in the same block
(`DesyncStateMachine.t.sol:349`, and `isUnderwaterCorroborated` by construction).

## What the feed actually does

| measure | value |
|---|---|
| median gap between rounds | 2,251 s (37.5 min) |
| per-round σ of log returns | 0.5713% |
| per-hour σ (× √(3600/2251)) | **0.722%** |
| worst 1-hour move in 70.6 days | **6.80%** |
| worst 6-hour move | **8.47%** |
| rolling 1h windows > 5% | 8 / 499 (1.60%) |
| rolling 1h windows > 10% | **0 / 499** |
| rolling 1h windows > 21.25% | **0 / 499** |

The 21.25% buffer is **3.13× the worst hour this feed has ever printed** and **29.4 × the estimated
hourly σ**. And the loss *given* the tail event is not the position: at a 25% overshoot the loss is
zero, at 30% it is 6.7% of the debt, at 40% it is 20%.

## The answer

**1. Fix the mechanism before setting the value.** Any `D` is meaningless while the delivered delay is
`D − (time since the last promotion)`. This is the whole of HIGH-1 and it dominates the parameter
question.

**2. With the mechanism fixed, `D = 6 hours`, equal to `PRICE_DESYNC_HOLD`.**
Measured bad-debt cost of `D ≤ 6 h` on this feed over 70.6 days: **zero** — the worst 6-hour move
(8.47%) is not half the buffer (21.25%). A pessimistic upper bound on the unobserved tail (rule of
three on 0/499 → ≤0.6% per window) times a few percent loss given the event times a 50,000 USDG
maximum position is **tens of dollars of expected bad debt per at-risk position per event**. Against
that: HIGH-1's demonstrated wrongful seizure is **$381.84 on a $1,472.67 position (25.9%)**, and
HIGH-2's is **$1,618.18 on the same position (110%)** — losses that land on a borrower who did nothing
wrong and are unrecoverable, where bad debt lands on lenders and is absorbed by `totalReserves` first
(`EsseyPool.writeOff`).
The binding constraint is not AAPL volatility. It is **how late an issuer's second leg can land** —
which is the reason `PRICE_DESYNC_HOLD` is already 6 hours (`EsseyMarkets.sol:329-333`). Setting
`PRICE_CONFIRM_DELAY` to the same 6 hours makes the sub-bound and above-bound cases receive the same
protection and makes the "at every magnitude" claim at `:341-342` true. It also collapses two
constants into one number the operator has to reason about instead of three.

**3. If 6 hours feels long, `D = 2 hours` costs nothing measurable** and still covers a same-session
leg gap. `D = 1 hour` (the current value) is the floor, not a considered choice — it is
`MULTIPLIER_GUARD_WINDOW` reused.

**4. Measure NVDA before fixing the constant.** `PRICE_CONFIRM_DELAY` is a shared, non-upgradeable
constant across every listed market, and I measured AAPL only. NVDA is listed
(`DeployMarkets.s.sol:203`, feed `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15`) and is materially more
volatile. The same 500-round measurement should be run on it, and the constant set against the worst
listed name — or made per-market in the timelocked `Market` struct.

**One caveat, stated plainly.** 70.6 days containing one stress episode (2026-07-30, −8.5% over 90
minutes) cannot *bound* a 21.25% tail; it can only say that nothing came within a third of it. The
sample also contains no gap-open, because this feed does not print overnight — but overnight is
already unliquidatable-into by construction (24/5 feed, 25 h staleness bound), and the same 20pp
`MIN_RISK_GAP_BPS` absorbs it. The honest statement is *"21.25% was never approached"*, not *"21.25%
is impossible"*.

---

# What this round did NOT find — stated plainly

- **CRIT-1 is closed.** Two write sites, both atomic on the pair. Four events, interleaved pauses, and
  two markets in different states all hold (`D_MultiState`, 3/3).
- **MED-3 is closed** and its three statements agree with each other, with the code, and with
  `MAINNET-CONFIG.md` and `MAINNET-ACTIVATION.md`. The repo's own tests pin it genuinely.
- **MED-2's stated rule is present and pinned** — `test_theGuardianMayNotBeTheLivenessGuardianEither`
  is the sole revert source for its payload, so deleting `DeployMarkets.s.sol:184-187` fails it.
- **`test_C7` is gone.**
- **No custody or value-flow defect** was found in the corroboration change: `liquidate` and
  `writeOff` require the live read *and* the corroborated one (`EsseyPool.sol:721,726` and `:796,799`),
  so every finding above that mis-values the corroborated pair blocks rather than seizes — except
  where the live read is independently wrong, which is HIGH-1 and HIGH-2.
- **No cross-market coupling in the breaker.** `EsseyPool.collateralToken` is `immutable`, so one pool
  is one market; every breaker, pause, and corroboration slot is keyed per token, and `D3` holds two
  markets in opposite states with no cross-talk. The one genuinely global surface is `LivenessOracle`,
  which is intentional.

---

## Reproduction

```
git checkout cb3e6aac4214b3674a421808f7909f365b6f5814
# copy rh-chain/src into the harness root, symlink lib, then:
forge test --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

Receipt with per-file `sha256`, SHA, RPC, chain-id and block: `~/.claude/gate-receipts/audit-glend-r4`.
