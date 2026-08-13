# Essey vs. a market-value-collateralized lender — bad-debt / downside comparison

**Audience:** a prospective partner evaluating Essey's lending core.
**Claim under test:** Essey's Don loan carries **structurally ~zero protocol bad debt**, where a conventional
market-value-collateralized ("reference") lender carries real, unbounded bad debt on fast or gapping
collateral crashes — and this is bought with a **quantifiable, honestly-stated cost** (smaller draws, no
market-value upside, pre-funded reserve capital).

This is an upside-vs-downside sheet, not marketing. Every number is reproducible from the sim in
§4; every mechanic is cited to the deployed contract that enforces it.

---

## 1. The two loan mechanics, precisely

### Essey — `DonLoan` against `DonReserve` (floor-collateralized, oracle-free)
- **Draw is a fixed fraction of a reserve FLOOR, not a market price.** `borrow()` disburses exactly
  `ltvBps` (50%) of `reserve.floorPerDon()` — the $ESSEY-denominated, reserve-backed floor of the Don.
  Debt and collateral share ONE unit ($ESSEY), so LTV needs no oracle, no session gate, no keeper.
  (`DonLoan.borrow`, `maxBorrow`.)
- **The floor cannot fall.** `DonReserve` is fund-only and pro-rata on redeem, so `floorPerDon()` is
  monotone non-decreasing by construction. Funding the reserve *heals* every open loan; nothing shrinks it.
- **Debt is FLAT.** Interest is prepaid in ETH at signing (a separate 70/30 leg); the $ESSEY principal is
  owed 1:1 forever with no accrual, no penalty phase. (`DonLoan.debtOf` — returns the principal, flat.)
- **Default is a CALENDAR event, not a price event.** Liquidation opens at `expiry + grace`. There is a
  ratio trigger (debt > 70% of the live floor) kept code-live as a dead backstop, but it is *structurally
  unreachable*: flat principal ≤ 50% of a non-decreasing floor can never climb to 70%. (`DonLoan.liquidate`.)
- **Settlement waterfall on default:** seize the liened Don → redeem it at the live floor → tip the caller
  (1%) → restore principal to the lendable pot → **surplus back to the borrower.** A defaulter loses the
  Don, never more than the equity above the debt.

**Why bad debt is ~0:** at liquidation, proceeds = `floorPerDon()_live ≥ floorPerDon()_origination ≥ 2 ×
principal`. Principal is always fully recoverable from the redemption; the protocol's loss term
`max(0, debt − recovery)` is identically zero. Solvency is provable from two on-chain invariants alone
(floor monotone; draw ≤ 50% of it) — this is the dregg solvency tuple the circuit commits.

### Reference — market-value-collateralized (the conventional RWA/NFT desk)
- Lends a fraction (LTV 50%) of the collateral's **floating secondary-market price** `P`.
- Liquidates when `debt > liqThreshold × P` (70%), by seizing and selling the collateral at the market.
- **Bad debt appears whenever the market value at the moment liquidation *executes* is below the debt** —
  which is exactly what deep, fast, or gapping crashes produce (the price leapfrogs the trigger, or a keeper
  is late, and the fire-sale clears below the loan principal).

---

## 2. Identical-stress bad-debt table

Both models originate the **same $500 debt** against a **$1,000 collateral** at **50% LTV** (identical
stress). We then crash the collateral's secondary-market value and measure **protocol bad debt** = the loss
the protocol eats after liquidation. The reference figure is **steelmanned**: no slippage and no 8%
liquidator bonus are charged against it (both would only make it worse — see §5).

| Scenario | Reference exec price | **Reference protocol loss** | **Essey protocol loss** | Why |
|---|--:|--:|--:|---|
| Orderly −30% (keeper liquidates near threshold) | $700 | **$0 (0%)** | **$0 (0%)** | Price still > debt at execution; both fully covered. Essey never even triggers (calendar, not price). |
| Fast −50% crash, executes at the crash floor | $500 | **$0 (0%)** | **$0 (0%)** | Reference at the knife-edge (`P_exec == debt`). Any slippage tips it negative (§5). |
| **Gap-down −60% through the threshold** | $400 | **$100 (20%)** | **$0 (0%)** | Price leaps past the 70% trigger; there was no moment to liquidate at the threshold. Essey's floor is unmoved. |
| **Deep crash −80%** | $200 | **$300 (60%)** | **$0 (0%)** | Even *instant* liquidation only recovers the market value; $300 of principal is unbacked. Essey redeems at the $1,000 floor. |
| **Wipeout −95%** | $50 | **$450 (90%)** | **$0 (0%)** | Near-total collateral loss becomes near-total protocol loss for the reference. Essey unaffected. |
| **Liquidation delay (keeper offline 48h)** | $300 | **$200 (40%)** | **$0 (0%)** | Liquidatable at ~$700 but executes at $300 after the delay. Essey has no price clock to miss. |

**Break-even:** the reference lender's bad debt begins the instant the collateral's market value at
liquidation drops below the loan principal ($500), and every further dollar of decline is 1:1 protocol loss.
**Essey has no such point** — the loan is sized to a reserve-backed floor that cannot fall, so principal is
always redeemable. Essey's loss column is `$0` in every scenario **by construction, not by luck.**

---

## 3. The honest cost — where Essey's conservatism *pays*

Zero bad debt is not free. A partner should see exactly what is traded for it.

### 3a. Smaller draws (no market-value upside)
Essey draws 50% of the **reserve floor**; the reference draws 50% of the **market price**. When the
collateral trades at a premium `m` over its floor (the normal case in a bull market — the market price
carries speculative premium the conservative floor deliberately excludes), the Essey borrower simply gets
less cash:

| Collateral market premium over floor | Reference draw | Essey draw | Essey borrower shortfall |
|--:|--:|--:|--:|
| 0% (floor == market) | $500 | $500 | $0 (0%) |
| +25% | $625 | $500 | **$125 (20% smaller)** |
| +50% | $750 | $500 | **$250 (33% smaller)** |
| +100% | $1,000 | $500 | **$500 (50% smaller)** |

The reference borrower also *re-levers as the market rises*; the Essey borrower only gains borrowing power
as the **floor** rises (reserve funding), never on market speculation. Essey is the wrong product for a user
who wants maximum leverage on a rising mark.

### 3b. Pre-funded reserve capital (protocol capital efficiency)
Essey's zero-bad-debt property is *paid for up front*: the protocol must lock $ESSEY in `DonReserve` to
stand the floor up (`RESERVE_FUND` → ~$300k-floor at the 8,888 cap). The reference model is capital-light —
it lends against a market price it does not have to pre-fund. **Essey converts protocol balance-sheet capital
into borrower solvency.** That is a deliberate, disclosed trade, not a free lunch.

### 3c. Prepaid interest + over-collateralized calendar default
- Interest is **prepaid in ETH** for the whole term at signing and never refunds — a borrower who repays
  early still paid the full term. (Default coefficient is 0 = free, but the mechanism charges upfront when on.)
- Default is a **calendar** event. A borrower who is *economically solvent* (debt far under the floor) but
  simply misses `expiry + grace` is still liquidated and **forfeits the Don and its Vault** — including any
  unclaimed stock dividends sealed inside it. A market-value lender's price-based trigger would leave that
  solvent borrower alone. Essey borrowers must service the calendar; this must be surfaced in the UI.

---

## 4. Reproducing the numbers

A throwaway simulation script (not committed) computes both columns from first principles:

```
ref_bad_debt(P_exec) = max(0, D − min(D, P_exec))          # D = 500, steelmanned (no slippage/bonus)
essey_bad_debt(F_live) = max(0, D − min(D, F_live))        # F_live ≥ F0 = 1000 (non-decreasing) ⇒ 0
```

The stress prices (`$700/$500/$400/$200/$50/$300`) are the collateral's market value at the moment the
reference lender's liquidation executes. Essey's `F_live` is pinned at the origination floor (the
worst case for Essey — in reality it can only be higher). Output matches §2 and §3 exactly.

---

## 5. Caveats and residual risks (fully disclosed)

- **The reference column is optimistic.** It charges the reference lender **no slippage and no 8% liquidator
  bonus.** With the 8% bonus (the value in `MAINNET-CONFIG.md`) plus fire-sale slippage, reliable liquidation
  needs `P_exec ≳ 1.08 × debt ≈ $540`; below that the reference losses in §2 are **larger** than shown, and
  the `−50% → $0` knife-edge row tips into a real loss. The comparison understates Essey's advantage.
- **Essey's "0" is a *protocol-solvency* statement, not "no one ever loses."** The Essey borrower can still
  lose the equity above their debt on a calendar default (§3c). And a borrower who took the loan to hold
  *dollars* bears $ESSEY→USDG FX on the way out (they borrowed $ESSEY, not USDG) — that is borrower FX, not
  protocol bad debt.
- **The 0 rests on two invariants holding:** `DonReserve.floorPerDon()` monotone (fund-only + pro-rata
  redeem) and every draw ≤ 50% of it. Both are enforced in the deployed contracts and are exactly the two
  facts the dregg solvency circuit proves. A future param change that raised LTV past 100% or made the
  reserve withdrawable would break the property — neither is reachable in the current code (the reserve has
  no withdraw path; LTV is immutable at deploy).
- **Different residual surface entirely:** Essey's `adminBurn`/`uiMultiplier` and stock-pausing hazards live
  on the *fee→stock payout* leg (the Bell/converter), **not** the loan. Those are handled by fail-open design
  and are validated on the real mainnet fork in `rh-chain/test/DonForkExtended.t.sol` (a paused AAPL falls
  open to USDG; a stale feed falls open to USDG — the claim never bricks and no funds strand). They do not
  touch loan solvency.

---

## 6. One-line takeaway

**Against a market-value lender, Essey trades borrowing *capacity* (smaller draws, no speculative upside,
pre-funded reserve) for the total elimination of *price-driven bad debt*: on the −60% gap, −80%, −95%, and
liquidation-delay scenarios the market-value lender eats 20–90% of principal while Essey eats nothing — because
Essey never lends against a number that can fall.**
