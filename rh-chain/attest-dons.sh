#!/usr/bin/env bash
# Put every Don's stat sheet on chain. attest() is PERMISSIONLESS — it only checks that the submitted
# bytes reproduce the collection's own commitment — so this needs no role, just gas.
#
#   AFFINITY=0x... SITE=https://essey.xyz ./attest-dons.sh 1 200
#
# Idempotent: an already-attested Don reverts with AlreadyAttested and is counted as skipped, so the
# script can be re-run after new mints without special-casing anything.
set -euo pipefail

AFFINITY="${AFFINITY:?set AFFINITY to the registry address}"
SITE="${SITE:-https://essey.xyz}"
RPC="${RPC:-rh_testnet}"
FROM="${1:-1}"
TO="${2:-200}"

: "${TESTNET_DEPLOYER_PK:?export TESTNET_DEPLOYER_PK}"

ok=0; skipped=0; nopre=0; failed=0
for ((id = FROM; id <= TO; id++)); do
  # The endpoint does a chain read, a KV read and an RPC previewSheet, so it is slow enough that a
  # bare `curl -sf` under a tight loop reports a timeout as an ABSENT preimage and silently skips a
  # Don that has one. Retry and allow real time before believing a Don has no record.
  pre=$(curl -sf --retry 4 --retry-delay 2 --retry-all-errors -m 25 "$SITE/api/don/$id" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("preimage") or "")
except Exception: print("")' 2>/dev/null || true)

  if [[ -z "$pre" ]]; then
    nopre=$((nopre + 1)); continue
  fi

  hex=$(printf '%s' "$pre" | xxd -p | tr -d '\n')
  if out=$(cast send "$AFFINITY" "attest(uint256,bytes)" "$id" "0x$hex" \
        --rpc-url "$RPC" --private-key "$TESTNET_DEPLOYER_PK" --gas-limit 400000 2>&1); then
    ok=$((ok + 1)); echo "#$id attested"
  elif grep -q "AlreadyAttested" <<<"$out"; then
    skipped=$((skipped + 1))
  elif grep -q "nonce too low" <<<"$out"; then
    sleep 2
    if cast send "$AFFINITY" "attest(uint256,bytes)" "$id" "0x$hex" \
        --rpc-url "$RPC" --private-key "$TESTNET_DEPLOYER_PK" --gas-limit 400000 >/dev/null 2>&1; then
      ok=$((ok + 1)); echo "#$id attested (after nonce retry)"
    else
      failed=$((failed + 1)); echo "#$id FAILED: nonce"
    fi
  else
    failed=$((failed + 1)); echo "#$id FAILED: $(head -c 120 <<<"$out")"
  fi
done

echo "attested=$ok already=$skipped no-preimage=$nopre failed=$failed"
