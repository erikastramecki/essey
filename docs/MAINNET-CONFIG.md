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

## Dons v3 mainnet config (verified 2026-08-11)

Every address below was re-verified against live mainnet (`https://rpc.mainnet.chain.robinhood.com`,
`cast chain-id` → **4663**) on 2026-08-11, read-only. Nothing was trusted from memory or docs alone.
Both mainnet `broadcast/*/4663/` dirs contain **dry-run only** — nothing of ours is deployed on mainnet;
the whole Dons stack (incl. $ESSEY and the converter) deploys greenfield.

### Env block for `DeployDons.s.sol` (paste + fill the two placeholders)

```bash
# --- identities (FOUNDER MUST SUPPLY — placeholders) ---
export ADMIN=<MULTISIG>          # broadcaster must equal ADMIN (one-shot wiring runs in-script)
export TREASURY=<MULTISIG>       # receives the fresh 8.888B $ESSEY mint
export SEEDER=<MULTISIG>         # receives the 2,222 AMM-float mintReserved

# --- tokens ---
export ESSEY=0                   # 0 = deploy a FRESH 8,888,888,888e18 EsseyToken (verified: no prior mainnet deploy — broadcast/ has dry-runs only)
export USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168   # verified: decimals()=6, symbol=USDG, name="Global Dollar", code present; matches docs.robinhood.com/chain/contracts
export WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73   # canonical per docs.robinhood.com/chain/contracts; verified: symbol=WETH, 18-dec, totalSupply≈29,336 ETH, AND SwapRouter02.WETH9() returns this exact address

# --- converter (deploy the mainnet BundleConverter FIRST, then fill these) ---
export CONVERTER=<from mainnet BundleConverter deploy>    # no mainnet converter exists (dry-run only) — deploys fresh, USDG passthrough + defaultPayout=BUNDLE per the decided config
export DEFAULT_PAYOUT=<conv.BUNDLE() from that deploy>

# --- USDG-denominated params (6 decimals CONFIRMED on-chain) ---
export MIN_RING=10000000         # 10e6 = 10 USDG in reward (USDG) decimals — matches the script default; the ONLY USDG-denominated env (ladder fees + DON_PRICE are 18-dec $ESSEY, unaffected)

# --- Chainlink feeds (both from Chainlink's own directory JSON, both verified live) ---
export ETH_FEED=0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9   # "ETH / USD", dec=8, $1,880.45, updatedAt 643s before check (heartbeat 86400s)
export USDG_FEED=0x61B7e5650328764B076A108EFF5fa7282a1B9aD2  # "USDG / USD", dec=8, $1.00005587, updatedAt ~4.8h before check
export SEQUENCER_FEED=0          # re-confirmed 2026-08-11: Robinhood Chain is NOT on Chainlink's L2 sequencer-uptime list, and the RH feed directory (56 feeds) has no uptime feed

# --- Uniswap v3 (official Uniswap deployment for chainId 4663) ---
export SWAP_ROUTER=0xcaf681a66d020601342297493863e78c959e5cb2  # SwapRouter02 — verified: code present, factory()=0x1f7d…2EfA, WETH9()=canonical WETH.  ⚠️ ABI BLOCKER below.

# --- ETH-denominated fees (RESIZED for real ETH price — see Gas/params) ---
export REROLL_FEE_WEI=1600000000000000    # 0.0016 ETH ≈ $3.01 @ $1,880.45 (script default 0.00075 = $1.41 — 53% under the ~$3 target)
export CUSTOM_FEE_WEI=5300000000000000    # 0.0053 ETH ≈ $9.97 @ $1,880.45 (script default 0.0025 = $4.70 — 53% under the ~$10 target)

# --- defaults confirmed fine as-is ---
# RESERVE_CAP=2722, DON_PRICE=300000e18 ($ESSEY, 18-dec) — script defaults hold
```

### Verification table

| Item | Address | Proof run (all `cast … --rpc-url https://rpc.mainnet.chain.robinhood.com`) | Result |
|---|---|---|---|
| Chain | — | `cast chain-id` | 4663 |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | `decimals()` / `symbol()` / `name()` / `cast code` | **6**, USDG, "Global Dollar", code present |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | `symbol()`/`decimals()`/`totalSupply()` + cross-check `SwapRouter02.WETH9()` | WETH, 18, ≈29,336 ETH wrapped; router agrees → canonical |
| ETH/USD feed | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | `decimals()`, `description()`, `latestRoundData()` | dec=8, "ETH / USD", $1,880.45, 643s fresh |
| USDG/USD feed | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` | same | dec=8, "USDG / USD", $1.00006, ~4.8h fresh |
| UniswapV3Factory | `0x1f7d7550b1b028f7571e69a784071f0205fd2efa` | `cast code` + `SwapRouter02.factory()` | code present; router agrees |
| SwapRouter02 | `0xcaf681a66d020601342297493863e78c959e5cb2` | `cast code` + bytecode selector scan | code present; has `0x04e45aaf` (Router02 `exactInputSingle`), **lacks `0x414bf389`** (classic) |
| WETH/USDG 500-tier pool | `0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a` | `factory.getPool` + `liquidity()` + token balances | live; ≈820 WETH + ≈1,004,441 USDG (deepest) |
| WETH/USDG 3000-tier pool | `0xa9188730Fe85Be88ad499D7d52B099e800fB0334` | same + `slot0()` | live; ≈248 WETH + ≈221,649 USDG; slot0 price ≈ $1,878 ≈ feed ✓ |
| Sequencer uptime feed | none | Chainlink L2-uptime list + full RH feed directory (56 feeds) | Robinhood Chain absent from both → `SEQUENCER_FEED=0` stance holds |

**Mainnet stock-token registry for the converter `listStock` sequence** — canonicity proven on-chain, not
by explorer labels: every token below is a beacon proxy whose EIP-1967 beacon slot reads the SAME beacon
`0xe10b6f6b275de231345c20d14ab812db62151b00` (the registry the already-verified AAPL points to), all
`decimals()=18`, `uiMultiplier()=1e18`, `paused()=false`, checked 2026-08-11. Every paired feed read
dec=8 + fresh-within-heartbeat via `latestRoundData()` the same day:

| Stock | Token (verified) | Feed (verified fresh) |
|---|---|---|
| AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` ($304.92) |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` ($218.00) |
| TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | `0x4A1166a659A55625345e9515b32adECea5547C38` ($332.61) |
| SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | `0x319724394D3A0e3669269846abE664Cd621f9f6A` ($772.32, 20.1h — inside the 24h heartbeat) |
| MSFT | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` ($502.55) |
| GOOGL | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | `0xF6f373a037c30F0e5010d854385cA89185AE638b` ($343.73) |
| AMZN | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` ($272.28) |
| META | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | `0x7C38C00C30BEe9378381E7B6135d7283356D71b1` ($599.46) |
| QQQ | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` ($718.93) |

All 9 `RobinhoodFeeds.sol` addresses also match Chainlink's directory JSON exactly (proxy addresses,
86400s heartbeat, 0.5% deviation — the feeds-as-proxy rule holds).

### Gas/params sanity

On-chain ETH/USD is **$1,880.45** (not the ~$4,500 assumed when the script defaults were set; the
3000-tier pool's own slot0 price cross-checks at ≈$1,878). Script defaults therefore undershoot ~53%:
`REROLL_FEE_WEI=0.00075 ether` = **$1.41** (target ~$3) and `CUSTOM_FEE_WEI=0.0025 ether` = **$4.70**
(target ~$10). The env block resizes them to 0.0016 / 0.0053 ether (≈$3.01 / ≈$9.97). Re-price on
deploy day — these track ETH.

### BLOCKERS / DECISIONS

1. **BLOCKER — SwapRouter ABI mismatch (code change required).** Mainnet has only **SwapRouter02**
   (+ UniversalRouter); no classic SwapRouter is deployed. `DonFeeRouter.ISwapRouter` **and**
   `StockConverter` encode the classic `ExactInputSingleParams` **with `deadline`** (selector
   `0x414bf389`) — proven absent from the deployed router bytecode (which carries Router02's
   `0x04e45aaf`). As written, **every `flushEth`/`flushEssey`/converter swap reverts on mainnet.**
   Fix: drop `deadline` from the struct (Router02 shape) in both contracts — and if deadline
   enforcement is wanted, wrap via Router02 `multicall(deadline, …)`. Re-audit the touched surface.
2. **FOUNDER — admin/treasury/seeder multisig address** (placeholders in the env block). Broadcaster
   must be ADMIN for the one-shot wiring.
3. **OPS — ESSEY/USDG pool cannot pre-exist** ($ESSEY deploys fresh). Post-deploy go-live step: create
   the ESSEY/USDG **3000-tier** V3 pool (the `esseyPoolFee=3000` the DonFeeRouter is configured for)
   and seed protocol-owned liquidity **before** the keeper's `flushEssey` leg can function; until then
   $ESSEY fees simply accumulate in the router (safe, no loss).
4. **DECISION — ETH leg pool tier.** Script wires `ethPoolFee=3000`, but the **500-tier** WETH/USDG
   pool is ~4.5× deeper (≈$1.0M vs ≈$0.22M USDG-side). Recommend `ethPoolFee=500` (admin-retunable
   post-deploy, but better set right at deploy).
5. **OPS — mainnet converter deploy.** `DeployBundleConverter.s.sol` is testnet-shaped (mints mock
   stock, deploys MockFeeds). The mainnet run needs: real token+feed pairs from the registry table
   above, the USDG passthrough, `spreadBps` decision, and **real stock acquired to `seedReserve`**
   (the standing B2 finding). Deploy converter first → its `CONVERTER`/`BUNDLE` fill the Dons env.
6. **Sequencer feed: still none** (re-checked Chainlink's L2-uptime list + the full 56-feed RH
   directory on 2026-08-11) — ship `SEQUENCER_FEED=0` with the disclosed keeper substitute. Re-check
   on deploy day; if one has appeared, StaleFeedGuard supports it and mainnet should use it.
7. **Fee resize** (item above) — founder sign-off on 0.0016/0.0053 ether; re-price on deploy day.
