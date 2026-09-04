# G-LEND gate — round 2 of 3 — Solidity/contract security lens

**Date:** 2026-09-04
**Frozen SHA:** `de67032d3d23675ebc6c170798ffad8bd7f3b65a` · `git status --porcelain` empty at start and end
**Substrate:** Robinhood Chain mainnet, `https://rpc.mainnet.chain.robinhood.com`, chain-id **4663**,
blocks **54048852 → 54062752** (the RPC is not an archive node, so runs are at latest and the block is
logged from inside the EVM; a reproducer will get a later one)

## VERDICT: NOT CLEAN — 1 HIGH, 2 MEDIUM, 4 LOW, 3 INFO. The round resets to zero.

Round 1's CRITICAL and HIGH are **closed**, and closed correctly. The escrow path added for MED-1 is
sound end to end — seven adversarial tests against the real token could not make value go missing.
The HIGH below is not a regression from the fix; it is the risk the CRITICAL was masking, and the
fix's stated rationale ("branch (b) is the real cover") is exactly half true.

---

## What round 1 found, re-checked at `de67032`

| R1 finding | Status | Evidence |
|---|---|---|
| CRIT-1 `_desyncGuard` reverts on the real token | **CLOSED** | `test_bothGatesAnswerAgainstTheRealToken` green; `ForkMvp::test_fullMvpPath_realTokenRealFeed` green — 1,036.31 USDG borrowed against real AAPL and repaid. Both gates answer. **But see HIGH-1.** |
| HIGH-1 restart-liquidation race | **CLOSED** | `LivenessOracle.sol:113` now tests the same `gapThreshold` in both directions; `grep -rn maxHeartbeatAge` over the whole repo returns only comments and docs — no code dependent survives. **But see MED-1.** |
| MED-1 collateral pause blocks `repay` | **CLOSED** | `test_C1`–`test_C6`. Debt settles under a frozen token, the Note survives as the ticket, `claimCollateral` returns the full collateral, and a burn during the escrow is shared exactly pro-rata (5.0 AAPL / 5.0 AAPL). **Borrower side only — see LOW-1.** |
| MED-2 single-key deploy posture | **PARTIALLY closed** | The five keys are now required and must differ from the deploy key. They need not differ from **each other** — see MED-2 below. |
| MED-3 false blast-radius claim | **CLOSED in text, see LOW-4** | `EsseyMarkets.sol:102-110` now states the truth. Its stated operational bound is not implementable. |
| LOW-1 `max*` overstate | **CLOSED** | `test_D1`: `maxWithdraw` 144 078 231 300 == cash exactly; both `max*` hand straight back and succeed. |
| LOW-2 `EsseyMultiply.close` pool binding | **CLOSED** | `test_E3`: a `FakePool` returning the real `markets()` is refused `WrongPool`. `test_E4`: the registry-named pool still passes without `openedIn`. |
| LOW-3 permissionless `repayPartial` | accepted, rationale recorded at `EsseyPool.sol:606-612` — agreed |
| LOW-4 dust-book accrual truncation | accepted, threshold recorded at `EsseyPool.sol:233-237` — agreed |
| INFO-1 `v4DiscountBps` dead storage | **still open** — see INFO-1 |

---

## HIGH-1 — the corporate-action guard is inoperative in the direction that costs borrowers everything

**CONFIRMED.** `src/EsseyMarkets.sol:266-292` (`_desyncGuard` / `_scheduledEffectiveAt`).

`_desyncGuard` has two branches:

- **(a)** a *scheduled* action read from `newUIMultiplier()`, requiring exactly 64 bytes back;
- **(b)** a *past* multiplier move stamped by `syncMultiplier` into `multiplierMovedAt`.

On the deployed AAPL Stock Token `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9`, branch (a) can never
fire. Verified live, not inferred:

```
cast call 0xaF3D…93f9 "newUIMultiplier()"  -> 0x…0de2b98c7058b254   (32 bytes)
cast call 0xaF3D…93f9 "uiMultiplier()"     -> 0x…0de2b98c7058b254   (32 bytes, identical)
cast call 0xaF3D…93f9 0xdeadbeef           -> execution reverted    (no fallback)
```

`newUIMultiplier()` on this token is an alias for the **current** multiplier. There is no schedule and
no `effectiveAt` surface at all (`test_B1`). `_scheduledEffectiveAt` therefore returns 0 at every
block, forever, and branch (a) is dead code in production.

That leaves branch (b), which only fires **after** `uiMultiplier` has already moved. So the guard
covers the multiplier-first half of a corporate action and nothing else. The other half — the
Chainlink feed reprices at the split before the issuer's `uiMultiplier` transaction lands — is
completely unguarded, and it is the half that mis-prices collateral **downward**.

There is no second line of defence:

- `src/StaleFeedGuard.sol` checks staleness, round completeness and session. It has **no deviation
  breaker** — a 99% single-round move is accepted verbatim (`test_B5`).
- `canLiquidate` deliberately has no `enabled` conjunct (`EsseyMarkets.sol:321-327`), so
  `disableMarket` stops new borrows and leaves liquidation wide open (`test_B4`).
- The only lever that would stop it is the liveness keeper going silent, i.e. the MED-3 kill switch.

### PoC — `test_B2_feedFirstSplitLiquidatesHealthyPositionsForFreeProfit`

Real AAPL, real feed, real USDG, deployed risk params (LTV 5000 / liqThreshold 7500 / bonus 500).
A borrower opens at 90% of max (45% LTV against a 75% threshold) and is unambiguously healthy. The
feed then halves, as it does on the ex-date of a 2:1 split, while `uiMultiplier` has not yet doubled:

```
multiplierMovedAt(AAPL) == 0            branch (b) has nothing to see
markets.canLiquidate(AAPL) == true      the guard does not fire
markets.canBorrow(AAPL)   == true       new borrows are admitted at the wrong price too
isUnderwater(...)         == true       a healthy position now reads underwater

debt repaid by liquidator (USDG)   1 480 442 175      $1,480.44
value of seized units, post-flip   3 107 169 659      $3,107.17
liquidator profit (USDG)           1 626 727 484      $1,626.73  (110% of the debt)
```

The liquidator pays the debt, takes collateral valued at half its true worth plus a 5% bonus, and
the borrower's "surplus refund" is computed at the same wrong price. Scaled to the deployed
`cap = 250_000e6` per market, the extractable value is of the order of the whole market's collateral,
taken from borrowers, on a date that is public months in advance.

`test_B3` is the control: with the multiplier moving first, branch (b) stamps the move and both gates
shut. The asymmetry is the finding.

**Epistemic status.** The *mechanism* is CONFIRMED — every step above is a passing assertion against
mainnet state. Whether the feed leads or lags the issuer's transaction on a real ex-date is
**UNVERIFIED**: it is the issuer's operational timing and we cannot observe it. It is not under this
protocol's control, which is precisely why the guard exists. The current live `uiMultiplier` is
1.000566080061092436 — not 1.0 — so this token demonstrably does rescale.

**Fix — pick one, they are not equivalent:**

1. **Preferred.** Give `_desyncGuard` a price-side trigger it can read without the issuer's
   cooperation: stamp `lastPrice` per market in `syncMultiplier` and treat a single-round move beyond
   a configured `maxDeviationBps` (say 1500) as a desync, shutting both gates for
   `MULTIPLIER_GUARD_WINDOW`. This covers a split in either direction and is the deviation breaker the
   price path lacks anyway.
2. **Minimum.** Add a guardian-callable `pauseLiquidation(token, until)` bounded to a few hours so
   there is *any* lever during a scheduled corporate action. Today there is none.
3. **Not sufficient on its own.** Making branch (a) return `true` on an unreadable schedule. The
   engineer is right that this bricks both gates permanently on this token — reject that option, as
   they did. The error is only in concluding branch (b) therefore suffices.

Whatever is chosen, correct `EsseyMarkets.sol:267` and `src/interfaces/IScaledUI.sol:11-16`: branch
(a) is documented as live coverage and is dead against the only collateral that will be listed.

---

## MED-1 — the collapsed liveness bound couples the whole protocol to a 15-minute keeper SLA, at the maximum amplification the constructor permits

**CONFIRMED.** `src/LivenessOracle.sol:108-116`, `script/DeployMarkets.s.sol:230`.

Deleting `maxHeartbeatAge` is right: one bound cannot race itself, and nothing else depended on it
(`grep -rn maxHeartbeatAge` over the repo — code hits are zero). The problem is the deployed pair.

`LivenessOracle(keeper, guardian, 900, 1 hours)` sets `resumeGrace == 4 × gapThreshold`, which is
**exactly** the ceiling `LivenessOracle.sol:76` enforces — and the reason that ceiling exists is the
comment immediately above it: a gap only just over the threshold otherwise "would suspend liquidations
for many multiples of the outage's own length … a liquidation DoS." The deploy sits on the worst
permitted value.

Because `canBorrow` also consults `liquidationsAllowed()` (`EsseyMarkets.sol:239`), both gates now
share a 15-minute keeper SLA where the borrow gate previously had 25 hours.

### PoC — `test_A1`, `test_A2`, `test_A3` (deployed params, real market)

```
A1  901 seconds of keeper silence  ->  4 501 seconds of total protocol outage
    (liquidationsAllowed false AND canBorrow false throughout: 901s dark + 3600s grace)

A2  24 cycles of "901s silent, one beat, sit in the grace"
    ->  30 hours of continuous liquidation blackout
    ->  keeper silence duty cycle: 2002 bps (20.02%)

A3  simple silence: both gates shut indefinitely, no further action needed
```

A keeper with 80% uptime measured in 15-minute buckets produces a **permanent** liquidation blackout
while interest compounds and prices move. `keeper/liveness-keeper.mjs:28` beats every
`gapThreshold/3 = 300s`, so two missed beats plus one slow block is enough. This is not a hypothetical
attacker; it is a single-key cron on a single RPC.

The safe-for-borrowers direction is the unsafe-for-lenders direction, and nothing bounds it.

**Fix.** Keep the single bound — that part is correct — and stop deploying at the amplification
ceiling. `LivenessOracle(keeper, guardian, 1800, 1800)` gives detection inside 30 minutes with a 1×
grace, or `(900, 900)` keeps the 15-minute detection with a 15-minute grace. There is no race either
way, because one predicate now serves both sides. If 1 hour of grace is genuinely wanted, raise
`gapThreshold` to 3600 to match it; a longer detection delay costs nothing now that a halted chain
fails the view with no transaction.

Separately: `liveness.heartbeat()` is gated on a single address and `setKeeper` is guardian-only, so
a keeper that dies has a cold-key recovery of one transaction. That is fine — but see LOW-4.

---

## MED-2 — the role gate stops the deploy key and nothing else; four of the five roles may still be one hot key, two of them immutably

**CONFIRMED.** `script/DeployMarkets.s.sol:126-161` (`_roleKey` / `_checkRoles`).

The rule enforced is: each of the five is non-zero, each differs from `msg.sender`, and
`livenessKeeper != livenessGuardian`. That is the **only** cross-role constraint. Nothing stops
`GUARDIAN == LIVENESS_KEEPER == DEPTH_KEEPER == RESERVE_TREASURY`.

`test/DeployMarketsRoles.t.sol` is honest to that rule — it indexes all five positionally
(`_withRole`, :44), so it does not have the "tests the first one five times" defect. It tests the rule
that exists. The rule is the gap, not the test.

### PoC — `test_F1_oneHotKeyMayHoldFourOfTheFiveRolesOnMainnet`

Run against a byte-identical copy of `script/DeployMarkets.s.sol`
(sha256 `b6534fe381a2c45a6b68cfd4f53ce69736c3f6cab79bb7cc7fdbbcbf08313d8c`, only the relative import
depth changed):

```
h.check(false /* mainnet profile */, {guardian: 0xB0B, livenessKeeper: 0xB0B,
    livenessGuardian: 0xC01D, depthKeeper: 0xB0B, reserveTreasury: 0xB0B})   -> ACCEPTED
```

### Blast radius of that one key, enumerated

| Held role | Contract | Power | Reversible? |
|---|---|---|---|
| `GUARDIAN` | `EsseyMarkets.guardian` | `disableMarket` on every market — all new borrows stop | **immutable**, `EsseyMarkets.sol:211` |
| `GUARDIAN` | `MarketHealthOracle.guardian` | rotate the depth keeper | immutable |
| `LIVENESS_KEEPER` | `LivenessOracle.keeper` | stop beating → liquidations *and* borrows shut protocol-wide, indefinitely, while interest compounds (MED-1 above) | rotatable by `LIVENESS_GUARDIAN` |
| `DEPTH_KEEPER` | `MarketHealthOracle.keeper` | every `effectiveCap` to 0 → `canBorrow` false, `_gateNewDebt` reverts | rotatable by guardian — but the guardian is the same key |
| `RESERVE_TREASURY` | `EsseyPool.reserveTreasury` | receives every skimmed reserve, i.e. all protocol revenue | **immutable**, `EsseyPool.sol:127` |

One compromised hot key = total protocol halt plus all protocol revenue, and two of the five bindings
cannot be rotated afterwards. That is close enough to the posture MED-2 was raised to prevent that
shipping it under a gate named for separation is worse than shipping it knowingly.

Note also that `admin` is still `msg.sender`, the deploy key: `EsseyMarkets.admin` (propose/commit
markets, propose resolver, all timelocked) and `MarketHealthOracle.admin`
(`DeployMarkets.s.sol:232-235`). Timelocked, so not urgent — but the largest key is the one the rule
was written to exclude, and it is excluded from four roles and kept for the fifth.

**Fix.** Two lines in `_checkRoles`:

```solidity
require(testnet || r.reserveTreasury != r.guardian
        && r.reserveTreasury != r.livenessKeeper
        && r.reserveTreasury != r.depthKeeper, "RESERVE_TREASURY must not be an operational key");
require(testnet || r.guardian != r.livenessKeeper, "GUARDIAN must not be the liveness keeper");
```

`RESERVE_TREASURY` is the one that must be cold and is immutable; `GUARDIAN` vs `LIVENESS_KEEPER` is
the pair whose union is "halt everything". Sharing `GUARDIAN` with `DEPTH_KEEPER` is defensible and
can stay.

---

## LOW-1 — the escrow was applied to the borrower's side only; liquidation and write-off still revert entirely under a collateral freeze

**CONFIRMED.** `EsseyPool.sol:726-727` (`liquidate`), `:775` (`writeOff`).

Both end in `IERC20(p.token).safeTransfer(...)`, so a collateral-token pause reverts them outright,
while `_growth()` (`EsseyPool.sol:359-364`) suspends the clock only for a **borrow-asset** pause. So
during a collateral freeze the protocol cannot manage risk on that market at all, and the debt keeps
growing.

`test_C7`: with the position deeply underwater, `liquidate` reverts under the freeze, and 30 frozen
days move the debt from 1 480 442 175 to 1 486 599 192 USDG.

**Assessment: accept, with the rationale recorded rather than left implicit.** The borrower always has
an exit (`repay` now escrows), which is the important half. Escrowing a liquidator's seizure would
mean paying `owed` for an IOU, which nobody sane does; and a token nobody can transfer is a token
nobody can value or sell, so refusing to liquidate it is arguably correct. What is *not* acceptable is
that the asymmetry is undocumented — `EsseyPool.sol:537-548` reads as though the freeze problem is
solved. Add one sentence at `liquidate` naming the residual, or fix it.

## LOW-2 — the mainnet deploy-config document contradicts the deploy script on every lending number

**CONFIRMED.** `docs/MAINNET-CONFIG.md:47-53` vs `script/DeployMarkets.s.sol`.

| Doc says | Code does |
|---|---|
| `LivenessOracle(keeper, guardian, maxHeartbeatAge=30m, resumeGrace=30m, gapThreshold=15m)` | 4-arg `(keeper, guardian, 900, 1 hours)` — `maxHeartbeatAge` no longer exists, and `resumeGrace` is 1h not 30m (`:230`) |
| `EsseyMarkets(sequencerFeed, liveness, admin, assetDecimals)` | 6 args, `(seqFeed, liveness, health, admin, guardian, assetDecimals)` (`:233`) |
| `EsseyPool(usdg, markets, base=1000, s1=0, s2=0, reserve=2000, bellSink=bell, bellShareBps=5000)` | `(usdg, token, markets, c.base, c.slope1, c.slope2, 1000, address(0), reserveTreasury, 0, identity)` — reserve 1000, **no Bell sink, bellShareBps 0** (`_listMarket`) |
| Markets LTV **35%** / liqThreshold **55%** / bonus **8%** | LTV **5000** / liqThreshold **7500** / bonus **500** (`_propose`) |

The risk-parameter row matters most: a reader sizing exposure from this doc gets a 20pp gap where the
code ships 25, and a bonus of 8% where the code ships 5%. The Bell row describes revenue routing the
mainnet script does not wire. Pre-existing (not introduced at `de67032`), but this is the document
that governs the deploy.

## LOW-3 — the testnet profile mints an 18-decimal USDG mock against a profile that declares 6

**CONFIRMED.** `script/DeployMarkets.s.sol:226` deploys `new ScaledUIStockMock("Mock USDG","USDG")`
as the borrow asset. `ScaledUIStockMock` does not override `decimals()`, so it is **18**.
`profileFor(46_630).usdgDecimals` is **6** (`:98`), and the `decimals()` assertion at `:207` runs only
on the `!testnet` branch.

The stack stays internally consistent (`EsseyPool`'s constructor cross-checks
`markets.assetDecimals()` against the asset), so nothing is *wrong* on testnet. What it means is that
a testnet rehearsal — the pre-mainnet gate — never exercises the 6-decimal borrow asset that ships.
This is the same shape as CRIT-1: a fixture that agrees with the design instead of with the chain.
One line fixes it (`decimals()` override returning `prof.usdgDecimals`).

## LOW-4 — the stated operational bound for MED-3 is not implementable against this contract

**CONFIRMED.** `EsseyMarkets.sol:108-110` now says the liveness-keeper risk is "bounded only
OPERATIONALLY: two independent keepers, and page on lastHeartbeat ageing past gapThreshold / 2."

`LivenessOracle.heartbeat()` is `if (msg.sender != keeper) revert NotKeeper()` — a single address
(`LivenessOracle.sol:88-89`). Two independent keepers is only possible if that address is a contract
or multisig that either operator can drive, which neither the contract nor `DeployMarkets.s.sol`
creates and the comment does not say. As written the mitigation reads as though it is in place.

Either deploy `LIVENESS_KEEPER` as a 1-of-N relay contract and say so, or reword to the bound that
actually exists (one keeper, one cold rotation key, and the page).

---

## INFO

**INFO-1 — `v4DiscountBps` is still dead storage. Re-flagged, and accepted with rationale.**
`MarketHealthOracle.sol:63,85,102,238,249` write, default and validate it; a repo-wide grep excluding
its own file and its own test finds **zero** consumers in `src/`, `script/`, `keeper/` or the web app.
No security impact — it is admin-only and timelocked. Re-flagged because a timelocked parameter with
no consumer reads on an ops dashboard as a live control, and someone will one day change it during an
incident and believe the haircut moved. Wire it or delete it; either is a small diff.
(`docs/MAINNET-ACTIVATION.md:1448` tracks the *test* gap for this param, not the dead-consumer one.)

**INFO-2 — `secondsUntilLiquidationsAllowed()` returns 0 while liquidations are shut.**
`LivenessOracle.sol:120-124` returns 0 when the block is on the liveness branch rather than the clock
branch, which is indistinguishable from "allowed now" for a consumer reading only this. Harmless while
it is paired with `liquidationsAllowed()`; materially more likely to be hit now that the bound is 15
minutes rather than 25 hours (`test_A3`).

**INFO-3 — no fork test exercises the deployed liveness shape.** `test/ForkMvp.t.sol:52` constructs
`LivenessOracle(keeper, admin, 30 minutes, 1 minutes)` — `resumeGrace` **below** `gapThreshold`, the
inverse of the deployed 900 / 3600. `_settleLiveness`'s "< gapThreshold, so it registers no gap"
comment (`:136`) is true only for that fixture. The deployed amplification is not covered by any fork
test in the repo; it is covered by `test/LivenessOracle.t.sol` unit tests, which is weaker for exactly
the reason this round exists.

---

## Rulings on the three items the engineer declared

**1. No `forceApprove(pool, 0)` after `EsseyMultiply.close`. — ACCEPTED, and for a stronger reason
than the one given.**

Measured, not reasoned: `test_E1` closes two rungs and asserts
`allowance(multiply, pool) == 0`, plus zero residual asset and zero residual collateral. `repay`
pulls exactly `owed` (`EsseyPool.sol:524`), and `close` calls `pool.accrue()` before the loop
(`EsseyMultiply.sol:243`) so the `debtOf` quoted outside equals the `owed` computed inside.

The "hostile or upgraded pool" case the founder asked about is not reachable at all, which is a better
argument than the exact-amount one: `close` accepts only `openedIn[pool]` (set exclusively from
`markets.activePool` at open time, `EsseyMultiply.sol:158`) or the registry's current `activePool`,
and `EsseyPool` is constructed with `new` — no proxy, no upgrade path, no admin that can change
`repay`. `test_E3` confirms a contract that merely returns the right `markets()` is refused.

Round 1's prescription was sound as defence-in-depth; declining it here costs one SSTORE per rung and
gives up nothing that is reachable.

**2. `_accruedConvertToShares` Ceil-instead-of-Floor is an equivalent mutant. — TRUE, BUT
CONFIG-DEPENDENT, AND THE INVARIANT MUST BE WRITTEN DOWN.**

It is not value-equivalent, which the declaration understates. Measured at a real lent-out pool
(`test_D2`, 150k USDG deposited, 60 days of accrual):

```
floor shares 144 033 140 463 647 845      ceil shares 144 033 140 463 647 846
previewRedeem(floor) = 144 078 231 299     previewRedeem(ceil) = 144 078 231 300 == cash exactly
```

The mutant returns one more asset unit and lands **exactly on** `cash`, never past it — so
`_withdraw`'s `assets_ > cash` check does not trip and no call reverts. Equivalence in behaviour, not
in value.

It holds only while **one share is worth at most one asset unit**, i.e.
`_accruedAssets() + 1 <= totalSupply() + 10 ** _decimalsOffset()`. Algebraically:
`floor(ceil(x)·r) = cash` whenever `r = (A+1)/(S+10^off) <= 1`. Measured margin at the deployed
`_decimalsOffset() == 6`: one share is worth 1.000313e-6 asset units — six orders of magnitude of
headroom, unreachable without a 1e6× share-price appreciation. `testFuzz_D2b` pins the boundary
condition over 256 runs.

**Record it as a config-dependent invariant**, in a comment at `EsseyPool.sol:402-408`:
"Floor vs Ceil is behaviourally equivalent here *only* while `_decimalsOffset() >= 6`; at offset 0 the
Ceil form overshoots `cash` and `_withdraw` reverts." A future offset change would silently
reintroduce the LOW-1 revert the max* rewrite existed to remove.

**3. INFO-1 deferred. — RE-FLAGGED as INFO, accept-or-delete, no security gate.** See INFO-1 above.

---

## Verified clean this round (asserted, not assumed)

- **The escrow path holds under attack.** Debt settles unconditionally; the Note survives as a bearer
  ticket; `claimCollateral` is bearer-authed, single-use and permissionlessly retryable; a doomed
  claim consumes nothing; a burn during escrow is shared exactly pro-rata; a borrower opening *after*
  an escrow is not diluted; and nothing is stranded when both exit (`test_C1`–`test_C6`).
- **Every other position path refuses an escrowed position** — `repay`, `borrowMore`, `repayPartial`,
  `addCollateral`, `removeCollateral`, `liquidate` all revert; `writeOff` reverts on `principal == 0`
  (`EsseyPool.sol:757`). The settled debt cannot be re-opened (`test_C2`).
- **`_tryReturnCollateral`'s empty-returndata branch is not a hole.** It accepts `ret.length == 0` as
  delivery without `SafeERC20`'s `token.code.length` check, but `_reconcile(p.token)` runs first and
  its typed `balanceOf` reverts against a codeless token — so a codeless or codeless-delegate token
  cannot reach the branch. Verified by reading `EsseyPool.sol:556` against
  `CollateralReconciler.sol:97`.
- **Reentrancy across the new escrow call.** `_tryReturnCollateral` gives the token control while
  `principal == 0` and the Note is unburned. Every pool entry point is `nonReentrant`; the one
  unguarded public function, `accrue()`, is a `dt == 0` no-op at that point because `repay` accrued at
  its top.
- **The 50 000-gas caps clear the real contracts.** `uiMultiplier()` 15 736 gas, `newUIMultiplier()`
  2 012, USDG `paused()` 15 449 (`test_D3`). No silent guard failure from the cap.
- **`maxWithdraw` / `maxRedeem` are both redeemable** and clamp at cash (`test_D1`).
- **A skim is share-price neutral** (`test_D4`).
- **`EsseyMultiply` holds nothing between transactions**, and an escrowed Note is forwarded to the
  caller rather than stranded in the periphery (`test_E2`).
- **`ScaledUIStockMock` and `MockStock` can now express the failures they claim to cover** — the
  `Shape{OneWord,TwoWords,Garbage,Reverts}` enum defaults to the deployed OneWord, and `paused`
  actually blocks `_update`. Only `uiMultiplier()` is still read through a typed `IScaledUI` call
  (`EsseyMarkets.sol:188,511`), and the deployed token answers it with 32 bytes, so that is sound.
- **Repo suite:** 669 tests, 21 suites, 0 failures. **Repo fork suite:** `test/ForkMvp.t.sol` 5/5
  green including `test_fullMvpPath_realTokenRealFeed`. The permanently-red fork test claim is
  verified true.

## Harness

Written outside the repo so the frozen tree stayed untouched
(`…/scratchpad/r2root/test/{Base,A_Liveness,B_Desync,C_Escrow,D_Vault,E_Multiply,F_Roles}.sol`).
Consolidated run: **27 tests, 6 suites, 0 failed** against
`--fork-url https://rpc.mainnet.chain.robinhood.com`. Every one is an assertion about behaviour; the
findings are the tests that PASS while asserting the broken behaviour.
