# keepers

Small container that calls permissionless maintenance functions on Bread contracts when they come due.

## Jobs

| Job | Contract | Schedule |
|---|---|---|
| [`distribute-yield`](jobs/distribute-yield.sh) | Yield distributor on Gnosis, `0xeE95A62b749d8a2520E0128D9b3aCa241269024b` | Polled every 30 min |
| [`saving-circles gnosis`](jobs/saving-circles.sh) | AutomaticSavingCircles on Gnosis, `0xdbe5e71950614A9508655Ca157EeD0B3F4167d78` | Daily, 00:00 UTC |
| [`saving-circles celo`](jobs/saving-circles.sh) | AutomaticSavingCircles on Celo, `0x8c6e6849F488419cd2e9DBBb79A8e73B10c9Dd51` | Daily, 00:00 UTC |

### distribute-yield

The contract tracks its own cycle (`cycleLength`, 518400 blocks, about 30 days) and exposes
`resolveYieldDistribution()`. The job sends `distributeYield()` only when the resolver says the
cycle is ready.

Because of this, a missed or failed run is just retried on the next tick, and the contract rejects a
second call in the same cycle. Prompt execution still matters: the next cycle is counted from the
block of the actual call, so every delay pushes all later distributions back by the same amount.

Each run:
- picks the first reachable RPC from `RPC_URLS`
- alerts if the keeper balance is below `MIN_BALANCE_XDAI`
- alerts if the cycle ended more than ~6h ago but the resolver still says not ready
- sends with a gas limit of 130% of the estimate
- treats "another caller distributed first" as success

### saving-circles

Saving Circles `v1.1.0` automates member deposits and claims through
`AutomaticSavingCircles`. Its `depositChecker()` and `claimChecker()` return whether a batch is due
and the exact calldata to send. The job sends that calldata as-is, deposits first, then claims.

Unlike `distribute-yield`, the batch functions are **not permissionless**: only the contract's
`automationExecutor` may call them. That role can only trigger automation that is already due; it
cannot move funds anywhere else. Still, use a dedicated wallet, not `KEEPER_PRIVATE_KEY`, and wire it
from the contract owner:

```sh
cast send <AutomaticSavingCircles> 'setAutomationExecutor(address)' <executor-address> \
  --rpc-url <rpc> --private-key <owner-key>
```

Each run:
- fails (and alerts) if the executor wallet is not `automationExecutor`
- alerts if the executor balance is below the per-network minimum (0.2 xDAI, 1 CELO)
- sends with a gas limit of 200% of the estimate (`SAVING_CIRCLES_GAS_LIMIT_MULTIPLIER_PCT`), and refuses anything above `SAVING_CIRCLES_MAX_GAS_LIMIT` (3M); batch cost grows with circle size
- reports members whose deposit or claim failed inside an otherwise successful batch (`AutomatedDepositFailed` / `AutomatedClaimFailed`), and alerts separately when the reason is empty

The headroom is large on purpose. Each member runs inside a try/catch, so `eth_estimateGas` returns a
limit at which the batch succeeds but a member's call runs out of gas and is only logged as failed;
on Gnosis a one-member deposit estimated ~300k but needed ~400k. Unused gas is not charged.

A missed or failed run is retried on the next tick: the checkers keep returning the work until it
is done.

## Configuration

See [`.env.example`](.env.example).

| Variable | Required | Purpose |
|---|---|---|
| `KEEPER_PRIVATE_KEY` | yes | Dedicated wallet that pays gas. It needs no role on any contract, so it should only ever hold gas money (about 1 xDAI lasts years). |
| `RPC_URLS` | no | Comma-separated RPC endpoints, tried in order. |
| `DISCORD_WEBHOOK_URL` | no | Gets a message for each successful distribution and for alerts (at most one per alert every 6h). |
| `HEALTHCHECK_URL` | no | Pinged on every run, with `/fail` on errors. Use a healthchecks.io check with a 30 min period and about 1h grace, so you hear about it if the container dies. |
| `MIN_BALANCE_XDAI` | no | Threshold for the low-balance alert. Default `0.2`. |
| `DRY_RUN` | no | `1` does everything except send the transaction. |
| `SAVING_CIRCLES_EXECUTOR_PRIVATE_KEY` | yes | Wallet set as `automationExecutor` on each AutomaticSavingCircles contract. Holds only gas money. |
| `SAVING_CIRCLES_GNOSIS_RPC_URLS`, `SAVING_CIRCLES_CELO_RPC_URLS` | no | Comma-separated RPC endpoints per network, tried in order. Default to public RPCs. |
| `SAVING_CIRCLES_HEALTHCHECK_URL` | no | Separate check for the daily runs (period 1 day). Falls back to `HEALTHCHECK_URL`. |

## Deploy

Deploy it as a Docker Compose resource built from this repository, with the variables above set as
secrets in the platform. It needs no ports, volumes or domain.

Keep it out of any deployment that runs untrusted code or LLM agents, so the key never shares an
environment with them.

## Test

Dry run against mainnet (read-only):

```sh
KEEPER_PRIVATE_KEY=0x... DRY_RUN=1 bash jobs/distribute-yield.sh
```

Saving Circles dry run:

```sh
SAVING_CIRCLES_EXECUTOR_PRIVATE_KEY=0x... DRY_RUN=1 bash jobs/saving-circles.sh gnosis
```

Real send against a local fork:

```sh
anvil --fork-url https://rpc.gnosischain.com --port 8547 &
cast rpc anvil_setBalance <keeper-address> 0xDE0B6B3A7640000 --rpc-url http://127.0.0.1:8547
KEEPER_PRIVATE_KEY=0x... RPC_URLS=http://127.0.0.1:8547 bash jobs/distribute-yield.sh
```

## Adding a job

1. Add `jobs/<name>.sh`.
2. Set `JOB=<name>` and source `lib/common.sh`, which provides `pick_rpc`, `alert`, `notify`, `ping_health` and `fail`.
3. Add a line to `crontab`.

Prefer polling the contract's own readiness check over counting time in cron.
