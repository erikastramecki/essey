# SCOPE — Provably-Solvent Lending (validity-proven rollup)

Status: **IVC core complete (research-validated).** Spike 0 → Rung 1 → Rung 3d (`IVCFold`) all built
and validated; true single-VK IVC proven end-to-end. This doc is the scope + running log for the
hardest, most-differentiating piece: a lending protocol whose every state transition is proven valid
in ZK, folded into one proof that verifies on any chain.

## Why this, and why hardest-first

The "lend on any chain, no oracle" framing is weak on its own — Pyth is a pull oracle,
so cross-chain price access is already cheap and permissionless. The defensible moat is
not *how we get the price* but *what we can prove about the whole protocol*:

> The first lending protocol where "this can never become insolvent through a bug" is a
> mathematical guarantee, proven per-block, not an audit claim.

We attack the **crux** first — the one load-bearing unknown whose failure collapses the
thesis — with the smallest experiment that returns a hard go/no-go. Not the whole system.

## The crux

Everything rests on one question:

> Can we fold N proven, solvency-checked state-transitions into ONE proof that stays
> cheaply verifiable on any EVM chain?

Sharp edge: our whole stack is **BN254** (the EVM pairing precompile + our exported
verifier). The efficient recursion 2-chain is BLS12-377 → BW6-761, but a BW6-761 verifier
is *not* cheap on EVM. So the property we need — an aggregate that lands on-chain at ~our
current gas — requires the **BN254-in-BN254 emulated** path to be economical. That is the
unknown Spike 0 measures.

## Spike 0 — go/no-go (code: `circuit/poseidon/spike0_recursion_test.go`)

- **0a `TestSpike0_Constraints`** — compile-only. Outer aggregation-circuit constraints at
  K=1,2,4,8 → constraints/proof and the fixed recursion overhead. The decisive economics number.
- **0b `TestSpike0_ProveVerify`** — full setup+prove+verify of the aggregate at K=1,2. Confirms
  it proves, times it, captures heap, confirms the aggregate is a standard BN254 Groth16 proof.

A small inner circuit is used on purpose: recursion overhead is ~independent of inner-circuit
size, so this isolates the per-proof aggregation cost (what decides viability) from the app
circuit we already measured (2.4M constraints, ~13s, ~338k gas).

### Kill criteria (decide fast)

| Signal | Meaning |
|---|---|
| Final on-chain verify not ~constant / not ~our gas class | **FAIL** — "any chain" property gone |
| Marginal prove cost of aggregation ≥ proving one bigger flat batch | **FAIL** — recursion buys nothing; use bounded batch |
| Outer RAM blows past one machine at K=8 | **AMBER** — feasible but needs infra; cost it before committing |

### Results — 0a (constraints) — DONE

Inner circuit: 3 constraints (trivial, as intended — isolates recursion overhead).

| K | outer constraints | per-proof | compile |
|---|---|---|---|
| 1 | 1,646,113 | 1,646,113 | 4.5s |
| 2 | 3,225,945 | 1,612,972 | 12.2s |
| 4 | 6,385,608 | 1,596,402 | 37.9s |
| 8 | 12,704,934 | 1,588,116 | 1m42s |

- Emulated BN254-in-BN254 recursion **works and compiles on our exact stack (gnark v0.11.0)**.
- Verifying one BN254 Groth16 proof in-circuit ≈ **1.6M constraints**, and cost is **flat & linear**
  in K (no superlinear blowup, ~1.59M/proof even at K=8). Predictable to scale.
- ~1.6M constraints/proof looks like ~2× the marginal cost of adding a loan to our existing flat
  `BatchCircuit` (~873k/loan) — **but that comparison mixes units.** 873k buys one more *loan*; 1.6M
  buys in-circuit verification of an entire *prior proof*, which can itself attest thousands of loans
  (a whole block). They only compete in the degenerate one-loan-per-proof case (kill-criterion #2),
  which nobody should build.

**Key inference:** use each tool for what it's cheap at.
- **Flat-batch within a block** — ~873k/loan, one shared Pyth quorum verify. Cheap throughput.
- **Recurse across blocks (IVC)** — fold a whole block's proof onto the running proof for a fixed
  ~1.6M *regardless of how many loans the block holds*. This yields a constant-size proof of *all
  history* — which a flat batch fundamentally cannot do (it would need every historical transition in
  one unbounded circuit). Per-loan, the 1.6M amortizes to near-zero as block size grows.

This is the standard rollup shape, and 0a says it is economical on our stack.

### Results — 0b (prove/verify) — K=1 DONE

| K | compile | setup | prove | verify | peak heap |
|---|---|---|---|---|---|
| 1 | 4.0s | 3m16s | **8.56s** | OK | 2.9 GB |
| 2 | 8.4s | — (reaped) | ~17s (proj.) | — | ~6 GB (est.) |

K=2 **setup** (3,225,945 constraints — measured exactly in 0a, not projected) peaks past the ~3.9 GB
free on this 16 GB laptop and was reaped twice. Setup is a one-time, offline, per-circuit operation, so
this is a prover-box sizing note (want ≥32 GB for circuits ≥3M constraints), not a per-proof cost.
Per-proof *proving* is the cheap part (8.56s at K=1; ~17s projected at K=2 from linear scaling).

- **The emulated recursion proves and verifies end-to-end** — not just compiles. K=1 prove is 8.6s,
  peak heap ~2.9 GB, lighter than our existing 2.4M-constraint portable proof (~13s, ~2.7 GB).
- The aggregate is a **standard BN254 Groth16 proof**. With few/no public inputs it lands at the
  cheapest end of our verifier's gas (~200–220k, vs our measured 217k commitment-free) → **kill-criterion
  #1 cleared**: on-chain verify is constant and in our gas class.
- Infra note (kill-criterion #3): K=2 setup (~3.2M constraints) hit memory pressure on this 16 GB
  laptop and was reaped. **Not a wall** — the real IVC fold step *is* K=2 (accumulator + one new block),
  ~6 GB, comfortable on any 32 GB prover box. You never put K=8 in one circuit for IVC; you chain K=2
  folds. So block-size is not RAM-bounded — only the per-step fold is, and it's small.

### Verdict — **GO, architecture corrected**

The crux is cleared: BN254-in-BN254 recursion is real, economical, and EVM-verifiable on our exact
stack. The naive "aggregate single-loan proofs" design would have lost to a flat batch — but the correct
design does not do that:

- **Within a block:** flat `BatchCircuit`, ~873k/loan, one shared Pyth quorum verify.
- **Across blocks:** an IVC fold (K=2, ~3.2M constraints, ~6 GB, prove ~17s projected) that carries a
  constant-size proof of *all history forward* — the thing a flat batch can never do.

No kill-criterion is tripped. Fallback to bounded-batch is **not** needed. Proceed to rung 1
(state-transition circuit).

**One number deferred to rung 1 (on purpose):** exact on-chain gas of the aggregate. The K=1 toy
aggregate has 0 public inputs, so it's structurally the cheapest Groth16 verify (3 fixed pairings,
~200k, ≤ our measured 217k). The *production* aggregate's gas depends on how many public field elements
the real transition circuit exposes (new state root + accumulator ≈ a few inputs, ~+a few k gas each).
That number only becomes real once rung 1 exists, so we measure it there rather than gas-testing a
0-input toy here.

## Rung 1 — state-transition circuit — DONE (borrow)

Code: `circuit/poseidon/transition.go`, `transition_test.go`. Proves

    old_root --(borrow Amount against one position)--> new_root

- **State tree:** Poseidon (Sui-compatible `sui::poseidon_bn254`), depth 20 (1M position slots). Leaf =
  Poseidon(10 position fields, `loan_commit_of` order); node = Poseidon(2). So the state root and every
  Merkle proof verify natively on Sui at settlement.
- **What it proves:** (1) pre-image position included in `old_root`; (2) `new_debt = old_debt + Amount`,
  range-bound; (3) resulting position solvent at the public price via the *shared* `enforceSolvent`
  (refactored out of `enforceLoan` — one encoding of the dregg rule, no duplication); (4) replacing only
  that leaf along the same path yields `new_root`.
- **Public inputs:** `old_root`, `new_root`, `price` (3). Everything else private.

### Results

| Metric | Value |
|---|---|
| Constraints (depth 20) | **12,454** |
| Prove | **74 ms** |
| Verify | OK |
| Valid solvent borrow | solves ✅ |
| Insolvent borrow (1700 > 1665 max) | rejected ✅ |
| Tampered `new_root` | rejected ✅ |

A transition is **~0.5% of one recursion fold (1.6M)** and ~0.5% of the portable proof (2.4M). A block
of hundreds of transitions is still cheap to prove flat, then folded once via the Spike-0 IVC step. The
solvency invariant is enforced on the *resulting* state, and the Merkle-update binding stops any change
to other positions — the two properties that make "provably solvent per block" real.

Existing `SolvencyCircuit`/portable tests still pass after the `enforceSolvent` refactor (no regression).

### Rung 1 — remaining

- Other actions: `repay` (debt−), `accrue` (debt× / interest), `liquidate` (debt & collateral both
  change, seize path). Same pattern; each is a small addition.
- Export the transition verifier and measure **real on-chain gas** (closes the number deferred from
  Spike 0 — now meaningful because the circuit exposes real public state: old_root, new_root, price).

## ⚠️ Note on retired scaffolding (post-audit)

Rungs 2, 3, 3b, and 3c below were built on two **stepping-stone circuits** — `BlockCircuit` (Rung 2) and
`AccStepCircuit` (Rungs 3/3b/3c) — that got us to the sound culmination, **`IVCFold` (Rung 3d)**. A
3-agent adversarial audit (2026-07) found real soundness gaps in the stepping stones when viewed as
production circuits: `AccStepCircuit`'s VK binding did **not propagate** down the chain (a wrapping/
laundering hole) and `BlockCircuit`'s shared VK was an **unbound witness** with no public outputs. Both
are exactly the holes `IVCFold` closes (in-circuit base case + VK-hash binding + VKCommit propagation),
which the audit confirmed sound. So `block.go` and `accumulator.go` (and their tests) were **retired**;
the reusable primitives they exercised — `proveBorrow` (transition.go), the VK-hash gadget (vkhash.go),
the emulated→native bridge, and the recursion type aliases — live on in the kept files and in `IVCFold`.

The sections below are preserved as the **development record** (the measurements were real when taken);
the code they describe is gone, superseded by Rung 3d. See `docs/audits/` for the audit round.

## Rung 2 — IVC block prover — DONE (correctness) — *[retired: superseded by IVCFold]*

Code: ~~`circuit/poseidon/block.go`, `block_test.go`~~ (retired). `BlockCircuit` recursively verified K
**real** rung-1 transition proofs against one shared transition VK, and enforced they chain:

    root_0 --tx_0--> root_1 --tx_1--> ... --tx_{K-1}--> root_K   (new_root(tx_i) == old_root(tx_{i+1}))

- Recursion: the Spike-0 BN254-in-BN254 emulated path, so the block proof stays a BN254 Groth16 proof.
- Chaining: emulated-field `AssertIsEqual` on the transition proofs' public inputs
  (`[old_root, new_root, price]`).

### Results

| Metric | Value |
|---|---|
| Constraints (K=2) | 3,410,607 |
| Valid chained block (2 real tx proofs) | **solves** ✅ (3.94s via `test.IsSolved`) |
| Non-chaining block (both tx valid, roots don't meet) | **rejected** ✅ |

Validation is via `test.IsSolved` — it runs the constraint solver over the full 3.4M-constraint circuit
with **two real in-circuit pairing verifications**, so it genuinely proves the composition logic
(real proofs accepted, chaining enforced, broken chain rejected) without the memory-hungry trusted setup.

**Deferred (RAM ceiling, not a logic gap):** the full Groth16 setup+prove of `BlockCircuit` (3.4M
constraints) is the same operation Spike 0 characterized — setup needs more headroom than this loaded
16 GB laptop has free (reaped twice). Spike 0's K=1 aggregate *did* prove (8.56s), so the mechanism is
confirmed; the K=2 block prove wants a ≥32 GB box for the one-time setup. Per-proof *proving* is cheap.

### The whole thesis now composes end-to-end

1. **Rung 1** — a transition is a real BN254 Groth16 proof (12.5k constraints, 74ms): inclusion +
   solvency-preserving update + Merkle binding.
2. **Rung 2** — those real proofs verify *in-circuit* and their state roots chain (proven above).
3. **Spike 0** — the aggregate is itself a BN254 proof, EVM-verifiable at ~our gas class, and the fold
   economics are flat/linear.

That is a working, validated path from one proven transition to "a single proof that every block chained
validly and stayed solvent." What remains is engineering, not open feasibility questions.

## Rung 3 — IVC accumulator fold step — DONE (one layer) — [retired: superseded by IVCFold]

Code: `circuit/poseidon/accumulator.go`, `accumulator_test.go`. Two circuits:

- **`AccBaseCircuit`** — the genesis seed: an empty history where `current == genesis`. Public
  `[genesis, current]`.
- **`AccStepCircuit`** — the fold step: verifies one incoming accumulator proof (attesting
  `genesis -> prev_current`), bridges its **emulated** root public-inputs to **native** variables via
  `api.FromBinary(field.ToBitsCanonical(...))` (canonical ⇒ `< modulus`, value preserved since the
  emulated modulus *is* the native field), carries `genesis` forward, and extends history by ONE native
  borrow transition `prev_current -> current` (reusing the rung-1 `proveBorrow`). Result: a new
  accumulator proof attesting `genesis -> current`, the **same size** as the one it consumed.

Design choice that makes it fit a modest box: the transition is done **natively** (~12.5k constraints),
so the step verifies only ONE proof (~1.6M) instead of two — the same size as Spike-0 K=1, which proved
here.

### Results

| Metric | Value |
|---|---|
| Constraints | 1,678,683 |
| Fold verifies a real base proof + extends state | **solves** ✅ (2.0s via `test.IsSolved`) |
| Tampered `current` root | **rejected** ✅ |
| Mismatched `genesis` carry | **rejected** ✅ |
| Full Groth16 prove + external verify (one layer) | **proved 8.61s** ✅ (setup 3m18s) |

The emulated→native root bridge — the one genuinely new/risky primitive — works. A fold proof recursively
verifies the prior accumulator and extends the state, and its size is independent of history length: the
constant-size-history property, demonstrated for real.

## Rung 3b — single-VK via adapter — DONE (proven) — [retired: superseded by IVCFold]

Code: `circuit/poseidon/ivc_shape_test.go` (shape analysis, compile-only), `ivc_singlevk_test.go`
(bootstrap, needs RAM). The question: is there ONE verifying key that folds against itself for unbounded
history?

**Answer — structurally, yes.** Compiling the fold at successive sizings reveals the fixed point:

| circuit | nbPublic | nbCommit | pubCommitted | constraints |
|---|---|---|---|---|
| `AccBaseCircuit` (seed) | 3 | 0 | `[]` | 1 |
| `A` = fold sized-for-seed | 3 | 1 | `[[]]` | 1,678,683 |
| `B` = fold sized-for-A | 3 | 1 | `[[]]` | 2,692,468 |
| fold sized-for-B | 3 | 1 | `[[]]` | (same as B) |

The recursion verifier introduces exactly **one commitment over internal wires** (`pubCommitted=[[]]`).
Every fold that verifies a 1-commitment proof has the **same verification-relevant shape as its own
output** — so **B verifies both an A-proof and a B-proof.** `A` (1.68M) is a one-time bootstrap adapter
off the 0-commitment seed; `B` (2.69M) is the self-referential steady state:

    seed --A--> L1 --B--> L2 --B--> L3      L1,L2,L3 all verified by vk_B's chain; L2->L3 is B verifying a B-proof

No base-case selector needed — the seed is just a smaller distinct adapter. The `nbCommit`/`pubCommitted`
structure is uniform; the differing private-wire *count* (1.29M vs 2.07M) is a prover-side detail the
verifier never sees.

**Proven end-to-end** (`TestIVC_SingleVK`, 549s on the 16 GB laptop once ~6 GB was free and `aCCS` was
released before B's setup):

| step | what happened | roots |
|---|---|---|
| seed | genesis = current | root0 |
| A setup 3m09s → L1 | **A verified the seed** | root0 → root1 |
| B setup 5m11s → L2 | **B verified an A-proof** | root1 → root2 |
| → L3 | **B verified a B-proof — self-reference** | root2 → root3 |
| verify | final proof accepted under **`vk_B`** | attests root0 → root3 |

One verifying key (`vk_B`) folded against itself: L2 and L3 are both B-proofs, and L3 is B recursively
verifying the B-proof L2. The final constant-size proof attests the full 3-step history back to genesis,
and `vk_B` verifies any depth. That is unbounded single-VK IVC, demonstrated — not argued.

## Rung 3c — VK-hash binding — gadget DONE (kept in vkhash.go); wiring retired with AccStepCircuit

Code: `circuit/poseidon/vkhash.go`, `vkhash_test.go`. The fold verified `PrevVK` as an unbound witness,
so a prover could substitute a verifying key. The binding hashes the VK in-circuit and pins it.

- **`hashVKInCircuit` / `hashVKNative`** — walk the `stdgroth16.VerifyingKey` by reflection, collect
  every emulated-`Element` limb (E ∈ GT = 48, the two G2 points = 32, the G1 `K[]` array, plus commitment
  keys), skip the derived pairing-line cache, and absorb with a rate-15 Poseidon sponge. In-circuit and
  off-circuit walk the identical struct in identical order, so the hashes match by construction.
- **Validated in isolation** (`TestVKHash_*`, <0.1s): 104 limbs for a small VK, **in-circuit hash ==
  native hash**, wrong pin rejected, and **distinct VKs → distinct hashes**.
- **Wired into `AccStepCircuit`**: a public `VKCommit` with `AssertIsEqual(hashVKInCircuit(PrevVK),
  VKCommit)`. Validated in the recursion (`TestAcc_Step*`): the bound fold **solves**, and a **tampered
  `VKCommit` is rejected**. The self-referential fixed point is **preserved** (F0 ≡ F1 at `nbPub=4,
  nbCommit=1, pubCommitted=[[]]`), so single-VK folding still holds with the binding on; the extra VK
  hash adds only ~4k/~24k constraints.

**Honest boundary:** this is the *local* binding — each fold publicly commits to the VK it used, so the
top-level verifier can pin the final `VKCommit` to `hash(vk_B)`. Making it airtight for *deep* chains
needs (a) **cross-step propagation** (each fold also checks the incoming proof's `VKCommit`), which is a
2-line addition, and (b) an **adapter-free base case** so the whole chain pins one VK (the current
adapter seam A→B legitimately uses two keys). Both are the same base-case-selector work; feasibility
isn't in question. The full *bound* self-referential prove (`TestIVC_SingleVK`, now ~2.72M for B) is
ready to run on a box with ~6–8 GB free.

## Rung 3d — base-case selector → TRUE single-VK IVC — DONE (validated)

Code: `circuit/poseidon/ivc_basecase.go`, `ivc_basecase_test.go`. `IVCFold` supersedes the adapter: one
circuit, one verifying key, genesis handled in-circuit — no bootstrap adapter, and full VK propagation.

- **`IsBase` selector.** Every proof does exactly one borrow transition. `IsBase=1` (genesis): the
  recursive slot holds a **constant dummy proof** (verified so the pairing check passes, content gated
  out); `prev_current` is forced to `GenesisRoot`, and the VK-binding / genesis-carry / VKCommit-
  propagation checks are made vacuous via `api.Select`. `IsBase=0` (step): the real prior `IVCFold` proof
  is verified, `hash(PrevVK)==VKCommit` is enforced, and VKCommit propagates unchanged.
- **The dummy** (`ivcDummyCircuit`) is built to match a fold proof's exact shape `(nbPub=4, nbCommit=1,
  pubCommitted=[[]])` — 3 public slots + one internal commitment — so the genesis fold can verify it.
  Confirmed by `TestDummy_ShapeMatchesFold`.
- **Self-referential:** `IVCFold`'s own proof has that same shape, so **one VK verifies the dummy, the
  genesis output, and every step** (2,837,387 constraints). No adapter, no per-layer keys.
- **`WithCompleteArithmetic()`** on `AssertProof` — required because the dummy drives the verifier MSM
  into edge cases the fast unsafe path can't handle.

### Results (validated via `test.IsSolved` + shape analysis)

| check | result |
|---|---|
| Genesis fold (verify dummy, first transition, gated checks) | **solves** ✅ (3.2s) |
| Genesis with an inconsistent transition | **rejected** ✅ |
| `IsBase=0` fed the dummy (step demands binding) | **rejected** ✅ |
| IVCFold self-referential (own shape ≡ inner shape) | **confirmed** ✅ |
| Full end-to-end prove (genesis → step → step, one VK) | **PROVED** ✅ (380s: 1 setup 5m30s + 3 folds) |

**Proven end-to-end** (`TestIVC_SingleVK_BaseCase`, 380s, one 2.84M setup):

| step | what happened | roots |
|---|---|---|
| setup | one circuit, one key (2,837,387 constraints, 5m30s) | — |
| genesis (IsBase=1) | dummy verified, first transition | root0 → root1 |
| step1 (IsBase=0) | verified the genesis proof under **vk** | root1 → root2 |
| step2 (IsBase=0) | verified step1 under the **same vk** — self-reference | root2 → root3 |
| verify | final proof accepted under the single **vk** | attests root0 → root3 |

One verifying key, no adapter, genesis in-circuit, VK binding active — the definitive single-VK IVC.

**Soundness of the base case:** `IsBase=1` forces the state to a fresh one-transition-from-genesis
history and gates the binding, so it can only *start* a chain — it cannot launder a deep bad state (that
would require a real prior proof under the pinned VK, which the step binding enforces). The verifier pins
the final `VKCommit` to `hash(vk)` and checks `genesis` is the canonical genesis root.

This closes the last genuinely-hard IVC piece: true single-VK IVC with an in-circuit base case and
VK-hash binding, all validated. What remains is ordinary engineering.

## Remaining (engineering, not feasibility)

- Expose `root_0`/`root_K` / per-step price as native public inputs where a settlement contract needs
  them directly (bridge primitive now in hand).
- Other transition actions: repay, accrue, liquidate.
- Full `IVCFold` prove (`TestIVC_SingleVK_BaseCase`) on a ≥32 GB box for comfortable margin → measure
  wall-clock at depth + on-chain gas of the verifier.
- Settlement contract, sequencer, DA, escape hatch.

## If Spike 0 passes — the build ladder

1. **State-transition circuit** — extend `SolvencyCircuit`/`BatchCircuit` to prove
   `old_root → new_root` under one action (borrow/repay/liquidate/accrue) with the solvency
   invariant enforced on the resulting state. dregg's proven rule becomes a per-transition constraint.
2. **IVC block prover** — prove block N valid *given a proof of block N−1*, folding history via
   the Spike-0 recursion.
3. **Settlement contract + escape hatch + minimal sequencer** — known-hard engineering, deferred
   until the ZK core is proven.
4. **End-to-end proven-solvent mini-rollup demo** — same "every number real, reproducible"
   discipline as the portable-proof demo.

## Fallback ladder (chosen by what Spike 0 shows)

- Recursion works but is expensive → **bounded-batch proven solvency** (capped block size, no IVC).
  We are ~70% there: `BatchCircuit` already does one-quorum-many-loans. Still a genuine
  "provably solvent per batch" differentiator, just with a size ceiling.
- Recursion is a dead end → fall back to the **non-rollup primitives** (multi-oracle proven
  pricing + private health proofs), which stand on their own and need none of this.

## What we reuse (don't rebuild)

`circuit/poseidon/{solvency,solvency_attested,portableproof}.go`, the prover
(`prover/prover.go`), Pyth-in-circuit (`circuit/pyth/*`), the exported on-chain verifier, and
dregg's Lean-verified solvency rule.
