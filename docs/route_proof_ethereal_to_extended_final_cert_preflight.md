# Read-Only Fresh Preflight: final ethereal->extended certification canary — 2026-07-10

Post-reposition preflight for the fragile <5s ethereal->extended attempt.
Strictly read-only: no arm, no gates, no autos touched, no orders, no route,
no deploy, no DB/env mutation.

## Current production state

- Venue: **ethereal** (authoritative field; the stopped runner's stale 2026-07-04
  heartbeat still says extended — expected)
- Shorts: ethereal `1.7021`, extended `0.0`, nado `0.0`; fresh Mellow target
  `1.709071445500797`, drift `0.00697`, tolerance `0.05127`, `inside_tolerance: true`
- Open orders: zero on all venues; `unconfirmed_venue_readbacks: []`
- Gates all false; runner `stopped` / systemd `inactive`; no duplicate runner;
  heartbeat not stale

## Route proofs

Still 5/6: extended->ethereal, extended->nado, nado->extended, ethereal->nado,
nado->ethereal all READY_FOR_RANDOM; **ethereal->extended STALE** (the route this
certification will repeat).

## ethereal->extended readiness (from=ethereal to=extended)

`ready_for_supervised_canary: false` with **exactly 4 blockers, all arm-clearable**:

1. `MIGRATION_LIVE_ENABLED must be true` — set by arm
2. `MIGRATION_MANUAL_LIVE_CANARY_ENABLED must be true` — set by arm
3. `MIGRATION_FULL_ALLOWED must be true` — set by arm
4. `source venue auto must be disabled during migration canary: ethereal` — arm
   pauses `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` (`would_pause: true`) and
   disarm restores it; extended auto already disabled (`would_pause: false`)

No state blockers remain: `target_leg_blockers: []`,
`source_close_preflight_blockers: []`, `live_env_gate_blockers: []`,
`dry_run_ready: true`, `live_path_implemented: true`, `fresh_target_status: ok`.
Env gates already satisfied in container: `EXTENDED_LIVE_ENABLED`,
`EXTENDED_MAINNET_PROBE_ENABLED`, `AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED` all true.

**Verdict: ready for ONE supervised canary immediately after arm.**

## Sequence and plan preview

Sequence: `target_first` (requested = recommended; `source_first_supported: false`).

- First leg (target, extended): `open_short`, sell, `size_eth 1.709071445500797`,
  expected after `1.709071445500797`
- Second leg (source, ethereal): `close_short`, reduce-only buy, `size_eth 1.7021`,
  expected after `0`
- Temporary combined after first leg: `3.4112` (overhedge) — this is the fragile
  double-exposure window that must close in <5s
- Expected final: combined `1.70907`, drift `0.0`, inside tolerance true
- Required confirmation phrase: `I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY`

`frozen_source_position` is not surfaced by the readiness report (it appears only
in live canary receipts; the reposition receipt showed `null`).

## ETHEREAL_* constants active

`EtherealHedgeExecutionService#ethereal_product_metadata_env_status` in the
deployed container:

```json
{"present": {"lot_size": true, "tick_size": true, "onchain_id": true},
 "all_present": true, "product_read_avoided_on_critical_path": true,
 "note": "Ethereal /v1/product read avoided via env constants (supports double_exposure < 5s)."}
```

The ~3s `/v1/product` read is off the pre-submit critical path, which is the
eba6b3c mechanism for reaching double_exposure < 5s. Margin is still expected to
be small.

## Confirmations

- No live action taken: no canary, no arm/enable, no auto pause, no
  runner/scheduler, no orders/signatures/cancels, no route, no deploy/push,
  no DB/env/secret/threshold/policy/code changes.
- All outputs read-only (`orders_submitted: 0, orders_placed: 0,
  signatures_created: 0`; readiness explicitly `dry_run: true, submitted: false`).

## Next step (requires explicit operator go)

Arm → post-arm readiness (must be true/empty blockers) → ONE supervised
`run_manual_live_canary position_id=6 from=ethereal to=extended
sequence=target_first` → always disarm/restore → verify `double_exposure_seconds`
against the <5s certification bar and refresh the route proof.
