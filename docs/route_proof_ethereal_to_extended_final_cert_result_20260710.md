# Final Certification Canary ethereal->extended — POSITION SAFE, CERTIFICATION FAILED ON LATENCY (2026-07-10)

One supervised manual live canary, ethereal->extended, target_first. Exactly one
route run, no retries, no other route, runner/scheduler never started. Gates
disarmed and Ethereal auto restored immediately after.

**Outcome: NOT 6/6.** The migration itself completed safely
(`LIVE_CANARY_CONFIRMED`), but the latency certification failed:
`double_exposure_seconds 30.76 > 5`, `route_production_safe: false`, and the
ethereal->extended proof remains **STALE** (proof timestamp still 2026-06-05).
Route proofs remain **5/6**.

**Critically, the failure was NOT the fragile Ethereal leg.** The Ethereal close
(the leg eba6b3c + ETHEREAL_* env constants targeted) was fast: **3.17s total**.
The budget was consumed by the Extended target-open **readback (14.65s)** and an
**~27.5s inter-leg gap** between target confirmation and source-close start.

## Pre-arm snapshot (all abort checks passed)

- Runner `stopped`/`inactive`; venue ethereal; shorts ethereal 1.7021 / extended 0.0
  / nado 0.0; open orders zero; inside_tolerance true; gates false; proofs 5/6
- Readiness: 4 arm-clearable blockers, sequence target_first, `dry_run_ready: true`
- ETHEREAL_* env status: `all_present: true`,
  `product_read_avoided_on_critical_path: true`

## Arm and post-arm readiness

Arm `ok: true`: 3 migration DB gates true; paused
`AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` (was true); extended auto already false.
Post-arm readiness: `ready_for_supervised_canary: true`, `blockers: []`, target_first.

## Live canary receipt

Path: `storage/hedge_migration_live_canaries/20260710.jsonl`
(host `/opt/delta_neutral/storage/hedge_migration_live_canaries/20260710.jsonl`),
receipt timestamp `2026-07-10T18:28:41Z`.

- `final_status: LIVE_CANARY_CONFIRMED`; both legs readback-confirmed
- Target leg (Extended open_short 1.70907): `TARGET_SUBMITTED_AND_CONFIRMED`,
  exchange order `2075648595888603136`
  - **timing: total 21.87s** — build 3.10s, submit 1.03s, **readback 14.65s (slow step)**
  - `target_open_position_readback_confirmed_at: 18:29:41.73Z`
- Source leg (Ethereal close_short 1.7021, reduce-only buy): `SOURCE_CLOSE_CONFIRMED`,
  exchange order `2206429e-0e0b-4968-8aea-249078b2de72`
  - **timing: total 3.17s** — build 1.50s, submit 0.80s, readback 0.77s (slow step: build)
  - `source_close_position_readback_confirmed_at: 18:30:12.38Z`
- Double exposure: **30.758s** (18:29:41.62Z → 18:30:12.38Z), start/end source both
  `position_readback`
  - Decomposition: source close action itself took only 3.17s ending 18:30:12.38, so it
    began ≈18:30:09.2 — leaving **≈27.5s between target confirmation and source-close
    start** inside the double-exposure window. That inter-leg gap is the dominant cost
    and the next diagnosis target.
- `target_total_latency_seconds: 21.872` (> 15 bar)
- `total_migration_latency_seconds / total_route_seconds: 57.147` (> 45 bar)
- Receipt blockers recorded: `LATENCY_THRESHOLD_EXCEEDED` for both target_total and
  total_migration
- `route_production_safe: false`, `production_safe_route: false`,
  `route_latency_proof: null`, `underhedge_seconds: null`
- `frozen_source_position: null` (surfaced in receipt as null)
- ETHEREAL_* env status is not embedded in the receipt; verified separately pre-arm
  (`all_present: true`, `product_read_avoided_on_critical_path: true`). The 1.50s
  Ethereal build (vs ~4.15s when opening on Ethereal in the reposition, and ~3s
  historical /v1/product reads) is consistent with the env constants being active.
- `final_inside_tolerance: true`, `source_flat_after: true`,
  `target_holds_expected_short: true`, `open_orders_after: 0`

## Disarm/restore (immediately after canary)

`ok: true`: all migration DB gates false;
`AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` restored to `true`
(post-check: `currently_enabled: true`, `restore_pending: false`);
`EXTENDED_AUTO_REBALANCE_ENABLED` left false as before.

## Final production state

- Venue: **extended**; shorts extended `1.703`, ethereal `0.0`, nado `0.0`
- Open orders: zero all venues; `inside_tolerance: true`; no unconfirmed readbacks
- Gates all false; runner `stopped`/systemd `inactive` — never started
- Route proofs: **5/6** — ethereal->extended STALE (unchanged, 2026-06-05 proof);
  all other five READY_FOR_RANDOM

## Explicit statement

This attempt **failed 6/6 certification** — but not because of fragile Ethereal
latency. The Ethereal source-close leg hit ~3.2s (the eba6b3c optimization worked).
The failure came from (a) Extended target-open position-readback latency (14.65s)
and (b) ~27.5s of inter-leg overhead before the source close began. Both sit on the
Extended/readback side of the window. No retry was run per hard rules.

## Confirmations

- Exactly one route (ethereal->extended), one canary, no retries, no loop, no other
  route, no runner/scheduler/random-runner start, no deploy/rebuild/push, no
  threshold/policy/order-construction changes.
- Only DB mutations were arm/disarm gate changes and Ethereal auto pause/restore;
  gates false and auto restored at end.
