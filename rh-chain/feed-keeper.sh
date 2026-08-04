#!/usr/bin/env bash
# Testnet feed keeper — re-stamps the mock price feeds so stock payouts, Cases, and the degen roll stay
# live (they go stale after ~25h). Run on a cron every ~2h. Idempotent + retries the flaky RPC.
#
#   ./feed-keeper.sh
#   cron (every 2h): 23 */2 * * * cd $HOME/Developer/assay/rh-chain && ./feed-keeper.sh >> /tmp/essey-feed-keeper.log 2>&1
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
[ -f .env ] || { echo "!! rh-chain/.env missing (needs TESTNET_DEPLOYER_PK)"; exit 1; }
set -a; . ./.env; set +a
PK="${TESTNET_DEPLOYER_PK:?TESTNET_DEPLOYER_PK not set}"
export FOUNDRY_PROFILE=script

run() { forge script script/FeedKeeper.s.sol --rpc-url rh_testnet --broadcast --private-key "$PK" --gas-estimate-multiplier 300 2>&1; }
for attempt in 1 2 3; do
  OUT=$(run) || true
  if echo "$OUT" | grep -q "refreshed feeds"; then
    echo "$(date -u '+%Y-%m-%d %H:%M UTC') OK — $(echo "$OUT" | grep -o 'refreshed feeds: [0-9]*')"
    exit 0
  fi
  echo "$(date -u '+%Y-%m-%d %H:%M UTC') attempt $attempt failed (RPC?); retrying…"
  sleep 5
done
echo "$(date -u '+%Y-%m-%d %H:%M UTC') FAILED after 3 attempts"; exit 1
