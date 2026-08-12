# Mainnet deploy checklist — Essey "Don" stack (task #81)

A **fill-in-and-go** operator checklist. The audits, the config manifest, and the go-live sequencing
already exist — this consolidates them into the single sheet you execute on deploy day.

- **Config values / external addresses:** [`docs/MAINNET-CONFIG.md`](./MAINNET-CONFIG.md) — the verified
  mainnet addresses + the Dons v3 env block (do not re-verify here; that doc is the source of truth).
- **Phase sequencing + gates:** [`docs/MAINNET-GO-LIVE.md`](./MAINNET-GO-LIVE.md) — this checklist IS Phase 6.
- **The deploy script:** `rh-chain/script/DeployDons.s.sol` — every constant below traces to it or to a contract.

> **The one thing to internalize:** the stack has a hard split between values that are **welded at
> construction** (Section A — wrong = redeploy the whole stack and migrate every holder) and values you can
> **tune any time after** (Section B — never block the deploy on these). Get Section A right; defer Section B.

---

## A. LOCKED-AT-DEPLOY — immutable / one-shot (must be right, or redeploy + migrate holders)

These are `immutable` in the contracts or set by a one-shot setter that reverts on a second call. **None can
be changed without redeploying the affected contract** — and because the stack is wired together by
construction pointers, redeploying one core contract cascades to a full-stack redeploy + holder migration.

### A1 — DonLoan immutables (`rh-chain/src/market/DonLoan.sol`, all `immutable`)

- [ ] `ltvBps = 5000` (50% max draw of live floor) — **LTV_BPS** in script
- [ ] `liqThresholdBps = 7000` (70%; enforced ≥ LTV + 20pp `MIN_RISK_GAP_BPS`) — **LIQ_THRESHOLD_BPS**
- [ ] `defaultGraceSeconds = 30 days` (calendar-default clock; bounds 7–90d) — **DEFAULT_GRACE**
- [ ] `liqTipBps = 100` (1% liquidator tip; max 500) — **LIQ_TIP_BPS**
- [ ] `ethFeeStockShareBps = 7000` (prepaid-ETH split: 70% → feeSink / 30% → treasury) — **ETH_FEE_STOCK_SHARE_BPS**
- [ ] `feeSink` + `treasury` addresses — **welded here** (see A3: feeSink trap)
- [ ] Behavior: **surplus-back-on-default** — `liquidate()` returns the equity above the debt to the
      borrower. Total-forfeiture would be a **code change**, not a param. (Section C decision.)

### A2 — DonExchange immutables (`rh-chain/src/market/DonExchange.sol`, all `immutable`)

- [ ] `swapFeeBps = 800` (8% buy/sell) — **SWAP_FEE_BPS**
- [ ] `snipeFeeBps = 1200` (12% snipe; enforced ≥ swapFee) — **SNIPE_FEE_BPS**
- [ ] `stockShareBps = 7000` (70% of each fee → feeSink, 30% → treasury) — **STOCK_SHARE_BPS**
- [ ] `donPrice` (price floor-minimum, `DON_PRICE`, default `300_000e18` $ESSEY) — the live price is
      `max(donPrice, reserve.floorPerDon())`, so this is only the day-one lower bound
- [ ] `feeSink`, `treasury`, `seeder` addresses — **welded here**

### A3 — The feeSink one-shot trap (THE deploy-day landmine)

`DonExchange.feeSink` and `DonLoan.feeSink` are **immutable**. There is **no `setFeeSink` on the exchange or
the loan.** `DeployDons` sets both to the **real DonFeeRouter only if the route env is fully wired**
(`WETH` **and** `ETH_FEED` **and** `USDG_FEED` **and** `SWAP_ROUTER` all non-zero → `routeWired = true`).
Otherwise both are welded to `treasury` as a "loud interim" — **forever, until a full redeploy.**

- [ ] **All four route env vars set** (Section D) so `DeployDons` builds the real `DonFeeRouter` in-script
      and passes it as the immutable `feeSink` to both the exchange and the loan. **This is the whole reason
      the fee-route infra is a pre-req (Section D), not a post-deploy step.**
- [ ] Confirm the deploy log does **not** print the `feeSink=TREASURY (interim)` warning. If it does, **stop
      and redeploy** — the testnet ran on the treasury-interim; mainnet must not.
- Note: the distributor's **mint-fee** sink (`DonDistributor.feeSink`) *is* re-pointable (`setFeeSink`), so
  the mint leg could be corrected later — but the exchange + loan legs cannot. Wire them right the first time.

### A4 — One-shot wiring (runs inside `DeployDons.deployAll`, in this order)

`DonFeeRouter` is deployed **first** (before exchange + loan) precisely so its address is the immutable
feeSink both receive at construction. Then the distributor pins the rest — each reverts on a second call:

- [ ] `distributor.initDon(don)` — one-shot; distributor becomes the Don's sole minter
- [ ] `distributor.setDonHook(bell)` → `Don.setHook` — one-shot (transfer hook = the Bell)
- [ ] `distributor.setBell(bell)` — one-shot (art-lock trusts the Bell's tier read; a re-pointable Bell = attack)
- [ ] `distributor.setDonLienManager(loan)` → `Don.setLienManager` — **one-shot. `Don.setLienManager`
      cannot be re-pointed, so the loan facility can never be swapped without redeploying the whole stack.**
      (The hard lesson: an upgrade to the loan = a full-stack redeploy + migrate.)
- [ ] `distributor.setFeeSink(sink)` + `distributor.setTreasury(treasury)` — set here (both re-pointable later)
- [ ] **Post-deploy, separately:** `distributor.setDonArt(DonArt)` → `Don.setArt` — one-shot; `tokenURI`
      is empty until it lands (Section E step 4)

### A5 — Other welded values

- [ ] `Don`: `maxSupply = 8888` (**MAX_SUPPLY**), `minter = distributor`, `vaultImplementation` — all immutable
- [ ] `DonDistributor`: `admin`, `reserveCap` (**RESERVE_CAP** = 2722: 500 team/partners + 2,222 AMM float),
      `rootTimelock = 2 days` (**ROOT_TIMELOCK**) — all immutable
- [ ] `DonReserve`: **fully adminless/immutable** — `essey`, `don`, and `backedSupply` (pinned to
      `maxSupply`, only ever decrements on redeem). No owner, no setter, no upgrade. Nothing to configure.
- [ ] `DonFeeRouter` immutables: `essey`, `usdg`, `weth`, `bell` (the USDG sink — **can never be
      redirected**), `admin`, feeds. (Its `router`/pool-fees/`minOutBps`/`keeper` are tunable — Section B.)
- [ ] `Guardian` (freeze-only multisig) — passed to `DonExchange` + `DonLoan` at construction (**GUARDIAN**).
      Freezes market activity in an incident; **cannot** touch funds. `DonReserve.redeem` is un-freezable
      (holders' guaranteed exit). Welded — pick the freeze multisig before deploy.

---

## B. TUNABLE-AFTER-DEPLOY — do NOT block the deploy on these

Every item here has a live setter. Start conservative, tune post-launch.

- [ ] **Interest coefficient** `ethPerFloorPerYearWad` — `DonLoan.setEthRatePerFloorYear(wad)` (treasury-only).
      **Deploy at `0` = free borrowing** (`ETH_RATE_PER_FLOOR_YEAR_WAD`); tune later for ESSEY→ETH drift only
      (it already floor-scales). Output is clamped to `MAX_PREPAID_ETH = 1 ether` regardless.
- [ ] **Mint fees** `rerollFee` / `customFee` — `DonDistributor.setFees(...)` (admin). *(But get them roughly
      right at deploy via env — see the Section C fee-resize note.)*
- [ ] **Team/stock split** `teamBps` — `DonDistributor.setTeamBps(...)`. Deploys at `0` = 100% of mint fees → stock.
- [ ] **Royalty %** — `distributor.setDonRoyalty(receiver, bps)`, capped at 10% (`MAX_ROYALTY_BPS = 1000`).
      Deploys at `ROYALTY_BPS = 500` (5%) to treasury.
- [ ] **Collection metadata** `contractURI` — `distributor.setDonContractURI(...)` (ERC-7572), empty until set.
- [ ] **Reserve funding** — `DonReserve.fund(amount)`, **permissionless, floor only ever rises.** Fund
      anytime; the day-one 300k floor needs 2,666,666,666 $ESSEY (30% of supply / 8888 cap).
- [ ] **Loan pot** — `DonLoan.fund(amount)` (permissionless) / `withdrawIdle(amount)` (treasury, idle only).
      Size is a founder call (Section C); resizable anytime.
- [ ] **WL root** — `distributor.proposeRoot(stage, root)` → `commitRoot(stage)` after the 2-day timelock →
      `setStageOpen(stage, true)`. Re-proposable per stage behind the timelock. `setPublicOpen(true)` opens
      the $10 custom mint.
- [ ] **Fee-router route** — `DonFeeRouter.setRoute(router, ethPoolFee, esseyPoolFee, minOutBps)` +
      `setKeeper(...)` (admin). **This is how you'd move the ETH leg to the 500-tier pool post-deploy** —
      see the Section C / D note on the baked `ethPoolFee=3000`.

---

## C. FOUNDER DECISIONS TO FILL IN

| # | Parameter (env / setter) | Recommended value + rationale / cost-of-getting-wrong | Founder's value |
|---|---|---|---|
| 1 | **TREASURY** multisig | The operator multisig. Receives the fresh 8.888B $ESSEY mint, the 30%-of-fees legs, idle-loan reclaim. **Welded into exchange+loan** (`treasury`). Wrong = full redeploy. | `________` |
| 2 | **GUARDIAN** multisig | Freeze-only multisig (exchange + loan). `0` = deploy immutable-with-no-freeze. Recommend a real cold multisig, distinct from treasury hot key. Welded. | `________` |
| 3 | **SEEDER** | Holds the 2,222 AMM float (`mintReserved` → `exchange.seed`). Welded as `seeder`. Recommend = multisig. | `________` |
| 4 | **Loan pot size** (`DonLoan.fund`, `LOAN_FUND`) | **Rec ≈ 266,666,666 $ESSEY (~3% of supply).** SeedDons default is 100M (rehearsal only — do not ship). Bigger = deeper lending; resizable anytime (tunable, not welded). | `________` |
| 5 | **REROLL_FEE_WEI** | **Rec `1600000000000000` (0.0016 ETH ≈ $3.01 @ $1,880).** Script default `0.00075` ≈ $1.41 is **53% under target** — must override. Re-price on deploy day (tracks ETH). Tunable post-deploy. | `________` |
| 6 | **CUSTOM_FEE_WEI** | **Rec `5300000000000000` (0.0053 ETH ≈ $9.97).** Script default `0.0025` ≈ $4.70 is **53% under** — must override. | `________` |
| 7 | **Interest coefficient** (`ETH_RATE_PER_FLOOR_YEAR_WAD`) | **Rec `0` (free borrowing at launch).** Tunable by treasury later. No downside to starting at 0. | `________` |
| 8 | **WL root + list** (`WL_ROOT`, stage 0) | The daodon WL root (`DeployDons` references `0x836f5ce5…`). **TravelSwap 250 allocation pending** — confirm the final list before computing the root. Tunable (re-proposable behind the 2-day timelock). | `________` |
| 9 | **Default behavior: surplus-back vs total-forfeiture** | **Rec: keep surplus-back** (current code returns equity-above-debt to the borrower on liquidation). Forfeiture = a **code change + re-audit**, not a config toggle. Decide before deploy. | `________` |
| 10 | **DON_PRICE** (exchange floor-min) | **Rec `300000e18`** (= the 300k floor at full reserve funding; script default holds). Welded `immutable`. Only the day-one lower bound; live price tracks the rising reserve floor. | `________` |
| 11 | **ETH-leg pool tier** (`ethPoolFee`) — see D/reconcile | **Rec `500`** (the 500-tier WETH/USDG pool is ~4.5× deeper than 3000). **Script bakes `3000`.** Either edit the script constant pre-deploy or retune via `setRoute` post-deploy. | `________` |

---

## D. MAINNET INFRA PRE-REQS (what the testnet lacked — needed BEFORE the stack deploy)

The real route infra must exist and be in the env **before** `DeployDons` runs, so it welds the real
`DonFeeRouter` as feeSink (Section A3). Addresses verified live in `MAINNET-CONFIG.md` (chainId 4663).

- [ ] **WETH** `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` — canonical; `SwapRouter02.WETH9()` agrees.
- [ ] **SWAP_ROUTER** `0xcaf681a66d020601342297493863e78c959e5cb2` — **SwapRouter02** (there is **no** classic
      SwapRouter on mainnet). ✅ **The Router02 selector fix has already shipped** — `DonFeeRouter.ISwapRouter`
      (and `StockConverter`) encode the Router02 `ExactInputSingleParams` **without `deadline`** (selector
      `0x04e45aaf`); `DonFeeRouter.flushEth/flushEssey` enforce the deadline themselves. No code change remains.
- [ ] **ETH_FEED** `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` — Chainlink "ETH / USD", dec 8, proxy address.
- [ ] **USDG_FEED** `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` — Chainlink "USDG / USD", dec 8, proxy address.
- [ ] **SEQUENCER_FEED = 0** — Robinhood Chain has no Chainlink sequencer-uptime feed (re-confirmed
      2026-08-11). `StaleFeedGuard` ships the check disabled + relies on the keeper heartbeat (disclosed).
      **Re-check on deploy day**; if one appeared, set it.
- [ ] **USDG** `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` — 6 decimals (confirmed). Drives `MIN_RING=10000000`.
- [ ] **CONVERTER + DEFAULT_PAYOUT** — no mainnet converter exists; **deploy the mainnet `BundleConverter`
      first** (real token+feed pairs from the `MAINNET-CONFIG.md` registry, USDG passthrough, real stock
      acquired to `seedReserve`), then fill `CONVERTER` and `DEFAULT_PAYOUT = conv.BUNDLE()`. `CONVERTER=0` =
      base-only (no stock payout) — not what mainnet wants.
- [ ] **ESSEY = 0** — deploy a **fresh** 8,888,888,888e18 `EsseyToken` minted to treasury (verified: no prior
      mainnet deploy). The ESSEY/USDG pool therefore **cannot pre-exist** — created post-deploy (Section E step 5).

> Paste the full env block from `MAINNET-CONFIG.md` → "Env block for `DeployDons.s.sol`" and fill the
> Section C placeholders. Do not hand-type addresses; copy them from that verified block.

---

## E. DEPLOY SEQUENCE (the ordered commands)

> **L2 gas gotcha:** Robinhood Chain under-estimates gas on `CREATE`s whose constructor makes an external
> call (the router/loan config-struct constructors). **Every `forge script … --broadcast` below needs
> `--gas-estimate-multiplier 300`** (the established value across this repo's mainnet-shaped scripts).

1. **Deploy the fee-route primitives / converter FIRST**
   - [ ] Deploy the mainnet **BundleConverter** (real pairs, USDG passthrough, `seedReserve` with real
         stock) → record `CONVERTER` + `DEFAULT_PAYOUT`. (WETH/router/feeds already exist on-chain — just
         verify + put in env. **Do NOT run `WireDonFees.s.sol` — it is testnet-only and deploys mocks;**
         `DeployDons` builds the real `DonFeeRouter` in-script from the env.)

2. **Deploy the stack** — `DeployDons.s.sol` with the full env set
   ```bash
   # ADMIN==broadcaster (one-shot wiring runs in-script). All Section C + D vars exported.
   forge script script/DeployDons.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
     --broadcast --gas-estimate-multiplier 300
   ```
   - [ ] Broadcaster == `ADMIN` (script `require`s it)
   - [ ] Deploy log shows a real `feeRouter` address (**not** `0x0` / the interim-treasury warning) — A3 gate
   - [ ] Record all 8 addresses (essey, distributor, don, reserve, bell, feeRouter, exchange, loan)

3. **Seed** — `SeedDons.s.sol` (fund reserve, fund loan pot, seed AMM desk, open mint)
   ```bash
   RESERVE_FUND=2666666666e18 LOAN_FUND=<Section C #4> SEED_COUNT=2222 WL_ROOT=<Section C #8> \
   forge script script/SeedDons.s.sol --rpc-url … --broadcast --gas-estimate-multiplier 300
   ```
   - [ ] Reserve funded → `floorPerDon` ≈ 300,000 $ESSEY
   - [ ] Loan pot funded to the founder size
   - [ ] 2,222 AMM float minted (in batches) + `exchange.seed` → inventory live
   - [ ] `proposeRoot(0, WL_ROOT)` fired; `setPublicOpen(true)` set (or defer public mint per go-live wave plan)

4. **Post-deploy wiring / go-live ops**
   - [ ] **Wire DonArt** — `distributor.setDonArt(DonArt)` (one-shot) + set its baseURI; `tokenURI` is empty
         until this lands. Also `setDonContractURI(...)` for the collection metadata.
   - [ ] **Create the ESSEY/USDG V3 pool** at the **3000 tier** (`esseyPoolFee=3000` the router is configured
         for) and seed protocol-owned liquidity — required before `flushEssey` can function (until then
         $ESSEY fees safely accumulate in the router).
   - [ ] **Commit the WL root** — `commitRoot(0)` after the 2-day timelock → `setStageOpen(0, true)`.
   - [ ] **Run the dregg solvency prover** against a live loan tuple (`DonLoan.loanTuple(donId)`) — prove
         `debt·10000 ≤ floor·ltvBps` under the deployed Groth16 verifier on a real open loan.
   - [ ] **Register the 5% royalty** (`ROYALTY_BPS=500`) on OpenSea / the marketplace collection page.

5. **Operational crons (Section F for the human setup side)**
   - [ ] **Feed-keeper** — refresh ETH/USDG (+ converter) feeds ahead of the ~25h staleness window
         (mainnet Chainlink feeds have real heartbeats; still monitor freshness + keeper liveness).
   - [ ] **Invariant-watcher** — floor non-decreasing, every open loan ≤ 50% of floor, fee splits landing
         70/30. Page on a breach.
   - [ ] **DonFeeRouter flush keeper** — `flushEth` (permissionless) + `flushEssey` (keeper-quoted) so fees
         become stock for staked Dons.

---

## F. NON-DEPLOY FOUNDER ACTIONS (adjacent — flag, don't block the chain deploy)

- [ ] **`RELAYER_PK` in Vercel env** — the privacy relayer (`/private` stealth-payment sweep) needs it set.
- [ ] **Claim Upstash** — the mint-combo reservation store (front-end rolls unused combos; on-chain enforces
      uniqueness, but the UI needs the reservation cache).
- [ ] **Install the feed-keeper cron** on the supervised host (with alerting; a dead keeper is an outage).

---

## Where the deploy script and the existing mainnet docs DISAGREE (reconcile before deploy)

1. **Mint fees — script defaults are stale.** `DeployDons` defaults `REROLL_FEE_WEI=0.00075`,
   `CUSTOM_FEE_WEI=0.0025` (sized for a ~$4,500 ETH assumption). `MAINNET-CONFIG.md` verified ETH ≈ $1,880
   and resizes to `0.0016` / `0.0053` ether. **The env MUST override the defaults** (Section C #5/#6). Re-price
   on deploy day.

2. **ETH-leg pool tier — script bakes 3000, config recommends 500.** `DeployDons` hard-codes
   `ethPoolFee: 3000` (it is **not** an env var). `MAINNET-CONFIG.md` decision #4 recommends the **500-tier**
   WETH/USDG pool (~4.5× deeper). To honor the recommendation either (a) edit the script constant before
   deploy, or (b) retune post-deploy via `DonFeeRouter.setRoute(...)` (it is tunable, not welded). **Decide
   which** (Section C #11). *(The ESSEY leg's 3000 tier is fine — it matches the pool you create in E step 4.)*

3. **SwapRouter ABI "BLOCKER" is stale — already fixed.** `MAINNET-CONFIG.md` BLOCKER #1 says a code change
   is required to drop `deadline` for Router02. **That fix has shipped** — `DonFeeRouter.ISwapRouter` and
   `StockConverter` already use the Router02 struct (no `deadline`, selector `0x04e45aaf`), and the router
   enforces the deadline itself. The config doc should be marked resolved; **no code change remains.**

4. **Loan pot size — no agreed number.** `SeedDons` defaults `LOAN_FUND=100_000_000e18` (labeled "rehearsal
   pot"); the founder rec is ~266.6M (~3%). These disagree by design — **the mainnet run must pass an explicit
   `LOAN_FUND`**; do not ship the rehearsal default.

5. **Converter must be deployed first, but no mainnet converter script exists yet.** `MAINNET-CONFIG.md` OPS
   #5 notes `DeployBundleConverter.s.sol` is testnet-shaped (mints mock stock). A mainnet-shaped converter
   deploy (real pairs + real `seedReserve` stock) is a **prerequisite** that produces `CONVERTER` /
   `DEFAULT_PAYOUT` for the Dons env — track it as its own gate, not an afterthought.
</content>
</invoke>
