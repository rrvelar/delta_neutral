# Final Read-Only Production Readiness Audit — post 6/6 route proofs (2026-07-11)

**Verdict: PASS (with 3 WATCH items).** Safe to proceed to a separate
operator-approved runner restart. No live action taken in this audit.

## Evidence table

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Route proofs 6/6, stale 0, missing 0 | **PASS** | Fresh `migration:route_proofs`: all 6 routes READY_FOR_RANDOM, `stale_route_proofs: 0`, `missing_route_proofs: 0`, `route_policy_health: ok`, `route_policy_blocker: null` |
| 2 | Status blockers empty | **PASS** | `blockers: []`, `restart_blocked_by_route_proofs: false`, `route_proof_restart_blockers: []`, `current_direct_market_safe: true` |
| 3 | One-leg normal state | **PASS** | extended `1.694` only short; ethereal/nado `0.0`; open orders zero ×3 venues; `inside_tolerance: true`; gates false ×3; `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` restored `true` (`restore_pending: false`), extended auto `false` as before; runner `stopped`, systemd `inactive (dead)`, pid/lock null; `duplicate_runner_process: false`; `unconfirmed_venue_readbacks: []` |
| 4 | d024ca0 deployed in running image | **PASS** | Image `c0a47d8fbfa7`; in-container greps: `unsafe_gates_left_enabled` ×2 in canary runner, `record_source_close_position_readback_time!` ×3 in executor. HEAD = d024ca0; image built from that tree yesterday |
| 5 | Env flags exact | **PASS** | `.env.production` 170-178: `ETHEREAL_LOT_SIZE=0.0001`, `ETHEREAL_TICK_SIZE=0.1`, `ETHEREAL_ONCHAIN_ID=2`, `EXTENDED_OPEN/CLOSE_FILL_CONFIRMATION_ENABLED=true`, `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=false`, `ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED=true` — all as expected |
| 6 | ethereal->nado safe:false impact | **Does NOT block** | see below |
| 7 | Uncommitted runtime changes | **None blocking** | `.dockerignore` (+`audit/`, build hygiene), registry test file (test-only), untracked `audit/`, stray `extended` file (accidental shell-redirect artifact holding a Rails error message from Jul 9 — junk, safe to delete later) |
| 8 | Push needed? | **No (operationally)** | Deploys build from the local tree; running image already contains d024ca0. Push is code-backup/review hygiene, deferred per rules |

## Route proofs summary

| route | status | production_safe | proof ts |
|---|---|---|---|
| extended->ethereal | READY_FOR_RANDOM | true | 2026-07-04 |
| ethereal->extended | READY_FOR_RANDOM | true | **2026-07-10 19:57** |
| extended->nado | READY_FOR_RANDOM | true | 2026-07-07 |
| nado->extended | READY_FOR_RANDOM | true | 2026-07-04 |
| ethereal->nado | READY_FOR_RANDOM | **false** | 2026-07-04 |
| nado->ethereal | READY_FOR_RANDOM | true | 2026-06-11 |

## Q6: does ethereal->nado `route_production_safe: false` matter for restart?

**No — restart is not blocked, by code:**
- Restart gating: the "route proofs" blockers are generated only from
  `missing_route_proofs` / `stale_route_proofs`
  (`migration_random_readiness.rb:116-117`, `migration_execution_preflight.rb:132-133`);
  both are empty. The live status confirms: `restart_blocked_by_route_proofs: false`.
- Route selection: per-route eligibility requires only
  `proof[:status] == READY_FOR_RANDOM` (`migration_random_planner.rb:63`);
  neither the planner nor the rotation runner consults `route_production_safe`.

**WATCH implication:** since selection ignores that flag, a restarted runner *can*
legitimately pick ethereal->nado even though its last proof event was judged
latency-unsafe on 2026-07-04. This is pre-existing semantics (unchanged by this
work; changing it would be a policy edit, out of scope). If that flag should gate
rotation, run a fresh ethereal->nado certification canary before or shortly after
restart.

## Remaining risks (WATCH items)

1. **ethereal->nado latency-unsafe flag** (above) — eligible for selection despite
   `route_production_safe: false` from 2026-07-04.
2. **Extended read flakiness** — the dashboard snapshot diagnostic intermittently
   logs `extended_optional: Timeout::Error` (also seen during yesterday's canaries).
   Currently tolerated (`refresh_status: ok`, `accepted_for_execution: true`), but it
   is the same endpoint slowness that made Extended position readbacks slow; expect
   occasional slow readbacks in future migrations.
3. **Unpushed commit d024ca0** — the only copy of yesterday's fixes is this VPS
   (plus the baked image). A host failure loses them. Push when authorized.

## Exact next step if proceeding (NOT run)

```
sudo systemctl start delta-neutral-random-production-6.service
# equivalent to: docker compose -f docker-compose.prod.yml exec -T web \
#   bin/rails migration:random_production_runner position_id=6 live=true interval_seconds=28800 ... (per unit file)
# then watch: systemctl status delta-neutral-random-production-6.service --no-pager
#             bin/rails migration:random_production_status position_id=6
```

Note the runner task itself arms `MIGRATION_*` gates per its own flow; the current
gates-false state is the correct pre-restart posture.

## Confirmations

No live action taken: no runner/scheduler start, no canary, no arming, no orders/
signatures/cancels, no route, no deploy/rebuild/push, no DB/env/secret/code/
threshold/policy changes. Every command was a read (git/grep/status/route_proofs/
gate_status/systemctl status/in-container greps).
