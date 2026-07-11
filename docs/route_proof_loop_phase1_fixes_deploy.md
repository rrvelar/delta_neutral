# Route-Proof Loop Phase 1: forensic fixes + deploy (2026-07-10)

- Commit: `d024ca0` "Fix frozen source proof and double-exposure end anchoring for manual canaries" (on top of eba6b3c)
- Files changed: `app/services/migration_manual_live_canary_runner.rb` (fix 1: accept
  `unsafe_gates_left_enabled` as inactive with nil pid + no duplicate; fix 4: surface
  granular leg timing in canary receipt), `app/services/hedge_venue_migration_executor.rb`
  (fix 2: `record_source_close_position_readback_time!` anchors double-exposure end at the
  close leg's own flat readback; final verification still runs and gates success), plus
  tests in both matching test files.
- Tests: 79 runs runner+executor (0 failures), 136 runs adjacent suites
  (extended lifecycle / ethereal service / readiness / route-proof registry / receipt
  writer, 0 failures). RuboCop: 4 files, no offenses.
- Env: appended 4 fail-closed fast-fill flags to `.env.production` (backup taken):
  `EXTENDED_OPEN/CLOSE_FILL_CONFIRMATION_ENABLED=true`,
  `ETHEREAL_CLOSE/OPEN_FILL_CONFIRMATION_ENABLED=true`.
- Deploy: image `c0a47d8fbfa7`, container recreated. In-container verification:
  flags active, ETHEREAL_* constants present, fix-2 method present, and fix 1 proven —
  `production_runner_inactive?` now true under armed-gates replay (was false).
- Production at rest: venue extended 1.703, ethereal/nado flat, open orders zero,
  inside_tolerance true, gates false, runner inactive, no duplicate.
- Next: reposition canary extended->ethereal, then ethereal->extended certification.
- Loop continues.
