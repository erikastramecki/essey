# Mainnet scope — Essey Stock-Token lending market

Scoping doc. Founder-ruled: the Stock-Token lending market (borrow USDG against real Robinhood
Stock Token collateral, AAPL/NVDA first) is a near-term mainnet priority. This maps the proven
reference implementation onto real assets on Robinhood Chain (chainId 4663) and enumerates the
reconciliation and the risks that only exist with real collateral.

Every claim carries a `file:line`. Paths are `essey-markets/…` (the reference impl, branch
`feat/ad1-batch` @ `b57a35c`, 46 commits ahead of `main`, 15 test suites) or `rh-chain/…` (the
public `essey` repo — canonical per the repo-consolidation ruling, and the mainnet destination).
Anything not grounded in code or a real on-chain fact is marked UNVERIFIED.

## Framing correction (verify, don't trust the brief)

The reference impl is FAR past "testnet with mocks". It already carries a wired
`RobinhoodMainnet` deploy profile (chainId 4663) with the real Chainlink feed set, real risk
parameters, and the real `uiMultiplier` USD valuation path. The mainnet work is mostly PORT +
RECONCILE + a small number of genuinely-new real-asset pieces (beacon check, swap adapter,
keepers) — not a rebuild. Two labels in the brief are wrong and are corrected below:

- `ConstantMultiplier.sol` is NOT a testnet throwaway and NOT the leverage swap adapter. It is a
  real `uiMultiplier` source for Ink's wrapped xStocks (`essey-markets/src/adapters/ConstantMultiplier.sol:7`,
  used at `essey-markets/script/DeployMarkets.s.sol:186`). On RH mainnet it is unused (RH Stock
  Tokens carry the ERC-8056 surface themselves — `multiplierIsToken=true`, `DeployMarkets.s.sol:87`).
- The leverage swap seam is `ISwapAdapter` (`essey-markets/src/interfaces/ISwapAdapter.sol:9`).
  No production implementation of it exists anywhere — see risk (d).

> **STATUS 2026-09-02 — THE PORT IS DONE. The paragraph below is HISTORICAL; do not act on it.**
> It described rh-chain before commit `75f90b0` ("feat(markets): mainnet Stock-Token lending —
> port EsseyPool + reconcile shared oracle guard", 2026-08-30) and is now false.
> VERIFIED by byte-comparing every `essey-markets/src/**.sol` against its `rh-chain/src`
> counterpart: **all 20 are IDENTICAL**, including the fork's then-uncommitted `EsseyPool.sol`
> (borrowMore/removeCollateral). `MarketHealthOracle`, `NoteArt`, `PoolFactory`, `EsseyMultiply`
> and `InkFeeds` are all PRESENT in rh-chain. rh-chain is now AHEAD of the fork: it carries four
> boundary tests the fork lacks (`EsseyMarkets.t.sol:127-134`, `EsseyPool.t.sol:168-204`,
> `RiskModules.t.sol:145-160` and `:336-357`) added by the audit rounds. §5's StaleFeedGuard
> migration is likewise COMPLETE — all 8 game call sites use the 5-arg API with a per-contract
> `FEED_HEARTBEAT = 86_400` (`BundleConverter.sol:68`, `StockConverter.sol:48`,
> `DonFeeRouter.sol:69`, `EsseyCases.sol:107`). The superseded copy was deleted in the same
> commit (`DeployLending.s.sol`, `DeployLendingRehearsal.s.sol`, `rehearse-borrow.sh`).
> **The reference fork `~/Developer/essey-markets` is archived and has nothing left to give.**
> Remaining lending work is deploy-config + the two deferred items (§4d Multiply adapter, §2
> beacon assert), NOT a port.

rh-chain today carries an OLDER lending copy (`EsseyPool.sol` 473 lines vs 704; `EsseyMarkets.sol`
317 vs 522; and it is MISSING `MarketHealthOracle`, `NoteArt`, `PoolFactory`, `EsseyMultiply`,
`InkFeeds`). The port direction is therefore `essey-markets → rh-chain`, replacing rh-chain's older
lending layer wholesale.

---

## 1. REUSE — chain-agnostic, port as-is pending re-audit

Copy from `essey-markets/src/` into `rh-chain/src/`. No logic change; the math is chain-independent.

| Contract | What it does | Anchor |
|---|---|---|
| `EsseyPool.sol` | Isolated ERC4626 lending core — one pool per collateral market (`:98`). borrow/borrowMore/repay/repayPartial/addCollateral/removeCollateral/liquidate/writeOff. Kink rate curve (`:199-205`), kink at 80% util (`:110`). | `essey-markets/src/EsseyPool.sol:40` |
| `EsseyMarkets.sol` | Risk registry: `proposeMarket`/`commitMarket` behind a 2-day `PARAM_TIMELOCK` (`:101`), decimal-normalized `collateralValue` (`:170-183`), `canBorrow`/`canLiquidate` gates, `MIN_RISK_GAP_BPS` = 2000 enforced in code (`:93`). | `essey-markets/src/EsseyMarkets.sol:32` |
| `CollateralReconciler.sol` | The adminBurn defense — a monotonic per-token survival index. See risk (a). | `essey-markets/src/CollateralReconciler.sol:40` |
| `Note.sol` / `NoteArt.sol` | Loan position as a transferable bearer ERC721; minted on borrow, burned on close (`Note.sol:36-46`). | `essey-markets/src/market/Note.sol:23` |
| `PoolFactory.sol` | Discovery-only registry; mirrors `markets.activePool` (`:41-46`). Holds no authority. | `essey-markets/src/market/PoolFactory.sol:26` |
| `LivenessOracle.sol` | Heartbeat liveness gate (stands in for the missing sequencer feed). Fail-closed after any gap (`:92-105`, `:112-117`). | `essey-markets/src/LivenessOracle.sol:26` |
| `MarketHealthOracle.sol` | AD-2 depth-derived borrow cap; zero liquidation authority by design. | `essey-markets/src/MarketHealthOracle.sol:20` |

`StaleFeedGuard.sol` (the NEW per-feed-heartbeat version) ports too, but it collides with the game
layer — see §5.

---

## 2. RESCOPE — logic survives; real-asset wiring already largely present

The oracle layer is not mocked in the reference impl. Nearly all of this is DONE; the gaps are the
beacon check and on-chain re-verification.

**Real Chainlink feeds — already curated (RH mainnet, chainId 4663).**
`essey-markets/src/RobinhoodFeeds.sol:10-18` pins 9 feeds, all `dec=8 heartbeat=86400s dev=0.5%`:
AAPL, TSLA, NVDA, MSFT, GOOGL, AMZN, META, SPY, QQQ.
- GLD / DJT / NFLX have NO feed here → those markets cannot be listed (no price source). VERIFIED
  (absent from the directory). Consistent with the brief.
- These are compile-time constants read directly by the `RobinhoodMainnet` profile
  (`DeployMarkets.s.sol:87-88`); collateral token addresses come from env (`:236`). UNVERIFIED that
  the feeds are live/correct at broadcast time — unlike the Ink profile, the RH profile does NOT
  re-verify feeds against env at deploy (`InkFeeds` does, `DeployMarkets.s.sol:132-140`). Mainnet
  gap: add a `cast`-based pre-broadcast liveness assert for the RH feeds.

**Per-feed heartbeat config — already set.** `RobinhoodMainnet` profile uses
`heartbeat=86400`, `maxStaleness=90000` (`RobinhoodFeeds.HEARTBEAT` / `RECOMMENDED_MAX_STALENESS`,
`RobinhoodFeeds.sol:20-21`; profile `DeployMarkets.s.sol:87-88`).

**`uiMultiplier()` USD valuation — already wired.** `collateralValue` prices
`uiAmount = rawAmount * uiMultiplier() / 1e18`, then normalizes decimals
(`essey-markets/src/EsseyMarkets.sol:181-182`). The mock equivalent it replaces is
`ScaledUIStockMock.uiMultiplier` (`essey-markets/src/testnet/ScaledUIStockMock.sol:19`). On RH
mainnet `multiplierSource[token] == token` (the RH Stock Token itself,
`DeployMarkets.s.sol:246` with `multiplierIsToken=true`).

**The "is-real-equity" test — TODAY it is uiMultiplier duck-typing, NOT the beacon.**
`proposeMarket`/`commitMarket` assert the multiplier source answers `uiMultiplier()` with a
nonzero value via a direct (no-try) call (`EsseyMarkets.sol:481-488`, rationale `:120`). There is
NO EIP-1967 beacon check anywhere in either repo (grep for `beacon`/`1967`/`e10b6f6b` in
`essey-markets/src` and `rh-chain/src` returns zero hits). If the founder wants the RH beacon slot
(`0xe10b6f6b275de231345c20d14ab812db62151b00`, UNVERIFIED — supplied by founder, not confirmed
on-chain) as the real-equity gate, that is NEW code — a propose/commit-time assertion that the
collateral's EIP-1967 beacon slot equals the known RH Stock Token beacon. Decision required:
keep uiMultiplier duck-typing, or add the beacon assert. Recommendation: add it — duck-typing
accepts any contract exposing a nonzero `uiMultiplier()`, which is a weak identity proof for real
money.

**Sequencer uptime feed — none on RH; runs on compensating controls.** `RobinhoodMainnet` passes
`seqFeed = address(0)` (`DeployMarkets.s.sol:87`), so `sequencerCheckDisabled == true`
(`StaleFeedGuard.sol:91-93`). The documented compensating controls are the 20pp risk gap and the
`LivenessOracle` keeper (`StaleFeedGuard.sol:79-83`, deploy banner `DeployMarkets.s.sol:200-206`).
Revisit if a real RH uptime feed appears.

---

## 3. REBUILD — testnet-only, discard for mainnet

- `essey-markets/src/testnet/MockFeed.sol` — Chainlink-shaped mock feed.
- `essey-markets/src/testnet/ScaledUIStockMock.sol` — mock Stock Token with the ERC-8056 surface.
- The `testnet` branch of the deploy script (`DeployMarkets.s.sol:163-167`, `:232-234`) — deploys
  the two mocks. The `RobinhoodMainnet` branch already bypasses it.
- `MockSwapAdapter` (`essey-markets/test/EsseyMultiply.t.sol:20`) — the ONLY `ISwapAdapter` impl in
  the tree; test-only. See risk (d) for why this is a blocker, not a throwaway.

NOT in this bucket (correcting the brief): `ConstantMultiplier.sol` is a real Ink-mainnet
component (§ Framing correction). It is simply unused on RH.

---

## 4. REAL-ASSET RISKS NOT PRESENT ON TESTNET — the critical section

### (a) Issuer `adminBurn` on collateral — HANDLED (bounded to bad debt, not a drain)

The RH Stock Token issuer holds `adminBurn(from, amount)` under `ADMIN_BURNER_ROLE` — a plain EOA,
no multisig/timelock, no pause/block check — able to destroy pool-held collateral
(`CollateralReconciler.sol:9-20`; the brief's premise, taken as VERIFIED-by-the-author on-chain,
not re-verified here). `CollateralReconciler` is exactly the handler:

- A monotonic per-token survival `collateralIndex` (`CollateralReconciler.sol:51-57`); a burn
  ratchets it down so total entitlement equals the surviving balance (`_reconcile`, `:97-122`).
- Positions snapshot the index at open, so a burn is shared ONLY among positions present when it
  happened; post-burn depositors recover full raw (`_effectiveCollateral`, `:81-91`).
- Every pool path reconciles BEFORE crediting/valuing, so it never lends against a burned balance:
  borrow `EsseyPool.sol:380`, borrowMore `:444`, repay `:478`, addCollateral `:531`, liquidate
  `:594`, writeOff `:648`.
- Health is judged on surviving collateral, so a burned position becomes MORE liquidatable, not
  stranded (`EsseyPool.sol:598`, test `EsseyPool.t.sol:352-357`).
- Pinned by tests: `EsseyPool.t.sol:269` (absorbed, repay still works), `:682`/`:1003` (total burn
  wipes cohort), `RiskModules.t.sol:324` (detected + recorded, must not revert),
  `Succession.t.sol:210`, `Isolation.t.sol` invariant handler `:306-310`.

Residual, accepted: a TOTAL burn zeroes the index and leaves the cohort un-borrowable
(`CollateralCohortWiped`, `CollateralReconciler.sol:62-70`) — the SAFE outcome. Mainnet need:
a keeper watching `CollateralShortfall` events (`:59`) that calls `disableMarket` on a detected
burn, plus the bad-debt `writeOff` path (`EsseyPool.sol:641`). The burn itself is an unpreventable
issuer power; the index converts it from a silent drain into a bounded, isolated bad-debt event.

### (b) Weekend / session-stale equity feeds (24/5) — HANDLED by design

- New borrows require an OPEN US session (`canBorrow` returns `inSession`,
  `EsseyMarkets.sol:222-244`). Session window is computed conservatively as the DST intersection
  14:30–20:00 UTC weekdays (`StaleFeedGuard.sol:169-186`), with a holiday guard requiring the last
  print to post at/after today's open (`:146-148`).
- Liquidation gates on FRESHNESS, not session (`_liquidationPriceGate`, `EsseyMarkets.sol:313-323`)
  — so weekday nights stay actionable while the price is inside `maxStaleness`.
- Weekend: the feed ages out ~25h after Friday's close → `priceOf` reverts `PriceStale`
  (`StaleFeedGuard.sol:136`) → BOTH borrow and liquidate refuse. The unliquidatable weekend gap is
  absorbed by the 20pp `MIN_RISK_GAP_BPS` buffer (`EsseyMarkets.sol:87-93`). This is the intended
  fail-closed posture; no mainnet change needed beyond the feed-liveness assert in §2.

### (c) Transfer gate + issuer powers (pause / block / clawback / upgrade) — PARTIAL

RH Stock Tokens are default-ALLOW blocklist (a fresh address can hold+move — VERIFIED per the
stealth-address work / memory), but the issuer can pause, block, clawback, or upgrade.

- Borrow-asset (USDG) pause: `accrue()` suspends interest pool-wide while USDG reports `paused()`
  — a borrower physically cannot repay through it (`EsseyPool.sol:214-260`, decoded as a raw word
  to avoid a Panic that would brick liquidation, `:257-259`).
- Collateral-token pause: interest is NOT forgiven pool-wide (only that token's holders are
  blocked), an accepted residual — the paused-collateral borrower keeps accruing
  (`EsseyPool.sol:220-226`).
- What breaks if collateral is paused/blocked mid-loan: `repay` still works (it moves USDG, then
  transfers collateral out — the collateral transfer would revert only for the borrower's own
  benefit). `liquidate` reaches `safeTransfer(seize)` of the paused collateral and REVERTS →
  liquidation of that market is FROZEN until unpause. Bounded by pool isolation to that one market.
  Clawback ≈ `adminBurn`, so it flows through the survival index (a). Upgrade is out of scope —
  an issuer upgrade that changes the token's semantics is un-modelable on our side.
- Mainnet need: monitor issuer pause/block state per collateral; `disableMarket` on a pause;
  accept the liquidation-freeze residual (isolation bounds it). No code change strictly required.

### (d) The Multiply swap leg needs a REAL DEX — BLOCKER, defer Multiply

`EsseyMultiply` requires a per-market `ISwapAdapter` to swap USDG ↔ Stock Token on both open and
close (`EsseyMultiply.sol:116-123`, `_buyStock` `:258-266`, `_swapExactIn` `:270-279`). Status:

- NO production `ISwapAdapter` implementation exists in either repo. The only impl is
  `MockSwapAdapter` (`essey-markets/test/EsseyMultiply.t.sol:20`), test-only.
- A Uniswap-V3-style DEX is ASSUMED live on RH: `StockConverter.sol:13` comment states "the
  Uniswap route live on Robinhood Chain" and it swaps via an injected `ISwapRouter.exactInputSingle`
  (`rh-chain/src/market/StockConverter.sol:39`, `:116`); `EsseyLadderSeeder.sol:9-11` implements
  V3 pool/factory/callback surfaces. But a code comment is not evidence — the router address is
  deploy-injected (`StockConverter.sol:61-72`), no verified on-chain router address is pinned
  anywhere, and $ESSEY itself has no AMM yet (memory).
- UNVERIFIED, and the hard dependency: (1) that a Uniswap-V3-style router is deployed on RH 4663,
  and (2) that a USDG↔AAPL / USDG↔NVDA pool exists with enough depth for a leverage loop. Neither
  is confirmable from the repo.

Recommendation: **defer Multiply from the first mainnet lending ship.** The base lending market
(borrow/repay/liquidate) has NO DEX dependency and can ship without it. If/when a router + liquid
pools are verified on-chain, a real `ISwapAdapter` is a thin wrapper over `exactInputSingle` (the
`StockConverter.sol:116` pattern already exists to copy). Until then, list no market in
`EsseyMultiply` (`listMarket` is admin-gated and append-only, `EsseyMultiply.sol:116`).

---

## 5. StaleFeedGuard / game reconciliation plan

**The collision.** The lending layer needs the NEW guard (per-feed heartbeat, 5-arg `_setFeed`,
`essey-markets/src/StaleFeedGuard.sol:209`). Four rh-chain game contracts inherit the OLD guard
(global `FEED_HEARTBEAT`, 4-arg `_setFeed`, `rh-chain/src/StaleFeedGuard.sol:195`). Bringing the
new guard into rh-chain breaks their compile: the arity changed AND the new guard REMOVED the
`FEED_HEARTBEAT` constant (`MIN_HEARTBEAT`/`MAX_HEARTBEAT`/`STALENESS_GRACE` remain,
`essey-markets/src/StaleFeedGuard.sol:50-56`).

**Every `_setFeed` call site (10, across 4 contracts) — all constructor-time or admin `listStock`,
all pass `maxStaleness = FEED_HEARTBEAT + STALENESS_GRACE = 86400 + 3600 = 90000`:**

| # | File:line | Context |
|---|---|---|
| 1 | `rh-chain/src/market/EsseyCases.sol:188` | constructor (base feed) |
| 2 | `rh-chain/src/market/EsseyCases.sol:223` | `listStock` |
| 3 | `rh-chain/src/market/BundleConverter.sol:114` | constructor (base feed) |
| 4 | `rh-chain/src/market/BundleConverter.sol:151` | `listStock` |
| 5 | `rh-chain/src/market/StockConverter.sol:81` | constructor (base feed) |
| 6 | `rh-chain/src/market/StockConverter.sol:92` | `listStock` |
| 7 | `rh-chain/src/market/DonFeeRouter.sol:129` | constructor (ETH feed) |
| 8 | `rh-chain/src/market/DonFeeRouter.sol:130` | constructor (USDG feed) |

(Also inheriting but NOT calling `_setFeed`: `rh-chain/src/RobinhoodFeeds.sol` is a library, and
`rh-chain/src/LivenessOracle.sol` / `EsseyMarkets.sol` are the OLD lending copy being replaced.)

**Behavior-preserving migration — exact map (old → new):**

```
OLD:  _setFeed(token, feed, FEED_HEARTBEAT + STALENESS_GRACE, decimals)   // maxStaleness = 90000
NEW:  _setFeed(token, feed, 86_400, 90_000, decimals)                     // heartbeat, maxStaleness
```

- `heartbeat = 86_400` (the old global `FEED_HEARTBEAT`).
- `maxStaleness = 90_000` (unchanged: old `FEED_HEARTBEAT + STALENESS_GRACE`).
- Bounds proof (exact preservation): new guard requires `maxStaleness ∈ [heartbeat, heartbeat +
  STALENESS_GRACE] = [86400, 90000]`; the ceiling test is `maxStaleness > heartbeat + grace`
  (strict, `essey-markets/src/StaleFeedGuard.sol:215`), so 90000 == ceiling PASSES. `heartbeat`
  bounds `[MIN 60, MAX 172800]` (`:212-213`); 86400 passes. Behavior is byte-identical at runtime
  (same `maxStaleness` compared at `priceOf`).
- Because the new guard has no `FEED_HEARTBEAT` constant, each contract must supply `86_400`
  explicitly. Cleanest: add one shared `uint32 constant FEED_HEARTBEAT = 86_400;` to the game side
  (e.g. a small `GameFeedConfig` lib or a per-contract local const) rather than reintroducing it
  into the lending guard (keeps the lending guard's per-feed philosophy clean). `STALENESS_GRACE`
  still lives in the new guard and can be reused.

All 8 calls are constructor-time or admin `listStock`; these contracts redeploy for mainnet
anyway, so this is a compile-fix + re-audit — no on-chain state migration. Re-run the game
contracts' own tests after the arity change.

---

## 6. Build + audit sequence

Ordered by dependency. **⚠ = the risky/unknown steps.**

1. **Port the REUSE bucket** (`essey-markets → rh-chain`): EsseyPool, EsseyMarkets,
   CollateralReconciler, Note/NoteArt, PoolFactory, LivenessOracle, MarketHealthOracle. Delete
   rh-chain's older lending copy in the same change (delete-don't-build-over). Low risk.
2. **Bring in the NEW StaleFeedGuard, then migrate the 4 game contracts** to the 5-arg API per §5.
   Prove behavior-preserving by the comment-stripped diff being value-identical at each call site,
   then re-run game tests. Low risk, mechanical.
3. **⚠ Real oracle wiring + beacon/identity decision:** confirm the `RobinhoodMainnet` profile,
   ADD a `cast`-based pre-broadcast feed-liveness assert for the RH feeds (§2), and rule on the
   beacon "is-real-equity" gate vs the current `uiMultiplier` duck-typing (`EsseyMarkets.sol:481`).
   Beacon address is UNVERIFIED — verify it on-chain before coding the assert. Risky: identity of
   the collateral is a money-correctness gate.
4. **AdminBurn operations:** stand up the keeper that watches `CollateralShortfall`
   (`CollateralReconciler.sol:59`) and calls `disableMarket`; wire the `resolver` + `writeOff` path
   (`EsseyMarkets.proposeResolver`/`commitResolver`, `EsseyPool.writeOff:641`). Code exists; this
   is ops wiring.
5. **⚠ Multiply swap adapter — or defer.** Verify on-chain whether a Uniswap-V3-style router and
   liquid USDG↔Stock pools exist on RH 4663 (§4d). If YES, build a real `ISwapAdapter` over
   `exactInputSingle`. If NOT (current state — UNVERIFIED), DEFER Multiply and ship base lending
   without it. Highest-unknown step; do not block base lending on it.
6. **Risk-param calibration** (per-market, at `proposeMarket`). Current reference values
   (`DeployMarkets.s.sol:274-282`, comment `:262`): LTV 50% (`ltvBps 5000`), liquidation 75%
   (`liqThresholdBps 7500`), liquidator bonus 5% (`liqBonusBps 500`), cap 250k USDG
   (`cap 250_000 * 10**assetDecimals`), max 20% of cap per position (`maxPositionBps 2000`). Rate
   curve = Kink mode: base 10%, slope1 5%, slope2 60%, kink 80%, reserve 10%
   (`RateModes.curve` `DeployMarkets.s.sol:43`, reserve arg `:241`; kink `EsseyPool.sol:110`). The
   25pp LTV→liq gap clears `MIN_RISK_GAP_BPS` 20pp. Founder to confirm or tune per name (AAPL vs
   NVDA volatility).
7. **3-agent audit gate** on the ported + migrated + new code (standing pre-push rule): all three
   agents clean in the same round; fix → re-run all.
8. **Mainnet deploy-config:** set `GUARDIAN` to a separate key (deploy warns if unset,
   `DeployMarkets.s.sol:171-176`), set `USDG` + `AAPL_TOKEN`/`NVDA_TOKEN` env, confirm RH profile,
   dry-run on a mainnet fork. Then `proposeMarket` (starts the 2-day timelock) → wait → `commitMarket`
   → `factory.register` → LivenessOracle heartbeat + resume grace → re-stamp feeds → session open
   (the deploy script prints this exact runbook, `DeployMarkets.s.sol:213-219`).
9. **Founder mainnet-deploy gate** — explicit, per-instance authorization. Acceptance/fork first;
   production only on an explicit say-so.

---

## Summary

- **REUSE:** 7 contracts (EsseyPool, EsseyMarkets, CollateralReconciler, Note+NoteArt, PoolFactory,
  LivenessOracle, MarketHealthOracle) — port as-is, replacing rh-chain's older lending copy.
- **RESCOPE:** oracle layer — mostly DONE (real RH feeds curated `RobinhoodFeeds.sol:10-18`, per-feed
  heartbeat set, `uiMultiplier` USD path live `EsseyMarkets.sol:181`). Gaps: a feed-liveness assert
  and the beacon-vs-duck-typing identity decision.
- **REBUILD (discard):** MockFeed, ScaledUIStockMock, the testnet deploy branch, MockSwapAdapter.
  (ConstantMultiplier is NOT a throwaway — real Ink component, unused on RH.)
- **Top 3 real-asset risks:** (a) `adminBurn` — HANDLED by the CollateralReconciler survival index,
  needs a monitoring keeper; (b) collateral pause/block — PARTIAL, freezes that market's liquidation
  until unpause, bounded by isolation; (c) Multiply's DEX dependency — a BLOCKER.
- **Mainnet DEX for Multiply:** none verified. Code assumes a Uniswap-V3-style route on RH
  (`StockConverter.sol:13`, router deploy-injected) but no address is pinned and no ISwapAdapter
  exists (only a test mock). UNVERIFIED → defer Multiply; ship base lending, which needs no DEX.
- **Game reconciliation:** 8 `_setFeed` calls in 4 contracts, all `maxStaleness=90000`; migrate to
  `_setFeed(t, f, 86_400, 90_000, dec)` — exact behavior preservation, compile-fix + re-audit only.
</content>
</invoke>
