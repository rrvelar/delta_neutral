# Aerodrome Alerting And Watchdog

This document defines the read-only alert/watchdog foundation for Aerodrome production supervised mode. It does not enable live trading, does not close positions, does not add background automation, and does not replace the manually gated live emergency close procedure.

## Watchdog Task

Run the read-only watchdog:

```bash
bin/rails aerodrome:watchdog_check
FORMAT=json bin/rails aerodrome:watchdog_check
```

The task is read-only:

- no database writes.
- no orders.
- no close.
- no Hyperliquid execution.
- no transactions.

## Alert Events

Alerting should eventually cover:

- supervised run started.
- ETH position opened.
- WETH rebalance executed.
- failed WETH rebalance.
- unexpected USDC rebalance.
- final close started.
- final close success.
- final close unknown or failed.
- final mainnet ETH not nil.
- `manual_action_required=true`.
- Hyperliquid readback unavailable after retries.
- Aerodrome position sync failure streak.
- process crash or unexpected exit.
- env gate mismatch.

## Watchdog Checks

`aerodrome:watchdog_check` checks:

- safe env state.
- mainnet ETH position read-only.
- testnet ETH position read-only.
- latest observation summary.
- latest observation `manual_action_required`.
- latest observation `final_position`.
- failed WETH rows and acknowledgment status.
- unexpected successful USDC rebalances.
- latest PnL snapshot age.
- rewards status if enabled.
- fees status if enabled.
- production supervised readiness status.
- observation log directory.
- `APP_GIT_SHA`.

## Blockers

Blockers require operator action before another live window:

- mainnet ETH position exists while persistent env is safe/disabled.
- latest observation has `manual_action_required=true`.
- latest observation `final_position` is not nil.
- unacknowledged failed WETH after last close.
- successful USDC rebalance exists.
- `APP_GIT_SHA` unavailable in production.
- production supervised readiness has blockers.
- mainnet ETH position cannot be read.

## Warnings

Warnings should be reviewed before another run:

- latest PnL snapshot is stale.
- rewards unavailable.
- fees unavailable or warn for the known staked NFT fee-read case.
- acknowledged failed WETH exists.
- observation log missing when no live run is expected.
- testnet ETH readback unavailable.

## Stop And Close Escalation

Stop live operation and escalate if any blocker appears during or after a supervised run.

Manual emergency close may be required when:

- mainnet ETH short remains open after a run.
- final close status is not `success`.
- final readback cannot confirm nil.
- `manual_action_required=true`.
- mainnet ETH short exceeds configured max.

The emergency close remains a separate live-order-capable task with manual gates. The watchdog does not close positions.

## Operator Response Checklist

1. Stop any active supervised run.
2. Run `bin/rails aerodrome:watchdog_check`.
3. Read mainnet ETH position independently.
4. If ETH remains open, use the manually gated live emergency close procedure.
5. Verify mainnet ETH nil.
6. Restore safe env defaults.
7. Preserve Rails logs and JSONL logs.
8. Record an incident note.
9. Do not start another live window until blockers are reviewed.

## Log Locations

Relevant logs:

- Rails logs: `log/production.log` or deployment-specific Rails log.
- Solid Queue/job logs in the same Rails log stream.
- observation JSONL: `storage/aerodrome_live_observation/*.jsonl`.
- VPS service logs: `systemd` journal if deployed under systemd.
- readiness/watchdog command output captured by the operator.

## Recommended Polling Intervals

For supervised mode:

- during live observation: watch logs continuously.
- watchdog check: every 5 minutes during a supervised window.
- readiness check: before and after each supervised window.
- post-run Hyperliquid readback: immediately after final close, then again after a short delay.

Do not run watchdog polling as live automation by default. A future scheduler must be approved separately.

## Future Alert Channels

Future integrations may include:

- email through existing Rails mail infrastructure.
- Telegram bot.
- local log tail.
- VPS `systemd` journal alerts.
- dashboard banner.

Any alert integration should be read-only and tested without live orders first.

## Future Live Window Blocking Rules

Do not start another live window if:

- watchdog status is `BLOCKED`.
- readiness status is `BLOCKED`.
- mainnet ETH readback is unavailable.
- mainnet ETH position is not nil.
- latest observation required manual action.
- latest observation did not confirm final nil position.
- unreviewed failed WETH rows exist.
- unexpected successful USDC rebalance exists.

Safe defaults remain disabled, paused, not approved, and testnet outside an explicitly approved supervised window.
