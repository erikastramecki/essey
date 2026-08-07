# Essey Private — a single-chain shielded layer (design scope)

*Internal scope (uncommitted to the public narrative). This is a production-bound feature meant to go live
on Robinhood Chain mainnet, tested first on testnet. Legal/compliance is handled out-of-band by the operator
and is NOT an engineering gate — the build assumes it ships. Engineering owns mechanics + security; the
operator owns compliance + who gets access.*

## Thesis: single-chain is exactly what makes this real
Essey lives entirely on Robinhood Chain — no bridge, no cross-chain settlement. So the failure mode that
makes "private cross-chain payments" a LARP (the bridge/swap/CCTP legs leak amount + timing) does not exist
for us. A shielded pool on Robinhood Chain gives clean, genuine privacy, and the anonymity set is *Essey's
own users*. The single-chain constraint, usually a limitation, is the moat: exclusive, self-contained, honest.

## What it is
An opt-in **shielded balance on Robinhood Chain** for the assets Essey already uses — the **cash leg (USDG)**
and **tokenized stock (AAPL/NVDA)**. Deposit into the shield, hold a private balance, withdraw to any fresh
address, or transfer privately to another user. No public link between the deposit and the withdrawal.

## Two primitives — ship the easy one first
### Phase 0 — Stealth addresses (no zk, weeks not quarters)
ERC-5564 stealth addresses + ERC-6538 registry: a user publishes a stealth meta-address; a sender derives a
one-time address only the recipient can spend, moves funds there, and posts an announcement the recipient
scans with a viewing key. **No circuits, no trusted setup, no pooled custody** — the on-chain surface is a
registry (storage) + an announcer (events); the crypto is client-side secp256k1 ECDH. Gives *recipient
unlinkability* — your receiving address stops being a permanent public identity. Hides WHO receives, not
amounts. This is the fastest real thing we can put on testnet.

### Phase 1 — zk shielded pool (full privacy: hides amounts + anonymity set)
A Poseidon-UTXO commitment pool with Groth16 proofs (the Railgun / Tornado-Nova / Veil family): deposit, hold
encrypted balances, withdraw/transfer behind a zk proof.
- **Fork an audited implementation** (Railgun contracts, Privacy Pools, Tornado Nova) — do NOT write circuits
  from scratch. zk proof-forgery bugs are total (see Veil's Groth16 forgery). Budget a dedicated zk audit.
- Needs a **relayer** so private withdrawals don't require a gas-funded fresh address (itself a link).

## Phases (all production-bound; stock is first-class, not a locked experiment)
- **Phase 0 — Stealth-address private payouts. ✅ BUILT + DEPLOYED + PROVEN (testnet), 2026-08-06.**
  Contracts: EsseyStealthAnnouncer (ERC-5564) `0xe386…F402`, EsseyStealthRegistry (canonical ERC-6538)
  `0x7f28…880f`, EsseyStealthPay (zero-custody) `0x36B7…7403` — 8 Foundry tests + a 3-agent adversarial
  audit round (all clean). Frontend: a `/private` page (register meta-address, pay to a one-time stealth
  address, scan the inbox, sweep out) on `@noble` primitives via a self-owned `stealth.ts` (ERC-5564
  secp256k1) that passed a round-trip proof + a 3-agent money-path audit; the full register→pay→scan→sweep
  cycle is **proven on-chain** (real USDG moved to a stealth address and swept back, gasUsed 35,396).
  Gated to EOA wallets (SCW signatures aren't reproducible → would orphan funds); sweep-time linkage is
  disclosed honestly (relayer-funded gas is a later phase). The "opt-in private payout on Bell/Cases" is
  served by the page's shield-to-self path (withdraw to wallet, then pay privately) — no contract change.
- **Phase 1 — Shielded USDG pool.** Forked + audited zk pool; deposit / hold / withdraw / private transfer,
  with a relayer.
- **Phase 1b — Shielded STOCK (AAPL/NVDA).** The same pool machinery extended to the tokenized-stock tokens —
  a full, mainnet-targeted asset, tested on testnet then mainnet with a limited internal set. Standard
  operational **pause/resume** control (like any protocol feature), NOT a compliance kill-switch. See the
  mechanical notes below (adminBurn) — that's the interesting engineering question and the reason to prove it
  early.
- **Phase 2 — Shielded supply into the lending pool + private user-to-user transfers.**
- **Out of scope:** any cross-chain privacy — there is none, single-chain by design, and that is the point.

## Mechanical notes to prove early (engineering owns these)
- **adminBurn on stock.** The tokenized-stock issuer can burn tokens at any address, including the shielded
  pool's balance. Open question the harness must answer: if the pool's backing is burned, what happens to the
  outstanding commitments / anonymity set? A shielded pool assumes its ERC-20 backing is inviolable; a
  burnable backing breaks that assumption. We must characterize the failure mode (pro-rata haircut? frozen
  withdrawals? per-note backing?) before stock shielding is trusted with real value. This is exactly the
  "does it work with stock the way we test everything else" question — prove it on testnet first.
- **Anonymity set.** Bootstraps from routing opt-in payouts through the shield; weak until volume commingles.
- **Relayer + gas.** Private withdrawals need a relayer path so a fresh address never has to be gas-funded.

## Security gate (non-negotiable)
Everything that touches money passes **at least 3 independent adversarial audits (all clean, same round)**
before it moves forward — the standing rule. The zk pool additionally gets a dedicated circuit/verifier audit.

## Operator track (parallel, not a blocker)
Compliance, KYC/allowlist for the internal-test cohort, and legal sign-off run in parallel and are owned by
the operator. Engineering does not gate on them; it builds production-capable and ships when the operator
greenlights access.

See CLAUDE.md context; relates to the Vault (ERC-6551), Bell payouts, Cases, and the lending pool.
