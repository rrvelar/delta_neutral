# Manual Canary — Scoped Source Auto-Rebalance Pause/Restore

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Scope:** Code + tests only. No live canary, no runner start, no order/signature, no production DB
mutation. (Change is NOT deployed yet — redeploy required before production use.)

Extends the manual-canary gate flow so `arm_manual_canary_gates` also pauses the **source venue's**
auto-rebalance gate for the canary window, and `disarm_manual_canary_gates` restores it exactly. This
resolves the Step 2 `nado->ethereal` NO-GO (`AERODROME_NADO_AUTO_REBALANCE_ENABLED=true`).

---

## Behavior

- `arm!` sets the manual-canary DB live gates true (unchanged), then:
  - Resolves the **source** venue's auto key via `OperationalSettings.auto_key_for(from)`
    (e.g. `AERODROME_NADO_AUTO_REBALANCE_ENABLED` for `from=nado`).
  - If that gate is currently **enabled=true**, records its prior value to a small state file and
    sets it **false**. If already false, it is a no-op (and never clobbers an existing pause record).
  - Never touches the **target** venue's auto gate.
- `disarm!` (always safe, no confirmation) sets all manual-canary DB gates false, then restores any
  paused source auto gate to its exact prior value and clears the record. Idempotent: a missing or
  absent pause record is a no-op.
- The prior value is persisted to `storage/manual_canary_gate_state.json` so `arm` and `disarm`
  (separate processes) agree on what to restore. Path is overridable
  (`MigrationManualCanaryGates.state_path=`) for test isolation.
- `manual_canary_gate_status` now includes a `source_auto` section: `key`, `current_value`,
  `currently_enabled`, `would_pause`, `previous_value`, `restore_pending`.

Only the source auto gate is modified; live gates and target auto are unchanged. Fail-closed: on any
failure the operator runs `disarm`, which both disables the live gates and restores the source auto.

---

## Files changed
- `app/services/migration_manual_canary_gates.rb` — source auto pause/restore, persisted pause record,
  `source_auto` status, idempotent disarm.
- `test/services/migration_manual_canary_gates_test.rb` — isolated `state_path`; new tests.

(The `migration:arm_manual_canary_gates` / `disarm_manual_canary_gates` / `manual_canary_gate_status`
rake tasks are unchanged — they call the service, so the new behavior flows through automatically.)

---

## Tests (test container, isolated DB)
`test/services/migration_manual_canary_gates_test.rb` — 10 runs, 0 failures. Cases include:
- nado source auto true is paused on arm and restored on disarm
- source auto already false stays false (not paused)
- disarm is idempotent / safe with nothing armed
- target venue auto is never modified
- failure path: disarm still disables gates AND restores source auto after a canary that never ran
- status reports the source auto pause state

Manual-canary cluster (gates + planner + readiness + runner) — 45 runs, 0 failures. RuboCop — 0
offenses on changed files.

---

## Read-only verification commands
```
# current source auto value (the Step 2 blocker):
docker compose -f docker-compose.prod.yml exec -T web bin/rails runner \
  'v=OperationalSettings.get("AERODROME_NADO_AUTO_REBALANCE_ENABLED"); puts [v.key,v.enabled,v.source].inspect'

# after redeploy, the status task shows the source_auto pause plan (read-only):
docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:manual_canary_gate_status from=nado to=ethereal
# expect source_auto: { key: AERODROME_NADO_AUTO_REBALANCE_ENABLED, would_pause: true, restore_pending: false }
```

---

## Deployment note
The running production image does not yet contain this change (verified read-only:
`manual_canary_gate_status` returns no `source_auto` section). A rebuild/redeploy is required before the
auto-pause takes effect in production. No deploy was performed.

## Safety confirmation
- No live canary, no orders/signatures/cancels, no runner start/restart.
- No production DB/env/secrets mutation: production was only queried read-only; all arm/disarm/pause
  logic was exercised solely in the isolated test DB with an isolated state file.
