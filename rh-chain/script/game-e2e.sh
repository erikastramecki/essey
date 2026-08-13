#!/usr/bin/env bash
# game-e2e.sh — orchestrator for the D.O.N. Skirmish Phase-0 adversarial wallet harness (GameE2E.s.sol)
# on Robinhood Chain testnet (46630).
#
# The game stack is time-gated (mission durations, the [10,40]min raid reveal window), so one forge run
# cannot cover it: this script sequences the GameE2E phases with real wall-clock sleeps, mines FAILED
# txs for the negative checks (cast send with a manual gas limit so the revert lands on-chain and is
# explorer-linkable), and appends every tx to an audit log the report is built from.
#
#   usage: script/game-e2e.sh <command> [args...]     (run from rh-chain/)
#
# Commands mirror the harness phases (phase <sig> <args…>, neg <label> <error> <wallet#> <to> <sig> <args…>,
# ticktime, log …). The canonical full sequence lives in docs/TESTNET-GAME-E2E.md. Keys: the deployer key
# comes from .env and is never printed; actor keys are keccak(seed,i) throwaways, derived on the fly.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

RPC=${RPC:-https://rpc.testnet.chain.robinhood.com/rpc}
CHAIN=46630
EXPLORER="https://explorer.testnet.chain.robinhood.com/tx/"
TXLOG=${TXLOG:-broadcast/game-e2e-txlog.jsonl}
SEED=$(cast keccak "$(cast from-utf8 "don-game-e2e-v1")")

# stack
CONTROLLER=0xe2BEA5db063EA57F73D6bA8294592d7f60CBec9f
SCRIP=0xAE8AEB1E0eA9A6E6A55b469107DD5c7cbf28F1F6
DEED=0xe180dbda25966Cd6AE372C967200F0EB6D003368
ESCROW=0x869cbc012C37F7655FA5eA8F655E862Aa631C93C
BOARD=0xA4839CA4b595c768636E05bF37E32b167e482d99
RAID=0xf497AAb709952FF061AEC34390Dad281649D1a2a
HITTER=0x219fafE26FB865b8dA4F55EF38ee99a91Ef969Cf
ENTROPY=0xc9e6B140C10e6DcDAE7a2d2a9FdD1BB82Ca1F047
DON=0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c

wallet_pk() { cast keccak "$(cast abi-encode 'x(bytes32,uint256)' "$SEED" "$1")"; }
wallet_addr() { cast wallet address --private-key "$(wallet_pk "$1")"; }

log_tx() { # label hash status extra
  printf '{"ts":%s,"label":"%s","tx":"%s","status":"%s","extra":"%s"}\n' \
    "$(date +%s)" "$1" "$2" "$3" "${4:-}" >>"$TXLOG"
  echo "LOGGED [$1] $2 ($3)"
}

# ---- phase <sig> [args…]: run a broadcast GameE2E phase and log every tx it sent ----
phase() {
  local sig="$1"; shift
  local fn="${sig%%(*}"
  FOUNDRY_PROFILE=script forge script script/GameE2E.s.sol:GameE2E \
    --rpc-url "$RPC" --broadcast --sig "$sig" "$@" --gas-estimate-multiplier 200 -vv
  local file="broadcast/GameE2E.s.sol/$CHAIN/${fn}-latest.json"
  [ -f "$file" ] || file="broadcast/GameE2E.s.sol/$CHAIN/run-latest.json"
  jq -r --arg fn "$fn" \
    '.transactions[] | [.hash, (.function // "eth-transfer"), .transactionType] | @tsv' "$file" |
    while IFS=$'\t' read -r hash f ty; do log_tx "$fn:$f" "$hash" "broadcast" "$ty"; done
}

# ---- view <sig> [args…]: run a NON-broadcast phase (verifyState, forkProofs) ----
view() {
  local sig="$1"; shift
  FOUNDRY_PROFILE=script forge script script/GameE2E.s.sol:GameE2E \
    --rpc-url "$RPC" --sig "$sig" "$@" -vv
}

# ---- neg <label> <ErrorSig()> <wallet#|deployer> <to> <fnsig> [args…] ----
# Negative check, proven twice: (1) eth_call must revert with EXACTLY the expected custom error
# selector; (2) the same call is mined with a manual gas limit -> an on-chain FAILED tx (status 0),
# explorer-linkable. Cheap on testnet; the revert itself is the proof.
neg() {
  local label="$1" err="$2" who="$3" to="$4" fnsig="$5"; shift 5
  local pk
  if [ "$who" = "deployer" ]; then pk="$TESTNET_DEPLOYER_PK"; else pk="$(wallet_pk "$who")"; fi
  local want got
  want=$(cast sig "$err")
  set +e
  got=$(cast call "$to" "$fnsig" "$@" --from "$(cast wallet address --private-key "$pk")" -r "$RPC" 2>&1)
  set -e
  if ! echo "$got" | grep -qi "${want#0x}"; then
    echo "NEG-CHECK FAILED [$label]: expected $err ($want), got: $got"
    log_tx "NEG:$label" "none" "UNEXPECTED" "$got"
    return 1
  fi
  echo "NEG [$label] eth_call reverted with $err as expected"
  local hash
  hash=$(cast send "$to" "$fnsig" "$@" --private-key "$pk" --gas-limit 500000 -r "$RPC" --json 2>/dev/null | jq -r .transactionHash)
  local status
  status=$(cast receipt "$hash" -r "$RPC" --json | jq -r .status)
  if [ "$status" != "0x0" ]; then
    echo "NEG-CHECK FAILED [$label]: mined tx unexpectedly SUCCEEDED ($hash)"
    log_tx "NEG:$label" "$hash" "UNEXPECTED-SUCCESS" "$err"
    return 1
  fi
  log_tx "NEG:$label" "$hash" "reverted-as-expected" "$err"
}

# ---- ticktime: force a fresh block so sim block.timestamp tracks wall clock ----
ticktime() {
  local addr
  addr=$(cast wallet address --private-key "$TESTNET_DEPLOYER_PK")
  cast send "$addr" --value 0 --private-key "$TESTNET_DEPLOYER_PK" -r "$RPC" >/dev/null
  echo "chain ts now: $(cast block latest -f timestamp -r "$RPC") (wall: $(date +%s))"
}

# ---- events <contract> <event-sig> [from-block]: pull the events the post-hoc asserts read ----
events() { cast logs --address "$2" "$3" --from-block "${4:-100500000}" --to-block latest -r "$RPC" --json; }

"$@"
