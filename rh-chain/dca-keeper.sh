#!/usr/bin/env bash
# Testnet DCA keeper. Executes due RecurringBuy fills (Auto-stack into stock). Each fill settles through the
# oracle-floored, US-session-gated converter, so off-market-hours or on a stale feed the fill reverts. This
# keeper SIMULATES each due fill first and only sends the ones that would land — so it never wastes gas fighting
# the session gate; those fills simply retry when the market is open. (Fills also need fresh feeds, so run this
# alongside feed-keeper.sh.) executeFill is permissionless, so any funded key can run this.
#
#   Run persistently:   ./dca-keeper.sh
set -uo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

set -a; . ./.env; set +a
PK="${TESTNET_DEPLOYER_PK:?set TESTNET_DEPLOYER_PK in rh-chain/.env}"
RPC="${RH_TESTNET_RPC:-https://rpc.testnet.chain.robinhood.com}"
RB="0xF0DCE628d4023cdc8115E6f5998D9279eA06d9ab"   # RecurringBuy on testnet 46630
KEEPER=$(cast wallet address --private-key "$PK" 2>/dev/null)
INTERVAL="${DCA_KEEPER_INTERVAL:-30}"

echo "dca-keeper: watching $RB every ${INTERVAL}s (executor $KEEPER)"
while true; do
  next=$(cast call "$RB" 'nextId()(uint256)' --rpc-url "$RPC" 2>/dev/null)
  if [[ "$next" =~ ^[0-9]+$ ]] && [ "$next" -gt 0 ]; then
    for ((id = 1; id <= next; id++)); do
      due=$(cast call "$RB" 'dueNow(uint256)(bool)' "$id" --rpc-url "$RPC" 2>/dev/null)
      [ "$due" = "true" ] || continue
      # Simulate first: a fill that would revert (closed session / stale feed / floor not met) is skipped, not
      # sent — so we don't burn gas, and it retries next poll once conditions clear.
      if cast call "$RB" 'executeFill(uint256)' "$id" --from "$KEEPER" --rpc-url "$RPC" >/dev/null 2>&1; then
        cast send "$RB" 'executeFill(uint256)' "$id" --private-key "$PK" --rpc-url "$RPC" --gas-limit 700000 >/dev/null 2>&1 \
          && echo "$(date -u +%H:%M:%S) filled schedule $id"
      fi
    done
  fi
  sleep "$INTERVAL"
done
