#!/usr/bin/env bash
# Calls distributeYield() on the yield distributor once its cycle has elapsed.
set -euo pipefail

JOB=distribute-yield
. "$(dirname "$0")/../lib/common.sh"

: "${KEEPER_PRIVATE_KEY:?KEEPER_PRIVATE_KEY is required}"
CONTRACT=${YIELD_DISTRIBUTOR_ADDRESS:-0xeE95A62b749d8a2520E0128D9b3aCa241269024b}
MIN_BALANCE_XDAI=${MIN_BALANCE_XDAI:-0.2}
# ~6h of Gnosis blocks past due with the resolver still saying no means something besides timing is blocking it.
STALL_ALERT_BLOCKS=${STALL_ALERT_BLOCKS:-4320}
GAS_LIMIT_MULTIPLIER_PCT=${GAS_LIMIT_MULTIPLIER_PCT:-130}

rpc=$(pick_rpc) || fail "no RPC endpoint reachable (${RPC_URLS})"

is_ready() {
  cast call "$CONTRACT" "resolveYieldDistribution()(bool,bytes)" --rpc-url "$rpc" | head -n1
}

keeper=$(cast wallet address --private-key "$KEEPER_PRIVATE_KEY")
balance=$(cast balance "$keeper" --ether --rpc-url "$rpc")
if awk -v b="$balance" -v m="$MIN_BALANCE_XDAI" 'BEGIN { exit !(b < m) }'; then
  alert low-balance "keeper \`$keeper\` has $balance xDAI (below $MIN_BALANCE_XDAI). Top it up."
else
  clear_alert low-balance
fi

current=$(cast block-number --rpc-url "$rpc")
last=$(cast call "$CONTRACT" "lastClaimedBlockNumber()(uint256)" --rpc-url "$rpc" | awk '{print $1}')
cycle=$(cast call "$CONTRACT" "cycleLength()(uint256)" --rpc-url "$rpc" | awk '{print $1}')
behind=$((current - last - cycle))

if [ "$(is_ready)" != true ]; then
  if [ "$behind" -gt "$STALL_ALERT_BLOCKS" ]; then
    alert stalled "cycle ended $behind blocks ago but resolveYieldDistribution() says not ready."
  else
    clear_alert stalled
    log "not due ($((-behind)) blocks to go)"
  fi
  ping_health
  exit 0
fi
clear_alert stalled

log "due ($behind blocks past cycle end), keeper $keeper, balance $balance xDAI"
gas=$(cast estimate "$CONTRACT" "distributeYield()" --from "$keeper" --rpc-url "$rpc")
gas_limit=$((gas * GAS_LIMIT_MULTIPLIER_PCT / 100))

if [ -n "${DRY_RUN:-}" ]; then
  log "DRY_RUN: would send distributeYield() with gas limit $gas_limit (estimate $gas)"
  ping_health
  exit 0
fi

if out=$(cast send "$CONTRACT" "distributeYield()" --private-key "$KEEPER_PRIVATE_KEY" \
    --rpc-url "$rpc" --gas-limit "$gas_limit" --timeout 300 --json 2>&1) \
  && [ "$(jq -r '.status' <<<"$out" 2>/dev/null)" = 0x1 ]; then
  tx=$(jq -r '.transactionHash' <<<"$out")
  log "distributed in $tx"
  clear_alert failed
  notify ":bread: Yield distributed: ${EXPLORER_TX_URL}${tx}"
  ping_health
  exit 0
fi

# Losing a race to another caller is success: the distribution happened.
if [ "$(is_ready)" != true ]; then
  log "distribution already done by another caller"
  ping_health
  exit 0
fi

fail "distributeYield() failed: $(head -c 500 <<<"$out")"
