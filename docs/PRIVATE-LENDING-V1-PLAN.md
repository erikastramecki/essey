# Private Lending v1 — the phased build plan

_Status: **PLANNING / DESIGN ONLY** — no code changed. This is the executable engineering plan for the
GO recommendation in `docs/PRIVACY-FULL-STACK-FEASIBILITY.md` ("GO on private lending as the v1
primitive; do NOT delay the current launch; treat private staking/rewards as research"). Every
load-bearing claim about the existing stack cites `file:line`. Written 2026-08-12 against
`feat/essey-market-layer`._

**The product in one sentence:** deposit stock-token collateral privately, borrow USDG against a
**hidden** position, prove `collateral · price ≥ debt / ltv` in zero knowledge on-chain without
revealing amounts — **confidential to the public, auditable by the user, screened at the front door,
disclosed on default.** Positioning is fixed by the feasibility study: _compliance-aware confidential
DeFi_, not anonymity (`PRIVACY-FULL-STACK-FEASIBILITY.md` §5.2, §7).

---

## 0. Executive answers (what the founder asked for, up front)

- **Doc:** this file.
- **Phases:** M0 decisions+spec (1–2 wks) → M1 circuits (4–5 wks) → M2 contracts+testnet (5–6 wks,
  overlaps M1) → M3 SDK/UI/relayer (4 wks, parallel to late M2) → M4 ceremony + formal audit +
  compliance (external, 6–10 wks calendar, starts as soon as M1/M2 freeze) → M5 mainnet gate.
- **Critical path:** M0 → M1 → M2 → M4(audit) → mainnet. M3 is off the critical path. Counsel
  engagement and audit-firm booking start at **M0** because their lead times, not our build time, set
  the calendar.
- **Time-sensitive answer (Don mainnet deploy #81): NO — nothing must be baked into the imminent Don
  stack.** DonLoan already carries everything private-lending ever needs from it (`loanTuple()`,
  `DonLoan.sol:244-265`), and v1 is a **separate contract stack** that never touches DonLoan. Full
  reasoning in §6.
- **Top 3 risks:** (1) liquidating a *hidden* position — the one research remnant dregg does NOT
  cover; mitigated by calendar-default term loans + in-circuit encrypted liquidation tickets
  (privacy forfeits on default). (2) Regulatory / chain-operator tolerance (the _Storm_ profile);
  mitigated by compliance-first design + counsel from M0 + a decision gate before mainnet. (3) A
  silent circuit-soundness bug = un-detectable insolvency; mitigated by differential fuzzing against
  the validated gnark reference, the standing 3-agent rounds, the external formal audit, and launch
  deposit caps.
- **Totals:** ~**4–5 months to testnet-proven**, ~**5–7 months to mainnet** (audit + ceremony +
  counsel are the tail). External cash: **~$80k–$250k** (formal zk audit $60–180k, counsel $20–60k,
  ceremony ≈ $0–10k coordination).

---

## 1. Architecture v1 — concretely

### 1.1 The two stacks being connected

- **Stack A (shipped):** the Nova shielded pool — UTXO join-split hiding amounts, deposit gate,
  nullifier set, incremental Merkle tree, snarkjs Groth16 verifier with 7 public signals
  (`rh-chain/src/private/pool/EsseyShieldedPool.sol:36-46,108-183`), proven on RH testnet at depth 20
  (27,022 constraints, `pool/README.md:30-38`). Client prover in the browser
  (`app/web/src/poolsdk.ts`), trustless relayer (`app/web/api/relay.ts:4-8`).
- **Stack B (validated, not wired):** the dregg solvency/transition circuit — proves a borrow against
  a hidden position keeps `debt·10000 ≤ collateral·price·ltvBps`, with only roots + price public
  (`circuit/poseidon/transition.go:41-91`, `solvency.go:33-43`); single-VK IVC proven end-to-end
  (`docs/SCOPE-solvency-rollup.md:314-360`). gnark's Poseidon is **verified byte-identical** to the
  iden3 reference (`docs/SCOPE-solvency-circuit.md:103-106`) — which is the same circomlib Poseidon
  Stack A's circuits and `MerkleTreeWithHistory.zeros()` use (`pool/README.md:18-19`). **The two
  stacks already share a hash function.** That is what makes note-commitment unification an
  engineering task, not a research one.

### 1.2 Decision D1 — implementation substrate for the new circuits (decide at M0)

The feasibility study framed the work as "gnark→BN254 EVM verifier port." Grounded in what v1
actually needs (browser proving + EVM verify + a snarkjs ceremony), the recommended resolution is:

**Write the new borrow/repay/release/liquidate circuits in circom, and use the validated gnark
circuit as the executable spec + differential-test oracle.** Rationale:

- The user-facing prover must run **in the browser**. Stack A's snarkjs/WASM pipeline already does
  this at 27k constraints (`poolsdk.ts:309+`); the borrow circuit lands in the same class (~60–150k
  constraints: two Merkle paths + Poseidon commitments + the solvency comparator + the ticket
  encryption). A gnark prover compiled Go→WASM is tens of MB and unproven in this repo.
- circom emits notes with the **exact** circomlib Poseidon Stack A uses → the "unify the note
  commitment" work item collapses to "use the same library," verified by known-answer tests.
- snarkjs has mature **multi-party ceremony tooling** (the M4 gate, `pool/README.md:39-46`); one
  toolchain means one ceremony process for all circuits.
- The gnark stack is **not discarded**: `TransitionCircuit`/`enforceSolvent` become the reference
  implementation every circom circuit is differential-fuzzed against (same statement, two independent
  encodings — accept iff both accept), and the IVC fold stays warm for the later
  "provably-solvent private pool" attestation (out of v1 scope, §1.8).

Fallback if D1 goes the other way (gnark + exported Solidity verifier): everything below still holds;
M1 gains a WASM-prover workstream and M3 gains a bundle-size/memory risk.

### 1.3 Contract set

One new money contract plus reuse:

```
                       ┌────────────────────────────────────────────────┐
   deposit AAPL        │  EsseyPrivateLending.sol  (NEW, one contract)  │
  (gate-screened) ───▶ │                                                │
                       │  Tree C  collateral notes   (Nova format)      │
                       │  Tree P  position notes     (dregg-style)      │
                       │  Tree D  USDG draw notes    (Nova format)      │
                       │  nullifier sets (per tree)  + USDG float       │
                       │                                                │
   Chainlink feed ───▶ │  StaleFeedGuard (REUSED)  price binding        │
   EsseyPoolGate  ───▶ │  isApproved()   (REUSED)  deposits only        │
                       │                                                │
   verifiers:          │  PoolVerifier2 (REUSED)   join-split C and D   │
                       │  BorrowVerifier / RepayVerifier /              │
                       │  ReleaseVerifier / LiquidateVerifier (NEW)     │
                       └────────────────────────────────────────────────┘
        exits: standard join-split withdraw from Tree D via relayer → stealth address
```

- **`EsseyPrivateLending.sol` (net-new, ~600–800 lines):** three `MerkleTreeWithHistory` instances
  (the audited tree, reused — `pool/README.md:18-19`), per-tree nullifier mappings (the
  `EsseyShieldedPool` pattern, `:49,166-167`), the USDG lending float (treasury-seeded, permissionless
  `fund()` like `DonLoan.sol:271-275`), and one entrypoint per operation. **Crucial adaptation from
  Stack B:** `MerkleTreeWithHistory` is append-only — dregg's in-place leaf replacement
  (`transition.go:88-90`) does not map onto it. Positions therefore live as **UTXO-style notes**:
  every position change spends the old position note (nullifier) and appends a new one. Same solvency
  statement, Nova's state discipline. This lets one tree implementation and one replay design serve
  all three trees.
- **Why one contract, not "lending pool wraps the shielded pool":** the borrow draw must become a
  *hidden* USDG note. If the lender and the shielded USDG pool are separate contracts, the draw is a
  public ERC-20 `Transfer` between them (amount leaked — feasibility §4.1 row 1). Holding the float
  and the note tree in the same contract makes the draw a pure tree insert: **no token moves at
  borrow, so no amount leaks.** The existing standalone shielded USDG/stock pools
  (`EsseyShieldedPool/Stock/Supply`) stay deployed and untouched; v1 is a sibling, not a migration.
- **Reused verbatim:** `EsseyPoolGate` (front door, `EsseyPoolGate.sol:15-64`), `PoolVerifier2` +
  `transaction.circom` for the deposit/exit join-splits on Trees C and D (the borrow circuit emits
  output commitments in Nova's exact note format, so the shipped, audited join-split spends them
  unchanged), `StaleFeedGuard` for the price read (`StaleFeedGuard.sol:129-162`), the relayer
  (`api/relay.ts` — add the new pool to `ALLOWED_POOLS`, `:19-24`), and `EsseyShieldedStock`'s
  pro-rata `adminBurn` haircut mechanics for the collateral tree (the RH issuer can burn/pause the
  underlying token; that hazard class is already solved once — reuse the same reconciliation).

### 1.4 Note & commitment design — the actual statements proven

**Note formats (all circomlib Poseidon, BN254):**

- Collateral / USDG note (Nova, unchanged): `commit = Poseidon(amount, ownerPubKey, blinding)`;
  nullifier = `Poseidon(commit, leafIndex, sign(spendKey, commit, leafIndex))`
  (`poolsdk.ts:114-147`). Trees C and D.
- Position note (new, dregg-derived): `pcommit = Poseidon(collateral, debt, ltvBps, expiry,
  ownerPubKey, blinding)` — the dregg leaf (`transition.go:11-25`) reshaped for an EVM UTXO pool:
  `pool/type` drop out (one contract = one collateral asset = the type, bound by construction;
  matches the feasibility's "single-collateral pool leaks the type by construction" — accepted for
  v1), `borrower` becomes the note-owner pubkey, `nonce` becomes the blinding, and **`expiry` joins
  the commitment** (term hidden until default). Position nullifier: Nova-style, so replay/double-close
  is impossible by the same mechanism already audited for notes. Trees are physically separate, so a
  position commitment can never be spent as a money note (type-confusion is structural, not
  constraint-dependent).

**BORROW — the load-bearing statement.** Public inputs (bound by the contract):
`[rootC, rootP, price, nowTs, nullifierC, pcommitNew, dcommitNew, ticketFields..., extDataHash]`.
Private: collateral note preimage + path in C; draw amount `D`; term; output blindings; ticket
encryption randomness. Constraints:

1. **Membership + spend:** collateral note `(C, pk, b)` is in `rootC`; `nullifierC` correctly derived
   (prevents double-pledge of the same collateral note).
2. **Position creation:** `pcommitNew = Poseidon(C, D, ltvBps, expiry, pk, b′)`, with
   `expiry = nowTs + term`, `term ∈ [MIN_TERM, MAX_TERM]`.
3. **Solvency (the dregg rule, verbatim):** `D · 10000 ≤ C · price · ltvBps` with the exact
   range-check discipline of `enforceSolvent` — `ToBinary(64)` on amounts, 96-bit price, 16-bit ltv,
   so no product wraps the field (`solvency.go:33-43`). `ltvBps` is a public pool parameter asserted
   equal in-circuit.
4. **Draw note:** `dcommitNew = Poseidon(D − fee, pk_recipient, b″)` — a hidden USDG note in Tree D.
   Origination fee (the DonLoan shape: prepaid, flat debt — `DonLoan.sol:11-33`) is a public
   `feeBps` netted in-circuit; debt recorded is the full `D`.
5. **Liquidation ticket (net-new, the one component with no in-repo precedent):** the circuit proves
   the published ciphertext is a correct Poseidon-DuplexSponge encryption of the position preimage
   `(C, D, ltvBps, expiry, pk, b′)` under `ECDH(ephemeralKey, keeperPubKey)` — the MACI pattern
   (in-circuit verifiable encryption via Poseidon; ~5–15k constraints). This is what makes a
   walked-away borrower liquidatable at all (§1.6) without trusting the borrower to encrypt honestly
   (an unverified blob like Nova's `encryptedOutput` would let a malicious borrower submit garbage
   and strand the debt forever — unacceptable in a lending pool).

Contract-side at `borrow(proof, publics, extData)`:
- `(price, dec, inSession) = StaleFeedGuard.priceOf(AAPL)`; require `inSession` (no borrows off-hours
  or on holidays — `StaleFeedGuard.sol:143-159`) and assert the proof's public `price` equals the
  fresh read. Require `nowTs == block.timestamp` (±small tolerance for inclusion delay).
- verify Groth16; check roots known (`isKnownRoot`), nullifier unspent; mark nullifier; append
  `pcommitNew` to P and `dcommitNew` to D; emit `NewCommitment` with the ECIES-encrypted note payload
  for the owner (the existing recovery mechanism, `EsseyShieldedPool.sol:51-58,179-180`) and the
  liquidation ticket ciphertext.
- **No token transfer happens.** Public leakage per borrow: that a borrow happened, when, and the
  collateral asset — never the amounts (feasibility §4.1, accepted seam).

**REPAY.** Public: `[rootP, rootD, nullifierP, nullifierD, pcommitNew|0, extDataHash]`. Proves: spend
position `(C, D, …)` and a USDG note of value `R ≤ D` (or accept a **public** USDG deposit leg
through the gate for repay-from-outside); new position `(C, D−R, …)` appended, or — when `D−R = 0` —
no new position and instead a **release**: a fresh collateral note `(C, pk, b‴)` appended to Tree C,
spendable/withdrawable by the owner. **Repay/release take no price input and are never gated** —
mirrors the pool invariant "withdrawals are never gated" (`EsseyShieldedPool.sol:31-33`) and, because
no solvency check is needed when debt only falls, **repay keeps working when the feed is stale or the
market closed.** Fail-closed borrows, always-open exits.

**LIQUIDATE (calendar default — §1.6).** Public: `[rootP, nullifierP, nowTs, seizedValue, surplus-
commit]`. The keeper (holding the decrypted ticket) proves: position `(C, D, ltv, expiry, pk, b′)`
∈ `rootP`, `expiry + GRACE < nowTs`, `seizedValue = min(C, needed)` per the waterfall, and a surplus
collateral note re-committed **to the borrower's own pk** (surplus-back, the DonLoan discipline —
`DonLoan.sol:54-58`). The seized collateral value is credited to a pool-owned note / public reserve
leg and sold publicly to restore USDG (the boundary crossing is public — feasibility §4.1 row
"liquidation event"; unavoidable and disclosed).

### 1.5 Price binding

- **Feed:** the live Chainlink AggregatorProxy for the collateral, already verified on mainnet —
  AAPL `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0`, NVDA `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15`
  (`docs/MAINNET-CONFIG.md:181-184`; proxy-not-raw-aggregator rule at `:98-101`). All RH-chain feeds
  run **86400s heartbeat / 0.5% deviation** (`StaleFeedGuard.sol:19-22,63-67`).
- **Mechanism:** on-chain binding (the option `SCOPE-solvency-circuit.md:40-44` recommends): the
  circuit treats `price` as a trusted public input; the **contract** asserts it equals a fresh
  `StaleFeedGuard.priceOf()` read in the same tx. No signature-in-circuit.
- **Staleness rules:** `maxStaleness = heartbeat + 3600s grace` (`StaleFeedGuard.sol:55-58,66-67`);
  borrows additionally require `inSession == true` (the 14:30–20:00 UTC conservative window +
  holiday detection, `:143-197`). **On stale/off-session: borrows revert (fail closed); repay,
  release, withdraw, and calendar liquidation all proceed** (none of them read a price). This is the
  same "no fresh price → refuse to originate, never refuse to exit" doctrine the public stack already
  ships.
- Sequencer-uptime: no feed exists on RH chain (`MAINNET-CONFIG.md:147,173`); inherit the disclosed
  compensating-controls stance (`StaleFeedGuard.sol:73-95`).

### 1.6 Why calendar default (and not price liquidation) — the honest core decision

dregg retires "prove solvency over hidden values." It does **not** answer "who liquidates a position
nobody can see?" — a price-triggered margin call requires someone to *know* a hidden position is
underwater, which contradicts hiding it. This is the genuine research remnant (risk R1, §5). v1
resolves it the way the standing design rule resolves lending forks — **reuse the shipped
DonLoan v3 model**: **fixed-term loans, interest prepaid, flat debt, default is a calendar event**
(`DonLoan.sol:11-19,48-58`). Concretely:

- Terms bounded (`MIN_TERM`–`MAX_TERM`; recommend 7–90 days for stock collateral — shorter than
  DonLoan's 365d ceiling because AAPL, unlike the monotone Don floor, can fall).
- Conservative LTV sized to worst historical drawdown over `MAX_TERM + GRACE` per
  `docs/LTV-RISK-FRAMEWORK.md` (recommend opening at 35–50%; founder parameter).
- On `expiry + GRACE`: the keeper decrypts that position's ticket and runs the liquidate proof.
  **Privacy is forfeited on default, and only on default, and only for that position** — a clean,
  compliance-positive line ("we can always resolve a defaulted loan; we can never see a performing
  one").
- The ratio trigger is deliberately absent in v1 (not merely dead-but-live as in
  `DonLoan.sol:49-54`): with hidden positions there is no honest way to fire it. Price risk inside
  the term is **pool underwriting risk**, priced by LTV + term caps + fees + a public
  `maxDrawPerPosition` cap (so aggregate exposure ≤ openPositions × cap is publicly boundable).

### 1.7 Settlement flow end-to-end

```
1. SCREEN   operator approves depositor (EsseyPoolGate.setApproved — ASP/KYT, §3)
2. DEPOSIT  AAPL → Tree C note. Boundary amount public (extAmount) unless funded by an
            internal transfer from already-shielded stock notes (then hidden).
3. BORROW   zk proof (browser, ~seconds) → position note + hidden USDG draw note.
            Price bound to Chainlink in-tx. No token moves. Ticket escrowed to keeper key.
4. EXIT     spend draw notes via the SHIPPED join-split withdraw, through the relayer,
            to a stealth/fresh address (poolsdk + api/relay.ts + ERC-5564 stealth).
            Amount public at the boundary; link broken; splittable across time/denoms.
5. REPAY    shielded USDG notes (or public gate-screened USDG) → debt falls; at zero,
            collateral note released to Tree C → withdrawable. Never gated, never priced.
6. DEFAULT  expiry+grace → keeper decrypts ticket → liquidate proof → collateral seized
            at need, surplus note back to borrower. Public boundary crossing, disclosed.
```

### 1.8 Explicitly out of v1 scope (so the plan stays honest)

Private staking/rewards (the unsolved `totalWeight` problem — feasibility §4.2), multi-collateral in
one pool (type-hiding), price-triggered liquidation of hidden positions, the 16-input join-split,
private LP supply into the lending float (v1 float is treasury-seeded; wiring `EsseyShieldedSupply`
in is a v1.1 candidate), and the IVC "provably-solvent private pool" attestation (kept warm in gnark;
note that in a UTXO design no single party knows all positions, so the aggregate-solvency story needs
its own design pass before it is promised).

---

## 2. Reused vs net-new — the 40–50% claim, quantified

| Component | Exists (file) | Changes needed | Net-new |
|---|---|---|---|
| Shielded-money core: tree, nullifiers, ext-data binding, gate hook | `EsseyShieldedPool.sol:36-193`, `MerkleTreeWithHistory.sol` | instantiate 3 trees in the new contract; per-tree nullifier namespaces | — |
| Join-split circuit + verifier (deposit/exit legs, Trees C & D) | `circuits-nova/transaction.circom`, `PoolVerifier2.sol` (`pool/README.md:24-28`) | none (borrow emits Nova-format notes on purpose) | — |
| Compliance front door | `EsseyPoolGate.sol:15-64` | none on-chain; production ASP process behind it (§3.1) | screening runbook |
| Solvency statement + range discipline | `solvency.go:33-43`, `transition.go:41-91` | re-express in circom (D1); gnark kept as differential oracle | BorrowCircuit (circom) |
| Position/state-transition pattern | `transition.go` (in-place update) | adapt to append+nullify UTXO positions (§1.4) | position-note lifecycle circuits (Repay/Release/Liquidate) |
| Poseidon equivalence (the unification linchpin) | verified gnark ≡ iden3 (`SCOPE-solvency-circuit.md:103-106`); pool uses same circomlib (`pool/README.md:18-19`) | known-answer tests across all arities used | — |
| Price binding + staleness + session gating | `StaleFeedGuard.sol` (whole file), feeds verified (`MAINNET-CONFIG.md:181-184`) | wire into `borrow` only | — |
| Client prover SDK (keys, notes, Merkle, proofs, ECIES note encryption) | `poolsdk.ts` (698 lines; keypair/Utxo/tree/prove machinery `:97-320`) | add borrow/repay/release builders + position-note scanning | ~30% new SDK code |
| Relayer (trustless, allow-listed) | `api/relay.ts:19-24,78-92` | add pool address; set production `MIN_FEE`; RELAYER_PK ops | — |
| Stealth exit rail | `EsseyStealth*.sol`, `stealth.ts` | none | — |
| Issuer-hazard handling (adminBurn/pause on collateral) | `EsseyShieldedStock.sol` pro-rata haircut | port the reconciliation to Tree C | — |
| Lending float + funding + term-loan shape | `DonLoan.sol:267-294` (fund/withdrawIdle), v3 term model | pattern reuse | `EsseyPrivateLending.sol` (~600–800 lines) |
| Liquidation ticket (verifiable encryption to keeper key) | — (MACI prior art, no in-repo code) | — | **the one all-new cryptographic component** |
| Ceremony tooling | snarkjs flow referenced `pool/README.md:39-46` | — | ceremony execution (external humans) |
| Viewing keys / audit export | ECIES enc-vs-spend key split already in SDK (`poolsdk.ts:21-22,44-48,249`) | formalize + export tool (§3.2) | disclosure bundle format |

**Verdict on the study's "~40–50% of plumbing exists":** confirmed, and now itemized. The
shielded-money leg, the compliance door, the price guard, the relayer/stealth rails, the prover SDK
skeleton, and the solvency *statement* are all standing. The genuinely new work is: four circom
circuits (one with verifiable encryption), one money contract, ~30% SDK growth, and the external
gates (ceremony, audit, counsel). No new research except R1, which §1.6 designs around rather than
solves.

---

## 3. Compliance-aware from line one

### 3.1 The screened front door (what screening, exactly)

`EsseyPoolGate.isApproved` already gates every deposit (`EsseyShieldedPool.sol:109-110`) and holds no
funds (`EsseyPoolGate.sol:14`). v1 keeps the interface and specifies the production process behind it:

- **Screening at approval time:** operator runs each requesting address through a commercial KYT/
  chain-analytics screen (TRM/Chainalysis-class: sanctions exposure, mixer proximity, stolen-funds
  taint) before `setApproved`. Approval is per-address, revocable, batched (`:47-58`). `openMode`
  **must be false** in production (`:17,60-64` already says so).
- **Deny-list compatibility:** (a) mirror Robinhood Chain's own actively-used deny-list — any address
  the chain operator blocks is auto-revoked from the gate; (b) re-screen on a cadence; revocation
  stops new deposits from that address but — by the pool's core invariant — **never traps funds:
  withdrawals are never gated** (`EsseyShieldedPool.sol:31-33`). This is the Railgun/ASP
  "screen-in, never trap" shape the feasibility endorses (§5.2).
- **Borrow/repay are not separately gated:** only screened funds can enter, so every note is
  screened-origin by induction; adding a gate to exits or proofs would break the "can always exit"
  invariant and add nothing.
- Launch posture: the beta allowlist doubles as the gate cohort (same curation muscle as
  `MAINNET-GO-LIVE.md` Phase 5).

### 3.2 Viewing keys / selective disclosure (the concrete mechanism)

The SDK already separates the **spend keypair** from the **encryption keypair** (`deriveKeypair` +
`PoolEncKeypair`; ECIES secp256k1 ephemeral-ECDH → HKDF-SHA256, `poolsdk.ts:21-22,44-48,249-260`),
and every note is published encrypted to the owner's enc key on-chain
(`EsseyShieldedPool.sol:51-58,179-180`). Therefore:

- **The viewing key IS the enc private key.** It decrypts every note (amount + blinding) ever
  addressed to the user but **cannot spend** (spending needs the separate spend key's signature in
  the nullifier, `poolsdk.ts:139-147`). Formalize this split as a product feature: "export viewing
  key" in the UI, derivation documented, spend key never leaves the wallet flow.
- **User-held path (default):** only the user holds both keys; the public sees commitments and
  ciphertexts.
- **Auditor path (user-initiated):** an **audit-export bundle** — the tool walks `NewCommitment`
  events, decrypts with the viewing key, and emits `{note preimages, position preimages, tx hashes,
  leaf indices}` + a user signature, independently verifiable by recomputing every Poseidon
  commitment against chain state. Hand it to a tax authority, an exchange, or — on lawful request —
  a regulator. No protocol change; deterministic; cannot be forged or partial-truthed (commitments
  either match or don't).
- **Keeper/default path (automatic, narrow):** the liquidation ticket (§1.4.5) is a per-position
  viewing grant to the operator's keeper key that is only *usable* after `expiry + GRACE` (the
  contract rejects earlier liquidate proofs via the public `nowTs` binding). Performing loans stay
  invisible to the operator. (Residual honesty note: the keeper key can technically decrypt a ticket
  ciphertext early off-chain — it just can't act on-chain or learn anything it won't lawfully learn
  at default anyway. If the founder wants stronger, a timelock-encryption scheme is a v2 upgrade;
  say the true thing in the docs.)

### 3.3 What the operator can and cannot see / touch

| Party | Sees | Can touch |
|---|---|---|
| Public | action existence/count/timing, collateral asset, aggregate float + tree sizes, price, boundary deposits/exits, defaults | nothing |
| Operator (gate) | approval requests + KYT results (off-chain PII stays off-chain, per the Phase-5 rule) | admit/revoke depositors only; **cannot move funds** (`EsseyPoolGate.sol:14`) |
| Relayer | withdrawal recipient, amount, timing of txs it relays | can only submit-or-refuse the exact user-built tx — extDataHash binds recipient/relayer/fee into the proof (`api/relay.ts:4-8`); cannot redirect or alter |
| Keeper (liquidation key) | defaulted positions' preimages, at/after default | run the public liquidate path only |
| Contract admin | — | `maximumDepositAmount` limit only, per the Nova pattern (`EsseyShieldedPool.sol:185-192`); no withdraw, no pause over user exits — carry the DonLoan "adminless over user funds" trust surface (`DonLoan.sol:70-72`) into the new contract |

**The Storm-case line (feasibility §5.1):** the entities in the fund-adjacent path are (a) the
relayer — kept **provably trustless** (submit-or-refuse only) and with a published fee schedule, and
(b) the keeper — which never custodies user funds (liquidation settles inside the contract's public
waterfall). No Essey service ever holds or redirects user value; contracts are adminless over user
funds; the gate is screen-in-only. That is the maximum structural distance from "operating an
unlicensed money-transmitting business" this architecture can buy — **counsel must still bless it
(M0/M4 gate), and marketing copy must say "confidential," never "anonymous."** The chain operator's
tolerance is the binding constraint (feasibility §7); a pre-mainnet briefing of the RH chain team is
the founder's call at the M5 gate.

---

## 4. Phase breakdown

Durations assume the current build capacity (agent fleet + founder) with the standing quality gates
(3-agent adversarial clean rounds on all money code). The study's "~3–5 months, 2–3 person zk team"
maps to the M0–M3 span; external humans set the M4 tail.

### M0 — Decisions + frozen spec (1–2 weeks, founder-heavy) — START THE CLOCKS
- **Deliverables:** D1 substrate decision (§1.2); collateral set (recommend **AAPL-only** first);
  LTV/term/fee/caps parameter sheet; liquidation-ticket design sign-off (§1.6 — this is the one to
  read twice); statement spec for all four circuits written against the gnark reference;
  **audit firm shortlisted + booked** (lead time 4–8 wks); **MSB/AML + securities counsel engaged**.
- **Acceptance:** spec doc reviewed; audit slot reserved for the M2-freeze date; counsel kickoff done.
- Solo-agent-buildable: the spec, yes. The bookings/engagements: **founder + external humans.**

### M1 — Circuits + differential verification (4–5 weeks)
- **Deliverables:** Borrow / Repay-Release / Liquidate circuits in circom; Poseidon known-answer
  tests across every arity used (circomlib ≡ gnark ≡ on-chain hasher); snarkjs verifiers generated;
  dev-zkey (single-contributor, testnet-only); browser prover benchmarks; the gnark reference
  extended to mirror the v1 statements (repay/liquidate variants of `proveBorrow`) as the fuzz oracle.
- **Acceptance tests:** (1) differential fuzz ≥ 10⁴ vectors per circuit: circom accepts iff the gnark
  reference accepts iff the plain-integer inequality holds — including adversarial edges (wrap
  attempts at 2⁶⁴, price = 0/max, D = C·price·ltv exactly); (2) each verifier ≤ ~300k gas on a local
  EVM; (3) borrow proof generated **in a browser** in < 60s on a mid laptop (kill-criterion
  threshold: > 5 min = rethink D1); (4) soundness negative tests (mutated witness → reject) in CI.
- Critical path. Solo-agent-buildable, with the circuit spec review flagged for the external audit.

### M2 — Contract + testnet integration (5–6 weeks, starts ~week 2 of M1 against the frozen spec)
- **Deliverables:** `EsseyPrivateLending.sol` + forge suite (lifecycle, fuzz, invariants: pool USDG
  balance ≥ 0 under all paths, released collateral ≤ deposited, nullifier uniqueness, no
  value-creation across trees); 3-agent adversarial rounds to a clean round (the standing gate);
  testnet deploy; an E2E prove script in the `ProveShieldedPool.s.sol` / `DonE2E.s.sol` harness
  style covering deposit → borrow → exit-via-relayer → repay → release → withdraw, plus a
  time-warped default → ticket-decrypt → liquidate → surplus-back.
- **Dependency:** the testnet feed keeper must be running (mock feeds go stale in ~25h — the open op
  in memory `testnet-feed-keeper`); the E2E fails honestly without it, which is itself a test of the
  fail-closed borrow path.
- **Acceptance:** full lifecycle proven on RH testnet with tx hashes in a `TESTNET-PRIVATE-E2E`-style
  doc; clean 3-agent round; **code freeze for the audit.**
- Critical path. Solo-agent-buildable.

### M3 — Client SDK, UI, relayer ops (4 weeks, parallel to late M2 — off the critical path)
- **Deliverables:** `poolsdk.ts` extension (borrow/repay/release builders, position-note scanning +
  recovery from `NewCommitment` ciphertexts alone); `/private` page lending panel (reuse the existing
  multi-pool panel — the reuse-existing-UI rule); viewing-key export + audit-export bundle tool;
  relayer: new pool allow-listed, production `MIN_FEE`, `RELAYER_PK` funded, second standby key;
  stealth-exit wiring; honest copy ("confidential, not anonymous; defaults are disclosed;
  amounts hidden in-pool, boundaries public").
- **Acceptance:** a fresh wallet on a clean machine completes the full flow on testnet from the UI;
  wallet wiped → full position + note recovery from chain + keys only; relayer outage degrades to
  self-submitted exit (linkable but never stuck).
- Solo-agent-buildable.

### M4 — Ceremony + formal audit + compliance (6–10 weeks calendar, starts at M2 freeze)
- **Trusted-setup ceremony (external humans, non-negotiable):** snarkjs MPC for all four new zkeys
  (+ regenerating the join-split zkey under the same ceremony while we're at it — it is currently
  single-contributor, `pool/README.md:41-43`). ≥ 8 genuinely independent contributors, public
  transcript, at least one air-gapped contribution, published attestations. Agents cannot be
  contributors — independence is the security property. ~2–4 weeks coordination, ≈ $0–10k.
- **Formal zk audit (external firm, non-negotiable):** circuits + verifier integration + contract
  (the constraint system has never been audited and "a wrong constraint is a silent solvency hole,"
  `SCOPE-solvency-circuit.md:94-97`). Firms of the zkSecurity / Veridise / ABDK / Trail of Bits
  class; ballpark **$60k–$180k**, 3–6 weeks engagement after the 4–8-week booking lead (booked at
  M0). Fix → re-audit deltas → clean.
- **Compliance track (founder + counsel):** MSB/money-transmission analysis of the
  relayer/keeper/gate roles; securities overlay on shielded stock collateral; marketing-copy review;
  ballpark **$20k–60k**. Deliverable: a written go / conditional-go / no-go.
- **Acceptance (the mainnet gate):** ceremony transcript published; audit clean (or all findings
  fixed + re-verified); counsel go; a final 3-agent clean round on the audited code.

### M5 — Mainnet (1–2 weeks, after gates)
- Deploy with production config (real 6-dec USDG, verified feed proxies per `MAINNET-CONFIG.md`,
  multisig roles per `MAINNET-GO-LIVE.md` Phase 4); gate `openMode=false`; seed float small; deposit
  caps on; smoke-test with tiny real value (the Phase-6 discipline); open to the beta cohort in
  waves.

**Parallelization map:** M1‖M2 (2-week stagger), M3‖M2, M4-ceremony‖M4-audit‖M4-counsel. **Critical
path: M0 → M1 → M2 → M4-audit → M5** ≈ 1.5 + 5 + 5 + 8 + 1.5 weeks ≈ **21 weeks ≈ 5 months to
mainnet**, testnet-proven at ~**week 12–14 (~3–3.5 months)** — inside the study's 3–5-month band.

---

## 5. Risk register

| # | Risk | Class | Mitigation | Kill-criterion |
|---|---|---|---|---|
| R1 | **Liquidating hidden positions** — the research remnant dregg does NOT cover (dregg proves transitions a borrower *chooses* to make; it cannot compel an absent borrower) | design/research | calendar-default term loans + verifiable-encryption tickets (§1.6); conservative LTV sized to term-length drawdowns; `maxDrawPerPosition` public cap | if M0 review finds the ticket scheme unsound or counsel finds keeper-decryption unacceptable **and** no variant survives: v1 narrows to USDG-collateral (no price risk) or stops |
| R2 | **Regulatory / chain-operator** — operator-adjacent shielded venue moving tokenized securities; _Storm_ money-transmitting precedent; RH deny-list can block the pool address (feasibility §5.1) | regulatory | compliance-first architecture (§3); counsel from M0; "confidential not anonymous" copy; founder decides on briefing the RH chain team pre-mainnet | counsel no-go, or a credible RH-operator block signal → stop before mainnet (testnet artifact retained) |
| R3 | **Circuit soundness bug** = silent mint or fake-solvent borrow, undetectable by observers because amounts are hidden | engineering (severe) | differential fuzz vs gnark oracle (M1); negative-witness CI; mutation testing; external formal audit (M4); launch deposit caps + small float so worst case is bounded; public float watchable | audit finds a class of soundness issue that survives redesign |
| R4 | **Trusted-setup compromise** — any zkey with a known toxic waste = forgeable proofs | crypto-ops | real MPC ceremony, ≥8 independent contributors, public transcript (M4); PLONK fallback (universal setup) if the ceremony can't be staffed — at proof-size/gas cost | cannot assemble ≥ 5 independent contributors → switch backend or hold mainnet |
| R5 | **Small anonymity set** — curated beta = tens of positions; aggregates + timing cap privacy regardless (feasibility §4.4) | product honesty | don't delay Phase-0 shielded settlement (it grows the organic set, §6); standard denominations; latency windows on exits; copy that never overclaims | none (quality, not safety) — but marketing claims are gated on measured set size |
| R6 | **Browser proving too slow / note-loss** | engineering | benchmark in M1 week 2 (<60s target); recovery-from-chain is a hard M3 acceptance test; ECIES payloads already on-chain per note | >5 min proving → revisit D1 (native/hosted prover with local witness) |
| R7 | **Relayer/keeper liveness** — dead relayer = self-doxxing exits; dead keeper = defaults unresolved | ops | relayer is fallback-degradable (self-submit still works); standby relayer key; keeper under the Phase-3 supervised-cron regime (`MAINNET-GO-LIVE.md` Phase 3); GRACE gives a wide keeper window | — |
| R8 | **Price risk inside the term** (no margin call by design) + 24h-heartbeat/off-hours gaps | economic | LTV vs drawdown table per `LTV-RISK-FRAMEWORK.md`; short max terms; `inSession`-only origination; pool-size cap; fees price the tail | realized bad-debt > fee income in beta → tighten LTV/terms or pause originations (originations are the only thing a guardian may freeze — exits never) |
| R9 | **Issuer actions on collateral** (adminBurn/pause on RH stock tokens) | platform | reuse `EsseyShieldedStock`'s pro-rata haircut reconciliation; disclosed as a trust assumption exactly as the public stack discloses it | — |

**Founder sign-off points:** M0 (parameters, D1, ticket design, engagements), M2-exit (testnet
results review), M4 (counsel outcome + audit report), M5 (go/no-go — the same human gate #81 has).

---

## 6. Interaction with the rest of the roadmap

- **Shielded-settlement launch (feasibility Phase 0): unchanged — do NOT delay it.** It shares rails
  with v1 (stealth, relayer, gate, `/private`), grows the organic anonymity set v1 will inherit
  (R5), and its ops hardening (RELAYER_PK, registration UX) is work v1 needs anyway. v1 is additive:
  a new sibling contract, no migration of any deployed pool.
- **Mainnet Don-stack deploy (#81): the time-sensitive answer is NO — ship it as-is, nothing needs
  to land now.** Definitively:
  1. Private-lending v1 **does not touch DonLoan**. Its collateral is shielded stock notes in its own
     contract; DonLoan lends against the Don floor. Different assets, different contracts, zero
     shared state.
  2. The only hook private-solvency work ever needs from DonLoan **already exists and is deployed
     behavior**: `loanTuple()` emits the canonical dregg tuple in circuit-sized units
     (`DonLoan.sol:64-68,244-265`). That serves the (separate, later) provable-solvency attestation
     of the *public* desk; v1 needs nothing more from it.
  3. The one-shot wiring concern (`Don.setLienManager` is one-shot; a new loan facility forces a new
     Don + full stack) is real but **irrelevant to v1** — v1 never becomes Don's lien manager. If the
     founder ever wants *private borrow-against-Don*, that is a v2+ product which requires a
     generational stack redeploy under the already-established migration pattern (deploy-new +
     redeem-old-at-floor) **no matter what we bake today** — and bolting a speculative hook onto
     audited contracts days before a mainnet deploy would reopen the audit gate for zero v1 benefit.
     Wrong trade; don't do it.
  4. The only #81-adjacent nicety: the treasury/multisig should assume it may later seed the private
     pool's USDG float — that is a plain ERC-20 transfer, needs no contract support, no action now.
- **Mainnet go-live plan:** v1 slots in as its own workstream after the Phase-1/2 gates
  (`MAINNET-GO-LIVE.md`) and reuses Phase 3 (keeper supervision — add the liquidation keeper +
  relayer to the cron/alerting regime), Phase 4 (key management — gate operator + keeper keys join
  the multisig regime; keeper decryption key is a new named key with a documented holder), and
  Phase 5 (the beta curation muscle doubles as the gate cohort).
- **Sequencing risk:** none of M0–M3 competes with #81's remaining founder decisions; the agent
  fleet can start M0/M1 immediately after the founder greenlights this plan.

---

## 7. Team / resourcing reality

**Agent-fleet-buildable (the bulk):** the spec, all four circom circuits + the gnark reference
extensions + differential fuzz rigs, `EsseyPrivateLending.sol` + the forge/invariant suites, the
3-agent adversarial rounds, testnet deploys + E2E harnesses, the SDK/UI/relayer work, the
audit-export tool, and all documentation. This mirrors how the Nova pool and the dregg stack were
actually built in this repo.

**Human, non-negotiable:**
- **Ceremony contributors** (≥ 8 independent parties) — independence is the security property; agents
  under one operator cannot provide it. Founder recruits from: other RH-chain teams, zk community
  ceremony regulars, the beta cohort.
- **External formal zk audit** — an independent firm with circuit expertise; also serves as the human
  zk-expert review of the M1 statement spec. ($60–180k, book at M0.)
- **Counsel** — MSB/AML + securities overlay; written opinion is a mainnet gate. ($20–60k.)
- **Founder** — decisions at M0 (parameters, D1, ticket sign-off), engagement/booking of the three
  external tracks, ceremony recruiting, the M4 counsel/audit review, and the M5 go/no-go.
  Realistic founder load: **~2–4 h/week steady, with three concentrated bumps** (M0 decision week,
  ceremony coordination week, M4 gate review). No founder coding required.

**Recommended-but-optional human:** one zk-fluent engineer/advisor to review the M1 circuit spec
before the fleet builds it — cheap insurance ahead of the audit; the audit catches what this misses.

**Budget line:** external cash **$80k–$250k** total; infra is negligible (a ≥32 GB prover box only if
the gnark IVC attestation path is revived later — the v1 circuits set up and prove on ordinary
hardware).

---

## 8. Summary table

| Milestone | Duration | Depends on | External humans | Gate |
|---|---|---|---|---|
| M0 spec + decisions + bookings | 1–2 wks | founder greenlight | counsel + audit booking | spec frozen |
| M1 circuits + differential fuzz | 4–5 wks | M0 | — | fuzz-clean, browser <60s, gas ≤300k |
| M2 contract + testnet E2E | 5–6 wks (overlaps M1) | M1 statements | — | 3-agent clean + testnet lifecycle proven |
| M3 SDK / UI / relayer | 4 wks (parallel) | M1 artifacts | — | fresh-wallet E2E + recovery |
| M4 ceremony + audit + counsel | 6–10 wks (parallel tracks) | M2 freeze | ceremony ≥8, audit firm, counsel | transcript + clean audit + counsel go |
| M5 mainnet | 1–2 wks | M4 | founder go/no-go | smoke-tested live |

**Testnet-proven ≈ 3–3.5 months. Mainnet ≈ 5 months (range 4–7 depending on audit lead time and
counsel).** The claim this plan cashes out: both hard feasibility questions were already answered
*yes* in this repo — what remains is disciplined engineering, three external human tracks, and one
honest design trade (calendar default with disclosure-on-default) that turns the unsolved part of the
problem into a compliance feature.
