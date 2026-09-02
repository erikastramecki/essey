# Mainnet Viability Review — what to build/ship next

Decision doc, 2026-08-30. Ranks every flow Essey has scoped, scanned, or considered by mainnet
viability, and names the single highest-leverage next move. **Analysis only — nothing here deploys,
edits a contract, or commits.** Every claim carries a `file:line`, an on-chain read, or a scope-doc
reference; unprovable items are marked UNVERIFIED. Mainnet deploy stays the founder's per-instance
gate.

Sources synthesized: [MAINNET-ACTIVATION.md](MAINNET-ACTIVATION.md) (13-flow register),
[MAINNET-LENDING-SCOPE.md](MAINNET-LENDING-SCOPE.md), [MAINNET-SHIELDED-SCOPE.md](MAINNET-SHIELDED-SCOPE.md),
[MAINNET-CONFIG.md](MAINNET-CONFIG.md), and the project memory (tokenomics, competitors, base-layer).

---

## Executive summary

**Two gates moved on-chain today (2026-08-30), and both are cross-flow unlocks:**

1. **The beacon "is-real-equity" gate is now VERIFIED.** The founder-supplied beacon
   `0xe10b6f6b275de231345c20d14ab812db62151b00` is a live contract (codesize 2332), and AAPL's
   EIP-1967 beacon slot reads *exactly* that address (on-chain read below). This was the last
   UNVERIFIED identity item across every real-stock flow ([MAINNET-ACTIVATION.md:68](MAINNET-ACTIVATION.md),
   [MAINNET-LENDING-SCOPE.md:86-88](MAINNET-LENDING-SCOPE.md)). The identity assert is now codeable
   against a confirmed target.
2. **The Multiply "no DEX" hard-blocker is refuted.** USDG↔NVDA and USDG↔AAPL Uniswap-V3 pools
   exist on 4663 (on-chain reads below). USDG/NVDA 500-tier holds ~$3.6M USDG + ~$2.2M NVDA (deep);
   USDG/AAPL 500-tier holds ~$39k (thin). The lending scope had this as the one BLOCKER that made
   Multiply undeployable ([MAINNET-LENDING-SCOPE.md:176-197](MAINNET-LENDING-SCOPE.md)). The pools
   are real; what remains is a bounded code fix (below), not a missing dependency.

**Ranked shortlist (most viable to build/ship next):**

| Rank | Flow | Bucket | Why it's here |
|---|---|---|---|
| 1 | **Base Stock-Token lending** (#3, borrow/repay/liquidate, NO Multiply) | Near-term | Scope DONE; every external dep now met; needs no DEX; port + audit only |
| 2 | **Fee accretion into the live floor** (DonReserve.fund route + USDG buyback) | Ship-now | No redeploy; activates the HOLD thesis on the already-live base layer |
| 3 | **Honest mainnet site reconciliation** | Ship-now | Base layer is LIVE but the site still says "testnet only" — a lie of omission |
| 4 | **$ESSEY/USDG AMM launch** (L-1 ladder) | Near-term | Built (EsseyLadderSeeder); needs founder go-live params; unlocks price discovery + #5 |
| 5 | **Multiply leverage** (#3 add-on) + the shared swap-adapter fix | Near-term | Pools now verified; one ABI fix unblocks 4 flows |

**Single highest-leverage next move: drive base Stock-Token lending (#3) to the 3-agent audit gate.**
It is the product thesis (borrow USDG against self-custodied real stock — the Robinhood MVP vision,
[[assay-robinhood-mvp-vision]]), its scope is complete, and as of today *every external dependency it
needs is verified on-chain*: USDG (6-dec), real Chainlink feeds, real AAPL/NVDA tokens, adminBurn
handled by the CollateralReconciler survival index, and now the beacon identity gate. It needs no DEX.
The residual is bounded internal work: port `essey-markets → rh-chain`, reconcile the StaleFeedGuard,
add a feed-liveness assert, calibrate risk params, 3-agent audit, hand the founder the deploy command.

---

## On-chain verification appendix (RPC `https://rpc.mainnet.chain.robinhood.com`, chainId 4663, 2026-08-30)

All reads below were run this session with `cast`; they are VERIFIED, not recalled.

| Fact | Read | Result |
|---|---|---|
| Base layer LIVE — EsseyReserve | `cast codesize 0xd970Ca726188e38982906Ae2284D2bdB80205A7b` | **6770** (deployed) |
| Reserve wired to $ESSEY | `essey()` on reserve | `0x315790B57C19141B34C4653a91b096Cf3f071610` |
| Base layer LIVE — $ESSEY | `symbol()` / `totalSupply()` | **"ESSEY"** / **8.888e27** (8,888,888,888 × 1e18) |
| USDG | `decimals()` / `symbol()` | **6** / **"USDG"** |
| Uniswap SwapRouter02 | `cast codesize 0xcaf681a66d020601342297493863e78c959e5cb2` | **24497** (present) |
| AAPL token | `uiMultiplier()` / `decimals()` | **1.000566e18** / **18** |
| NVDA token | `uiMultiplier()` | **1e18** |
| **Beacon (NEW — VERIFIED)** | `cast codesize 0xe10b6f6b…` + AAPL EIP-1967 beacon slot | codesize **2332**; AAPL slot `0xa3f0…3d50` → **`0xe10b6f6b…`** |
| **USDG/NVDA 500-tier pool (NEW)** | `factory.getPool` + balances | `0xd4EB…14a3`: **~3,633,225 USDG + ~10,214 NVDA (≈$2.2M)** |
| **USDG/AAPL 500-tier pool (NEW)** | `factory.getPool` + balances | `0xAae0…2d6D`: **~38,844 USDG + ~114 AAPL (≈$39k)** |
| USDG/NVDA + USDG/AAPL 3000 & 10000 tiers | `factory.getPool` | all exist (thinner; 10000-tier NVDA has 0 liquidity) |
| **Uniswap V4 PoolManager (for the Sluice/hook idea)** | `cast codesize` on the 3 canonical V4 PoolManager addresses | **all codesize 0** → standard V4 NOT at canonical addresses. **UNVERIFIED** whether V4 exists at a non-canonical address (a "Uniswap-style PoolManager" holding 4,806 NVDA is noted at [SCOPE-robinhood-chain.md:344](SCOPE-robinhood-chain.md) but with no address and not confirmed as V4) |

**Standing UNVERIFIED / accepted issuer risks (unchanged, priced-in, not resolved by the above):**
- USDG owner `0xcFA0388f…14C6F` can pause / per-address freeze / upgrade the token
  ([MAINNET-ACTIVATION.md:110-120](MAINNET-ACTIVATION.md)). Real, named, must be accepted per flow.
- Stock issuer holds `adminBurn`/pause/clawback via EOAs ([MAINNET-CONFIG.md:18-19](MAINNET-CONFIG.md)) —
  unpreventable; handled (lending) or accepted (elsewhere), never eliminated.
- No sequencer-uptime feed on RH ([MAINNET-CONFIG.md:147](MAINNET-CONFIG.md)) → keeper substitute.

**The one shared code blocker the pools expose (bounded, known):** `StockConverter` and
`DonFeeRouter` encode the *classic* SwapRouter `exactInputSingle` (selector `0x414bf389`, includes
`deadline`), but mainnet only ships **SwapRouter02** (selector `0x04e45aaf`, no `deadline`) —
proven by bytecode scan ([MAINNET-CONFIG.md:170](MAINNET-CONFIG.md), [:206-212](MAINNET-CONFIG.md)).
As written, every converter/fee swap **reverts on mainnet**. Fix = drop `deadline` (Router02 shape) +
re-audit the touched surface. This one fix is a cross-flow unlock (see below).

---

## Per-flow assessment (the 13-flow register + notable ideas)

Scored on Value / Effort / Deps / Risk. "Effort" states build state today, cited.

### #1 — Base layer ($ESSEY reserve) · **LIVE**
- **Value:** the foundation everything is additive to; the redeemable equity floor + REDEEM exit
  ([[essey-base-layer-equity-peg]], [[essey-value-lifecycle-buildorder]]).
- **Effort:** DONE — deployed + 2-round audit-clean ([[essey-base-layer-equity-peg]]:41-51),
  confirmed live on-chain above (reserve codesize 6770, $ESSEY 8.888e27, wired).
- **Deps:** none — adminless, one-way, in-kind pro-rata redemption.
- **Risk:** low; unconditionally solvent in units ([[essey-combined-tokenomics-design]]:39-45). The
  floor sits ~125× below the AMM open at genesis ([[essey-value-lifecycle-buildorder]]:21) — REAL but
  small; market in units, not dollars.
- **Bucket: DONE / ongoing** (fee accretion is the live-work item — see the Fee-accretion idea).

### #3 — Stock-Token lending · **scope DONE, deps now MET**
- **Value:** the BORROW exit ([[essey-value-lifecycle-buildorder]]:14-15) and the core Robinhood MVP
  thesis. The flagship real-asset product.
- **Effort:** PORT + RECONCILE, not rebuild — the reference impl (`essey-markets` `feat/ad1-batch`)
  already carries a real `RobinhoodMainnet` 4663 profile, real feeds, real risk params, the live
  `uiMultiplier` USD path ([MAINNET-LENDING-SCOPE.md:14-32](MAINNET-LENDING-SCOPE.md)). 7 REUSE
  contracts port as-is; guard reconcile is mechanical (§5). adminBurn HANDLED by CollateralReconciler
  ([MAINNET-LENDING-SCOPE.md:117-141](MAINNET-LENDING-SCOPE.md)); needs a monitoring keeper.
- **Deps — all now resolved:** USDG 6-dec (✓ on-chain), real feeds curated
  ([MAINNET-LENDING-SCOPE.md:59-68](MAINNET-LENDING-SCOPE.md)), real AAPL/NVDA (✓), beacon identity
  gate (✓ VERIFIED today). Base borrow/repay/liquidate needs **no DEX**.
- **Risk:** money-path, but the top-3 real-asset risks are handled or bounded by isolation
  ([MAINNET-LENDING-SCOPE.md:305-310](MAINNET-LENDING-SCOPE.md)); collateral-pause freezes only that
  one market's liquidation (§4c).
- **Bucket: NEAR-TERM — rank #1.** Residual: port, guard reconcile, feed-liveness assert, risk
  calibration, 3-agent audit, founder deploy ([MAINNET-LENDING-SCOPE.md:254-292](MAINNET-LENDING-SCOPE.md)).

### #3 (Multiply add-on) — leverage loop · **blocker refuted today**
- **Value:** leveraged stock exposure on top of base lending.
- **Effort:** build a real `ISwapAdapter` over `exactInputSingle` (only a test mock exists,
  [MAINNET-LENDING-SCOPE.md:180-182](MAINNET-LENDING-SCOPE.md)) **and** apply the SwapRouter02 ABI fix
  ([MAINNET-CONFIG.md:206-212](MAINNET-CONFIG.md)), then audit.
- **Deps:** a router + liquid USDG↔stock pools — **now VERIFIED on-chain** (NVDA ~$2.2M deep; AAPL
  ~$39k thin). Previously the single hard BLOCKER ([MAINNET-LENDING-SCOPE.md:176-197](MAINNET-LENDING-SCOPE.md)).
- **Risk:** thin AAPL depth ⇒ NVDA-first, small-size caps; slippage/sandwich on the loop.
- **Bucket: NEAR-TERM — rank #5.** Ship base lending first; add Multiply (NVDA) once the swap fix is
  audited. Do NOT block base lending on it ([MAINNET-LENDING-SCOPE.md:193-197](MAINNET-LENDING-SCOPE.md)).

### #2 — Shielded / private transfers · **1-cmd deploy, but a HARD crypto blocker**
- **Value:** private-from-day-one goal ([[essey-value-lifecycle-buildorder]]:36-42); the stealth path
  already shipped on testnet ([[essey-private-phase0]]).
- **Effort:** the minimal live USDG transfer is ONE deploy ([MAINNET-SHIELDED-SCOPE.md:13-16](MAINNET-SHIELDED-SCOPE.md)),
  but gated behind a **trusted-setup ceremony**: the deployed zkey is single-contributor ⇒ proofs are
  forgeable ⇒ the pool is drainable with real money ([MAINNET-SHIELDED-SCOPE.md:19-25](MAINNET-SHIELDED-SCOPE.md),
  [:167-171](MAINNET-SHIELDED-SCOPE.md)). Plus a formal zk-circuit audit.
- **Deps:** multi-party ceremony (regenerate verifier/zkey/wasm same generation); `openMode=false`
  config fix; a separate mainnet client for `/private` (can't flip the shared `NET`); USDG 6-dec
  frontend fix ([MAINNET-SHIELDED-SCOPE.md:197-206](MAINNET-SHIELDED-SCOPE.md)).
- **Risk:** highest cryptographic risk of any flow — a forged proof drains real funds. Plain-USDG pool
  has NO adminBurn/freeze haircut ([MAINNET-SHIELDED-SCOPE.md:120-128](MAINNET-SHIELDED-SCOPE.md));
  shielded STOCK already has the pro-rata haircut ([:108-118](MAINNET-SHIELDED-SCOPE.md)).
- **Bucket: LATER.** Cheap to deploy, unsafe to fund until the ceremony + circuit audit land. The
  ceremony is the critical path, not any asset address.

### #6/#7/#8 — Bell stock payouts / Cases / Degen · **need the swap fix + real inventory**
- **Value:** the game's reward rails paying real stock ([[pending-stock-payout-deploy]], [[pending-degen-case]]).
- **Effort:** contracts testnet-audited; mainnet needs the StaleFeedGuard reconcile
  ([MAINNET-LENDING-SCOPE.md:201-249](MAINNET-LENDING-SCOPE.md)), the SwapRouter02 ABI fix (these route
  through `StockConverter`/`BundleConverter`), real Dice entropy for Degen ([MAINNET-CONFIG.md:25](MAINNET-CONFIG.md)),
  and **real stock acquired to seed reserves** (the standing B2 finding, [MAINNET-CONFIG.md:88](MAINNET-CONFIG.md)).
- **Deps:** all gated behind the game economy going mainnet (#13) + the swap fix.
- **Risk:** RTP solvency on real assets; adminBurn on held inventory; entropy soundness (confirmed sound,
  [MAINNET-CONFIG.md:96](MAINNET-CONFIG.md)).
- **Bucket: LATER** — fold into the game-mainnet workstream.

### #4/#5 — Don mint / Don trade · **need real payment + a real $ESSEY market**
- **Value:** the fee-earning seat + its secondary market ([[essey-dons-tokenomics]]).
- **Effort:** #4 needs real mint payment (USDG and/or CoinVoyage PayKit fiat, [[essey-fiat-mint-coinvoyage]]);
  #5 needs a real $ESSEY market — which is the AMM launch (below). NEEDS SCOPE
  ([MAINNET-ACTIVATION.md:36-37](MAINNET-ACTIVATION.md)).
- **Deps:** #5 hard-depends on the $ESSEY/USDG AMM existing.
- **Risk:** medium; mint-proceeds routing correctness.
- **Bucket: LATER** (#4) / **NEAR-TERM once AMM lands** (#5).

### #10 — Quests / whitelist · **founder deprioritized**
- Founder ruled REMOVE the quests/invite/onboarding-stepper flows ([[essey-dons-tokenomics]]:73). The
  paid-invite gate ([[essey-mainnet-launch-flr-seed]]:24-31) replaces it as the growth engine.
- **Bucket: PARK / superseded** — the invite-gate splitter is the net-new piece, folded into game mainnet.

### #11 — Recurring buy / DCA · needs the game/converter on mainnet first ([[essey-mancer-inspired-mechanics]]). **Bucket: LATER.**

### #12 — Fee / tokenomics (FeeRouter) · built + 6-audit-clean, ships with the mainnet redeploy
([[essey-fee-model-mancer]]); DonFeeRouter flush hits the same SwapRouter02 ABI blocker
([MAINNET-CONFIG.md:210](MAINNET-CONFIG.md)). **Bucket: NEAR-TERM (rides the swap fix).**

### #13 — Game economy (Scrip → real) · **the biggest cross-flow rework**
- Requires the Scrip→real-stock remap (economist), plus the V2 board that fixes the un-removable MILK
  RUN faucet (97% of emission) and the dead raid loop ([[essey-game-milkrun-and-dead-raids]]). Below
  ~1,000 MAU no carve makes a year-1-visible floor ([[essey-combined-tokenomics-design]]:34-37).
- **Bucket: LATER** — the demand engine, but the furthest from mainnet-ready.

### Notable ideas from memory

- **Fee accretion into the live floor** — route proceeds into `DonReserve.fund()` + stand up the USDG
  buyback; **"Buildable NOW (no redeploy)"** ([[essey-combined-tokenomics-design]]:47-48). Activates the
  HOLD exit on the already-live base layer. Caveat: mainnet fee volume is near-zero until the game is on
  mainnet; the FLR seed yields only ~$15/day decaying ([[essey-mainnet-launch-flr-seed]]:20-22). **Bucket: SHIP-NOW** (rank #2) — cheap, thesis-activating, honest even at low volume.
- **$ESSEY/USDG AMM (L-1 ladder)** — single-sided zero-capital launch @ $250k FDV via `EsseyLadderSeeder`
  (built, [[essey-liquidity-launch-plan]]). Needs founder go-live params (L-2…L-7 open). Unlocks price
  discovery, #5, and the redeem-vs-market arb. **Bucket: NEAR-TERM (rank #4).**
- **Bonds (holder exit #4)** — mature-state only; backing sits ~125× below market at genesis, so bonds
  may only draw on surplus above 100% backing ([[essey-value-lifecycle-buildorder]]:16-24). **Bucket: PARK** until surplus is real.
- **Don→equities-direct adapter** — **SUPERSEDED**: base-layer ruling D1 = Dons ← $ESSEY ← equities;
  DROP the direct adapter ([[essey-base-layer-equity-peg]]:28-31). **Bucket: PARK (retired).**
- **StockFi options / STORMM fast-follow** — explicitly POST base-layer + mainnet; WATCH the competitor's
  Sept 2026 launch first ([[essey-competitor-stormm-options]]). **Bucket: PARK (aspirational).**
- **TravelSwap tokenized travel** — explicitly future, after mainnet ([[travelswap-essey-tokenized-travel]]).
  **Bucket: PARK.**

- **The Sluice model (sluice.live) — a Uniswap V4-hook LP/POL tool, as the on-chain home for the
  $ESSEY pool-side tax + POL.** Sluice: the protocol *becomes* the pool via a V4 hook; atomic fee
  auto-compounding; dynamic fee 0.30–3.00% scaling with price movement; "exclusive liquidity" (the
  hook refuses external LPs → one shared full-range position); LPs get ERC-6909 shares. It is an
  **AMM/LP-management tool, NOT lending** — it does nothing for lender supply, which `EsseyPool`'s
  ERC-4626 core already handles ([MAINNET-LENDING-SCOPE.md:41](MAINNET-LENDING-SCOPE.md)). Assessed
  against the three asks:
  1. **As the venue for the $ESSEY pool-side buy/sell tax flywheel:** *conceptually the right shape,
     but not usable as-is.* The pool-side-tax ruling ALREADY names a "Uniswap V4 hook
     `beforeSwap/afterSwap`" as one of the two candidate venues for the tax that buys equities into
     the EsseyReserve floor ([[essey-pool-side-tax-ruling]]:24-27), and flags "V3-first vs launch a
     V4-hook pool" as an explicit *build-time* decision (:34-36). So a V4 hook is a sanctioned design
     path. BUT Sluice's hook charges a **dynamic swap fee to its own LPs** — it does NOT skim a tax and
     route it to an external reserve to buy RWA. Our flywheel needs custom `afterSwap` logic (skim →
     convert USDG→equities→`DonReserve.fund()`) that Sluice does not provide. So this is "build our own
     tax hook (V4-shaped), optionally referencing Sluice," **not** "adopt Sluice."
  2. **As capital-efficient POL for the $ESSEY AMM (none exists today) + the stock/Multiply route:**
     genuinely attractive in principle — single shared full-range position + atomic auto-compounding
     deepens protocol-owned liquidity over time. For POL specifically the **"refuses external LPs"
     tradeoff is fine-to-good** (we *want* to own this liquidity; our L-1 launch is already
     zero-capital single-sided + protocol-funded pairing, [[essey-liquidity-launch-plan]],
     [[essey-dons-tokenomics]]:22). It is bad only if we later want a *public* $ESSEY LP market — a
     tradeoff to accept deliberately, not stumble into.
  3. **Use-Sluice's-hook vs build-our-own:** adopting a third-party hook makes it a **money chokepoint
     + external dependency + full audit obligation** (audit-third-party-code before it runs), and it
     still would not carry the tax-routing logic we need. Building our own V4 afterSwap tax hook is a
     net-new contract that needs the 3-agent gate regardless (the ruling says so, :34-36).
  - **HARD DEPENDENCY, UNVERIFIED:** every V4-hook path needs the V4 **PoolManager** deployed on 4663.
    The 3 canonical PoolManager addresses are **absent** (on-chain, above); V4-at-a-non-canonical-address
    is UNVERIFIED. Meanwhile the **V3 path is deployable today** (SwapRouter02 verified on-chain;
    `EsseyLadderSeeder` V3 single-sided already built). This mirrors the ruling's own recommendation:
    ship V3-first, add a taxed V4-hook pool later *if* V4 is confirmed on RH.
  - **Bucket: PARK (near-term-conditional) — a tool/option under rank #4, not a standalone flow.** Do
    NOT gate the AMM launch on it. Keep Sluice as the reference design for the eventual taxed pool; the
    net-new deliverable either way is *our own* V4 tax hook, gated on confirming V4 on 4663.

---

## Ranked buckets

**SHIP-NOW** (viable, low residual, deps met, no new audit-heavy contract)
- Fee accretion into the live floor (no redeploy) — rank #2
- Honest mainnet site reconciliation ([SITE-CLEANUP-SCOPE.md](SITE-CLEANUP-SCOPE.md)) — rank #3

**NEAR-TERM** (viable, a bounded dependency away)
- Base Stock-Token lending #3 (borrow/repay/liquidate) — rank #1
- $ESSEY/USDG AMM launch (L-1) — rank #4
- Multiply leverage + the shared swap-adapter fix — rank #5
- FeeRouter / #12 (rides the swap fix)
- #5 Don trade (once the AMM lands)

**LATER / NEEDS-REWORK**
- #2 Shielded (gated on the trusted-setup ceremony + zk audit)
- #13 Game economy + #6/#7/#8 payouts + #4 Don mint + #11 DCA (the game-mainnet workstream)

**PARK** (not viable yet / superseded)
- Bonds (mature-state), StockFi options (watch competitor), TravelSwap (future)
- #10 Quests (founder-deprioritized), Don→equities-direct adapter (retired by ruling)
- Sluice / V4-hook tax pool (near-term-conditional; gated on UNVERIFIED V4 on 4663; a tool under #4, not the tax logic itself)

---

## Top 5 — why this next + concrete remaining steps

### 1. Base Stock-Token lending (#3, no Multiply) — *the highest-leverage move*
**Why now:** it's the product thesis (borrow against self-custodied real stock), its scope is complete,
and today closed the last open external dependency (the beacon identity gate) — leaving only bounded
internal engineering. It needs no DEX, so nothing external gates it. **Remaining to mainnet:**
(1) port the 7 REUSE contracts `essey-markets → rh-chain`, deleting rh-chain's older lending copy in the
same change ([MAINNET-LENDING-SCOPE.md:257-259](MAINNET-LENDING-SCOPE.md)); (2) bring in the new
StaleFeedGuard + migrate the 8 `_setFeed` call sites in 4 game contracts (mechanical, behavior-preserving,
§5); (3) add the `cast`-based pre-broadcast feed-liveness assert + code the beacon identity assert now
that the target is verified ([MAINNET-LENDING-SCOPE.md:263-267](MAINNET-LENDING-SCOPE.md)); (4) stand up
the CollateralReconciler `disableMarket` keeper; (5) calibrate LTV/liq per name (AAPL vs NVDA); (6)
**3-agent audit**; (7) hand the founder the deploy runbook ([MAINNET-LENDING-SCOPE.md:285-292](MAINNET-LENDING-SCOPE.md)).
Add $ESSEY itself as a collateral market next ([[essey-value-lifecycle-buildorder]]:14-15).

### 2. Fee accretion into the live floor — *cheapest thesis-activation*
**Why now:** the base layer is live but its floor only rises on discretionary `DonReserve.fund()` —
nothing auto-routes revenue in ([[essey-competitor-netnet-capital]]:33-36). Wiring the fund route + a
standing USDG buyback is buildable with no redeploy ([[essey-combined-tokenomics-design]]:47-48) and makes
the HOLD exit real. **Remaining:** route real proceeds into `DonReserve.fund()`; stand up the USDG buyback
bid at floor×(1−fee), capped 1%/epoch. **Honest caveat:** mainnet fee volume is near-zero until the game
is on mainnet (FLR seed ≈ $15/day decaying) — so this is thesis-activating plumbing, not a revenue event
yet. Market the floor in units.

### 3. Honest mainnet site reconciliation — *stop the lie of omission*
**Why now:** the base layer went live but the site still says "not on mainnet" in multiple places, and
carries dead testnet/demo surfaces ([SITE-CLEANUP-SCOPE.md:16-27](SITE-CLEANUP-SCOPE.md)). Per the hard
rule, mainnet copy over testnet contracts (and vice-versa) is dishonest. **Remaining (essey-web-designer,
low risk):** reword the blanket "not on mainnet" to the true split (base layer LIVE, game season on
testnet Scrip); delete the `/launch` operator console (`backedAssetFactory=0x0`); verify the explorer
PEGS addresses on-chain before any "verified" pill; do NOT blanket-relink the game to the base-layer
addresses (different contract sets). Founder sign-off on any public-facing copy.

### 4. $ESSEY/USDG AMM launch (L-1 ladder) — *price discovery + the arb backstop*
**Why now:** `EsseyLadderSeeder` is built ([[essey-liquidity-launch-plan]]); a live market turns the
redeemable floor into an arb-anchored price and unblocks #5 (Don trade). **Remaining:** founder rules the
open L-2…L-7 params (FDV confirm, ladder shape, exit-fee %) → create the 3000-tier $ESSEY/USDG V3 pool →
seed protocol-owned liquidity. A go-live sitting with the founder, not an engineering blocker.

### 5. Multiply leverage + the shared swap-adapter fix — *one fix, four flows*
**Why now:** the pools are verified (rank-5 evidence above). The remaining work is a bounded code fix
that is ALSO the unlock for Bell/Cases/Degen payouts and the DonFeeRouter flush. **Remaining:** drop
`deadline` to the SwapRouter02 shape in `StockConverter` + `DonFeeRouter`
([MAINNET-CONFIG.md:206-212](MAINNET-CONFIG.md)); build a real `ISwapAdapter` over `exactInputSingle`
([MAINNET-LENDING-SCOPE.md:193-197](MAINNET-LENDING-SCOPE.md)); re-audit the touched swap surface;
list NVDA first (deep pool), gate AAPL to small size (thin pool). Do not block base lending on it.

---

## Cross-flow unlocks (resolve once, unblock many)

- **The beacon identity gate (VERIFIED today)** → codeable across #2-stock, #3, #6, #7, #8 — every
  real-stock-holding flow can now assert collateral identity against a confirmed on-chain target instead
  of `uiMultiplier` duck-typing ([MAINNET-LENDING-SCOPE.md:81-91](MAINNET-LENDING-SCOPE.md)).
- **The SwapRouter02 ABI fix (one bounded change)** → unblocks Multiply (#3), Bell/Cases/Degen payouts
  (#6/#7/#8), and the DonFeeRouter fee flush (#12). Highest fix-to-unlock ratio in the register.
- **The StaleFeedGuard reconcile (mechanical, §5)** → shared by #3, #6, #7, #9; behavior-preserving,
  compile-fix + re-audit, no state migration.
- **The game going mainnet (#13, the V2 board + Scrip→real remap)** → the gating parent for #4, #6, #7,
  #8, #11 and the demand engine that gives Fee-accretion (idea #2) something to route.

## Founder decisions / dependencies on the critical path
- **Multisig** for admin/treasury/seeder/bankroll ([MAINNET-CONFIG.md:213](MAINNET-CONFIG.md)) — gates
  every deploy.
- **Real stock to seed** converter/Degen reserves (B2, [MAINNET-CONFIG.md:88](MAINNET-CONFIG.md)).
- **Trusted-setup ceremony** for shielded (#2) — the one item no engineering can shortcut.
- **AMM go-live params** (L-2…L-7) and the **redemption exit-fee %** (the "most important number,"
  [[essey-base-layer-equity-peg]]:37) — founder rulings, not builds.
- **Real Dice entropy** address for Degen ([MAINNET-CONFIG.md:25](MAINNET-CONFIG.md)).
- Every mainnet deploy remains the founder's explicit per-instance action.
</content>
</invoke>

> CORRECTION 2026-08-30 (on-chain verified): the reserve is NOT empty. It holds MSTR/GLD/NVDA (small test deposits from ops, block ~49.65M). "ops holds 100% of supply" refers to $ESSEY the TOKEN, not the stock legs. Verify via cast, not this doc.
