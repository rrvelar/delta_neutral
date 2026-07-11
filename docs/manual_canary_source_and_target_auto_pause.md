# Manual Canary — Pause/Restore BOTH source and target venue auto-rebalance

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Scope:** Code + tests only. No live canary, no runner start, no order/signature, no production DB
mutation, no venue-adapter / order-construction / execution-semantics change, no threshold weakened.
Change is not deployed.

Resolves the reposition blocker: `extended->ethereal` was blocked by
`target venue auto must be disabled during migration canary: ethereal`
(`AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED=true`), which the previous source-only pause could not clear.

---

## Behavior

`MigrationManualCanaryGates` now pauses/restores the auto-rebalance gate of BOTH the source (from) and
target (to) venue for a manual canary:

- `arm!` sets the manual-canary DB live gates true (unchanged), then for each of the source and target
  venue:
  - resolves the venue's auto key via `OperationalSettings.auto_key_for(venue)`;
  - if that gate is currently **enabled=true**, records its prior value and sets it **false**;
  - if already false, it is left alone and no restore state is created;
  - unrelated venue autos are never touched.
- `disarm!` sets all manual-canary DB gates false, then restores **every** persisted paused auto gate
  (source and target) to its exact prior value, and clears the state. Idempotent and safe after a
  partial arm / a canary that never ran.
- Prior values are persisted per gate key in `storage/manual_canary_gate_state.json`
  (`{ route, paused_autos: { KEY => { previous_value, venue, role, paused_at } } }`) so arm and disarm
  (separate processes) agree on what to restore.
- `manual_canary_gate_status` now returns both a `source_auto` and a `target_auto` section, each with
  `role, venue, key, current_value, currently_enabled, would_pause, previous_value, restore_pending`.

Only source/target venue autos are modified; live gates and unrelated venue autos are unchanged.
Fail-closed: on any failure the operator runs `disarm`, which disables the live gates and restores all
paused autos.

The arm/disarm/status rake tasks are unchanged — they call the service and print its result, so the
new `paused_autos` / `restored_autos` / `target_auto` fields flow through automatically.

---

## Files changed
- `app/services/migration_manual_canary_gates.rb` — pause/restore both venue autos; persisted
  `paused_autos` collection; `source_auto` + `target_auto` status; idempotent disarm.
- `test/services/migration_manual_canary_gates_test.rb` — rewritten with the required cases.

## Tests (test container, isolated DB)
`migration_manual_canary_gates_test` — 12 runs, 0 failures:
- target ethereal auto true -> paused on arm, restored on disarm
- source AND target both true -> both paused and restored
- source false / target true -> only target changes
- target false / source true -> only source changes
- arm never modifies an unrelated venue auto (nado)
- disarm idempotent
- failure path: disarm disables gates AND restores both autos after a canary that never ran
- status reports both source_auto and target_auto

Required suites (gates + planner + readiness + random_readiness + runner) — 50 runs, 0 failures.
RuboCop on changed files — 0 offenses.

---

## Read-only verification (after deploy)
```
docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:manual_canary_gate_status from=extended to=ethereal
# expect:
#   source_auto: { venue: extended, key: EXTENDED_AUTO_REBALANCE_ENABLED, would_pause: false }
#   target_auto: { venue: ethereal, key: AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED, currently_enabled: true, would_pause: true }
docker compose -f docker-compose.prod.yml exec -T web bin/rails runner \
  'v=OperationalSettings.get("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"); puts [v.key,v.enabled,v.source].inspect'
```

## Deployment note
Not deployed. The running image still has the source-only pause; a redeploy is required before the
target-auto pause takes effect in production. Between the last disarm and the deploy the state file is
absent (disarm clears it), so there is no stale record.

## Safety confirmation
No live canary, no orders/signatures/cancels, no runner start/restart, no production DB/env/secrets
mutation. Venue adapters, order construction, migration execution semantics, and safety thresholds
unchanged. All arm/disarm/pause logic was exercised only in the isolated test DB with an isolated state
file. Production state unchanged: venue extended, extended short ~1.729, ethereal/nado flat, open orders
zero, inside_tolerance=true, runner inactive, route proofs 5/6.
