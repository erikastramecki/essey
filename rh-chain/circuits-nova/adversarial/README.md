# Shielded-pool circuit — adversarial witness suite

Durable soundness harness for `Transaction(20,2,2)` (`../transaction2.circom`), a
Tornado-Nova / Privacy-Pools fork. Owned by the `essey-zk-auditor` agent. It does
**not** touch the production circuit or ceremony — it recompiles the circuit into
`build/` and runs a fresh local groth16 setup for testing only.

## Threat model

A malicious prover with unlimited compute who controls every private input. For
each attack the suite crafts the witness the attacker *wants* and confirms the
circuit refuses to prove it. **A malicious witness that produces a verifying
proof is a CRITICAL finding.** A passing end-to-end proof of an honest tx does
*not* mean the circuit is sound; only the rejection of every crafted fraud does.

## Run

```bash
./setup.sh        # one-time: compile + local groth16 setup (artifacts are gitignored)
node run.js       # exit 0 = all rejected; 1 = CRITICAL; 2 = canary failed
```

## What it checks

Two rejection mechanisms:

- **witness-reject** — the wasm witness calculator evaluates every constraint, so
  a violated `===` throws. A throw means the R1CS is unsatisfiable for that
  assignment, i.e. no honest proof can exist. If a fraudulent witness instead
  generates, the suite goes on to actually `groth16 prove` + `verify` it.
- **pubsig-binding** — from a valid proof, each public signal is mutated and the
  proof re-verified; it must fail, proving the signal is bound into the statement.

Attacks (all must be rejected):

| id  | attack                                             | constraint that must catch it |
|-----|----------------------------------------------------|-------------------------------|
| a   | value creation (Σout > Σin + publicAmount)         | `sumIns + publicAmount === sumOuts` |
| a'  | value creation on the real-spend path              | same |
| b   | intra-tx duplicate nullifier (same note twice)     | `sameNullifiers === 0` |
| c   | forged Merkle root                                 | `ForceEqualIfEnabled(root, tree.root, inAmount)` |
| c'  | forged Merkle path (tampered sibling)              | same |
| d   | forged ownership (spend with wrong privkey)        | commitment→leaf→root chain |
| d'  | forged nullifier (inputNullifier tampered)         | `inNullifierHasher.out === inputNullifier` |
| e   | 248-bit overflow (outAmount = 2^248)               | `Num2Bits(248)` on outputs |
| e'  | negative-amount aliasing (outAmount = p-100)       | `Num2Bits(248)` on outputs |
| —   | public-signal binding (×7)                         | Groth16 public-input binding |

## Meta-test (proving the suite can fail loudly)

Removing `sumIns + publicAmount === sumOuts` from a mutant circuit makes attack
(a) generate a witness **and a verifying proof** — the suite reports
`PROVED_CRITICAL`. So the CRITICAL path is real, not decorative. Re-run that
check after any change to the reject logic.

## Out of scope for this circuit-level suite

- **Cross-transaction double-spend** is a *contract* invariant
  (`EsseyShieldedPool._transact`: `isSpent` + the `nullifierHashes` mapping), not
  a circuit one. The circuit only forbids duplicate nullifiers *within one tx*.
- **`root` validity** (`isKnownRoot`) and **`publicAmount` range** are contract
  side (`calculatePublicAmount`, `MAX_EXT_AMOUNT`). The circuit binds them but
  does not range/validity-check them.
- **Trusted-setup / ceremony integrity** — the suite uses a throwaway setup.

## Extending

Add a case by pushing to `TESTS`-style calls in `run.js` (use `witnessReject`).
Keep the differential discipline: a fraud case should differ from a *passing*
baseline only in the one thing under test, so a rejection isolates one constraint.
