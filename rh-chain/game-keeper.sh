#!/usr/bin/env bash
# Testnet D.O.N. game keeper (the degen-keeper.sh pattern, three duties):
#   1. fulfill pending MockEntropy words for the GAME stack (missions, raids, favors)
#   2. auto-resolve missions at the bell (resolve is permissionless payable; the keeper fronts the
#      ~0.000025e fee so a player's mission settles with ZERO extra signatures)
#   3. floorSettle raids whose garrison never opened within the 1h timeout (permissionless; runs the
#      real roll at House-only defense per the H-1 audit fix)
# Liveness only — the keeper can never touch Scrip (audit fix F1) and every one of these calls is
# permissionless, so a dead keeper degrades UX, never funds. On mainnet the real Dice oracle replaces
# duty 1 and duties 2/3 stay as ops crons.
#
# Run it persistently:   ./game-keeper.sh
set -uo pipefail
cd "$(dirname "$0")"

# PATH so cron/launchd can find foundry.
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

set -a; . ./.env; set +a
PK="${TESTNET_DEPLOYER_PK:?set TESTNET_DEPLOYER_PK in rh-chain/.env}"
RPC="${RH_TESTNET_RPC:-https://rpc.testnet.chain.robinhood.com}"
# MUST equal board.entropy() / raid.entropy() — read it back, never copy it forward. The 08-15
# re-point updated BOARD and RAID and left this on the old stack's MockEntropy, so every word was
# delivered to a contract nothing was waiting on and no mission ever settled.
ENTROPY="0x2a1193A7D654D9311dd0b2aE3C44A870D497e521"   # game MockEntropy (46630)
BOARD="0x15D607638BeEcF9d62E6eC00a37601A89E72CDF1"     # MissionBoard
RAID="0xc4B372ff6b3c2Ba511FB8Affa54f88F3Bdc1b2f6"      # RaidEngine
WINDOW=60   # trailing re-scan for SHORT-LIVED objects (entropy seqs, raids: reveal ≤40min, garrison ≤1h)
INTERVAL="${GAME_KEEPER_INTERVAL:-2}"
GARRISON_TIMEOUT=3600
# Missions get a persisted LOW-WATER MARK instead of a trailing window: a long brief (DEEP RUN is 16h)
# falls out of any fixed window before its bell, which stranded missions 13/14/16/21/28/29. The mark is
# the lowest unsettled id; it advances past the settled prefix, so the scan stays small and nothing ages out.
STATE_DIR=".keeper-state"; mkdir -p "$STATE_DIR"
MISSION_LO_FILE="$STATE_DIR/mission.lo"
# The board the low-water mark was computed against. A mark is meaningless against a different board.
MISSION_BOARD_FILE="$STATE_DIR/mission.board"
[ -f "$MISSION_LO_FILE" ] || echo 1 > "$MISSION_LO_FILE"

echo "game-keeper: entropy $ENTROPY / board $BOARD / raid $RAID every ${INTERVAL}s"
while true; do
  now=$(date +%s)

  # -- duty 1: deliver pending entropy words (parallel with duties 2/3 — latency fix) -------------
  (
  next=$(cast call "$ENTROPY" 'nextSeq()(uint64)' --rpc-url "$RPC" 2>/dev/null)
  if [[ "$next" =~ ^[0-9]+$ ]] && [ "$next" -gt 1 ]; then
    start=1; [ "$next" -gt "$WINDOW" ] && start=$((next - WINDOW))
    for ((seq = start; seq < next; seq++)); do
      filled=$(cast call "$ENTROPY" 'fulfilled(uint64)(bool)' "$seq" --rpc-url "$RPC" 2>/dev/null)
      [ "$filled" = "true" ] && continue
      if cast send "$ENTROPY" 'fulfill(uint64)' "$seq" --private-key "$PK" --rpc-url "$RPC" --gas-limit 900000 >/dev/null 2>&1; then
        echo "$(date -u +%H:%M:%S) word delivered seq $seq"
      fi
    done
  fi

  ) &
  # -- duty 2: ring the bell on due missions ------------------------------------------------------
  (
  mcount=$(cast call "$BOARD" 'missionCount()(uint64)' --rpc-url "$RPC" 2>/dev/null)
  if [[ "$mcount" =~ ^[0-9]+$ ]] && [ "$mcount" -ge 1 ]; then
    mstart=$(cat "$MISSION_LO_FILE" 2>/dev/null); [[ "$mstart" =~ ^[0-9]+$ ]] || mstart=1
    # 2026-08-15: a redeploy left this mark at 73 from a 72-mission board. The new board had 37, so
    # the scan range was empty, nothing ever resolved, and the mark then CONVERGED to mcount+1 —
    # indistinguishable from healthy. Comparing the mark to the count is not enough; it has to be
    # tied to the board it was computed against.
    prevboard=$(cat "$MISSION_BOARD_FILE" 2>/dev/null || true)
    if [ "$prevboard" != "$BOARD" ] || [ "$mstart" -gt $((mcount + 1)) ]; then
      echo "$(date -u +%H:%M:%S) KEEPER RESET · mark $mstart vs missionCount $mcount · board ${prevboard:-none} -> $BOARD · rescanning from 1"
      mstart=1
      echo "$BOARD" > "$MISSION_BOARD_FILE"
    fi
    newlo=0   # first id still unsettled this pass; becomes the next low-water mark
    fee=$(cast call "$BOARD" 'entropyFee()(uint256)' --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
    for ((mid = mstart; mid <= mcount; mid++)); do
      # Mission fields: donId briefId departAt due garrisonHash provision reserved entropyRequested settled
      m=$(cast call "$BOARD" 'missions(uint64)(uint256,uint64,uint64,uint64,bytes32,uint256,uint256,bool,bool)' "$mid" --rpc-url "$RPC" 2>/dev/null) || continue
      due=$(echo "$m" | sed -n '4p' | awk '{print $1}')
      requested=$(echo "$m" | sed -n '8p')
      settled=$(echo "$m" | sed -n '9p')
      [ "$settled" = "true" ] && continue
      [ "$newlo" -eq 0 ] && newlo=$mid               # lowest still-unsettled id seen this pass
      [ "$requested" = "true" ] && continue          # word in flight; duty 1 finishes it
      [[ "$due" =~ ^[0-9]+$ ]] || continue
      [ "$now" -lt "$due" ] && continue
      if cast send "$BOARD" 'resolve(uint64)' "$mid" --value "$fee" --private-key "$PK" --rpc-url "$RPC" --gas-limit 900000 >/dev/null 2>&1; then
        echo "$(date -u +%H:%M:%S) bell rung mission $mid"
      fi
    done
    # everything below newlo is settled for good; nothing settled at all => start past the current tail
    [ "$newlo" -eq 0 ] && newlo=$((mcount + 1))
    echo "$newlo" > "$MISSION_LO_FILE"
  fi

  ) &
  # -- duty 3: floor-settle raids whose garrison never opened -------------------------------------
  (
  rcount=$(cast call "$RAID" 'raidCount()(uint64)' --rpc-url "$RPC" 2>/dev/null)
  if [[ "$rcount" =~ ^[0-9]+$ ]] && [ "$rcount" -ge 1 ]; then
    rstart=1; [ "$rcount" -gt "$WINDOW" ] && rstart=$((rcount - WINDOW + 1))
    for ((rid = rstart; rid <= rcount; rid++)); do
      # Raid fields: attackerDon targetDon committedAt revealedAt commitHash garrisonHash
      #              attackPower defensePower word state wordReceived garrisonRevealed
      r=$(cast call "$RAID" 'raids(uint64)(uint256,uint256,uint64,uint64,bytes32,bytes32,uint256,uint256,bytes32,uint8,bool,bool)' "$rid" --rpc-url "$RPC" 2>/dev/null) || continue
      state=$(echo "$r" | sed -n '10p' | awk '{print $1}')
      [ "$state" = "1" ] || continue                  # Revealed only
      wordrecv=$(echo "$r" | sed -n '11p')
      [ "$wordrecv" = "true" ] || continue
      grevealed=$(echo "$r" | sed -n '12p')
      [ "$grevealed" = "true" ] && continue
      revealedAt=$(echo "$r" | sed -n '4p' | awk '{print $1}')
      [[ "$revealedAt" =~ ^[0-9]+$ ]] || continue
      [ "$now" -lt $((revealedAt + GARRISON_TIMEOUT)) ] && continue
      if cast send "$RAID" 'floorSettle(uint64)' "$rid" --private-key "$PK" --rpc-url "$RPC" --gas-limit 1200000 >/dev/null 2>&1; then
        echo "$(date -u +%H:%M:%S) floor settled raid $rid"
      fi
    done
  fi

  ) &
  wait
  sleep "$INTERVAL"
done
