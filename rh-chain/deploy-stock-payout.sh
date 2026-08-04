#!/usr/bin/env bash
# One-command stock-payout deploy (testnet). Chains all five deploy steps, auto-passing each step's
# fresh addresses into the next, then prints the exact ADDR block for app/web/src/live.ts.
#
#   ./deploy-stock-payout.sh            # deploy + seed + lens, then prove the stock claim on-chain
#   ./deploy-stock-payout.sh --no-prove # skip the on-chain proof (e.g. off-session)
#
# MUST run during a US market session (14:30-20:00 UTC weekday) for the proof to settle in stock.
# Requires PK (deployer key) in rh-chain/.env, RPC alias rh_testnet, jq installed. Aborts on any error.
set -euo pipefail
cd "$(dirname "$0")"
# Make forge/jq/git/cast resolvable under a scheduler's minimal PATH (cron/launchd).
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# --- deployer key (gitignored .env) ---
[ -f .env ] || { echo "!! rh-chain/.env missing (needs PK=...)"; exit 1; }
set -a; . ./.env; set +a
: "${PK:?PK not set in .env}"

export FOUNDRY_PROFILE=script
RPC=rh_testnet
CHAIN=46630
# Orbit stack under-estimates intrinsic gas; 300 adds headroom (unused gas is refunded, no extra cost).
FORGE="forge script --rpc-url $RPC --broadcast --private-key $PK --gas-estimate-multiplier 300"

# Reused (existing) testnet addresses — the pool + its markets keep working.
export USDG=0x7461E670d44FF4397A3E48030C5b06f6163a5De2
export USDG_FEED=0x6ac94CAb7302415A9a29d9746Fb6051523592E3b
export AAPL=0xaC6cd493e69eb82e8f113E33De8e5542F313B731
export NVDA=0x8393cc99FAC1CF79E3bEceA56f344159ddFd91E9
export QUEST=0x3DD40673665e13bD4A8A7B1D6e27Cb43EDfE0427
export POOL=0x283a4891458180f502E82E40470d3e06321ba748
BUNDLE=0x000000000000000000000000000000000000B0B1

# addr <Script> <ContractName> -> first CREATE address of that contract in the latest broadcast
addr() { jq -r --arg n "$2" '[.transactions[] | select(.contractName==$n and .contractAddress!=null) | .contractAddress][0]' \
  "broadcast/$1.s.sol/$CHAIN/run-latest.json"; }
req() { [ -n "$1" ] && [ "$1" != "null" ] || { echo "!! failed to extract $2"; exit 1; }; }

echo "== 1/5 BundleConverter + reserve =="
$FORGE script/DeployBundleConverter.s.sol >/dev/null
export CONVERTER=$(addr DeployBundleConverter BundleConverter); req "$CONVERTER" CONVERTER
echo "   CONVERTER=$CONVERTER"

echo "== 2/5 Market (fresh Seat+Bell+Exchange+Cases) =="
CONVERTER=$CONVERTER DEFAULT_PAYOUT=$BUNDLE $FORGE script/DeployMarket.s.sol >/dev/null
export DISTRIBUTOR=$(addr DeployMarket MintDistributor); req "$DISTRIBUTOR" DISTRIBUTOR
export SEAT=$(addr DeployMarket Seat);                 req "$SEAT" SEAT
export ESSEY=$(addr DeployMarket EsseyToken);          req "$ESSEY" ESSEY
export BELL=$(addr DeployMarket Bell);                 req "$BELL" BELL
export EXCHANGE=$(addr DeployMarket EsseyExchange);    req "$EXCHANGE" EXCHANGE
export CASES=$(addr DeployMarket EsseyCases);          req "$CASES" CASES
export SEATART=$(addr DeployMarket SeatArt);           req "$SEATART" SEATART
echo "   SEAT=$SEAT BELL=$BELL"

echo "== 3/5 Gate convert() to the Bell =="
CONVERTER=$CONVERTER BELL=$BELL $FORGE script/WireConverterBell.s.sol >/dev/null

echo "== 4/5 Seed market (float, cases, faucet) =="
$FORGE script/SeedStockMarket.s.sol >/dev/null
export FAUCET=$(addr SeedStockMarket TestnetFaucet); req "$FAUCET" FAUCET

echo "== 5/5 Redeploy QuestLens with the new Seat =="
$FORGE script/DeployLens.s.sol >/dev/null
export LENS=$(addr DeployLens QuestLens); req "$LENS" LENS

echo
echo "==================== NEW ADDRESSES -> app/web/src/live.ts ADDR ===================="
cat <<EOF
  seat:      "$SEAT"
  essey:     "$ESSEY"
  bell:      "$BELL"
  exchange:  "$EXCHANGE"
  cases:     "$CASES"
  faucet:    "$FAUCET"
  converter: "$CONVERTER"
  lens:      "$LENS"
  // unchanged: usdg, aapl, nvda, pool, quest, markets
EOF
echo "===================================================================================="

if [ "${1:-}" != "--no-prove" ]; then
  echo
  echo "== PROVING the stock claim on-chain (must be in-session) =="
  SEAT=$SEAT BELL=$BELL EXCHANGE=$EXCHANGE ESSEY=$ESSEY USDG=$USDG CONVERTER=$CONVERTER \
    $FORGE script/ProveStockPayout.s.sol
  echo "== If the run above asserted AAPL/NVDA in the Vault, stock payouts are LIVE. =="
fi

echo
echo "NEXT: paste the ADDR block into app/web/src/live.ts, commit, then flip prod:"
echo "  git checkout main && git merge --ff-only feat/essey-market-layer && git push origin main"
