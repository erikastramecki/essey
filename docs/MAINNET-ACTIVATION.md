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
| 3 | **Stock-Token lending** | /lend · EsseyMarkets, EsseyPool, oracle layer, EsseyMultiply | testnet (essey-markets) | Reuse proven core; real feeds + beacon + real DEX for Multiply; adminBurn on collateral; risk calibration; audit; deploy. | [MAINNET-LENDING-SCOPE.md](MAINNET-LENDING-SCOPE.md) *(in progress)* |
| 4 | **Don mint** | /builder · MintDistributor, DonMintSplitter | testnet | Real mint payment (USDG and/or fiat via CoinVoyage PayKit); real proceeds routing to reserve/treasury. | NEEDS SCOPE |
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
- **A real DEX/AMM on RH mainnet** — blocks #3 (Multiply) and #5 (a real $ESSEY market). [VERIFY]
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

- **#3 Lending — BUILT + AUDITED + PUSHED (public).** Ported to rh-chain, StaleFeedGuard reconciled
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
