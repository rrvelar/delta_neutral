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

## Watchdog Alert Messages

Run the read-only dry-run alert formatter:

```bash
bin/rails aerodrome:watchdog_alerts
FORMAT=json bin/rails aerodrome:watchdog_alerts
```

`aerodrome:watchdog_alerts` converts watchdog status, blockers, warnings, readback state, observation summary, and recommended next steps into an operator-friendly alert message. Default delivery is local dry-run output only:

```bash
AERODROME_ALERTS_ENABLED=false
AERODROME_ALERTS_DELIVERY=dry_run
AERODROME_ALERT_EMAIL_RECIPIENT=
AERODROME_ALERT_EMAIL_MIN_SEVERITY=warn
```

The alert task is read-only:

- no database writes.
- no orders.
- no close.
- no Hyperliquid execution.
- no transactions.
- no email or Telegram sends.

It does not close positions. If a blocker requires action, the operator must use the separate manually gated emergency close procedure or the Hyperliquid UI.

Email delivery is available only when explicitly gated:

- `AERODROME_ALERTS_ENABLED=true`
- `AERODROME_ALERTS_DELIVERY=email`
- `AERODROME_ALERT_EMAIL_RECIPIENT` is present
- alert severity is at or above `AERODROME_ALERT_EMAIL_MIN_SEVERITY`

Severity order is `pass < warn < blocked`; the recommended minimum severity is `warn`. SMTP must be configured separately through the existing Rails Action Mailer SMTP settings. Email alerts are still read-only: they do not close positions, open positions, or enable live operation.

Scheduled email alerts use deduplication and cooldown to avoid repeated identical messages:

- state file: `storage/aerodrome_watchdog_alerts/state.json`
- warning/pass cooldown default: `AERODROME_ALERT_EMAIL_COOLDOWN_SECONDS=1800`
- blocked repeat default: `AERODROME_ALERT_EMAIL_REPEAT_BLOCKED_SECONDS=300`
- fingerprint changes send immediately.
- severity escalation sends immediately.
- blocked alerts repeat more frequently than warnings.
- dry-run delivery does not write alert state.

Reset alert state only after operator review:

```bash
rm storage/aerodrome_watchdog_alerts/state.json
```

Resetting state can cause the next matching email alert to send again. It does not affect trading state.

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
- watchdog scheduler tick: every 5 minutes when explicitly configured by the operator.
- readiness check: before and after each supervised window.
- post-run Hyperliquid readback: immediately after final close, then again after a short delay.

Do not run watchdog polling as live automation by default. `bin/aerodrome-watchdog-tick` and `bin/rails aerodrome:watchdog_scheduler_check` are scheduler foundation tools only; they run watchdog alerts, do not start live observation, do not close positions, and do not call Hyperliquid execution methods. See `docs/AERODROME_WATCHDOG_SCHEDULER.md` for systemd/cron templates and operator response rules.

Production live runner V1 is separate from watchdog alerting. Watchdog tasks remain read-only and must not start `bin/rails aerodrome:production_live_run`, must not close positions, and must not approve leave-position-open operation. After every production live run, the operator must run `bin/rails aerodrome:production_live_status`; any `manual_action_required=true`, unknown readback, failed close, or unexpected USDC rebalance remains an alert/blocker condition.

The first Production Live Runner V1 run showed that a valid in-cap ETH hedge can be intentionally left open on clean duration completion. Generic safe-mode watchdog behavior still treats unexpected mainnet ETH as `BLOCKED`, which is correct outside an approved live period. The next alerting/watchdog stage should add approved-open-position monitoring so a known valid open ETH hedge can be monitored as intended state while still blocking cap breaches, failed WETH rows, USDC activity, stale approval, unknown readback, or manual-action logs.

Approved open position monitoring is now read-only watchdog context. It does not close positions and does not approve new live runs. It only suppresses the generic open-ETH blocker when the latest production live log proves `position_left_open=true`, final position confirmed, no manual action required, and the current ETH short remains within caps/tolerance. Any out-of-bounds, unknown, unconfirmed, manual-action, failed WETH, or USDC-success condition remains `BLOCKED`.

Production supervised readiness remains strict safe-mode evidence. When an approved-open ETH hedge is valid and in caps, the watchdog may suppress the readiness blocker that only says mainnet ETH is not nil, and it reports that suppression explicitly in `readiness_status`, `readiness_blockers`, `readiness_warnings`, and `readiness_blockers_suppressed_due_approved_open`. This is monitored state, not an emergency. Readiness blockers unrelated to the approved open ETH still make the watchdog `BLOCKED`.

`aerodrome:production_live_status` reports lock state as active, absent, or stale. A stale finished-run lock is a warning; verify no live process is running, inspect the latest log, and confirm current mainnet ETH state before manually removing `storage/aerodrome_production_live/run.lock`. Watchdog alerts do not remove locks and do not close positions.

## Future Alert Channels

Future integrations may include:

- email through existing Rails mail infrastructure.
- Telegram bot.
- local log tail.
- VPS `systemd` journal alerts.
- dashboard banner.

Any real alert integration should be read-only and tested without live orders first. The current implementation supports dry-run/local output and gated email delivery only. Telegram delivery remains future work.

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
