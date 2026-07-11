# Route Proofs 6/6 ACHIEVED — ethereal->extended certified <5s (2026-07-10)

Autonomous repair + certification loop result: **all 6 routes READY_FOR_RANDOM,
0 stale, 0 missing; runner restart blockers now empty.** Runner/scheduler never
started. Final state one-leg normal.

## Certified run (ethereal->extended, target_first)

- `LIVE_CANARY_CONFIRMED`, `route_production_safe: true`, proof timestamp
  `2026-07-10T19:57:02Z` in the registry
- **double_exposure_seconds: 3.929 < 5** (was 30.758 this morning)
- target_total_latency_seconds: 9.32 < 15; total_migration_latency_seconds: 14.33 < 45
- Window: Extended open authoritative fill `19:57:45.319`
  (`extended_order_by_id_fill`) → Ethereal flat position readback `19:57:49.248`
- Decomposition: inter-leg 0.0004s → close preamble 0.023s (frozen proof sized the
  close: `{short_size: 1.6931, invariants_proven: true}`) → build 1.59s → sign 0.05s →
  submit 0.77s → flat position readback 1.48s (1 poll)
- Orders: `2075670822826610688` (Extended open), `9124f0b6-...` (Ethereal reduce-only close)
- Receipts: `storage/hedge_migration_live_canaries/20260710.jsonl`

## What was fixed (commit `d024ca0` on top of eba6b3c)

1. **Frozen source proof** (`migration_manual_live_canary_runner.rb`): accept runner
   status `unsafe_gates_left_enabled` (the normal armed-canary state) as inactive when
   pid is nil and no duplicate runner process exists. Running/duplicate/locked states
   still block. Effect: close-leg preamble 3.36s → 0.02s.
2. **Double-exposure end anchoring** (`hedge_venue_migration_executor.rb`): use the
   close leg's own flat-readback timestamp for the window end; wall-clock stamp only as
   fallback. Final all-venue verification still runs and still gates success. Effect:
   removed the 24.1s verification inflation.
3. **Receipt observability**: canary receipts now carry granular leg timing
   (build/sign/submit/readback), inter-leg latency, fill sources/agreement,
   frozen-proof status.
4. Tests: +6 (runner frozen-proof matrix incl. unsafe_gates_left_enabled positive and
   pid/duplicate/locked negatives; executor end-anchor + fallback). 79 runner+executor
   tests and 136 adjacent tests green; RuboCop clean.

## Config changes (.env.production, backups taken)

- Fast-fill flags enabled: `EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED=true`,
  `EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED=true`, `ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED=true`
- **`ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=false`** — key finding: Ethereal's
  order-list fill read is SLOW (~3.8s observed) while its position readback is FAST
  (~0.7-1.5s). The "fast" fill path on the Ethereal close actually cost 6.24s vs 3.93s.
  Fail-closed position readback (covered by the new end-anchor tests) is both faster
  and the original conservative confirmation. Extended is the opposite (position
  readback ~14.6s, order-by-id ~1s), so Extended flags stay on.
- Deploys: image `c0a47d8fbfa7` (code fixes + flags), then env-only container recreate
  for the Ethereal close flag flip.

## Canary sequence run today (one at a time, full arm/disarm discipline each)

1. 18:10 reposition extended->ethereal — confirmed (pre-fix baseline)
2. 18:28 certification attempt — position-safe, FAILED latency 30.76s (forensics in
   `docs/ethereal_to_extended_cert_failure_forensic_diagnosis.md`)
3. 19:44 reposition extended->ethereal — confirmed; validated authoritative fill paths
   (both ends `authoritative_fill`, agreements true)
4. 19:48 certification attempt — position-safe, FAILED latency 6.24s (Ethereal
   order-list read 3.83s identified via new observability)
5. 19:57 certification — **PASSED: 3.93s < 5** after Ethereal close flag flip

Every canary ended with disarm + auto restore + one-leg normal verification. No
emergency actions were needed at any point.

## Final production state

- Route proofs: **6/6 READY_FOR_RANDOM**, `stale: 0`, `missing: 0`,
  `random_production_status blockers: []`
- Venue: extended holds `1.694` (fresh target ~1.687-1.69 band, inside_tolerance true)
- Ethereal/nado flat; open orders zero everywhere; unconfirmed readbacks empty
- Gates all false; `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` restored true;
  runner `stopped`/systemd `inactive`; no duplicate process
- Commit: `d024ca0` (local only, not pushed per rules)

## Remaining observations (not in scope, flagged only)

- `ethereal->nado` is READY_FOR_RANDOM but carries a pre-existing
  `route_production_safe: false` from its 2026-07-04 proof — unchanged by this work;
  worth a certification pass of its own if that flag matters for rotation.
- Uncommitted pre-existing changes left untouched: `.dockerignore` (audit/ ignore),
  `test/services/migration_route_proof_registry_test.rb`.

**Loop complete — success criteria met; autonomous loop ends here.**
