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

### 6. Shielded stock — *private stock positions, resilient to issuer burns*
Shield tokenized stock (AAPL / NVDA), not just USDG — hold a **private stock balance**, transfer it privately, and
withdraw to any address. Stock carries one hazard USDG does not: the token's issuer can **burn tokens at any
address**, including the pool's own backing (a real Robinhood Stock Token power, a regulatory clawback surface). A
naive shielded pool assumes its backing is inviolable, so a burn would freeze the last people to withdraw entirely —
a bank run. The shielded-stock pool instead applies a **pro-rata haircut**: if the backing is ever burned, every
holder redeems their proportional share of what remains, in the same proportion no matter what order they exit — the
loss is shared fairly, never dumped on whoever is slowest. Once impaired, deposits close (so no new depositor
subsidizes the shortfall) while withdrawals always stay open. This failure mode and its mitigation are proven by a
dedicated on-chain harness before the feature is trusted with real value.

## The honest limits (testnet)

- **Amounts are public at the edges.** The shielded pool hides in-pool balances and the deposit↔withdrawal *link*,
  but a deposit and a withdrawal are still visible ERC-20 movements. On a new, small pool, matching amounts can
  re-link them — so unshield to a fresh address, and privacy strengthens as more people use the pool.
- **The anonymity set is small early on.** This is inherent to a young pool: you hide in the crowd, and the crowd is
  still forming.
- **One note per transaction** (the 2-input circuit); consolidation and a 16-input circuit are later work.
- **You need a standard wallet (EOA).** Keys derive from a wallet signature, which smart-contract wallets can't
  reproduce deterministically.

## The mainnet blockers (named, grounded — this is NOT mainnet-ready)

Three concrete blockers stand between the testnet build and a safe live transfer. Do NOT deploy real
funds until every one clears (per [MAINNET-ACTIVATION.md](MAINNET-ACTIVATION.md), Update 2, lines ~90–104):

1. **HARD BLOCKER — placeholder/single-contributor verifier → forgeable proofs.** The deployed zkey is
   single-contributor (`DeployShieldedPool.s.sol:20-21`, `pool/README.md:41-43`), so **proofs are
   forgeable and the pool is drainable with real money**. This needs a multi-party trusted-setup ceremony
   + a regenerated verifier/zkey/wasm before ANY mainnet value. A cryptographic must, not a config tweak.
2. **`openMode=true` baked into the deploy script** (`DeployShieldedPool.s.sol:41`) while the gate itself
   says it MUST be false in production (`EsseyPoolGate.sol:17`; `setOpenMode` at `:58-60`). Fix before deploy.
3. **Unhaircut USDG pool.** The plain-USDG shielded pool has **no pro-rata haircut**
   (`EsseyShieldedPool.sol:169-177`). Real USDG is pausable, per-address freezable, and an upgradeable
   proxy (verified on-chain, `MAINNET-ACTIVATION.md` Update 3), so a pause/freeze/upgrade against the
   pool could brick or seize funds with no defense. Shielded STOCK already handles issuer adminBurn via a
   pro-rata haircut (`EsseyShieldedStock.sol:162-166`); shielded USDG does not.

## What's still ahead (before mainnet / real value)

- A real **multi-party trusted-setup ceremony** for the circuit (blocker 1 above).
- A **formal specialist zk audit** by an outside firm.
- The **production screening engine** behind the front door, and the operator's **MSB / AML** track.
- **Production relayer hardening** (a gas-covering fee + rate-limiting) and mainnet token decimals.
- The **live-token burn assumption** for shielded stock: the pool reads any drop in its raw backing as an issuer
  burn. That is correct for the Robinhood Stock Token model (corporate actions move a display multiplier, not raw
  balances), but it is the assumption to confirm against the production token before real value.
- Depth we can add: viewing keys for selective disclosure, a 16-input circuit for note consolidation, and a
  decentralized relayer network.

## How it's verified

Every money-touching change is attacked by multiple independent adversarial agents before it moves — the same gate
the rest of Essey uses. The private-money cycle (shield → transfer → receive → unshield, cross-device) and the
private yield-bearing supply are proven on-chain on testnet. Shielded stock ships with a dedicated **adminBurn
harness** that characterizes the bank-run failure of a naive pool and proves the pro-rata haircut socializes an
issuer burn fairly and order-independently — the same socialization the lending engine uses for the same hazard.
Try it on the [Private](/private) page.
