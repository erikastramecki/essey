# Essey Private — shielded pool (Phase 1)

A single-chain shielded USDG pool that **hides amounts**: deposits, in-pool transfers, and withdrawals
move UTXO notes whose values live inside a zk proof, and the deposit↔withdrawal link is broken.

## Architecture (the "Veil pattern")

The zk core is **Tornado Nova** (MIT), ported and de-bridged; all compliance lives in a **separate front-door
contract** so the core stays unmodified. That split is deliberate — it keeps the audited money-math intact and
puts the operator's policy where we can change it.

- **`EsseyShieldedPool.sol`** — Nova's join-split pool, de-bridged from the Gnosis L1↔L2 machinery to a plain
  single-chain ERC-20 pool. The ONLY core change is a front-door hook: a deposit calls `gate.isApproved(depositor)`.
  2-input join-split (deposit / withdraw / 2→2 transfer).
- **`EsseyPoolGate.sol`** — the operator front door. `isApproved` gates deposits (the association set). Withdrawals
  are never gated. Phase 1 is a straight allow-list (`openMode` for testnet); credential fast-paths + an async
  KYT queue layer on top of the same interface later.
- **`MerkleTreeWithHistory.sol`** — Nova's incremental tree, ported to 0.8.28. `zeros()` regenerated to **modern
  circomlib Poseidon** (Nova's original table was old-tornado Poseidon and is NOT interchangeable).
- **`PoolVerifier2.sol`** — the snarkjs-generated Groth16 verifier (7 public signals).
- **Poseidon hasher** — `../../circuits-nova/build/Hasher2.bytecode.txt`, generated from the SAME circomlib the
  circuit uses (deployed from raw bytecode).

## Circuits

`../../circuits-nova/*.circom` — Nova's join-split ported from Circom 0.5 to Circom 2.x (modern circomlib). Public
signals, in order: `[root, publicAmount, extDataHash, inputNullifier0, inputNullifier1, outputCommitment0,
outputCommitment1]`.

## Status (2026-08-06)

- 3-agent adversarial audit (circuit + contract + tree/hasher): **clean on security** — no forge / mint / steal /
  double-spend / drain / gate-bypass / tree-corruption.
- **Proven on Robinhood Chain testnet**: a hidden-amount USDG deposit → withdrawal (see `script/ProveShieldedPool.s.sol`).

## ⚠️ NOT production-ready — before any real value

1. **Tree depth.** The demo circuit is `Transaction(5,...)` → 32 leaves = **16 total transactions**, then funds
   lock. Recompile at production depth (e.g. 20 → ~1M txs), regenerate the zkey + `PoolVerifier2.sol`, deploy with
   matching `LEVELS`. (`zeros()` already extends to 23.)
2. **Trusted setup.** The demo zkey used throwaway ceremony entropy. Production needs a real multi-party ceremony.
3. **Formal zk audit** of the circuit by a specialist firm.
4. **Production ASP** (the screening engine behind the gate) + the operator's MSB/AML counsel track.

## Regenerating artifacts

The prover SDK + witness/proof generation live in the working dir `scratchpad/nova-port/` (`lib.js`,
`prove_deposit.js`, `prove_withdraw.js`). The large binaries (`.zkey`, `.wasm`, `.ptau`) are gitignored — rebuild
via `circom` 2.x + `snarkjs` 0.7.x against the circuits here.
