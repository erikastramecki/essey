# Speculative upside for Don-collateral lending — design scope

**Status:** research/design only — no code changed. Every claim cites the real contract or test.
**Question:** how could Essey give borrowers *bigger draws that grow with value* (the market-value-NFT-lender
experience) without destroying the core differentiator — **structurally zero bad debt**, proven in
[`docs/RISK-COMPARISON.md`](./RISK-COMPARISON.md) §2 (`docs/RISK-COMPARISON.md:53-65`) and the fork stress
battery (`rh-chain/test/DonSolvencyStress.t.sol`).
**Decision doc for:** the founder, ahead of the #81 mainnet deploy
([`docs/MAINNET-DEPLOY-CHECKLIST.md`](./MAINNET-DEPLOY-CHECKLIST.md)).

---

## 0. The mechanics that box us in (grounding)

Four facts of the deployed design bound every option below:

1. **The draw is a fixed fraction of a floor that cannot fall.** `borrow()` disburses exactly
   `ltvBps` of the live `reserve.floorPerDon()` (`rh-chain/src/market/DonLoan.sol:312-313`, view at
   `:209-211`), and `DonReserve` is fund-only + pro-rata on redeem, so the floor is monotone
   non-decreasing (`rh-chain/src/market/DonReserve.sol:60-62` floor; `:67-71` permissionless fund;
   `:76-91` pro-rata redeem; no withdraw path exists — the contract is adminless by design, `:25-26`).

2. **The risk knobs are immutable.** `ltvBps` and `liqThresholdBps` are `immutable`
   (`DonLoan.sol:82-83`), constructor-checked to `ltvBps + 2000 ≤ liqThresholdBps ≤ 9000`
   (`DonLoan.sol:110-111,180`). Debt is flat forever (`debtOf` returns principal, `:231-235`);
   default is the calendar (`:403`); liquidation redeems at the floor and returns the surplus to the
   borrower (`:415-424`). Checklist section A1 confirms: wrong value = redeploy + migrate
   (`docs/MAINNET-DEPLOY-CHECKLIST.md:17-32`).

3. **The lien is one-shot.** `Don.setLienManager` reverts on a second call
   (`rh-chain/src/market/Don.sol:175-179`); only that one facility can lien (`:183-188`), block
   transfers (`:229-237`), and seize (`:242-250`). **A second lender can never lien a Don. Any change
   to the loan facility after #81 is a full-stack redeploy + holder migration**
   (`docs/MAINNET-DEPLOY-CHECKLIST.md:66-68`).

4. **There is no market-price signal above the floor.** The desk quotes
   `price() = max(donPrice, floorPerDon())` on both sides (`rh-chain/src/market/DonExchange.sol:119-122`)
   — deliberately floor-pinned so buy→redeem arbitrage is strictly unprofitable (`:29-36`, proven as
   invariant D, `DonSolvencyStress.t.sol:467-477`). Nothing on-chain knows what a Don is "worth"
   above the floor. OpenSea/secondary have no oracle.

The stress battery already proved: floor monotonic (invariant A, `DonSolvencyStress.t.sol:415-419`),
no bad debt with `debt + tip ≤ floor` per loan (invariant B, `:428-446`), and — critically for lever 2
— a **24-combo tunable sweep** (`ltvBps ∈ {1000, 2500, 5000, 7000}` × 2 reserve levels × 3 interest
coefficients, `:767-790`) where **every point, including `ltvBps = 7000`, recovers full principal with
zero protocol loss** (`:828`).

---

## 1. Lever 1 — Floor-growth amplification (free; zero bad-debt impact)

**Mechanism.** `maxBorrow()` tracks the floor 1:1 (`DonLoan.sol:209-211`). `DonReserve.fund()` is
permissionless (`DonReserve.sol:67-71`). Route more protocol proceeds into the reserve → floor rises →
every future draw (and every top-up under lever 3) rises. Funding also *heals* every open loan
(`DonLoan.sol:237-239`).

**What currently does NOT flow to the reserve** (this is the whole opportunity):

| Proceeds stream | Where it goes today | Cite |
|---|---|---|
| 70% of AMM fees (8% swap / 12% snipe) | `feeSink` = DonFeeRouter → USDG → Bell (stock dividends) | `DonExchange.sol:50-51,196-204`; `DonFeeRouter.sol:58,199-202` (bell sink immutable) |
| 30% of AMM fees | treasury | `DonExchange.sol:199-203` |
| 100% of mint/reroll ETH fees (teamBps=0) | feeSink → Bell | `DonDistributor.sol:47,214-227` |
| Prepaid loan interest (ETH) | 70% feeSink / 30% treasury | `DonLoan.sol:336-348` |
| 5% secondary royalty | treasury | `Don.sol:112-114`; checklist B (`ROYALTY_BPS=500`) |
| Desk sale prices | stay in DonExchange's own reserve (back the sell side) | `DonExchange.sol:154` |

`docs/TOKENOMICS-v3.md:75-76` states it flatly: *"loan interest does **not** flow here."* The Bell leg
is welded (`DonFeeRouter.bell` immutable, `:58`); the 70/30 splits are immutable in the exchange and
loan. **The only stream freely redirectable post-deploy is the treasury's own 30% legs + royalties —
by treasury policy, calling `DonReserve.fund()`.**

**Quantified flywheel.** Floor = reserve / 8,888 (`DonReserve.sol:60-62`; funded floor = 300,030
$ESSEY, `docs/TOKENOMICS-v3.md:70`). Raising the floor Δ per Don costs Δ × 8,888 $ESSEY:

| Floor target | maxBorrow @50% / @70% | Reserve funding needed | = % of total supply |
|---|---|---|---|
| 300,030 (day 1) | 150,015 / 210,021 | — | 30% (already in) |
| +10% → 330,033 | 165,016 / 231,023 | ~266.7M | +3% |
| +25% → 375,037 | 187,518 / 262,526 | ~666.7M | +7.5% |
| +50% → 450,045 | 225,022 / 315,031 | ~1.33B | +15% |

Per desk round-trip at the 300k floor: fees ≈ 24k (buy) + 24k (sell) $ESSEY; the treasury's 30% leg is
~14.4k → floor +1.62 $ESSEY per round trip if fully routed. A +10% floor needs ~18,500 round trips
from that leg alone. **Honest read: policy-only routing is a slow, real, compounding drip — not a hype
engine.** To make it material you'd re-cut the split *at deploy* (the splits are immutable — pre-#81
config/code, e.g. a treasury-splitter contract as the welded `treasury` address that forwards a share
to `DonReserve.fund`, note it must also proxy the two treasury-gated calls `withdrawIdle` /
`setEthRatePerFloorYear`, `DonLoan.sol:280-294`), or adopt the desk-excess design in §6 (every
above-floor desk sale funds the floor).

**Risk class:** none — funding the reserve is the safest action in the system (invariant A/E).
**Effort:** policy version: zero code. Splitter version: ~1 day + 1 audit round, decided before #81.
**"Zero bad debt" impact:** none; strictly strengthens it.
**What the borrower feels:** draw grows with *protocol revenue*, not with hype. This is real upside
but it is slow and it never tracks a speculative mark.

---

## 2. Lever 2 — Higher LTV at deploy (config-only; TIME-SENSITIVE, irreversible)

**Mechanism.** Pass a bigger `ltvBps` to the `DonLoan` constructor on deploy day. One number in the
#81 env; zero code change *within the currently-provable range*.

**The hard bounds, from the code:**
- Constructor requires `ltvBps + MIN_RISK_GAP_BPS(2000) ≤ liqThresholdBps ≤ MAX_LIQ_THRESHOLD_BPS(9000)`
  (`DonLoan.sol:110-111,180`) → **`ltvBps ≤ 7000` is the maximum deployable without a code change.**
  80%/90% are *not config* — they require editing the constants and re-auditing (see table below).
- Solvency arithmetic: liquidation pays tip = `liqTipBps` (100 = 1%) of proceeds first
  (`DonLoan.sol:418`), so full principal recovery at the origination floor requires
  `ltvBps + liqTipBps ≤ 10000` — arithmetically fine up to 99%. The binding constraints are the
  constructor bounds and the cushion, not rounding (18-decimal dust is negligible; the dregg tuple
  already rounds debt up / floor down conservatively, `DonLoan.sol:256-261`).

**The 60/70/80/90 analysis** (floor 300,030; tip 1%):

| ltvBps | Draw | Liq threshold needed | Deployable? | Liquidation surplus to defaulter (floor − debt − tip) | Zero-bad-debt status |
|---|---|---|---|---|---|
| 5000 (current) | 150,015 | 7000 ✓ | ✓ config | 49% of floor ≈ 147k | Proven (sweep + invariants) |
| 6000 | 180,018 | 8000 ✓ | ✓ config | 39% ≈ 117k | Same structure; **not a swept point** — extend the sweep before shipping it |
| **7000** | **210,021** | **9000 ✓ (== max)** | **✓ config** | **29% ≈ 87k** | **Proven — swept at exactly this point, zero loss** (`DonSolvencyStress.t.sol:768,828`) |
| 8000 | 240,024 | needs 10000 ✗ | ✗ code change (`MAX_LIQ_THRESHOLD_BPS`/gap constants) + re-audit + re-sweep | 19% | Still structurally sound *arithmetically*, but you'd be editing the enforced risk discipline itself |
| 9000 | 270,027 | needs 11000 ✗ | ✗ code change | 9% | Cushion thin: tip + any future param drift eats it; the "dead" ratio backstop loses all dead-band |

**Cushion trade-offs at 7000:** the ratio backstop (dead-but-present, `DonLoan.sol:48-58`) sits at
9000 — still structurally unreachable (flat 70% debt < 90% threshold), but the dead-band shrinks from
20pp to 20pp-gap-at-a-higher-altitude; a defaulter's returned equity drops from ~49% to ~29% of the
floor (still surplus-back, checklist C#9, `docs/MAINNET-DEPLOY-CHECKLIST.md:126`); and the loan pot
depletes ~40% faster per loan (266.6M funds ~1,777 loans at 50% vs ~1,269 at 70% of today's floor) —
resize via `LOAN_FUND` (tunable, checklist C#4). The dregg circuit proves `debt·10000 ≤ floor·ltvBps`
with `ltvBps` as a tuple field (`DonLoan.sol:244-265`) — **no circuit change at any LTV**.

**⚠ FLAG: this decision is welded.** `ltvBps` is immutable (`DonLoan.sol:82`), and because
`Don.setLienManager` is one-shot (`Don.sol:175-179`), a redeployed DonLoan means a full-stack redeploy
and holder migration (`MAINNET-DEPLOY-CHECKLIST.md:66-68`). **The LTV number must be decided before
#81 and cannot be revisited after.** It also cannot be *lowered* later — if 7000 later feels
aggressive for the narrative, that's forever too.

**Risk class:** zero at ≤7000 (proven); param-discipline risk at >7000.
**Effort:** ≤7000: env change + (for 6000) one added sweep point. >7000: constants edit + full re-audit.
**"Zero bad debt" impact:** none at ≤7000 — the claim survives verbatim. The *marketing* changes from
"we lend half the floor" to "we lend 70% of the floor", which is a stronger product and a still-true claim.

---

## 3. Lever 3 — Top-up draws / refinance (new feature; still floor-backed; PRE-#81 ONLY)

**Mechanism.** Today the code explicitly forbids top-ups: one loan per Don (`LoanExists`,
`DonLoan.sol:323`) and the header says the workaround out loud — *"no top-ups (repay and re-borrow to
re-lever onto a risen floor)"* (`DonLoan.sol:305`). That workaround requires the borrower to produce
the full principal mid-term. A `refinance(donId, termSeconds)` removes that capital requirement:

```
newPrincipal = ltvBps × floorNow / 10000        // same line as borrow (DonLoan.sol:313)
require(newPrincipal > loan.principal)           // floor rose → there is a delta
disburse(newPrincipal − loan.principal)          // the top-up
loan.principal = newPrincipal                    // still exactly ltvBps of a live floor snapshot
loan.expiry    = now + termSeconds               // re-originate the calendar
loan.nonce     = ++loanNonce                     // fresh dregg tuple, prove as usual
prepaid ETH    = _prepaidFromFloor(floorNow, termSeconds), full charge, no credit for the old term
```

**Fit with the flat-debt / prepaid / calendar model:** treat it as an atomic repay+re-borrow (which is
exactly what the current comment tells users to do manually). Debt stays flat at the *new* principal;
interest stays a fresh prepaid-ETH leg on the new floor × new term (consistent with "prepaid… never
refunds", `DonLoan.sol:360-363` — no pro-ration, no refund of the old term's ETH); the calendar resets,
which is fine because the solvency invariant is time-free. Do **not** design a delta-draw that keeps
the old expiry with pro-rated interest — it adds a second interest formula and buys nothing.

**Structural safety:** unchanged. At every (re)origination `principal = ltvBps × floorPerDon()` against
a floor that only rises → invariant B (`debt + tip ≤ floor`) holds by the same argument; the sweep's
proof shape covers it. Fails closed if the pot lacks the delta (transfer reverts).

**Effort:** ~1 function + events + ~1-2 days of tests (extend the stress handler with an `act_refinance`
and re-run the invariant campaign) + one 3-agent audit round.
**⚠ The catch:** it must be **in DonLoan before #81** — the one-shot lien weld means it cannot be added
after without full migration. This is the same deadline as lever 2.
**"Zero bad debt" impact:** none.
**What the borrower feels:** this is the one that *feels* like a market-value lender — "my Don's line
went up, I draw more" — while the number going up is the provable floor, not a mark.

---

## 4. Lever 4 — The premium tranche (the real market-value move; opt-in, segregated)

An **opt-in second draw against market value above the floor**, price-liquidated, funded from a
**segregated risk pot**, so bad debt is *possible but bounded* and never touches the base layer.

### 4.1 Structure

- **Base slice (unchanged):** `ltvBps × floor`, funded from the base pot, liquidated by calendar,
  settles by reserve redemption. Zero bad debt, exactly as today.
- **Premium slice (new, opt-in):** up to `premLtvBps × max(0, P − floor)` where `P` is a
  manipulation-resistant reference price. Funded ONLY from a separate `premiumPot` (own accounting,
  own depositors, own loss absorption). Price-liquidated: if `premDebt > premLiqBps × (P_live − floor)`
  — or on the same calendar default — the whole position settles together (one Don, one lien).
- **Settlement waterfall:** try an auction first (Dutch, start ≥ P, floor-redemption as the reserve
  bid of last resort — note the desk *sell* side pays `floor − 8%` (`DonExchange.sol:177-183`), i.e.
  *below* floor, so the desk is not a liquidation venue; `DonReserve.redeem` at the floor is). Proceeds:
  tip → base principal (always covered at ≥ floor) → premium principal → borrower surplus. **Any
  premium shortfall is written off against `premiumPot` only.** Base pot and DonReserve are never
  debited — the "bounded" claim is an accounting wall inside one contract, so it must be an *audited
  invariant* (premiumPot balance ≥ 0 standalone; base `totalPrincipal` accounting untouched by premium
  writeoffs), not a comment.

### 4.2 Where does the price come from? (the hard problem)

There is no oracle. OpenSea has none. Today the only venue is the desk, and its price is pinned to the
floor by design (`DonExchange.sol:119-122`) — **the current system deliberately destroys the very
signal this lever needs.** Options, worst to best:

| Source | Verdict |
|---|---|
| Trusted reporter posts OpenSea floor | Rejected — reintroduces an oracle/keeper trust surface into the loan path; contradicts the oracle-free thesis stated in `DonLoan.sol:24-25` |
| Spot desk price (if the desk floated) | Rejected — spot is exactly what flash-pump-then-borrow eats |
| **TWAP of real desk trades above the floor-pin** (requires the §6 hybrid desk) | Viable — trades cost 8-12% fees + the above-floor spread, so writing the TWAP costs real money |
| **Underwriter-quoted (NFTfi-style P2P on the premium slice only)** | Most robust — the premium lender *is* the price oracle and eats their own quote; no global price needed |

**Manipulation-resistance requirements if TWAP (the classic flash-pump-then-borrow exploit is THE
attack — pump the venue, borrow the inflated premium, default, keep the cash):**
- **TWAP window ≥ 7 days**, arithmetic over trade observations, ignoring self-crossed sizes below a
  minimum. A pump must be sustained across the window against permissionless sellers arbing it back down.
- **Deposit-age / loan-delay:** premium draws only against a Don held ≥ N days (buy-then-instantly-borrow
  is the exploit's second half).
- **Premium cap per Don:** `min(premLtvBps × (TWAP − floor), capBps × floor)` — e.g. the premium slice
  can never exceed 50% of the floor no matter what the TWAP says. This alone bounds the exploit's
  payoff per Don.
- **Global tranche cap:** `Σ premium principal ≤ coverageBps × premiumPot` — bad debt is bounded by
  construction to capital that opted in.
- **Attack economics must be negative:** cost to move a 7-day TWAP by X (fees ≈ 8-16% per round trip
  on the desk + spread) must exceed `premLtvBps × X` per Don × per-Don cap × attacker's Don count.
  This inequality is a design deliverable, not a hope — it goes in the audit scope.

**Capital for the risk pot:** protocol treasury seed (simplest; the 30% legs) and/or third-party
underwriter deposits that earn the premium slice's interest — the premium leg should charge *real*
interest (in $ESSEY, accruing or prepaid) since its lenders bear real risk; the base leg's
prepaid-ETH-only model (`DonLoan.sol:21-33`) under-prices risk capital.

### 4.3 The one-shot constraint (why this is now-or-a-migration)

`Don.setLienManager` is one-shot (`Don.sol:175-179`). The premium tranche needs to lien and seize the
same Don as the base loan → **it must live INSIDE the single lien-manager contract**. Three paths:

1. **Build it into DonLoan before #81.** Honest cost: this is not a function, it is a product —
   TWAP accumulator (+ the §6 desk redeploy to generate the series), auction module, segregated pot
   accounting, premium interest model, new invariant lane in the stress battery, attack-economics
   analysis. **Estimate: 3-5 weeks build + ≥3 full 3-agent audit rounds + a new fork-stress lane.
   This delays #81 by 1-2 months.** It also puts unproven price-liquidation code inside the contract
   whose headline is that it has none.
2. **Weld a thin `LienRouter` as the lienManager now**, which delegates lien/seize authority to one
   facility at a time behind a long timelock — keeps the door open for a premium-capable DonLoan v2
   later. Cost: the trust story degrades from "the lien power is pinned forever to one audited
   facility" (`Don.sol:172-174`) to "…behind a timelock an admin can re-point," which is exactly the
   rug-shaped surface the one-shot was built to close. Small code, large narrative/audit cost.
3. **Wait for stack v2** (a full redeploy + holder migration is already the acknowledged price of any
   loan change, `MAINNET-DEPLOY-CHECKLIST.md:66-68`). The premium tranche becomes the headline feature
   that *justifies* a migration, once mainnet has real trade history to feed a TWAP.

**"Zero bad debt" impact:** the claim becomes **"zero on the base layer — structurally, as before;
bounded-by-the-opt-in-pot on the premium layer."** True and defensible, but it is a different sentence,
and RISK-COMPARISON.md's clean `$0` column acquires an asterisk. See §7 on the marketing trade.

---

## 5. Lever 5 — Full market-value lending (rejected, for completeness)

Size the *whole* draw off a market price and liquidate by price. This is precisely the reference model
of `docs/RISK-COMPARISON.md` §1b, and its measured outcome is the §2 table: **20% / 60% / 90% of
principal lost on gap-down, deep-crash, and wipeout scenarios, plus 40% on a 48h keeper delay**
(`docs/RISK-COMPARISON.md:57-60`) — with the reference column *steelmanned* (no slippage, no
liquidator bonus, `:126`). It deletes both invariants the dregg circuit proves (`:131-135`), the
oracle-free property, and the entire reason RISK-COMPARISON.md exists. There is no design variant of
"lend against a number that can fall" that keeps the differentiator. **Rejected.**

---

## 6. The desk question — a floating ask ABOVE the floor-pin

Could `DonExchange` grow a market price above the floor to feed lever 4's TWAP?

**What the pin currently buys** (`DonExchange.sol:29-36,119-122`): one price, both sides, `= max(donPrice,
floor)`. Buy→redeem arb is strictly loss-making (invariant D, `DonSolvencyStress.t.sol:467-477`);
the desk can never be drained against a risen floor; the whale-drain scenario proves emptying the
inventory is strictly unprofitable (`:638-665`).

**Analysis of a floating ask:**
- **Buy side (ask floats up):** arb-safety *improves*. Buy at `ask ≥ floor` plus 8% fee, redeem at
  `floor` → loss grows with the premium. Invariant D's inequality only gets stronger.
- **Sell side is the danger:** if the *bid* ever floats above the floor, the desk overpays from its own
  reserve and can be drained by minting/buying-cheap-elsewhere and selling in. **The bid must stay
  pinned at `floor` (minus the 8%)** — the floor remains the buy-side backstop, exactly as today.
- **What actually breaks:** nothing structural — what breaks is *symmetry*. The desk becomes a real
  market-maker with a spread (`ask = max(floor, curve)`, `bid = floor`), where `curve` is
  inventory-based (sudoswap/NFTX-style: ask rises as the 2,222 float depletes). Pushing the curve
  costs real purchases at escalating prices plus 8% fees — a manipulable-but-expensive signal, which
  is the raw material a long TWAP needs.
- **The elegant coupling:** route each sale's **excess over the floor into `DonReserve.fund()`**
  (permissionless, `DonReserve.sol:67-71`). Every above-floor sale then *permanently raises the floor*
  — speculation on Dons mechanically converts into base-layer borrowing power for everyone. This is
  the strongest version of lever 1 and it makes attacking the TWAP self-defeating: the pump's cost
  partially becomes floor, which raises the attacker's own redemption backstop but also everyone
  else's, and it can never be pulled back out.

**Barrier:** `DonExchange` is fully immutable (constructor-set, `DonExchange.sol:70-98`) — a floating
desk is a **redeploy**. And note the float trap: the exchange has **no withdrawal path for inventory**
(only `seed` adds, `:131-138`; Dons leave only via `buy`/`snipe`, `:146-172`) — once the 2,222 float
is seeded, migrating to a desk v2 means buying every remaining Don out at price + fee. **So the desk
design is effectively also a pre-#81 decision** (or an accepted buy-out cost later).

---

## 7. Barriers summary

| Barrier | Bites which lever | Severity | Detail |
|---|---|---|---|
| No price oracle above the floor; flash-pump-then-borrow | 4 (and 6 as its feeder) | **Hardest problem in this doc** | No venue but the deliberately-pinned desk; TWAP needs a floating desk + weeks of history + attack-economics proof; underwriter-quoted sidesteps it at the cost of P2P UX |
| One-shot `Don.setLienManager` | 3, 4 | Hard deadline | `Don.sol:175-179`; anything touching DonLoan ships before #81 or costs a full-stack migration (`MAINNET-DEPLOY-CHECKLIST.md:66-68`) |
| Immutables: `ltvBps`, `liqThresholdBps`, fee splits, desk params, `donPrice` | 2, 1(splits), 6 | Hard deadline | `DonLoan.sol:82-86`, `DonExchange.sol:48-52`; checklist section A |
| Constructor risk-bounds: `ltv ≤ 7000` without a code change | 2 | Medium | `DonLoan.sol:110-111,180` — 80/90% are code+re-audit, not config |
| Desk float is unwithdrawable once seeded | 6 | Medium | `DonExchange.sol:131-138` — desk v2 after seeding = buy out the float |
| Risk-pot capital | 4 | Medium | Real $ESSEY must sit idle absorbing premium losses; treasury seed or underwriters who must be paid real interest |
| Narrative cost | 4 | Medium-high | "Zero bad debt" → "zero on base, bounded on opt-in" — see below |
| Audit burden | 3: +1 round · 4: ≥3 rounds + new stress lane · 2(≤7000): ~0 (swept) | Varies | Repo gate: 3 agents clean in the same round before any push |

**The marketing trade (lever 4), assessed:** RISK-COMPARISON.md's power is a `$0` column with no
footnotes (`:53-65`) and the one-liner "Essey never lends against a number that can fall" (`:145-149`).
A premium tranche keeps that sentence *true of the base layer* and the tranche is honestly opt-in,
segregated, and bounded — a story sophisticated partners will accept (it's a senior/junior structure).
But it costs the unqualified claim, and the doc's §5 already stakes credibility on full disclosure.
Verdict: survivable if and only if the tranche ships with its own RISK-COMPARISON-grade bounded-loss
proof (max loss = premiumPot, demonstrated in the stress battery). Without that artifact, don't ship it.

---

## 8. What speculative upside is actually being bought — who gets what

- **Borrowers:** everything in this doc is borrower-side. Lever 2 is a one-time step-up (draw 150k →
  210k at today's floor). Lever 3 makes the draw *track* the floor over time without recapitalizing.
  Lever 4 is the only lever where the draw tracks *hype* (market premium) — and only for borrowers who
  opt into a price-liquidatable slice. Note the borrowed asset is $ESSEY (`DonLoan.sol:35-41`); the
  borrower still carries $ESSEY→USDG FX on exit (`RISK-COMPARISON.md:127-130`).
- **Holders (non-borrowers):** levers 2/3/4 change **nothing** for them — no new claim on the reserve,
  no dilution, floor untouched. Lever 1 (and §6's excess-to-reserve) is the only holder-side upside:
  a faster-rising redemption floor. Premium-pot *underwriters* (lever 4) gain a new yield instrument
  and are the only party that can newly lose money — by explicit opt-in.
- **The protocol:** levers 1-3 add zero risk. Lever 4 concentrates all new risk into one capped pot,
  plus the tail risk that a TWAP-manipulation post-mortem taints the base layer's brand even though
  its solvency was never touchable.

---

## 9. Recommendation

**Pull, in order:**

1. **Lever 2 now — set `ltvBps = 7000` / `liqThresholdBps = 9000` in the #81 env.** It is the exact
   point the 24-combo sweep proved solvent (`DonSolvencyStress.t.sol:768,828`), it is config-only, it
   is a +40% draw on day one, and the zero-bad-debt claim survives verbatim. If the founder wants a
   dead-band for comfort, 6000/8000 is the fallback — but add that point to the sweep first. **This is
   THE decision that must land before #81; it is immutable and a miss cannot be corrected without a
   full-stack migration.**
2. **Lever 3 now — add `refinance()` to DonLoan before #81.** Small, floor-backed, preserves every
   invariant, one audit round, and it delivers the "my line grows" experience that is most of what a
   market-value lender actually feels like. Same deadline as lever 2 (the one-shot lien weld).
3. **Lever 1 immediately and forever — standing treasury policy** to route the 30% legs + royalties
   into `DonReserve.fund()`; optionally the treasury-splitter at deploy to make it mechanical.
4. **Lever 4 — do not ship in #81. Defer to stack v2, staged:**
   - *Phase A (can be pre-#81 if the desk is redeployed anyway, else v2):* the §6 hybrid desk —
     floating ask, floor-pinned bid, excess-over-floor → `DonReserve.fund()`. This alone amplifies
     lever 1 and starts producing the only honest price series above the floor.
   - *Phase B (v2, after months of real trade history):* premium tranche inside DonLoan v2 — 7-day
     TWAP, deposit-age gate, per-Don cap (≤50% of floor), global cap vs the segregated pot,
     auction-then-redeem waterfall, bounded-loss proof published next to RISK-COMPARISON.md.
   - Do **not** weld a re-pointable LienRouter just to keep this door open — it trades the trust
     model's cornerstone for optionality the v2 migration path already provides.
5. **Lever 5 — rejected** (§5); it un-writes RISK-COMPARISON.md.

**Honest bad-debt impact:** levers 1/2/3: zero — structurally identical to today. Lever 4: zero on
base, bounded by the opt-in pot on the premium slice (a true but weaker sentence). Lever 5: the
reference lender's 20-90% loss profile, i.e. the end of the differentiator.

**The single hardest technical barrier:** a manipulation-resistant on-chain price above the floor.
The system's own arb-proof desk pin (`DonExchange.sol:119-122`) means no such signal exists today, no
external oracle exists, and the canonical NFT-lending exploit (flash-pump-then-borrow) targets exactly
whatever signal gets built — compounded by the one-shot lien weld that forces any consumer of that
price to be designed into the loan contract before it exists.
