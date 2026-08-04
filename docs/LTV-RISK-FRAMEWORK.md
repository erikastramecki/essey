# LTV & risk-parameter framework

How Essey sets loan-to-value (LTV) and liquidation thresholds safely — the methodology,
how the big lenders do it, and the concrete schema for our assets (esp. the RWA gap-risk
that makes tokenized equities special: a market-closed gap that an always-priced asset
never has).

## The one question LTV answers
> If the collateral price falls, can a liquidation still fully cover the debt before the
> position goes underwater?

LTV must leave enough headroom to survive **four things** between "healthy" and "bad debt":
1. **Price drop during the liquidation window** — the time to detect + execute a liquidation.
2. **Slippage** — the liquidator has to sell the collateral; thin liquidity = worse fills.
3. **Liquidation penalty/bonus** — the incentive paid to liquidators (they buy collateral at a discount).
4. **Oracle error/latency** — the price we act on may lag or be uncertain.

So there are **two** numbers per asset, and their gap is the safety:
- **Max LTV** (borrow LTV) — the most you can borrow when opening. e.g. 40%.
- **Liquidation Threshold (LT)** — the debt/value ratio that triggers liquidation. e.g. 50%.
- **LT > Max LTV** always, so a fresh max loan isn't instantly liquidatable. And **LT itself is
  set below the "stress-survivable" ratio** so a liquidation at LT still clears the debt.

## How other platforms do it

| Platform | Model | Who sets it | Key factors |
|----------|-------|-------------|-------------|
| **Aave** | Per-asset LTV / liq-threshold / liq-bonus; supply+borrow caps; isolation mode; e-mode for correlated pairs | Governance, advised by **risk firms (Gauntlet, Chaos Labs) running agent-based simulations** | volatility, on-chain liquidity/depth, oracle quality, correlation |
| **Compound** | Collateral factor (= LTV) per asset | Governance | same |
| **MakerDAO** | Min collateralization ratio per collateral type (inverse LTV), debt ceilings, stability fees, liquidation penalty | Governance + risk core units | volatility, liquidity, systemic risk |
| **Morpho Blue** | **Immutable per-market LLTV** chosen at market creation from a whitelist; markets are **isolated** | Market creator; curators choose which to fund | oracle + LLTV picked for the pair |
| **Kamino** | Per-asset LTV/LT + caps + e-mode | Governance/risk | volatility, liquidity, oracle |

**The common thread:** LTV is a **governance risk parameter**, not a live computation. The
number comes from a **stress/simulation model** of "how bad can this get in a liquidation,"
and it's **monitored and adjusted** as volatility and liquidity change. The best shops
(Aave via Gauntlet/Chaos) literally run Monte-Carlo simulations of price paths + liquidation
cascades to pick the caps and thresholds. Smaller/newer protocols start with a
**conservative rules table** and tighten/loosen from observation.

## The risk inputs (what feeds the number)

1. **Volatility** — the worst plausible drawdown over the liquidation window. Use a high
   percentile (e.g. 99th) of historical + implied vol. Higher vol → lower LTV.
2. **Liquidity / market depth** — how much can you liquidate without moving the price? Thin
   liquidity → high slippage → **lower LTV AND a supply cap** (never let one market's
   liquidation exceed what the market can absorb).
3. **Oracle quality** — Chainlink feed update frequency (heartbeat), staleness, and
   manipulation resistance. A slow/stale feed → more conservative. (We value collateral at
   `collateral balance x Chainlink price` under a staleness/session guard; see StaleFeedGuard.)
4. **Liquidation feasibility** — how fast can our keeper act? Slower → bigger buffer.
5. **Gap risk (THE RWA-specific one — see below).**

## The formula (how a threshold is derived)
For a stress drop `D` (a high-percentile adverse move over the liquidation window, **plus the
overnight gap for equities**), slippage `S`, and liquidation penalty `P`, the liquidation
threshold must satisfy: after the drop, the (discounted) collateral still covers the debt +
penalty. Intuitively:

```
LT  ≈  (1 − D − S) / (1 + P)          # threshold survives a stress drop + slippage + penalty
maxLTV  =  LT − margin                # a fresh loan can't be instantly liquidatable (margin ~10%)
supplyCap  ≈  k · (market depth that can be liquidated in one window)
```

Example (a large-cap equity): plausible stress drop incl. an overnight gap `D≈35%`, slippage
`S≈5%`, penalty `P≈8%` → `LT ≈ (1−.35−.05)/1.08 ≈ 0.55`. Round DOWN for safety → **LT 55%**,
**maxLTV ~45%**. (Then tighten for single-name / volatile names.)

## THE RWA DIFFERENCE — gap risk (our defining constraint)
A tokenized stock (AAPL / NVDA "Robinhood Token") can be held and moved on-chain around the
clock, **but the underlying share only trades 9:30–16:00 ET**. Overnight / weekend / on a
trading halt, the feed price is a **stale last-print** while the real value can gap on news
(earnings, a halt, a macro shock). An attacker can borrow at Friday's price right before a
Monday gap-down.

This is why **tokenized equities need conservative LTV** — the LTV must survive a
*discontinuous* overnight move, not just intraday drift:
- **Single-name stock** overnight gaps can be 10–30% on bad news → a large cushion (a
  correspondingly low LTV).
- A **diversified index** would gap far less and could carry a higher LTV — but the deployed
  collateral universe is single-name stock only (AAPL / NVDA), so single-name gap risk is the
  binding case.

Note: unlike an always-priced asset, tokenized stock has **real market-closed gaps** — the
underlying simply is not trading off-hours — which is exactly why the session guard exists.

Our oracle policy enforces the freshness side of this with **StaleFeedGuard**: a conservative
US-session window (14:30–20:00 UTC), a ~25h staleness bound (Chainlink heartbeat 86400s +
3600s grace), and a sequencer-uptime check so we never lend on a print from a down sequencer.
LTV handles the *magnitude* of the gap; the guard handles *not lending on a stale print*.

## Essey's schema (the per-asset table + how a new asset is parameterized)

**To onboard a market, classify it and set params from this table (conservative to start):**

The deployed collateral universe is tokenized **single-name stock (AAPL / NVDA "Robinhood
Token")**, borrowing **USDG** from the pool. Those are the in-scope rows; the remaining rows
are methodology sketches for classes we do not currently list (out of scope on Robinhood
Chain today).

| Class | Example | Max LTV | Liq threshold | Rationale |
|-------|---------|--------:|-------------:|-----------|
| Large-cap single equity (in scope) | AAPL, NVDA (Robinhood Token) | conservative | LT > maxLTV | gap risk + single-name vol; set from the stress formula |
| Index equity (out of scope) | — | higher | — | diversified → smaller gap, if ever listed |
| Volatile single equity (out of scope) | — | lower | — | high vol + gap |

**The onboarding checklist for a new asset's LTV:**
1. **Classify** (single-name equity / index equity, and — if ever listed — stable / treasury)
   → start from the row above. Single-name equity is the deployed case.
2. **Adjust for the specifics:** vol percentile, on-chain liquidity/depth (→ maybe lower + a
   supply cap), feed heartbeat/staleness behavior, and — for equities — the plausible
   **overnight gap** for that name (single-stock > index).
3. **Set LT from the stress formula**, then **maxLTV = LT − ~10% margin**.
4. **Set a supply/borrow cap** sized to liquidatable depth (don't let a liquidation exceed
   market depth in one window).
5. **Add a reserve/insurance buffer** target (a borrow-fee cut) for residual gap-tail risk.
6. **Review + monitor:** re-evaluate as vol/liquidity move; tighten fast, loosen slowly.

## Who enforces it (the Essey-specific safety)
The LTV *value* is our risk decision (the table + process above). The enforcement is
**on-chain in Solidity**: the borrow is admitted only if `debt <= collateral balance x
Chainlink price x LTV`, checked in `EsseyMarkets` / `EsseyBorrow` at authorization time,
after the StaleFeedGuard has cleared the feed (session window + staleness bound + sequencer
uptime). So the risk parameters are checked by the contract on every borrow, not asserted in
a config. Liquidation applies the liquidation threshold the same way (`EsseyLiquidate`).
There is no in-kernel ZK proof in the deployed lending path — enforcement is the Solidity
market code against the Chainlink feed.

## v1 vs. later
- **v1 (now):** the conservative rules table above + the stress-formula onboarding checklist +
  the oracle discipline. Deliberately conservative LTVs on the listed single-name stock (AAPL /
  NVDA) so we're safe while small.
- **Later (scale):** commission a Gauntlet/Chaos-style **simulation** of price paths +
  liquidation cascades to calibrate caps and thresholds precisely; add per-market isolation
  (Morpho-style) so a bad market can't contaminate the shared pool; a funded reserve.
