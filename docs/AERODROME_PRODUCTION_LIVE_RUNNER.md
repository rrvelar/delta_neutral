# Aerodrome Production Live Runner V1

## Scope

`bin/rails aerodrome:production_live_run` is the first supervised leave-position-open runner for the Aerodrome WETH/ETH hedge. It is live-order capable only when explicit one-off gates are supplied. It is not enabled by default, not scheduled, not a daemon, and not unattended 24/7 operation.

## Required Gates

The runner refuses unless all production live gates are set:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- `AERODROME_PRODUCTION_LIVE_ENABLED=true`
- `AERODROME_PRODUCTION_LIVE_CONFIRM=I_UNDERSTAND_THIS_RUNS_PRODUCTION_LIVE_HEDGE`
- `AERODROME_PRODUCTION_LIVE_DURATION_SECONDS` configured and `<= 21600`
- `AERODROME_PRODUCTION_LIVE_INTERVAL_SECONDS` configured and `>= 180`
- `AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN=true`
- `AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR=true`
- `AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL=true`
- `AERODROME_MAX_LEVERAGE=1`
- `AERODROME_MAX_SHORT_ETH` configured and `<= 0.75`
- `AERODROME_MAX_SHORT_NOTIONAL_USD` configured and `<= 2000`
- `AERODROME_MIN_ORDER_NOTIONAL_USD >= 10`
- live emergency close gates present and valid.

Default persistent env must remain disabled, paused, not live-approved, and testnet outside an explicitly approved supervised run.

Production live V1 has a higher supervised cap tier than the micro tools. The production live runner accepts operator-configured caps up to `0.75` ETH and `$2000` notional at exactly `1x` leverage, while `production_canary_run`, `live_observation_window`, and `production_target_step_test` remain micro-capped at `0.02` ETH / `$50` unless a future task explicitly changes them. The current first real direct Slipstream position is intended to use `AERODROME_MAX_SHORT_ETH=0.55`, `AERODROME_MAX_SHORT_NOTIONAL_USD=1300`, and `AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH=0.60` for a roughly `$925` 1.0x WETH hedge. Increasing beyond the production hard ceiling requires separate review and code changes.

## Runtime Behavior

The runner takes a file lock at `storage/aerodrome_production_live/run.lock` and writes JSONL events to `storage/aerodrome_production_live/*.jsonl`.

The runner removes its own lock file after releasing the lock on normal finish or error finalization. If a lock file remains after a finished log, `production_live_status` reports `stale_finished` as a warning. Operators should verify no live runner process is active, inspect the latest JSONL finish event, and confirm current mainnet ETH state before manually removing the stale lock file.

Each iteration runs:

- `PositionSyncJob.perform_now(position.id)`
- `HedgeSyncJob.perform_now(hedge.id)`
- read-only mainnet ETH position readback
- production-live runtime safety check

The live runner never opens/closes USDC directly and does not call `set_leverage` directly. Hedge execution remains inside the existing `HedgeSyncJob` and `HyperliquidService` path.

## Leave-Position-Open Rule

On clean duration completion, V1 leaves the ETH hedge open by design. Success requires final readback to confirm either:

- an ETH position exists and remains within configured caps, or
- target short is zero and final ETH position is nil.

The operator must run `bin/rails aerodrome:production_live_status` after every run and verify the final state independently.

## Error And Signal Rule

If the run stops because of an error, blocker, failed WETH/ETH rebalance, cap breach, unexpected USDC rebalance, readback failure, inactive/missing position, env mismatch, emergency close gate mismatch, or `SIGINT`/`SIGTERM`, the runner attempts the manually gated live emergency close when close-on-error/signal gates are true. Success then requires final ETH nil.

If final readback cannot confirm the ETH state, status is `close_unknown` and `manual_action_required=true`.

## Status And Stop Plan

- `bin/rails aerodrome:production_live_status` is read-only. It reports lock state, latest log, latest final status, current mainnet ETH position, safe env values, and manual-action state.
- `bin/rails aerodrome:production_live_stop_plan` is read-only. It prints operator stop/close steps and never closes positions.

Manual emergency close remains a separate explicitly gated task.

## Not Approved

This runner is not an unattended live service. Do not add systemd, cron, or UI start controls for it without a separate review. Future unattended/systemd live service and larger limits require separate approval and implementation.

## First VPS Run

The first VPS Production Live Runner V1 run passed. It ran for 3600 seconds with 300 second intervals, one WETH-side rebalance, max `0.02` ETH / `$50` notional caps, and 1x leverage. Runtime safety stayed `PASS` with no blockers or warnings, USDC was not used, and the clean duration-complete path intentionally left an in-cap ETH hedge open. Final output reported `position_left_open=true`, `final_position_confirmed=true`, `manual_action_required=false`, and `status=success`.

After the micro-test milestone, production live V1 was moved to the supervised production cap tier described above. The historical first V1 run remains a micro-cap proof; new production live runs may use the larger supervised env caps only when explicitly supplied and still remain manual, gated, monitored, and non-24/7.

The first real new-position 1x supervised run passed and is recorded in `docs/AERODROME_NEW_POSITION_FIRST_LIVE_RUN_REPORT.md`. Token id `70184676` synced through the direct Aerodrome Slipstream position manager/factory, ran for 1800 seconds with 300 second intervals, opened WETH hedge `#200` from `0.0` to `0.3912` ETH, kept runtime safety `PASS`, and left the approved open ETH hedge by design. Approved-open monitoring reported `approved`, `production_live_status` reported `PASS`, and `watchdog_alerts` reported `WARN` with no blockers. The operator then manually ran the gated emergency close, which closed ETH to nil.

The first 6-hour supervised run on the same new real 1x position also passed and is recorded in `docs/AERODROME_NEW_POSITION_6H_LIVE_RUN_REPORT.md`. It ran for 21600 seconds with 300 second intervals, kept the web/dashboard online, completed 72 iterations, opened WETH hedge `#201` from `0.0` to `0.3973` ETH, kept runtime safety `PASS`, finished with `position_left_open=true`, `final_position_confirmed=true`, `manual_action_required=false`, and had no errors. Approved-open monitoring is expected to treat that in-cap ETH hedge as monitored state while open. Emergency close remains manual and gated.

The 6-hour run also showed that natural rebalances may not execute even when `proposed_delta_usd` exceeds `$10` if `hedge.tolerance=0.05` keeps the relative deviation inside tolerance. That anti-churn behavior is protective. Rebalance tolerance policy needs a separate review before changing.

After the run, mainnet ETH was later verified nil and `live_emergency_close` returned noop because there was no ETH position to close. Safe env was restored. This is not unattended 24/7 approval. The next stage is approved-open-position monitoring/watchdog so a known valid open ETH hedge can be monitored as intended state instead of generic safe-mode `BLOCKED`.

Approved open position monitoring is documented in `docs/AERODROME_APPROVED_OPEN_POSITION_MONITORING.md`. It is read-only and treats an open ETH short as non-blocking only when the latest successful production live finish left `position_left_open=true`, final position was confirmed, `manual_action_required=false`, and current ETH remains within caps/tolerance. It does not approve new live runs and does not close positions.

Current Hyperliquid readback decides whether a previous approved-open position is still open. If the latest production live log has a non-nil `final_position` but current ETH readback is nil, that stale approved-open state is warning-only and does not permanently block a future run after fresh preflight. If readback is unavailable, current ETH exists without explicit adoption, or current ETH is mismatched/out of caps, the runner blocks.

An adopt-existing production live run may start with an already-open ETH short only when `AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT=true` and approved-open monitoring reports `approved` with no blockers. The current ETH short must be within max ETH and max notional caps, `manual_action_required` must be false, and current readback must succeed. In that case, the runner suppresses only the strict readiness blocker that says mainnet ETH is not nil and records the warning `mainnet ETH is approved open hedge and is being adopted`. All unrelated readiness blockers still block. Non-adopt runs remain strict and block if ETH is already open.

Watchdog/readiness integration is approved-open-aware. `production_supervised_readiness` remains strict safe-mode evidence and can be `BLOCKED` solely because mainnet ETH is open. When the approved-open detector validates that ETH as the expected in-cap hedge, watchdog suppresses only that readiness nil-position blocker and reports it as monitored state. Other readiness blockers remain blockers.

The VPS approved-open watchdog retest passed and is documented in `docs/AERODROME_APPROVED_OPEN_WATCHDOG_VPS_RETEST_REPORT.md`. A 360 second production live run left an ETH short around `-0.0093` open by design, approved-open monitoring validated it, `watchdog_alerts` returned `WARN` rather than `BLOCKED`, and the operator then manually closed ETH through the separately gated live emergency close. Longer production live runs or restart/adopt-existing workflow require separate approval and planning.

## Volatility Guard And Target-Step Testing

Production live runner iterations run `AerodromeRebalanceVolatilityGuard` before `HedgeSyncJob`. If the guard is disabled, behavior is unchanged. If the guard is enabled and detects sharp movement, excessive window move, price divergence, cooldown, or too-recent rebalance, the runner skips that rebalance attempt and logs the guard result. The guard does not close positions and does not bypass emergency close.

`docs/AERODROME_TARGET_STEP_TEST.md` documents the controlled target-step rebalance test. It is live-capable, supervised only, and requires explicit one-off gates. It temporarily changes the hedge target up/down, restores the original target, and closes ETH at finish. It must not be used as unattended automation.

The VPS target-step rebalance test passed and is recorded in `docs/AERODROME_TARGET_STEP_REBALANCE_TEST_REPORT.md`. The test intentionally stepped the target `0.01 -> 0.015 -> 0.01`, the volatility guard allowed both steps, WETH rebalances `#196` and `#197` succeeded, the target was restored, and final ETH was nil. The test also confirmed why a normal 5-hour run may not rebalance again when observed deltas remain below the `$10` minimum order notional.

Operator command wrappers for supervised production are documented in `docs/AERODROME_PRODUCTION_OPERATOR_COMMANDS.md`. `bin/vps-production-open-run-template` prints a manual command template but does not run the live runner. `bin/vps-production-close-template` prints a manual emergency close template but does not close. Backups are required before and after live runs, and `bin/vps-production-post-run-check` should be run after every supervised run.

The VPS production live command should run as a one-off Docker Compose runner container with `docker compose -f docker-compose.prod.yml run --rm --no-deps web ...`. Do not stop the existing web container for normal production-supervised operation; the dashboard and PnL views should stay available through the SSH tunnel. Stopping web is reserved for debug/emergency maintenance, not the normal live-run template.

## Adopt-Existing Recovery Test

The VPS adopt-existing recovery workflow passed and is documented in `docs/AERODROME_ADOPT_EXISTING_RECOVERY_TEST_REPORT.md`. Step A opened WETH hedge `#198` from `0.0` to about `0.011` ETH and left it open by design. Step B ran with `AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT=true`, adopted the approved ETH short around `-0.0109`, logged the warning that the approved open hedge was being adopted, kept runtime safety `PASS`, and finished successfully with `position_left_open=true` and `manual_action_required=false`. A later manual emergency close returned mainnet ETH to nil.

Adopt-existing remains supervised only. Non-adopt runs remain strict. Future unattended restart/adopt behavior requires separate design and approval.
