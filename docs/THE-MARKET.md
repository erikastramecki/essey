# The Market layer — design

A stock-market club where the odds and the books are both provable. This is the mechanic spec: what each
piece is, why it's shaped that way, and what's enforced on-chain versus promised.

## The loop

**Get a Seat → raise its Tier → someone rings the Bell → stock lands in your Vault.** Fees from real
activity — trading, royalties, loan interest — pool up, and the Bell splits the pot across every active
Seat, by Tier, paid in real stock. No emissions anywhere in the loop: everything distributed was first
earned.

## The mechanics

### Seat — membership as an asset
2,222 ERC-721s. Owning one is owning a slice of everything the club earns. Scarcity is real (the supply
is immutable) and visible (the float held by the Exchange is on-chain).

### Vault — the Seat IS a wallet
Every Seat deploys its own token-bound wallet (ERC-6551) at mint, at a deterministic address only the
collection can create. Payouts land in the Vault, not your EOA — so selling a Seat sells a *portfolio*,
and everything it ever earned travels with it. One honest consequence: sellers should claim and drain
before selling; a Vault's contents belong to the Seat, not to you.

### Tier — staking that buys weight, not yield
Stake $ESSEY to raise a Seat's Tier; higher Tier means a larger slice of every Payout. Half of every
activation fee is burned. Tier clears when the Seat changes hands — deliberately: status is a recurring
choice by the current owner, not a permanent subsidy to whoever staked first, and the churn is a
permanent $ESSEY sink.

### The Bell — permissionless payouts with a bounty
When the fee pot is worth ringing, **anyone** can ring it, and the ringer earns a tip for paying the gas.
No keeper, no bot infrastructure, no admin schedule — the crowd is the cron job. Distribution is O(1)
accumulator math (a global per-weight index; each Seat tracks its debt against it), so a ring costs the
same gas whether ten Seats are active or two thousand.

### Payout — a fee-share, never a dividend
The pot splits pro-rata by Tier weight into every active Seat's Vault, paid in the fee stable or —
per-Seat, opt-in — converted at the claim edge into a chosen stock. Conversion is oracle-checked and
session-gated; if it can't fill safely it **fails open to base**: you always get paid, the only question
is the asset. We say "Payout" and never "dividend" because that's what it is: protocol fees,
mechanically LP-style, never guaranteed.

### The Exchange — instant liquidity for Seats
A two-sided vault AMM holding Seat inventory and an $ESSEY reserve at a flat price: **buy** the next
Seat, **snipe** an exact number for a premium, or **sell** one back to the float. Every trade's fee
drops into the Bell's pot — the market for membership funds the members. The float doubles as the
scarcity dial, and the whole thing is adminless over funds: the one privileged role can only *add*
inventory, never touch a balance.

### Note — your loan is a bearer certificate
Borrowing mints a Note: an NFT that *is* the position. Debt, collateral claim, and solvency state travel
together, transferable as one object — sell your loan, gift it, use it. The engine underneath is a real
lending protocol with conservative, session-gated oracle discipline; the Note is that engine's position
made portable.

### Cases — fair-value packs and the Degen multiplier
Two ways to open a Case, both provably fair and provably solvent, behind one Safe/Degen toggle.

**Fair-value Cases.** Buy in $ESSEY; a committed on-chain draw delivers a real stock unit straight to
your wallet. **Every unit is ~the case's value — the draw only ever decides which name.** Rarity is
scarcity of the name, never payout size. The bankroll is provably solvent: buying reverts unless a real,
already-deposited prize unit backs your unopened case. Sell any unit back at oracle value minus a floored
spread; both fee legs feed the Bell.

**The Degen Case.** A multiplier roll — 0.65× to 50×, ~90% average payback — for players who want the
variance. It stays honest on the two axes an ordinary box can't: **provably fair** — the roll is a
Keccak256-verifiable commit-reveal (the Dice Protocol entropy oracle) mapped onto odds published
on-chain, so anyone can recompute the outcome — and **provably solvent** — every open reserves its
worst-case 50× payout in real stock *before* you roll, priced at buy. Winnings are pull-based (withdraw
when you like); if a roll is ever left unsettled, anyone can reclaim it for the floor. Rolls settle during
US market hours, when the reserve is priced. The old "no multipliers, ever" gate is retired: uneven
prizes are exactly what a verifiable-entropy + worst-case-reserve design makes safe to ship.

### The Tape — the receipts, live
Everything above prints to a live feed where every line is a real transaction with a verify link. A
"proven only" filter lets a skeptic watch nothing but the verifiable events. When the Tape is quiet, it
says so — a fee-share that fakes busy would be lying about the only thing that matters.

## Why this composition works

Each mechanic feeds another: trading funds Payouts; Payouts justify Tiers; Tiers sink $ESSEY; Seats
carry their history in Vaults, which makes the Exchange's flat price meaningful; loans mint Notes and
pay interest into the same pot. The design goal is a flywheel where **every reward traces to a fee and
every fee traces to a transaction you can check** — engagement mechanics with an audit trail, not
instead of one.

## What's live today vs designed

**Live on Robinhood Chain testnet, adversarially audited (published rounds, clean or not), with play
money:** Seats, Vaults, Tiers, the Bell paying real stock through the claim-edge converter, the Exchange,
the mint distributor, fair-value Cases, and the Degen multiplier Case. Stock payouts and degen rolls are
proven end-to-end on-chain (a Bell claim delivering AAPL + NVDA into a Seat's Vault; a roll settling and
crediting stock). The lending engine — supplying to earn, and borrowing against the stock you hold, each
loan a transferable Note — is deployed; open borrowing switches on with the seeded pool.

**Designed, not yet built:** royalty routing and the loan-interest→Bell share (the After Hours engines),
the Tape's full indexer, and on-chain Seat art. **Not yet on mainnet:** everything here is testnet play
money with no real value. The mainnet cut swaps the testnet's mock entropy for the live Dice oracle and
the play tokens for real ones.
