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
   and sell-back drops its fee into the Bell's pot.
2. **Royalties** (6%, enforced on every Seat resale) — persists as long as Seats change hands.
3. **Loan interest** — the engine only a lending protocol can have. A share of real borrowing interest
   against real collateral routes to the Bell. This is TVL-durable: it pays in quiet markets, it pays
   when NFT volume dries up, and it exists because the club is built on top of an actual credit market
   rather than beside one.

The ranking is honest: launch-window engines fade; the loan-interest floor is why the model is designed
to outlast its own launch.

## Deliberate absences

- **No emissions, no staking APY in $ESSEY.** Tier staking buys *payout weight*, not token yield.
- **No buyback.** Value accrual is access demand, not treasury market-making — simpler to reason about,
  cleaner regulatory posture, no reflexive machinery to blow up in a drawdown.
- **No launch governance.** Adminless contracts don't need a token vote to not do things.

## The mint is free — earned, not sold

Seats cost nothing to mint. The whitelist is earned by *using the protocol* on testnet (the trading-day
quest), committed on-chain as a timelocked Merkle root anyone can recompute. We'd rather 2,222 Seats go
to people who have already borrowed, supplied, and rung the Bell than to whoever clicked fastest — usage
is the sybil resistance *and* the marketing.

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
