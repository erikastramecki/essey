#!/bin/bash
# Runs check-liveness-keeper.mjs and pages on ANY non-zero exit, including 2 (bad config): a
# supervisor that cannot run is not a quieter supervisor. See RUNBOOK, "Schedule the check".
set -uo pipefail

# Against the script, not the caller (9b6d047): launchd sets WorkingDirectory, a human does not.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$RH_DIR/.keeper-state"
ALERT="$STATE_DIR/liveness-pager.alert"
mkdir -p "$STATE_DIR"

ENV_FILE="${LIVENESS_PAGER_ENV:-$(cd "$RH_DIR/.." && pwd)/.env.liveness-pager}"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$(cd "$RH_DIR" && node keeper/check-liveness-keeper.mjs 2>&1)"
code=$?
printf '%s\n%s\n' "$STAMP" "$out"

if [ "$code" -eq 0 ]; then
  rm -f "$ALERT"
  exit 0
fi

# Durable before notified: the file outlives a missed banner and a webhook outage.
printf '%s  check-liveness-keeper.mjs exit %s\n%s\n' "$STAMP" "$code" "$out" > "$ALERT"

# UNANCHORED: keeper-health.mjs:66 prefixes per-market findings with the token address, so
# `^UNOBSERVED` matches nothing. Plain `FEED DARK` is absent on purpose — it is non-fatal.
summary="$(printf '%s' "$out" | grep -E 'NEVER BEAT|STALE BEAT|LIQUIDATIONS OFF|NO MARKETS|SCAN DISAGREES|LIST STALE|UNCORROBORATED|UNOBSERVED|PREMATURE|BREAKER BLIND|FEED BROKEN|FEED DARK TOO LONG|LIVENESS KEEPER: NOT WORKING' | head -6)"
[ -n "$summary" ] || summary="$(printf '%s' "$out" | head -3)"
body="ESSEY liveness keeper NOT WORKING (exit $code) at $STAMP
$summary"

paged=0
if [ -n "${PAGER_WEBHOOK_URL:-}" ]; then
  payload="$(printf '%s' "$body" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify({text:s})))')"
  # --fail: a 404 from a revoked webhook is an undelivered page, not a delivered one.
  if printf '%s' "$payload" | curl -sS --fail --max-time 20 -X POST \
      -H 'Content-Type: application/json' --data-binary @- "$PAGER_WEBHOOK_URL" >/dev/null; then
    paged=1
  else
    printf 'PAGE UNDELIVERED  webhook POST failed; the alert is in %s\n' "$ALERT"
  fi
fi

command -v osascript >/dev/null 2>&1 && \
  osascript -e "display notification \"$(printf '%s' "$summary" | head -1)\" with title \"ESSEY liveness keeper NOT WORKING\"" >/dev/null 2>&1

if [ "$paged" -eq 0 ]; then
  printf 'NO PAGE SENT  PAGER_WEBHOOK_URL is unset or the POST failed (env file: %s).\n' "$ENV_FILE"
  printf '              This unit is NOT paging anyone. Configure it or stop trusting it.\n'
fi
exit "$code"
