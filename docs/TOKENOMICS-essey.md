# TOKENOMICS — $ESSEY & the Essey Market economy

Design spec for the token and incentive economy behind the Seat/Bell/Note market layer
(`docs/DESIGN-seats-market-layer.md`), grounded in StonkBrokers' *verified on-chain* model
(`docs/ECONOMICS-seats-model.md`) and the founder direction (2026-08): free/cheap mint,
royalties-feed-the-pool, and heavy, volatile gamification — pointed at Essey's moat, *provable trust*.

## Reference: how StonkBrokers actually works (from their verified contracts)

The engine runs on **three assets, each with exactly one job** — and it never blurs them:

| Asset | Job | Notes (measured) |
|---|---|---|
| **$STONKBROKER** | *access / volatility* — spent to buy a broker (666,666) and activate Tiers | 2.455B supply, 12,336 holders, 47% in a float-control escrow |
| **ETH** | *fee currency* — every trade/loan fee is charged in ETH | keeps fee accounting off the volatile token |
| **Stocks** (AAPL/NVDA…) | *the yield* — what's distributed to holders | the reward is NOT the token — no emission spiral |

- **Free mint.** `MINT_PRICE = 0` (verified). 4,444 brokers, all via burn-to-mint whitelist. No public sale.
- **Enforced 6.66% royalty.** ERC-2981 at 666 bps + a transfer validator that blocks marketplaces which
  don't honor it — so OpenSea *must* pay.
- **Two distribution engines**, fees split 70% Booster / 30% protocol:
  - **Clock In** ← AMM trade fees (10% swap / 15% snipe) + loan fees (15% APR) — launch-spike, **decays**.
  - **Overtime** ← the 6.66% secondary royalty — recurring. **Measured day 16: Overtime pays ~9× more
    per round than Clock In.** Royalties are the *durable* engine; trade fees are the launch sugar rush.

**The two takeaways that shape our design:** (1) pay the yield in a *real* asset, never the meme token;
(2) **royalties outlast trade fees** — the founder instinct to lean on them is exactly right.

## $ESSEY — the design

### Three-asset separation (adopted)
- **$ESSEY** = access + volatility. Spent to buy Seats on the Exchange and to activate/upgrade Tiers.
- **USDG / ETH** = fees.
- **Stocks / USDG** = Payouts (via the Bell → Vaults).
Rewards are **never** paid in $ESSEY. You spend the volatile token to earn the stable asset, so the
flywheel keeps paying regardless of $ESSEY's price. This is the single most important anti-death-spiral
rule, and it's why we don't need staking-emissions at all.

### Supply & emission
- **Fixed supply, no staking emissions.** The reward is stocks, so there is nothing to inflate.
  This alone differentiates us from ~every GameFi token that inflates itself to pay "yield."
- A float-control reserve (like their escrow) holds unsold supply for the Exchange and liquidity.

### Distribution / mint (founder direction: free or near-free)
Free mint maximizes reach (their 12k holders prove it). Recommended model — **free mint earned by
*using the protocol***, not by burning an unrelated NFT: a Seat allocation is granted for
borrowing/supplying on `EsseyPool`. This points the free mint at real usage from day one (design
improvement #4 made concrete) and seeds the lending flywheel with the same action.

*Open decision (founder's call):* (a) usage-gated free mint [recommended], (b) open/first-come free
mint [max virality, sybil surface], (c) small flat mint fee [weak $ESSEY sink, filters bots]. These
have very different launch dynamics — see task #17.

### The Bell's pot — THREE engines, ranked by durability (our structural edge)
StonkBrokers has two (trade fees + royalties). We have three, because we're also a lending protocol:

| Engine | Source | Durability |
|---|---|---|
| Launch trade fees | Exchange swap/snipe fees | spike → fast decay (their measured shape) |
| **Royalties** | enforced Seat secondary-sale royalty (~5–6.66%, ERC-2981 + transfer policy → OpenSea pays) | recurring, secondary-driven — **their durable engine** |
| **Loan interest** | a reserve share of `EsseyPool` interest | recurring, **TVL-driven, uncorrelated to NFT mood** — *the one they can't build* |

Ranked durability: trade fees < royalties < loan interest. The third engine makes our economy
structurally more resilient than theirs — it pays even when nobody is trading NFTs.

### $ESSEY value accrual — pure access demand (NO buyback in v1)
Founder decision (2026-08): **no buyback** — StonkBrokers doesn't have one, and dropping it keeps us
close to their proven model *and* strengthens reg posture (a token that captures protocol cash flow via
buyback looks more security-like; a pure access/utility token does not). So $ESSEY's value comes from
demand to *use* it, exactly as $STONKBROKER's does:
1. **Access demand** — you need $ESSEY to buy Seats (the Exchange), activate/upgrade Tiers, and buy Cases
   (below). This is the whole thesis. It's recurring, not one-time: Tiers clear on transfer, so
   activation is a *churning* sink (StonkBrokers ran ~29 activations/day into week 3). Cases add a second
   recurring $ESSEY sink.
2. **Float control** — a reserve holds unsold supply; the Exchange price-releases it against demand (their
   escrow model). Scarcity is a managed dial.
3. **Burn** — keep the 50% Tier-fee (and a slice of Case) burn as flavor, not the value thesis (their
   burn was 0.046% of supply in 16 days — cosmetic at scale; never lead messaging with it).
4. **Governance** (optional, later) — over the reward lineup and Exchange/Case params.

This is deliberately **demand-driven and volatile**: when people want in (buying Seats/Cases, activating
Tiers) $ESSEY has strong utility pull; when they don't, it fades — which is the engagement volatility the
founder wants, honestly disclosed. "Number go up" here is *adoption*, not fee-capture. A buyback can be
revisited later as a deliberate, separately-reviewed choice; it is not v1.

### The "provably backed" extension of the moat
Where StonkBrokers says "provably fair," $ESSEY can add **"provably backed"**: the buyback treasury and
the Bell's solvency (every open Payout obligation covered) are ZK-verifiable, same stack as the IVC
work. No meme token can make that claim.

## The Case system — a stock gacha that is also a fee engine (founder-prioritized)

A CS:GO-case-style front door to stock, and a *second two-sided fee engine* feeding the Bell. Full build
scope in `docs/DESIGN-seats-market-layer.md`; here is its economic role.

**The loop:** spend to buy a **Case** → it contains real Robinhood Stock Tokens sealed in a Vault-NFT
(the Seat/Vault primitive reused) → **keep it** (hold the stock, or borrow against it on `EsseyPool`),
trade it, or **sell it back** to the system at a discount. "Spend to get a good 401k; if you don't like
it, sell it back."

**Two-sided fees (the founder's key point) — both route to the Bell's pot:**
- **Buy-side fee** — charged on purchase (flat and/or %).
- **Sell-back spread** — reselling to the system pays out at e.g. 95% of oracle value; the ~5% spread is
  house revenue.
So every Case that's opened *and* every Case that's sold back feeds distributions — a fee engine that
earns on the round trip, not just the entry.

**Two variants, deliberately reg-differentiated:**
- **(a) Fair-value pack ("401k pack")** — you always receive ~fair value in stock; the draw only decides
  *which* stock (or the basket mix). Not a game of chance — a wrapped/randomized *purchase*. Best match
  for the "get a good 401k" framing; lower reg risk (StonkBrokers' Certificate Counter is "no game of
  chance").
- **(b) Multiplier case ("degen case")** — a provably-fair roll (win more / less than paid). A game of
  chance; higher reg risk — StonkBrokers US-restricts their Degen Mode for exactly this. Gated,
  jurisdiction-aware, separately legal-reviewed.

**How it fits the economy:** a third stock-acquisition path (alongside Bell payouts and direct
borrowing), a new $ESSEY sink (Cases bought in $ESSEY), NFT volume (Cases are NFTs → royalties → Bell),
and it closes the flywheel from a new angle: **buy a Case → get stock → borrow against it on EsseyPool.**

**Essey twist (the moat):** provably-fair draw **and** a **provably-solvent bankroll** — ZK-prove the
machine always reserves the worst-case payout in real stock (their inventory-bound reservation, made
verifiable). "The only case system where the odds AND the bankroll are provable."

**Open dependency:** entropy on Robinhood Chain — no Chainlink VRF on the production path; StonkBrokers
built miner-backed DERP. Options: their conductor, a commit-to-future-entropy scheme, or a ZK draw.
Decide at build time.

## How this fails (read before shipping)
- **Royalty-dependence needs secondary volume.** If Seats don't trade, the durable-looking royalty
  engine is dry. Mitigation: the loan-interest engine doesn't depend on NFT trading — it's the floor.
- **Reflexive buybacks cut both ways.** Amplified up *and* down. This is a feature for engagement and a
  risk for holders; it must be disclosed in the experimental warning (task #14).
- **Free-mint sybil surface.** Usage-gating (borrow/supply to earn) raises the cost of sybil vs an open
  claim; still needs anti-farming design.
- **Mercenary activation.** Tiers clear on transfer, so activation is recurring revenue — but a
  down-market kills activation demand and the burn/treasury sinks with it.
- **$ESSEY has no cash-flow *right*.** Buyback ≠ dividend; keep it that way for reg posture.

## Reg note (founder decision territory)
A pure access token is the safest posture. Every value-accrual lever we add (fee-share, buyback,
governance-over-fees) nudges toward security-like characteristics. "Buyback-and-make" from protocol
fees is common but not risk-free; "Payout," never "dividend"; and the stock-token payout features are
already US-restricted on StonkBrokers for a reason. These are choices for legal review, not defaults.

## Decisions (locked 2026-08-02)

| # | Decision | Resolution |
|---|---|---|
| 1 | **Mint** | **Free mint** (founder). Model: primarily **usage-earned** (borrow/supply on EsseyPool → earn a Seat allocation) so the free mint seeds the lending flywheel + resists sybils, with a minter-controlled whitelist tranche reserved for early community/partners (StonkBrokers' `setWhitelist` pattern). *(delegated → recommended)* |
| 2 | **Royalty** | **6%** (founder), ERC-2981 + a transfer policy so marketplaces (OpenSea) must honor it — enforcement is the whole point (StonkBrokers enforce theirs). Routes to the Bell. *(rate locked by founder; enforcement recommended)* |
| 3 | **Buyback** | **None in v1** (founder). Revisitable later, separately reviewed. |
| 4 | **Loan-interest → Bell** | *(delegated → recommended)* **Leave lender economics untouched.** `EsseyPool.reserveBps` (the protocol's cut of interest) is unchanged, so lenders' yield doesn't move. Of that *protocol reserve* only, route **~50% to the Bell** (Seat rewards) and keep ~50% as treasury runway — tunable. This gives Seats a TVL-durable reward stream (the engine StonkBrokers can't build) *without* touching what lenders earn. Needs a small `EsseyPool` reserve-routing addition + its own audit gate. |
| 5 | **Governance** | *(delegated → recommended)* **No on-chain governance in v1** — it adds admin surface against the adminless posture the audit rewarded. Reward-lineup rotation is handled by a timelocked registrar (like the converter's append-only registry), not a token vote. $ESSEY governance is a deliberate later addition. |
| 6 | **Purchase currency** | Seats (the Exchange) and Cases are bought in **$ESSEY** — this is the primary access-demand sink that gives the token utility. Fees are charged/collected in USDG/ETH; Payouts are stocks/USDG. |

### Still open (decide at build time, not blocking)
- Case variants to ship first (fair-value "401k pack" vs multiplier "degen case") + jurisdiction gating.
- Entropy source on Robinhood Chain (miner-DERP conductor / commit-to-future-entropy / ZK draw).
- Exact tier fee numbers in $ESSEY (set against the launch Exchange price, per the ladder-pricing rule).
- The float-reserve / liquidity / community allocation split (operational transfers from the treasury).

### Token contract — BUILT (`rh-chain/src/market/EsseyToken.sol`)
Fixed supply **2,222,222,222 × 1e18** (the 2,222-Seat motif; same order as the reference economy's
proven 2.455B scale). ERC20 + **Burnable** (real supply-reducing burns; the Bell's dEaD sink also
works) + **Permit** (gasless approvals → one-tx Tier activation). **Adminless**: no mint function, no
owner, no pause, no blocklist — entire supply minted once to the distribution treasury; float/LP/
community splits happen by ordinary transfers. Tests (4): fixed supply, burn-only monotonic supply,
EIP-2612 permit flow, and an end-to-end Tier activation using the real token through the shipped Bell
(50% burn / 50% treasury verified). Needs the 3-agent gate before push, like everything money-touching.

*Naming note (2026-08-02):* the Seat AMM is **"the Exchange"** (founder rejected "the Floor";
runner-up: "the Pit") — "a Seat on the Exchange" being the real-world idiom the Seat NFT is named for.
