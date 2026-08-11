# Essey Tokenomics v3 — The Dons

> **Status: design spec (2026-08-11).** Supersedes the Seat model in `TOKENOMICS.md` for the mainnet launch.
> The 2,222 Seats become the **8,888 Dons** — a PFP collection that IS the seat at the table. Most of the
> machinery already exists (Bell, FeeRouter, converters, tier accumulator, provably-solvent lending); this is a
> re-skin + three net-new contracts. Numbers below are the agreed design; the *interactive model* is the tuner.

## 0. One-line

**A Don is a seat, a stock, and a margin account — all in one NFT.** Mint it, stake it to take a seat, earn
tokenized stock every time the Bell rings, trade it like a stock in the AMM, and borrow against it — and Essey
can cryptographically **prove** the whole book is solvent.

## 1. Collection & token

| | |
|---|---|
| Collection size | **8,888 Dons** (ERC-721, mint-on-demand — not pre-generated) |
| Token | **$ESSEY** — fixed supply **8,888,888,888** (re-motif'd from 2.222B to match 8,888 Dons; exact same supply-per-NFT ratio 1,000,100.01), 18 dec, adminless, non-mintable, deflationary. Pure access chip, never a reward. Mainnet-deploy constant `TOTAL_SUPPLY = 8_888_888_888e18`. |
| Payout / stable | **USDG**; rewards delivered as **tokenized stock** (AAPL/NVDA/BUNDLE), fail-open to USDG |
| Mint chain | **Robinhood Chain** (recommended — USDG + stock + Bell live there; ETH mint would need a fee bridge) — *open* |

## 2. The mint ladder (fees in ETH, configurable)

Three **mutually-exclusive** paths per whitelist allocation. Reroll/custom fees are paid in **ETH** (the chain's
native token — no USDG swap needed) and are **admin-configurable** (targets below):

1. **Free (WL)** → a randomly-generated Don.
2. **~$3 reroll** → re-randomize; **unlimited**. Once you go random you are **locked to rerolls** — you can never convert to custom.
3. **~$10 custom** → build every trait in the builder, mint exactly that.

**100% of every reroll/custom fee → the stock feeSink** (buys Robinhood stock for the staked+activated Dons right
away — no team split by default). This is the flywheel: reroll/custom activity flows straight back to holders as
stock, driving more activity. The split stays configurable (`teamBps`, default 0) if we ever want a team cut. All fee
fields (`rerollFee`, `customFee`, `teamBps`, `treasury`, `feeSink`) are settable on `DonDistributor`.

**Team reserve:** **500 Dons** (`reserveCap` on `DonDistributor`, minted via `mintReserved`) held back for **AMM
liquidity seeding, Gotcha Boxes, and team members**. So of 8,888: ~4,286 whitelist + 500 reserve + the rest public/custom.

Traits are **mutable until the Don is staked** (staking locks the art forever). Randomness reuses the existing
entropy source (Dice on mainnet / MockEntropy on testnet).

**Whitelist (indexed, 5,540 mints / 8,888):** HomesByMajestic *burn 2 → mint 1* (3,317), DaoDon Cards+Cases
*hold, 1 per NFT* (883), DaoDon Founders *hold, 2 per card* (90), TravelSwap OGs *5 each, manual* (1,250).
Remaining ~3,348 for public/team. Full allocation in `wl_allocation.json`.

## 3. Protocol-funded pairing (the liquidity floor)

At mint the **treasury pairs X $ESSEY** with each Don, deposited **into the AMM as bonded liquidity** (not handed
to the user). X is the Don's floor.

- **The floor is RESERVE-BACKED (not per-Don vesting).** 30% of supply — **2,666,666,666 $ESSEY** — funds `DonReserve`
  (a reuse of the audited `SeatReserve`) against the 8,888 cap, so **floor = reserve ÷ 8,888 = 300,000 $ESSEY/Don**,
  redeemable and monotonically rising as fees flow in.
- **Anti-dump = the floor itself.** You sell your Don at the pool price and can't withdraw the backing; any Don can
  always be redeemed for its 300k floor, so it can never trade below (arbitrage). No vesting or cooldown needed.
- **AMM trading inventory = 25% of the collection (2,222 Dons)** — protocol-owned depth; the market price is
  arb-anchored to the 300k floor. `DonReserve` is immutable (no admin, no `backedSupply` setter — nothing to trust).

## 4. Activation & tiers (StonkBroker model — already in `Bell.sol`)

To **earn**, the holder stakes the Don + pays a **tiered activation fee in $ESSEY** → sets payout **weight**. Fee
is a **sink, not a stake: 50% burned, 50% treasury.** Tier **clears on transfer** (the buyer re-activates). This
is the existing Bell mechanic (which already improves StonkBrokers' per-holder gas push with an O(1) accumulator).

| Tier | Activation fee ($ESSEY) | Weight |
|---|---:|---:|
| Base | 66,666 | 1.00× |
| T1 | 166,666 | 1.25× |
| T2 | 366,666 | 1.60× |
| T3 | 666,666 | 2.00× |
| T4 | 1,666,666 | 3.33× |

*(Adopts StonkBrokers' 5-rung "666" ladder; Essey's live version is the same minus the 1.25× rung.)*

## 5. Qualification — kept StonkBroker-lean

We evaluated a full brokerage-style qualification (record date, ex-dividend, a ~60-day "season", vesting, unstake
cooldown), but per **"copy StonkBroker"** we run their **lean model**: **activate → earn immediately**, and a Don's
tier **clears on transfer** (the buyer re-activates). No season, no vesting, no cooldown. To receive a given ring, a
Don must simply be **active (staked) when the Bell rings**. (The seasoning/anti-snapshot ideas are parked in git
history if we ever want that layer later.)

## 6. The Bell / Clock-In stock loop

Fees accrue in a pot; when full, **anyone rings the Bell** (permissionless, **no tip** — gas-only, like StonkBrokers'
Clock In), which swaps the pot **USDG → tokenized stock** and credits it **pro-rata by weight** into each active Don's
token-bound Vault. A **protocol keeper** rings when the pot fills (holders can also self-ring, since they're paid on the
drop). This is StonkBrokers' "Clock In / StockBooster" — Essey matches it and is still **ahead**: USDG pot (theirs is
ETH and bleeds value pre-drop) and O(1) distribution.

- **Elect up to 3 stocks with weights** per Don (Clock-In 2.0 parity); no election → the BUNDLE basket.
- **Convert-on-accrual:** fees auto-DCA into stock as they arrive, so the pot *is* real stock from day one.
- **All fees feed it** — mint rerolls/customs, AMM trade fees, activation — the primary market funds the dividends.

## 7. The AMM (net-new) — softened StonkBroker fees

A **Don ↔ $ESSEY** pool seeded with **2,222 Dons (25% of the collection)** of protocol-owned inventory. Broker-style:
buy/sell a Don for $ESSEY at the pool price; snipe a specific one for a premium. Price is **arb-anchored to the 300k
`DonReserve` floor** — a Don can always be redeemed for its floor, so it never trades below.

- **8% standard swap · 12% snipe** (softened from StonkBrokers' 10/15; keeps the 1.5× snipe ratio), on **both
  buys and sells**.
- **70% of every fee → the stock/Bell pot** (→ dividends to seated Dons) · **30% → protocol.**

## 8. Borrow against your Don (this is our core product)

Essey **is** a provably-solvent RWA lending protocol (AAPL/NVDA borrow markets already built + audited). A Don
plugs in as a new collateral type:

- **Collateral = the Don's protocol-known floor** (paired X $ESSEY + AMM position + accrued stock).
- Borrow **USDG up to an LTV** at a set APR (StonkBrokers offers 15%; we set our own).
- The Don **stays staked**, so its **stock dividends auto-service the loan** — a real margin account.
- Liquidation falls back on the Don's own backing → book stays solvent by construction.
- **The dregg ZK circuit proves solvency** — the moat StonkBrokers can't match.

## 9. Reused vs net-new

- **Reused:** Bell, FeeRouter (60/20/20), StockConverter/BundleConverter, tier/weight accumulator, stock-payout +
  USDG fail-open, the lending engine.
- **Net-new:** (1) PFP mint contract (3-path + reroll), (2) Don↔$ESSEY bonded AMM, (3) mint-fee → auto-stock
  routing, plus (4) borrow-against-Don collateral adapter.

## 10. Website requirement

Every mechanic above **must be clearly explained to players** on the site — a plain-language `/how-it-works`
plus in-flow explainers at the mint ladder, staking, tier picker, snipe, and borrow. The Seats narrative is
**retired** (single-narrative rule). Built *with* the mechanics, not bolted on.

## 11. Open knobs (see the interactive model)

X (pairing) · season length · vest length + unstake cooldown · borrow LTV/APR · mint chain · keep 2.222B supply
vs re-motif for 8,888 · reconcile protocol-funded pairing vs user-paid activation (keep activation **user-paid**
so the 50% burn stays a real demand sink).
