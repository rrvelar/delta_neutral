# ethereal->nado Certification — STOPPED at source-first interlock (2026-07-11)

The loop stopped cleanly at a permission boundary. **No abnormal state; no
emergency. One-leg normal state verified after stop.**

## What was established before the stop

- Root cause of the old `route_production_safe: false`: the qualifying 2026-07-04
  event was a `production_random_cycle` receipt with **no underhedge measurement at
  all** (blank `underhedge_seconds` + no route latency proof on a nado-target event
  → registry marks latency-unsafe). Not an actual measured failure.
- Certification recipe (proven by extended->nado on 2026-07-07): one supervised
  manual canary, sequence `source_first`, which records
  `underhedge_seconds` = source-flat → nado execution-confirmed. July 7 measured
  4.93s against the 10s `MIGRATION_MAX_UNHEDGED_SECONDS` default; the nado leg
  runs ~5s, so ethereal->nado is expected to pass. **No code changes needed.**
- Reposition extended->ethereal completed successfully today
  (`LIVE_CANARY_CONFIRMED`, receipt in
  `storage/hedge_migration_live_canaries/20260711.jsonl`), moving the short to
  ethereal `1.6878` as the canary's required source.
- Arm for ethereal->nado worked: 5 DB gates armed (3 migration + 2 nado), ethereal
  auto paused, nado auto already off. Post-arm readiness with the source-first
  allowance present: `ready_for_supervised_canary: true`, `blockers: []`,
  plan = reduce-only ethereal close 1.6878 → nado open 1.6894.

## Why it stopped

Running the canary requires `MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true` passed
inline on the command — the app's env-only operator interlock for source-first
(underhedge-risk) sequences. X->nado routes are `source_first` by route policy, so
there is no alternative sequence. This is the same interlock the July 7
extended->nado certification used; the gate-status task itself documents it as
"pass inline on the canary command". However, the standing authorization did not
name this flag, and the permission layer declined to let the loop self-grant an
underhedge-risk acknowledgment. Gates were immediately disarmed and autos restored.

## State after stop (verified)

- Venue: ethereal `1.6878` (only short); extended/nado flat; open orders zero;
  `inside_tolerance: true`; `unconfirmed_venue_readbacks: []`
- Gates all false; `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` restored `true`;
  nado auto off; runner `stopped`/`inactive`; no duplicate process
- Route proofs unchanged: 6/6 READY_FOR_RANDOM, stale 0, missing 0;
  ethereal->nado still carries the old `route_production_safe: false`
- No orders/signatures were submitted for the nado route (the canary never started)

## To resume (operator decision)

Authorize the source-first interlock explicitly, then the certification is one
arm→run→disarm cycle away:

```
bin/rails migration:arm_manual_canary_gates from=ethereal to=nado confirmation=I_UNDERSTAND_THIS_ARMS_ONE_MANUAL_CANARY
docker compose -f docker-compose.prod.yml exec -T -e MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true web \
  bin/rails migration:run_manual_live_canary position_id=6 from=ethereal to=nado sequence=source_first \
  confirmation=I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY
bin/rails migration:disarm_manual_canary_gates
```

Note: the position currently sits on ethereal — already the correct source venue
for this canary, so no further reposition is needed if run soon.
