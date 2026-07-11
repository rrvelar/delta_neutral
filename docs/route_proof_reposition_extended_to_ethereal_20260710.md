# Supervised Reposition Canary: extended->ethereal — SUCCESS (2026-07-10)

One supervised manual live canary, reposition only (not the ethereal->extended
certification). Runner/scheduler never started. Exactly one route run, no retries.
Gates disarmed and autos restored afterwards.

## Pre-arm snapshot (all abort checks passed)

- Runner: `stopped`, systemd `inactive`; no duplicate process, heartbeat not stale
- Venue: extended; shorts extended `1.687`, ethereal `0.0`, nado `0.0`
- Open orders: zero on all venues; `inside_tolerance: true`
- Gates all false; route proofs 5/6 (ethereal->extended STALE)
- Readiness `from=extended to=ethereal`: sequence `target_first`, exactly 4 blockers,
  all arm-clearable (3 DB gates + ethereal auto pause)

## Arm

`migration:arm_manual_canary_gates from=extended to=ethereal` → `ok: true`.
Armed `MIGRATION_LIVE_ENABLED`, `MIGRATION_MANUAL_LIVE_CANARY_ENABLED`,
`MIGRATION_FULL_ALLOWED`. Paused target auto
`AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` (previous `true`); extended auto already
disabled.

Post-arm readiness: `ready_for_supervised_canary: true`, `blockers: []`,
sequence `target_first`.

## Live canary result

`migration:run_manual_live_canary position_id=6 from=extended to=ethereal
sequence=target_first` → **`final_status: LIVE_CANARY_CONFIRMED`**

- Target leg (ethereal open short): `TARGET_SUBMITTED_AND_CONFIRMED`, readback
  confirmed at `18:10:49Z`; order id `0ca4613f-1217-441d-9e14-7601a3d60f99`
  - timing: total `7.60s` (build `4.15s` ← slow step, submit `0.89s`, readback `2.50s`)
- Source leg (extended close): `SOURCE_CLOSE_CONFIRMED`, readback confirmed at
  `18:11:39Z`; exchange order id `2075643962503917568`
  - timing: total `15.93s` (build `2.22s`, submit `1.16s`, readback `9.11s` ← slow step)
- `total_route_seconds: 59.35`; confirmations via `position_readback`
- `final_inside_tolerance: true`, `source_flat_after: true`,
  `target_holds_expected_short: true`, `open_orders_after: 0`
- Receipt: `storage/hedge_migration_live_canaries/20260710.jsonl`
  (host `/opt/delta_neutral/storage/hedge_migration_live_canaries/20260710.jsonl`)

## Disarm/restore (immediately after)

`migration:disarm_manual_canary_gates` → `ok: true`. All three migration DB gates
back to false (nado gates confirmed false too).
`AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` restored to `true`.

## Post-canary verification

- Venue: **ethereal**; shorts ethereal `1.7021` (target 1.70793, inside tolerance),
  extended `0.0`, nado `0.0`
- Open orders: zero on all venues; `inside_tolerance: true`;
  `unconfirmed_venue_readbacks: []`
- Gates: all false; runner `stopped` / systemd `inactive` — never started
- Route proofs: still 5/6; `extended->ethereal` READY_FOR_RANDOM with
  `route_production_safe: true`, `latency_proof_status: passed` (proof timestamp
  2026-07-04 — this reposition intentionally did not alter proofs);
  `ethereal->extended` still STALE pending the separate certification canary
- Transient note: one status read hit an Extended snapshot `Timeout::Error`
  (stale-diagnostic fallback); an immediate re-run returned a fresh clean readback
  (`extended 0.0`, `source_errors: {}`). No action needed.
- Stale-heartbeat note: the stopped runner's last heartbeat (2026-07-04) still says
  `current_production_venue: extended`; the authoritative status field says
  `ethereal`. Expected, since the runner has not run since.

## Confirmations

- Exactly one route executed (extended->ethereal), one canary, no retries, no loop.
- No runner/scheduler/random-runner start; no ethereal->extended run; no other route.
- Gates disarmed (all false) and paused auto restored at end.
- No threshold/policy/order-construction changes, no deploy/rebuild/push.
- Only DB mutations were the intended arm/disarm gate changes and auto pause/restore.

## Next step

Separate final certification canary ethereal->extended (fragile <5s path) from the
now-correct starting state (venue ethereal, real ethereal short). Requires fresh
preflight + explicit operator go.
