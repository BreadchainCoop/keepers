# Shared helpers for keeper jobs. Source from a job after setting JOB.

: "${JOB:?JOB must be set before sourcing common.sh}"
RPC_URLS=${RPC_URLS:-https://rpc.gnosischain.com,https://gnosis-rpc.publicnode.com}
ALERT_COOLDOWN_SECONDS=${ALERT_COOLDOWN_SECONDS:-21600}
STATE_DIR=${STATE_DIR:-/tmp/keepers}
EXPLORER_TX_URL=${EXPLORER_TX_URL:-https://gnosisscan.io/tx/}
mkdir -p "$STATE_DIR"

log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$JOB" "$*" >&2; }

# First RPC that answers, so one provider outage doesn't stall a job.
pick_rpc() {
  local url
  for url in ${RPC_URLS//,/ }; do
    if cast block-number --rpc-url "$url" --rpc-timeout 15 >/dev/null 2>&1; then
      echo "$url"
      return 0
    fi
    log "RPC unreachable: $url"
  done
  return 1
}

notify() {
  [ -n "${DISCORD_WEBHOOK_URL:-}" ] || return 0
  curl -fsS -m 15 -H 'Content-Type: application/json' \
    -d "$(jq -n --arg c "$1" '{content: $c}')" "$DISCORD_WEBHOOK_URL" >/dev/null \
    || log "Discord webhook failed"
}

# A failing job runs every tick; the cooldown keeps one problem from becoming a flood.
alert() {
  local key=$1 message=$2 stamp="$STATE_DIR/$JOB.$1.alerted" now
  now=$(date +%s)
  if [ -f "$stamp" ] && [ $((now - $(cat "$stamp"))) -lt "$ALERT_COOLDOWN_SECONDS" ]; then
    return 0
  fi
  echo "$now" > "$stamp"
  notify ":rotating_light: **$JOB**: $message"
}

clear_alert() { rm -f "$STATE_DIR/$JOB.$1.alerted"; }

# Dead-man's switch: the monitor alerts when pings stop, which catches a dead container.
ping_health() {
  [ -n "${HEALTHCHECK_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "${HEALTHCHECK_URL}${1:-}" || log "healthcheck ping failed"
}

fail() {
  log "ERROR: $1"
  alert failed "$1"
  ping_health /fail
  exit 1
}
