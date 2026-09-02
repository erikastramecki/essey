# Essey Tokenomics — The Dons

> **Status: shipped spec (updated 2026-09-01).** Supersedes the Seat model in `TOKENOMICS.md`. The 2,222
> Seats become the **8,888 Dons** — a PFP collection that IS the seat at the table. This document is
> reconciled against the deployed contracts (`rh-chain/src/market/{Don,DonDistributor,DonReserve,DonExchange,DonFeeRouter,DonLoan,Bell}.sol`):
> **where a number appears here, it is the number in the code.** Where a value is admin-tunable, we say so.
>
> **Chain status.** The **$ESSEY token is live on mainnet** (Robinhood Chain, id 4663) at
> `0x315790B57C19141B34C4653a91b096Cf3f071610`. The **Dons game layer** — mint, Bell, exchange, loan,
> and the mission/raid economy — currently runs as a **testnet Skirmish season in Scrip** (play-money, no
> real value; see `docs/GAME-GUIDE.md`); its mainnet deploy is a separate, later step. This document is
> **Dons/game-side tokenomics**, siloed from the protocol fee model. Where a $ESSEY sink below is a GAME
> mechanic (notably the Bell activation burn, §4), it is a game-side mechanic and is **not** the protocol
> fee model, which is USDG-denominated and burns nothing (`docs/BASE-LAYER.md:108-114`).

## 0. One-line

**A Don is a seat, a stock, and a margin account — all in one NFT.** Mint it, stake it to take a seat, earn
tokenized stock every time the Bell rings, trade it against the floor-pinned exchange, and borrow against
it — and Essey can cryptographically **prove** the whole book is solvent.

## 1. Collection & token

| | |
|---|---|
| Collection size | **8,888 Dons** (ERC-721, mint-on-demand — not pre-generated) |
| Token | **$ESSEY** — fixed supply **8,888,888,888** (`EsseyToken.TOTAL_SUPPLY = 8_888_888_888e18`; same supply-per-NFT ratio 1,000,100.01), 18 dec, adminless, non-mintable. **Live on mainnet at `0x315790B57C19141B34C4653a91b096Cf3f071610`** (Robinhood Chain 4663). Pure access chip, never a reward. Supply is fixed and never minted; the only $ESSEY sink is the game-side Bell activation burn (§4), which acts on the game's own balances (testnet Scrip this season). |
| Payout / stable | **USDG**; rewards delivered as **tokenized stock** (AAPL/NVDA/BUNDLE), fail-open to USDG |
| Mint chain | **Robinhood Chain** — resolved and **deployed** (USDG + stock + Bell live there) |

## 2. The mint ladder (fees in ETH, admin-tunable)

Three **mutually-exclusive** paths per allocation. Reroll/custom fees are paid in **ETH** (the chain's native
token — no USDG swap needed). Deployed values (tunable via `DonDistributor.setFees`):

1. **Free (WL)** → a randomly-generated Don, gas only.
2. **Reroll — `rerollFee = 0.00075 ETH` (tuned to track ~$3)** → re-randomize; **unlimited** until staked. Once
   you go random you are **locked to rerolls** — you can never convert to custom.
3. **Custom — `customFee = 0.0025 ETH` (tuned to track ~$10)** → build every trait in the builder, mint exactly that.

**Randomness & uniqueness.** The random roll happens client-side; what the contract enforces on-chain is
**combo uniqueness** — every trait combination is written to the `usedCombo` ledger, so no two Dons can ever
share a look (rerolls free the old combo and claim the new one). Chain-entropy rolls are a future revision;
the mint makes no on-chain-entropy claim today.

**100% of every reroll/custom fee → the stock feeSink** (buys Robinhood stock for staked+activated Dons — no
team split: `teamBps` deployed at **0**). This is the flywheel: mint activity flows straight back to holders
as stock. The split stays configurable (`teamBps`, `treasury`, `feeSink` settable) if a team cut is ever wanted.

**Announced direction — the 50/50 mint splitter (design-forward, not yet deployed).** At the real-asset
go-live the mint `feeSink` re-points to an **immutable 2-leg ETH splitter**: **50% → a stock-seed reserve**
that funds the game's real-asset prize inventory (the stock active players *win* by playing) · **50% →
treasury**. **No Bell leg, no floor leg** (`stockSeedBps = 5_000`, destinations immutable once deployed;
the re-point is a single `setFeeSink` call). This is the anti-passive turn applied to mint: proceeds seed
the prizes that at-risk play earns, rather than paying idle staked Dons. It supersedes the earlier
50/20/10/20 idea. **Nothing here is live today** — mint currently routes 100% → `feeSink` as described
above; the splitter is drafted and lands with the real-asset seasons (see `docs/GAME-GUIDE.md`).

**Reserve: `reserveCap = 2,722` Dons** (hard cap on `mintReserved`, immutable — it cannot be raised):
**2,222** of those are the exchange's trading inventory (protocol-owned, seeded into `DonExchange` — held by
the desk, not by people) and **up to 500** cover partners and team.

**Allocation of the 8,888:**

| Tranche | Dons | Notes |
|---|---:|---|
| Whitelist (indexed) | 5,540 | HomesByMajestic *burn 2 → mint 1* (3,317) · DaoDon Cards+Cases *hold, 1 per NFT* (883) · DaoDon Founders *hold, 2 per card* (90) · TravelSwap OGs *5 each, manual* (1,250). Full list in `wl_allocation.json`. |
| Reserve (`reserveCap`) | 2,722 | 2,222 exchange inventory + up to 500 partners/team |
| Public / custom headroom | 626 | whatever the WL doesn't claim also falls through here |
| **Total** | **8,888** | |

**Whitelist safety:** the WL Merkle root sits behind a **2-day public timelock** (`ROOT_TIMELOCK = 2 days`,
propose → commit) — the list is visible before it can go live, and no one can swap it in quietly.

**Trait mutability:** traits are mutable until the Don is staked. Rerolling is blocked **the instant the Don
holds a Bell tier** (`tier > 0`), not merely after `lockOnStake` fires; `lockOnStake` itself is
permissionless but conditioned on the Don being active — anyone can flip the lock once the condition holds.
**Staking locks the art forever.**

## 3. The floor — `DonReserve`

The floor is **one reserve, not per-Don pairing**: there is no bonded per-Don LP position. **30% of supply —
2,666,666,666 $ESSEY — funds `DonReserve`** (a reuse of the audited `SeatReserve` design) against the Don
contract's immutable 8,888 cap:

- **Floor = reserve ÷ 8,888 = 300,030 $ESSEY per Don** (the funded value; the deployment doc and the
  rehearsed 150,015 half-floor borrow agree). Distinct from this is `DonExchange.donPrice = 300,000e18` —
  the exchange's deploy-time **price minimum**; the desk trades at `max(live floor, 300,000)`.
- **Redemption is always open** — any Don's owner can redeem for the full pro-rata floor share, no window, no
  admin. Redemption consumes the Don (locked in the reserve permanently, Vault included).
- **Monotone by construction.** Funding raises the floor (protocol proceeds routed in via `fund()`, or anyone
  may fund it — loan interest does **not** flow here; it's a prepaid ETH fee); redemptions are
  pro-rata and can never lower it for anyone else. **Anti-dump = the floor itself** — a Don can never trade
  below it (arbitrage), so no vesting or cooldown is needed.
- **Nothing to trust:** `DonReserve` is immutable — no admin, no upgrade path, no `backedSupply` setter; the
  backed count is read from the Don contract's own immutable cap.
- **Exchange inventory = 2,222 Dons (25% of the collection)**, protocol-owned depth in `DonExchange`, price
  arb-anchored to the floor.

## 4. Activation & tiers (the Bell)

To **earn**, the holder stakes the Don + pays a **tiered activation fee in $ESSEY** → sets payout **weight**
(the Bell's O(1) accumulator — one division per ring regardless of table size). Fee is a **sink, not a
stake: 50% burned, 50% treasury** (`Bell.sol:368-369` — half `safeTransferFrom` to the `0x…dEaD` burn
address, half to the immutable treasury; VERIFIED). Tier **clears on transfer** (the buyer re-activates).

> **This burn is a GAME-side Bell mechanic, not the protocol fee model.** The locked protocol fee model
> is USDG-denominated and splits **45 floor / 40 holders / 15 dons with NO burn** (default deploy split,
> `script/DeployEsseyV4Pool.s.sol:47-49`; corrected 2026-09-02 from "50/40/10", which was the rails
> 40/50/20 mistaken for the split) — the hook never mints
> or skims $ESSEY (`docs/BASE-LAYER.md:108-114`). The Bell activation burn is a separate demand sink on the
> Dons game side; it burns the game's own $ESSEY balances (testnet Scrip this Skirmish season) and touches
> the live mainnet supply only at the game's future mainnet deploy. Do not read this line as protocol
> tokenomics.

| Tier | Activation fee ($ESSEY) | Weight |
|---|---:|---:|
| Base | 66,666 | 1.00× |
| T1 | 166,666 | 1.25× |
| T2 | 366,666 | 1.60× |
| T3 | 666,666 | 2.00× |
| T4 | 1,666,666 | 3.33× |

All five rungs are live (deploy ladder: fees 66,666 / 166,666 / 366,666 / 666,666 / 1,666,666; weights
100 / 125 / 160 / 200 / 333). **Fees are cumulative** — `upgrade` charges only the delta, so Base → T4 costs
1,600,000 $ESSEY whether you climb rung by rung or jump.

## 5. Qualification — deliberately lean

We evaluated a full brokerage-style qualification (record date, ex-dividend, a ~60-day "season", vesting,
unstake cooldown) and rejected it: **activate → earn immediately**, and a Don's tier **clears on transfer**
(the buyer re-activates). No season, no vesting, no cooldown — none of these exist in the code. To receive a
given ring, a Don must simply be **active (staked) when the Bell rings**. (The seasoning/anti-snapshot ideas
are parked in git history if we ever want that layer later.)

## 6. The Bell — the stock loop

Fees accrue in a **USDG pot**: `DonFeeRouter` converts inflows (ETH mint fees, $ESSEY trade fees) to USDG on
flush and forwards them to the Bell. **Stock conversion happens at the claim edge, per Don** — each claim is
delivered as that Don's elected stocks (or the BUNDLE default), failing open to USDG if a conversion can't
settle. The pot is *not* pre-converted to stock as fees arrive.

- **Anyone rings** once the pot passes the threshold; a **protocol keeper** rings routinely. Deployed params:
  **`tipBps = 0`** (no ringer tip — 100% of the pot goes to active Dons, gas-only ringing) and
  **`minRing = 10 USDG`** (testnet threshold).
- **`ring()` reverts if no Don is active** — the pot simply waits and keeps growing; early activators inherit
  everything accumulated before them.
- **Elect up to 3 stocks with weights** per Don; no election → the BUNDLE basket. Elections clear on transfer.
- **All routed fees feed it** — mint rerolls/customs (100%) and the exchange's 70% share — the primary market
  funds the dividends. (*Announced direction:* once the 50/50 mint splitter of §2 lands, mint proceeds seed
  the game's stock prizes instead of the Bell; the Bell then draws from the exchange's 70% share and loan
  interest. The Bell keeps feeding staked Dons from **market-layer** activity, unchanged.)

**Market layer vs the game economy (design-forward).** The fees above are the **market layer** — mint,
exchange, and loan activity — and they pay staked Dons through the Bell. The separate **game economy**
(missions, raids, the House loop) follows an **anti-passive** rule and its fees **never touch the Bell**:
game dividends pay *deployed, at-risk* capital, and a raid-insurance fund (the Fixer's Book) protects
active players; idle staked Dons earn only the indirect legs (a rising floor). This split lands with the
real-asset seasons; the player-facing shape is in `docs/GAME-GUIDE.md`.

## 7. The exchange — `DonExchange`

A **Don ↔ $ESSEY** desk seeded with **2,222 Dons (25% of the collection)** of protocol-owned inventory.
Broker-style: buy/sell a Don at the desk price; snipe a specific one for a premium. Price is pinned on every
trade to **`max(live floor, 300,000 $ESSEY)`**, read fresh from `DonReserve` — a Don can always be redeemed
for its floor, so it never trades below, and the desk can never be arbitraged against a risen floor.

- **8% standard swap · 12% snipe** (the mechanic we adapted charges 10%/15%; we softened both and kept the
  1.5× snipe ratio), on **both buys and sells**.
- **70% of every fee → the Bell** (→ dividends to seated Dons) · **30% → treasury.**
- Every trade takes a **slippage bound** (max cost on buys / min proceeds on sells) — the floor can rise
  between click and confirmation, and the trade reverts rather than filling worse than approved.
- **Adminless over funds:** the only privileged role can *add* Dons to inventory — it can never withdraw the
  $ESSEY reserve or touch fees.

## 8. Borrow against your Don (`DonLoan` — this is our core product)

Essey **is** a provably-solvent RWA lending protocol (AAPL/NVDA borrow markets already built + audited). A
Don plugs in as a new collateral type:

- **Fixed-term, fixed-draw.** `borrow(donId, termSeconds)` draws **exactly `ltvBps` of the live floor** — no
  amount is chosen — disbursed IN FULL in $ESSEY. Term is bounded **7–365 days** (`MIN_TERM`/`MAX_TERM`).
- **Loans are denominated in $ESSEY** — the floor's own unit. With debt and collateral in the same unit
  there is **no price oracle, no trading-session gate, no keeper** — none of the usual failure points.
- **Collateral = exactly `DonReserve.floorPerDon()`** — nothing else. Vault contents are **not** counted as
  collateral (and are **forfeited with the Don on liquidation** — the UI must warn: claim regularly).
- Deployed params: **LTV 50%** (5,000 bps → max borrow 150,015 $ESSEY at today's floor) · **liquidation at
  70% of the live floor** (7,000 bps, a *dead-but-present* ratio backstop — structurally unreachable) ·
  **calendar default** (`DEFAULT_GRACE = 30 days` past expiry) · **liquidation tip 1%** (100 bps, capped at 5%).
- **Interest is prepaid in ETH, never in $ESSEY.** `prepaidEth = ethPerFloorPerYearWad · floorPerDon() · term
  / YEAR`, clamped to **`MAX_PREPAID_ETH = 1 ETH`**. It is forwarded at borrow, split **70% → `feeSink`
  (stock for staked Dons) / 30% → `treasury`** (`ethFeeStockShareBps = 7000`) — the same 70/30 shape as AMM
  fees. The coefficient `ethPerFloorPerYearWad` is treasury-tunable (deployed at **0 = free borrowing**);
  any `msg.value` above the prepaid is refunded.
- **Debt is flat = principal forever** — no accrual. `debtOf` returns exactly the principal; past expiry it is
  still just the principal. You owe back the full draw **1:1**.
- The Don **stays in your wallet — still staked, still earning.** A lien blocks transfer/swap/redeem until
  the debt clears; dividends keep accruing to the Don's Vault throughout.
- **Repayment is 1:1 in $ESSEY** (`repay`, callable by anyone on the borrower's behalf): the prepaid ETH
  interest is never part of debt and never refunds; full repayment releases the lien immediately.
- **Default is a calendar event.** Liquidation opens when `block.timestamp > expiry + defaultGraceSeconds`
  (30 days) — permissionless. Because debt is a flat 50% of a non-decreasing floor, the 70% ratio trigger can
  never fire; the calendar is the live trigger.
- **Liquidation waterfall:** the Don is seized and redeemed at the floor; proceeds pay the caller tip →
  principal (back to the lendable pool) → **surplus returned to the borrower**. No interest leg (it was
  prepaid). The Don itself is consumed (locked in the reserve, Vault and all).
- **The dregg ZK circuit proves solvency**: every loan emits an on-chain tuple (`DonLoan.loanTuple`) proven
  under a Groth16 verifier — `debt ≤ 50% of floor` at origination with conservative rounding (debt rounds
  up, floor rounds down), so the proof can only overstate risk, never hide it.

## 9. Reused vs net-new

- **Reused:** Bell (tier/weight O(1) accumulator), StockConverter/BundleConverter, stock-payout + USDG
  fail-open, the lending engine + dregg prover, the `SeatReserve` design (as `DonReserve`).
- **Net-new:** (1) `DonDistributor` — 3-path mint + reroll + WL timelock, (2) `Don` — the 8,888 ERC-721 with
  trait ledger + Vaults, (3) `DonExchange` — floor-pinned desk with its internal 70/30 split,
  (4) `DonFeeRouter` — 100% of flushed value → the Bell (admin can retune route/slippage/keeper but can
  never redirect funds), (5) `DonLoan` — borrow-against-Don with provable solvency.
- **Not used on the Dons path:** the Seats-era 60/20/20 `FeeRouter` — that split belongs to the retired
  narrative; the Dons fee routes are exactly the ones in §2/§6/§7/§8.

## 10. Website requirement

Every mechanic above **must be clearly explained to players** on the site — a plain-language `/how-it-works`
plus in-flow explainers at the mint ladder, staking, tier picker, snipe, redeem, and borrow (including the
two hard warnings: redemption is permanent and locks the Vault; liquidation consumes the Don and its Vault).
The Seats narrative is **retired** (single-narrative rule). Built *with* the mechanics, not bolted on.

## 11. Open knobs

Genuinely open (everything else above is deployed):

- **Final mainnet ETH fee levels** for reroll/custom (`setFees` targets ~$3 / ~$10).
- **`DonLoan` pot sizing** — how much $ESSEY the lending facility is seeded with.
- **Mainnet `DonFeeRouter` wiring** — the real ETH→USDG route (testnet runs an interim route with mocks).

Resolved since the initial draft: mint chain (**Robinhood Chain, deployed**) · supply re-motif (**done**,
8,888,888,888e18) · pairing-vs-activation (**no pairing** — one reserve backs the floor; activation stays
**user-paid** so the 50% burn is a real demand sink) · season/vest/cooldown (**cut** — see §5).
