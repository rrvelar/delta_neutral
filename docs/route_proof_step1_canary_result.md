# Position #6 — Step 1 Supervised Canary (extended -> nado) — Execution Result

**VPS:** France  ·  **Path:** /opt/delta_neutral  ·  **Date:** 2026-07-07
**Outcome:** Live canary was issued as approved but the system **fail-closed with zero live activity**.
**No orders, no signatures, no state change. Runner not started. No DB/env/secrets mutated.**

Scope executed: **Step 1 only** (extended -> nado, source_first, Position #6). Steps 2 and 3 were
**not** run.

---

## Sequence of actions (all via `docker compose -f docker-compose.prod.yml exec -T web`)

### 1. Preflight — first attempt: NO-GO (fail-closed)
`migration:random_production_status position_id=6` and the source_first dry-run showed the hedge had
drifted **out of tolerance** (target had grown to ~1.758 vs Extended short 1.622; drift 0.136 vs
tolerance 0.053). `inside_tolerance=false`, `current_direct_market_safe=false`. Per the approval
conditions, Step 1 was **not** executed. No live command was issued.

### 2. Preflight — retry: GO
After the hedge was rebalanced (Extended short 1.622 -> **1.762**), re-running the two read-only
checks passed every go/no-go condition:

| Condition | Value | Result |
|---|---|---|
| runner stopped / pid null / duplicate=false | stopped / None / false | ok |
| current venue = extended | extended | ok |
| active short venue exactly extended | ["extended"] | ok |
| ethereal & nado flat | 0.0 / 0.0 | ok |
| open orders zero (all venues) | zero / zero / zero | ok |
| inside_tolerance = true | true | ok |
| dry-run: only expected live-gate blockers | yes (no tolerance/readback blocker) | ok |

Dry-run planned legs: close Extended (buy 1.762 -> 0), open Nado (sell ~1.760). `orders=0, signatures=0`.

### 3. Live Step 1 canary — issued exactly as approved
```
docker compose -f docker-compose.prod.yml exec -T web env \
  MIGRATION_LIVE_ENABLED=true MIGRATION_MANUAL_LIVE_CANARY_ENABLED=true MIGRATION_FULL_ALLOWED=true \
  AERODROME_NADO_HEDGE_LIVE_ENABLED=true AERODROME_NADO_LIVE_MIGRATION_ENABLED=true \
  MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true \
  bin/rails migration:run_manual_live_canary position_id=6 from=extended to=nado sequence=source_first \
    confirmation=I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY
```

**Result — fail-closed, nothing submitted:**

```
submitted:            false
would_execute_live:   false
dry_run:              true
orders_submitted:     0
orders_placed:        0
signatures_created:   0
final_status:         blocked_before_submit
```

Blockers reported:
```
- MIGRATION_LIVE_ENABLED must be true for supervised live canary.
- MIGRATION_MANUAL_LIVE_CANARY_ENABLED must be true.
- MIGRATION_FULL_ALLOWED must be true for full supervised canary.
- AERODROME_NADO_HEDGE_LIVE_ENABLED must be true
- AERODROME_NADO_LIVE_MIGRATION_ENABLED must be true
- source_first canary is blocked until target venue live-open preflight passes and MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true
```

Route support reported:
```
requested_sequence:   source_first
recommended_sequence: target_first
source_first_supported: false
supported_sequences:  ["target_first"]
```

### 4. Post-canary verification — state unchanged
```
route_proofs:  completed = [extended->ethereal, ethereal->nado, nado->ethereal, nado->extended]
               stale     = [ethereal->extended, extended->nado]           (still 4/6, unchanged)
status:        stopped | pid None | duplicate false
venue:         extended | active_short_venues ["extended"]
inside_tolerance: true | current_direct_market_safe: true
shorts:        extended 1.762, ethereal 0.0, nado 0.0                     (Extended short unchanged)
```

---

## Why the canary did not execute (two independent blockers)

1. **Live gates are read from OperationalSettings (DB), not process ENV.** All five gates still
   evaluated as "must be true" despite being passed inline via `env …`. The non-persistent inline
   approach specified in the command therefore has **no effect** on these gate checks. Making them
   effective would require a persistent OperationalSettings/DB change, which is explicitly prohibited.

2. **`extended->nado` does not support `source_first`.** The canary planner reports
   `source_first_supported: false`, `supported_sequences: ["target_first"]`,
   `recommended_sequence: "target_first"`. The approved command used `sequence=source_first`, which
   this route cannot execute. Note this contradicts the route *policy* strategy
   (`MIGRATION_ROUTE_EXTENDED_TO_NADO_STRATEGY = source_first`) surfaced by
   `migration:random_readiness` — a configuration inconsistency worth reconciling.

Because of these, the run stayed in `blocked_before_submit` and placed nothing.

---

## Safety confirmation

- Live canary issued exactly as approved; system fail-closed. **0 orders, 0 signatures, submitted=false.**
- Did **not** start/restart `delta-neutral-random-production-6.service` (still `inactive`, pid None).
- Did **not** enable any persistent gate; did **not** mutate production DB/env/secrets.
- Did **not** run Step 2 or Step 3; did **not** change the approved sequence.
- Route proofs and hedge state are byte-identical before/after (still 4/6, Extended short 1.762).
- All commands used `docker compose -f docker-compose.prod.yml exec -T web`.

---

## What is required before Step 1 can actually execute (needs your decision — not done)

Either or both of the following are outside the current approval/constraints:

1. **Enable the live gates via OperationalSettings** (persistent DB change you prohibited): the five
   gates above must be true at evaluation time. Inline ENV does not satisfy them on this deployment.
2. **Reconcile the sequence for `extended->nado`:** the route only supports `target_first`, but the
   approved command and the route policy specify `source_first`. Proceeding would require approving
   `sequence=target_first` (and confirming the resulting proof satisfies the nado-target latency
   requirement) or fixing the route strategy config.

I am holding here. No further action without your explicit approval addressing the two points above.
