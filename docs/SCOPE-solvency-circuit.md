# Scope — a minimal solvency circuit

What it would take to turn the disabled proof gate into a live one: a real zk circuit whose proof
`dregg_lending::borrow` will accept. Grounded in the deployed interfaces, not aspiration.

## What already exists (don't rebuild)

- **On-chain verifier** — `dregg_verifier::verifier::verify(vk, public_inputs, proof)` wraps
  `sui::groth16` on BN254. Generic: it checks *a* proof against *a* vk + public inputs; it knows
  nothing about solvency. Deployed and live.
- **The commitment** — `dregg_lending::lending::loan_commit_of<Collateral>` computes
  `sui::poseidon::poseidon_bn254([ph, pl, bh, bl, debt, collateral, ltv_bps, nonce, th, tl])`:
  pool-id (2 limbs), borrower (2 limbs), debt, collateral **units**, ltv_bps, nonce, and the
  collateral **type** blake2b-hashed to 2 limbs. `borrow()` asserts
  `payment_id == bcs::to_bytes(loan_commit_of(...))`, then `verify(vk, payment_id, proof)`, then
  marks `payment_id` single-use. So the public input the proof must bind is fixed and already
  enforced on-chain.
- **A Poseidon gadget in gnark** — `circuit/poseidon/poseidon_gadget.go`: `PoseidonBn254(api, inputs)`
  on `gnark v0.11.0`, with a test that matches iden3's reference. The hard primitive is done and the
  framework is chosen.

So the missing piece is **the circuit that sits around that Poseidon** and a proof pipeline — not a
from-scratch cryptosystem.

## The finding that defines the work: price is not committed

`loan_commit_of` binds debt, collateral units, LTV, and type — but **not price**. There is no
`price`/`oracle`/`pyth` reference anywhere in `lending.move`. A solvency statement is
`debt ≤ collateral × price × LTV`; you cannot prove it against a commitment that never mentions
price.

This is the real substance. Two consequences:

1. **The commitment schema must change** — add `price` (and its scale/decimals) to
   `loan_commit_of`, taking Poseidon from 10 inputs to 11 (t=12, still within the gadget's
   supported arity). This touches the pinned commitment format, so it must be coordinated with the
   async path and any proof fixtures.
2. **A proof over a price is only as honest as the price.** A prover can input a fake high price and
   prove a fake-solvent loan. The proof gate's own comment already teaches this lesson for amounts
   (audit F1: "the proof gate alone proves NOTHING about the loan"). Price needs the same on-chain
   binding: `borrow()` must read a fresh oracle (Pyth) and assert the committed price equals it
   within the conservative band — **or** the circuit must verify an oracle signature over the price
   (a signature-in-circuit, much heavier). Recommend the on-chain check; keep the circuit to
   arithmetic.

**Be clear-eyed:** for a *single* loan, a solvency proof buys little over a native on-chain
`assert(debt ≤ collateral × price × ltv)`, which Move can do cheaply. The zk payoff is the **batch**
path — proving N loans solvent against one committed post-state (`batch_accumulator`,
`settle_batch`, dregg's `final_root`). The minimal single-loan circuit is the foundation and the
learning step, not itself a win over today's LTV check.

## The minimal circuit (gnark, BN254)

**Public input (1 field element):** `commit` — must equal on-chain `loan_commit_of`.

**Private witnesses:** the 11 preimage fields (pool_hi/lo, borrower_hi/lo, debt, collateral,
ltv_bps, nonce, type_hi/lo, price).

**Constraints:**
1. `commit == PoseidonBn254([... , price])` — reuse the existing gadget.
2. Solvency: `debt × SCALE ≤ collateral × price × ltv_bps`. Inequality in a prime field is the one
   real gotcha — you cannot compare field elements directly; you bit-decompose and use a comparator
   (`gnark` `cmp` / `AssertIsLessOrEqual`) with explicit bit-widths so nothing wraps. With u64
   debt/collateral and ~64-bit price, the product is ~142 bits « the 254-bit field, so it is safe
   once the range checks are in place.
3. Range-check every multiplicand to its declared width.

Total: low thousands of constraints (Poseidon dominates). Proving is milliseconds; this is not a
performance problem, it is an integration-correctness problem.

## Phased plan

**Phase 1 — Circuit + local proof (no chain).** Write `SolvencyCircuit`, reuse `PoseidonBn254`,
`groth16.Setup` → pk/vk, prove+verify in a Go test. Days. Risk: the comparator/range logic.

**Phase 2 — On-chain equivalence (the hard part).**
- Prove `sui::poseidon::poseidon_bn254` and gnark `PoseidonBn254` produce the **identical** digest
  for the exact input vector. Highest-risk item — test exhaustively, never assume.
- Serialize gnark's vk into the encoding `sui::groth16::prepare_verifying_key` expects; serialize the
  public input so `bcs::to_bytes(commit)` matches `public_proof_inputs_from_bytes`. Cross-stack byte
  matching; budget debugging time.
- Amend `loan_commit_of` to include price.
- Green test: `verifier::assert_verify(vk, payment_id, proof)` passes on localnet with a
  gnark-produced proof. ~1–2 weeks.

**Phase 3 — Prover in the operator + enable the gate.** Operator produces `(proof, public_inputs)`
from loan terms + oracle price; pin `vk` at `create_pool`; add the on-chain price↔oracle assert in
`borrow()`. `borrow()` already checks commitment + verifies, so origination lights up once a valid
proof exists. ~1 week.

**Phase 4 — Batch (the real payoff).** Generalize to N loans over one committed post-state
(`settle_batch`/`final_root`). Separate, larger project — this is where zk beats an on-chain loop.

**Phase 5 — Audit the constraint system.** Never audited; a wrong constraint is a silent solvency
hole. Independent review + differential fuzzing: for random inputs, circuit-accepts iff the real
inequality holds.

## Risks / decisions to make first

1. **Oracle binding is the substance.** Decide on-chain price check vs signature-in-circuit before
   writing constraints. Everything downstream depends on it.
2. **Single-loan zk is near-redundant with an on-chain check.** Commit to the batch path as the
   actual goal, or accept the circuit is a stepping stone.
3. **Poseidon param match** (Sui native vs gnark) is the top integration risk.
4. **Trusted setup.** Groth16 needs a per-circuit ceremony; a bad/backdoored setup = forgeable
   proofs. Consider gnark's PLONK backend (universal setup, no per-circuit ceremony) at a
   proof-size/cost tradeoff.
5. **Schema change** to `loan_commit_of` ripples to the async path and every fixture.

## Rough effort

A minimal circuit that verifies on-chain and lets `borrow` originate: **~2–4 weeks** of focused
work for someone fluent in gnark, Phase 2 carrying the risk. The batch path and the audit are
larger and separate. None of it is blocked on new cryptography — it is integration, encoding
discipline, and the oracle-binding decision.
