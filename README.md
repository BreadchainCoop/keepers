# keepers

Small container that calls permissionless maintenance functions on Bread contracts when they come due.

> **`near-hackathon` branch.** A temporary branch for the NEAR hackathon (1–14 Nov 2026). Its
> crontab runs only [`saving-circles-near`](jobs/saving-circles-near.sh), and it deploys as its own
> Coolify resource; the EVM jobs keep running from `main` on another host. Delete the branch and the
> resource after the hackathon.
>
> **What it does.** Every minute (demo circles can have 5-minute rounds, and `process_due` only
> deposits for the current round) it lists the active circles on the NEAR Saving Circles contract
> (`next_id`, `get_circles`), asks `get_due(circle_id)` for each, and calls the permissionless
> `process_due(circle_id)` when deposits or claims are listed
> ([saving-circles-near#23](https://github.com/BreadchainCoop/saving-circles-near/pull/23)). It attaches
> 300 TGas (unused gas is refunded), then reads the final outcome of every receipt to report
> `funds_deposited`, `funds_withdrawn`, `automated_deposit_failed` and `payout_failed`. A circle whose
> only due claims failed to pay out recently is skipped for 6h instead of retried every run.
> Underfunded members are reported (at most every 6h per circle) without sending a transaction.
>
> **Keeper key.** Use a function-call access key on the keeper account, limited to receiver
> `circles.bread-saving-circles.testnet` and method `process_due`, with a gas allowance (e.g. 1 NEAR).
> It can't move NEAR or call anything else. The job checks the key's receiver, methods and remaining
> allowance on every run.
>
> | Variable | Required | Purpose |
> |---|---|---|
> | `NEAR_KEEPER_ACCOUNT_ID` | yes | Keeper account, e.g. `keeper.bread-saving-circles.testnet`. Holds only gas money. |
> | `NEAR_KEEPER_PUBLIC_KEY` | yes | `ed25519:…` public key of the function-call key. |
> | `NEAR_KEEPER_PRIVATE_KEY` | yes, unless `DRY_RUN` | `ed25519:…` private key of that key. Secret. |
> | `SAVING_CIRCLES_NEAR_NETWORK` | no | `testnet` (default) or `mainnet`. |
> | `SAVING_CIRCLES_NEAR_CONTRACT` | no | Default `circles.bread-saving-circles.testnet` on testnet; required on mainnet. |
> | `SAVING_CIRCLES_NEAR_RPC_URLS` | no | Comma-separated RPCs for views and outcomes. Default FastNEAR, then `rpc.testnet.near.org`. Sends use near-cli-rs's built-in network config. |
> | `SAVING_CIRCLES_NEAR_HEALTHCHECK_URL` | no | healthchecks.io check (1 min period, about 10 min grace). |
> | `SAVING_CIRCLES_NEAR_MIN_BALANCE` | no | Low-balance alert for the keeper account. Default `2` NEAR. |
> | `SAVING_CIRCLES_NEAR_MIN_ALLOWANCE` | no | Low-allowance alert for the keeper key. Default `0.2` NEAR. |
> | `DISCORD_WEBHOOK_URL`, `DRY_RUN` | no | As below. |

## Jobs

| Job | Contract | Schedule |
|---|---|---|
| [`distribute-yield`](jobs/distribute-yield.sh) | Yield distributor on Gnosis, `0xeE95A62b749d8a2520E0128D9b3aCa241269024b` | Polled every 30 min |
| [`saving-circles gnosis`](jobs/saving-circles.sh) | AutomaticSavingCircles on Gnosis, `0xdbe5e71950614A9508655Ca157EeD0B3F4167d78` | Polled hourly |
| [`saving-circles celo`](jobs/saving-circles.sh) | AutomaticSavingCircles on Celo, `0x8c6e6849F488419cd2e9DBBb79A8e73B10c9Dd51` | Polled hourly |
| [`saving-circles sepolia`](jobs/saving-circles.sh) | AutomaticSavingCircles on Sepolia, `0xb75320178b00eabacafa00545f9d1ed90a5fc8ce` | Polled hourly |
| [`saving-circles polygon`](jobs/saving-circles.sh) | AutomaticSavingCircles on Polygon, `0x8c6e6849F488419cd2e9DBBb79A8e73B10c9Dd51` | Polled hourly |

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
- alerts if the executor balance is below the per-network minimum (0.2 xDAI, 1 CELO, 0.2 ETH, 5 POL)
- sends with a gas limit of 400% of the estimate (`SAVING_CIRCLES_GAS_LIMIT_MULTIPLIER_PCT`), and refuses anything above `SAVING_CIRCLES_MAX_GAS_LIMIT` (3M); batch cost grows with circle size
- reports members whose deposit or claim failed inside an otherwise successful batch (`AutomatedDepositFailed` / `AutomatedClaimFailed`), and alerts separately when the reason is empty
- still runs claims when the deposit batch fails, then fails the run if either did

The headroom is large on purpose. Each member runs inside a try/catch, so `eth_estimateGas` returns a
limit at which the batch succeeds but a member's call runs out of gas and is only logged as failed;
on Gnosis a one-member deposit estimated ~300k but needed ~400k. On Sepolia a one-member deposit
estimated ~368k and needed over ~460k, and a two-member deposit estimated ~493k: at the old 200%
default (985k) the second member's `depositFor` ran out of gas, while 1.1M was enough. Unused gas is
not charged.

All four networks share one executor wallet, so `SAVING_CIRCLES_EXECUTOR_PRIVATE_KEY` must be
`automationExecutor` on each contract; a network where it isn't fails (and alerts) every run.

#### Sepolia (testnet)

AutomaticSavingCircles on Sepolia, `0xb75320178b00eabacafa00545f9d1ed90a5fc8ce`, is the contract the
Stacks frontend (`app-stacks`) uses on testnet.

#### Polygon

AutomaticSavingCircles on Polygon has the same address as on Celo (the deployer was at the same nonce),
but it is a separate contract with its own state. `polygon-rpc.com` requires an API key and publicnode
refuses receipt lookups without a token, so set `SAVING_CIRCLES_POLYGON_RPC_URLS` to a keyed RPC
(Alchemy / Infura); the default is `polygon.drpc.org`.

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
| `SAVING_CIRCLES_{GNOSIS,CELO,SEPOLIA,POLYGON}_RPC_URLS` | no | Comma-separated RPC endpoints per network, tried in order. Default to public RPCs; use a keyed one for Polygon. |
| `SAVING_CIRCLES_{GNOSIS,CELO,SEPOLIA,POLYGON}_HEALTHCHECK_URL` | no | One check per network (period 1h, about 1h grace). No fallback to `HEALTHCHECK_URL`, so `distribute-yield` pings can't mask a dead job. |
| `SAVING_CIRCLES_{GNOSIS,CELO,SEPOLIA,POLYGON}_ADDRESS` | no | Override the AutomaticSavingCircles contract per network. |
| `SAVING_CIRCLES_{GNOSIS,CELO,SEPOLIA,POLYGON}_MIN_BALANCE` | no | Low-balance alert threshold per network. Default `0.2` xDAI, `1` CELO, `0.2` ETH, `5` POL. |
| `SAVING_CIRCLES_GAS_LIMIT_MULTIPLIER_PCT` | no | Gas limit as a percentage of the estimate. Default `400`. |
| `SAVING_CIRCLES_MAX_GAS_LIMIT` | no | Refuse to send a batch whose gas limit exceeds this. Default `3000000`. |

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
