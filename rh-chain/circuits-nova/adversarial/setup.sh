#!/usr/bin/env bash
# Regenerate the local proving artifacts for the adversarial suite. These are
# large and derived, so they are gitignored; run this once before ./run.js.
# A fresh groth16 setup over the same R1CS is sound for soundness testing — the
# suite tests the constraint system, not any particular trusted-setup ceremony.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CIRCUITS="$(cd "$HERE/.." && pwd)"
CIRCOMLIB="${IDEN3_CIRCUITS_NODE_MODULES:-$PWD/node_modules}"
PTAU="${PTAU_PATH:-$PWD/pot15_final.ptau}"

mkdir -p "$HERE/build"
echo "==> compiling transaction2.circom (depth 20) ..."
circom "$CIRCUITS/transaction2.circom" --r1cs --wasm --sym -o "$HERE/build" -l "$CIRCOMLIB"

echo "==> groth16 setup (pot15) ..."
snarkjs groth16 setup "$HERE/build/transaction2.r1cs" "$PTAU" "$HERE/build/harness_0000.zkey"
echo "essey-zk-auditor-adversarial-suite" | snarkjs zkey contribute \
  "$HERE/build/harness_0000.zkey" "$HERE/build/harness_final.zkey" --name="adv-suite"
snarkjs zkey export verificationkey "$HERE/build/harness_final.zkey" "$HERE/build/vkey.json"

echo "==> done. Run:  node $HERE/run.js"
