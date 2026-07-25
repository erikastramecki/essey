# Build — portable proof (in-circuit Pyth/Wormhole verification)

**Goal:** a zk proof that carries a Pyth price's full provenance inside it, so a batch of Essey
loans can settle on *any* chain — including one with no oracle — and the chain trusts the price
because the proof verifies the guardian quorum and Merkle inclusion itself. This is "heavy B" from
[SCOPE-solvency-circuit.md](SCOPE-solvency-circuit.md).

## The real verification chain (grounded, not assumed)

Decoded from a live Hermes update (`circuit/pyth/testdata/pyth_btc_update.hex`). A Pyth "PNAU"
accumulator update is a Wormhole VAA attesting a Merkle root, plus a Merkle proof per price. To
trust a price with no oracle, the verifier must reproduce all of:

1. **Guardian quorum.** 13 of 19 guardians each sign `keccak256(keccak256(body))` (an 88-byte body)
   with secp256k1 ECDSA. Each guardian is identified by a keccak-derived 20-byte address.
2. **Merkle root** lives in the VAA body payload (magic `AUWV`, 20-byte keccak160 root).
3. **Merkle inclusion.** The price is a leaf `keccak160(0x00 || message)`; a 13-hop proof of
   `keccak160(0x01 || pair)` climbs to the root.
4. **Bind** the extracted price to the loan's committed price (the existing solvency circuit).

## Honest cost re-scope

The earlier benchmark (1.27M constraints, ~7s prove) was the **ECDSA core only**. Both keccak and
ECDSA are now MEASURED in gnark: one keccak256 block = **191,871** constraints (higher than the
~150k guess); one secp256k1 ECDSA = 121,435; the 13-sig quorum = 1,266,437.

| Component | keccak256 hashes | measured constraints |
|---|---|---|
| ECDSA quorum (verify vs pubkey) | — | 1.27M |
| body double-hash | 2 | ~0.38M |
| guardian pubkey → address (×13) | 13 | ~2.49M |
| Merkle path (leaf + 13 hops) | 14 | ~2.69M |
| solvency core | — | 2,235 |
| **full circuit (measured)** | ~29 | **~6.8M** |

**keccak lookup tables AMORTISE — the 6.8M above was an over-count.** Building the Merkle circuit
revealed keccak is not 192k *each*: the first hash pays ~192k to build the shared lookup tables,
every additional hash is only **~60k marginal** (measured: 1 keccak 191,871; 2 keccak 252,062,
Δ 60,191; 14-keccak Merkle 979,085 ≈ 192k + 13×60k). Corrected projection:

| | naive (192k each) | measured marginal (~60k) |
|---|---|---|
| keccak, design B (16 hashes) | ~3.0M | 192k + 15×60k ≈ **~1.1M** |
| + ECDSA quorum | 1.27M | 1.27M |
| **full circuit (design B)** | ~4.3M | **~2.5M** |

So realistically ~15–20s prove — **now confirmed by the assembled circuit (phase 5): 2,396,290
constraints, 16.9s prove, 684 MB key, 2.7 GB RAM, 4m52s one-time setup, 2 ms verify.** The memory
came in well under estimate; a laptop can prove this. On-chain **verify stays 2 ms / 496 B
regardless** (Groth16 verify is size-independent).

**Optimization (measured): pin pubkeys, not addresses.** 13 keccaks only exist to derive guardian
*addresses* from recovered pubkeys. Pinning the guardian **pubkeys** (derived once off-circuit,
audited) verifies ECDSA directly and drops those hashes (design B above).

## Phases

1. **Native parser + real fixture — DONE.** `circuit/pyth/` parses a real PNAU update; tests pin
   every field against Hermes (BTC $64,124.49, 13 sigs, 13-hop proof).
2. **Native full verifier — DONE.** `verify.go` verifies the 13 guardian ECDSA sigs (ecrecover over
   the double-keccak body) against Wormhole guardian-set-7 addresses (`guardians.go`, pulled live
   from the core contract), and verifies the sorted-pair Merkle proof to the root. Tests confirm the
   real update passes and that a tampered body or price is rejected. This is the ground truth + the
   witness generator the circuit consumes.
3. **In-circuit keccak + ECDSA — DONE (single guardian).** keccak cost MEASURED (191,871/block).
   `singleGuardianCircuit` (`guardian_verify_test.go`) computes `keccak256(keccak256(real body))`
   in-circuit, bridges the 32-byte digest to a `Secp256k1Fr` scalar (`digestToScalar`: little-endian
   FromBits + ReduceStrict), and verifies a REAL guardian ECDSA signature over it against the pinned
   pubkey — full Groth16 proof, 378,163 constraints, ~48s. The seam between the keccak (bytes) and
   ECDSA (emulated scalar) worlds is closed on real data. Scaling to the 13-guardian quorum is
   replication: the body digest is computed ONCE and shared, then 13 ECDSA verifies against 13
   pinned pubkeys — ~1.8M constraints (design B, pubkeys pinned, no address keccak).
4. **In-circuit Merkle proof — DONE.** `merkleCircuit` (`merkle_verify_test.go`) climbs the real
   13-hop Pyth proof — leaf `keccak(0x00||msg)[:20]`, sorted-pair nodes `keccak(0x01||min||max)[:20]`
   (in-circuit compare + conditional swap) — to the real root. 979,085 constraints; verified with
   `test.IsSolved` on the real fixture. Revealed the keccak-amortisation finding above.
5. **Assemble + bind — DONE.** `portableProofCircuit` (`portable_proof_test.go`) is the whole thing
   in one circuit: double-keccak digest → 13 ECDSA verifies vs pinned pubkeys → extract the Merkle
   root from the guardian-signed body (`body[68:88]`) → 13-hop Merkle climb must equal it → extract
   the price (`message[33:41]`) → bind it into the solvency commitment. **A real Groth16 proof of the
   full circuit verifies on real Pyth data.** MEASURED: 2,396,290 constraints, 4m52s one-time setup,
   684 MB proving key, **16.9s prove, 2 ms verify, 2.7 GB RAM.** (Insolvent loans are correctly
   rejected by the solvency guard — confirmed when a mis-sized test debt failed the inequality.)
6. **Batch — DONE.** `batchCircuit` (`batch_test.go`) verifies the guardian quorum + root ONCE, then
   proves N loans under it — built and solved on a REAL 3-price Pyth update (BTC/ETH/SOL, one signed
   root). MEASURED marginal per added loan: **~873k constraints** (n=1 2,396,290; n=2 3,269,702; n=3
   4,143,112). So the ~1.5M guardian verification (the expensive "price is real" part) amortises to
   ~0 per loan; each loan carries only its own Merkle inclusion proof (~873k) + solvency. Per-loan
   prove time drops from ~17s (standalone) toward ~6s at scale. **Same-asset** loans share one
   Merkle proof, collapsing the marginal to just the solvency check (~2k) — genuinely near-zero.
   (`essey/pyth` is now imported directly by the circuit tests via a local replace, so batch
   witnesses come from real fixtures, not hardcoded blobs.)
7. **Trusted setup + audit — foundation DONE; ceremony & external audit remain.**
   - **Soundness suite (`soundness_test.go`) — DONE.** The property an audit checks: the circuit
     accepts ONLY valid witnesses. Five negative cases, each breaking one link of the trust chain,
     all REJECTED: forged guardian body, forged Merkle inclusion, terms≠commitment, over-borrow, and
     price substitution (the crux — you cannot swap a favourable price for the attested one).
     Combined with the completeness proof (the assembled test accepts the real update), this is the
     circuit's soundness/completeness backbone.
   - **Trusted setup — decision pending.** Groth16 needs a per-circuit setup; a botched one forges
     proofs. Two paths: (a) a Groth16 MPC ceremony (gnark `mpcsetup`, N independent participants,
     secure if ≥1 is honest) — but per-circuit, so batch-size changes re-run it; (b) switch to PLONK,
     whose universal SRS (from an existing Powers of Tau) needs no per-circuit ceremony, at some
     prover/proof-size cost. **Recommend PLONK** given the circuit will vary by batch size. Not yet
     run here (a real ceremony needs external participants).
   - **Independent audit — external.** A ~2.4M-constraint circuit needs third-party review; a wrong
     constraint drains the pool. The soundness suite + native reference (`circuit/pyth`) are what an
     auditor differential-tests against.

## Reproduce

```
cd circuit/pyth && go test ./...                    # native parser vs the real fixture
COUNT=13 go test -run Quorum ./circuit/poseidon     # the measured ECDSA-quorum pipeline
```

## Why this and not the cheaper options

On Sui / Robinhood Chain the chain verifies Pyth/Chainlink natively for ~free, so in-circuit
verification is redundant *there*. Its whole value is portability: once the proof self-certifies the
price, an Essey loan batch can settle on a minimal chain that has no oracle at all. That is the
capability being built.
