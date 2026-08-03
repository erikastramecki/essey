# ECONOMICS — Seat/Market layer, modeled from StonkBrokers' measured data

Source: their live contracts on Robinhood Chain via Blockscout API, measured **2026-08-02** (raw data
memo in session scratchpad; headline numbers reproduced here). Reference design:
`docs/DESIGN-seats-market-layer.md`.

**The one caveat that governs everything: their protocol was ~16 days old at measurement** (core
deployed 2026-07-17). Every rate below is a *launch-spike* rate, not steady state. We model against
their day-16 numbers as the optimistic bound and their visible decay as the realistic shape.

## What we measured (their economy in numbers)

| Metric | Measured | Note |
|---|---|---|
| Protocol age | ~16 days | all rates compressed into launch window |
| $STONKBROKER holders | 12,336 | token reach ≫ NFT reach |
| NFT unique holders | **562 wallets** | the *real* community size behind the noise |
| NFTs actually circulating | ~2,190 (49.3%) | **the AMM vault itself holds 2,254 = 50.7% of supply** |
| Activated (on payroll) | 1,662–1,663 | = **~76% of circulating** (not 37% of total — wrong denominator) |
| Activation txs | 1,593 lifetime, ~29/day | re-activation churn is a recurring sink (clears on transfer) |
| NFT transfers | 8,617 lifetime, ~84/day | secondary motion continues post-hype |
| AMM trades | **~9–10/day at day 16**, sell-skewed 6:4 | trade-fee flow decays fast after launch |
| Clock In rounds | 747 (sampled round: 0.051 ETH ≈ $95) | AMM-fee-funded engine, small per-round by day 16 |
| Overtime rounds | 208 (sampled round: 0.443 ETH ≈ **$838**) | royalty-funded engine, **~9× bigger per round** now |
| Total distributed | ~$245k extrapolated (site claims $349k) | same order of magnitude; not fully enumerated |
| Tokens burned | 1.134M = **0.046% of supply** | the "50% burn" sink is narrative, not tokenomics-material |

## The four insights that change our design assumptions

1. **The effective market absorbed ~2,200 NFTs across ~560 wallets.** The 4,444 headline is float
   management: the AMM holds half the collection as inventory, released against demand. A "minted out"
   collection where the AMM is the majority holder *is the design*, not a failure.
2. **Launch-fee flow decays; royalties outlast it.** By day 16, the royalty-funded engine (Overtime)
   pays ~9× more per round than the trade-fee engine (Clock In). Any model that assumes launch-week AMM
   volume persists is wrong by an order of magnitude within two weeks.
3. **Engaged holders activate at ~76%.** The staking/payroll mechanic converts extremely well among
   people who actually hold the NFT — and because Tiers clear on transfer, the ~84 transfers/day create
   a *recurring* re-activation fee stream, not just a one-time sink.
4. **The burn is cosmetic at this scale** (0.05% of supply in 16 days). Keep the burn (it's a good
   story and a real if small sink) but never lead tokenomics messaging with it.

## Essey translation — defensible starting assumptions

**Collection size: 2,222 Seats** (placeholder pending final call). Grounding: their market — with a
hot chain, a free-mint history, and launch hype — absorbed ~2,200 into real wallets. Sizing our whole
collection to their *absorbed* number (not their headline) means the Exchange can genuinely sell through,
and scarcity works for us. The Exchange holds unsold inventory as float, price-releasing it — their model,
adopted deliberately. (The Bell's O(1) accumulator puts no technical cap on supply; this is purely an
economic choice.)

**Tier fees: set by the ladder rule at launch, in $ESSEY, against the live Exchange price.** Keep our
weight ratios (100/160/200/333). Calibrate fees so upgrade cost-per-weight-point ≤ (Exchange price +
Tier-1 fee) per weight-point — the verified StonkBrokers rule that keeps every tier rational. 50%
burn / 50% treasury, expectations set by insight #4.

**Exchange fees: 10% swap / 15% snipe on ETH notional (their proven schedule), TWAP-sandwich oracle.**
With cross-product coherence: any Note origination/exit fee must be ≥ the Exchange exit fee so lending
can't be a discount exit (their verified invariant, adopted).

**Bell pot run-rate — model three sources, honestly:**

| Source | Character | Day-16-calibrated illustration |
|---|---|---|
| Exchange trade fees | launch spike → fast decay | 10 trades/day × (0.1–0.15 × notional) — assume this decays ~90% from launch week, per their measured shape |
| Re-activation churn | recurring, transfer-driven | transfers/day × avg tier fee — but note: in our design (as in theirs) tier fees go burn/treasury, **not** the pot |
| **Loan interest share** | **recurring, TVL-driven — OUR structural edge** | reserve share of interest: e.g. $1M borrowed × 8% APR × 10% reserve share ≈ $8k/yr baseline, scaling linearly with TVL and immune to NFT-market mood |

Insight #2 is the strategic one: **their pot decays with NFT churn; ours can be fed by lending interest,
which persists as long as positions stay open.** StonkBrokers has no equivalent — their "recurring"
engine is marketplace royalties, which still depends on NFT trading. A lending protocol's fee base
compounds with TVL instead. This is the economic argument for the flywheel priority (payouts-in-stock →
borrow-against-stock): every loop through it grows the *durable* pot source.

## Explicit unknowns / to revisit

- Their exact USD total distributed (order-of-magnitude corroborated only) and historical drop-size
  decay curve (would sharpen the Exchange-fee decay assumption).
- ETH fee-inflow path (internal transfers not sampled) and where AMM ETH liquidity sits.
- Our $ESSEY launch pricing (Exchange price in $ESSEY) — tier fees derive from it; can't be set until
  token economics exist.
- All "illustrative" numbers above are labeled as such; nothing here is a revenue projection.
