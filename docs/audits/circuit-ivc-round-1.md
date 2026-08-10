# Circuit / IVC stack — adversarial audit round 1

**Target:** `circuit/poseidon/` — the validity-proven rollup (IVC) circuits: Spike-0 recursion,
`TransitionCircuit`/`proveBorrow`, the VK-hash gadget, and the single-VK IVC fold
(`IVCFold`) · **Date:** 2026-07-26 · **Result:** 3 confirmed (all in stepping-stone circuits), **fixed by
retirement**; re-audit **CLEAN.**

Three independent auditors (soundness; test-integrity & claims; correctness & hygiene). Findings below
are the calibrated result, not the reporters' first pass.

---

## The finding that matters most

> The final circuit was sound; the *scaffolding that led to it* was not. An IVC fold that binds only
> its immediate inner proof's verifying key — without propagating that binding down the chain — lets one
> honest outer layer wrap an arbitrarily bogus inner chain.

Two of the three findings are the same class of hole (an unbound / non-propagated verifying key), and
both live in circuits that `IVCFold` was built to replace. `IVCFold` already carried the correct
pattern (in-circuit base case + VK-hash binding + VKCommit propagation), which the audit confirmed
sound. The response was to **delete the scaffolding**, not patch it.

---

## Fixed (full detail — resolved by retiring the circuits)

### HIGH — `AccStepCircuit`: VK binding did not propagate down the chain

The adapter fold bound only the *immediate* inner proof's key (`hash(PrevVK) == VKCommit`) but never
constrained the inner proof's own `VKCommit` public input. Each inner accumulator proof's `VKCommit`
was therefore a free witness from its parent's perspective. Exploit: the verifier pins only the
outermost `VKCommit`; inside, a prover sets the inner proof's `VKCommit = hash(BOGUS_VK)` and folds a
`BOGUS_VK` proof of an insolvent `genesis → bad_current` transition with no solvency constraint. One
honest outer layer wraps an arbitrarily bogus inner chain and passes — defeating the solvency
guarantee. **Resolved:** `accumulator.go` deleted. The sound form is `IVCFold`'s cross-step propagation
`prevVKCommit == VKCommit` (ivc_basecase.go), which the audit confirmed present and correct.

### HIGH — `BlockCircuit`: shared transition VK was an unbound witness with no public outputs

The block prover took the transition verifying key as a plain witness, never bound to any commitment,
and exposed no public fields (not even the boundary roots). Exploit: a prover supplies `VK' =` the key
of a permissive same-shape circuit with no solvency check, generates proofs for an arbitrary chain, and
all recursive checks pass — the block proof attests nothing about solvency, and no consumer can even
read the boundary roots to detect it. **Resolved:** `block.go` deleted. `IVCFold` binds its `PrevVK` to
the public `VKCommit`.

### MED — recursion verify without complete arithmetic / subgroup checks

`AccStepCircuit` and `BlockCircuit` verified untrusted prover-supplied proofs using gnark's *incomplete*
emulated point arithmetic (no `WithCompleteArithmetic()`), which mishandles coincident / infinity
points; no `WithSubgroupCheck()` either. No concrete false-accept witness was produced (hence MED), but
the code verified adversarial inputs on the unsafe path. **Resolved:** moot after deletion; the sole
remaining verifier, `IVCFold`, uses `WithCompleteArithmetic()` (required — the genesis dummy proof
drives the MSM into exactly these edge cases).

---

## Confirmed sound (no defect) — `IVCFold` and the kept primitives

Re-verified across all three auditors on the trimmed tree:

- **`IVCFold` base case** — `IsBase` constrained boolean; the VK-binding, genesis-carry, and VKCommit
  propagation checks are vacuous only at genesis and enforced otherwise; `oldRoot = Select(IsBase,
  GenesisRoot, prevCurrent)` forces a genesis start when `IsBase=1`, so a mid-chain base flag cannot
  launder a deep state. Soundness rests on the verifier pinning `VKCommit == hash(vk)` and the genesis
  root.
- **VK-hash gadget** (`vkhash.go`) — collects every EC-point coordinate (E ∈ GT, `K[]`,
  GammaNeg/DeltaNeg, pedersen keys); the only unhashed field is the compile-time-constant
  `PublicAndCommitmentCommitted`, not prover-controllable. In-circuit and native walks are identical, so
  the two hashes match by construction.
- **Merkle update / `proveBorrow`** — `pathBits` boolean; old and new roots share the same siblings, so
  only the target leaf can change; `amount` range-bound.
- **Solvency** (`solvency.go`) — 64/64/96/16-bit range bounds keep both sides of the inequality far
  below the field modulus, so no wrap can hide an overflow.
- **Emulated→native root bridge** — `FromBinary(ToBitsCanonical(...))` is canonical (`< r`), no
  aliasing, exact since the emulated modulus equals the native field.

Test integrity: every negative test fails at its *intended* constraint (verified with stack traces);
`test.IsSolved` results are never presented as full end-to-end proofs; headline constraint counts match
compiled reality.

---

## What was NOT covered

- The heavy full-prove tests (`TestIVC_SingleVK_BaseCase`, `TestSpike0_ProveVerify`) were not re-run
  during the audit (RAM-bound on the 16 GB dev box); their recursion mechanism is exercised by the
  `IsSolved` tests that were run, and their circuit shapes/sizes match the record.
- This is a **research build**: not deployed, and the remaining protocol surface (settlement contract,
  sequencer, DA, the non-borrow transition actions) does not exist yet and was out of scope.
