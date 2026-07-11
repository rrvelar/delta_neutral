# Forensic Diagnosis: failed ethereal->extended certification canary (2026-07-10)

Read-only diagnosis of the 30.758s double-exposure measurement. No live action,
no code/DB/env changes. Evidence: executor receipt (line 2 of
`storage/hedge_migration_live_canaries/20260710.jsonl` — the runner's canary
receipt on line 3 drops the granular timestamps), plus code tracing and an
in-process read-only replay of the frozen-proof builder inside the web container.

## Exact timeline (from the executor receipt)

| time (UTC) | event |
|---|---|
| 18:28:41 | receipt/plan built (then ~34s of pre-execution preflight — outside the exposure window) |
| 18:29:15.234 | target leg (Extended open 1.70907) started |
| 18:29:16.503 → 19.603 | Extended build (3.10s) |
| 19.603 → 22.689 | ~3.09s unaccounted leg overhead (between build and sign) |
| 22.689 → 22.702 | sign (0.013s) |
| 22.703 → 23.729 | submit (1.03s); exchange accepted 18:29:23.729 |
| 23.729 → 38.375 | Extended position readback polling, 6 attempts @0.5s = **14.65s** |
| 38.375 → 41.623 | ~3.25s leg wrap-up before returning |
| 18:29:41.623 | target leg returned ⇒ `double_exposure_started_at` (no authoritative fill ⇒ fallback start) |
| 18:29:41.733 | source close submit marker — **0.0008s after target confirm. There was NO inter-leg gap.** |
| 41.733 → 45.089 | ~3.36s source-leg preamble: fresh Ethereal position read (frozen proof was nil) |
| 45.089 → 48.263 | Ethereal close: build 1.50s, sign 0.08s, submit 0.80s, **flat confirmed by position readback in 1 poll (0.77s)** — leg total 3.17s |
| **18:29:48.263** | **source actually flat (leg-internal authoritative readback)** |
| 48.277 → 18:30:12.380 | `final_readback_status` all-venue verification: **24.10s** (slow Extended read again) |
| 18:30:12.381 | `mark_time!` stamps `source_close_position_readback_confirmed_at` ⇒ `double_exposure_ended_at` |

Measured window: 41.622 → 12.380 = **30.758s**. Genuine overhedge window
(target-leg return → source actually flat): **≈6.6s**. The other **≈24.1s is
measurement inflation** — the end marker is stamped *after* the slow final
all-venue verification instead of at the leg's own flat confirmation.

## Answers to the numbered questions

**1. Why was frozen_source_position null? — A real logic bug in eba6b3c (Part A).**
`MigrationManualLiveCanaryRunner#frozen_source_position_proof` requires BOTH
`migration_db_gates_armed?` AND `production_runner_inactive?`, where the latter
accepts only runner status `stopped`/`failed`. But
`MigrationRandomProductionRunner#production_status` (line 515) returns
`"unsafe_gates_left_enabled"` whenever any migration gate is armed and no runner
process is running — which is **exactly the state of every supervised canary**.
Conditions 5 and 7 are mutually exclusive; the proof can never be built in the
scenario it was designed for. Proven by read-only replay in the container:
with the historical plan and canary-time gate state faithfully stubbed
in-process, `production_runner_inactive?` → false (status
`unsafe_gates_left_enabled`, pid nil, duplicate false) and the builder returns
nil; with gates disarmed the same check returns true. Cost: the close leg did a
fresh Ethereal position read (~3.4s preamble) instead of using the frozen size.

**2. Why position_readback instead of authoritative_fill (both ends)?** The
authoritative fill paths are env-gated and default-OFF, and **none of the flags
exist in `.env.production`**: `EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED` /
`EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED`
(extended_mainnet_lifecycle_check.rb:615-621) and
`ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED` /
`ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED`
(ethereal_hedge_execution_service.rb:776-781). With the flags off,
`open_fill_confirmation`/`close_fill_confirmation` are never built, so
`apply_authoritative_target_open_confirmation!` and
`apply_authoritative_source_close_confirmation!` both fell back (by design,
fail-closed) to position_readback.

**3. Why did source close start ~27.5s after target confirmation? — It didn't.**
`target_confirm_to_source_close_submit_latency_seconds = 0.0008`. The earlier
inference was a receipt-interpretation error: the runner's canary receipt drops
the granular executor timestamps (`from_executor_result` copies a fixed subset),
so the gap appeared between two *confirmation* markers. The real composition
after target confirm: 3.36s close-leg preamble + 3.17s close action + 24.10s
final verification before the end marker was stamped.

**4. Why 14.65s Extended target-open readback?** With
`EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED` unset, `confirm_after_submit` used the
slow `poll_short_readback` position-readback path: 6 polls over 14.65s until the
Extended position endpoint reflected the new short. The consolidation work
reduced build reads (build was 3.10s), but the readback fast path was never
enabled. (Additional Extended leg overhead: ~3.09s between build and sign and
~3.25s wrap-up after confirmation — secondary but real.)

**5. Did Extended authoritative fill happen but fail to propagate?** No fill
confirmation was ever produced (`open_fill_confirmation: nil` in the leg,
`target_open_fill_confirmed_at: null`). Feature disabled by env, not a
propagation failure.

**6. Did Part B defer target diagnostics trigger?** No. The Extended Part B
defer (extended_mainnet_lifecycle_check.rb:702-710) only triggers after an
authoritative FULL order-by-id fill — unreachable with the flag off. The
Ethereal-side defer (account diagnostics deferred when `migration && close`,
ethereal_hedge_execution_service.rb:255-257) DID work — visible in the fast
1.50s close build.

**7. Did the executor wait for target final readback before source close?** No —
0.0008s between target confirmation and source-close submit marker. The waiting
happened *inside* the target leg (14.65s position-readback confirmation), which
is intended fail-closed behavior with the fast-fill flag off.

**8. Do receipt fields distinguish the four times?** The EXECUTOR receipt does:
`target_open_fill_confirmed_at` (null), leg-internal
`readback_confirmed_at` (18:29:38.375), leg return / `target_leg_accepted_at`
(18:29:41.623), `source_close_submit_started_at` (18:29:41.733). The RUNNER
canary receipt does not — it omits the granular `*_started_at/*_finished_at`
fields, which is what misled the initial analysis.

**9. Bug vs interpretation vs control flow?** Three distinct findings:
- **Code bug (eba6b3c Part A):** self-contradictory frozen-proof invariants (Q1).
- **Measurement bug (pre-existing, exposed here):** executor stamps
  `source_close_position_readback_confirmed_at` with wall-clock AFTER
  `final_readback_status` (executor lines 711-712) instead of using the close
  leg's own authoritative flat-readback time (18:29:48.263). When no
  authoritative close fill exists, the double-exposure end inherits the entire
  final-verification duration (~24.1s here). The leg's internal flat
  confirmation IS a position readback, so using its timestamp stays fail-closed.
- **Config gap (not a bug):** all four fill-confirmation fast-path flags are
  default-OFF and absent from `.env.production`; the <5s design assumed them on.

## Root cause (one paragraph)

The <5s path never engaged: the frozen source proof self-cancels because arming
the gates flips the runner status to `unsafe_gates_left_enabled` (+~3.4s), the
Extended/Ethereal authoritative fill fast paths were never enabled in prod env
(target readback +14.65s slow path; no authoritative end anchor), and with no
authoritative close fill the double-exposure end marker was stamped after a
24.1s all-venue final verification. Genuine exposure was ≈6.6s; measured 30.76s.

## Smallest safe fix proposal (not implemented)

1. **Frozen proof (1 line):** in `MigrationManualLiveCanaryRunner#production_runner_inactive?`,
   accept `unsafe_gates_left_enabled` alongside `stopped`/`failed` (it already
   requires `pid.nil?` and no duplicate process; that status by definition means
   gates armed + no process — the exact supervised-canary state). Alternatively
   compare on `status[:pid].nil? && !status[:lock] && status[:duplicate_runner_process] != true`.
2. **Window end (2-3 lines):** in `execute_receipt`, when the confirmed close
   leg carries `timing[:readback_confirmed_at]`, use it for
   `source_close_position_readback_confirmed_at` instead of `mark_time!` after
   `final_readback_status` (keep `mark_time!` as fallback). Final verification
   still runs and still gates success — it just stops inflating the window.
3. **Config (operator decision, separate step):** set
   `EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED=true` and
   `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=true` in `.env.production` to engage
   the authoritative order-by-id fast paths (both fail closed to position
   readback).
4. **Optional receipt fix:** surface `target_leg_submit_*`,
   `source_close_submit_*`, and `target_confirm_to_source_close_submit_latency_seconds`
   in the runner canary receipt so window decomposition doesn't require the
   executor line.

Projected window with 1–3: close preamble ~0-1s (frozen size) + close
build/sign/submit ~2.4s + authoritative fill confirm ~1s ≈ **4-5s** — consistent
with the expected ~4.35s floor; fix 2 alone would have recorded ≈6.6s.

## Tests needed

- Runner unit test reproducing Q1: runner status `unsafe_gates_left_enabled`
  with nil pid / no duplicate + all armed-canary invariants ⇒ proof is built
  (fails before fix 1); plus existing nil cases stay nil (gates unarmed, runner
  running, ethereal auto enabled, zero size).
- Executor unit test for fix 2: confirmed close leg with
  `timing[:readback_confirmed_at]` + artificially slow final verifier ⇒
  `double_exposure_ended_at` equals the leg readback time; absent that timing
  field ⇒ falls back to current stamped-after-verification behavior.
- Flag-off regression: fill-confirmation builders return nil and both
  `double_exposure_*_source` remain `position_readback` (fail-closed unchanged).

## Confirmations

No live action taken: no canary, no arm, no runner, no orders/signatures/
cancels, no route, no deploy/push, no code/DB/env/secret/threshold/policy
changes. All container commands were read-only status/replay probes; the
frozen-proof replay stubbed `OperationalSettings.enabled?` in-process only.
