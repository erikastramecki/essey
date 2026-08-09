# $ESSEY — tokenomics

**The one-sentence design:** you spend the volatile token to earn the stable asset — $ESSEY buys access
to the club, and everything the club pays out is real stock.

## Three assets, three jobs — never crossed

| Asset | Job | Why it never does another job |
|---|---|---|
| **$ESSEY** | Access. Buys Seats, raises Tiers, opens Cases. | Rewards are **never** paid in $ESSEY. An access token that also pays rewards has to inflate to keep paying, and inflation eats the people it's paying. Ours can't — there is no emission schedule because there are no emissions. |
| **The fee stable (USDG/ETH)** | Denominates every fee and fills the Bell's pot. | Fees priced in a stable are legible: you always know what a trade, a royalty, or a loan actually paid the club. |
| **Tokenized stocks** | The payout. What lands in your Vault when the Bell rings, what a Case seals to your wallet. The default Bell payout is a **diversified stock bundle via a BundleConverter** (opt-in single-stock per Seat), converted at the claim edge, oracle-checked and session-gated, and it **fails open to USDG** if it can't settle safely. | The reward being an asset people *want to hold* is the whole point — the club pays you in something with a life outside the club. |

This separation is the anti-death-spiral rule. Sell pressure on $ESSEY can't touch the payout engine,
because the payout engine never held $ESSEY in the first place.

## Supply: fixed, adminless, done

2,222,222,222 $ESSEY — the 2,222-Seat motif at token scale — minted once at deploy, all of it. The
contract has **no mint function, no owner, no pause, no upgrade**. There is nothing for a key to do,
which is the strongest statement a token contract can make. Supply only ever goes down: 50% of every
Tier activation is burned, permanently.

## Where value accrual comes from (and why we think it holds)

$ESSEY is a pure demand asset. Wanting in — a Seat, a higher Tier, a Case — requires it; nothing else
creates or destroys it. That demand is fed by **three fee engines**, deliberately ranked by durability:

1. **Trade fees** (the Exchange, Case purchases) — loud at launch, cyclical forever. Every buy, snipe,
   and sell-back drops its fee into the split (below).
2. **Royalties** (6%, enforced on every Seat resale) — persists as long as Seats change hands.
3. **Loan interest** — the engine only a lending protocol can have. A share of real borrowing interest
   against real collateral feeds the split. This is TVL-durable: it pays in quiet markets, it pays
   when NFT volume dries up, and it exists because the club is built on top of an actual credit market
   rather than beside one.

The ranking is honest: launch-window engines fade; the loan-interest floor is why the model is designed
to outlast its own launch.

## Where the fees go — most of it back to the members

Every fee the three engines produce lands in one immutable **FeeRouter**, which splits it by fixed,
un-changeable shares:

| Share | Destination | What it does |
|---:|---|---|
| **60%** | the **Bell's pot** → Seat holders | the revenue-share: a Seat earns a pro-rata cut of every fee the club takes, paid in the asset the holder chose (stock by default, USDG if they opt out), on each ring |
| **20%** | the **bankroll** | re-seeds the stock/case reserves, so "provably solvent" holds under volume |
| **20%** | **ops** | keeper gas, oracle feeds, the runway to keep the lights on |

So **80% of every fee returns to the protocol** — to the members who hold Seats and to the solvency that
backs the payouts. Only the ops fifth leaves the loop. The router is immutable and ownerless: the split
can never be re-pointed, and integer dust rounds *toward* the Seat holders, never away. On mainnet each
fee emitter is wired straight to the router at deploy, so there is no admin able to change where a fee goes.

**This is a revenue-share, not a token buyback — and that distinction is the whole reg posture.** Value
returns to *Seats* (a membership earned by use), to *stock in Vaults* (a real asset), and to *solvency* —
never to $ESSEY. The token stays pure access demand; nothing here captures cash flow *for the token*.

## Deliberate absences

- **No emissions, no staking APY in $ESSEY.** Tier staking buys *payout weight*, not token yield.
- **No $ESSEY buyback.** Fees route *back to the protocol* — but to Seats, stock, and solvency (above),
  never to buying the token. Value accrual for $ESSEY stays pure access demand, not treasury
  market-making: cleaner regulatory posture, no reflexive machinery to blow up in a drawdown.
- **No launch governance.** Adminless contracts don't need a token vote to not do things.

## The mint is free — earned, not sold

Seats cost nothing to mint. The whitelist is earned by *using the protocol* on testnet (the trading-day
quest), committed on-chain as a timelocked Merkle root anyone can recompute. We'd rather 2,222 Seats go
to people who have already borrowed, supplied, and rung the Bell than to whoever clicked fastest — usage
is the sybil resistance *and* the marketing.

## The Seat floor — a hard downside that only rises

Above the volatile fun sits a **hard, stable floor**. Every Seat is redeemable for USDG through the
immutable **SeatReserve**: the reserve split evenly across the full Seat supply, `floor = reserve /
maxSupply`. Anyone can fund the reserve — protocol proceeds do — and a Seat's owner can redeem at the
floor at any time, which locks the Seat in the reserve and forfeits its membership. Because redemption is
always open at the floor, a Seat can never trade below it.

The math is pro-rata and provably fair: redeeming pays exactly `reserve / backed` and decrements both the
reserve and the backed count, so the floor **never drops** for anyone who stays, and integer dust only
ever raises it. It is impossible-by-construction to over-pay — the reserve backs the full `maxSupply`,
read from the Seat contract on-chain, so an early redeemer can never drain a share funded for a Seat that
hasn't been minted yet. There is nothing to trust between a deposit and the floor it creates.

## Cases: the honest fine print

Two case modes share the same /cases page via a Safe/Degen toggle.

**Safe (fair-value) Cases** are fair-value by construction — every prize unit is ~the case's value in
stock; the draw only decides *which* name. Two exposures are accepted and managed rather than hidden:

- **The buyback reserve is $ESSEY-drift exposed.** Cases cost fixed $ESSEY; sell-backs pay oracle USD.
  If $ESSEY falls far enough, cases become cheap claims on the reserve — bounded by the reserve's balance
  (payouts stop rather than go fractional) and managed by pricing margin and standing top-ups.
- **Inventory value decays under two-sided flow.** Sellers return laggards and keep winners, so the prize
  pool drifts below par unless the bankroll re-seeds fresh units. The *solvency* guarantee (every unopened
  case backed by a real unit) always holds; par value is maintained operationally, and we say "backed,"
  never "guaranteed par."

**Degen Case** is the honest opposite: a 0.65x-50x multiplier gacha, ~90% average payback (RTP) — so the
house edge is real and the expected value is below your stake. It is provably-fair (a Keccak256-verifiable
commit-reveal via the Dice Protocol entropy oracle, mapped onto odds disclosed on-chain) and
provably-solvent (every open reserves its worst-case 50x payout in real stock before you roll). No prize
is minted from thin air, and no roll can pay what the reserve hasn't already set aside.

## How this fails (read before buying anything)

- If Seats stop trading, the royalty engine dries up. The loan-interest engine is the designed floor.
- $ESSEY's price is pure access demand and can go to zero. It is a chip, not a claim on anything.
- Payouts are protocol fees — some days the pot is thin, some days nobody rings. Never guaranteed,
  never a dividend, and the Tape will show you the quiet days as honestly as the loud ones.
