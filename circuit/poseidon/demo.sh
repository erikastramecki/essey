#!/usr/bin/env bash
# The whole Essey portable-proof pipeline in one command, on a LIVE Pyth price:
#   fetch live price -> verify it's guardian-signed -> prove a solvent loan in ZK -> verify on-chain.
# First run does a one-time trusted setup (~5 min, cached); after that it runs in ~30s — live-demo
# ready. Requires: go, foundry (anvil/forge/cast), curl.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="${CACHE:-$HERE/.demo-keys}"          # cached proving keys (gitignored)
OUT="$(mktemp -d)"
RPC=http://127.0.0.1:8546
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil account 0
BTC=e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43

echo "════════════════════════════════════════════════════════════════"
echo "  ESSEY — a loan, proven against a live price, verified on-chain"
echo "════════════════════════════════════════════════════════════════"

echo; echo "[0] Fetch a LIVE BTC price from Pyth (Hermes)"
curl -s -m 20 "https://hermes.pyth.network/v2/updates/price/latest?ids%5B%5D=$BTC&encoding=hex" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['binary']['data'][0])" > "$OUT/update.hex"
echo "    got a signed accumulator update ($(( $(wc -c < "$OUT/update.hex") / 2 )) bytes)"

# steps 1-5: native verify -> prove -> export verifier + calldata
( cd "$HERE" && go run ./cmd/demo "$OUT/update.hex" "$CACHE" "$OUT" )

echo; echo "[6] Verify the proof ON-CHAIN (a real EVM, no oracle deployed)"
mkdir -p "$OUT/proj/src"; cp "$OUT/Verifier.sol" "$OUT/proj/src/"
printf '[profile.default]\nsrc="src"\nout="out"\nsolc="0.8.28"\n' > "$OUT/proj/foundry.toml"
( cd "$OUT/proj" && forge build >/dev/null )
pkill -f "anvil.*8546" 2>/dev/null || true; sleep 1
anvil --port 8546 >/dev/null 2>&1 & ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
sleep 3
ADDR=$(cd "$OUT/proj" && forge create src/Verifier.sol:Verifier --rpc-url $RPC --private-key $PK --broadcast 2>/dev/null \
  | grep -oE "Deployed to: 0x[a-fA-F0-9]+" | awk '{print $3}')
echo "    verifier deployed to a fresh chain at $ADDR"
CALLDATA=$(cat "$OUT/calldata.txt")
if cast call "$ADDR" --data "$CALLDATA" --rpc-url $RPC >/dev/null 2>&1; then
  GAS=$(cast send "$ADDR" --data "$CALLDATA" --rpc-url $RPC --private-key $PK 2>/dev/null | grep -iE "^gasUsed" | awk '{print $2}')
  echo "    ✓ PROOF VERIFIED ON-CHAIN — gas used: ${GAS:-~few hundred k}"
else
  echo "    ✗ on-chain verification failed:"; cast call "$ADDR" --data "$CALLDATA" --rpc-url $RPC 2>&1 | head -2; exit 1
fi

echo
echo "════════════════════════════════════════════════════════════════"
echo "  A live Pyth price → a ZK proof → verified on a chain with no"
echo "  oracle, for ~a few hundred k gas. That is a loan that can settle"
echo "  anywhere. Every step above is real."
echo "════════════════════════════════════════════════════════════════"
