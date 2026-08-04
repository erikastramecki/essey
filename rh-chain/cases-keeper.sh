#!/usr/bin/env bash
# Testnet fair-value Cases keeper. EsseyCases.open() may be called by the buyer OR this keeper, and the
# prize is always delivered to the stored buyer, so this reveals on their behalf -> the buyer signs only
# the buy. It opens each ready case promptly (well within the 256-block blockhash window); past that
# window a case can only be floor-claimed by the buyer, so keeper uptime is load-bearing.
#
#   Run persistently:   ./cases-keeper.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

set -a; . ./.env; set +a
PK="${TESTNET_DEPLOYER_PK:?set TESTNET_DEPLOYER_PK in rh-chain/.env}"
RPC="${RH_TESTNET_RPC:-https://rpc.testnet.chain.robinhood.com}"
CASES="0x97ad3b44d0B362F70460c90993E9eF79b9D2D749"   # keeper-enabled EsseyCases on testnet 46630
WINDOW=60
INTERVAL="${CASES_KEEPER_INTERVAL:-3}"

echo "cases-keeper: watching $CASES every ${INTERVAL}s"
declare -A handled   # ids we've already opened/attempted — avoids re-sending during state-propagation lag
while true; do
  next=$(cast call "$CASES" 'nextCaseId()(uint256)' --rpc-url "$RPC" 2>/dev/null)
  if [[ "$next" =~ ^[0-9]+$ ]] && [ "$next" -gt 0 ]; then
    bn=$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo 0)
    start=0; [ "$next" -gt "$WINDOW" ] && start=$((next - WINDOW))
    for ((id = start; id < next; id++)); do
      [ -n "${handled[$id]:-}" ] && continue
      # cases(id) -> (buyer, drawBlock, boughtAt, opened)
      res=$(cast call "$CASES" 'cases(uint256)(address,uint64,uint64,bool)' "$id" --rpc-url "$RPC" 2>/dev/null) || continue
      opened=$(echo "$res" | sed -n '4p')
      [ "$opened" = "true" ] && { handled[$id]=1; continue; }
      drawBlock=$(echo "$res" | sed -n '2p' | awk '{print $1}')
      [[ "$drawBlock" =~ ^[0-9]+$ ]] || continue
      [ "$bn" -le "$drawBlock" ] && continue   # draw block not mined yet
      # Send once, then mark handled regardless: success opens it; a revert means AlreadyOpened (keeper
      # or buyer beat us) or DrawExpired (buyer must claimExpired) — either way, stop retrying this id.
      cast send "$CASES" 'open(uint256)' "$id" --private-key "$PK" --rpc-url "$RPC" --gas-limit 600000 >/dev/null 2>&1 \
        && echo "$(date -u +%H:%M:%S) opened case $id"
      handled[$id]=1
    done
  fi
  sleep "$INTERVAL"
done
