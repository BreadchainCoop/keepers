# keepers

Small container that calls permissionless maintenance functions on Bread contracts when they come due.

## Jobs

| Job | Contract | Schedule |
|---|---|---|
| [`distribute-yield`](jobs/distribute-yield.sh) | Yield distributor on Gnosis, `0xeE95A62b749d8a2520E0128D9b3aCa241269024b` | Polled every 30 min |

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
