#!/usr/bin/env bash
# Runs the deposits and claims that AutomaticSavingCircles reports as due on one network.
# Usage: saving-circles.sh <gnosis|celo>
set -euo pipefail

NETWORK=${1:?usage: saving-circles.sh <gnosis|celo>}

case "$NETWORK" in
  gnosis)
    PREFIX=SAVING_CIRCLES_GNOSIS
    DEFAULT_CONTRACT=0xdbe5e71950614A9508655Ca157EeD0B3F4167d78
    DEFAULT_RPC_URLS=https://rpc.gnosischain.com,https://gnosis-rpc.publicnode.com
    DEFAULT_EXPLORER_TX_URL=https://gnosisscan.io/tx/
    DEFAULT_MIN_BALANCE=0.2
    SYMBOL=xDAI
    ;;
  celo)
    PREFIX=SAVING_CIRCLES_CELO
    DEFAULT_CONTRACT=0x8c6e6849F488419cd2e9DBBb79A8e73B10c9Dd51
    DEFAULT_RPC_URLS=https://forno.celo.org,https://celo-rpc.publicnode.com
    DEFAULT_EXPLORER_TX_URL=https://celoscan.io/tx/
    DEFAULT_MIN_BALANCE=1
    SYMBOL=CELO
    ;;
  *)
    echo "unsupported network: $NETWORK" >&2
    exit 2
    ;;
esac

# Per-network settings override the Gnosis defaults in common.sh.
rpc_urls_var=${PREFIX}_RPC_URLS
contract_var=${PREFIX}_ADDRESS
min_balance_var=${PREFIX}_MIN_BALANCE
healthcheck_var=${PREFIX}_HEALTHCHECK_URL
RPC_URLS=${!rpc_urls_var:-$DEFAULT_RPC_URLS}
EXPLORER_TX_URL=$DEFAULT_EXPLORER_TX_URL
# One check per network and no fallback to HEALTHCHECK_URL: another job's or network's success ping
# would otherwise mark this one healthy.
HEALTHCHECK_URL=${!healthcheck_var:-}

JOB=saving-circles-$NETWORK
. "$(dirname "$0")/../lib/common.sh"

[ -n "${SAVING_CIRCLES_EXECUTOR_PRIVATE_KEY:-}" ] || fail "SAVING_CIRCLES_EXECUTOR_PRIVATE_KEY is not set."
CONTRACT=${!contract_var:-$DEFAULT_CONTRACT}
MIN_BALANCE=${!min_balance_var:-$DEFAULT_MIN_BALANCE}
# The batch wraps each member in try/catch, so eth_estimateGas finds a limit where the batch succeeds but
# a member's inner call runs out of gas and is silently recorded as failed. On Gnosis a 1-member deposit
# estimates ~300k but needs ~400k. Unused gas is not charged, so keep wide headroom.
GAS_LIMIT_MULTIPLIER_PCT=${SAVING_CIRCLES_GAS_LIMIT_MULTIPLIER_PCT:-200}
# Batch cost grows with circle size; refuse to send anything estimated above this.
MAX_GAS_LIMIT=${SAVING_CIRCLES_MAX_GAS_LIMIT:-3000000}
# Emitted per member when one deposit or claim inside a batch reverts; the batch itself still succeeds.
# An empty reason usually means the member's call ran out of gas.
DEPOSIT_FAILED_TOPIC=0xe02b8c1677b1dde89011d18ca371f4f209efc5c302979e98f4c6e9716c91b836
CLAIM_FAILED_TOPIC=0xb9a339b2cf3a8502be61372ea29041d145f88f72022f37353ac667869766cb2b

rpc=$(pick_rpc) || fail "no RPC endpoint reachable (${RPC_URLS})"

keeper=$(cast wallet address --private-key "$SAVING_CIRCLES_EXECUTOR_PRIVATE_KEY") \
  || fail "SAVING_CIRCLES_EXECUTOR_PRIVATE_KEY is not a valid private key."

# Only automationExecutor may call the batch functions, so a mismatch means every send would revert.
executor=$(cast call "$CONTRACT" "automationExecutor()(address)" --rpc-url "$rpc" 2>&1) \
  || fail "reading automationExecutor failed: $(head -c 500 <<<"$executor")"
if [ "$(tr '[:upper:]' '[:lower:]' <<<"$executor")" != "$(tr '[:upper:]' '[:lower:]' <<<"$keeper")" ]; then
  if [ -n "${DRY_RUN:-}" ]; then
    log "DRY_RUN: keeper $keeper is not automationExecutor ($executor); sends would revert"
  else
    fail "keeper \`$keeper\` is not automationExecutor on \`$CONTRACT\` (executor is \`$executor\`)."
  fi
fi

balance=$(cast balance "$keeper" --ether --rpc-url "$rpc" 2>&1) \
  || fail "reading keeper balance failed: $(head -c 500 <<<"$balance")"
if awk -v b="$balance" -v m="$MIN_BALANCE" 'BEGIN { exit !(b < m) }'; then
  alert low-balance "keeper \`$keeper\` has $balance $SYMBOL (below $MIN_BALANCE). Top it up."
else
  clear_alert low-balance
fi

errors=()

# Records instead of exiting so a failed deposit batch doesn't also hold back claims.
checker_error() {
  log "ERROR: $1"
  errors+=("$1")
}

run_checker() {
  local checker=$1 failed_topic=$2 result can_exec payload gas gas_limit out tx failures empty_reason

  result=$(cast call "$CONTRACT" "$checker()(bool,bytes)" --rpc-url "$rpc" 2>&1) \
    || { checker_error "$checker: call failed: $(head -c 500 <<<"$result")"; return 0; }
  can_exec=$(sed -n 1p <<<"$result")
  payload=$(sed -n 2p <<<"$result")

  if [ "$can_exec" != true ]; then
    log "$checker: not due"
    return 0
  fi
  if [ "$payload" = 0x ]; then
    checker_error "$checker returned canExec with an empty payload."
    return 0
  fi

  gas=$(cast estimate "$CONTRACT" "$payload" --from "$keeper" --rpc-url "$rpc" 2>&1) \
    || { checker_error "$checker: gas estimation failed: $(head -c 500 <<<"$gas")"; return 0; }
  gas_limit=$((gas * GAS_LIMIT_MULTIPLIER_PCT / 100))
  if [ "$gas_limit" -gt "$MAX_GAS_LIMIT" ]; then
    checker_error "$checker: gas limit $gas_limit (estimate $gas) exceeds SAVING_CIRCLES_MAX_GAS_LIMIT $MAX_GAS_LIMIT."
    return 0
  fi

  if [ -n "${DRY_RUN:-}" ]; then
    log "DRY_RUN: $checker would send ${payload:0:10} with gas limit $gas_limit (estimate $gas)"
    return 0
  fi

  if ! out=$(cast send "$CONTRACT" "$payload" --private-key "$SAVING_CIRCLES_EXECUTOR_PRIVATE_KEY" \
      --rpc-url "$rpc" --gas-limit "$gas_limit" --timeout 300 --json 2>&1) \
    || [ "$(jq -r '.status' <<<"$out" 2>/dev/null)" != 0x1 ]; then
    checker_error "$checker: execution failed: $(head -c 500 <<<"$out")"
    return 0
  fi

  tx=$(jq -r '.transactionHash' <<<"$out")
  failures=$(jq --arg c "$CONTRACT" --arg t "$failed_topic" \
    '[.logs[] | select((.address | ascii_downcase) == ($c | ascii_downcase) and .topics[0] == $t)]' <<<"$out")
  # abi.encode(bytes("")): offset 0x20, length 0.
  empty_reason=$(jq --arg e "0x$(printf '%064x%064x' 32 0)" '[.[] | select(.data == $e)] | length' <<<"$failures")
  failures=$(jq length <<<"$failures")
  log "$checker: executed in $tx ($failures member failures, $empty_reason with empty reason)"

  if [ "$empty_reason" -gt 0 ]; then
    alert out-of-gas "$checker batch ran but $empty_reason member call(s) reverted with no reason, likely out of gas. Raise SAVING_CIRCLES_GAS_LIMIT_MULTIPLIER_PCT: ${EXPLORER_TX_URL}${tx}"
  elif [ "$failures" -gt 0 ]; then
    notify ":warning: Saving Circles on $NETWORK: $checker batch ran but $failures member(s) failed: ${EXPLORER_TX_URL}${tx}"
  else
    notify ":bread: Saving Circles on $NETWORK: $checker batch executed: ${EXPLORER_TX_URL}${tx}"
  fi
}

run_checker depositChecker "$DEPOSIT_FAILED_TOPIC"
run_checker claimChecker "$CLAIM_FAILED_TOPIC"

if [ "${#errors[@]}" -gt 0 ]; then
  fail "$(printf '%s\n' "${errors[@]}")"
fi
clear_alert failed
ping_health
