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

- **FeeRouter wiring:** deploy `FeeRouter(usdg, bell, bankroll, ops, 6000, 2000)` → 60% Bell / 20% bankroll /
  20% ops; then deploy each fee emitter (Exchange/Cases/Degen) with `treasury = FeeRouter` and
  `boosterShareBps = 0`, so 100% of fees flow through the router. Supervised keeper calls `flush()`.
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

## Gate

The **mainnet-config audit round** (3 adversarial lenses: 6-dec USDG · feeds/sequencer/roles · wiring/Dice/
multisig) is running against this config. 3-clean-same-round is the true mainnet gate. Then Phase 4 (multisig)
+ Phase 3 (keepers) + counsel sign-off → Phase 6 deploy.
