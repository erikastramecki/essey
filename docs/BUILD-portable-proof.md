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

The earlier benchmark (1.27M constraints, ~7s prove) was the **ECDSA core only**. The real circuit
also needs keccak256 in-circuit, which is ~150k constraints each:

| Component | keccak256 hashes | est. constraints |
|---|---|---|
| ECDSA quorum (measured) | — | 1.27M |
| body double-hash | 2 | ~0.3M |
| guardian pubkey → address (×13) | 13 | ~2.0M |
| Merkle path (leaf + 13 hops) | 14 | ~2.1M |
| **total (estimate)** | ~29 | **~5–6M** |

So realistic figures, extrapolating the measured ~7s / 1.27M linearly: **~30–40s prove, ~10 min
one-time setup, ~1.5 GB proving key, ~10 GB RAM.** Still runtime-feasible for a *batch* (one proof
amortized over many loans); the on-chain **verify stays 2 ms / 496 B regardless** (Groth16 verify is
size-independent). The keccak cost is the next thing to measure, not assume.

## Phases

1. **Native parser + real fixture — DONE.** `circuit/pyth/` parses a real PNAU update; tests pin
   every field against Hermes (BTC $64,124.49, 13 sigs, 13-hop proof).
2. **Native full verifier — DONE.** `verify.go` verifies the 13 guardian ECDSA sigs (ecrecover over
   the double-keccak body) against Wormhole guardian-set-7 addresses (`guardians.go`, pulled live
   from the core contract), and verifies the sorted-pair Merkle proof to the root. Tests confirm the
   real update passes and that a tampered body or price is rejected. This is the ground truth + the
   witness generator the circuit consumes.
3. **In-circuit keccak + ECDSA — next.** Wire gnark's keccak gadget; MEASURE its real cost; integrate with
   the ECDSA quorum. Replace the estimate above with numbers.
4. **In-circuit Merkle proof** against the root.
5. **Assemble + bind.** One circuit: VAA verify → extract price → feed the solvency commitment.
6. **Batch.** N loans, one shared VAA verification, one proof.
7. **Trusted setup ceremony + audit.** A ~5–6M-constraint circuit: a botched setup forges prices; a
   wrong constraint drains the pool. Non-negotiable before mainnet.

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
