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

**keccak is 82% of the circuit — the ECDSA is the minority.** Extrapolating the measured 1.27M
pipeline (×5.4): **~40s prove, ~13 min one-time setup, ~1.9 GB proving key, ~14 GB RAM.** Runtime-
feasible for a *batch* (one proof over many loans), but proving wants a real machine. On-chain
**verify stays 2 ms / 496 B regardless** — Groth16 verify is size-independent.

**Optimization (measured): pin pubkeys, not addresses.** 13 keccaks only exist to derive guardian
*addresses* from recovered pubkeys. If the pool pins the guardian **pubkeys** (derived once,
off-circuit, audited) we verify ECDSA directly and drop the pubkey→address hashes:
**~2.5M constraints gone → ~4.3M full circuit.** Adopt this in phase 5.

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
