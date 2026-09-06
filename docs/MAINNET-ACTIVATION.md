# Mainnet Activation — every flow, flagged

**Directive (founder, 2026-08-30):** *every flow Essey has must be scoped for MAINNET
activation with LIVE stocks / collateral running through the platform.* No flow stays
testnet as an end-state. This doc flags all of them; deep per-flow scopes live in their own
docs (linked). See [[essey-mainnet-only-directive]].

## Universal mainnet conditions (apply to EVERY stock/collateral-touching flow)
Each flow below must satisfy all that apply before it activates on mainnet (4663):
1. **Real RH Stock Tokens** (not mocks) — AAPL/NVDA and any others, gated by the non-forgeable
   beacon check (`0xe10b6f6b275de231345c20d14ab812db62151b00`), priced via `uiMultiplier()`
   (balance·uiMultiplier·price, never raw balanceOf).
2. **Real Chainlink feeds** — 8-dec, but 24/5 (weekend/session-stale); GLD/DJT/NFLX have NO
   feed. Every flow that reads a price must fail-closed out-of-session, not liquidate/settle on
   a stale mark.
3. **Issuer powers on real stock** — adminBurn (can destroy tokens at any address), pause,
   block, clawback, upgrade. Every flow HOLDING real stock must handle collateral vanishing or
   freezing mid-flow (bad-debt / haircut / skip-and-retry).
4. **Real stablecoin (USDG) on mainnet** — the likely gating dependency across flows. If no
   real USDG exists on 4663, that blocks shielded-USDG, lending, converters, and payouts alike.
   [VERIFY — flagged in the shielded + lending scopes.]
5. **Real gas** — no faucet; users fund their own wallet.
6. **Shared oracle guard** — the mainnet StaleFeedGuard (per-feed heartbeat) must be reconciled
   across the 4 game converters AND lending (behavior-preserving). See lending scope §5.
7. **3-agent audit of the mainnet CONFIG** (contracts may be testnet-audited, but real-asset
   assumptions + config are not) and a **founder-gated deploy** (the founder runs every mainnet
   deploy; never self-deploy).

## Flow register (status + what mainnet activation needs)

| # | Flow | Route / contracts | Chain today | Mainnet-activation needs | Scope |
|---|------|-------------------|-------------|--------------------------|-------|
| 1 | **Base layer — $ESSEY reserve** | /treasury · EsseyToken, EsseyReserve | **LIVE mainnet** | DONE (adminless, real-equity reserve). Ongoing: fee accretion, treasury deposits. | live |
| 2 | **Shielded / private transfers** | /private · Stealth{Announcer,Registry,Pay}, Shielded{Pool,PoolGate,Verifier}, ShieldedSupply, ShieldedStock ×2, Poseidon | testnet (46630) | Deploy shielded set to mainnet; real USDG/AAPL/NVDA; funded mainnet relayer; adminBurn haircut on REAL shielded stock; re-audit config; re-wire /private; drop testnet framing. | [MAINNET-SHIELDED-SCOPE.md](MAINNET-SHIELDED-SCOPE.md) *(in progress)* |
| 3 | **Stock-Token lending** | /lend · EsseyMarkets, EsseyPool, oracle layer, EsseyMultiply | **ported into `rh-chain`; NOT DEPLOYED on any chain.** `/lend` UI rewired to mainnet 4663 with an honest not-deployed state (`lending.ts:30` is the one activation switch) | ⚠️ **Gate G-LEND at ZERO — `built-not-audited`** (Update 17.1; the old "3 clean rounds" claim is retracted as unevidenced). Then: real feeds + beacon (**beacon VERIFIED on chain 2026-09-02**); adminBurn on collateral; risk calibration; 3 clean rounds on a real 4663 fork with the report published; harness; founder deploy. **Multiply DEFERRED** — no DEX/adapter on 4663. | [MAINNET-LENDING-SCOPE.md](MAINNET-LENDING-SCOPE.md) *(in progress)* |
| 4 | **Don mint** | /builder · MintDistributor, DonMintSplitter, DonDistributor | testnet | Real mint payment (USDG and/or fiat via CoinVoyage PayKit); real proceeds routing to reserve/treasury. **Controlled beta-mint phasing SCOPED** → [DONS-BETA-MINT-PHASING.md](DONS-BETA-MINT-PHASING.md) (reuse existing WL/stage/timelock mechanism; no new build). | [DONS-BETA-MINT-PHASING.md](DONS-BETA-MINT-PHASING.md) *(beta-mint phasing)* |
| 5 | **Don trade (buy/snipe/sell)** | /market · EsseyExchange | testnet | Real settlement asset; real $ESSEY market (no AMM yet — dependency). | NEEDS SCOPE |
| 6 | **Bell — stock payouts** | /bell · Bell, BundleConverter | testnet | Pays REAL stock: real converter feeds (session/staleness), real stock inventory, adminBurn exposure on held stock. | NEEDS SCOPE |
| 7 | **Cases** | EsseyCases | testnet | Opens cases for REAL stock; StaleFeedGuard reconcile; real stock inventory + adminBurn. | NEEDS SCOPE |
| 8 | **Degen (multiplier gacha)** | /degen · EsseyCasesDegen | testnet | Real entropy (Dice, not MockEntropy); real stock/share settlement; RTP solvency on real assets. | NEEDS SCOPE |
| 9 | **Converters** | StockConverter, BundleConverter | testnet | Real Chainlink feeds, real Stock Tokens, StaleFeedGuard migration (shared with lending). | folds into #3/#6 |
| 10 | **Quests / whitelist** | /start · QuestRegistry, QuestLens | testnet | Real onboarding/whitelist gating for the paid-invite mainnet model. | NEEDS SCOPE |
| 11 | **Recurring buy / DCA** | RecurringBuy | testnet | Real asset auto-stack; real feeds; real funding. | NEEDS SCOPE |
| 12 | **Fee / tokenomics** | FeeRouter, DonFeeRouter | not deployed | 60/20/20 revenue-share on real fees; buys real equities into reserve. Ships with mainnet. | see [[essey-fee-model-mancer]] |
| 13 | **Game economy (Scrip → real)** | game currency across all Don flows | testnet Scrip | Remap Scrip → real stock/collateral allocation (game-economist task); the biggest cross-flow rework. | NEEDS SCOPE (economist) |

## Cross-flow gating dependencies (resolve early — they block multiple flows)
- **Real USDG on mainnet** — blocks #2, #3, #6, #11 if absent. [VERIFY]
- **A real DEX/AMM on RH mainnet** — blocks #3 (Multiply) and #5 (a real $ESSEY market). Uniswap V3 is
  live on 4663 (factory `0x1f7d…2efa`, verified) → **$ESSEY launches V3-first** (V3-first vs Pons ruled
  2026-08-30: [MAINNET-AMM-LAUNCH-SCOPE.md §9](MAINNET-AMM-LAUNCH-SCOPE.md)). **Pons launchpad
  (factory `0x7eD5…EC7e`) CANNOT host the existing $ESSEY** — it only mints its own curve-bound tokens,
  so it is not a launch venue for the already-deployed clean token.
- **StaleFeedGuard reconciliation** — blocks #3, #6, #7, #9 sharing one guard.
- **adminBurn handling pattern** — needed by every real-stock-holding flow (#2 stock, #3, #6, #7, #8).

## Not moved by this directive
- Mainnet DEPLOY stays the founder's explicit per-instance gate — prepare audit-clean +
  deploy-ready, hand over exact commands, never self-deploy.
- Public blog/posts still need founder sign-off before publishing.

## Update 2026-08-30 — scope results in

**#3 Lending — scope DONE ([MAINNET-LENDING-SCOPE.md]).** Reference impl (essey-markets
feat/ad1-batch) is further along than assumed: it carries a real `RobinhoodMainnet` (4663) deploy
profile, real Chainlink feeds, real risk params, real `uiMultiplier` USD path. Work is PORT +
RECONCILE (essey-markets → rh-chain), not rebuild. adminBurn HANDLED (CollateralReconciler survival
index, ~10 tests; needs a monitoring keeper). Next gate: build/port + guard reconcile → 3-agent audit.
- **Multiply DEFERRED** — needs a mainnet DEX/router that is NOT verified to exist on 4663, and no
  production `ISwapAdapter` impl exists. Base borrow/repay/liquidate needs NO DEX → ships without it.
- **Beacon "is-real-equity" gate** — not present today (uses `uiMultiplier()` duck-typing). Beacon
  address `0xe10b6f6b…` is UNVERIFIED (founder-supplied). Do NOT hard-assert until confirmed on-chain.
- **Guard reconcile** — 8 `_setFeed` sites across EsseyCases/BundleConverter/StockConverter/
  DonFeeRouter; behavior-preserving `_setFeed(t,f,86_400,90_000,dec)` + a shared const; compile-fix +
  re-audit, no state migration.

**#2 Shielded — scope running; how-to draft ready** at `docs/DRAFT-shielded-howto.md` (mainnet-framed,
holds until shielded contracts are on mainnet). Live-page edit was correctly reverted.

**FOUNDER DEPENDENCIES surfaced (likely the real critical path):**
- Confirm a **real USDG** token on RH mainnet 4663 (blocks shielded-USDG, lending, payouts). [VERIFY]
- Confirm a **real DEX/router + USDG↔Stock liquidity** on 4663 (blocks Multiply, a real $ESSEY market).
- Confirm the **beacon address** `0xe10b6f6b…` on-chain (needed to harden the equity-identity gate).
- Provide a funded **mainnet relayer signer** for gasless shielded withdrawals (founder-held key).

**PM:** `essey-deployment-manager` agent created to own this register + the gate ladder going forward.

## Update 2026-08-30 (2) — shielded scope in ([MAINNET-SHIELDED-SCOPE.md])

**#2 Shielded — scope DONE. Minimal live-USDG-transfer path is ONE deploy** (Poseidon2 +
Groth16Verifier + EsseyPoolGate + EsseyShieldedPool → real USDG); no relayer needed (self-submit at
fee 0). Real USDG on mainnet is VERIFIED: `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, **6 decimals**,
"Global Dollar" (docs/MAINNET-CONFIG.md:11). BUT three real blockers stand between here and a safe
live transfer — do NOT deploy real funds until they clear:

1. **HARD BLOCKER — trusted setup.** The deployed zkey is single-contributor
   (DeployShieldedPool.s.sol:20-21, pool/README.md:41-43) → **proofs are forgeable, the pool is
   drainable with real money.** Requires a multi-party ceremony + regenerated verifier/zkey/wasm
   before ANY mainnet value. This is a cryptographic must, not a config tweak.
2. **Config — `openMode=true` baked into the deploy script** (DeployShieldedPool.s.sol:41) while the
   gate itself says it MUST be false in production (EsseyPoolGate.sol:16,60). Fix before deploy.
3. **USDG admin surface UNVERIFIED** — the plain-USDG pool has NO haircut (EsseyShieldedPool.sol:
   169-177); if real USDG can freeze/blacklist/burn the pool address, funds brick with no defense.
   MUST read the USDG token code before shielding real USDG. (Shielded STOCK already handles issuer
   adminBurn via pro-rata haircut — EsseyShieldedStock.sol:162-166.)

Frontend also: USDG is 6-dec but hardcoded 18 (private.tsx:13-14, live.ts:277); and `/private` needs
its own mainnet client (the reserve.ts:21-23 pattern) — the shared `NET` can't be flipped to 4663.

**Net:** a live shielded USDG transfer is a 1-command deploy AWAY from working, but is NOT SAFE for
real funds until the trusted-setup ceremony is done, `openMode` is false, and USDG's admin powers are
read. Recommend: do the ceremony + config-harden + USDG read → re-audit → founder deploy.

## Update 2026-08-30 (3) — USDG admin surface VERIFIED on-chain
Read RH mainnet directly (RPC reachable; blockscout is Cloudflare-gated). USDG
`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`: decimals **6** (confirmed — frontend's hardcoded 18 is
a bug), symbol USDG, **owner `0xcFA0388f5ddf905FdC08c45c716C15Dc10A14C6F`**, **pausable** (paused()=false
now), **per-address freezable** (`isFrozen(address)` exists → issuer can freeze a specific address, e.g.
a pool), and **an upgradeable EIP-1967 proxy** (impl `0x68184c449e1a8f34fa18d289737129fd27b66f8f` → issuer
can change ANY behavior, incl. add burn/clawback). Consequence for shielded USDG (#2): the plain-USDG
pool has NO haircut (EsseyShieldedPool.sol:169-177), so a pause/freeze/upgrade against the pool address
could brick or seize funds with no pro-rata defense. This is a real, named issuer risk to accept or
mitigate before shielding real USDG — distinct from the adminless base-layer reserve. Shielded STOCK
already has an adminBurn haircut; shielded USDG does not.

## Update 2026-08-30 (4) — two gates RESOLVED on-chain + lending SHIPPED; viability review in
See [MAINNET-VIABILITY-REVIEW.md] for the full ranked review.

- **#3 Lending — BUILT + PUSHED (public), NOT AUDITED (gate 0 of 3).** Ported to rh-chain, StaleFeedGuard reconciled
  (behavior-preserving), 1254→1267 tests, THREE consecutive clean 3-agent rounds (economics /
  access-oracle / mutation). Committed 75f90b0 + pushed to public essey (127f985). REMAINING: the
  founder's mainnet DEPLOY (funded deployer + admin/guardian roles), + optional beacon assert, +
  Multiply adapter. Contracts public; NOT deployed (no borrow live yet).
- **BEACON gate — VERIFIED (was UNVERIFIED).** `0xe10b6f6b275de231345c20d14ab812db62151b00` is a live
  contract; AAPL's EIP-1967 beacon slot reads exactly it. The is-real-equity identity assert is now
  codeable across #2-stock/#3/#6/#7/#8. (Adding the assert to a live contract needs its own audit round.)
- **MULTIPLY "no DEX" — REFUTED (was BLOCKER).** Uniswap V3 SwapRouter02 `0xcaf681…5cb2` live;
  USDG↔NVDA 500-tier pool is DEEP (~$3.6M USDG + ~$2.2M NVDA); USDG↔AAPL thin (~$39k). Multiply needs
  the swap ADAPTER + a one-line SwapRouter02 `deadline`-drop ABI fix (that same fix also unblocks Bell/
  Cases/Degen payouts + the DonFeeRouter flush — a cross-flow unlock).
- **Sluice (V4-hook liquidity mgmt)** — PARK / near-term-conditional. Not a lending-supply solution;
  we'd build our OWN V4 afterSwap tax hook (route the $ESSEY pool-side tax → buy equities into reserve),
  not adopt Sluice. Hard dep: Uniswap V4 PoolManager on 4663 is UNVERIFIED. Ship the $ESSEY AMM V3-first;
  add a taxed V4 hook later only if V4 is confirmed on-chain.

## Update 2026-08-30 (5) — ACTIVE NEAR-TERM PUSH: flywheel accretion + shielded-game BETA

Two coordinated programs are now the active push. Both new docs are analysis/planning only.

**Base-layer correction (register #1 confirmed, config doc stale):** `EsseyReserve` +$ESSEY ARE live on
mainnet — reserve `0xd970Ca726188e38982906Ae2284D2bdB80205A7b`, $ESSEY `0x315790B57C19141B34C4653a91b096Cf3f071610`,
ops/treasury `0x93e6e42CcC676614FB3635b0983d60F35dDE4B9E` (verified 2026-08-29, [[essey-reserve-deposit-address]];
`claimBase` 8.888e27, `EXIT_FEE` 500, adminless). `MAINNET-CONFIG.md:121` ("nothing deployed") is STALE — it
predates the 08-29 Foundation deploy; the game/lending/shielded FRONTENDS remain testnet-only, which is a
separate fact.

**A. Flywheel accretion — [MAINNET-FLYWHEEL-MATH.md].** `fund(token,amount)` (`EsseyReserve.sol:93`) raises
`floorOf = reserveOf·1e18/claimBase` (`:203-205`) pro-rata for every holder; 5% exit fee is permanent
over-collateralisation (`:53,147`), and the immutability IS the trust. Key number: every **$1M of lifetime
accretion = +$0.0001069 redeemable floor per $ESSEY, forever, monotone-up** (spread across the full 8.888B
genesis supply → a long-game ratchet, ~$100M NAV for a 1¢ floor). **Nothing auto-calls `fund()` and no
pool-tax hook exists (grep-verified)** — accretion is operational today. The AUTO version (pool-side tax →
buy equities → `fund()`) is COUPLED to the AMM and launches **in lockstep with AMM seeding, not before**
(V4 `PoolManager` on 4663 UNVERIFIED; V3 SwapRouter02 `0xcaf681…5cb2` is live). Recommendation:
**operational-first accretion (keeper/manual `fund()`), lock-later-only-if-ever** — do NOT bake the rate into
an immutable `FeeRouter`-style splitter (`FeeRouter.sol:17,35-36` splits are set-once; it has no reserve leg).

**B. Shielded-game BETA — [SHIELDED-GAME-BETA-PLAN.md].** Real gameplay on mainnet; shielding treated as
PRODUCTION (a BETA, not a demo). Player wins SMALL real stock (existing payout path, plain transfers
`Bell.sol:341`) and shields it on `/private` — **Option A: payout-routing + UX, NO game-contract change**
(the player generates their own note; `EsseyShieldedStock.transact` requires gate-approval + a self-held note
commitment, `EsseyShieldedStock.sol:124-137`). Founder ruled the **FULL multi-party ceremony**, and **ONE
ceremony** on `transaction2` secures ALL three shielded pools (shared `PoolVerifier2` zk core,
`EsseyShieldedStock.sol:11-12,8,55,178`); `SolvencyVerifier` is a separate circuit, out of scope. Go-live
order: (1) ceremony → regen `PoolVerifier2`+zkey/wasm; (2) deploy shielded set to mainnet (real
USDG/AAPL/NVDA, **openMode=FALSE**, `setApproved` players) → 3-agent config audit → FOUNDER deploy; (3) wire
game payout → shielded stock (essey-web-designer); (4) game on mainnet (don-economist economy scope). Issuer
freeze/adminBurn = FOUNDER-ACCEPTED (haircut already built, `EsseyShieldedStock.sol:162-166`).

**Blocked-on / next actions:**
- **don-economist** — `docs/GAME-MAINNET-ECONOMY-SCOPE.md` does NOT exist yet (confirmed 08-30); it is the
  pending dependency for the beta's game side (#13 Scrip→real remap).
- **Ceremony** — the founder's multi-party ceremony on `transaction2` is the hard gate for the shielded set
  (#2) and blocks the beta's shielding leg.
- **Founder gates** — every mainnet deploy (shielded set, game contracts); ceremony sign-off; `maxDeposit`
  cap + seed stock amount/tickers; `openMode=false`/`setApproved` posture.

## Correction 2026-08-30 — the "USDG 18-dec frontend bug" is NOT a bug
Earlier updates (and the PM status) called the frontend's hardcoded USDG `decimals:18` a bug. VERIFIED false:
essey.xyz's app/web is testnet-only (chainId 46630) and reads a TESTNET USDG mock `0x7461E670…5De2`
(symbol E20M) which IS 18-decimal — so 18 is CORRECT there; changing it to 6 would break the live testnet
/private + DCA flows by 10^12. The mainnet 6-dec USDG `0x5fc5…d168` is NOT referenced in app/web. The only
mainnet-facing layer (reserve.ts, chainId 4663) reads decimals LIVE from the contract — no hardcode. The 18→6
change is only correct as part of a full testnet→mainnet address cutover of live.ts, not a standalone fix.

## Update 2026-08-30 — Pons launchpad evaluated (V3-first for $ESSEY confirmed)

Investigated whether $ESSEY should launch on **Pons** (the RH launchpad FLOOR/$FLR uses). Read the live
$FLR deployment on 4663. Full analysis: [MAINNET-AMM-LAUNCH-SCOPE.md §9](MAINNET-AMM-LAUNCH-SCOPE.md).

- **Pons is a bonding-curve launchpad** (factory `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`, owner
  `0x263ed295…19Dd`) that **mints its own curve-bound tokens and graduates them to a V3-style pool**. Its
  fee is a **1.00% curve trade fee** (`feeBps=100`) split **30% Pons / 70% creator**; the "0.70% → floor"
  is the creator share, routed by FLOOR to its own `RwaFloorTreasury`. It has a **built-in decaying snipe
  tax (99%→0 over 3s)**. All read on-chain from $FLR's curve `0xE525…906b`.
- **HARD BLOCKER for $ESSEY:** Pons has **no path to onboard an existing ERC-20** — `launchToken(...)` mints
  a new token. The already-deployed, adminless, fully-minted $ESSEY **cannot be launched on Pons**, and
  re-issuing it as a Pons token would orphan the live `EsseyReserve` (fixed `claimBase`). **V3-first stands.**
- **The one transferable idea:** Pons's decaying launch snipe-tax is exactly the defense a clean-token V3
  launch cannot have — a candidate to replicate at the pool/seeder or a future V4-hook layer (protocol-engineer).
- **Founder dependency line updated** (cross-flow deps): $ESSEY = Uniswap V3-first; Pons ruled out for the
  existing token.

## Correction 2026-08-30 — Uniswap V4 WITH HOOKS is VERIFIED LIVE on RH mainnet (4663)
Prior updates said "Uniswap V4 PoolManager on 4663 UNVERIFIED" and gated the taxed-hook flywheel on it.
CORRECTED by on-chain trace of FLR (see MAINNET-AMM-LAUNCH-SCOPE.md §9.6): a working V4 PoolManager
`0x8366a39CC670B4001A1121B8F6A443A643e40951` and a production afterSwap fee-hook `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044`
(address low-bits 0x2044 = BEFORE_INITIALIZE+AFTER_SWAP+AFTER_SWAP_RETURNS_DELTA) are LIVE on 4663; Pons/FLOOR run on them.
So the $ESSEY pool-side buy/sell tax → buy-equities → EsseyReserve flywheel IS buildable NOW via a V4 hooked $ESSEY/USDG
pool + our own audited hook — the clean $ESSEY token stays clean (hook is on the POOL). Earlier "V4 not on RH" was
INCOMPLETE (only the canonical Uniswap V4 address was probed; this is a non-canonical deployment). UNVERIFIED: whether
0x8366 is Uniswap-canonical vs a redeploy (irrelevant to feasibility); live fee throughput (escrow balances 0 at trace block).
FLOOR fee reconciled: 1% total / 30-70 Pons-creator / 50-50 buyback-basket → ~0.35% of volume buys equities (docs' 3%/2% is WRONG).

## Update 2026-08-30 — Option B (V4 hooked $ESSEY pool) — PoolManager AUDIT: GO
essey-auditor verdict (docs/OPTION-B-V4-AUDIT.md), both make-or-break gates VERIFIED on-chain (4663):
- `initialize` is PERMISSIONLESS (eth_call from a random EOA with an ESSEY/USDG key succeeds; bad inputs revert
  with genuine v4-core errors) → we CAN create our own $ESSEY/USDG pool. Not Pons-gated.
- `0x8366a39CC670B4001A1121B8F6A443A643e40951` is BYTE-IDENTICAL to Uniswap's official mainnet V4 PoolManager
  (24,010 bytes; only delta = the 20-byte immutable self-address; identical CBOR metadata) → genuine, unmodified,
  no added access control / no drain / no pause / no upgrade; protocol-fee cap 0.1%/dir intact. Owner = single EOA
  (Pons/RH key), reach limited to ≤0.1% fee skim.
Residuals (bounded, non-blocking): single-EOA PM owner (no timelock, ≤0.1% lever); USDG issuer-pause on the quote
leg (founder-accepted). UNVERIFIED-but-bounded: fee-controller internals (PoolManager caps its output at 0.1%).
REMAINING to ship Option B: build OUR EsseyReserveHook (fee→reserve + anti-snipe) → 3-agent audit + harness →
CREATE2 address-mine → founder-gated deploy. Docs: OPTION-B-V4-BUILD.md, OPTION-B-V4-ECON.md, OPTION-B-V4-AUDIT.md.

## Update 2026-08-30 (2) — anti-snipe HIGH: launch-seed SPEC delivered (docs/OPTION-B-V4-LAUNCH-SEED.md)
3-agent gate found a HIGH: DeployEsseyV4Pool.s.sol `initialize`s the pool but seeds in a SEPARATE later tx →
live-but-empty window. A dust swap on the empty pool (v4-core: 0-liquidity swap succeeds with (0,0) delta,
Pool.sol:279/343) both starts the 45s decay clock early (EsseyReserveHook.sol:213 stamps launchTime with NO
liquidity check) → real opening trade pays only 1% base; AND walks slot0 price (pin checked only at initialize,
:189) → single-sided ladder lands at attacker's price. FIX (economist SPEC, engineer to build): 3 layers —
(1) LaunchSeeder periphery does initialize+modifyLiquidity atomically in ONE tx (init needs no unlock,
PoolManager.sol:117; POL locked by construction, no withdraw = no dent to adminlessness); (2) hook guard in
beforeSwap reverts swaps while active liquidity==0 (StateLibrary.getLiquidity, :183; re-mine same 0x20CC flags)
— THIS is what actually closes the HIGH, since initialize is permissionless and an attacker can front-run the
init leg; (3) seeder tolerates a pre-initialized pool (anti-DoS). Layers 1-3 fully close BOTH the surcharge
bypass and the repricing corollary. Residuals R2/R3 (tail window past decay) are inherent + a SNIPE_SECONDS
params/reserve-funding decision, not a code defect. Fork suite (RED on split-tx, GREEN on fix) specified.
NEXT: essey-protocol-engineer builds hook guard + LaunchSeeder + fork suite → 3-agent re-gate.

### Update 2026-08-30 (3) — Dons settlement ruling (founder)
Game (Dons House-layer) settlement is **in-kind / units, on-chain, 24/7, never gated on a price feed** —
no quest/heal/raid/payout pauses when the equity market is closed. The oracle is **display-only**
(dollar figures are labeled estimates; live during market hours, "as of last market close" off-hours).
A variety of stocks does NOT pull an oracle into settlement: raids take a proportional in-kind slice of
whatever tokens sit in the target's hopper. Details + supersession in DONS-HOUSE-LAYER-REWORK.md §4
(RESOLVED 2026-08-30). Owners: don-designer + essey-web-designer.

### Update 2026-08-30 (4) — founder rulings: POL, basket scope, lending roadmap
- **POL slice APPROVED at 10%** of the swap fee, folded into the one hook rework (with the empty-pool
  HIGH fix); launch-economist to recommend the 75/15/10 → four-way re-split, founder confirms the
  number before the engineer builds. Then one gate re-run on the final hook shape.
- **Basket-as-a-product**: designer scoping the Essey product/UX (reuses the reserve/converter);
  PM + founder decide implement / shelf / ready-project after the scope lands.
- **Lending direction (roadmap, not a build order yet):** Essey general lending sits UNDERNEATH the
  Don layer and is DISTINCT from DonLoan — anyone borrows against their RH Stock Tokens without
  selling (base layer already built). Roadmap extensions to scope later: (1) LOOPING / leverage loops
  on the collateral; (2) a MORPHO-STYLE yield-aggregating vault so the stock earns yield while it sits
  as collateral. Front and back end. Owner when scheduled: essey-protocol-engineer + essey-launch-economist.

### Update 2026-08-30 (5) — fee adjustability ruling (founder): Option B + one-way lock
Founder chose a BOUNDED, ADJUSTABLE fee-split governor over the hook (NOT a fully-immutable split),
with progressive decentralization: adjustable during bootstrap, and a one-way `lock()` that permanently
freezes the split and renounces the governor whenever the founder chooses (adjustable → immutable, never
back). Constraints: governor touches the SPLIT ONLY (reserve/dons/ops/POL), within hard immutable rails
(min reserve share, max ops share, POL 0–15% band); base fee + anti-snipe surcharge stay immutable;
short timelock on changes; **EsseyReserve stays fully adminless — the governor can never touch deposited
backing or redemptions.** Folded into the one hook rework (empty-pool fix + POL + governor). launch-economist
specs the rail numbers + timelock; auditor reviews the governance surface in the gate.

### Update 2026-08-30 (6) — hook-rework SPEC delivered (POL + re-split + governor): OPTION-B-V4-LAUNCH-SEED.md Part II
launch-economist folded BOTH decisions into ONE spec (docs/OPTION-B-V4-LAUNCH-SEED.md Part II, §7-§12) so the
engineer builds once and the gate runs once. Grounded on v4-core `Pool.sol:206-236` (read this session):
ESSEY=currency0/USDG=currency1, so single-sided-USDG POL = a **bid wall BELOW spot** (owes only USDG, adds ZERO
active liquidity → does NOT reopen the empty-pool HIGH). **POL cannot be launch-seeded** ($0 USDG at t=0) — it is
**fee-COMPOUNDED** by a permissionless crank on a separate locked `EsseyPOL` holder (no withdraw), the hook just
forwards a `polEscrow` bucket (mirrors fundReserve). REC re-split: **75/7.5/7.5/10** (reserve/dons/ops/POL,
floor-protected). **FINAL split RULED by founder 2026-08-30: 75 reserve / 20 Dons / 5 POL / 0 ops**
(7500+2000+500+0=10000 ✓) — ops ELIMINATED (funded later via bonds off the over-collateralized floor, needs no
standing tax slice); freed 10 pts go +5 Dons (15→20), +5 live POL. Reserve untouched → $684k/yr equities @
$250k/day; POL ≈ $45.6k/yr locked USDG bid; Dons ≈ $182.5k/yr. Code requirement pinned: the rounding remainder
must move from ops to the RESERVE (`resPart = baseFee − donPart − opsPart − polPart`) so a 0% share accrues
EXACTLY 0 (else 0-ops would still collect dust as the current remainder-holder, EsseyReserveHook.sol:242). 0
shares are valid — sum-check is Σ==BPS with uint shares, no positivity assumption (EsseyReserveHook.sol:110).
surcharge stays 100% reserve (NOT POL). Governor
rails REC: **MIN_RESERVE=6000, MAX_OPS=1500, MAX_POL=1500, timelock=48h, one-way lock()**; split adjustable, RATE
immutable; reserve stays fully adminless (EsseyReserve.sol:21). Founder confirms: default split numbers, rails,
timelock, surcharge-POL=no. Tests F-K specified (POL unpullable/single-sided, empty-pool not reopened, rails
enforced, timelock unbypassable, lock permanent, governor cannot reach reserve/rate). NEXT: essey-protocol-engineer
builds the full rework in one pass → 3-agent gate incl. governor surface + byte-diff → harness.

### Update 2026-08-30 (7) — Dons beta controlled-mint SCOPED (docs/DONS-BETA-MINT-PHASING.md)
Founder asked for a throttled Don mint for the mainnet beta (~20 players first, then curated scale) and who owns
the scope. **PM owns it** (launch program-management + gating), launch-economist consulted for Phase-3 open-mint
anti-snipe only (Phases 1-2 are `publicOpen=false`, Merkle-gated → no snipe surface). Grounded deltas:
- **Testnet play count (VERIFIED on-chain 2026-08-30, chainId 46630):** Don `0x582E…dB53c` `totalMinted`=**192**/8888;
  **25** unique mint recipients (24 excl. deployer `0x976e…993d` whose 84 mints = desk seed/admin, `reserveMinted`=84);
  **508** mission dispatches (`Departed`) across **73** unique Dons; those 73 held today by **8** wallets (7 non-infra)
  = the **~7-wallet genuine active-player cohort**; **23** raid commits / 17 attacker Dons. **NOT on any whitelist** —
  DonDistributor `publicOpen`=true, `stageRoot[0/1]`=0x00 (open public mint, no root committed).
- **Throttle = REUSE, not build.** DonDistributor already IS a phasing engine: `claimWL(stage,allocation,proof,combos)`
  Merkle-gated per (stage,account) (`DonDistributor.sol:150-171`, MintDistributor leaf format `:16-18,160`), per-stage
  `stageOpen` (`:156`), 48h `rootTimelock` propose→commit (`:248-263`), `publicOpen` for open mint (`:52,205`). Hard-N =
  curate an N-leaf root + `publicOpen=false`; allowlist membership IS the cap. No new contract.
- **Phasing 1-2-3:** P1 = ~7 active testers + curated fill, **~20-leaf root**, `publicOpen=false`; P2 = add prior curated
  WL (daodon 3,637-wallet list / go-live request-form roots — same leaf format); P3 = `publicOpen=true` + launch-economist
  anti-snipe. Advance gates = money-path integrity (House-layer solvency invariant), no un-absorbed issuer-freeze, keeper
  liveness, raid loop resolves, tester feedback triaged.
- **Seed↔cap coupling:** provision-only missions need seed=0; $20-25 ≈ 0.087-0.11 AAPL of **starter provisioning stock**
  for the cohort — thins past ~20 players, which is why ~20 is the right first cap. Gacha unfundable at $20-25 (≈$46/open).
- **DEPENDENCY (load-bearing):** the throttle/WL half is DONE (reuse). The blocker to a live *playable* beta is the
  **House-layer real-token custody BUILD** — still DESIGN-ONLY (`DONS-HOUSE-LAYER-REWORK.md:9`; mission/raid/House are
  `IScrip` not `IERC20`). Before P1 gameplay runs: founder ruling route (a)/(b) → build → 3-agent audit → founder deploy
  → seed + commit P1 root. Minting is ready; PLAYING needs the custody build first.
- **Game readiness:** RULED = real-stock variety, in-kind 24/7 settlement, display-only oracle. DESIGN-ONLY = House-layer
  custody rework (the one blocking build). OPEN mechanics = raid loop (H-1 fix landed commit 97196c1; V2 board mid-build
  per `git status` GameControllerV2/HitterNFTV2/GameRaidH1), trait mis-calibration (defence ~9x offence), milk-run faucet —
  all converge on the same V2 board / custody redeploy. Quest=Cases-reparametrized carried per founder framing but
  UNVERIFIED at contract level (don-designer to confirm).

### Update 2026-08-30 (8) — fee split FINALIZED (founder) + Dons-director added
Founder finalized the hook fee split: **75 reserve / 20 Dons / 5 POL / 0 ops.** Ops eliminated (funded
later via bonds off the over-collateralized floor); its slice went mostly to the Dons (15→20) with 5
standing up live POL. All governor-adjustable within the rails (min-reserve 60 / max-ops 15 / POL 0–15).
launch-economist to lock this into OPTION-B-V4-LAUNCH-SEED.md before the engineer builds. Also: added
essey-dons-director (game-side program owner / lore-master).

### Update 2026-08-31 — $ESSEY FEE-MODEL REDESIGN opened as a tracked program (supersedes Update (8))
Founder ruled today: keep the 1% (100 bps) $ESSEY buy/sell fee; **re-split and DROP POL + ops.**
- **45 bps → floor reserve** (existing `EsseyReserve`).
- **40 bps → NEW holder stock-airdrop engine** — buy stocks each epoch (~twice daily), distribute to
  $ESSEY holders pro-rata by holding value. A DEFAULT basket auto-assigned to non-choosers; opt-in
  predetermined CATEGORY baskets (tech / Wall St / finance / …); holders CLAIM per epoch or AUTO-PUSH
  at a dust threshold; a registry that lets us keep ADDING stocks and baskets with no redeploy. Modeled
  on Floor/Floorify.
- **15 bps → Dons ecosystem** (existing sink).
This REPLACES the 75/20/5/0 split of Update (8): reserve 75→45, Dons 20→15, POL 5→0, ops already 0, and
a new 40-bps holder bucket that does not exist today.

**GROUNDING — why this is a rebuild, not a governor tweak (VERIFIED *as of 2026-08-30, against the
PRE-REBUILD hook*):**

> ### ⚠️ SUPERSEDED — corrected 2026-09-02. Read this box before the two bullets below.
> The two bullets that follow described the **pre-rebuild** hook and were true when written, but they are
> labelled VERIFIED and carry `file:line` citations that **now point at different code**. A reader following
> them today lands on a direct contradiction about the MONEY RAILS. The bullets are kept for the audit trail;
> **these are the current facts, re-verified against the committed file on 2026-09-02:**
> - **`MIN_RESERVE_BPS = 4_000`** (40%, not 60%) at **`EsseyReserveHook.sol:38`** (not `:50`), with
>   `MAX_HOLDERS_BPS = 5_000` at `:39` and `MAX_DONS_BPS = 2_000` at `:40`; enforced at `:366-368`.
>   The 45% reserve floor is **accepted** by the current contract, not rejected.
> - **THREE buckets** — `reserveShareBps / holdersShareBps / donsShareBps` at **`EsseyReserveHook.sol:73-75`**
>   (not four at `:84-87`). `opsShareBps` and `polShareBps` are GONE; the holder bucket EXISTS and is where
>   the holder route lands.
> - **Do not confuse the RAILS with the SPLIT.** Rails (the immutable bounds) are 40/50/20. The **default
>   deploy split** is **45 reserve / 40 holders / 15 dons** — `DeployEsseyV4Pool.s.sol:47-49` and
>   `test/EsseyReserveHook.t.sol:132-134`. Conflating the two is exactly the error the 2026-09-02 pre-push
>   audit caught in the G1 receipt (H-3).

- ~~The deployed-shape hook has a hard immutable rail `MIN_RESERVE_BPS = 6_000` (60%),
  `EsseyReserveHook.sol:50`, enforced on every proposed split at `:395`~~ → **the 45% floor is structurally
  rejected** by the current contract. Not adjustable; it is a `constant`. **[SUPERSEDED — see box]**
- ~~The hook has exactly FOUR buckets — `reserveShareBps / donsShareBps / opsShareBps / polShareBps`
  (`EsseyReserveHook.sol:84-87`) — and **no holder bucket.**~~ The 40-bps holder route has nowhere to land.
  **[SUPERSEDED — see box]**
- Therefore the hook must be REBUILT (new rail floor, drop POL/ops buckets, add a holder-distribution
  route) → **full 3-round audit re-gate**, because a money-path contract changed.
- The holder engine is a **brand-new money-moving contract** (`HolderStockDistributor`, name TBD). VERIFIED
  it does not exist anywhere in the repo today (grep of all non-`out` `.sol` for `HolderStockDistributor /
  holderShareBps / holderSink` → 0 matches). It needs its OWN dedicated 3-round audit gate.
- **Hook build/gate state (VERIFIED 2026-08-30; SUPERSEDED 2026-09-02):** ~~the reworked hook + its three
  test files are **untracked on `main`** — built locally, never committed/pushed. **UNVERIFIED:** whether it
  "cleared a 3-round gate" — no audit doc for the hook exists under `docs/audits/`.~~ **BOTH facts have since
  changed and the "no audit doc" line must NOT ship as written — the very push it would ride on ADDS that
  doc.** Current: the contracts are **COMMITTED** (`ae143bc`) and the gate is **MET**, grounded in
  [`docs/audits/esseyreservehook-gate-2026-08-31.md`](audits/esseyreservehook-gate-2026-08-31.md). Load-bearing conclusion holds regardless: the split it was built/spec'd for is
  now obsolete AND the 60% rail blocks 45%, so it is rebuilt-and-re-gated either way.

**PROGRAM PHASES / OWNERS / DEPENDENCIES** *(State column reconciled 2026-09-02 — see Update (12). The
dated "Tracker state" footers on earlier updates below are point-in-time snapshots and are NOT re-written;
THIS table plus Update (12) are the current state.)*
| Phase | What | Owner | Depends on | State |
|---|---|---|---|---|
| R | Research Floor's epoch model (claim-vs-push, default+category baskets, dust threshold, per-user basket) | research-intern | may need founder's browser for Floor's app | DONE (informed S; FLR push-vs-claim still VERIFY-gated, `:804-808`) |
| S | Scope new split + distributor architecture + hook-rebuild scope (per-user baskets + add-stocks/baskets registry + claim/push, all v1-core) | launch-economist | R (informs epoch/UX shape) | DONE — split LOCKED at rails 40 reserve / 50 holders / 20 dons |
| B1 | Build hook rebuild (new floor rail, drop POL/ops, add holder route) | protocol-engineer | S locked | **DONE** — `EsseyReserveHook.sol` 453 lines + `LaunchSeeder.sol` 183 lines, COMMITTED `ae143bc` (`git show --stat ae143bc`, VERIFIED 2026-09-02) |
| B2 | Build `HolderStockDistributor` (epoch buy + pro-rata by holding value + default/category baskets + registry + claim/auto-push) | protocol-engineer | S locked | **BUILT, not audited** — `HolderDistributor.sol` 327 lines + `BasketRegistry.sol` 148 lines, COMMITTED `ae143bc` (VERIFIED 2026-09-02). Params still placeholder pending the 6 founder rulings + eligibility bar |
| G1 | 3-round audit gate — hook (governor + money-path surface, byte-diff vs prior) | essey-auditor | B1 all-clean-same-round | **✅ MET 2026-08-31** — 3 consecutive complete-clean 3-lens rounds on byte-identical code; receipt [`docs/audits/esseyreservehook-gate-2026-08-31.md`](audits/esseyreservehook-gate-2026-08-31.md) (92 tests, 4 equivalent survivors). Carries 2 DEPLOY-CONFIG preconditions (feeCurrency=USDG; ESSEY non-circulating until the atomic seed) |
| G2 | 3-round audit gate — distributor (fresh money path: pro-rata math, basket registry, claim/push, dust) | essey-auditor | B2 all-clean-same-round | NOT FIRED — blocked on founder params + eligibility bar (answers incoming) |
| G3 | 3-round audit gate — `StockLpVault` (added after this table was written) | essey-auditor + protocol-engineer | vault build | **NOT MET — REOPENED by a new MEDIUM.** The F-C blocker is CLOSED: `rh-chain/test/StockLpVaultFork.t.sol` now exists (12 tests, all green against the live NVDA/USDG fee-500 pool `0xd4EB…14a3` on 4663) and closes F-C, F2, S10, S10b, F-A, F-B; 17/17 mutants verified RED, vault source byte-unchanged (`git diff --stat src/` empty, VERIFIED 2026-09-02). **NEW FINDING (MEDIUM, code):** `_factor` (`rh-chain/src/market/StockLpVault.sol:460`, pre-fix line) floors an 18-dec stock's mark to whole dollars — NVDA's live feed $216.7894 marks as $216 — and the under-mark is extractable at **±20 bps per round trip at ZERO pool deviation**, permissionless and repeatable; the exactly-representable-price control returns 0 bps, naming the cause. Invisible in-mock (its 220e8 feed is exact). Also **L-A-1 is understated**: measured up to **15 bps/trip** at the gate ceiling, not ~4, and single-sided is NOT $0. **MEDIUM now FIXED (2026-09-02, protocol-engineer):** `_factor` (`rh-chain/src/market/StockLpVault.sol:461-467`) carries the mark at USD x 1e36 as a pure multiply, exact for every feed/token decimal pair up to 36 and refusing (`BadConfig`) past it; the 1e18 carry is stripped at the two unit boundaries only (`totalValueUsd` `:419`, the seed share mint `:190`). Measured on the same live pool: the zero-deviation round trip fell from **+20 / -20 bps (~$44 a trip)** to **-8.9e-7 / -6.7e-7 USD** while the price stayed 44 bps non-integral. 59/59 in-mock + 12/12 fork green, full suite 1431 pass / 2 fail (the same 2 pre-existing `DonMainnetFork` + `DonSolvencyStress` setUp failures as before the change), **17/17 new mutants RED, zero survivors**. Dead `LiquidityOverflow` error dropped (F-D). **G3 must now be re-run FROM ZERO on the changed source — not gate-ready.** L-A-1's deviation term is unchanged and still open |
| I | Integration + adversarial harness — full epoch loop on chain (buy → distribute → claim/push) with real wallets | essey-harness | G1 + G2 + G3 clean | NOT STARTED |
| D | FOUNDER-gated mainnet deploy (exact commands prepared; never self-deploy) | FOUNDER | I green | NOT STARTED |

**Cross-flow dependencies (inherited, load-bearing):** the holder engine BUYS real stocks each epoch →
it inherits every Universal mainnet condition (real RH Stock Tokens + beacon, real Chainlink feeds
session/staleness fail-closed, adminBurn/pause/clawback on held stock, real USDG `0x5fc5…d168` 6-dec,
real gas). It also needs a **real DEX/router on 4663 to source the stock each epoch** — the SAME
unresolved dependency that DEFERRED Multiply (#3) and gates a real $ESSEY market (#5). This is a founder
dependency, not a build item.

**HONEST TIMELINE / EXPECTATION STATEMENT:** research + a LOCKED design land **today**. The two builds
(hook rebuild + new distributor), their TWO separate 3-round audit gates, and integration/harness are a
**FEW DAYS, not hours.** Nothing is live-and-audited today, and nothing should be implied as close. The
two game cores' recent momentum does NOT transfer: this is a **fresh money path** (a never-before-audited
distributor moving real stock to holders) plus a **re-gate of an already-money-critical hook** — the audit
gate is the schedule, and it is deliberately slow. No date is committed until the design is locked (Phase S)
and the engineer sizes the build; any "days" number before then is an estimate, not a commitment.

**COMMS GUARD (Jester lane):** nothing about this redesign ships publicly ahead of what is actually
deployed. The blog stays honest and current — roadmap is labeled roadmap, the 1% split described on the
site remains the DEPLOYED reality until D lands. No post naming "45/40/15", "holder stock airdrops", or a
launch date without (a) the contracts live on 4663 and (b) founder sign-off. This is a design ruling, not
a shipped feature.

**OPEN FOUNDER DECISIONS (surfaced by this scope — founder rules):**
1. **Per-user baskets vs default-only for v1** — full per-user category selection is more contract
   surface + more audit; if timeline presses, default-basket-only is the smaller, faster-to-gate v1 with
   category opt-in as a fast-follow. Founder: full per-user in v1, or phase it?
2. **Claim vs auto-push default** — is the default behavior manual CLAIM (holder pulls) or AUTO-PUSH at a
   dust threshold (protocol pushes)? Auto-push costs gas per holder per epoch and scales with holder count.
3. **Dust-threshold value** — the accrued-value floor below which a holder is NOT pushed (carries to next
   epoch). Needs a number (in USDG terms) before the distributor is built.
4. **Launch basket + stock set** — which stocks and which category baskets exist at launch (tech / Wall St /
   finance / … + the DEFAULT basket composition). The registry lets us add later, but v1 ships with a set.
5. **Epoch cadence confirm** — "~twice daily" needs a concrete interval (and who/what triggers each epoch —
   permissionless crank vs keeper) before the distributor is built.

### Update 2026-08-31 (2) — HARD GATE: VERIFY-BEFORE-BUILD against Floor's real flows (founder directive)
Founder ruling: **nothing is built or drafted on the economist's scope until Floor's actual flows are fully
VERIFIED — grounded on Floor's source/chain, not taken on anyone's word.** The launch-economist's fee-model
scope (Model B / `HolderDistributor` / basket registry) is a **HYPOTHESIS, not approved.** It must be
validated against how Floor actually implements every flow before it feeds any build (B1/B2). This inserts a
new blocking phase **V** ahead of B1/B2 in the phase table above — B1/B2 do not start until V clears.

**Intern's grounded ON-CHAIN verification of Floor (relayed via coordinator; intern-verified-on-chain, not
re-run by PM) — corrects BOTH the economist's assumptions AND Floor's own marketing:**
- $FLR, treasury `0x13ee…58Cb`, currently **epoch 281**.
- Distribution = **per-epoch Merkle claim** → MATCHES Model B's claim mechanic.
- **Epoch interval = 1 HOUR** — NOT the "~twice daily" in Update 2026-08-31. My prior cadence assumption is
  REFUTED; see Decision 5 correction below.
- **Single DEFAULT basket only.** NO per-user / per-category selection — that is a DIFFERENT product
  (PAIR / Folio), not Floor. My prior "opt-in category baskets / per-user" framing described PAIR/Folio, not
  the verified Floor mechanic; see Decision 1 & 4 corrections below.
- **keeper + owner, NOT adminless.**

**Remaining verification before ANY build (the content of Phase V):**
- **(a) Full-SOURCE read of Floor's `RwaFloorTreasury`** — every flow: epoch publish/settle, claim/claimMany,
  withdraw/sweep guards, TWAB. Coordinator is dispatching research-intern for this. BLOCKS B1/B2.
- **(b) App-level flows** — claim-vs-push UX, and PAIR/Folio basket selection — via the founder's browser.
  **FOUNDER-GATED** (needs the founder to drive their browser).
Until BOTH land, the economist's architecture stays a hypothesis and the protocol-engineer does not start.

**Phase table amendment:** insert **Phase V (Floor source + app verification; owner research-intern +
founder-browser; blocks B1/B2)** between S and B1. Phase S (economist scope) output is now explicitly
"proposed, pending V" — not "locked design today." The "locked design today" language in Update
2026-08-31 is SUPERSEDED: design is not locked until V validates it.

**COMMS (founder ruling, hardened):** Jester is **holding ALL drafts** while we are mid-implementation.
Nothing public — no roadmap teaser, no mechanic description — until the founder lifts the hold. This is
stricter than the prior comms guard: not just "nothing ahead of deploy," but "nothing at all right now."

**Decision-list corrections (grounded by the intern's read — these were mis-scoped in Update 2026-08-31):**
- **Decision 1 (per-user vs default-only):** Floor itself is DEFAULT-BASKET-ONLY; per-user/category is a
  separate product (PAIR/Folio). So per-user is a DELIBERATE SCOPE-EXPANSION beyond Floor, not the Floor
  baseline. Reframe the founder decision as: "ship the verified Floor model (single default basket) as v1,
  or build BEYOND Floor to PAIR/Folio-style per-user baskets?" The latter needs its own verification (b).
- **Decision 4 (launch basket set):** if v1 = verified Floor model, this collapses to ONE default basket
  composition, not a multi-category set. Multi-category only applies if Decision 1 chooses the PAIR/Folio path.
- **Decision 5 (epoch cadence):** REFUTED — Floor runs **hourly**, not twice-daily. Founder still rules the
  cadence WE want (hourly is a lot of keeper txs + stock buys), but the "~twice daily" premise came from
  marketing, not chain. Also note Floor is keeper+owner, not adminless — a trust-surface decision for us.
Decisions 2 (claim vs auto-push default) and 3 (dust threshold) stand, pending Phase V(b) UX read.

**Tracker state:** R = returned (on-chain layer) + intern being re-dispatched for source layer (a).
S = in flight, now explicitly gated behind V. **V = the new blocking gate (a)+(b), NOT clear.** B1/B2/G1/G2/I/D
all NOT STARTED and now downstream of V. Comms = full hold.

### Update 2026-08-31 (3) — FOUNDER RULING: NO STAKING EVER → Model B (no-custody keeper) LOCKED; Phase V satisfied
Founder resolved the pivotal decision. **NO STAKING, EVER** — passive hold-in-wallet-and-receive is a HARD
product promise. Per the adminless three-way impossibility (adminless × passive-hold × on-chain-weighting
can't all hold on a hookless token), this forces **Model B: a KEEPER.** **Model A (staking) is KILLED — removed
from the design.** Justification the founder authorized: the hard passive requirement + the **hookless immutable
token** (`EsseyToken.sol:21` — plain `ERC20/ERC20Burnable/ERC20Permit`, no transfer hook, so the token itself
cannot compute holder weights on transfer). Do NOT reopen staking.

**HolderDistributor design — LOCKED on Model B, MINIMIZED (build B2 to THIS shape):**
- **Keeper has NO CUSTODY.** It ONLY posts a weight/Merkle root. It can NEVER move, hold, or drain holder stock.
- **CHALLENGE WINDOW** on every root activation (root is not claimable until the window passes).
- **BOND + permissionless deterministic FALLBACK** so liveness is not single-keeper (anyone can post the
  deterministic root if the keeper stalls; bond is slashable).
- **Honest residual (recorded, load-bearing):** there is **no pure on-chain fraud proof** of a TWAB weighting
  for the raw token. Correctness = **bond + public recomputation + governance slash within the window.** A ZK
  proof of the weighting is a **future v2** — the design MUST keep that door open (don't foreclose a verifier).
- **Adminless surfaces stay adminless:** the `EsseyReserve` and the hook split-governor remain FULLY adminless.
  The keeper touches ONLY the holder-weight snapshot — nothing in the reserve or the fee split.

**PHASE V — SATISFIED (design gate cleared).** Floor fully mapped app + source; founder's own wallet cadence
confirmed on-chain (~12h drops, per-stock minimum with dust carry) in `rh-chain/docs/research/floor-flr-scope.md`
§C (intern-verified; PM confirmed the doc exists at that path, did not re-run the on-chain reads). V no longer
blocks B1/B2. **Gate now:** once the five sub-decisions below are ruled, the design LOCKS and B1/B2 build scope
can start. This SUPERSEDES the "V not clear" state of Update 2026-08-31 (2).

**Phase-table amendment:** V = SATISFIED. B1 (hook rebuild) + B2 (HolderDistributor, Model-B-minimized shape
above) unblocked, but **gated on the 5 remaining founder rulings** landing (they set B2's parameters). Owners
unchanged: B1/B2 protocol-engineer → G1/G2 essey-auditor (two separate 3-round gates) → I essey-harness → D founder.

**REMAINING FOUNDER DECISIONS (sequence for the founder — PM does not decide these):**
1. **Epoch cadence + per-stock minimum threshold.** Floor = ~12h; match it? And the per-stock minimum buy
   threshold — Floor's is off-chain; we set OURS on-chain → needs a concrete **USDG number** (below it, dust
   carries to next epoch). (Replaces the old "~twice daily" premise, which was marketing — Update 2026-08-31 (2).)
2. **Anti-snipe weighting: TWAB vs balance-at-snapshot.** Time-weighted balance (snipe-resistant, keeper-computed)
   vs simple balance at the snapshot block. **Recommend TWAB** given no staking (a snapshot alone lets a buyer
   snipe the block before a drop). Choice drives keeper compute + the residual above.
3. **Basket rails.** Default basket + category packs + custom split, all selected via **gasless signed message**
   (per Floor §B); plus min/max weight caps and a one-change-per-N cooldown. Confirm the rail set + the caps.
4. **Launch basket + category-pack set** — which stocks in the default basket and each category pack at launch.
5. **Keeper params** — who operates the keeper initially, the **bond size**, and the **challenge-window length**.

**COMMS:** Jester hold stands (full hold, founder ruling) — no change. Nothing public.

**Tracker state:** Model A KILLED; Model B LOCKED + minimized. V SATISFIED. B1/B2 unblocked but gated on the 5
rulings. G1/G2/I/D downstream. Comms full hold. No build, no deploy.

### Update 2026-08-31 (4) — SIM: snapshot-farming is net-profitable at launch → TWO-SNAPSHOT HOLDING GATE (hard B2 req)
launch-economist ran a decisive sim (constant-product model + parameter sweep, NOT algebra). Recorded:
- **Attack:** buy $ESSEY right before a snapshot, capture pro-rata airdrop weight, sell after — "snapshot
  farming." **Net-profitable across a wide, realistic LAUNCH-WINDOW regime**: profitable once epoch volume
  > **~5× the held ELIGIBLE FLOAT.** Eligible float is small at launch because pool/LP/treasury must be
  EXCLUDED from the reward denominator → the attack is **worst exactly at launch.**
- **Example:** $250k depth / $5M epoch volume / $50k float → attacker nets **~$9.9k/epoch capturing 65%** of
  the holder distribution.
- **Break-even (sim, load-bearing):** `V > (2 · tax / holder_share) · H` where H = eligible float. Cutting the
  holder share only **MOVES this line**, it does not remove the profitable surface. **Only a holding gate
  closes it structurally.**

**MITIGATION — TWO-SNAPSHOT HOLDING GATE (sim-confirmed to close 100% of the profitable surface, ZERO cost to
honest holders):** credit each wallet **`min(balance_at_prev_snapshot, balance_at_this_snapshot)`** — i.e.
require presence at two consecutive snapshots. A flash farmer has prev-snapshot balance 0 → weight 0 → reward 0.
This is exactly the founder's proposed "hold across a full epoch" gate.

**RECORD AS: a HARD REQUIREMENT of the HolderDistributor / keeper design (B2)** — pending the founder's formal
adoption (economist recommended he lock it; the founder designed the fix). Properties, grounded to Model B:
- Lives **ENTIRELY in the keeper's off-chain distribution query** (Model B) → **NO contract change, NO redeploy.**
- Does **NOT** affect the hook rebuild (B1), which is purely the split — B1 stays in flight, unaffected.
- Composes with the weighting decision (Decision 2): the gate is the `min()` of two snapshots; whether each
  snapshot is TWAB or point-balance is still Decision 2 — the gate applies either way.
- **Open build detail for the engineer when B2 starts:** the **snapshot source.** The token has **no on-chain
  checkpoint** (`EsseyToken.sol` is plain `ERC20/Burnable/Permit`, VERIFIED Update (3)) → the keeper does
  **off-chain transfer-log balance reconstruction** for both snapshots. This is a B2 implementation item, not
  a founder decision.

**Decision-list touch:** Decision 2 (TWAB vs snapshot) is unchanged BUT now explicitly sits UNDER the
two-snapshot gate — the gate is required regardless of which weighting wins. Parameter-only mitigations (e.g.
cutting holder share, Decision-1 knobs) are recorded as INSUFFICIENT alone per the break-even result above.

**Scope-doc fold:** launch-economist to fold this sim + the gate into their fee-model scope
(`OPTION-B-V4-LAUNCH-SEED.md`) — PM keeps the register authoritative and does not edit the economist's live
artifact mid-flight.

**Tracker state:** Model A killed; Model B locked. Two-snapshot holding gate = HARD B2 requirement, pending
founder formal adoption (surfaced as a ruling, below-list). V satisfied. B1 in flight (split only, unaffected).
B2 gated on the 5 rulings + this gate's adoption. G1/G2/I/D downstream. Comms full hold. No build, no deploy.

**FOUNDER RULING TO CONFIRM (adds to the pending list):** formally adopt the two-snapshot holding gate as a
hard requirement of B2 (the economist recommends locking it; the founder designed it).

## WORKSTREAM — Holder experience UI + site information-architecture cleanup (opened 2026-08-31)

Founder opened a NEW product-UI workstream, distinct from the contract-side fee-model program above (this is
its FRONT-END counterpart). Four pieces: (1) the $ESSEY holder experience — gasless-signature basket selection
(default / category packs / custom split), claim view, pending/accrual display, in a HOLDER PROFILE inside
essey.xyz; (2) a protocol LANDING PAGE (floorfi.app-style) + the app it funnels into; (3) site IA — cleanly
SEPARATE Essey-the-protocol (base/reserve, fee engine, holder airdrop, lending, shielded) from Dons-the-GAME;
(4) clean up the old audit backlog surfaced under "Learn". **PM owns scope + sequencing; essey-web-designer
executes; essey-brand-designer sets the Essey-vs-Dons identity split + landing direction. PM does not build/deploy/publish.**

**GROUNDED CURRENT STATE (VERIFIED this session):**
- **IA is game-first and tangled (confirms founder).** Nav leads with The Game / Mint / Trade / How to Play /
  Game Guide; every Essey-PROTOCOL surface is scattered behind two "Learn"/"More" doors — Treasury, Blog, The
  Tape, Explorer, Private under "More"; Docs/Provable/Engine under "Learn" (`app/web/src/App.tsx:59-96`). Lending
  is HIDDEN from nav entirely (route resolves) (`App.tsx:56-57,162-169`). Base layer $ESSEY + reserve are the
  only mainnet-live flow (register #1); the whole site is testnet-FRAMED ("live on Robinhood Chain testnet",
  `App.tsx:601-608`).
- **Audit backlog surface.** Footer "Audits ↗" links the raw GitHub `docs/audits` tree (`App.tsx:640-644`);
  `/docs` (reached via "Learn") carries an "Audits" doc group of 6 entries (`docs.generated.ts`). On disk
  `docs/audits/` holds 10 files incl. **stale-pivot** rounds: `sui-rounds-1-6.md`, `solidity-round-1.md` (Jul 24,
  Sui-era — predate the RH-chain/Essey pivot). Cleanup = archive stale + point the surface at CURRENT rounds, NOT
  the raw tree. (Memory `public-audit-trail-fix-first`: audits are a kept public trail → ARCHIVE, do not delete.)
- **Holder-airdrop CONTRACTS are NOT built** (guardrail-critical). No `HolderDistributor` contract definition
  exists anywhere; the only reference is a `holdersSink` immutable in the UNTRACKED (`??`) reworked hook
  (`EsseyReserveHook.sol:50`). Per the fee-model program above: B2 (distributor) NOT STARTED, gated on 5 founder
  rulings + the two-snapshot gate; G1/G2/I/D downstream. **The holder UI has nothing live to wire to.**
- **Holder UI spec is grounded.** The gasless-signature basket model (default / category packs / custom split;
  rails NVDA≥35%, ≤75%/asset, 1 change/48h; claim + ~12h auto-push) is VERIFIED against Floor's live app in
  `rh-chain/docs/research/floor-flr-scope.md §B`. Design-against-spec is possible NOW.

**SPLIT — what can touch the live site vs what stays preview-only:**

| Track | Work | Owner(s) | Live-site-safe? | Depends on |
|---|---|---|---|---|
| **NOW-1 IA reorg** | Restructure existing content into two coherent areas: Essey-protocol vs Dons-game. Reorganizes EXISTING deployed content only. | web-designer (build) · brand-designer (identity/visual split) | YES — no new claims | founder GO + IA-structure ruling |
| **NOW-2 Audit cleanup** | Archive stale (Sui-era) rounds; point the surface at current rounds; replace raw-GitHub-tree link with a curated audits view. | web-designer | YES — reorganizes existing | founder GO + archive-vs-keep-visible ruling |
| **SPEC-1 Holder profile UI** | Basket selection (default/category/custom, gasless sign), claim view, pending/accrual — designed against Floor §B spec, STAGED IN PREVIEW. | web-designer (build) · brand-designer (Essey visual language) | NO — advertises an undeployed feature | §B spec (have it); WIRED only at B2/D deploy |
| **SPEC-2 Landing + app funnel** | floorfi.app-style protocol landing + the holder app it funnels into. PREVIEW-only (it funnels to the not-yet-built holder app). | web-designer (build) · brand-designer (landing direction) | NO — funnel to undeployed app | brand direction; WIRED at B2/D deploy |

**SEQUENCING vs the contract build:** NOW-1/NOW-2 have zero contract dependency → start on founder GO. SPEC-1/SPEC-2
DESIGN now against the §B spec but WIRE only when B1 (hook rebuild) + B2 (`HolderDistributor`) clear G1/G2 → I → D
(founder deploy) in the fee-model program above. Until D lands: preview-branch only, never promoted to essey.xyz,
factual copy matches deployed reality (web-designer's standing rule; founder's no-vapor guardrail).

**DEPENDENCIES / FOUNDER DECISIONS NEEDED TO PROCEED:**
1. **GO to start the designers** — essey-web-designer (NOW-1 + NOW-2 live; SPEC-1/2 in preview) and
   essey-brand-designer (Essey-vs-Dons identity split + landing direction). The founder rules on kickoff.
2. **IA-structure call** — the crux: does the protocol become the FRONT DOOR (essey.xyz = protocol home, game as
   a routed section / `/dons` or `dons.*`), or a hard top-nav split within one site? The current "/" landing is
   game-first (`App.tsx` Landing) — this decides whether NOW-1 re-fronts the site.
3. **Audit cleanup policy** — archive stale Sui-era rounds out of the visible surface (recommended; trail kept in
   repo/history per memory), or keep them visible? And curated-view vs raw-tree link.
4. **Brand seam** — brand-designer scope is the Essey PROTOCOL only (hierarchy addendum); the Dons side keeps its
   own aesthetic (don-designer/dons-director). The IA split must honor that seam — confirm the two identities are
   deliberately DISTINCT, not unified.
5. **Landing/app scope confirm** — SPEC-2 is the funnel to the holder airdrop → stays preview until B2/D. Confirm
   the landing's job is the holder-airdrop story (not a general re-skin that could ship live piecemeal).

**COMMS:** unaffected by the Jester full-hold (that governs blog/social). This is product UI. But the no-vapor
guardrail is the same spine: SPEC-1/2 never advertise the holder airdrop on the live site until the contracts are
on 4663. No build, no deploy, no publish by the PM — designers execute on founder GO.

**Tracker state:** scoped. NOW-1/NOW-2 ready to start (blocked only on founder GO + decisions 2-3). SPEC-1/2
design-ready against §B, wiring gated on the fee-model program's D. Owners: web-designer + brand-designer.

### Update 2026-08-31 (5) — UI/UX workstream GO (founder) + deploy discipline locked
Founder gave GO on the UI/UX workstream and answered the open UX decisions. Owners: essey-web-designer (build
+ PREVIEW deploy), brand-designer (identity EXTENSION), orchestrator (Chrome verify + prod promote). This runs
ALONGSIDE the fee-model build; the holder-hub UI is downstream of B2 contracts for its live data, but the
IA/brand/cleanup pieces are independent and ship now.

**Locked rulings:**
1. **IA:** `essey.xyz` = **PROTOCOL front door.** The Dons GAME moves into its own wing (`/dons` hierarchy)
   with a bridge from the Don player view → the holder view. A protocol-only visitor must NEVER hit the Dons
   piece unless they seek it.
2. **Holder hub = a HUB, not all-new.** It chains **claim → (optional) shield → borrow (LTV / terms / manage)
   → explorer visibility**, weaving the EXISTING shielded (`/private`), lending, and explorer surfaces into one
   journey. Reuse, not rebuild.
3. **Audit cleanup:** archive the stale **Sui-era** rounds out of the visible surface; **keep the trail in
   repo.** (Targets `docs/audits/sui-rounds-1-6.md` + the Sui-era design docs — web-designer to confirm the
   exact visible-surface set; repo history retained.)
4. **BRANDING CORRECTION (revises the earlier "brand seam" decision):** NOT a new identity split. Keep the
   existing Dons visual language EXACTLY; **EXTEND** it to the Essey protocol UI. Two distinct sections, ONE
   identity. The brand-designer's job is **extension, not a new look.**
5. **Blog navigation fix** folded into the web work: recent-first, scalable timeline.

**DEPLOY DISCIPLINE (recorded, binding on this workstream):**
- **web-designer builds + deploys to PREVIEW ONLY.** Never prod.
- **ORCHESTRATOR verifies every page in Chrome, then handles the prod promote** to `essey.xyz`, with a
  **HOLD-IF-BROKEN** safety valve.
- **The airdrop / claim / borrow / shield-claim UI is PREVIEW-ONLY until its contract is live on 4663 — NO
  VAPOR.** (Consistent with the register's rule: no mainnet copy over contracts that aren't deployed.)
- **LIVE-NOW set** (no unshipped-contract dependency): **IA reorg + audit cleanup + blog fix + honest landing.**
  Everything holder-hub-data-dependent stays preview until B2 → G2 → I → D lands the contract.

**Tracker state:** fee-model program unchanged by this (Model A killed / Model B locked / two-snapshot gate =
hard B2 req pending founder adoption / V satisfied / B1 in flight / B2 gated on the 6 rulings / G1-G2-I-D
downstream). NEW parallel UI/UX workstream: LIVE-NOW pieces cleared to build→preview→(orchestrator)promote;
holder-hub live UI preview-only until its contract deploys. Comms: Jester full hold unchanged. No build/deploy
on PM's end.

### Update 2026-08-31 (6) — B2 build STARTED (in tandem with B1 + UI/UX)
Founder GO: the **HolderDistributor contract (B2) build is now ACTIVE** — was "NOT STARTED, gated on rulings."
Reconciliation of the earlier gate: the **SHAPE is locked**, so B2 builds NOW with **placeholder params**; the
6 founder rulings **tune the params before its GATE, not before the build.** Engineer builds to the locked
Model-B-minimized shape:
- keeper posts a **Merkle root**, **NO custody**;
- **challenge window** on activation; **bond + permissionless deterministic fallback** for liveness;
- **two-snapshot holding gate baked into the root** (`min(prev, this)` — Update (4));
- **gasless-signature baskets**; **append-only basket registry** (add stocks/baskets, no redeploy);
- **params flagged PENDING FOUNDER** (cadence, per-stock min, weighting TWAB/snapshot, basket rails/caps/
  cooldown, launch set, keeper/bond/challenge-window — the 6 rulings).
Reports to coordinator for the **3-round gate (G2) when done** — **gate not fired yet, nothing deployed.**

**Now-in-tandem (three parallel workstreams):**
- **B1** — hook rebuild (split-only: 45 floor / 40 holder / 15 Dons, new floor rail, drop POL+ops) — IN FLIGHT.
- **B2** — HolderDistributor (locked shape, placeholder params) — **ACTIVE** (this update).
- **UI/UX** — IA reorg + audit cleanup + blog fix + honest landing LIVE-NOW; holder-hub live UI preview-only
  until B2's contract deploys.

**Tracker state:** Model A killed / Model B locked. B1 in flight. **B2 ACTIVE** (placeholder params; 6 rulings
tune before G2). Two-snapshot holding gate = hard B2 req (in the root), founder formal adoption still pending.
V satisfied. G1 (hook) + G2 (distributor) = two separate 3-round gates, NOT fired. I (harness) + D (founder
deploy) downstream. Comms: Jester full hold. No build/deploy on PM's end.

### Update 2026-08-31 (7) — B2 CODE COMPLETE (tests green) → awaiting founder-fired G2 gate
**Delta:** flow #12 fee/tokenomics → holder-airdrop leg. **B2 moves ACTIVE (in-build) → CODE COMPLETE,
NOT audited / NOT committed / NOT pushed.** Reported by essey-protocol-engineer. Next gate is G2 (the
3-round audit) — **founder fires it; PM did not.** No deploy, nothing public.

**PM-VERIFIED this session (independent of the engineer's report):**
- Three new files exist and are UNTRACKED (`??`, so uncommitted/unpushed — matches the report):
  `rh-chain/src/market/HolderDistributor.sol` (327 lines, `wc -l`), `rh-chain/src/market/BasketRegistry.sol`
  (148 lines, `wc -l`), `rh-chain/test/HolderDistributor.t.sol` (571 lines, `wc -l`). [`git status --porcelain`
  + `wc -l`, PM ran this session]
- **The holdersSink seam is REAL** (load-bearing wiring the auditor/harness will build on):
  `EsseyReserveHook.sol:343-350` — `fundHolders(address token)` reads `holdersEscrow[token]`, zeroes it, then
  `IERC20(token).safeTransfer(holdersSink, amount)`. The distributor receives USDG passively as `holdersSink`
  and reads its own balance as the epoch pot, exactly as reported. [PM read `EsseyReserveHook.sol:340-352`]

**ENGINEER-REPORTED (reproduce commands given; NOT re-run by PM — the founder-fired G2 gate is the real check):**
- Both new contracts compile under solc 0.8.28.
- `forge test --match-path test/HolderDistributor.t.sol` → 32 passed / 0 failed.
- Full-repo `forge test` → 1355 passed / 2 failed; the 2 (`DonMainnetFork.t.sol`, `DonSolvencyStress.t.sol`)
  fail identically in `setUp()` (`ERC721InvalidReceiver`) with B2 files stashed out → **PRE-EXISTING, no
  regression from B2** (engineer's stash-diff test). PM has NOT re-run the stash diff.
- 12 adversarial mutations against money-path guards, each turned its specific test RED then restored to
  byte-identical source; suite back to 32/32.
- `forge fmt` clean; comment density 12.5% / 11.9% (under the 15% chokepoint ceiling).
- (Note: engineer quoted 288 / 126 SLOC; PM's `wc -l` totals are 327 / 148 — the delta ≈ comment lines, not
  a discrepancy in substance.)

**PENDING FOUNDER — immutable-at-deploy params, flagged in-contract, must be chosen BEFORE deploy** (these are
the same open rulings tracked in Update (5)/(6) as "the 6 rulings", now enumerated by the engineer as the exact
constructor knobs): epoch cadence (~12h min interval), challenge-window length, claim-window length, keeper-bond
size, dark-keeper grace period, sweep/slash sink destinations, registry timelock length. **Placeholder values
are in the code today; the founder's numbers replace them before G2→deploy.** [engineer-reported; each is a
constructor/immutable param — PM did not enumerate them in source this session]

**GATE LADDER position (unchanged owners):**
- G2 (essey-auditor, 3 consecutive clean rounds: economics / access-oracle / mutation) — **founder fires. NOT
  fired.** This is the single most security-critical piece in the program (real stock custody + Merkle claims),
  so the 3-round bar is non-negotiable.
- Then I (essey-harness) on-chain E2E, then D (founder mainnet deploy).
- **guard-git note:** these are changed contracts; **no public push until G2 returns 3-round-clean** (hook rule 2,
  guard-git-enforced). They correctly sit untracked right now.

**Paired work:** B1 (hook rebuild) is in tandem; B2 depends on it ONLY for exposing `holdersSink` as the USDG
destination, which the current hook source does (`EsseyReserveHook.sol:348`, PM-verified above). B1 has its own
gate G1. Both must clear before D.

**Tracker state:** Model A killed / Model B locked. **B2 = CODE COMPLETE, pre-G2.** B1 in flight. Two-snapshot
holding gate = hard B2 req (in the root). V satisfied. G1 (hook) + G2 (distributor) = two separate 3-round gates,
**NEITHER fired.** I (harness) + D (founder deploy) downstream. 7 immutable params await founder values before
deploy. Comms: Jester full hold. **No gate fired, no push, no deploy on PM's end.**

### Update 2026-08-31 (7) — NEW workstream: Oracle-deviation-aware treasury rebalancer / internal arb (DESIGN-ONLY)
Founder opened a research/design workstream. **Owners:** launch-economist = analysis owner; PM = program owner.
**Status: DESIGN-ONLY — NO BUILD.** Tracked alongside the fee-model + UI/UX streams.

**The idea (as framed by founder — the economist is producing the substantive scope; NOT re-derived by PM):**
- RH tokenized stocks can spike to a multiple of true price off-hours/weekends (thin liquidity + short
  squeezes), then re-peg Monday when the RH market maker sells in.
- **Two exposures:** (a) **treasury holdings look inflated then snap back**; (b) the **epoch buyback (B2) could
  overpay** at an off-hours premium.
- **Proposed value-add:** an active rebalancer that **sells the off-hours premium and rebuys on re-peg**, plus
  **valuation discipline — mark backing at ORACLE, not pool.** Possibly externalized as an arb bot later.

**Economist's scope in flight (their analysis to confirm/quantify — PM does not assert these):**
- Quantify the deviation **empirically vs oracle on 4663** (real magnitude, not assumed).
- Confirm whether **StockConverter's oracle-fairness + session gating already mitigates most of the buyback
  exposure (b)** — [economist to confirm; not verified by PM]. If so, exposure (b) may be largely covered and
  the net new work is (a) valuation discipline + the active rebalancer.
- Design the rebalancer + its nuances: **session-gate tension** (can't trade the premium if the flow is
  session-gated fail-closed), **liquidity/execution** (thin off-hours book), **re-peg timing risk**, and
  **keeper-not-adminless** trust surface.

**Cross-links (load-bearing for the founder):**
- Directly touches **B2**: exposure (b) is the epoch buyback overpaying — a rebalancer/valuation-discipline
  ruling may set constraints on how B2 sources stock each epoch (e.g. mark-at-oracle, skip/limit off-hours
  buys). Flag for sequencing: if the economist finds (b) is real and NOT covered by StockConverter gating,
  B2's buy path may need a param or guard — record it, do not fold into B2's build silently.
- Touches the **base reserve (#1)** valuation: "mark backing at oracle, not pool" is a treasury-accounting
  discipline that spans the reserve, not just the airdrop engine.

**Tracker state:** THREE active build streams (B1 hook in flight / B2 distributor ACTIVE, placeholder params /
UI/UX live-now + preview) PLUS TWO analysis-only threads: (i) the 6 B2 param rulings + holding-gate adoption
pending founder; (ii) **NEW oracle-deviation rebalancer — DESIGN-ONLY, economist analyzing, no build.** V
satisfied. G1/G2/I/D downstream, gates not fired. Comms: Jester full hold. No build/deploy on PM's end.

**Economist findings (launch-economist, 2026-08-31, GROUNDED — delivered to founder, scope recorded here):**
- **(a) valuation inflation — ALREADY FULLY MITIGATED, both layers.** `EsseyReserve` never touches a price:
  `floorOf`/`reserveOf` return UNITS, not USD (`EsseyReserve.sol:197-205`); adminless (`:21-25`). The Treasury
  UI renders units only and states "a backing ledger, not a price" (`app/web/src/treasury.tsx:154-155`,
  `reserve.ts:88`) — no pool price, oracle price, or USD NAV anywhere (grep VERIFIED). A pool spike CANNOT leak
  into any stated floor today. Residual: only IF a future USD-NAV display is added, it MUST value at
  Chainlink oracle (session/staleness-gated), never pool spot. Cheap guardrail, not a live gap.
- **(b) buyback overpay — bounded by StockConverter, BUT the accretion buy path does not use it yet.**
  `StockConverter._oracleMinOut` enforces out ≥ oracle-fair·(1−maxSlippageBps) and reverts off-session
  (`NotInSession`) — so THROUGH the converter, an over-pegged buy can overpay by at most `maxSlippageBps`
  (hard-ceiled 5%, `StockConverter.sol:49,142,147`) in-session and ZERO off-hours. BUT reserve accretion as
  scoped (flywheel §5 step 2) is a RAW SwapRouter02 call — no oracle-fair guard, no session gate. **Fix (cheap,
  high-value): route accretion buys through StockConverter → `convert(amountIn, stock, reserveAddr)`** — the
  converter is proven live on 4663 (floor-flr-scope §D). That closes (b) with an existing audited contract.
- **Empirical magnitude — deviations are SMALL and bot-arbitraged; NO capturable multiple observed.** VERIFIED
  on 4663 this session (Mon 2026-08-31 ~22:40 UTC, off-hours, market closed since 20:00): pool spot vs
  Chainlink, NVDA −0.27%, AAPL −0.11%, TSLA +0.26%, SPY +0.22%, GOOGL +0.20%. Realized ranges from Swap logs:
  NVDA (deep $3.48M pool) 485 swaps/13min held a 0.07% band; SPY (thin $15k pool) 263 swaps/~11h held 0.64%
  range, max +0.54% vs oracle. Founder's "multiple of true price" is NOT present in current data — deep pools
  are heavily bot-arbitraged even off-hours. CAVEAT: node prunes state (~<3h) and wide log windows time out, so
  I could NOT reach the actual weekend (Sat/Sun) or rare halt/squeeze tails — absence in an 11h Monday sample is
  weak evidence about a monthly tail.
- **VERDICT: valuation discipline = keep + guardrail (nearly free); buyback guard = route B2 through the existing
  converter (small); active rebalancer = NOT justified on current evidence (premium too thin to harvest, and the
  session gate blocks the sell exactly when the deviation would occur). Recommend: adopt the two cheap mitigations
  now; SHELVE the active rebalancer, revisit only if a real, repeated, capturable off-hours dislocation is
  observed with a proper price indexer.** Full report + nuances delivered to founder.

### Update 2026-08-31 (8) — FLR deposited to EsseyReserve → NEW daily-accrual workstream (VERIFY-gated)
**Founder ACTION (on-chain):** deposited **1,133,023 FLR** from treasury wallet `0x93e6…b9e` INTO **EsseyReserve
`0xd970Ca…05A7b`**, **block 51257763** — reported **VERIFIED `balanceOf` = `reserveOf` = 1.133e24**.
[coordinator-relayed on-chain-verified; PM has NOT independently re-run the read — treat the figure as VERIFIED
by the economist/coordinator, flagged for a PM re-read if it becomes a deploy-blocking number.] Note: this makes
the reserve address CONCRETE — supersedes the memory note "[[essey-reserve-deposit-address]] NOT DEPLOYED yet."
**Intent:** the reserve holds FLR so Floor stock airdrops land DIRECTLY in the reserve daily (auto-accruing
backing). Owners: launch-economist = verify/framing; PM = program; web-designer = pages (gated).

**Status: DESIGN / VERIFY-ONLY until the make-or-break gate resolves.**

1. **MAKE-OR-BREAK GATE (blocks everything on accrual).** launch-economist is verifying NOW whether Floor's
   distributor **PUSHES** stock to the reserve contract, or requires a **CLAIM** the **adminless reserve cannot
   make.** If pull/claim → **the airdrops STRAND** in Floor's distributor and the whole daily-accrual premise
   **FAILS.** Nothing is built on the accrual until this verdict lands. **This is the gate — record it as
   blocking #2's accrual framing, #3 entirely, and #4's stock leg.**
2. **PAGE FIX (small; after economist sets framing).** FLR is **NOT** in `app/web/src/reserve.ts` BASKET → the
   backing page does not show the 1.133M FLR. Add FLR as a **NON-EQUITY line** — it **fails the RH-stock beacon
   check**, so present it as a **protocol token backed by Floor's equities, one layer removed**, NOT mixed with
   the direct-equity backing. Owner: web-designer, AFTER the economist's framing read. [PM to confirm the
   `reserve.ts` BASKET path/line with web-designer before edit — cited from coordinator, not yet PM-grep'd.]
3. **REAL-TIME ACCRUAL DISPLAY (explorer).** Show the reserve's backing value / accrual live as airdrops land.
   Designer task, **GATED ON #1** — do NOT build accrual UI for airdrops that might strand.
4. **DAILY TRACKING.** Standing day-over-day check of the reserve's FLR + stock holdings. (Once #1 clears for the
   stock leg; the FLR leg can be tracked now.)

**Cross-links:** this is the same Floor distributor the fee-model B2 mirrors — the push-vs-claim verdict (#1)
also informs whether OUR HolderDistributor (B2) can push to an adminless reserve, or whether the reserve needs a
claim path. Flag: if Floor requires a claim, an adminless reserve as a beneficiary is structurally hard — may
force a design conversation (claimer contract vs non-adminless collector). Record, do not fold into B2 silently.

**Tracker state:** build streams B1 (in flight) + B2 (ACTIVE, placeholder params) + UI/UX (live-now + preview).
Analysis threads: oracle-deviation rebalancer (design-only); **NEW FLR daily-accrual (VERIFY-gated on #1
push-vs-claim — make-or-break).** Pending founder: 6 B2 param rulings + holding-gate adoption. V satisfied.
G1/G2/I/D downstream, not fired. Comms: Jester full hold. No build/deploy on PM's end.

### Update 2026-08-31 (9) — NEW BUILD workstream: StockLpVault (single-sided stock LP earn vault)
Founder: "do it." Scope: `docs/research/stock-earn-vaults-scope.md` (VERIFIED exists, 27KB). The retention/
compounding layer of the flywheel — holders keep airdropped stock on-platform + compound the yield → TVL +
bootstrapped fees. **Build-with-gate.** Owners: essey-protocol-engineer (build); launch/don-economist (net-of-IL
yield + range/hedge sizing); PM (program). Reports to coordinator for its 3-round gate when done.

- **Phase 1 MVP — engineer building NOW.** Single-sided concentrated-LP vault on the NVDA/USDG-500 pool;
  **ERC-4626 oracle-valued shares** (valued at **Chainlink mark, NOT spot** — anti-manipulation); **permissionless
  compound**; **keeper-gated rebalance**; **NO external hedge.** **Reuses `EsseyLadderSeeder`'s V3 mint/callback/
  collect** (VERIFIED reuse target: `EsseyLadderSeeder.sol:10-11,25,29` — `pool.mint` + `uniswapV3MintCallback`
  + permissionless `collectFees()` :54). `StockLpVault` VERIFIED does not exist yet (grep, 0 matches). → its own
  **3-round audit gate (G3)** when done, NOT fired.
- **Phase 2** — auto-compound + auto-pair + multi-pool. NOT STARTED.
- **Phase 3 — Arcus perp-token hedge — GATED (blocking on-chain verification).** Arcus (24/7 stock perps +
  ERC-20 pTokens, dYdX team) is **docs-claimed but on-chain-UNVERIFIED on 4663.** **Phase-3 gate = verify Arcus is
  actually live on 4663 (contracts on chain), same pattern as the Multiply-DEX and Arcus-style dependencies.**
  Do NOT build the hedge until Arcus is confirmed on-chain. [UNVERIFIED — founder/docs-supplied.]

**Cross-links (load-bearing):**
- **HolderDistributor (B2) is the deposit funnel** — airdropped stock → one-click LP into this vault. B2 and the
  vault share the holder as the same user; the "claim → (optional) shield → borrow" hub journey (Update (5))
  gains a "→ earn" leg. Coordinate the deposit seam so it's not two disjoint builds.
- **StockConverter** for valuation; **keeper pattern SHARED** across B2 / rebalancer / this vault (one keeper
  design discipline, not three).
- Economist owns net-of-IL yield + range/hedge sizing.

**Grounding note (intern-flagged, recorded for the team):** this RPC can misbehave on topic-filtered
`eth_getLogs`. Earlier airdrop/reserve scans **RECONCILED to `balanceOf`** so those figures are solid, but
**log-based analytics must tally client-side**, not trust a topic-filtered server-side log query. Applies to the
daily-tracking (#4, Update (8)) and any explorer accrual analytics.

**Tracker state — FOUR build streams + TWO analysis + gates:** *(SUPERSEDED — this is the 2026-08-31 (9)
snapshot. Current state = the phase table `:370-383` + Update (12) below.)*
- BUILD: **B1** hook (in flight) · **B2** HolderDistributor (ACTIVE, placeholder params) · **UI/UX** (live-now +
  preview) · **StockLpVault Phase 1** (ACTIVE, build-with-gate; P3 Arcus-gated).
- ANALYSIS/VERIFY: oracle-deviation rebalancer (design-only) · FLR daily-accrual (VERIFY-gated on push-vs-claim #1).
- PENDING FOUNDER: 6 B2 param rulings + two-snapshot holding-gate adoption.
- GATES (NONE fired): **G1** hook · **G2** distributor · **G3** vault — three separate 3-round audits → **I**
  harness → **D** founder deploy. Phase-3 Arcus on-chain verify = its own blocking gate.
- Comms: Jester full hold. No build/deploy on PM's end.

### Update 2026-08-31 (10) — CONNECTED PRODUCT TRACKER created ([`PRODUCT-TRACKER.md`](PRODUCT-TRACKER.md))
Founder directive ("things are not being connected together"): built the single at-a-glance matrix of EVERY
product across CODE · UI/UX · DEPLOY · OWNER · next-action, with the process rule (designer maps/queues/builds UI
as each contract lands), the ceremony as a tracked gating item, and the disconnects surfaced. This register stays
the chronological/narrative source; the tracker is the connected matrix. **Update both when a gate moves.**

**Two grounded corrections this reconciliation made to the narrative above (verified this session against the
actual files, not recall):**
- **B1 hook rebuild has LANDED locally** — updates (6)/(7) say "in flight," but `EsseyReserveHook.sol` on disk now
  carries the three-bucket split (`reserveShareBps/holdersShareBps/donsShareBps` `:73-75`), `MIN_RESERVE_BPS=4_000`
  (`:38`, was 6000 → the 45% floor is now structurally accepted, PENDING FOUNDER), POL+ops DROPPED, and the holder
  route (`holdersSink`/`holdersEscrow`/`fundHolders` `:50,88,344-348`). Still UNTRACKED, unaudited.
- **StockLpVault's two UI view fns now EXIST** — `previewWithdraw` (`:217`) + `pendingFees` (`:281`); closes gaps
  G-UI-1/G-UI-2 from the vault scope. 23/23 in its own suite (coordinator-reported, not PM-re-run).

**Two states the tracker records that this narrative did not:**
- **D-1 audit-state UNVERIFIED** *(as of 2026-08-31; **RESOLVED** by Update (11) — the receipt now exists at
  `docs/audits/esseyreservehook-gate-2026-08-31.md`. Kept for the trail; do not read as current):* the hook is founder-reported "R2 clean, 1 round to go," but no audit doc exists
  under `docs/audits/` for it and the contract is untracked — recorded UNVERIFIED until the auditor commits round
  receipts. Consistent with update `:366-368`.
- **Wrap-up cleanup workstream:** `FOUNDRY_PROFILE=v4 forge test` has ~45 failing tests in unrelated suites
  (GameRaid/Isolation/LivenessOracle/MarketHealthOracle/Note/NoteArt/RateModes/Succession/TravelCase), mostly
  `OutOfGas` in `setUp()`, PRE-EXISTING/not regressions (coordinator-reported, PM has not re-run). Owner =
  essey-protocol-engineer; a gating item for the "everything wrapped up" claim. Tracked in `PRODUCT-TRACKER.md §8`.

### Update 2026-08-31 (11) — G1 (hook) MET + G3 (vault) firing
- **G1 — $ESSEY launch hook (`EsseyReserveHook` + `LaunchSeeder`) is AUDIT-CLEAN.** Three consecutive
  complete-clean 3-lens rounds on byte-identical code; committed receipt at
  [`docs/audits/esseyreservehook-gate-2026-08-31.md`](audits/esseyreservehook-gate-2026-08-31.md) (verdict MET, 92
  tests, F-C1 coverage gap caught mid-gate → test-only fix + mutation-verified → 3 clean rounds; 4 equivalent
  survivors). This **resolves tracker disconnect D-1** (was UNVERIFIED — now grounded in a receipt, not chat). Rails
  founder-confirmed 40/50/20. Two DEPLOY-CONFIG gates carry forward (feeCurrency must = USDG; ESSEY non-circulating
  until the atomic seed). Contracts still UNTRACKED — guard-git now unblocks the push (3 clean rounds); commit next.
- **G3 — StockLpVault gate FIRING (round 1 of 3).** CODE → `audit-in-progress`. Needs 3 consecutive clean rounds.
- Register+tracker reconciled. No deploy, no push, no publish on PM's end.

### Update 2026-09-02 (12) — REGISTER RECONCILE (G1=MET pass) + ceremony status + team-MD check
PM pass, read/reconcile only. No build, no push, no deploy, no publish.

**Reconciled in this doc (the stale-state fix the tracker flagged):**
- **Phase table `:370-383` rewritten.** B1 was `NOT STARTED` while the hook is built AND audit-clean; B2 was
  `NOT STARTED` while the distributor is built; G1 was `NOT STARTED` while its receipt says **MET**. G3 (vault)
  did not exist in the table at all. All five cells now carry a `file:line`, a `git` read, or the audit receipt.
- **The 2026-08-31 (9) "Tracker state" block `:863-871` is marked SUPERSEDED** rather than rewritten. Same for
  every other dated "Tracker state / gates NOT fired" footer above (`:465,512,551,653,678,729,763,827`) — those
  are point-in-time snapshots inside a chronological log and were true when written. **Current state = the phase
  table + this entry.** Do not read a dated footer as live status.

**CEREMONY — DID NOT RUN on 2026-09-01. VERIFIED, and this is load-bearing.**
- `ls -laT the ceremony directory` (run 2026-09-02) shows **only** `ceremony_0000.zkey` (the
  pre-contribution key), `pot15_final.ptau`, `transaction2.r1cs`, `CEREMONY-RUNBOOK.md` — **all mtime
  2026-08-30**. There is **no** `ceremony_0001.zkey`, `ceremony_0002.zkey`, or `ceremony_final.zkey`.
- The app still serves the **single-contributor** proving key: `app/web/public/pool/transaction2.zkey`,
  mtime **2026-08-15** (`ls -laT app/web/public/pool/`).
- `rh-chain/src/private/pool/PoolVerifier2.sol` mtime **2026-08-15**; last touched at commit `61a27bd`
  (`git log -- rh-chain/src/private/pool/PoolVerifier2.sol`) — no post-ceremony verifier swap happened.
- **Consequence, unchanged:** the deployed shielded setup remains single-contributor → **proofs forgeable,
  a funded pool drainable with real money** (`:96-98`). The shielded set (#2) stays HARD-BLOCKED. The two
  human gates from `CEREMONY-READINESS.md` are still open: **B1** a real independent second contributor
  (or a founder ruling on the Erik-only + beacon fallback) and **O2** the public beacon source/height.
  Everything mechanical is green — ptau provenance CONFIRMED (blake2b == official PSE), starting key
  `ZKey Ok!`, toolchain installed, runbook written.

**Team-MD / shared-doc currency check (`~/.claude/agents/*.md` + the five shared docs) — flagged, not fixed
(they are outside the two docs the PM owns):**
- `docs/PRODUCT-TRACKER.md` — **CURRENT** (reconciled 2026-09-01, 2nd session; its own "STILL STALE" note
  pointed at this register, which this entry closes).
- `docs/JESTER-PERSONA-BIBLE.md` — **CURRENT** through §32 (2026-09-01). Cosmetic only: §30 is filed after §31.
- `docs/CEREMONY-READINESS.md` — **CURRENT as a readiness inventory**, but its header still reads "for a
  founder-run ceremony on **2026-09-01**" (`:3`) and the step list says "run it tomorrow" (`:~86`). The date
  has passed with no run — needs a re-date by the zk lead when the founder sets a new one.
- `docs/AGENT-HIERARCHY.md` — **STALE, 2 gaps.** (a) **`essey-legal-advisor` is missing entirely** — the
  charter exists (`~/.claude/agents/essey-legal-advisor.md`, 2026-08-31) but no roster line or addendum
  (`grep -n essey-legal-advisor docs/AGENT-HIERARCHY.md` → no match). (b) It never names
  `docs/PRODUCT-TRACKER.md`, so no charter's read-first list points at the connected matrix.
- `~/.claude/agents/essey-legal-advisor.md` — **STALE: no onboarding block and no GROUNDING GATE.** Every
  other Essey charter carries both; this one carries neither (`grep -n "READ FIRST\|GROUNDING GATE\|AGENT-HIERARCHY"`
  → no match). It spawns stateless with no orientation.
- `~/.claude/agents/essey-web-designer.md:10` — **STALE:** still lists `~/Developer/essey-markets/web/` as a
  co-owned site, against the canonical-repo ruling (one public source of truth; the markets fork is archived)
  [[essey-canonical-repo-decision]]. The directory still exists on disk, so the charter will send the
  designer to the wrong tree.
- `~/.claude/agents/essey-deployment-manager.md:39-46` — **STALE (PM's own charter):** the "Specialists you
  coordinate" list names only 5 (auditor, web-designer, jester, don-economist/don-designer, harness). Missing
  8 real team members: protocol-engineer, zk-auditor, launch-economist, brand-designer, research-intern,
  social, legal-advisor, dons-director.
- All other Essey charters carry the onboarding block + grounding gate and read current.

**One more stale-state correction:** the **Opal Exchange dossier is DELIVERED**, not queued —
`docs/research/opal-exchange-dossier.md`, 18,784 bytes, mtime **2026-09-01 14:36** (`ls -laT`, VERIFIED
2026-09-02). Both `RESUME-2026-09-01` and the tracker's kickoff queue said "not dispatched." Verdict:
Opal's privacy is a **TEE/enclave trust assumption, not cryptography** (no ZK, no mixer, no shielded
pool; off-chain matching, nothing on-chain-verifiable), and "100% of fees to holders" is an operator-run
off-chain snapshot + manual airdrop with no distribution contract located. This makes Essey's shielded
pool a genuine cryptographic differentiator against the narrative the founder flagged — **and it raises
the cost of the ceremony not running**: the differentiator is exactly the thing still gated. The two
downstream items (brand/narrative study; uniform-price sealed batch-auction anti-snipe scope) are
UNBLOCKED and are now the live research work.

**PUSH GATE — a finding the tracker did not surface.** The tracker's B1 row says the next action is
"push (needs 3-agent clean + founder go)." That understates it. The 7 local commits (`git status -sb` →
`ahead 7`) include `ae143bc`, which touches **12 contract files**, only 2 of which are audit-clean
(`git show --numstat ae143bc -- rh-chain/src`, VERIFIED 2026-09-02):
- **audit-clean (G1 MET):** `EsseyReserveHook.sol`, `LaunchSeeder.sol`.
- **built, NEVER audited:** `HolderDistributor.sol`, `BasketRegistry.sol`, `StockLpVault.sol` (G3 not met),
  `DonMintSplitter.sol`, `EsseyLadderSeeder.sol`, `GameControllerV2.sol`, `GameLedger.sol`, `HitterNFTV2.sol`.
- **MODIFICATIONS to already-deployed contracts:** `MissionBoard.sol` (+35/−13) and `EsseyCasesDegen.sol`
  (+30/−1) — changed contracts under hard rule 2.
**Therefore G1 alone does NOT unblock the public push.** Pushing this bundle would put nine unaudited
contracts and two modified deployed ones on the public repo. Options for the founder: (a) fire a scoped
pre-push audit round over the whole `ae143bc` contract set, or (b) split the push so only the G1-clean
hook + `LaunchSeeder` + the docs/web commits go out and the rest waits on G2/G3. **PM recommends (b)** —
it is the smaller blast radius and does not hold the finished work hostage to the unfinished. Founder's call.

**Nothing else moved.** No gate advanced today; this entry only makes the register match the receipts.

### Update 2026-09-02 (13) — SEVEN FOUNDER RULINGS landed; five workstreams dispatched
All seven relayed via the orchestrator. Recorded here and in `PRODUCT-TRACKER.md`. PM did not deploy,
push, publish, or dispatch — the orchestrator dispatches.

1. **AGENT CONFIG — repair authorized.** `docs/AGENT-HIERARCHY.md` repaired this pass (see below). The
   four `~/.claude/agents/*.md` charter edits are prepared but NOT applied — see the note at the end.
2. **PUSH — SPLIT it** (PM's recommendation adopted). Only the G1-clean set ships: `EsseyReserveHook.sol` +
   `LaunchSeeder.sol` + the docs/web/blog commits, after `essey-auditor` returns a clean **scoped** round on
   **just that set**. The 9 built-never-audited contracts and the 2 modified already-deployed ones
   (`MissionBoard.sol` +35/−13, `EsseyCasesDegen.sol` +30/−1) are held back in a separate commit until gated.
   **Mechanical note:** `ae143bc` is ONE commit mixing clean and unclean contracts, so this is a history
   rewrite of an unpushed commit, not a partial push.
3. **CEREMONY — B1 SETTLED: the founder contributes HIMSELF and finalizes with a PUBLIC BEACON.** No
   independent second contributor. `essey-zk-auditor` dispatched to prepare the run + an exact live
   walkthrough. **POSTURE, to be stated exactly and never softened:** founder-only + beacon is enormously
   better than the single-contributor key on chain today — the beacon is unbiddable public randomness, so
   the toxic waste cannot be ground after the fact — but it is **NOT a multi-party ceremony**. Security
   rests on the founder honestly discarding his entropy PLUS the beacon. **Never publish it as multi-party**
   (Jester + social: this is a hard framing constraint, not a preference). `CEREMONY-READINESS.md` re-dated
   accordingly; the contribution chain is now `_0000 → _0001 → beacon → _final` (the counterparty step is
   SKIPPED, and step 3 beacons `_0001`, not `_0002`).
4. **FLR AIRDROP — CLOSED, not a risk.** Floor's airdrops have **volume MINIMUMS** before they drop, so the
   reserve receiving nothing is **EXPECTED**, not evidence of a stranded claim-only path. The push-vs-claim
   VERIFY-gate (`:804-808`) is retired as a finding. Memory: `floor-airdrop-minimums`. **Do not re-open this**
   — it is a settled fact, and re-discovering it as a "finding" wastes the founder's time.
5. **Vault fork-test = BUILD** (`StockLpVaultFork.t.sol`, dispatched) · **keeper owner = protocol-engineer**
   (dispatched) · **eligibility bar = 0.1% of supply = 8,888,889 $ESSEY, a KEEPER KNOB** (unblocks G2) ·
   **FLR price = query via PONS**, the launchpad Floor is on (dispatched).

**Repairs made this pass (`docs/AGENT-HIERARCHY.md`):** added `essey-legal-advisor` to the org diagram, the
agent list, and its own addendum — the charter had existed since 2026-08-31 but was never listed, so the agent
was invisible to the org and to every other agent's read-first. Added the four newer specialists that were
also missing from the agent list (zk-auditor, brand-designer, launch-economist, research-intern) plus
dons-director; the roster is now **13 specialists + the PM**, stated explicitly. Added a **read-first block**
that puts `PRODUCT-TRACKER.md` third in every agent's orientation. Added a **two-doc rule** addendum recording
the lesson from this reconcile: update BOTH docs when a gate moves, and **a dated log entry is a point-in-time
snapshot, never live status.**

**O2 IS NOW THE CRITICAL PATH.** With B1 settled, the single remaining input before the ceremony can run is
the **public beacon source + height** — and it must be **pre-announced and FUTURE** (e.g. a Bitcoin block hash
at an agreed height after the contribution), or it can be ground and the whole exercise is theatre. The
ceremony is the hard blocker on the entire shielded set (#2), and the Opal dossier (Update (12)) makes it the
sharpest item on the board: our shielded pool is real cryptography where the competitor's is an enclave trust
assumption — and the real one is the one still gated. **No new date is set.**

**NOT DONE — agent-charter edits held.** Ruling 1 also covers four files under `~/.claude/agents/`
(`essey-legal-advisor.md` onboarding+grounding block · `essey-web-designer.md:10` stale `essey-markets` path ·
`essey-deployment-manager.md:39-46` incomplete roster · charters reading into PRODUCT-TRACKER). Those are
harness **agent configuration**, and the authorization reached the PM as an agent-relayed message rather than
from the founder directly. The exact patches are written and ready to apply on the founder's own word; the
repo-side docs (this file, `AGENT-HIERARCHY.md`, `CEREMONY-READINESS.md`, `PRODUCT-TRACKER.md`) are done.

### Update 2026-09-02 (14) — scoped pre-push audit NOT CLEAN; H-2/H-3 doc corrections landed
The scoped pre-push round on the G1-clean set came back **NOT CLEAN**. H-1 (absolute local paths in
`rh-chain/circuits-nova/adversarial/` leaking the layout of two other private repos) was fixed by the
coordinator. H-2 and H-3 were in PM-owned docs and are fixed here. **Push stays BLOCKED pending a fresh
3-round clean.** Every number below was re-verified against the committed file, not carried forward.

**H-2 — the register contradicted the code shipping in the same push.** Three corrections, all made as
dated SUPERSEDED boxes rather than silent rewrites, so the audit trail survives and the contradiction dies:
- `MIN_RESERVE_BPS` — register said **`6_000` at `EsseyReserveHook.sol:50`**, labelled VERIFIED. Code says
  **`4_000` at `:38`** (`grep -n MIN_RESERVE_BPS`, 2026-09-02), with `MAX_HOLDERS_BPS=5_000` `:39`,
  `MAX_DONS_BPS=2_000` `:40`, enforced `:366-368`.
- Bucket count — register said **FOUR** (`reserveShareBps/donsShareBps/opsShareBps/polShareBps` at `:84-87`),
  labelled VERIFIED. Code has **THREE** (`reserveShareBps/holdersShareBps/donsShareBps` at `:73-75`).
- "No audit doc exists for the hook" (`:366`) — the same push **ADDS** that doc. Marked superseded.
- B1/G1 `NOT STARTED` rows were already corrected in Update (12); the auditor read `HEAD`, where Update (12)
  was still **uncommitted**. That was the real defect — see the commit note at the end.

**H-3 — the audit receipt misstated the fee split, and the error had already spread.** The receipt said
"Default deploy split **50 holders / 40 reserve / 10 dons**." The real default is **45 reserve / 40 holders
/ 15 dons** (`script/DeployEsseyV4Pool.s.sol:47-49`; `test/EsseyReserveHook.t.sol:132-134`). **The receipt
had printed the RAILS as if they were the SPLIT.** This matters beyond tidiness: 50/40/10 sits *exactly on*
two rails — holders at the 5000 ceiling, reserve at the 4000 floor — so the old text described a launch
shipping at its limits with zero governor headroom. The real split has 500 bps above the reserve floor and
1000 bps below the holders ceiling.

**The contamination chain — wider than the audit flagged.** One wrong number in one receipt propagated into
**four more documents**, each citing the receipt as its source. Found by sweeping `grep -rn "50/40/10"`
rather than trusting the two files reported. All corrected:
`docs/audits/esseyreservehook-gate-2026-08-31.md` (origin) → `docs/audits/README.md` →
**`docs/BASE-LAYER.md:110,136`** → **`docs/OUTSTANDING.md:14`** → **`docs/TOKENOMICS-v3.md:108`**.
The last three are **tracked, public, and rendered on the live site's `/docs`**. The wrong split is in the
built bundle (`app/web/dist/assets/index-*.js`, gitignored build artifact), so **essey.xyz is currently
publishing the wrong fee split** and will keep doing so until a rebuild + founder-gated deploy. Flagging,
not fixing — a deploy is not the PM's to make, and the clean-tree deploy gate applies.
**This is the "never let one agent's unverified assumption become another agent's premise" failure, in its
exact textbook shape.** Four downstream docs cited the receipt instead of the code. The receipt was the
single point of failure and nothing re-derived it.

**Two LOW findings recorded that existed nowhere in the receipt (now added to it):**
- **S-1** — `EsseyReserveHook.sol:256`'s `EmptyPool` guard is unconditional and never disarms after launch.
  A buy that exhausts active liquidity leaves `getLiquidity()==0`, and every subsequent swap reverts.
- **S-2** — `LaunchSeeder.seed()` (`:123`) validates each rung individually (`:156,157,162,168,144`) but has
  **no post-condition that the result is active at spot**. One-shot (`seeded=true` `:127`), no withdraw path.
- **They COMPOUND:** a mis-parameterized seed (S-2) yields zero active liquidity, which S-1 turns into a
  **permanently un-swappable pool** — a launch that can neither trade nor be recovered, from one bad rung
  array on a one-shot call. **Fix-in-code vs accept-in-writing is a FOUNDER call; the PM does not decide it.**
  Procedural mitigation is now DEPLOY-CONFIG preconditions #3 (fork-simulate the rungs first) and #4 (rung
  contiguity bracketing spot). Precondition #1 strengthened to **ERC20 USDG, never the native currency** —
  a V4 `Currency` may be the zero address and the payout path assumes an ERC20 transfer.

**Process improvement ADOPTED: every future audit receipt carries `sha256sum` of each audited file.** Added
to the G1 receipt with an honest caveat — the hashes were taken 2026-09-02, not during the 2026-08-31 rounds,
so they pin the files forward but do **not** retroactively prove the audited bytes. Baseline for the next
gate, not proof of the last.

**Open contradiction flagged, not resolved:** the receipt says "rails founder-confirmed 40/50/20" while the
source still carries `// PENDING FOUNDER CONFIRMATION` on all three rail constants
(`EsseyReserveHook.sol:37-40`) and on the default split (`DeployEsseyV4Pool.s.sol:46`). One of the two is
wrong. Founder resolves: confirm and strip the comments, or downgrade the receipt's claim.

**THE PROCESS DEFECT WORTH KEEPING.** Update (12) fixed the stale register on 2026-09-02 — and then sat
**uncommitted in the working tree**, so the auditor reading `HEAD` correctly found the register still stale.
A reconcile that is not committed did not happen. **New standing rule: a doc reconcile is not done until it
is committed.** Applied immediately — this entry and every correction above are being committed now, not
left in the tree.

### Update 2026-09-02 (15) — vault MEDIUM (whole-dollar mark) FIXED; G3 resets to zero
The `_factor` truncation the fork test found is closed in source. `_factor`
(`rh-chain/src/market/StockLpVault.sol:461-467`) no longer divides by `10 ** tokenDec`: the mark is carried at
USD x 1e36 (`MARK_EXP = 36`, `:87`) as a pure multiply, so the feed's full precision survives for **every**
decimal pair whose feed+token decimals sum to <= 36, and a pair above that is refused with `BadConfig` rather
than floored. The extra 1e18 is stripped at exactly two unit boundaries — `totalValueUsd` (`:419`) and the
seed share mint (`:190`) — so the public USD-1e18 unit and the share unit are byte-for-byte what they were.

- **Measured on the live NVDA/USDG fee-500 pool, same test that found it:** the zero-deviation round trip went
  from **+20 bps in / -20 bps out (~$44 on a $22k trip)** to **-8.9e-7 / -6.7e-7 USD** — dust in the vault's
  favour — with the live price still 44 bps non-integral. `test_fork_FINDING_whole_dollar_mark_truncation_is_fixed`
  now asserts the fixed behaviour and self-checks that its dust band sits 100x under the leak it replaces;
  the exactly-representable control is untouched and still green.
- **Evidence:** 59/59 `test/StockLpVault.t.sol` (6 new pins), 12/12 `test/StockLpVaultFork.t.sol`, full suite
  1431 passed / 2 failed — the same two pre-existing `DonMainnetFork` / `DonSolvencyStress` `setUp` failures
  present before the change (baseline 1425/2, re-run VERIFIED 2026-09-02). **17 adversarial mutants, all RED,
  zero survivors** (exponent +/-1, `MARK_EXP` 35/37, the original divide restored, divide-for-multiply, guard
  dropped and `>`->`>=`, each `shift` operand dropped, and every direction of both `/ PRICE_SCALE` sites
  including round-up).
- **The in-mock blind spot is closed too.** The mock feed is exactly `220e8`, which the OLD `_factor`
  represented without loss — which is why this was fork-only. The suite now carries a non-integral price
  (`$220.4321`) on the 18-dec leg and `$0.99987654` on the 6-dec leg, so restoring the original divide is RED
  **in-mock as well as on the fork**.
- **F-D closed:** the dead `LiquidityOverflow` error is deleted (grep: the only other definitions belong to
  `LaunchSeeder.sol:84` and `EsseyLadderSeeder.sol:131`, which use their own).
- **Gate consequence: G3 restarts from zero.** The vault source changed after the fork-test round, so the
  three consecutive clean rounds must be re-run against the new bytes. Nothing is pushed and nothing is
  deployed; the vault is not deployed anywhere, so there was never live exposure.
- **Still open, unchanged by this fix:** L-A-1's deviation term (deposit mints at the oracle mark, withdraw
  pays a spot-basis slice) — measured 8-9 bps a trip at the 100 bps gate ceiling, bounded by the pinned 25 bps
  and **not** a rounding bug. That is a design question for the auditor + economist, not this changeset.

## Update 2026-09-02 — #3 lending: the /lend SURFACE is mainnet-ready (contracts still not deployed)

- **The UI moved to mainnet 4663.** New `app/web/src/lending.ts` reads through `reserve.ts`'s
  `mainnetPub` and writes through `mainnet-tx.ts`; `live.ts` `NET` was NOT flipped, so the game wing
  stays on 46630. `/lend` no longer reads a single contract on testnet.
- **`LENDING.markets` (lending.ts:30) is the single activation switch.** EsseyMarkets is the root:
  `activePool(token)`, `liveness()`, `health()` and the pool's own `note()`/`asset()` are all
  discovered from it, so the founder's deploy turns the page on by setting one address — no rewrite.
- **`EsseyMarkets`/`EsseyPool`/`StaleFeedGuard` are STILL NOT on 4663.** VERIFIED: no
  `rh-chain/broadcast/DeployMarkets.s.sol/4663` exists. The page renders an explicit "not deployed"
  state with no inputs and no buttons rather than a dead control.
- **The beacon address is now VERIFIED on chain, not founder-supplied.** MAINNET-LENDING-SCOPE.md §2
  marked `0xe10b6f6b275de231345c20d14ab812db62151b00` UNVERIFIED. `cast storage <AAPL|NVDA>
  0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50 --rpc-url <4663>` returns exactly
  that beacon for both Stock Tokens (2026-09-02). The scope's open question on the beacon assert can be
  answered on evidence.
- **Fork rehearsal of the read layer.** `DeployMarkets.s.sol` deployed against an anvil fork of 4663;
  after the 2-day warp and `commitMarket`, `market(AAPL)` returned
  `(true, 5000, 7500, 500, 18, 250000000000, 2000)` — every ABI entry the UI declares decodes against
  the real contracts, and `canBorrow` resolved false at the `liquidationsAllowed()` rung, which is the
  reason the UI now names. Fork broadcast artifacts were deleted; nothing was deployed.
- **#11 DCA is unchanged and still testnet.** `RecurringBuy` has no mainnet build, so its panel keeps
  the 46630 path and now carries an explicit `testnet · chain 46630` label on a mainnet page.
  RECOMMENDATION: give it its own route so one page does not hold two chains.

---

## Update 2026-09-02 (16) — PROGRAM RECONCILE: audit R1 NOT CLEAN (two HIGHs), history rewritten, four surfaces shipped to prod

Everything below was re-verified this pass against the repo, the receipts, the chain, and the **live
production bundle**. Recall was not used. The five preceding updates in this doc are point-in-time
snapshots; this entry supersedes them where they disagree.

### 16.1 The push set — re-derived, because history was REWRITTEN today

`git log --oneline origin/main..HEAD` = **14 commits**, HEAD `ae62d34`, origin/main `6903bc6` (VERIFIED
2026-09-02). A `filter-branch` ran today to scrub two private repo names out of committed paths, so
**every SHA recorded in this register before this entry is STALE**. In particular `ae143bc` — cited as
"the source checkpoint" throughout Updates (12)–(14) and across the tracker — is now `c7d0e60`
(`git log --oneline origin/main..HEAD`). Do not cite a pre-rewrite SHA again.

**The leak is ALMOST gone from the unpushed range — one residue remains, and it must be cleared before the
push.** Grepping the two scrubbed names over `git rev-list origin/main..HEAD` returns **`.githooks/pre-commit`
in two commits** (`ae62d34`, `04e763d`): the hook's own comment explained what it blocks by naming the very
repos being scrubbed. The **worktree copy has since been generalised** (re-verified 2026-09-02: zero hits
across the working tree) — but a worktree fix does not clean a commit, which is the exact lesson H-1 taught
in Update (14). **Those two commits need amending or rewriting before the push.** Hygiene finding H-1 is
therefore **NOT closed**; it is one rewrite away from closed.

*(The two names are deliberately not written into this register. Grep for them from the shell, not from a
tracked doc — writing the pattern down re-creates the leak inside the file that documents it. This entry
did exactly that on its first draft and was corrected in the same pass. The failure is that reflexive.)*

**The structural cause is closed too.** `.githooks/pre-commit` now exists (2,339 bytes, executable,
`core.hooksPath=.githooks` — VERIFIED). It blocks staged secrets files, PEM keys, key/mnemonic literals,
API-token literals, and — the actual 2026-09-02 leak — **any absolute `/Users/*/Developer|Documents|Desktop/`
path**, checked against the *staged blob*, not the worktree. Escape hatch `COMMIT_SECRET_OK=1`.
The audit's structural finding *"No git hooks are installed… the pre-commit secret hook recorded in memory
DOES NOT EXIST"* (receipt `~/.claude/gate-receipts/audit-7fe1cb8`) is **RESOLVED**.
**Scope limit, stated plainly:** it gates `commit`, not `push`, and it does not catch `.orig`/backup
copies of source (two are in the tree right now — see 16.6).

### 16.2 AUDIT ROUND 1 — NOT CLEAN, twice over. The round counter is at ZERO.

Receipt: `~/.claude/gate-receipts/audit-7fe1cb8` (9,551 bytes, 2026-09-02). PoCs:
`~/.claude/gate-receipts/audit-7fe1cb8-poc/A{1,2,3}Poc.t.sol`. All findings CONFIRMED on an **RH mainnet
(4663) fork against the real deployed PoolManager** `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
The receipt pins the audited bytes by sha256 + git blob id, and those match the hashes in the G1 receipt —
so the findings apply to exactly the bytes that would have shipped.

**This RETRACTS the "G1 MET" posture for the shipping bytes.** G1's three clean rounds were real, but they
were run without a real-PoolManager swap harness; the moment one existed it found two HIGHs in the same
pass. G1 is now **REOPENED**, not met.

| ID | Sev | What | Where |
|---|---|---|---|
| **A-1** | **HIGH** | The empty-pool guard is a **pre-check only**. Post-seed the tick sits exactly on `rung0.tickLower`, so `amountSpecified=-1` with `sqrtPriceLimitX96 = openPrice-1` crosses out of the only active range at **zero cost** (v4 `SwapMath` returns `amountIn=0` when `target==current`, and again at `liquidity==0`), zeroing active liquidity and leaving the guard armed forever. **Attacker holds zero ESSEY and zero USDG and pays nothing. Measured: 33,440 gas. Pool permanently unswappable in both directions.** | `EsseyReserveHook.sol:256` |
| **A-3** | **HIGH** | Compounding A-1. Dust ESSEY buys an ACTIVE rung at spot (no USDG needed when `sqrtP == sqrtLower`), then the A-1 free walk moves price off the peg. `seed()` then reverts `PreInitWrongPrice` **forever**, and no swap can restore the price because the hook bricks every swap at zero liquidity. LaunchSeeder had **no egress path**, so the pre-funded seed allocation (**1.5B ESSEY** in the harness config) was **permanently unrecoverable**. The documented founder procedure was the loss path. | `LaunchSeeder.sol:136-146` |
| **A-4** | MEDIUM | Rails had a reserve FLOOR but **no holders/dons floor**, and `lock()` is one-way with no timelock. A compromised governor could `proposeSplit(10000,0,0)` → 48h → `executeSplit` (permissionless) → `lock()`, **permanently zeroing the holder-airdrop and Dons buckets**. | `EsseyReserveHook.sol:364-370, 403-409` |
| **A-6** | test-integrity | `MockV4Manager.probeSwap` calls only `hook.beforeSwap` — **the mock never runs the v4 swap loop**, so **90 of the gate's 92 tests structurally cannot observe liquidity going to zero mid-swap**. The one real-manager test used a 1,000,000 USDG buy and missed the zero-cost path entirely. | `test/EsseyReserveHookLaunchSeed.t.sol:48,162-164`; `EsseyHookRealSwapSeedFork.t.sol:921` |
| A-2 | not-new | Already known + already tested (deploy precondition #2). Re-verified on chain 2026-09-02 that the precondition **currently holds**: ESSEY `totalSupply == balanceOf(0x93e6…4B9E) == 8,888,888,888e18`. A-3 escalated its consequence from "surcharge lost" to "seed and launch lost." | `EsseyReserveHook.sol:308` |
| A-5 | LOW | Locked positions accrue 0.3% LP fees forever with no collect path. Documented as intentional; **needs explicit founder acceptance**, not silent passing. | `LaunchSeeder.sol:28-31` |

**The lesson worth keeping, because it repeats:** the full V4 suite was **120/120 GREEN with every finding
above live**. Green is not clean. A mock that does not run the real loop manufactures coverage — the same
failure shape as the vault's circular-in-mock `LiquidityAmounts` (F-C, Update (15)) and the keeper's
non-archive-node assumption. **Every gate from here carries a real-fork harness or it does not count.**

**SUPERSEDED: S-1 and S-2 were recorded as LOW.** Update (14) and the tracker carry them as
"⚠️ founder rules fix-vs-accept, neither worse than LOW alone." That was wrong by two severity levels.
A-1 is S-1 with a **zero-cost, zero-balance** trigger; A-3 is S-2 with **permanent loss of the seed
allocation**. "Accept in writing" is no longer available for either.

### 16.3 FOUNDER RULINGS 2026-09-02 (this batch)

| # | Ruling | Consequence |
|---|---|---|
| R-16.1 | **Fix A-1 and A-3 in code; re-gate from ZERO.** | Engineer running now. Supersedes the fix-vs-accept question on S-1/S-2. |
| R-16.2 | **Fee FLOORS for BOTH holders and Dons** — proposed **2500 / 500 bps** against the existing 4000 reserve floor. | Closes A-4. Floors now sum to 7,000 bps, so the governor's reachable space shrinks and reserve gains an *implied ceiling* of 7,000. **Founder: confirm you intend that implied reserve ceiling** — it was not stated in the ruling. |
| R-16.3 | **Rewrite history to scrub the leak.** | ✅ DONE — verified in 16.1. |
| R-16.4 | **Airdrop exclusions = all protocol-owned addresses.** | Keeper eligibility input. Settles a B2 open item. |
| R-16.5 | **Eligibility bar = exactly 0.1%** (10 bps of `totalSupply`). | = 8,888,889 $ESSEY. Keeper knob, not a source constant. Unblocks G2. |
| R-16.6 | **Batch auction REJECTED.** | The launch-economist's batch-auction anti-snipe thread is **CLOSED**. The hook's decaying surcharge + the two-snapshot gate remain the anti-snipe posture. Remove it from the research queue. |
| R-16.7 | **Ceremony ON HOLD at the founder's word.** | **DO NOT RE-RAISE.** O2 (beacon source/height) and the ceremony date are **withdrawn as critical-path items**. The shielded set (#2) is consequently **PARKED, not blocked-and-waiting** — a status change, not a status update. |
| R-16.8 | **Treasury shows full dollar value including FLR.** | Shipped. See 16.4. |

### 16.4 SHIPPED TO PRODUCTION and VERIFIED LIVE (founder-run deploy, 2026-09-02)

Verified by fetching the live bundle — `https://essey.xyz/assets/index-BQOOG3UJ.js`, 4,478,856 bytes,
HTTP 200 — and grepping it. This is chain-of-evidence on the *deployed artifact*, not the source tree.

- **Treasury dollar value** — live, with the honesty logic intact (`unpricedHeld` / `unpricedSymbols`
  present in the bundle: a figure with no price source is **excluded from the total**, never counted as
  zero). **FLR is priced**, closing the long-open "FLR price source" founder blocker: `prices.ts:178`
  `flrPrice()` crosses the Pons V4 ETH/FLR pool against the ETH/USD feed, and fails closed when ETH is
  stale (`prices.ts:42-51,178-211,230`). FLR is in the basket at `reserve.ts:57`.
- **`/tape` on mainnet** — `tape-ui.tsx:1-4` reads `tape-mainnet.ts` (4663); the `live` chip only appears
  after a real read returns. The old game feed `tape.ts:1-3` is now **explicitly fenced** to `/dons/explorer`.
- **`/explorer` is the protocol explorer** — `explorer.tsx:1-9` reads the EsseyReserve's own state and
  history on 4663. **The game-era desk moved to `/dons/explorer`** behind `GameGate` (`App.tsx:339`).
- **`/redeem`** — route exists (`App.tsx:436`), **write surface gated** (`REDEEM_ON`, `App.tsx:63`);
  deep-linking on the live host reaches coming-soon and never a burn.
- **Footer reframed** to the protocol story.

**Two register/tracker claims are now STALE and are corrected here:**
1. **"essey.xyz is currently publishing the wrong fee split"** (Update (14)) — **NO LONGER TRUE.** The
   prod bundle contains "50/40/10" **only inside the dated CORRECTION boxes** (grep of the live bundle,
   3 hits, all in retraction context) alongside the correct 45/40/15. The corrected docs are deployed.
2. **Tracker F1/F2 "honesty defect — play-money SEASON 0 framing reachable from the protocol front
   door"** — **RESOLVED.** The two `SEASON 0` strings surviving in the bundle belong to game components
   that are unreachable behind `GAME_ON`.

### 16.5 BUILT TODAY, NOT DEPLOYED

Verified present in the tree and **absent from the prod bundle** (`grep -c '"/earn"' bundle.js` → **0**).

- **`/earn`** — vault UI, preview-gated (`App.tsx:454`, `EARN_ON` `:79`). Its coming-soon copy already
  states the contract "deploys once its audit clears" — honest, and correct given 16.7.
- **`/lend` rewired to mainnet 4663** with an honest not-deployed state. `lending.ts:30` `LENDING.markets`
  is the **single activation switch** — the founder's deploy turns the page on by setting one address.
  The beacon `0xe10b6f6b…51b00` is now **VERIFIED on chain** (`cast storage` on both Stock Tokens,
  2026-09-02), no longer founder-supplied. **The DCA panel is still testnet 46630** and is labelled as
  such on a mainnet page — recommend it gets its own route so one page does not hold two chains.
- **Holder-airdrop keeper** — 14 files, now **tracked** (`git ls-files rh-chain/keeper/holder-airdrop/`);
  92 keeper tests + 37 Solidity + **46/46 mutation gate**, plus a cross-language proof that a keeper-built
  root replays through the real `HolderDistributor`.
- **Three mainnet-fork harnesses** — `EsseyHookRealSwapSeedFork.t.sol` (50KB), `StockLpVaultFork.t.sol`
  (27KB), `EsseyReserveHookFork.t.sol`; all tracked.
- **Vault `_factor` precision fix** — 17/17 mutants RED. **G3 reset to zero** (Update (15)).

**A finding from the hook fork harness that changes a deploy precondition:** deploy precondition #2
("ESSEY non-circulating until the atomic seed") was **unsatisfiable as written** — ESSEY is already fully
minted to the ops wallet. The real rule is about **TRANSFERS**: the treasury must send ESSEY only to
`LaunchSeeder` until `seed()` completes. Precondition #2 is **restated**, not merely re-verified.

### 16.6 IN FLIGHT RIGHT NOW — the A-1/A-3/A-4 fix (uncommitted, unaudited, NOT verified by the PM)

`git diff --stat`: 5 files, +365/−77 — `EsseyReserveHook.sol` (+30/−?), `LaunchSeeder.sol`,
and three test files. Read, not run. **Reported as data, not as truth.**

- **A-1 fix** — the guard is now **pre-seed only**: `if (launchTime == 0 && getLiquidity(...) == 0) revert EmptyPool();`
- **A-4 fix** — `MIN_HOLDERS_BPS = 2_500`, `MIN_DONS_BPS = 500` added; `_splitWithinRails` now enforces
  both floors; the stale `// PENDING FOUNDER CONFIRMATION` comments are **stripped** — which also closes
  the open contradiction Update (14) flagged between the receipt and the source.
- **A-3 / S-2 fix** — `LaunchSeeder.seed()` gains a post-condition `if (getLiquidity(poolId()) == 0) revert NoActiveLiquidity();`,
  plus a new `recoverGriefedSeed()` egress.

**THREE THINGS THE RE-GATE MUST SPECIFICALLY ADVERSARIALISE. Flagging as PM, not adjudicating:**
1. **`recoverGriefedSeed()` is a NEW egress on a contract whose entire security argument was
   "no egress path exists."** Its own doc comment now has to carry that argument. This is the classic
   shape of a fix that opens a hole — it must be attacked as hard as A-3 was, in every ordering.
2. **Disarming the guard post-launch is a real widening.** A-1's fix trades "bricked forever" for
   "walkable when the ladder legitimately empties at either end." The auditor must prove the post-launch
   zero-liquidity swap cannot be walked for free, not merely that the brick is gone.
3. **A-6 is not fixed by either code change.** 90 of 92 tests still cannot observe the swap loop. The
   re-gate must run on the **real-manager fork harness**, or it re-certifies the same blind spot.

**Hygiene, must clear before commit:** `rh-chain/src/market/EsseyReserveHook.sol.orig` and
`LaunchSeeder.sol.orig` are in the tree, **untracked and NOT gitignored** (`git check-ignore` → no match).
They are pre-fix duplicates of two public contracts. The pre-commit hook does **not** catch them.

### 16.7 GATE LADDER — actual state after this pass

| Gate | Product | State 2026-09-02 (end of pass) |
|---|---|---|
| **G1** hook + LaunchSeeder | B1 | ❌ **REOPENED — round counter ZERO.** Was MET; the real-PoolManager fork harness found A-1/A-3 HIGH in the shipping bytes. Fix in flight (16.6) → then **3 consecutive clean rounds on the real-fork harness**. |
| **G2** HolderDistributor + BasketRegistry | B2 | **Not fired — and now genuinely fireable.** All five params are constructor args (`HolderDistributor.sol:88-100` → immutables `:27-32`), so ruling them changes **zero bytes** and cannot invalidate a round; they become deploy-config preconditions as `feeCurrency=USDG` did at G1. Eligibility bar ruled (R-16.5) and exclusions ruled (R-16.4). **The one real constraint is sequencing:** fire G2 only once the keeper has stopped touching the contract, or the rounds get paid for twice. |
| **G3** StockLpVault | Earn | ❌ **ZERO** — reset by the `_factor` fix (Update (15)). Code sound, fork harness exists (12/12), 17/17 mutants RED. Needs 3 clean rounds on the new bytes. Open founder params before *deploy* (not before the gate): `performanceFeeBps`, `bountyBps`, share name/symbol, and L-A-1's deviation basis. |
| **Ceremony** | Shielded set #2 | ⏸️ **ON HOLD at the founder's word (R-16.7). DO NOT RE-RAISE.** O2 and the date are withdrawn from the critical path. The shielded stack is **PARKED**: 1,207 lines of finished `/private` UI and a fully line-specified rewire (`MAINNET-SHIELDED-SCOPE.md:142-160`) sit ready, and the deployed zkey stays single-contributor — so **nothing shielded may touch real value** while this is parked. That constraint does not expire with the hold. |
| **I** harness (E2E) | B1+B2+B3 | Downstream of G1/G2/G3. |
| **D** founder deploy | all | Founder-gated, per-instance. Unchanged. |

### 16.8 Records corrected or retired by this pass

| Was recorded as | Actually | Evidence |
|---|---|---|
| G1 **MET** (receipt-backed, cited ~15 places) | **REOPENED** — two HIGHs in the audited bytes | `~/.claude/gate-receipts/audit-7fe1cb8` |
| S-1 / S-2 = **LOW**, "founder rules fix-vs-accept" | **HIGH** (A-1 / A-3), zero-cost and loss-of-seed; accept-in-writing withdrawn | same receipt; PoCs `A1Poc/A3Poc.t.sol` |
| `ae143bc` = the source checkpoint | **SHA no longer valid** — history rewritten today; it is `c7d0e60` | `git log --oneline origin/main..HEAD` |
| "ahead 7" of origin | **ahead 14** | `git rev-list --count origin/main..HEAD` |
| "essey.xyz is publishing the wrong fee split" | **STALE** — corrected docs are deployed; "50/40/10" survives only inside retraction boxes | grep of live bundle `index-BQOOG3UJ.js` |
| Tracker F1/F2 "honesty defect on the protocol front door" | **RESOLVED** — `/explorer` is the protocol explorer; the game desk is at `/dons/explorer` behind `GAME_ON` | `App.tsx:336,339`; `explorer.tsx:1-9`; live bundle |
| "No git hooks are installed" (audit structural) | **RESOLVED** — `.githooks/pre-commit`, `core.hooksPath` set, blocks the exact 2026-09-02 leak class | `.githooks/pre-commit`; `git config core.hooksPath` |
| FLR **price source** = open founder blocker | **CLOSED** — priced via the Pons V4 ETH cross, fails closed on a stale ETH feed | `prices.ts:178-211,230` |
| Beacon `0xe10b6f6b…51b00` UNVERIFIED (founder-supplied) | **VERIFIED on chain** for both Stock Tokens | `cast storage`, 4663, 2026-09-02 |
| Deploy precondition #2 "ESSEY non-circulating until the seed" | **Unsatisfiable as written** — ESSEY is fully minted. Restated as a **TRANSFER** rule: treasury sends ESSEY only to `LaunchSeeder` until `seed()` completes | `EsseyHookRealSwapSeedFork.t.sol`; on-chain supply read |
| Batch-auction anti-snipe = live research thread | **REJECTED (R-16.6)** — thread closed | founder ruling |
| Ceremony O2 beacon = "the real critical path #1" | **ON HOLD (R-16.7)** — withdrawn from the critical path; do not re-raise | founder ruling |

### 16.9 Still UNVERIFIED / open in our own records — flagged, not fixed

- **The ~45 failing tests** in `FOUNDRY_PROFILE=v4 forge test` are still **coordinator-reported and never
  re-run by the PM**. Update (15) separately reports the full suite at **1431 pass / 2 fail**. These two
  numbers cannot both describe the same tree. **Settled by:** the engineer running the full tree once and
  pasting the output. Until then neither figure is load-bearing.
- **`EsseyLadderSeeder` at `0x1c9fd50d…5876a` is a REAL mainnet-4663 deployment** nobody is tracking
  (`broadcast/RehearseEsseyLadder.s.sol/4663/run-latest.json`). Despite the "Rehearse" name it is live.
  **Founder: intended, or a rehearsal artifact to document and retire?**
- **`EsseyReserve.sol` appears in NO audit doc** (hygiene finding H4, receipt). The blog asserts "repeated
  adversarial audits" over the contract that holds mainnet money. That claim is **UNSUPPORTED**, and it is
  published. Either cite the round or cut the line.
- **`base-layer-live.md:18,22` is STALE** — "Three tokens right now" / "roughly 0.0093 MSTR" against a
  re-derived on-chain basket of six. The *other* post is accurate; do not "fix" the accurate one.
- **Redemption prose vs. product**: `EsseyReserve.redeem` is live and adminless, but the write surface is
  gated, so a reader who follows the copy finds no Redeem door. Misleading by omission, not false.

*This entry is committed, not left in the tree — per the standing rule from Update (14) that a doc
reconcile is not done until it is committed.*

### PRE-PUSH BLOCKER — history scrub #2 (opened 2026-09-02)
Commit `04e763d` still contains the other private repo's NAME inside `.githooks/pre-commit`'s own
comment — the comment explaining the scrub re-introduced the string the scrub removed. The worktree
is clean (verified: zero occurrences tree-wide); the COMMIT is not. The hook does not catch it
because a bare name is not a path.
**MUST run a second filter-branch over `origin/main..HEAD` before any push.** Verify with a
per-commit loop, not a worktree grep — that is the check that missed it the first time.

---

## Update 2026-09-04 (19) — THE GATE RULE CHANGED. G-LEND reconciled across all nine rounds.

**⚠️ This supersedes §18.1 and §18.2.** Written in answer to the founder's direct question — *where are
the lending audits* — and reconciled from the artifacts, not carried forward. At-a-glance matrix:
[`PRODUCT-TRACKER.md`](PRODUCT-TRACKER.md) ⭐ 2026-09-04 (19) block.

### 19.1 THE RULE — founder ruling 2026-09-04, and it is the most important entry in this register

> *"Redefine the gate as three consecutive rounds with no CRITICAL, HIGH, or MEDIUM. LOWs get logged,
> triaged, and fixed on their own schedule rather than blocking."*

**This replaces "any finding resets the counter,"** which was unreachable in practice: a competent
adversarial auditor will essentially always find something at LOW, so the counter could never close —
not because the code was unsound, but because the bar was perfection. G-LEND ran **nine rounds** under
the old rule and never closed while severity collapsed from CRITICAL to nothing-above-LOW.

Saved as memory `essey-audit-gate-definition`; the enforced wording is in
`~/.claude/bin/guard-git.py:221-223` (**VERIFIED** — read this pass).

**The operative consequence, ruled explicitly by the founder and enforced from here on:**

1. **Three CONSECUTIVE rounds return 0 CRITICAL / 0 HIGH / 0 MEDIUM.** LOWs and INFOs do not block.
2. **Any change to the audited surface resets the counter to zero.** Three rounds against three
   different versions of the code prove nothing — the point is **three independent looks at the same
   bytes.** Each round records the frozen SHA and an empty `git status --porcelain`.
3. **Therefore LOWs are NOT fixed mid-gate.** They are logged with `file:line` and a severity
   rationale and scheduled *after* the gate closes. Fixing a LOW changes the code, resets the
   counter, and the gate never closes for exactly the reason the old rule failed.
4. **A round only counts if it ran against the real substrate** — the receipt must name RPC, chain-id
   and block. A mock-only round does not count.
5. **Severity is the auditor's call, not the engineer's,** and a promotion or demotion carries its
   reasoning. An auditor that promotes a LOW to justify a round is as broken as one that misses a HIGH.

### 19.2 All nine rounds, with report and receipt, re-verified this pass

Every row below was re-read from the report's own verdict line and the receipt's own frozen-SHA line.

| Round | Frozen SHA | Verdict | Report | Receipt |
|---|---|---|---|---|
| 1 | `99a5735` | **1 CRIT**, 1 HIGH, 3 MED, 4 LOW | `glend-round-1.md:12` | `audit-glend-r1` |
| 2 | `de67032` | **1 HIGH**, 2 MED, 4 LOW | `glend-round-2.md:9` | `audit-glend-r2` |
| 3 | `0cf6831` | **1 CRIT**, 1 HIGH, 3 MED, 2 LOW | `glend-round-3.md:9` | `audit-glend-r3` |
| 4 | `cb3e6aa` | **2 HIGH**, 3 MED, 6 LOW | `glend-round-4.md:15` | `audit-glend-r4` |
| 5 | `2804b2e` | 0/0, **2 MED**, 3 LOW | `glend-round-5.md:15` | `audit-glend-r5` + `-r5-fix` |
| 6 | `c04a6ce` | 0/0, **1 MED**, 3 LOW | `glend-round-6.md:14` | `audit-glend-r6` |
| **7** | `2309cb0` | **0 / 0 / 0**, 2 LOW, 3 INFO | `glend-round-7.md:27` | `audit-glend-r7` + `-r7-poc/` |
| 8 | `959b70a` | 0/0, **1 MED**, 4 LOW, 9 INFO | `glend-round-8.md:28` | `audit-glend-r8` + `-r8-fix` + `-r8-poc/` |
| **9** | `1bc9ec7` | **0 / 0 / 0**, 2 LOW, 8 INFO | `glend-round-9.md:49` | `audit-glend-r9` + `-r9-poc/` |

**All nine reports are tracked in git** (`git ls-files docs/audits/ | grep glend` → 9 files) — the
gate ladder's published-report step is met for every round. The round-7 untracked-report blocker
recorded in §18.2 is **closed** (committed in `efe34aa`).

### 19.3 THE COUNT, stated plainly — and it is better than it sounds

| Round | Under the new rule |
|---|---|
| 7 — 0/0/0 | ✅ **qualifies** |
| 8 — 1 MEDIUM | ❌ **resets** |
| 9 — 0/0/0 | ✅ **qualifies → count = 1** |
| *round 9's fixes changed the code* | ❌ **resets to 0** |

> **G-LEND: 0 of 3, on the frozen result of the current engineer pass.** Not 1 of 3, and not because
> a round failed — because rule 2 applies to our own remediation as strictly as to anything else.

**This is verified, not assumed.** `git status --porcelain` this pass shows the audited surface dirty:

```
 M docs/MAINNET-ACTIVATION.md
 M rh-chain/script/DeployMarkets.s.sol
 M rh-chain/src/EsseyPool.sol          <- the audited surface
 M rh-chain/test/EsseyPool.t.sol
 M rh-chain/test/mutants/glend-r4.py
```

The `EsseyPool.sol` change introduces `MAX_FORGIVEN_GAP = 1 hours` and bounds the R9 LOW-1 straddle
(`git diff rh-chain/src/EsseyPool.sol`, read this pass). **Round 9 audited `1bc9ec7`; this is not
`1bc9ec7`.** Rounds 10, 11 and 12 must run on the committed, frozen result of this pass.

**Note the tension, and rule 3 resolves it:** this pass is itself a mid-gate LOW fix, which is what
rule 3 forbids. It was in flight when the ruling landed, so it finishes and is committed — and it is
the **last** LOW fixed before the gate. From the next round on, a LOW is logged and scheduled, never
patched mid-gate.

### 19.4 Round 9 STRUCK two carried-forward items — both were phantom debt

Recorded because both had propagated into the round-8 handoff as standing third-round coverage debt
that **does not exist**, and because the shape is instructive.

- **X-P is not a survivor. REFUTED outright** (`glend-round-9.md:102-157`). The round-8 probe ran it
  against **one test**; "survives" in this gate is defined over the whole `SELECT` suite
  (`test/mutants/glend-r4.py`, `suite_verdict()`). Re-run against the real suite it produces **18
  distinct assertion kills** — the most heavily-killed mutant in the engagement. The algebra is in
  the report: `_deviates` (`src/EsseyMarkets.sol:640-643`) is homogeneous of degree 1, so under X-P
  the common `price` factor cancels and the breaker goes blind to price entirely.
- **`EsseyMarkets.sol:525` points at comment lines** (`glend-round-9.md:161-203`). At `1bc9ec7`,
  `:525` and `:556` are `///` comment text; the real `_confirmable` call sites are `:540` and `:571`.
  Not a coverage gap — the seven candidate mutants at the warm push were all KILLED. Downgraded to
  INFO-3/INFO-4 (the raw push's coverage is incidental rather than targeted).

**The lesson, and it is the sixth instance of a standing shape:** an instrument that runs one mutant
against one test and reports "SURVIVES" carries a claim the measurement cannot support. The five
prior instances produced false GREENs; this one produced a false GAP and cost a round's attention.

### 19.5 Round 8's MEDIUM was pre-existing — it is not a regression of this engagement

`glend-round-8.md:28` returns 0 CRIT / 0 HIGH / **1 MED** / 4 LOW / 9 INFO. The MEDIUM is in
`EsseyPool.accrue()` — an instantaneous borrow-asset pause discarded the **whole** elapsed accrual
interval (`rh-chain/src/EsseyPool.sol:220-223`, `:254-259` at that SHA), destroying ≈$89.86/day of
lender interest at the deployed parameters with nothing bounding `dt`.

**It is not in the corporate-action machinery this engagement built.** The report says so in its own
verdict: *"the finding is not in the delay line… the 41-mutant gate is genuinely 41/41 and I could
not break it"* (`glend-round-8.md:30-35`). **`EsseyPool.sol` predates the engagement** — first
committed in `2c8abc9` (`git log --diff-filter=A`), and the accrual block's blame runs back through
`656dc1c` (*"close borrow-path #5 — narrow interest suspension to borrow asset"*), long before
G-LEND round 1. Seven rounds passed over it. It is a real MEDIUM and it correctly reset the counter;
it is **not** evidence that the hardened surface is churning.

**This does not soften the reset.** Round 8 reset the count, full stop. The provenance matters for
reading the trajectory, not for the arithmetic.

### 19.6 The current engineer pass is NOT clean by its own account

**Engineer-reported, not re-run by the PM: 54/58 mutants killed, four not killed.** The four are the
**magnitude and boundary of the constant the pass itself introduced** — `MAX_FORGIVEN_GAP`.

**The mechanism is VERIFIED from the diff**, which is what makes the report credible rather than
merely accepted: the new tests warp by `p2.MAX_FORGIVEN_GAP()`
(`git diff rh-chain/test/EsseyPool.t.sol` — four call sites), so **a mutation of the constant moves
the test's own warp with it** and the test cannot see the change. That is the fifth-plus instance of
the standing false-green shape — *a test that reads the constant it exists to pin* — and it is the
same defect R4 LOW-1, R5 LOW-1, R6 LOW-3 and R7 LOW-2 each found in a different dress.

**Grounded on disk:** the mutant script carries **58 mutants** (`grep -c '^    ("M'` → 58, last is
`M58`), up from 42, with M43–M58 added for the new constant, its boundary, and the R8 MED-1 guard
re-mutated so one classifier scores the pair. The engineer is correcting the four now.

> **PM position: this pass does not go to the auditor until its own mutation gate is 58/58.** Handing
> a round a surface whose new constant is unpinned spends a round discovering what we already know.

### 19.7 What lending still needs BEYOND the gate — four things, and two are the founder's

The gate is not the last step. Even at 3 of 3, `/lend` does not go live until:

| # | Requirement | Owner | State |
|---|---|---|---|
| 1 | **Three clean rounds on frozen bytes** (rounds 10–12) | `essey-auditor` | **0 of 3** — §19.3 |
| 2 | **Adversarial harness against a REAL deploy** — real wallets, real 4663, real assets | `essey-harness` | **Not started.** Cannot start: nothing is deployed (`rh-chain/broadcast/DeployMarkets.s.sol/` does not exist — VERIFIED this pass). This is a post-deploy gate, so it sits *after* the founder's deploy, not before it |
| 3 | **The guardian-key decision** — single EOA or multisig | **FOUNDER** | Open. §19.8 |
| 4 | **The cap** — per-market number and `maxPositionBps` | **FOUNDER** | **Now answered by the economist** — §19.9 |
| 5 | **Deploy authorisation** — per-instance, founder-only | **FOUNDER** | Not available yet; gated on 1–4 |

**Also still standing, unchanged from §18.2c:** the push of the (now) **31 commits** is blocked on
decision #5, the live anti-scam-page falsehood. `origin/main` is at `6903bc6`;
`git rev-list --count origin/main..HEAD` → **31** (VERIFIED). **Nothing is pushed and nothing is
deployed.**

### 19.8 The guardian key — why it is a decision BEFORE deploy, not after

`address public immutable guardian;` — `rh-chain/src/EsseyMarkets.sol:126`, set once at `:169`
(**VERIFIED this pass**). **There is no rotation. Ever.** A lost or unavailable guardian key
permanently removes the only corporate-action lever, and the remedy is a full registry redeploy plus
market migration.

Note the asymmetry that has confused this decision before: **`LivenessOracle` has a *different*
guardian, and that one CAN be rotated** (`proposeRotation`/`commitRotation`, `LivenessOracle.sol:203`,
`:220`, 2-day timelock). The rotation that exists is not the one that matters here. The
`EsseyMarkets` guardian is immutable and the choice is made at deploy or never.

- **Multisig:** survives a lost or unavailable holder; costs signing latency against a 24h window —
  survivable, since ex-dates are known weeks ahead (`RUNBOOK-EX-DATE-PAUSE.md` §4).
- **Single EOA:** one lost key ends the lever permanently.

### 19.9 The cap is ANSWERED — it is a tolerance decision, not a design one

**Economist-reported (`don-economist`), UNVERIFIED by the PM — no cap-analysis doc exists on disk;
`grep -rn '62_500\|74 days' docs/` returns only an unrelated round-8 caveat. What would settle it: the
economist's model output committed to `docs/`.**

- **Bad debt measured at $0 across every cap from $25k to $1M, over 74 days of both live feeds.**
- Therefore the cap **does not trade off against bad debt.** It trades off against **tolerance** —
  how much exposure the founder is willing to have open at once.
- **Option A:** `$62,500`/market with `maxPositionBps` raised to **4,000** → **$25k tolerance**.
- **Option B:** keep the current `$250,000` with `maxPositionBps` at 2,000 → **$100k tolerance**.
- **The residual that dominates is wrongful seizure, not bad debt** — which is precisely what rounds
  3–7 were spent closing (R3 HIGH-1's 2,592 bps harvest, R4 HIGH-1/HIGH-2's $381.84 and $1,618.18 on
  a $1,472.67 position, `glend-round-4.md:606-607`).

**Currently in the deploy script** (VERIFIED, `rh-chain/script/DeployMarkets.s.sol:395-396`):
`cap: uint128(250_000 * 10 ** assetDecimals)` and `maxPositionBps: 2_000`. **Option B is what ships
if unruled.**

⚠️ **Editing `:395-396` pre-deploy edits the G-LEND audited surface** — the deploy script is in scope
(R1 MED-2 and R2 LOW-3 were both `DeployMarkets` findings). Under rule 2 that **resets the counter**.
**Rule the cap BEFORE rounds 10–12 start, or accept 250k/2000 and change it after deploy through the
2-day timelock** (`EsseyMarkets.sol:735`, `:753`, `:795` — zero bytes to change it later).

### 19.10 Decision list refreshed

Ordered, with what changes on each branch, in
[`PRODUCT-TRACKER.md`](PRODUCT-TRACKER.md) §DECISION LIST. Changes this pass: **#3 (cap) moves from
*awaiting the economist* to *awaiting the founder*, with a deadline — before round 10 starts**;
**#8 corrected 27 → 31 commits**; **#4 (guardian) re-grounded** and its ordering constraint restated
(#4 gates #9; the deploy script refuses without `GUARDIAN`).

---

## Update 2026-09-04 (18) — G-LEND rounds 5, 6, 7: the severity curve reaches zero

**⚠️ This supersedes the G-LEND row in §17.8, which was three rounds stale.** Rounds 5, 6 and 7
appeared nowhere in this register until now. At-a-glance matrix:
[`PRODUCT-TRACKER.md`](PRODUCT-TRACKER.md) ⭐ 2026-09-04 block.

### 18.1 The full seven-round trajectory, with receipts

| Round | SHA | Verdict | Report | Receipt |
|---|---|---|---|---|
| 1 | `99a5735` | **1 CRIT**, 1 HIGH, 3 MED, 4 LOW | `glend-round-1.md:12` | `audit-glend-r1:4` |
| 2 | `de67032` | **1 HIGH**, 2 MED, 4 LOW | `glend-round-2.md:9` | `audit-glend-r2:4` |
| 3 | `0cf6831` | **1 CRIT**, 1 HIGH, 3 MED, 2 LOW | `glend-round-3.md:9` | `audit-glend-r3:2` |
| 4 | `cb3e6aa` | **2 HIGH**, 3 MED, 6 LOW | `glend-round-4.md:16` | `audit-glend-r4:6` |
| 5 | `2804b2e` | 0/0, **2 MED**, 3 LOW | `glend-round-5.md:16` | `audit-glend-r5:5` |
| 6 | `c04a6ce` | 0/0, **1 MED**, 3 LOW | `glend-round-6.md:14` | `audit-glend-r6:14` |
| **7** | `2309cb0` | **0 / 0 / 0**, 2 LOW, 3 INFO | `glend-round-7.md:17` | ✅ `audit-glend-r7` (5,161 B, 10:33) |

### 18.2 Round 7 is clean and COUNTS. G-LEND is 1 of 3.

Receipt **verified present**: `~/.claude/gate-receipts/audit-glend-r7`, 5,161 bytes, 2026-09-04 10:33,
with an `audit-glend-r7-poc/` directory beside it. It records the frozen SHA `2309cb0`, a real 4663
mainnet-fork substrate (`eth_chainId 0x1237`, block 54426499), an empty `git diff --stat 2309cb0`, and
every sha256 re-taken identical at end of round.

*An earlier check in this session ran before 10:33 and reported the receipt absent. That finding is
**withdrawn**; the timing was mine, not the auditor's.*

**What still stood at the time of writing:** `docs/audits/glend-round-7.md` was **untracked**. The
gate ladder's published-report step is not met until it is committed — we retracted someone else's
"audit-clean" claim on 2026-09-03 for a missing artifact (§17.1, `:1409-1415`), and the rule binds us
symmetrically. **Closed:** committed in `efe34aa` (`git show --stat efe34aa`). Rounds 8 and 9 remain.

### 18.2a Round-7 LOWs and INFOs fixed (working tree, NOT committed)

Engineer pass on top of `2309cb0`. `git diff --stat 2309cb0 -- rh-chain/src` is **one file, comment
only** — proven by stripping `//` and blank lines from both versions and diffing (identical). No
contract behaviour changed; everything below is tests, the keeper supervisor, and docs.

| Finding | Fix | Where |
|---|---|---|
| **LOW-2** the warm push's multiplier half unpinned (survivor X-A, 397/397) | the discriminating test the auditor wrote, landing the leg while the feed still READS; verified green on the tree, red on X-A, red on M27 | `test/GLendR7.t.sol:26` · gate `M38` |
| **LOW-1 A** `FEED DARK` unbounded in duration | `MAX_DARK_AGE = 345_600s` (4 days), overridable with `FEED_DARK_CEILING`; sized against the measured worst gap, which is the 2026-07-02 → 07-06 Independence Day weekend (79.74h AAPL / 76.09h NVDA) against 52-58h for an ordinary one | `keeper/keeper-health.mjs:32` |
| **LOW-1 B** four `priceOf` reverts read as one | only a decoded `PriceStale` is the calendar; `PriceNotPositive` / `RoundIncomplete` / `FeedNotConfigured` and anything undecodable are fatal `FEED BROKEN`. Error definitions added to `marketsAbi` because viem decodes `errorName` only for declared errors | `keeper/keeper-health.mjs:25,38` · `check-liveness-keeper.mjs:80` |
| **INFO-1** the horizon omitted the keeper term | stated as **max feed gap + tolerated keeper gap + `PRICE_CONFIRM_DELAY` + `CONFIRM_STEP`**, with the SLO that bounds the middle term named (**12h — 9h to `UNOBSERVED`, 3h to restore; an operational commitment awaiting the founder's ratification**). Full horizons 100h / 96h, worst move unchanged at 1.69x / 1.65x | `MAINNET-CONFIG.md` · `EsseyMarkets.sol:396` · `measure-feed-volatility.mjs:107` |
| **INFO-2** two one-sided tests | `GLendR6WarmSource` now pins that the line MOVED (it passed under M27 before); `GLendR6.t.sol:126`'s assertion was identical in the opposite world and now reads what the observing keeper actually bought; the two `assertLt(secs, 12 hours)` bounds now use the same constant R5's sibling does | `test/GLendR6.t.sol` |

**A SIXTH false green, found while fixing the fifth.** `head.mult` → `confirmedObservation(token).mult`
— the multiplier half taken from the READ slot, four steps behind the head — **survived 398/398**,
including the test just written for LOW-2. Every fixture in the suite varied five prices across the
ring and held one multiplier, so R5's older-slot test pinned only the price half. Not equivalent: it
pairs a post-leg price with a pre-leg multiplier for a whole outage, which is R4 MED-1's harm in both
directions. Pinned by `test_theWarmedMultiplierIsTheLastKnownGoodPairNotAnOlderSlot`
(`test/GLendR7.t.sol:59`), gate `M40`, with `M39`/`M41` added so each argument is attacked
independently against each wrong source. That test pins the PROPERTY rather than one mutant — the
two further wrong-slot variants (`+2`, `+3`) are killed by it too, on the same assertion.

**Two tool defects fixed because they corrupt the evidence, not the code.** `test/mutants/glend-r4.py`
restored its mutant in a `finally`, which a SIGTERM skips — a killed run left a live mutant on disk
looking like an ordinary edit (observed: the age CEILING silently removed). And a fork-backend 429
prints as `[FAIL: …`, so an unlucky mutant read as **KILLED by evidence that never ran**. Both are
now handled: signal handlers restore every touched file, and a transport-only failure is retried and
reported `RPC-FLAKE` rather than counted.

**Not touched, by instruction:** `docs/RUNBOOK-EX-DATE-PAUSE.md` and `keeper/measure-halt-baddebt.mjs`.
**Open, pre-existing, not mine:** `forge build` under the DEFAULT profile fails `Stack too deep` — 
reproduced on a clean `git archive 2309cb0` tree, so it predates this work; `FOUNDRY_PROFILE=script`
and `FOUNDRY_PROFILE=v4` both exit 0.

### 18.2b Citations decay — the `:274-282` post-mortem

`DeployMarkets.s.sol:274-282` was repeated as the risk-params location across this register, the
tracker, `MAINNET-LENDING-SCOPE.md` and `app/web/src/lending.ts`. It is `:393-396` today. **The
auditor who first wrote it was correct** — at round 1's SHA `99a5735` that range was exactly the
`Market` struct literal (`git show 99a5735:rh-chain/script/DeployMarkets.s.sol | sed -n '274,282p'`).
Six rounds of fixes grew the file ~120 lines.

**Rule adopted: line citations in status docs are SHA-relative and must be re-derived, never copied
forward. Cite `symbol` + `file:line` so staleness is self-correcting.** Fixed in the three live docs
and the frontend comment. **Audit reports are not rewritten** — they record what was true at a frozen
SHA.

### 18.2c ⚠️ PUSH BLOCKER — a false sentence is live on the anti-scam page

**Confirmed, not inferred.** Two deployed contracts are named `essey` in our own frontend:

- `app/web/src/reserve.ts:35` — `0x315790B5…071610`, **mainnet 4663**, canonical, live since 2026-08-29.
- `app/web/src/live.ts:29` — `0x32a860B1…23d1F`, commented **`// $ESSEY v2 (8.888B supply)`**, inside
  `ADDR` scoped to `NET = { chainId: 46630, "Robinhood Chain Testnet" }` (`live.ts:14-21`).

`app/web/src/blog/posts/only-real-essey-contract.md:14` — **published to essey.xyz 2026-09-01** —
states *"There is no second contract, no "v2", no bridge, no pre-sale address."* That is **false as
written**, and the falsifying evidence is a comment in our own public repo.

**The correction must be scoped to mainnet, and must NOT claim a second mainnet $ESSEY** — the other
token is testnet play-money. Asserting a mainnet collision would be a false alarm on the anti-scam
page, worse than the original imprecision. The post's substance is right; only its absolutism is
wrong. Scoping it to chain 4663 makes it true *and* stronger anti-scam copy. Jester dispatched;
full framing in [`PRODUCT-TRACKER.md`](PRODUCT-TRACKER.md) §"Decision #5, in full".

**This gates the push (#8): the 27 commits include the post (`3bb9449`).**

### 18.3 The churn is in the bolt-on — from round 3, not from the start

Recorded because it is the difference between *"the lending engine is unsound"* and *"one bolt-on is
young"*, and because the strong form is false:

- Rounds 1–2 raised **five core-engine findings** — R1 MED-1 (collateral pause blocked repayment while
  interest accrued, `glend-round-1.md:277`), R1 LOW-1/LOW-3/LOW-4 (`:393`, `:464`, `:488`), R2 LOW-1
  (escrow applied to the borrower's side only, `glend-round-2.md:224`). All closed, none reopened.
- **From round 3 onward every CRIT/HIGH/MED has been in the corporate-action breaker** or its
  keeper/role scaffolding. No engine finding above LOW has ever been raised.
- The engine was **positively verified on a real fork**, not merely unmentioned — seizure accounting,
  `adminBurn` pro-rata sharing to 12 decimals, reentrancy on all five entry points, pool isolation,
  write-off to the wei, the full rate curve (`glend-round-1.md:549-606`).

**Correction to the program's own framing:** the breaker did **not** first exist at round 2. It dates
to `9c1a99e` and `676c205`, both **2026-08-09**; round 1 found that August version broken against the
real Stock Token (CRIT-1, `glend-round-1.md:100`). The named `_breaker` state machine is the round-2
fix (`0cf6831`). This register had no entry for the August origin.

### 18.4 The operational half now exists: the ex-date pause runbook

[`RUNBOOK-EX-DATE-PAUSE.md`](RUNBOOK-EX-DATE-PAUSE.md). The founder asked whether a simpler
operational approach could replace the machinery. **It covers the announced case entirely and the
surprise case not at all** — an oracle misprint or an off-schedule issuer produces no announcement to
watch for. The answer is both, and the runbook says so in its own §0 and §8 so it cannot be quoted as
an argument for dropping the breaker.

Five findings from writing it, none of which were in any doc:

1. **`pauseLiquidation` alone is unsafe** — `canBorrow` (`EsseyMarkets.sol:324-346`) never reads
   `liquidationPausedUntil`. Always `disableMarket` first; cost is the 2-day re-enable.
2. **The pause duty cycle is exactly 50% at any length** (`:865-866`). Contiguous cover maxes at 30h,
   then a 24h hole no lever closes.
3. **A ≤20% action gets zero automatic cover** — `_deviates` is strictly `> 20%` (`:620-623`).
4. **The weekend needs no pause** — past 25h staleness `canLiquidate` is already false (`:714-721`).
   Dark window is ~55h worst-measured (`:508`), not the ~40h in circulation.
5. **The guardian is `immutable`, no rotation** (`:126`, `:169`). **Founder decision before deploy.**

**Build gap:** no corporate-action watcher exists in `rh-chain/keeper/`. Recommend queueing one to
`essey-protocol-engineer` after G-LEND clears.

### 18.5 Cap mechanics prepared; the number is the economist's

Mechanics brief in [`PRODUCT-TRACKER.md`](PRODUCT-TRACKER.md) §CAP. Not immutable — 2-day timelock,
zero bytes (`EsseyMarkets.sol:735`, `:753`, `:795`). Per-market caps are supported (`:133`). **At cap
250k the static cap only binds while depth is under 750k USDG** (`capFractionBps = 3_333`,
`MarketHealthOracle.sol:97`); above that the depth oracle governs, so bad-debt modelling must run
against `min(static, effectiveCap)` (`EsseyMarkets.sol:220-227`), not the static cap alone.

**Params citation corrected program-wide:** the risk params are at `DeployMarkets.s.sol:393-396`, not
`:274-282` as recorded in §17 and the tracker.

### 18.6 Unpushed count corrected

**27**, not 17 (`git log --oneline origin/main..HEAD | wc -l`; HEAD `2309cb0`).

---

## Update 2026-09-03 (17) — OVERNIGHT PROGRAM RECONCILE: lending is UNAUDITED, two HIGHs closed, G2 not clean

Written by the PM at the start of the founder's ~12-hour overnight window. Every claim below was
re-derived this pass from the repo, the gate receipts, and the working tree. **Recall was not used.**
Where this entry disagrees with Update (16) or the tracker, **this entry wins**; where it repeats a
claim it could not re-verify, it says so and names what would settle it.

### 17.1 THE HEADLINE CORRECTION — lending has NEVER been through a clean audit gate

Both docs currently assert lending is done. **`PRODUCT-TRACKER.md` row D1 reads
"audit-clean, 3 consecutive clean rounds, pushed public."** That claim is **RETRACTED as
unevidenced.** There is **no receipt of any kind** behind it:

- `docs/audits/` holds 11 reports (`ls docs/audits/`). The **only** ones covering the lending engine
  are **Solidity 1 and Solidity 2**, and `docs/audits/README.md:36-37` records them as
  *"criticals + highs fixed; tail open"* and **"not clean; ~50 mutations survive a green suite."**
- `~/.claude/gate-receipts/` holds no lending receipt. The Essey receipts there are
  `audit-7fe1cb8` (G1 R1), `audit-g1-r1`, `audit-g3-r1`, `audit-g2-r1`, `audit-esseyreserve-r1` —
  all 2026-09-02, none naming `EsseyPool` / `EsseyMarkets` / `EsseyMultiply` / `MarketHealthOracle`.
  *(The 2026-09-03 receipts in that directory — `audit-fb55aca`, `audit-79e1860`, `audit-704493d`,
  `audit-9894a18`, `audit-62ef234`, `audit-aa3a255` — belong to a **different project**; they name
  `feat/consume-name-guard`, `feat/bookkeeper-receipt` and an auth-database suite. The receipts
  directory is shared across repos. Do not count them here.)*

**RULING, standing until a receipt exists: lending is `built-not-audited`.** Every downstream
statement — the register's flow #3, the tracker's D1 and the "audited flow with a finished UI"
framing in the hand-off list — inherits that. **This time the artifact gets published**: the round
does not count until a report lands in `docs/audits/` naming the files and pinning their sha256.

**The process defect worth keeping.** This is the *third* time a gate was believed met on evidence
that did not exist or did not test what it claimed: G1's three clean rounds (real, but run without a
real-PoolManager harness — Update 16.2), the vault's circular-in-mock `LiquidityAmounts` (F-C,
Update 15), and now lending's rounds, for which nothing was written down at all. The pattern is not
carelessness in the audit; it is **a claim entering the register without a receipt attached**.

### 17.2 Fixture hardening — RUNNING NOW, and 5 of the 7 blockers already have fixtures in tree

Seven blockers were raised where a named mutation currently SURVIVES the lending suite, plus eight
weak assertions. **Source: relayed to the PM by the orchestrator; the PM did not run the mutation
campaign and does not report the survivor set as independently verified.** What the PM *did* verify,
by reading `git diff` on a dirty tree at 2026-09-03 (2 files, +42/−6 → since grown), is which
blockers now have a fixture:

| # | Blocker | Fixture in tree? | Evidence |
|---|---|---|---|
| 1 | Rounding direction unpinned across the valuation stack (every test price is a whole dollar, so truncation has nothing to truncate) | ✅ **three sites** | `test/EsseyMarkets.t.sol` `test_valuationRoundsDownAtEveryStage` (price `20_000_000_011`, pins `collateralValue`, `maxBorrow`, both sides of `isUnderwater`); `test/EsseyPool.t.sol` `test_liquidationSeizureRoundsDownNotUp`; `test_positionLimitTruncatesAgainstTheLiveCap` |
| 2 | Interest accrual pinned once at 1% relative tolerance — a 365→360 day year survives | ✅ | `EsseyPool.t.sol`: `assertApproxEqRel(...,0.01e18)` replaced with `assertEq(debtOf, 770e6)`, plus a new `test_accrualOverANonRoundIntervalIsExact` pinning `borrowIndex` to the wei over a 1,000,000 s interval |
| 3 | `reserveBps` magnitude unpinned — doubling it routes 100% of interest to the protocol, zero to lenders | ✅ | `EsseyPool.t.sol` `test_reserveSplitIsExactBothWays` — a `reserveBps 5_000` pool pinning `totalReserves == 35e6`, `totalAssets == 100_035e6`, and `previewRedeem` |
| 4 | `EsseyMultiply` only tested at 18 decimals; **mainnet USDG is 6** | ❌ **not started** | `test/EsseyMultiply.t.sol` still binds `ScaledUIStockMock usdg` (`:58`) and the only decimal bound in the file is `1e18` (`:321`) |
| 5 | The swap mock reproduces the contract's own formula, so `maxSlippageBps` is unpinned | ❌ **not started** | `MockSwapAdapter` (`EsseyMultiply.t.sol:20-26`) is constructed from the same `MockFeed` the contract prices against (`EsseyMultiply.sol:258-265` `_buyStock` derives `minOut` from that feed) |
| 6 | Four of five `MarketHealthOracle` timelocked params have no behavioural fixture | ❌ **not started** | `Params` = `capFractionBps, hysteresisBps, maxRaisePerDayBps, raiseDelay` (`src/MarketHealthOracle.sol:58-63`) — R3 INFO-3: `v4DiscountBps` was deleted and this row still cited it. `test/MarketHealthOracle.t.sol` pins the **mechanism** (`test_paramChangeIsAdminProposedTimelockedAndPermissionlesslyCommitted:614`, `..Cancelled:632`, `..BoundsAreValidatedAtPropose:645`) — no test changes a param and asserts the behaviour moves |
| 7 | The `rampBase == 0` path never exercises its `min()` | ❌ **not started** | `src/MarketHealthOracle.sol:140-145` — `if (base == 0) { base = _clampedBase(token, c.pendingRaiseTo); … }`; no test in the file's 32 named tests targets it |

**#5 is the one to watch, and it is not a fixture problem — it is the circular-mock class again.**
A mock that recomputes the contract's own formula cannot falsify the contract. That exact shape
voided G1 (A-6, 90 of 92 tests blind to the swap loop) and G3 (F-C, the vault's dilution test
measuring dilution with the biased function it was auditing). Making it the third occurrence in one
week. **The slippage fixture must drive the adapter's output from an independently specified value,
never from the oracle the contract reads.**

### 17.3 Two HIGHs CLOSED overnight; G1 and G3 both restart from ZERO

`58523e1` *fix(hook,vault): charge the fee on the fill, price the vault at the composition it holds*
(2026-09-03 10:02 PT, `git show --stat 58523e1`) closes the two round-1 HIGHs:

- **G1-1 (HIGH), hook** — the swap fee was charged on the amount **requested**, not the amount
  **filled** (`EsseyReserveHook.sol:260,275,326`; receipt `~/.claude/gate-receipts/audit-g1-r1`).
  Measured on a real 4663 fork: a 5,000,000 USDG buy filled 117,616 and was charged 50,000 —
  **4,251 bps against an advertised 100**. A specified-leg fee now demands a complete fill; an
  over-ladder exactIn buy reverts `PartialFill` instead of filling short. The refund alternative was
  rejected in writing (v4's `afterSwap` can only move the unspecified currency, and the refund path
  pays the router).
- **second hook finding, founder-flagged** — exactIn charged bps of the gross, exactOut bps of the
  net. Harmless at the 1% steady state; **at the t0 anti-snipe surcharge it was a ~50x hole** — a
  sniper flipping one router flag paid ~4,975 effective bps instead of 9,900. `_feeParts` now
  grosses up on exactOut.
- **G3-1 (HIGH), vault** — `_valueAtOracle` priced the LP position at the composition it *would*
  hold at the oracle price, not the one it holds at spot (`StockLpVault.sol:422-438`; receipt
  `audit-g3-r1`). V3 position value is concave, so the as-held figure sits strictly above the curve
  and **understated the vault in both directions**: measured $206.73 skimmed at 90 bps deviation,
  $1,040.97 at 465 bps, zero-sum to 18 significant figures. Now reads spot, which inverts the sign.
- **vault first-depositor inflation (MEDIUM)** — closed with an ERC4626 virtual offset,
  `VIRTUAL_SHARES = 1e12`, sized three orders inside both measured failure bounds.

**Gate consequence: G1 and G3 are each at ZERO with new bytes.** Neither contract is deployed
anywhere (verified in the commit's own claim and by the absence of any 4663 broadcast for either).

### 17.4 EsseyReserve — round 1 CLEAN on the money, with deployed bytecode verified against source

Receipt: `~/.claude/gate-receipts/audit-esseyreserve-r1` (2,113 bytes, 2026-09-02).

- **Bytecode verification — VERIFIED.** `cast code 0xd970Ca72…5A7b` on chain 4663 is byte-identical
  to `solc 0.8.28` over `rh-chain/src/market/EsseyReserve.sol` (optimizer disabled, legacy pipeline)
  after masking the 11 immutable slots and the 53-byte metadata trailer. `EsseyToken` likewise.
  **This is the first time a deployed Essey contract has been proven to be the source we publish.**
- **VERDICT: CLEAN** on custody, solvency, authority, rounding, reentrancy and paused-token
  isolation. **No fund-loss finding. No patchable defect.**
- Three non-blocking findings recorded: **R-1** self-backing not enforced + `circulatingSupply`
  manipulable; **R-2** a 5% terminal strand; **R-3** a test gap — the CEI-removal mutant (MUT4)
  **survived both suites** while 9 of 10 others were killed.
- **The two risks that dominate contract risk are operational, not code:** the treasury EOA is a
  single key over 100% of redemption rights, and issuer pause/upgrade on the stock legs is
  unrecoverable inside an adminless vault.

**`docs/CUSTODY-AUDIT-STATUS.md` was STALE against this** — it still read *"UNAUDITED at the time
value was deposited… Accepted by: nobody yet"* a day after the round came back clean. Corrected in
this pass. **And the gate that file feeds has a hole worth naming:** `app/web/check-custody-audit.mjs:52-53`
tests only that the contract's **name appears** in the status file — it cannot distinguish "audited
clean" from "unaudited, accepted by nobody." A stale scare-line passes the build exactly as well as
a clean receipt. The gate proves the question was *asked*, not that it was *answered*.

**Not published yet, deliberately.** The receipt does not go into `docs/audits/` as-is: R-1 and R-2
are unpatchable residuals on a **live, immutable, adminless** contract holding real value, and the
fix-first policy (`docs/audits/README.md:12-16`) publishes exploit detail only after the fix lands.
A public report needs a redaction pass and founder sign-off. **Queued, not skipped.**

### 17.5 G2 — NOT CLEAN. 3 HIGH, 4 MEDIUM, 5 LOW. Round counter at ZERO.

Receipt: `~/.claude/gate-receipts/audit-g2-r1` (4,409 bytes, 2026-09-02), over
`HolderDistributor.sol` and `BasketRegistry.sol`, sha256-pinned. The suite was **green at audit
time** — 32 + 5 Solidity, 92 keeper, 46/46 mutation gate — and **caught none of these**.

| ID | Sev | What |
|---|---|---|
| **H-1** | HIGH | `postRoot` is unconstrained: the poster can name **itself** sole recipient of a whole epoch (`HolderDistributor.sol:173-188`, `_settle:256-271`). The stated containment "cannot name a payout recipient" (`keeper.mjs:8,14-17`) is **FALSE**. Only defence is the governor's `challengeRoot`. |
| **H-2** | HIGH | `renounceGovernor():307-310` deletes that only defence permanently, and makes the H-1 theft **permissionless** (fallback `_authorizePoster:149-153`) and **free** (bond unslashable, withdrawn after `activeAt`). |
| **H-3** | HIGH | No on-chain exclusion enforcement; `config.mjs:33 EXCLUSIONS` is optional and defaults to `[]`. On chain 2026-09-02, ESSEY `totalSupply == balanceOf(0x93e6…4B9E)` = 100%. **Unset EXCLUSIONS silently routes 99.77% of every epoch to ops.** `env.example:24` lists 1 of the 5 ruled addresses. |
| M-1 | MED | A `slashSink` that rejects ETH bricks `challengeRoot` (`:203-204`) — the only defence against H-1 cannot run. The test `RevertingSink` (`:73`) is **dead code, never instantiated**, while its comment claims it proves this case. |
| M-2 | MED | USDG has no exit but `converter.convert`; a dead oracle / delisted stock / off-session strands the pot forever. No timeout rescue for an un-rooted epoch. |
| M-3 | MED | `lastRootAt` is global (`:176,185`): a fallback poster locks the keeper out every cycle, so the fallback stays open forever. |
| M-4 | MED | The root commits to nothing off-chain — no manifest hash, preferences in a private JSON with no on-chain anchor. **`challengeRoot` has no evidentiary basis.** |
| L-1…L-5 | LOW | `minBond`/`minEpochInterval` accept 0; registry proposals never expire; `leafOf:314-316` omits `address(this)`/`chainId` (cross-deploy root replay); `ChallengeWindowActive` means opposite conditions at `:196` and `:259`; preference sigs never consumed on-chain and have no nonce floor. |

Verified clean and worth keeping: the Merkle construction (double-hashed, domain-separated,
second-preimage safe), claim accounting (CEI + `nonReentrant` + per-`(epoch,holder,token)` flag +
per-epoch reserved cap), epoch isolation, `sweepEpoch` bounds, and the EIP-712 domain binding.

**Register consequence: the tracker's "G2 — not fired, now genuinely fireable" is superseded. G2
HAS fired, and it came back NOT CLEAN.** Fix → three fresh rounds.

### 17.6 Push state, and one pre-push item that is now CLOSED plus one that is not

- **`origin/main..HEAD` = 17 commits** (`git rev-list --count`, 2026-09-03). origin/main is
  `6903bc6`. Update (16)'s "ahead 14" is stale by three.
- **The Update (16) PRE-PUSH BLOCKER (history scrub #2) is RESOLVED.** It named commits `ae62d34`
  and `04e763d` as carrying the other private repo's name inside `.githooks/pre-commit`'s own
  comment. Re-derived this pass: `ae62d34` **is no longer in the range** at all, and the hook file
  is touched by exactly two commits in the range (`65ca1fc`, `cbbc3cd` — `git log -- '.githooks/pre-com*'`).
  Reading the blob at each: `65ca1fc` already carries `"[redacted]"` in place of the name, and
  `cbbc3cd` generalises it further to "another private repo". **No commit in the current range
  carries the bare name in that file.**
  *Scope limit, stated plainly:* the PM verified the **one file the register named**. A full-range
  scan for the two actual names cannot be run from a tracked doc without re-creating the leak —
  **the founder should run it from the shell before authorising the push.**
- **NEW, and open: four files at HEAD carry an absolute home path** — `git grep -lE
  '/Users/[A-Za-z0-9._-]+/(Developer|Documents|Desktop)/' HEAD` returns
  `app/web/_private_haircut_smoke.mjs`, `docs/RESUME-balance-and-h1.md`,
  `docs/RESUME-trait-calibration.md`, `rh-chain/xyz.essey.game-keeper.plist`. The only string
  present is the repo's own absolute path — **not** another repo's name, so this is
  username/layout disclosure on a public repo, not a private-repo leak. **But it is precisely the
  class `.githooks/pre-commit:42-43` blocks**, which means these four files would fail the repo's own
  gate if re-staged today. Pre-existing (they predate the hook); the hook only sees newly staged
  blobs. **Clear before the push.**

### 17.7 Test-count contradiction — one number now, still not PM-verified

Update (16.9) left two irreconcilable figures ("~45 failing" vs "1431 pass / 2 fail"). The
`58523e1` commit body reports **1438 pass / 2 fail against a 1431/2 baseline, same two pre-existing
`setUp` failures**, plus V4 146/146, vault in-mock 65/65, vault fork 13/13.

**Still not settled, and deliberately so.** That is an engineer-reported figure in a commit message,
not output the PM ran. **The PM did not run `forge test` this pass on purpose:** the engineer is
mid-edit on `test/EsseyPool.t.sol` and `test/EsseyMarkets.t.sol` right now, and a second concurrent
`forge` invocation shares `out/` and `cache/` in the same checkout — a collision would produce
failures neither agent could attribute. **Settled by:** the engineer pasting a full-tree run on a
clean tree at a named SHA when the fixture work lands. Until then, `1438/2` is the best number we
have and it is labelled.

### 17.8 GATE LADDER — state at the top of the overnight window

> ⚠️ **The G-LEND row below is a 2026-09-03 SNAPSHOT and is three rounds stale. Superseded by
> [Update 18.1](#update-2026-09-04-18--g-lend-rounds-5-6-7-the-severity-curve-reaches-zero).**
> Rounds 5, 6 and 7 are recorded there. Do not quote this row as current state.

| Gate | Product | State 2026-09-03 | What moves it |
|---|---|---|---|
| **G-LEND** | Lending: `EsseyPool`, `EsseyMarkets`, `LivenessOracle`, `CollateralReconciler`, `StaleFeedGuard`, `MarketHealthOracle`, `Note`/`NoteArt` | ❌ **ZERO — round 4 returned NOT CLEAN (2 HIGH, 3 MED, 6 LOW), counter reset again** (`docs/audits/glend-round-4.md`). All findings fixed in the working tree, **uncommitted and re-audit pending** — see Update 17.9 below. Round 3's CRIT-1 and MED-3 were confirmed genuinely closed and stay closed under the new code | Round-5 re-audit from zero → **3 consecutive clean rounds, all lenses, on a real 4663 fork** → **report published to `docs/audits/`** → harness → founder deploy |

### Update 17.9 — G-LEND round-4 findings fixed (2026-09-04, working tree, NOT committed)

Round 4 (`docs/audits/glend-round-4.md`, frozen SHA `cb3e6aa`) returned **NOT CLEAN**. Its central
finding is the one worth carrying forward: `test_theCorroborationDelayBoundaryIsExact` **performed the
bypass it was named to prevent and asserted the result** — a test that pinned the promotion RULE while
the security PROPERTY went untested, through three green rounds.

| Finding | Fix | Where |
|---|---|---|
| **HIGH-1** `PRICE_CONFIRM_DELAY` was not a delay: the rate limit ran on the PROMOTION clock, which any permissionless caller positions, so the delivered wait was one second on real AAPL for 2,592bps | a DELAY LINE: observations pushed no faster than `CONFIRM_STEP` apart, and the read is always the oldest of `CONFIRM_SLOTS`; `corroboratedValue` re-tests that age in both directions, so the property does not rest on the push cadence being right | `EsseyMarkets._confirmable` / `confirmedObservation` / `corroboratedValue` |
| **HIGH-2** the breaker was load-bearing on an unsupervised keeper with a hand-typed market list, and failed OPEN | `MAX_CONFIRM_AGE` makes an unobserved market lose its corroborated price entirely (fail CLOSED); the keeper DERIVES its market list from `MarketCommitted` logs and alerts on any disagreement; `observe()` escalates like `beat()` does; **a unit for the on-chain symptom check is BUILT AND DOCUMENTED — NOT INSTALLED** (R9 LOW-2: this row previously read "now actually RUNS", which was false on the operator machine) — R8 LOW-1 found that the only launchd unit supervised the keeper process, while `check-liveness-keeper.mjs`, the sole thing that detects a keeper that is up and observing nothing, was scheduled nowhere and appeared only as a manual runbook command; the second unit is written to run it every 900s and page on any non-zero exit, but its plist is a `__REPO__` TEMPLATE the operator must `sed` and load per `RUNBOOK.md:119-151`, and `launchctl list | grep liveness` returns nothing today. **Move this to installed only when `launchctl list | grep liveness-pager` returns a line and `.keeper-state/liveness-pager.log` shows one run that is not `NO PAGE SENT`**; **the runbook and README, which omitted `ESSEY_MARKETS` and so instructed the operator into the vulnerable state, are corrected** | `EsseyMarkets.MAX_CONFIRM_AGE`; `keeper/liveness-keeper.mjs`, `keeper/market-list.mjs`, `keeper/check-liveness-keeper.mjs`, `keeper/xyz.essey.liveness-keeper.plist`, `keeper/xyz.essey.liveness-pager.plist`, `keeper/page-liveness-keeper.sh`, `rh-chain/README.md`, `rh-chain/RUNBOOK.md` |
| **MED-1** an unreadable price split the observation pair — Friday's price with Monday's multiplier, on a feed unreadable ~55h every weekend | `_syncPrice` returns whether it RECORDED, and `seenMultiplier` advances only when it did: a partial observation records nothing at all | `EsseyMarkets._syncPrice` / `syncMultiplier` |
| **MED-2** `LIVENESS_GUARDIAN` alone was a permanent, UNRECOVERABLE kill switch for liquidation and borrowing | a 2-day timelocked `proposeRotation` / `commitRotation` of BOTH liveness roles, held by the market admin, cancellable only by it — a guardian that could veto its own removal restores the same dead end. **FOUNDER RULING NEEDED on the trade**, see MAINNET-CONFIG.md | `src/LivenessOracle.sol`; `script/DeployMarkets.s.sol` |
| **MED-3** the deploy key held `pauseLiquidation` and `disableMarket`, which the doc block attributed to the guardian and `_roleKey`'s own rule exists to prevent | both are GUARDIAN-ONLY; admin keeps the timelocked route to the same outcome | `EsseyMarkets.pauseLiquidation` / `disableMarket` |
| **LOW-1** a 50k gas cap on the observation read against an uncapped valuation read | one budget for both, raised to 200k; a token this registry cannot read stops being VALUED instead of silently losing its breaker | `EsseyMarkets.collateralValue` / `MULTIPLIER_READ_GAS` |
| **LOW-2** the UI said "closed for an hour" for a six-hour hold and never read `priceDesyncAt` | branch (c) has its own explainer, and both durations are read from the contract | `app/web/src/lending.ts` |
| **LOW-3** the keeper's `setInterval` overlapped itself at ≥4 markets and could drop the heartbeat | self-scheduling `setTimeout` after the tick completes | `keeper/liveness-keeper.mjs` |
| **LOW-4** three shipped statements no longer matched the code | corrected, including the `4× gapThreshold` guard that no longer exists | `docs/OUTSTANDING.md`, `rh-chain/README.md`, `keeper/liveness-keeper.mjs` |
| **LOW-5** the seasoning idiom every corroboration test used silently switched the breaker off in 140 tests | `_advanceLive` now OBSERVES on the keeper's cadence; a test that wants the unobserved market asks for `_advanceQuiet` by name | `test/EsseyPool.t.sol` and the four sibling fixtures |
| **LOW-6** two Don-layer fork suites failed on a `makeAddr` vanity address that now carries an EIP-7702 delegation on mainnet | the fixture normalises its own EOAs and says why; **and with those suites running again they immediately caught that the deployed AAPL `uiMultiplier` is no longer 1e18** | `test/DonSolvencyStress.t.sol`, `test/DonMainnetFork.t.sol` |

**THE PARAMETER, now set from data.** `PRICE_CONFIRM_DELAY = 6 hours`, equal to `PRICE_DESYNC_HOLD`.
Every round of both listed feeds on chain-id 4663 over 2026-06-22 → 2026-09-04 (74.3 days; AAPL
`0x6B22…2cD0` 555 rounds, NVDA `0x379E…9F15` 981) gives a worst move of 6.80%/7.06% at 1h,
8.47%/7.88% at 6h, 8.97%/9.22% at 12h, 10.23%/12.00% at 24h. The delay spends the 21.25% between the
liquidation threshold and liquidator indifference at 5000/7500/500; nothing at any of those horizons
came within a third of it. **NVDA is NOT materially more volatile than AAPL at these horizons** —
per-round sigma **0.5712% (n=554) against 0.5602% (n=980)**, log-return sample standard deviation —
which the round-4 report had assumed the other way. **Corrected in R5 INFO-3:** the pair first
recorded here (0.5585% / 0.5751%) had the ordering reversed and no stated estimator, and the shipped
script computed no sigma at all, so it was not reproducible from anything in the repo. It now is —
`perRoundSigmaPct` in `keeper/measure-feed-volatility.mjs`. Nothing depends on the number; the
conclusion holds under both, and the binding figures are the worst-move table, which reproduces
exactly. **And read that table at 72h, not 6h** (R5 MED-1): 12.61%/12.62%, 1.69x/1.68x inside the
21.25% buffer. The derivation is recorded in the constant's own doc block, so the next reader
inherits it.

**Found while measuring, and worth its own ticket:** both feeds' first ~20 historical rounds
(2026-06-22 → 2026-06-23T13:48 UTC) return answers scaled 1e18 rather than the 1e8 `decimals()`
reports, then switch. Anything reading feed HISTORY on 4663 mis-prices by 1e10 across that boundary.
Nothing in the lending stack reads history — `priceOf` uses `latestRoundData` — so this is not a live
exposure, but it is a trap for any future TWAP or backtest.

**Also found, and NOT a lending finding:** the deployed AAPL Stock Token's `uiMultiplier()` is
`1_000_566_080_061_092_436`, not `1e18` (`cast call 0xaF3D…93f9 "uiMultiplier()(uint256)"`, 2026-09-04);
NVDA is exactly `1e18`. A multiplier that MOVES stamps `multiplierMovedAt` and holds both gates for
`MULTIPLIER_GUARD_WINDOW`, so if Robinhood expresses accruals through it continuously rather than in
discrete corporate actions, borrowing would be blocked on a rolling basis. **Whether it drifts
continuously is UNVERIFIED** — the 4663 RPC is not an archive node, so the token's own history is not
readable from here. What would settle it: an archive node, or watching `uiMultiplier()` daily.

### Update 17.2 — G-LEND round-3 findings fixed (2026-09-04, working tree, NOT committed)

Round 3 (`docs/audits/glend-round-3.md`, frozen SHA `0cf6831`) returned **NOT CLEAN**. Every finding is
now fixed and each one's proof-of-concept, run from the auditor's own fork harness, is RED.

| Finding | Fix | Where |
|---|---|---|
| **CRIT-1** one unresolved >20% move permanently disarmed the breaker | the armed pair is released when the hold expires, and the same observation re-baselines and can re-arm; `_disarm` is the ONLY writer that clears it, so the two slots cannot come apart | `rh-chain/src/EsseyMarkets.sol` `_breaker` / `_disarm` |
| **HIGH-1** the 2,000bps bound protects a position only at ORIGINATION | no bound can cover a seasoned loan (cushion → 0 at the threshold), so seizure now needs the move CORROBORATED: underwater/insolvent at an observation ≥ `PRICE_CONFIRM_DELAY` (1h) old as well as live | `EsseyMarkets.isUnderwaterCorroborated` / `isInsolventCorroborated`; gates in `EsseyPool.liquidate` and `_writeOffFloor` |
| **MED-1** the breaker measured between OBSERVATIONS and nothing made them dense | `MAX_BASELINE_AGE = 1h`: across a longer gap the comparison is drift and does not arm; the liveness keeper now calls `syncMultiplier` for every market on its existing heartbeat | `EsseyMarkets.MAX_BASELINE_AGE`; `rh-chain/keeper/liveness-keeper.mjs` |
| **MED-2** `GUARDIAN == LIVENESS_GUARDIAN` reached the forbidden union in one un-timelocked tx | the deploy refuses it, matching the existing `GUARDIAN != LIVENESS_KEEPER` rule | `rh-chain/script/DeployMarkets.s.sol` `_checkRoles` |
| **MED-3** `pauseLiquidation` chained into a permanent freeze | a new pause may not start until the last one has been over for as long as it lasted, so liquidation is open ≥ half of any span | `EsseyMarkets.pauseLiquidation` / `pauseCooldownUntil` |
| **LOW-1** `test_C7` was a false green | deleted, with the reason recorded in place; the property is proven by `G_EngineerProof::test_G1/G2` and `J_Escrow` ×6 | round-2 harness `C_Escrow.t.sol` |
| **INFO-1/2/3** stale doc claims | corrected | `DeployMarkets.s.sol`, `MAINNET-CONFIG.md`, this file (row 6 of the Multiply table) |

**OPEN DECISION FOR THE FOUNDER / don-economist — `PRICE_CONFIRM_DELAY` is a RISK PARAMETER, not a bug
fix.** HIGH-1 has no bounded fix: any mechanism that stops a sub-bound corporate action from harvesting a
seasoned position must also delay a liquidation triggered by a genuine move of the same size, because on
chain at that instant the two are the same evidence. The delay is set to 1 hour, reusing
`MULTIPLIER_GUARD_WINDOW`'s own derivation, and it applies ONLY to a position the latest uncorroborated
move has just flipped — one already past the bar is seized with no delay, and a completed corporate
action costs nothing. The trade is wrongful-seizure risk down, bad-debt risk up. **The engineer does not
own this call.**

**Residual, stated rather than closed:** the exposure is bounded, not removed — a single-leg move whose
other leg lands more than `PRICE_CONFIRM_DELAY` later still harvests, which is the same residual the file
already documents for the super-bound case and the reason `pauseLiquidation` exists for a known ex-date.
Whether Robinhood expresses dividends through `uiMultiplier` at all remains **UNVERIFIED** and is not
observable on chain.

**Pre-existing and NOT introduced here:** `DonSolvencyStressTest::setUp` and `DonMainnetForkTest::setUp`
both fail `ERC721InvalidReceiver(0xaE0b…1946)` — verified identical at HEAD `0cf6831` with the working
tree stashed. Don game layer, unrelated to lending; needs its own ticket.
| **G1** hook + LaunchSeeder | $ESSEY launch | ❌ **ZERO** — reset by `58523e1`'s new bytes. R1 HIGH (G1-1) closed | 3 clean rounds on the fee-on-fill bytes, real-fork harness |
| **G2** HolderDistributor + BasketRegistry | Holder Hub | ❌ **ZERO — FIRED AND FAILED.** 3 HIGH / 4 MED / 5 LOW (17.5) | Fix H-1/H-2/H-3 + M-1…M-4 → 3 fresh rounds |
| **G3** StockLpVault | Earn | ❌ **ZERO** — reset by `58523e1`'s new bytes. R1 HIGH (G3-1) + first-depositor MED closed | 3 clean rounds on the new bytes |
| **G-RESERVE** | EsseyReserve (live mainnet) | 🟢 **R1 CLEAN**, deployed bytecode verified against source (17.4). R-3 test gap open | Public report (redaction + founder sign-off); R-3 CEI fixture |
| **Ceremony** | Shielded set | ⏸️ **ON HOLD at the founder's word (R-16.7). DO NOT RE-RAISE.** | Founder, when he chooses |
| **D** founder deploy | all | Founder-gated, per-instance. Unchanged. | — |

### 17.9 Records corrected by this pass

| Was recorded as | Actually | Evidence |
|---|---|---|
| D1 lending "**audit-clean**, 3 consecutive clean rounds, pushed public" | **UNEVIDENCED — retracted.** No receipt anywhere; the only lending reports are Solidity 1–2, recorded "not clean" | `docs/audits/README.md:36-37`; `ls ~/.claude/gate-receipts/` |
| G2 "not fired — now genuinely fireable" | **FIRED, NOT CLEAN** — 3 HIGH | `~/.claude/gate-receipts/audit-g2-r1` |
| `EsseyReserve` "appears in NO audit doc" (16.9, H4) | **Audited R1 CLEAN 2026-09-02**, bytecode verified against source | `~/.claude/gate-receipts/audit-esseyreserve-r1` |
| `CUSTODY-AUDIT-STATUS.md`: reserve "UNAUDITED… accepted by nobody yet" | **STALE by one day** — corrected in this pass | same receipt |
| "ahead 14" of origin | **ahead 17** | `git rev-list --count origin/main..HEAD` |
| PRE-PUSH BLOCKER: `04e763d` carries the private repo name in the hook comment | **RESOLVED** — `ae62d34` is out of the range; `65ca1fc`/`cbbc3cd` both carry redacted text | per-blob read of `.githooks/pre-com*` at each commit |
| G1 "REOPENED, fix in flight (uncommitted)" (16.6) | **Fix COMMITTED** `58523e1`; a *second* HIGH (G1-1, fee-on-requested) was found and closed after that entry | `git show --stat 58523e1`; `audit-g1-r1` |
| G3 "code sound, no vulnerability found in any round" | **A HIGH was found** (G3-1, oracle-composition mispricing) once a real-fork lens ran | `~/.claude/gate-receipts/audit-g3-r1` |

### 17.10 Still UNVERIFIED — flagged, not fixed

- **The 7 fixture blockers + 8 weak assertions are orchestrator-relayed, not PM-reproduced.** The PM
  verified which have fixtures in tree (17.2), **not** that each named mutation survives. Settled by
  the engineer's mutation log at hand-off.
- **`1438 pass / 2 fail`** — engineer-reported in a commit body. Settled by a clean-tree run (17.7).
- **`EsseyLadderSeeder` at `0x1c9fd50d…5876a` is a live mainnet-4663 deployment nobody tracks**
  (`broadcast/RehearseEsseyLadder.s.sol/4663/run-latest.json`). Unchanged from 16.9. **Founder.**
- **The blog's "repeated adversarial audits" claim over `EsseyReserve`** is now *partly* supported —
  one round, clean. "**Repeated**" is still false at n=1. Cut the plural or wait for round 3.
- **Multiply's mainnet DEX** (`MAINNET-LENDING-SCOPE.md:193-217`) — no router, no `ISwapAdapter`
  implementation, no verified liquid USDG↔Stock pool on 4663. Multiply stays **DEFERRED**; base
  lending needs no DEX. Unchanged.

*This entry is committed, not left in the tree.*

### 17.11 `PRODUCT-TRACKER.md` IS GITIGNORED — the two-doc rule has a one-legged doc

`git check-ignore -v docs/PRODUCT-TRACKER.md` → **`.gitignore:67`**. `git ls-files --error-unmatch`
confirms it has **never been tracked**.

Consequences, stated plainly because nothing else in our records says this:

- The tracker — named in the PM charter as one of the two sources of truth, and the first doc a new
  session is told to read — **exists only in this working directory.** It has no history, no diff,
  no backup, and would not survive a fresh clone.
- **Update (14)'s standing rule "a doc reconcile is not done until it is committed" cannot be
  satisfied for the tracker.** Every reconcile written into it since it was created has been, in
  git's terms, unsaved work.
- It is 88 KB of the program's only at-a-glance state.

**This is most likely deliberate** — the repo is public and the tracker carries internal sequencing,
founder decisions and unfixed findings. **That is a good reason to keep it out of the public repo and
a bad reason to have no copy of it anywhere.** *(INFERRED intent; the PM did not find a written
ruling. Founder: confirm.)*

**Founder decision:** keep it gitignored **and** give it a durable home (a private repo, or the
project memory), or reclassify it as publishable. Either is fine. "Ignored and nowhere else" is not.

### 17.12 IN FLIGHT ALONGSIDE THIS PASS — a blog post about the reserve audit

Untracked and being written right now: `app/web/src/blog/posts/reserve-audit.md`, plus a one-line
edit to `app/web/src/blog/posts/put-your-stocks-to-work.md` retiring the false *"repeated adversarial
audits"* claim. Read this pass. **Hard rule 3 applies: nothing publishes without founder sign-off**
(the time-boxed autonomy grant expired ~2026-09-01).

**The good news, recorded so it is not re-litigated:** the draft names R-1/R-2/R-3 in plain language
with **no mechanism and no exploit path**, so the fix-first concern in 17.4 is largely already
answered by the framing. It also states the surviving mutant rather than rounding "9 of 10" up, and
it says the exit is unproven in production. That is the standard.

**Three corrections it needs before sign-off, each cited:**

1. **"thirteen tokenized equities plus 3,150,505 FLR" is wrong twice.** `app/web/src/reserve.ts:44-58`
   holds 13 addresses **including FLR**, and its own comment (`:41-43`) says the list is *"only what
   the page KNOWS to look up… Any token in here that the reserve does not hold simply reads zero"* —
   **a lookup list, not holdings.** Three of the 13 are not equities (CASHCAT, PONS, FLR). Update
   (16.9) separately records a *"re-derived on-chain basket of six."* **Publish a live per-token read
   or no number at all.**
2. **"It went live on 2026-08-29" has no source in our records.** The tracker's A2 row states the
   deploy is proven by a recorded `cast codesize`, **not** by a broadcast receipt
   (`broadcast/DeployEsseyFoundation.s.sol/4663/` is dry-run only). A date asserted in a post about
   audit rigour needs a block number, not a recollection.
3. **"It goes there with the next push"** commits us to publishing the receipt. Publish a written
   **report** in the house format, not the raw gate receipt — the receipt carries more than the post
   does, on a contract that can never be patched.
