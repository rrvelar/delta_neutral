# Read-Only Preflight: fragile ethereal->extended <5s path (post eba6b3c + ETHEREAL_* env) — 2026-07-10

Read-only preflight after deploying eba6b3c with `ETHEREAL_LOT_SIZE=0.0001`,
`ETHEREAL_TICK_SIZE=0.1`, `ETHEREAL_ONCHAIN_ID=2`. No live action of any kind taken.

## Command correction

The requested tasks `migration:manual_canary_gate_status route=...` and
`migration:manual_live_canary_dry_run` do not exist in that form:

- Gate status and readiness tasks take `from=<venue> to=<venue>`, not `route=`.
  With `route=`, the task silently fell back to defaults and reported `nado->nado`.
- There is no `manual_live_canary_dry_run` task. The read-only equivalent is
  `migration:manual_live_canary_readiness position_id=6 from=... to=...`
  (pure read-only; `dry_run: true, submitted: false, orders 0`). A receipt-writing
  rehearsal also exists as `migration:rehearse_route` ("without signing or
  submitting") but was not run, to keep this pass strictly read-only.

## Current production state (read-only)

- Current production venue: **extended**; shorts: extended `1.687`, ethereal `0.0`, nado `0.0`
- Open orders: zero on all venues; `inside_tolerance: true`
  (`target_short_eth 1.709`, `combined_short_eth 1.687`, drift `0.0155`, tolerance `0.0511`)
- Gates: `MIGRATION_LIVE_ENABLED=false`, `MIGRATION_AUTO_ENABLED=false`,
  `MIGRATION_RANDOM_ROTATION_LIVE_ENABLED=false`
- Runner: `stopped`, systemd unit `inactive`
- Route proofs: 5/6 READY_FOR_RANDOM (`extended->ethereal`, `extended->nado`,
  `nado->extended`, `ethereal->nado`, `nado->ethereal`); `ethereal->extended` **STALE**

## Is ethereal->extended runnable from current state? NO

`manual_live_canary_readiness position_id=6 from=ethereal to=extended` says
`ready_for_supervised_canary: false` with these state blockers (beyond gates):

- `position hedge execution_venue must be ethereal before migration`
- `source venue must have a real short before canary.` (ethereal short is 0.0)
- `source close preview unavailable.`

With ethereal flat, the planner degenerates: `planned_source_leg: null` and the
only planned leg is a 0.0155 ETH drift top-up on extended — not a real migration.
**A reposition is required first: extended->ethereal** (which is READY_FOR_RANDOM
and was previously proven).

## Reposition route extended->ethereal (read-only check)

Gate status (`from=extended to=ethereal`, recommended sequence `target_first`):

- DB gates (all currently false, fail-closed): `MIGRATION_LIVE_ENABLED`,
  `MIGRATION_MANUAL_LIVE_CANARY_ENABLED`, `MIGRATION_FULL_ALLOWED`
- Env gates already satisfied in the deployed container: `EXTENDED_LIVE_ENABLED=true`,
  `EXTENDED_MAINNET_PROBE_ENABLED=true`, `AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED=true`
- Autos: extended auto already disabled (`would_pause: false`); ethereal auto currently
  enabled — the manual canary gate flow **would pause it** (`would_pause: true`) and
  restore afterwards

Readiness verdict: `ready_for_supervised_canary: false` with exactly 4 blockers,
**all arm-clearable** (no state blockers):

1. `MIGRATION_LIVE_ENABLED must be true` — armed by `arm_manual_canary_gates`
2. `MIGRATION_MANUAL_LIVE_CANARY_ENABLED must be true` — armed by same
3. `MIGRATION_FULL_ALLOWED must be true` — armed by same
4. `target venue auto must be disabled during migration canary: ethereal` — paused by the
   arm/canary flow (would_pause: true)

Plan preview (target_first): open ethereal short `1.70793` (fresh Mellow target),
then close extended short `1.687`; `expected_final_combined_short 1.70793`,
`expected_final_inside_tolerance: true`, `expected_final_drift 0.0`.

## ethereal->extended blockers (for the record)

`ready_for_supervised_canary: false`; blockers: the same 3 DB gates + `source venue
auto must be disabled (ethereal)` (arm-clearable) **plus** the 3 non-arm-clearable
state blockers listed above (execution_venue must be ethereal; real ethereal short
required; source close preview unavailable). Route support: `live_path_implemented:
true`, `target_first` only (`source_first_supported: false`); route proof status
STALE ("must be repeated") — clears only by repeating the proof, not by arming.

## Confirmations

- No live canary, no gates armed/enabled, no autos paused, no runner/scheduler
  start, no orders/signatures/cancels, no route run, no deploy/rebuild/push,
  no DB/env/secret mutation, no threshold/policy/code changes.
- Every command run was read-only (status/readiness reports; `orders_submitted: 0,
  orders_placed: 0, signatures_created: 0` in all outputs).

## Next step

Supervised reposition canary extended->ethereal (proven route) to return the
position to ethereal, then repeat the ethereal->extended proof attempt with the
fragile <5s path. Both require explicit operator go + gate arming; nothing armed now.
