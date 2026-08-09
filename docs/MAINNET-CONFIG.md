# Mainnet config manifest — Robinhood Chain (chainId 4663)

The assembled mainnet-bound configuration (Phase 2 of `MAINNET-GO-LIVE.md`). Every external address is
verified against **live mainnet** unless marked TO-RESOLVE. This is the blueprint the `Deploy-mainnet`
script + the mainnet-config audit round build from. RPC: `https://rpc.mainnet.chain.robinhood.com`.

## External addresses (verified on-chain 2026-08-09)

| Role | Address | Verified |
|---|---|---|
| **USDG** (borrow asset, fee stable) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | "Global Dollar", **6 decimals** |
| **AAPL** Stock Token | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | 18-dec, `uiMultiplier()=1e18`, pausable, not paused |
| **NVDA** Stock Token | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | 18-dec, `uiMultiplier()=1e18` |
| **TSLA** / **SPY** | `0x322F…03b2d` / `0x117c…4C0C` | (future markets) |
| Deny-list registry | `0xe10b6f6b275de231345c20d14ab812db62151b00` | default-open (verified Phase 0) |
| Chainlink equity feeds (9) | `src/RobinhoodFeeds.sol` | 86400s heartbeat / 0.5% deviation; regenerate w/ `script/fetch-feeds.mjs` |

**Stock-token privileged roles are EOAs (out of our control — Robinhood's):** `ADMIN_BURNER_ROLE`
`0x957b…74d4`, `MULTIPLIER_UPDATER_ROLE` `0x9290…8143`, `TOKEN_PAUSER_ROLE`, `MINTER_ROLE`, `DEFAULT_ADMIN`.
Collateral can be burned / rescaled / paused at any moment — this is the hazard `CollateralReconciler`
(per-token index + live `uiMultiplier` re-read) and the borrow-asset pause check defend against.

## TO-RESOLVE before deploy

- **Dice entropy** (mainnet VRF for the Degen case) — address + interface. Testnet uses `MockEntropy`.
- **Operator multisig** — the admin/treasury/seeder/bankroll holder (Phase 4). Everything below assigns to it.
- **Sequencer-uptime feed** — could NOT be located on mainnet (Phase 0). `StaleFeedGuard` ships the sequencer
  check DISABLED and relies on the `LivenessOracle` keeper heartbeat instead. Either locate the feed
  (ask `chain-developers-group@robinhood.com`) or ship on the keeper and disclose (accepted).

## Deploy config / parameters

- **FeeRouter wiring (CORRECTED after the mainnet-config audit — B1):** the FeeRouter routes exactly ONE
  token (USDG) and has no rescue, so it must **NEVER** be the `treasury` of an emitter that also sends $ESSEY
  there — that $ESSEY would be stranded forever. Cases/Degen/Bell send $ESSEY (case price, tier fee) to
  `treasury`. Corrected wiring:
  - Deploy `FeeRouter(usdg, bell, bankroll, ops, 6000, 2000)` → 60% Bell / 20% bankroll / 20% ops. Keeper flushes.
  - **Exchange:** `treasury = FeeRouter`, `boosterShareBps = 0` → its 100%-USDG fee flows through the router
    (the Exchange's $ESSEY stays in its two-sided reserve, never touches `treasury` — safe).
  - **Cases / Degen:** `treasury = MULTISIG` (holds the $ESSEY case price), `boosterShareBps = 10000` → 100%
    of their USDG fee → the Bell pot directly (revenue-share; no bankroll/ops carve for these two).
  - **Bell** tier activation: $ESSEY → 50% burn / 50% `treasury = MULTISIG`.
  - Net: the 60/20/20 split applies to Exchange trade fees (the primary engine); Cases/Degen USDG fees are
    100% revenue-share to the Bell; all $ESSEY sinks land in the multisig. No token is ever stranded.
- **Payout choice:** deploy the converter with a **USDG passthrough** (`isSupported(USDG)=true`, identity) +
  `Bell.defaultPayout = BUNDLE` (stock default, USDG opt-out) — the decided per-Seat payout choice.
- **Lending:** `EsseyMarkets(sequencerFeed=<disabled/keeper>, liveness, admin=multisig, assetDecimals=6)`;
  `EsseyPool(usdg, markets, base=1000, s1=0, s2=0, reserve=2000, bellSink=bell, reserveTreasury=multisig,
  bellShareBps=5000)`. Markets: LTV **35%** / liqThreshold **55%** / bonus **8%** / **20pp gap**
  (`MIN_RISK_GAP_BPS`), cap per market, `collateralDecimals=18`, `feedDecimals=8` (cross-checked at
  propose+commit against the real token/feed — fix #3). **New pool layout** (the #2/#5 fixes).
- **LivenessOracle:** `(keeper, guardian, maxHeartbeatAge=30m, resumeGrace=30m, gapThreshold=15m)` — the
  #8-guarded config. Keeper hot key ≠ guardian cold key.
- **Timelock:** `PARAM_TIMELOCK = 2 days` (constant) — market activation waits 2 days after propose.

## Deploy sequence (greenfield)

1. $ESSEY token · Seat NFT · SeatArt · MintDistributor.
2. Bell (converter-wired, `defaultPayout=BUNDLE`) · BundleConverter (with USDG passthrough) · SeatReserve.
3. **FeeRouter** → then Exchange / Cases / Degen with `treasury=FeeRouter, boosterShareBps=0`.
4. LivenessOracle · EsseyMarkets · EsseyPool (new layout). proposeMarket(AAPL/NVDA) → commit after 2 days.
5. Seed: Seat inventory + $ESSEY reserve, converter stock reserves, bankroll, pool USDG liquidity.
6. Assign all admin/treasury/seeder/bankroll roles to the **multisig**; verify no EOA retains control.
7. Smoke-test every path with tiny real amounts (see `MAINNET-GO-LIVE.md` Phase 6).

## Config-level risks (for the audit + disclosure)

- **6-dec USDG is real for the first time** (testnet used an 18-dec mock). Local tests use a 6-dec MockUSDG;
  the mainnet-config audit round is verifying every contract's decimals handling end-to-end.
- **Sequencer check disabled → keeper substitute.** A dead keeper degrades to "liquidations off" (safe), but
  a live keeper during a sequencer outage is the exposure the audit is scoring.
- **24h feed heartbeat** — a price can be up to 24h stale and still "fresh"; the session/holiday gating +
  the 20pp gap absorb this, but it's the accepted overnight/weekend blindness.
- **adminBurn / multiplier EOA** — unmitigated on-chain (Robinhood's key); priced into LTV + disclosed.

## Mainnet-config audit round — findings + disposition

The round (3 lenses: 6-dec USDG · feeds/sequencer/roles · wiring/Dice/multisig) surfaced the following;
each is closed by a code fix, a config correction, or an accepted+disclosed disposition.

| Finding | Sev | Disposition |
|---|---|---|
| `assetDecimals` not cross-checked vs the real asset | MED | ✅ **code fix** — pool-constructor invariant (`1503f90`) |
| Scheduled-`uiMultiplier`↔feed desync borrow window | MED-HIGH | ✅ **code fix** — `canBorrow` refuses borrows within 1h of a pending `effectiveAt` (`676c205`) |
| No on-chain liveness gate on `canBorrow` | MED | ✅ **code fix** — `canBorrow` now gates on `liquidationsAllowed()` (`676c205`) |
| Admin can swap a live market's feed | HIGH | ✅ **code fix** — feed is append-only on `commitMarket` (`676c205`) |
| **B1** `treasury=FeeRouter` strands $ESSEY | BLOCKER | ✅ **config fix** — corrected wiring above (Exchange→router; Cases/Degen/Bell $ESSEY→multisig) |
| **B2** Degen reserve seeded by minting mock stock | BLOCKER | ⚠️ **deploy TODO** — mainnet must acquire real stock to `seedReserve` (a `Deploy-mainnet` seeding step; degen fail-safe-reverts until seeded) |
| Mainnet `Deploy.s.sol` ships zero rates | MED | ⚠️ **config** — set the intended curve at deploy: `base=1000 (10% APR), reserve=2000 (20%)`, `bellShareBps=5000` |
| Entropy provider defaults to `0xDACE` | LOW | ⚠️ **deploy** — pass the real Dice `ENTROPY_PROVIDER`; entropy design itself confirmed sound |
| Stale liveness comments in 2 scripts | LOW | ✅ **fixed** (`Deploy.s.sol`, `DeployLending.s.sol`) |
| Bell funding keeper-dependent (`boosterShareBps=0` on Exchange) | LOW | ops — run a `FeeRouter.flush()` keeper |
| Early-close (#6) · deny-list default-open | LOW | accepted + disclosed (see `OUTSTANDING.md`) |

**adminBurn protection confirmed SOUND** by the audit (the collateral index does its job). **Entropy design
confirmed SOUND** (provable-solvency reservation before the roll, commit-reveal correct, reclaim valve).

- **Feeds MUST be the Chainlink AggregatorProxy address, never a raw aggregator.** The market feed is now
  append-only (a rug-edge fix), so a market can't migrate its feed. Chainlink rotates the underlying
  aggregator behind a stable proxy; configuring the proxy keeps the market alive across rotations, whereas a
  raw aggregator that's later retired would strand the market (stale price → unliquidatable → bad debt).
  Verify `RobinhoodFeeds.sol` holds proxy addresses. (Deploy discipline; the feed-swap attack is the worse
  hazard, so append-only + proxy is the correct combination.)

## Gate

**Code side: MET.** Two fix iterations + a final **3-clean mainnet-config audit round** on the hardened code
(6-dec USDG · sequencer/feeds/roles · wiring · desync state-machine · fresh skeptic — all CLEAN); 382/382 tests
green. Every code finding closed impossible-by-construction or with a symmetric guard + tests. Accepted,
disclosed residuals: the issuer/feed reprice-timing gap (absorbed by the 20pp gap), the disabled sequencer
check (keeper substitute), the adminBurn/multiplier EOA hazard, early-close (#6).

**Remaining = deploy-time config (Phase 6, not code)** + **human gates:** Degen real-stock seeding, the mainnet
rate curve, the real Dice `ENTROPY_PROVIDER`, feeds-as-proxy — all baked into the `Deploy-mainnet` script; then
Phase 4 (multisig) + Phase 3 (keepers) + securities-counsel sign-off → Phase 6 deploy + smoke-test.
