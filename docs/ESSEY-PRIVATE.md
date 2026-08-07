# Essey Private — the privacy layer

Essey Private is a set of on-chain privacy tools on Robinhood Chain, built so you can hold, move, and earn
without being watched. It's single-chain by design (privacy comes from a crowd on one chain, not from bridging),
and everything runs client-side — proofs are generated in your browser, and private keys never leave your device.

**Experimental, testnet only.** Amounts, limits, and the honest caveats are stated plainly below.

## What it does, in four layers

### 1. Stealth-address payments — *get paid without being watched*
Publish one reusable address. Every payment lands at a fresh, **one-time address only you can detect and spend**, so
your public wallet never appears on the receiving side. This hides *who* was paid; amounts stay public. It's the
ERC-5564 / ERC-6538 standard, so off-the-shelf stealth wallets interoperate with the same registry.

### 2. Shielded pool — *hide your balance and amounts*
Deposit USDG into a zk shielded pool. Your balance and any in-pool movement are hidden, and the pool **breaks the
link between a deposit and a withdrawal**. It's a UTXO design (Tornado-Nova lineage) with an operator "front door"
that screens deposits — the compliance chokepoint sits in a separate contract so the audited money-math core stays
untouched. Proving runs in your browser (a few seconds).

### 3. Private transfers + cross-device recovery — *a real private-money system*
Each shielded note is encrypted to your key and stored on-chain, so your balance **recovers on any device** by
scanning the chain — no browser-bound storage to lose. And you can **receive private payments from others**: an
in-pool transfer moves shielded USDG between users without ever unshielding, visible to an observer only as opaque
commitments.

### 4. Relayer — *private, gasless withdrawals*
You can have a **relayer** submit your withdrawal or transfer, so the transaction comes from the relayer, not your
wallet — hiding your tx-origin, and costing you no gas. The relayer is **trustless**: the recipient, relayer, and fee
are all bound into the zk proof, so a relayer can only submit the exact transaction or refuse — never alter the fee
or redirect funds.

### 5. Shielded lending supply — *private, yield-bearing liquidity*
Supply USDG to the lending pool **privately**. Your supply position is a shielded note denominated in pool shares,
so **the position and the yield it earns are hidden**. Yield accrues automatically — a note's share count is fixed,
but the shares appreciate as interest accrues, so its value grows with no on-chain event tied to you. Withdraw the
note any time to receive your USDG plus accrued yield, to any address.

## The honest limits (testnet)

- **Amounts are public at the edges.** The shielded pool hides in-pool balances and the deposit↔withdrawal *link*,
  but a deposit and a withdrawal are still visible ERC-20 movements. On a new, small pool, matching amounts can
  re-link them — so unshield to a fresh address, and privacy strengthens as more people use the pool.
- **The anonymity set is small early on.** This is inherent to a young pool: you hide in the crowd, and the crowd is
  still forming.
- **One note per transaction** (the 2-input circuit); consolidation and a 16-input circuit are later work.
- **You need a standard wallet (EOA).** Keys derive from a wallet signature, which smart-contract wallets can't
  reproduce deterministically.

## What's still ahead (before mainnet / real value)

- A real **multi-party trusted-setup ceremony** for the circuit.
- A **formal specialist zk audit** by an outside firm.
- The **production screening engine** behind the front door, and the operator's **MSB / AML** track.
- **Production relayer hardening** (a gas-covering fee + rate-limiting) and mainnet token decimals.
- Depth we can add: **shielded stock** (AAPL/NVDA, not just USDG), viewing keys for selective disclosure, and a
  decentralized relayer network.

## How it's verified

Every money-touching change is attacked by multiple independent adversarial agents before it moves — the same gate
the rest of Essey uses. The private-money cycle (shield → transfer → receive → unshield, cross-device) and the
private yield-bearing supply are proven on-chain on testnet. Try it on the [Private](/private) page.
