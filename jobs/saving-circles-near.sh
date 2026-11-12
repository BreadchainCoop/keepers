#!/usr/bin/env bash
# Runs automatic deposits and claims on the NEAR Saving Circles contract
# (BreadchainCoop/saving-circles-near, `process_due` / `get_due`): for every active circle,
# calls process_due when get_due lists deposits or claims.
# Usage: saving-circles-near.sh
set -euo pipefail

NETWORK=${SAVING_CIRCLES_NEAR_NETWORK:-testnet}
case "$NETWORK" in
  testnet)
    DEFAULT_CONTRACT=circles.bread-saving-circles.testnet
    DEFAULT_RPC_URLS=https://test.rpc.fastnear.com,https://rpc.testnet.near.org
    DEFAULT_EXPLORER_TX_URL=https://testnet.nearblocks.io/txns/
    ;;
  mainnet)
    DEFAULT_CONTRACT=
    DEFAULT_RPC_URLS=https://free.rpc.fastnear.com,https://rpc.mainnet.near.org
    DEFAULT_EXPLORER_TX_URL=https://nearblocks.io/txns/
    ;;
  *)
    echo "unsupported SAVING_CIRCLES_NEAR_NETWORK: $NETWORK" >&2
    exit 2
    ;;
esac

# Override the Gnosis defaults in common.sh. No fallback to HEALTHCHECK_URL, so another job's
# success ping can't mark this one healthy.
RPC_URLS=${SAVING_CIRCLES_NEAR_RPC_URLS:-$DEFAULT_RPC_URLS}
EXPLORER_TX_URL=$DEFAULT_EXPLORER_TX_URL
HEALTHCHECK_URL=${SAVING_CIRCLES_NEAR_HEALTHCHECK_URL:-}

JOB=saving-circles-near-$NETWORK
# shellcheck source=lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

CONTRACT=${SAVING_CIRCLES_NEAR_CONTRACT:-$DEFAULT_CONTRACT}
MIN_BALANCE=${SAVING_CIRCLES_NEAR_MIN_BALANCE:-2}
MIN_ALLOWANCE=${SAVING_CIRCLES_NEAR_MIN_ALLOWANCE:-0.2}
# get_circles loads every circle in the page; keep pages well inside the view gas limit.
PAGE_SIZE=${SAVING_CIRCLES_NEAR_PAGE_SIZE:-20}
# Unused prepaid gas is refunded on NEAR, so always attach the maximum. That avoids the EVM
# failure mode where an estimate fits the call but not every member inside it.
GAS='300.0 Tgas'

[ -n "$CONTRACT" ] || fail "SAVING_CIRCLES_NEAR_CONTRACT is not set."
[ -n "${NEAR_KEEPER_ACCOUNT_ID:-}" ] || fail "NEAR_KEEPER_ACCOUNT_ID is not set."
[ -n "${NEAR_KEEPER_PUBLIC_KEY:-}" ] || fail "NEAR_KEEPER_PUBLIC_KEY is not set."
if [ -z "${DRY_RUN:-}" ] && [ -z "${NEAR_KEEPER_PRIVATE_KEY:-}" ]; then
  fail "NEAR_KEEPER_PRIVATE_KEY is not set."
fi

near_pick_rpc() {
  local url
  for url in ${RPC_URLS//,/ }; do
    if curl -fsS -m 15 -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":"keeper","method":"status","params":[]}' "$url" 2>/dev/null \
        | jq -e '.result.chain_id' >/dev/null 2>&1; then
      echo "$url"
      return 0
    fi
    log "RPC unreachable: $url"
  done
  return 1
}

rpc=$(near_pick_rpc) || fail "no RPC endpoint reachable (${RPC_URLS})"

# JSON-RPC call; prints the whole response. RPC errors come back as HTTP 200 with `.error`.
rpc_call() { # method params-json
  curl -fsS -m 30 -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc: "2.0", id: "keeper", method: $m, params: $p}')" \
    "$rpc"
}

query() { # params-json; prints .result or fails
  local out
  out=$(rpc_call query "$1" 2>&1) || { echo "$out"; return 1; }
  jq -e '.result and (.result.error | not)' <<<"$out" >/dev/null 2>&1 || { echo "$out"; return 1; }
  jq -c '.result' <<<"$out"
}

# Calls a view method on the contract; prints its JSON return value.
view() { # method args-json
  local out
  out=$(query "$(jq -nc --arg c "$CONTRACT" --arg m "$1" --arg a "$(printf '%s' "$2" | base64 -w0)" \
    '{request_type: "call_function", finality: "final", account_id: $c, method_name: $m, args_base64: $a}')") \
    || { echo "$out"; return 1; }
  jq -r '.result | implode' <<<"$out"
}

near_amount() { awk -v y="$1" 'BEGIN { printf "%.4f", y / 1e24 }'; }
below() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

account=$(query "$(jq -nc --arg a "$NEAR_KEEPER_ACCOUNT_ID" \
  '{request_type: "view_account", finality: "final", account_id: $a}')") \
  || fail "reading keeper account \`$NEAR_KEEPER_ACCOUNT_ID\` failed: $(head -c 500 <<<"$account")"
balance=$(near_amount "$(jq -r '.amount' <<<"$account")")
if below "$balance" "$MIN_BALANCE"; then
  alert low-balance "keeper \`$NEAR_KEEPER_ACCOUNT_ID\` has $balance NEAR (below $MIN_BALANCE). Top it up."
else
  clear_alert low-balance
fi

# The key should be a function-call key limited to process_due on the contract; with any other
# receiver or method list every send would be rejected.
key=$(query "$(jq -nc --arg a "$NEAR_KEEPER_ACCOUNT_ID" --arg k "$NEAR_KEEPER_PUBLIC_KEY" \
  '{request_type: "view_access_key", finality: "final", account_id: $a, public_key: $k}')") \
  || fail "NEAR_KEEPER_PUBLIC_KEY is not an access key of \`$NEAR_KEEPER_ACCOUNT_ID\`: $(head -c 500 <<<"$key")"
if [ "$(jq -r '.permission' <<<"$key")" = FullAccess ]; then
  log "WARNING: keeper key is a full-access key; a function-call key limited to process_due is safer"
else
  receiver=$(jq -r '.permission.FunctionCall.receiver_id' <<<"$key")
  [ "$receiver" = "$CONTRACT" ] \
    || fail "keeper key may only call \`$receiver\`, not \`$CONTRACT\`."
  jq -e '.permission.FunctionCall.method_names | length == 0 or index("process_due")' <<<"$key" >/dev/null \
    || fail "keeper key may not call process_due (methods: $(jq -c '.permission.FunctionCall.method_names' <<<"$key"))."
  allowance=$(jq -r '.permission.FunctionCall.allowance // empty' <<<"$key")
  if [ -n "$allowance" ] && below "$(near_amount "$allowance")" "$MIN_ALLOWANCE"; then
    alert low-allowance "keeper key has $(near_amount "$allowance") NEAR of gas allowance left (below $MIN_ALLOWANCE). Replace it with a new function-call key."
  else
    clear_alert low-allowance
  fi
fi

keyfile=
if [ -z "${DRY_RUN:-}" ]; then
  # Read from the environment by jq, so the private key never appears in a process's arguments.
  keyfile=$(umask 077 && mktemp)
  trap 'rm -f "$keyfile"' EXIT
  jq -n --arg a "$NEAR_KEEPER_ACCOUNT_ID" --arg k "$NEAR_KEEPER_PUBLIC_KEY" \
    '{account_id: $a, public_key: $k, private_key: env.NEAR_KEEPER_PRIVATE_KEY}' > "$keyfile"
fi

errors=()

# Records instead of exiting so one circle's failure doesn't hold back the others.
circle_error() {
  log "ERROR: $1"
  errors+=("$1")
}

# Members whose payout failed recently, per circle. A failed payout is restored, so get_due keeps
# listing it; without this the keeper would retry (and pay gas) every run until it succeeds.
failed_payouts_file() { echo "$STATE_DIR/$JOB.payout-failed.$1"; }

recently_failed_only() { # circle-id due-json
  local file now
  file=$(failed_payouts_file "$1")
  [ -f "$file" ] || return 1
  now=$(date +%s)
  [ $((now - $(stat -c %Y "$file"))) -lt "$ALERT_COOLDOWN_SECONDS" ] || return 1
  jq -e --slurpfile failed "$file" \
    '(.deposits | length) == 0 and (.claims - $failed[0] | length) == 0' <<<"$2" >/dev/null
}

process_circle() {
  local id=$1 due deposits claims underfunded out tx status attempt events
  local deposited withdrawn deposit_failed payout_failed

  due=$(view get_due "$(jq -nc --arg id "$id" '{circle_id: $id}')") \
    || { circle_error "circle $id: get_due failed: $(head -c 300 <<<"$due")"; return 0; }
  deposits=$(jq '.deposits | length' <<<"$due")
  claims=$(jq '.claims | length' <<<"$due")
  underfunded=$(jq '.underfunded | length' <<<"$due")

  if [ "$underfunded" -gt 0 ]; then
    alert "underfunded-$id" "circle $id: $underfunded member(s) with automatic deposits on can't cover this round: $(jq -r '.underfunded | join(", ")' <<<"$due")"
  else
    clear_alert "underfunded-$id"
  fi

  if [ "$deposits" -eq 0 ] && [ "$claims" -eq 0 ]; then
    log "circle $id: not due"
    return 0
  fi
  if recently_failed_only "$id" "$due"; then
    log "circle $id: only claims whose payout failed recently are due; skipping"
    return 0
  fi
  if [ -n "${DRY_RUN:-}" ]; then
    log "DRY_RUN: circle $id would run process_due ($deposits deposit(s), $claims claim(s))"
    return 0
  fi

  if ! out=$(near contract call-function as-transaction "$CONTRACT" process_due \
      json-args "$(jq -nc --arg id "$id" '{circle_id: $id}')" \
      prepaid-gas "$GAS" attached-deposit '0 NEAR' sign-as "$NEAR_KEEPER_ACCOUNT_ID" \
      network-config "$NETWORK" sign-with-access-key-file "$keyfile" send 2>&1); then
    circle_error "circle $id: process_due failed: $(tail -c 500 <<<"$out")"
    return 0
  fi
  tx=$(grep -oE '(Transaction ID: |/transactions/|/txns/)[1-9A-HJ-NP-Za-km-z]{43,44}' <<<"$out" \
    | grep -oE '[1-9A-HJ-NP-Za-km-z]{43,44}$' | head -n1 || true)
  if [ -z "$tx" ]; then
    circle_error "circle $id: process_due sent, but no transaction hash in the CLI output: $(tail -c 500 <<<"$out")"
    return 0
  fi

  # Payouts are detached promises, so wait for every receipt, not only process_due's own.
  status=
  for attempt in 1 2 3 4 5; do
    if status=$(rpc_call tx "$(jq -nc --arg h "$tx" --arg s "$NEAR_KEEPER_ACCOUNT_ID" \
          '{tx_hash: $h, sender_account_id: $s, wait_until: "FINAL"}')") \
        && jq -e '.result' <<<"$status" >/dev/null 2>&1; then
      break
    fi
    log "circle $id: waiting for $tx to finalize (attempt $attempt)"
    status=
  done
  if [ -z "$status" ]; then
    circle_error "circle $id: could not read the outcome of ${EXPLORER_TX_URL}${tx}"
    return 0
  fi
  if jq -e '.result.status | has("Failure")' <<<"$status" >/dev/null; then
    circle_error "circle $id: process_due failed: ${EXPLORER_TX_URL}${tx} $(jq -c '.result.status.Failure' <<<"$status" | head -c 300)"
    return 0
  fi

  events=$(jq -c '[.result.receipts_outcome[].outcome.logs[]
      | select(startswith("EVENT_JSON:")) | ltrimstr("EVENT_JSON:") | fromjson?
      | select(.standard == "saving_circles")
      | .event as $e | (.data | if type == "array" then .[] else . end) | . + {event: $e}]' <<<"$status")
  count() { jq --arg e "$1" '[.[] | select(.event == $e)] | length' <<<"$events"; }
  deposited=$(count funds_deposited)
  withdrawn=$(count funds_withdrawn)
  deposit_failed=$(count automated_deposit_failed)
  payout_failed=$(count payout_failed)
  log "circle $id: executed in $tx ($deposited deposit(s), $withdrawn payout(s), $deposit_failed underfunded, $payout_failed payout(s) failed)"

  if [ "$payout_failed" -gt 0 ]; then
    jq -c '[.[] | select(.event == "payout_failed") | .member]' <<<"$events" > "$(failed_payouts_file "$id")"
    alert "payout-failed-$id" "circle $id: $payout_failed payout(s) failed, likely because the member isn't registered with the token (storage_deposit): ${EXPLORER_TX_URL}${tx}"
  else
    rm -f "$(failed_payouts_file "$id")"
    clear_alert "payout-failed-$id"
  fi
  notify ":bread: Saving Circles on NEAR $NETWORK: circle $id: $deposited deposit(s), $withdrawn payout(s): ${EXPLORER_TX_URL}${tx}"
}

next_id=$(view next_id '{}') || fail "reading next_id failed: $(head -c 500 <<<"$next_id")"
next_id=$(jq -r '.' <<<"$next_id")

active=()
for ((start = 0; start < next_id; start += PAGE_SIZE)); do
  args=$(jq -nc --argjson s "$start" --argjson n "$next_id" --argjson p "$PAGE_SIZE" \
    '{circle_ids: [range($s; [$s + $p, $n] | min) | tostring]}')
  if ! page=$(view get_circles "$args"); then
    circle_error "get_circles from $start failed: $(head -c 300 <<<"$page")"
    continue
  fi
  while read -r id; do
    [ -n "$id" ] && active+=("$id")
  done < <(jq -r '.[] | select(. != null and .active and (.decommissioned | not)) | .id' <<<"$page")
done
log "$next_id circle(s), ${#active[@]} active"

for id in "${active[@]}"; do
  process_circle "$id"
done

if [ "${#errors[@]}" -gt 0 ]; then
  fail "$(printf '%s\n' "${errors[@]}")"
fi
clear_alert failed
ping_health
