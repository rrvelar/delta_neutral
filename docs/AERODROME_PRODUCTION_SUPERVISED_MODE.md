# Aerodrome Production Supervised Mode

This document defines the next operational stage after the successful 3-hour supervised live observation window. It is documentation and read-only readiness tooling guidance. It does not enable live trading, does not add unattended automation, and does not approve larger size.

## Definition

Production supervised mode is a manually approved, actively watched live operation window for the Aerodrome WETH/USDC hedge path. It uses the existing gated Aerodrome HedgeSyncJob path, existing HyperliquidService, and existing live emergency close tooling.

Production supervised mode is not:

- unattended 24/7 automation.
- a daemon that runs live by default.
- approval to scale size.
- approval to hedge USDC.
- permission to remove `AERODROME_HEDGE_PAUSED`, `AERODROME_HEDGE_ENABLED`, `AERODROME_LIVE_APPROVED`, or emergency close gates.

## Current Evidence

Local operator evidence shows:

- testnet open/rebalance/close passed.
- first mainnet micro-run passed.
- 15-minute and 30-minute live observations passed.
- a 1-hour observation exposed finalization/readback ambiguity.
- finalization hardening was implemented.
- 15-minute finalization retest passed.
- 3-hour supervised live observation passed.
- final mainnet ETH position was nil.
- persistent safe env was restored after each run.

This evidence supports planning production supervised mode. It does not approve unattended live operation.

## Safe Defaults

Persistent app env must remain safe unless a manually approved supervised window is actively running:

```text
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
HYPERLIQUID_TESTNET=true
```

Do not store seed phrases in env. Do not commit secrets. Prefer API-wallet operation over main wallet private keys where supported by the operator setup.

## Required Live Gates

Any supervised live window still requires explicit one-off live gates:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- the task-specific confirmation phrase.
- the task-specific close/leave-position gates.
- `AERODROME_MAX_LEVERAGE=1`
- task-specific max short ETH and max notional caps.
- live emergency close enabled.
- live emergency close confirmation phrase.
- live emergency close max ETH greater than or equal to max short ETH.

These gates are temporary for a supervised run. Restore safe defaults immediately after the run.

Cap tiers are task-specific. Live observation, production canary, and target-step test runs remain micro-capped at `0.02` ETH / `$50`. Production live runner V1 has a higher supervised production tier controlled by configurable hard ceilings: `AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH`, `AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD`, and `AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH`. Runtime caps remain separate through `AERODROME_MAX_SHORT_ETH`, `AERODROME_MAX_SHORT_NOTIONAL_USD`, and `AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH`; they must be configured and stay within the hard ceilings.

For the next larger supervised LP/hedge size, `AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH=1.5` is the intended hard ETH ceiling. This does not enable unattended operation or bypass manual gates.

## Required Preflight Sequence

Before a supervised production run:

1. Confirm `git status --short` is clean.
2. Run `bin/rake`.
3. Create a backup.
4. Confirm dashboard health: active Aerodrome position, current PnL snapshot, rewards/fees status, and latest rebalance history.
5. Run `bin/rails aerodrome:pre_live_check`.
6. Run `CHECK_HYPERLIQUID=true bin/rails aerodrome:live_preflight_check` in mainnet read-only mode.
7. Run `bin/rails aerodrome:production_supervised_readiness`.
8. Run `bin/rails aerodrome:watchdog_check`.
9. Confirm mainnet ETH position is nil.
10. Confirm testnet ETH position is nil.
11. Confirm latest observation JSONL ended with final position nil and `manual_action_required=false`.
12. Confirm live emergency close gates are ready but not persistently armed outside the supervised window.

Passing readiness is not permission to run live. A human operator must still explicitly approve the run.

## Required Backup Sequence

Before a run:

- create a database/application backup.
- record git SHA. Production container deployments should set `APP_GIT_SHA=$(git rev-parse --short HEAD)` at build/deploy time because `.git` may not exist inside the image.
- record env gate plan without secrets.
- record latest mainnet/testnet ETH readback.

After a run:

- create a post-run backup.
- archive the observation JSONL log.
- record final mainnet/testnet ETH readback.
- restore safe env defaults.

## Required Final Close Sequence

Every supervised run must end with close-on-finish enabled. Success requires:

- final close status `success`.
- final mainnet ETH position `nil`.
- `final_position_confirmed=true`.
- `manual_action_required=false`.
- no unexpected USDC rebalance.

If final close is unknown or failed, run the live emergency close procedure if gates and max ETH allow it. If readback remains unavailable, stop and escalate to manual Hyperliquid account inspection.

## Stop And Close Rules

Stop the bot and close or verify closure if any of these occur:

- mainnet ETH short exceeds configured max.
- any failed WETH rebalance appears.
- Hyperliquid readback is unavailable after retries.
- final close status is not `success`.
- `manual_action_required=true`.
- mainnet ETH position cannot be read.
- Aerodrome position sync repeatedly fails.
- current Aerodrome position becomes inactive or missing.
- env gates mismatch expected supervised-run values.
- unexpected USDC rebalance appears.
- process receives `SIGINT` or `SIGTERM` during a live run.

USDC must never be opened or closed by Aerodrome hedge logic.

## Emergency Close Escalation

The first response to an open ETH short after a supervised run is the gated live emergency close task. It is live-order capable and blocked by default. It closes ETH only, uses explicit size, and must never open positions or touch USDC.

Escalate manually if:

- emergency close fails.
- Hyperliquid readback remains unknown.
- ETH position remains open.
- network/API errors persist.
- actual ETH short exceeds max close cap.

## Operator Responsibilities

During production supervised mode, the operator must:

- actively watch logs and dashboard.
- keep Hyperliquid account UI/readback available.
- verify every rebalance row.
- verify no USDC rebalance appears.
- verify final mainnet ETH position nil.
- restore safe env defaults after the run.
- record incident notes for any warning, failure, or manual action.

## Alert Conditions

Alerting is required before any longer or semi-continuous operation. Future alert channels may include:

- email.
- Telegram.
- local log tail.
- VPS `systemd` journal.
- dashboard banner.

Alert events:

- run started.
- position opened.
- rebalance executed.
- failed rebalance.
- final close started.
- final close success.
- final close unknown or failed.
- mainnet ETH not nil after run.
- manual action required.
- RPC/API error streak.
- process crash.

`bin/rails aerodrome:watchdog_check` is read-only: it does not close positions, does not place orders, and does not call Hyperliquid execution methods. `bin/rails aerodrome:watchdog_alerts` is also read-only and formats watchdog output into dry-run/local alert messages with title, summary, blockers, warnings, and recommended actions. Dry-run remains the default. Email delivery is disabled by default and requires `AERODROME_ALERTS_ENABLED=true`, `AERODROME_ALERTS_DELIVERY=email`, `AERODROME_ALERT_EMAIL_RECIPIENT`, and severity at or above `AERODROME_ALERT_EMAIL_MIN_SEVERITY` (`warn` recommended). SMTP must be configured separately. Watchdog alerts do not close positions, open positions, or automate live operation. Blockers require operator action, and the emergency close remains a separate manually gated task.

Scheduler foundation is documented in `docs/AERODROME_WATCHDOG_SCHEDULER.md`. `bin/aerodrome-watchdog-tick` runs only `bin/rails aerodrome:watchdog_alerts`, and `bin/rails aerodrome:watchdog_scheduler_check` verifies scheduler readiness read-only. A scheduler must not run live observation or emergency close. It does not start live trading, does not close positions, and defaults to dry-run alerts unless email is explicitly enabled by env.

Scheduled email alerts use file-backed deduplication under `storage/aerodrome_watchdog_alerts/state.json`. Repeated identical warnings are suppressed during `AERODROME_ALERT_EMAIL_COOLDOWN_SECONDS` (default 1800 seconds), while blocked alerts can repeat after `AERODROME_ALERT_EMAIL_REPEAT_BLOCKED_SECONDS` (default 300 seconds). Dry-run does not write alert state. Reset state only after review with `rm storage/aerodrome_watchdog_alerts/state.json`; emergency close remains separate and manually gated.

VPS deployment foundation is documented in `docs/VPS_PRODUCTION_DEPLOYMENT.md`. The VPS phase starts with read-only dashboard/watchdog operation only. Live observation on the VPS requires separate manual preflight and explicit one-off gates. No unattended 24/7 live operation is approved by the VPS deployment foundation.

Production canary runner tooling is documented in `docs/AERODROME_PRODUCTION_CANARY_RUNNER.md`. The canary is supervised only and is closer to real production than observation windows because it runs bounded `PositionSyncJob`/`HedgeSyncJob` iterations with a lock, heartbeat JSONL log, stop conditions, canary-aware runtime safety checks, and mandatory final emergency close. It still requires explicit one-off gates, `close_on_finish=true`, and small caps. It is not unattended operation, and future leave-position-open mode requires separate approval.

The persistent watchdog and the production canary runtime safety checks have different jobs. `aerodrome:watchdog_check` is for safe persistent monitoring and remains strict: with the default disabled/paused/not-approved/testnet env, an unexpected mainnet ETH short is a blocker. During an explicitly gated canary run, a small ETH short within configured caps is expected, so the canary runner uses canary-aware runtime safety instead. That runtime check still blocks failed WETH/ETH rows, successful USDC rows, cap breaches, readback failures, missing emergency close gates, inactive position/hedge state, and previous canary logs with `manual_action_required=true`. A previous non-nil final position is warning-only if current ETH readback is nil.

The VPS canary run that created `ShortRebalance #190` stopped because the generic watchdog was used during expected live canary state. The final emergency close succeeded, `manual_action_required=false`, and final mainnet ETH was nil. This does not approve continuous operation; any repeat canary requires fresh readiness/preflight evidence and explicit manual approval.

The VPS canary runtime-safety retest passed after the canary-aware check was added. The 1-hour run reported runtime safety `PASS` with no blockers or warnings, treated the in-cap ETH short as expected during the canary, completed with `stop_reason="duration complete"`, closed `0.0106` ETH on the first final-close attempt, and ended with final mainnet ETH nil and `manual_action_required=false`. This confirms the context-specific runtime safety path for supervised canaries while keeping the generic watchdog strict for persistent monitoring.

Production live runner V1 is documented in `docs/AERODROME_PRODUCTION_LIVE_RUNNER.md`. It is the first leave-position-open mode, but it is still supervised and manually launched only. It requires explicit one-off production-live gates, leaves ETH open only on clean duration completion, closes on errors/signals when gated, and requires `aerodrome:production_live_status` after every run. USDC remains unsupported, and unattended/systemd live service remains future work requiring separate approval.

For the first real direct Slipstream position, use the production live tier with `AERODROME_MAX_SHORT_ETH=0.55`, `AERODROME_MAX_SHORT_NOTIONAL_USD=1300`, and `AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH=0.60`. This is still supervised production, not approval for unattended 24/7 operation or further cap increases.

The first real new-position 1x supervised run passed and is recorded in `docs/AERODROME_NEW_POSITION_FIRST_LIVE_RUN_REPORT.md`. Token id `70184676` opened a `0.3912` ETH WETH-side hedge under the supervised production caps, approved-open monitoring worked, watchdog was `WARN` rather than `BLOCKED`, and the manually gated emergency close later returned mainnet ETH to nil. Keep the web/dashboard running during these runs so operator monitoring remains available. The next stage can be a longer supervised run on the new position or a separately approved unattended-design project.

The first 6-hour supervised run on the new real 1x position also passed and is recorded in `docs/AERODROME_NEW_POSITION_6H_LIVE_RUN_REPORT.md`. It ran 21600 seconds with 72 iterations while the web/dashboard stayed online, opened WETH hedge `#201` at `0.3973` ETH, kept runtime safety `PASS`, finished with `position_left_open=true`, `final_position_confirmed=true`, `manual_action_required=false`, and had no errors. Approved-open monitoring should treat the in-cap ETH hedge as monitored state while open, and emergency close remains manual and gated. This is still supervised production, not unattended 24/7 approval.

The 6-hour run showed that normal rebalances can remain skipped even when some proposed deltas exceed `$10` if `hedge.tolerance=0.05` keeps the relative deviation inside tolerance. Treat that as protective anti-churn behavior. Rebalance tolerance policy needs separate review before any change.

The first VPS Production Live Runner V1 run passed. It ran for 1 hour with 12 iterations, one WETH rebalance, runtime safety `PASS`, no blockers or warnings, and no USDC activity. On clean duration completion it intentionally left an in-cap ETH hedge open with `position_left_open=true`, `final_position_confirmed=true`, `manual_action_required=false`, and final status `success`. Mainnet ETH was later verified nil, `live_emergency_close` returned noop, and safe env was restored. This milestone does not approve unattended 24/7 operation; the next stage is approved-open-position monitoring/watchdog.

Approved open position monitoring is read-only and lets watchdog distinguish a known valid open ETH hedge from an unexpected ETH position. It only treats ETH as intended state when the latest production live log is successful, duration-complete, `position_left_open=true`, confirmed, no manual action required, and current ETH is within caps/tolerance. It does not close positions or approve new live runs.

The VPS approved-open watchdog/readiness retest passed and is recorded in `docs/AERODROME_APPROVED_OPEN_WATCHDOG_VPS_RETEST_REPORT.md`. A 360 second production live run left an ETH short around `-0.0093` open by design, approved-open monitoring validated it, `production_live_status` reported `PASS`, and `watchdog_alerts` reported `WARN` rather than `BLOCKED` because the only suppressed readiness blocker was strict safe-mode ETH-open evidence. The operator then manually ran the gated live emergency close and final mainnet ETH readback was nil. This remains supervised production mode, not unattended operation.

Volatility-aware rebalance guarding is part of supervised mode preparation. When enabled, it prevents the runner from chasing sharp pump/dump movement by skipping unsafe rebalance attempts; it does not close positions. The controlled target-step test is a separate live-capable supervised tool for verifying rebalance up/down behavior without relying on market movement. It requires explicit gates, restores the original target, closes ETH at finish, and remains outside unattended 24/7 operation.

The VPS target-step rebalance test passed. Rebalances `#196` and `#197` verified controlled WETH hedge movement up and down while the volatility guard allowed both steps. The target was restored, final ETH was nil, and manual action was not required. The earlier 5-hour run’s lack of extra rebalances is consistent with the `$10` minimum order notional because the observed delta was only about `$6.31`.

The VPS adopt-existing recovery workflow passed. A first supervised production run opened WETH hedge `#198` and left ETH open. A second supervised run with the explicit adopt gate adopted that approved open ETH hedge, kept runtime safety `PASS`, skipped an unnecessary rebalance after the recent rebalance, and finished successfully with the hedge still open by design. Manual close later returned ETH to nil. This proves supervised restart/adopt-existing recovery for v1, not unattended operation.

Production operator command wrappers are documented in `docs/AERODROME_PRODUCTION_OPERATOR_COMMANDS.md`. They make the VPS workflow explicit: status checks are read-only, backups are required before and after live runs, open/close helpers print templates only, and watchdog/approved-open monitoring never closes positions. The live runner remains manual and gated; no unattended live scheduler is approved.

The production live runner should be launched as a one-off Docker Compose runner while the web container remains online. The dashboard and PnL pages should remain available through the SSH tunnel for operator monitoring. Stopping web is a debug/emergency action, not normal supervised production flow.

## VPS And Runtime Setup

Recommended foundation before production supervised mode:

- stable VPS with enough disk, memory, and swap for Rails/Solid Queue.
- `systemd` unit with explicit env file handling and journal retention.
- no live gates in persistent env by default.
- log rotation for Rails logs and observation JSONL logs.
- monitored disk space.
- documented restart policy.
- clear operator access to Hyperliquid UI/API readback.
- backup and restore procedure tested.

Do not run as unattended 24/7 automation until watchdogs, alerting, and incident response have been tested.

## Log Retention

Retain:

- Rails logs for the run window.
- Solid Queue/job logs.
- observation JSONL logs.
- readiness/preflight output.
- final emergency close output.
- final mainnet/testnet ETH readback.

Observation JSONL logs should be archived with the run report.

## Restart Policy

For production supervised mode, restarts should be conservative:

- do not auto-restart into live gates without operator confirmation.
- after crash/restart, first run read-only readiness and Hyperliquid readback.
- if ETH position is open, follow emergency close escalation.
- do not resume live observation automatically.

## Incident Response

For any incident:

1. Stop the live process if still running.
2. Read mainnet ETH position.
3. If ETH short remains and gates allow, run live emergency close.
4. Verify mainnet ETH nil.
5. Restore safe env defaults.
6. Preserve logs and JSONL.
7. Create incident note.
8. Do not restart live operation until the cause is reviewed.

## Recovery Procedure

Recovery after failure requires:

- mainnet ETH nil or explicitly documented open-position handling.
- failed rebalance rows reviewed.
- failed zero-size no-position rows acknowledged only through the existing acknowledgment task.
- `bin/rake` passing.
- readiness checks passing.
- explicit manual approval for the next run.

Do not delete or rewrite `ShortRebalance` history.

## Staged Rollout Plan

1. Keep safe defaults.
2. Add/read `aerodrome:production_supervised_readiness`.
3. Use `aerodrome:watchdog_check` as read-only watchdog evidence.
4. Test alerting without orders.
5. Test crash/stop/final-close behavior under mocks.
6. Plan one supervised production-mode window with task-appropriate caps; micro tools stay at `0.02` ETH / `$50`, while production live V1 may use the reviewed supervised tier.
7. Review logs and incident readiness before any longer duration.

Scaling duration, size, or autonomy requires a separate approval and safety review.

`APP_GIT_SHA` is metadata only. It helps readiness identify the deployed revision and does not enable live trading, orders, or any execution path.
