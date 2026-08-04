#!/usr/bin/env bash
# Testnet degen-roll keeper. Settlement is permissionless and credits the stored buyer, so this can
# settle every pending roll on their behalf — letting the frontend need only ONE signature (the buy).
# On mainnet the real Dice oracle does this job; this stand-in exists only for the 46630 testnet.
#
# Run it persistently:   ./degen-keeper.sh
# It scans the recent seq window every few seconds and fulfills anything still pending.
set -uo pipefail
cd "$(dirname "$0")"

# PATH so cron/launchd can find foundry.
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

set -a; . ./.env; set +a
PK="${TESTNET_DEPLOYER_PK:?set TESTNET_DEPLOYER_PK in rh-chain/.env}"
RPC="${RH_TESTNET_RPC:-https://rpc.testnet.chain.robinhood.com}"
ENTROPY="0xb9b82A4900642A98e29F59B937FDE6B2DDaF1E6F"   # MockEntropy on testnet 46630
WINDOW=40   # how many recent seqs to re-scan each pass (covers any transient misses)
INTERVAL="${DEGEN_KEEPER_INTERVAL:-3}"

echo "degen-keeper: watching $ENTROPY every ${INTERVAL}s"
while true; do
  next=$(cast call "$ENTROPY" 'nextSeq()(uint64)' --rpc-url "$RPC" 2>/dev/null)
  if [[ "$next" =~ ^[0-9]+$ ]] && [ "$next" -gt 1 ]; then
    start=1; [ "$next" -gt "$WINDOW" ] && start=$((next - WINDOW))
    for ((seq = start; seq < next; seq++)); do
      filled=$(cast call "$ENTROPY" 'fulfilled(uint64)(bool)' "$seq" --rpc-url "$RPC" 2>/dev/null)
      [ "$filled" = "true" ] && continue
      if cast send "$ENTROPY" 'fulfill(uint64)' "$seq" --private-key "$PK" --rpc-url "$RPC" --gas-limit 600000 >/dev/null 2>&1; then
        echo "$(date -u +%H:%M:%S) settled seq $seq"
      fi
    done
  fi
  sleep "$INTERVAL"
done
