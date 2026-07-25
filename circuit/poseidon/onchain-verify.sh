#!/usr/bin/env bash
# On-chain verification of a real Essey proof, end to end: export the Solidity verifier from the
# circuit's vk, deploy it to a local EVM, verify a real Groth16 proof, and report gas. This is the
# check every settlement chain runs — flat cost, no oracle, regardless of the circuit's size.
#
#   bash onchain-verify.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil account 0
RPC=http://127.0.0.1:8546

echo "── export Verifier.sol + proof calldata from the circuit vk ──"
( cd "$HERE" && OUT="$OUT" go test -run TestExportOnchainVerifier -timeout 200s >/dev/null )

echo "── foundry project ──"
mkdir -p "$OUT/proj/src"; cp "$OUT/Verifier.sol" "$OUT/proj/src/"
printf '[profile.default]\nsrc="src"\nout="out"\nsolc="0.8.28"\n' > "$OUT/proj/foundry.toml"
( cd "$OUT/proj" && forge build >/dev/null )

echo "── anvil + deploy ──"
pkill -f "anvil.*8546" 2>/dev/null || true; sleep 1
anvil --port 8546 >/dev/null 2>&1 & ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
sleep 3
ADDR=$(cd "$OUT/proj" && forge create src/Verifier.sol:Verifier --rpc-url $RPC --private-key $PK --broadcast 2>/dev/null \
  | grep -oE "Deployed to: 0x[a-fA-F0-9]+" | awk '{print $3}')
echo "   verifier: $ADDR"

PROOF="[$(cat "$OUT/proof.txt")]"; INPUT="[$(cat "$OUT/input.txt")]"
echo "── verify the REAL proof on-chain (view reverts if invalid) ──"
cast call "$ADDR" "verifyProof(uint256[8],uint256[1])" "$PROOF" "$INPUT" --rpc-url $RPC >/dev/null \
  && echo "   ✓ VERIFIED on-chain (did not revert)"
echo "   gas: $(cast estimate "$ADDR" "verifyProof(uint256[8],uint256[1])" "$PROOF" "$INPUT" --rpc-url $RPC)"

echo "── negative control: a bogus public input must be rejected ──"
if cast call "$ADDR" "verifyProof(uint256[8],uint256[1])" "$PROOF" "[123456]" --rpc-url $RPC >/dev/null 2>&1; then
  echo "   ✗ SOUNDNESS FAILURE: bogus input accepted"; exit 1
else
  echo "   ✓ bogus input rejected"
fi
echo "done."
