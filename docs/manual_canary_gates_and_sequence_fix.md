# Position #6 — Manual Canary Blockers: Gate Evaluation & Sequence Alignment

**VPS:** France  ·  **Path:** /opt/delta_neutral  ·  **Date:** 2026-07-07
**Scope:** Investigation + code/test changes only. No live orders, no canary, no runner start, no
production gate/DB mutation. Goal remains 6/6 READY_FOR_RANDOM (no subset policy).

Two blockers seen during the Step 1 `extended->nado` supervised canary are explained and fixed.

---

## Problem 1 — Live gates are DB-backed, so inline ENV had no effect

### Code path
`OperationalSettings.get(key, env:)` (app/services/operational_settings.rb:72) resolves in this order:
1. `OperationalSetting` **DB row** if present  ->  wins
2. else process `env[key]`
3. else default `false`

`OperationalSettings.enabled?` (line 83) uses `get` for every ALLOWED_KEY, and all five migration
gates are ALLOWED_KEYS (`MIGRATION_KEYS`, lines 19-28). The canary planner reads them via
`bool_env` (migration_manual_canary_planner.rb:436), which routes ALLOWED keys through
`OperationalSettings.enabled?`.

### Read-only evidence (production)
```
MIGRATION_LIVE_ENABLED:              enabled=false source=DB setting raw="false"
MIGRATION_MANUAL_LIVE_CANARY_ENABLED:enabled=false source=DB setting raw="false"
MIGRATION_FULL_ALLOWED:              enabled=false source=DB setting raw="false"
AERODROME_NADO_HEDGE_LIVE_ENABLED:   enabled=false source=DB setting raw="false"
AERODROME_NADO_LIVE_MIGRATION_ENABLED:enabled=false source=DB setting raw="false"
```

Every gate has a **DB row set to "false"**, which authoritatively shadows the inline
`env GATE=true` the command passed. This is a **safety feature**, not a bug: a DB-disabled gate must
not be overridable by a one-off process env var.

Note: some gates are ENV-only (not ALLOWED_KEYS) and DO honor inline env —
`EXTENDED_LIVE_ENABLED`, `EXTENDED_MAINNET_PROBE_ENABLED`, `AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED`,
`MIGRATION_SOURCE_FIRST_CANARY_ALLOWED`.

### Fix (Task 5) — safe temporary gate arming
New service `MigrationManualCanaryGates` + three rake tasks:

- `migration:manual_canary_gate_status from=X to=Y` — **read-only**; lists the DB gates and the
  ENV-only gates for the route, with each gate's value/source.
- `migration:arm_manual_canary_gates from=X to=Y confirmation=I_UNDERSTAND_THIS_ARMS_ONE_MANUAL_CANARY`
  — sets **only the DB-backed** gates for that route to true (audited via OperationalSetting reason).
  Prints before/after and the ENV-only gates to pass inline. Never runs a canary.
- `migration:disarm_manual_canary_gates` — sets **all** manual-canary DB gates back to false
  (fail-closed cleanup). No confirmation needed (only disables). Run after every canary and after
  any failure.

Safe operator flow (DB gates via arm task; ENV-only gates inline; always disarm):
```
docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:manual_canary_gate_status from=extended to=nado
docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:arm_manual_canary_gates from=extended to=nado confirmation=I_UNDERSTAND_THIS_ARMS_ONE_MANUAL_CANARY
docker compose -f docker-compose.prod.yml exec -T web env EXTENDED_LIVE_ENABLED=true EXTENDED_MAINNET_PROBE_ENABLED=true MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true \
  bin/rails migration:run_manual_live_canary position_id=6 from=extended to=nado sequence=source_first confirmation=I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY
docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:disarm_manual_canary_gates   # ALWAYS, even on failure
```
(These arm/disarm tasks were NOT run on production during this investigation.)

---

## Problem 2 — Route policy says source_first, planner reported target_first only

### Code paths
- **Route policy** `MigrationRouteOperationalPolicy#route_strategy` (migration_route_operational_policy.rb):
  nado-target routes default to `source_first` (`DEFAULT_STRATEGIES`, `default_strategy`). Production
  DB confirms `MIGRATION_ROUTE_EXTENDED_TO_NADO_STRATEGY="source_first"`.
- **Readiness** `MigrationRandomReadiness#commands_for` derives the canary command's `sequence=` from
  this policy -> emits `source_first`.
- **Canary planner** `MigrationManualCanaryPlanner` (used by BOTH `MigrationManualLiveCanaryRunner`
  and `MigrationManualLiveCanaryReadiness`) **hardcoded** `recommended_sequence: "target_first"`,
  `supported_sequences: %w[target_first]`, `source_first_supported: false` for **every** route —
  decoupled from the route policy. That mismatch is the contradiction.

### Why they disagreed
The planner's sequence metadata was a static literal, not derived from the route policy, so it always
claimed target_first even though the policy/runner/registry treat nado targets as source_first.

### Decision (Task 3) — extended->nado is source_first
Evidence: DB route policy = source_first; the route-proof registry has dedicated
`source_first_nado_target` latency-proof handling; the production runner already proved `ethereal->nado`
as source_first (READY via `production_random_cycle`); and `MigrationManualLiveCanaryRunner` records
the nado latency-proof fields (`route_latency_proof`, `route_production_safe`, `double_exposure_seconds`,
`underhedge_seconds`). So source_first is executable and provable for nado targets.

### Fix (Task 4) — planner derives its sequence from the route policy
`MigrationManualCanaryPlanner` now reads `MigrationRouteOperationalPolicy#route_strategy` as the single
source of truth: `recommended_sequence`, `supported_sequences`, and `source_first_supported` reflect
the policy. Result: readiness, planner, route policy, and the canary command all agree —
`source_first` for `extended->nado`, `target_first` for target_first routes. The source_first safety
gate (`MIGRATION_SOURCE_FIRST_CANARY_ALLOWED`) is unchanged (not loosened). The overhedge/underhedge
warning text now matches the recommended sequence.

---

## Files changed
- `app/services/migration_manual_canary_planner.rb` — recommended/supported sequence + source_first
  support derived from route policy; sequence-aware risk warning.
- `app/services/migration_manual_canary_gates.rb` — NEW: arm/disarm/status for manual-canary gates.
- `lib/tasks/migration.rake` — NEW tasks: `manual_canary_gate_status`, `arm_manual_canary_gates`,
  `disarm_manual_canary_gates`.
- `test/services/migration_manual_canary_planner_test.rb` — routes now assert the policy sequence;
  added an explicit `extended->nado -> source_first` agreement test.
- `test/services/migration_manual_canary_gates_test.rb` — NEW: gate-key selection, confirmation-gated
  arm, fail-closed disarm.

## Tests run (test container, isolated DB)
- migration_manual_canary_gates_test, migration_manual_canary_planner_test,
  migration_manual_live_canary_readiness_test, migration_random_readiness_test,
  migration_manual_live_canary_runner_test -> **44 runs, 0 failures**.
- RuboCop on all changed files -> **0 offenses**.

## Read-only verification commands
```
# gates are DB-set false (why inline env failed):
docker compose -f docker-compose.prod.yml exec -T web bin/rails runner \
  'OperationalSettings.get("MIGRATION_LIVE_ENABLED").tap { |v| puts [v.key, v.enabled, v.source].inspect }'
# route policy sequence:
docker compose -f docker-compose.prod.yml exec -T web bin/rails runner \
  'puts MigrationRouteOperationalPolicy.new.route_strategy(from: "extended", to: "nado")'   # => source_first
# which gates a canary needs + current state:
docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:manual_canary_gate_status from=extended to=nado
```

## Safety confirmation
- No live orders, no signatures, no live canary, no runner start/restart.
- No production DB/env/secrets mutation: only read-only `OperationalSettings.get` / status queries were
  run against production; arm/disarm were exercised only in the isolated test DB.
- Fail-closed behavior preserved throughout; disarm always returns gates to false.

## Remaining / follow-up (not executed)
- The two stale routes (`extended->nado`, `ethereal->extended`) still need supervised proofs; the plan
  is unchanged (source_first for extended->nado). Live execution remains gated on explicit approval.
- When the live source_first `extended->nado` canary is eventually run, verify the resulting receipt
  yields `READY_FOR_RANDOM` (not `NOT_PRODUCTION_SAFE_LATENCY`) — i.e. the nado latency-proof fields
  are within thresholds. If not, use `migration:prove_route_latency` (policy-strategy path) instead.
