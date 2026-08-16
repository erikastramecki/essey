#!/usr/bin/env bash
# Is the keeper doing its job? Not "is the process up" — on 2026-08-15 it was up, logging steadily,
# and resolving nothing for eleven hours because it held the previous stack's ENTROPY address and a
# low-water mark past the end of the board. Both failures are invisible in `ps` and in the log.
#
# So this checks the SYMPTOM: a mission that is past due and still unsettled. That is the one thing
# that cannot be true for long while the keeper works, whatever the cause.
#
#   ./rh-chain/check-keeper.sh [graceMinutes]
set -euo pipefail

BOARD="${BOARD:-0x15D607638BeEcF9d62E6eC00a37601A89E72CDF1}"
RPC="${RH_TESTNET_RPC:-https://rpc.testnet.chain.robinhood.com/rpc}"
GRACE=$(( ${1:-15} * 60 ))
MISSION_SIG='missions(uint64)(uint256,uint64,uint64,uint64,bytes32,uint256,uint256,bool,bool)'

now=$(date +%s)
count=$(cast call "$BOARD" 'missionCount()(uint64)' --rpc-url "$RPC" | awk '{print $1}')
stale=0

for ((id = 1; id <= count; id++)); do
  m=$(cast call "$BOARD" "$MISSION_SIG" "$id" --rpc-url "$RPC" 2>/dev/null) || continue
  due=$(echo "$m" | sed -n '4p' | awk '{print $1}')
  settled=$(echo "$m" | sed -n '9p' | tr -d ' ')
  [ "$settled" = "true" ] && continue
  [[ "$due" =~ ^[0-9]+$ ]] || continue
  if (( now > due + GRACE )); then
    printf 'STALE  mission %s  due %ss ago, unsettled\n' "$id" "$((now - due))"
    stale=$((stale + 1))
  fi
done

# The keeper is the only thing that pokes the entropy the ENGINES name. A mismatch is the exact
# 2026-08-15 failure and is worth reporting even when nothing has gone stale yet.
want=$(cast call "$BOARD" 'entropy()(address)' --rpc-url "$RPC")
have=$(grep -oE '^ENTROPY="0x[0-9a-fA-F]{40}"' game-keeper.sh | grep -oE '0x[0-9a-fA-F]{40}' || true)
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; } # macOS ships bash 3.2 — no ${x,,}
if [ "$(lower "$want")" != "$(lower "$have")" ]; then
  printf 'MISMATCH  board.entropy()=%s but game-keeper.sh holds %s\n' "$want" "${have:-none}"
  stale=$((stale + 1))
fi

if ((stale)); then
  echo "--- KEEPER: NOT WORKING ($stale) ---"
  echo "check the process, then .keeper-state/mission.board vs the live board, then ENTROPY."
  exit 1
fi
echo "--- KEEPER: OK --- $count missions, none past due by more than $((GRACE / 60))m"
