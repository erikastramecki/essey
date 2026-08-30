# Mainnet flywheel math — the equity-peg ratchet

**Purpose:** let the founder eyeball the accretion numbers BEFORE anything runs. Every factual claim
carries a `file:line`, an on-chain fact, or is marked UNVERIFIED / ILLUSTRATIVE. Analysis only — this
doc deploys nothing, changes no contract, commits nothing.

**Status of the base layer:** LIVE on RH mainnet (4663). Verified 2026-08-29
([[essey-reserve-deposit-address]] memory):
- `EsseyReserve` = `0xd970Ca726188e38982906Ae2284D2bdB80205A7b` (adminless, `owner()` reverts, empty/fresh)
- `$ESSEY` token = `0x315790B57C19141B34C4653a91b096Cf3f071610`
- ops / treasury wallet (holds the 8.888B mint; forwards stock) = `0x93e6e42CcC676614FB3635b0983d60F35dDE4B9E`
- on-chain: `claimBase` = 8.888e27 ✓, `EXIT_FEE_BPS` = 500 ✓

> NOTE on a stale doc: `MAINNET-CONFIG.md:121` ("nothing of ours is deployed on mainnet") was verified
> 2026-08-11 — it PREDATES the 2026-08-29 Foundation deploy and is stale for the base layer. It is still
> correct that the game/Dons/lending/shielded frontends run testnet-only via the shared `NET`
> (`app/web/src/live.ts:14-21`); the reserve reads mainnet through its own client
> (`essey-markets/web/src/reserve.ts:21-23`).

---

## 1. The manual ratchet — `fund()` raises the floor pro-rata

### The mechanism (immutable, adminless)

`EsseyReserve.fund(token, amount)` pulls `amount` of any token into the reserve and emits `Funded`
(`EsseyReserve.sol:93-97`). It is permissionless and token-agnostic; a raw ERC-20 transfer straight to
`0xd970Ca…05A7b` counts identically (claims read live `balanceOf`), and `fund()` only adds a clean event
for indexers (`EsseyReserve.sol:89-92`).

Holding $ESSEY is a redeemable, in-kind, pro-rata claim on the whole pile. The floor for one token:

```
floorOf(token) = reserveOf(token) * 1e18 / claimBase        (EsseyReserve.sol:203-205)
reserveOf(token) = token.balanceOf(reserve)                  (EsseyReserve.sol:197-199)
```

`claimBase` is the $ESSEY genesis total supply, captured once in the constructor and never changed
(`EsseyReserve.sol:57,83`). $ESSEY total supply = `8_888_888_888e18` (`EsseyToken.sol:22`), i.e.
**8,888,888,888 whole tokens** = 8.888888888e27 base units (on-chain `claimBase` reads 8.888e27 ✓).

**Consequence — a single deposit lifts EVERY holder's floor at once.** Because the denominator
`claimBase` is fixed, `floorOf` is strictly linear in the reserve balance: fund `X` more units of a
token and every $ESSEY's in-kind claim on that token rises by `X * 1e18 / claimBase`, permanently and
monotone-up. No holder has to do anything; there is no per-holder bookkeeping.

### The 5% exit-fee ratchet (`EXIT_FEE_BPS = 500`, immutable)

Redemption is two-step, both O(1) (`EsseyReserve.sol:105-112,127-135`):
- `redeem(e)` burns your $ESSEY, mints a receipt of fee-adjusted **weight `w = e·9500/10000` = 95% of e**
  (`EsseyReserve.sol:147`).
- `claim(id, token)` pulls `w/claimBase` of that token's lifetime deposits.

The forfeited **5% is never claimable by anyone** — it stays as permanent OVER-COLLATERALISATION: the
bondable surplus and the arbitrage price floor (`EsseyReserve.sol:39-41,53`). `EXIT_FEE_BPS` is a
`constant` and the whole contract is adminless — no owner, setter, upgrade, pause, or withdraw
(`EsseyReserve.sol:21-25,53`).

**The immutability IS the trust feature, not a limitation.** Nobody — not the founder, not a compromised
key — can raise the fee, drain the pile, or dilute a holder. The only two things the contract can do with
a token are accept a deposit and pay a holder's own pro-rata slice out. That is exactly why the peg is
credible: there is no key to compromise and nothing to trust between a deposited equity and a holder's
in-kind claim on it.

---

## 2. Worked scenarios (so the numbers are eyeballable)

### 2a. Redeemable floor per whole $ESSEY, by reserve NAV

The redeemable, in-kind backing of one WHOLE $ESSEY = `0.95 × NAV / 8,888,888,888` (the 5% stays).
This uses the FULL genesis denominator, independent of how much $ESSEY circulates — see the caveat below.

| Reserve NAV (USD) | Redeemable floor / $ESSEY | Note |
|---|---|---|
| $100,000 | $0.0000107 | ~1.1e-3 ¢ |
| $250,000 | $0.0000267 | FLR-seed-scale ignition ([[essey-liquidity-launch-plan]] $250k FDV) |
| $1,000,000 | $0.0001069 | |
| $10,000,000 | $0.0010688 | ~0.1 ¢ |
| $100,000,000 | $0.0106875 | ~1.07 ¢ |

**The single number to internalise:** every **$1,000,000** of lifetime accretion adds **+$0.0001069**
redeemable floor to EVERY $ESSEY, forever, monotone-up. The floor is spread across the full 8.888B
genesis supply, so it is a **long-game ratchet, not an overnight peg** — a one-cent redeemable floor
needs ~$100M of lifetime NAV. This is the honest scale; the founder should size expectations to it.

### 2b. In-kind view (AAPL example)

`floorOf` returns raw token units, not dollars — the peg is the EQUITIES' value in-kind
([[essey-base-layer-equity-peg]] invariant 1), never a $ target. Illustratively, at an **UNVERIFIED**
$230 AAPL mark (no Chainlink feed cited here), $1,000,000 of AAPL ≈ 4,347 AAPL whole tokens →
in-kind floor `4347 / 8.888888888e9` ≈ 4.89e-7 AAPL per $ESSEY → redeemable 95% ≈ 4.65e-7 AAPL. At $230
that is $0.0001069, matching 2a. (AAPL `0xaF3D…93f9`, 18-dec, `uiMultiplier()=1e18`,
`MAINNET-CONFIG.md:12,183`.)

### 2c. The circulating-supply caveat (important)

`floorOf` and the arbitrage floor PRICE use `claimBase` (the full 8.888B), regardless of circulation.
But the FRACTION of the pile ever actually pulled = `circulating/claimBase × 0.95` — most of the 8.888B
sits in treasury and never redeems (`circulatingSupply()` excludes dead + reserve-held $ESSEY,
`EsseyReserve.sol:193-195`). So uncirculated supply "leaves backing on the table": it is never claimed,
which deepens over-collateralisation for the holders who do redeem. Two true statements to hold at once:
- **Per-token arbitrage floor** (what a market-maker defends) = `0.95 × NAV / 8.888888888e9` — table 2a.
- **Reserve actually drawn down** if fraction `f` of supply redeems = `f × 0.95 × NAV` — the rest stays.

---

## 3. The AUTO flywheel — pool-side tax → buy equities → `fund()`

**This does NOT exist yet and is COUPLED to the AMM.** Grep of `rh-chain/src` (2026-08-30): nothing
calls `reserve.fund()`, and there is no `afterSwap` / `PoolManager` / `buyTax`/`sellTax` hook contract.
Accretion today is 100% operational (§4). The auto version is a $ESSEY buy/sell tax charged at the pool
that routes to buy equities and `fund()`s them.

**Hard coupling:** there is no $ESSEY AMM/pool on 4663 yet, and no pool-tax contract. The auto-flywheel
therefore launches **IN LOCKSTEP with the AMM seeding, not before.** Plan of record
(`MAINNET-ACTIVATION.md:137-140`): ship the $ESSEY AMM **V3-first**; add a taxed **V4 `afterSwap` hook**
later, and only if a Uniswap **V4 `PoolManager` on 4663 is confirmed on-chain — currently UNVERIFIED.**
V3 SwapRouter02 `0xcaf681…5cb2` IS live and USDG↔NVDA liquidity is deep (~$3.6M USDG + ~$2.2M NVDA);
USDG↔AAPL is thin (~$39k) (`MAINNET-ACTIVATION.md:133-136`).

### Auto-accretion rate (once the AMM + tax hook exist)

`$/day into the reserve ≈ tax% × daily $ volume` (minus swap slippage to convert the taxed asset into
stock). Ranges to sanity-check:

| Tax | Daily volume | $/day to reserve | $/month | $/year |
|---|---|---|---|---|
| 0.5% | $100,000 | $500 | ~$15,200 | ~$182,500 |
| 1% | $50,000 | $500 | ~$15,200 | ~$182,500 |
| 1% | $250,000 | $2,500 | ~$76,000 | ~$912,500 |
| 2% | $100,000 | $2,000 | ~$60,800 | ~$730,000 |

Cross-reference to §2a: a full year at 1% × $250k/day (~$912k NAV added) moves the redeemable floor by
~$0.0000975 per $ESSEY. Real, but incremental — consistent with FLR being **ignition, not fuel**
([[essey-mainnet-launch-flr-seed]]). The durable engine is the platform fee base, not the tax alone.

**Slippage / venue note for the auto path:** a pool tax collected in $ESSEY or USDG must be swapped to
AAPL/NVDA before `fund()`. Prefer the DEEP NVDA pool; the thin $39k AAPL pool moves on large buys — buy
in tranches or accumulate. The SwapRouter02 ABI needs a one-line `deadline`-drop fix
(`MAINNET-ACTIVATION.md:135`), shared with Bell/Cases/Degen payouts.

---

## 4. Customizability — keep accretion TUNABLE (operational), lock the MATH (immutable)

The right split of what is immutable vs tunable:

| Layer | Immutable (good — it is the trust) | Why |
|---|---|---|
| Reserve math | `EXIT_FEE_BPS=500`, `claimBase`, adminless, no withdraw | `EsseyReserve.sol:53,57,21-25` — no key to compromise; the peg is credible BECAUSE nobody can change it |

| Layer | MUST stay tunable (operational) | Failure if hardcoded |
|---|---|---|
| Accretion RATE / amount / token / cadence | keeper or manual `fund()` | baking a rate into an immutable splitter freezes it forever |

**Do NOT route accretion through an immutable `FeeRouter`-style splitter.** `FeeRouter`'s three shares
AND three destinations are ALL set once at deploy and immutable — no owner, setter, or upgrade
(`FeeRouter.sol:35-36` immutable fields; `:69-74` constructor-assigned; `:17` "ALL immutable"). It also
routes to bell / bankroll / ops and has **no reserve leg** (grep confirmed) — so the existing router does
not accrete the reserve at all. If a future splitter added a reserve leg, that share would be frozen at
deploy, killing the ability to tune the accretion rate as revenue and market conditions change.

**Recommendation: operational-first, lock-later-only-if-ever.** Run accretion as a keeper/manual sweep
(the reserve accepts a plain transfer, so no on-chain wiring is even required). Every knob stays in the
operator's hands. Only consider hardcoding a share into an immutable contract once the rate has been
stable for a long time and the founder explicitly wants to remove his own discretion — and even then it
is one-way. There is no rush; the reserve is already live and accepts deposits today.

---

## 5. The tunable accretion PROCESS — the concrete small/tunable loop to START

A manual-or-keeper loop the founder controls end-to-end. Nothing here needs a new contract.

**The loop (sweep → buy stock → `fund()`):**
1. **Revenue accrues** (USDG or $ESSEY) in the ops wallet `0x93e6…4B9E`.
2. **Buy equities**: swap a chosen amount USDG → AAPL/NVDA via Uniswap V3 SwapRouter02 `0xcaf681…5cb2`
   (prefer deep NVDA; tranche AAPL). *(This is the SwapRouter02 `deadline`-drop ABI path,
   `MAINNET-ACTIVATION.md:135`.)*
3. **Accrete**: approve `EsseyReserve` for the bought stock, then `reserve.fund(stock, amount)`
   (`EsseyReserve.sol:93`). A raw ERC-20 transfer to `0xd970Ca…05A7b` counts identically
   (`EsseyReserve.sol:89-92`) — `fund()` is preferred only for the indexer event.
4. **List if new**: a token only COUNTS toward the displayed floor/NAV once LISTED (registrar `listStock`,
   add-only, cap 32 — [[essey-reserve-deposit-address]]). Genesis-basket tokens are listed at deploy.
   **UNVERIFIED: whether AAPL/NVDA are in the deployed genesis basket** — confirm via `listedTokens()` on
   the live reserve before relying on them showing on the page (redemption works regardless; display/NAV
   needs the listing).

**Knobs — all operational, none hardcoded:** which token, how much, how often, cadence, funding source.
Change any of them any time, no deploy.

| Concern | Operational (no contract) | Would need a contract |
|---|---|---|
| Rate / amount / token / cadence | ✅ keeper or manual `fund()` | — |
| Automating the sweep on a schedule | ✅ keeper cron (pattern exists: [[testnet-feed-keeper]]) | — |
| Buying stock from USDG | ✅ SwapRouter02 call | — |
| Hardcoding a fixed accretion share | — | immutable splitter w/ reserve leg (NOT recommended) |

**Start manual** (a few `fund()` calls, verify `reserveOf` moves, recommend a tiny test deposit first per
[[essey-reserve-deposit-address]]), then **graduate to a keeper cron** once the cadence is proven. Both
are operational; neither is founder-irreversible; both keep every knob tunable.

---

## 6. What is a contract change vs operational — and what is UNVERIFIED

**Operational (no deploy, tunable now):** the entire §4/§5 manual/keeper accretion loop; the reserve is
already live and accepting deposits.

**Contract change (needs build + 3-agent audit + founder deploy):** the auto pool-tax hook (a V4
`afterSwap` hook — none exists); any immutable splitter with a reserve leg (not recommended).

**UNVERIFIED / flagged:**
- Uniswap **V4 `PoolManager` on 4663** — not confirmed on-chain; blocks the taxed-hook auto-flywheel.
- The **$ESSEY AMM itself** — not yet seeded on 4663; the auto-flywheel is in lockstep with it.
- AAPL/NVDA **prices** in §2b are ILLUSTRATIVE (no feed cited).
- Whether **AAPL/NVDA are in the reserve's genesis basket** (`listedTokens()`) — confirm on-chain.
</content>
</invoke>
