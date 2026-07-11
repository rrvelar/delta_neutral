# Position #6 — Step 3 `ethereal->extended` Double-Exposure Investigation

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Type:** Read-only investigation (no live canary, no runner start, no gates, no DB/env/secrets mutation).

Why `ethereal->extended` (target_first) migrated safely but was NOT certified: `double_exposure_seconds
= 37.16 > MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS = 5`.

---

## Root cause

The 37s overhedge window is the **Ethereal source-close confirmation window**, dominated by **slow
Ethereal position readback polling** — not an Extended-open issue.

- Executor sets `double_exposure_started_at = target_leg_accepted_at` (Extended open accepted) and
  `double_exposure_ended_at = source_close_flat_confirmed_at` (Ethereal confirmed flat)
  (`app/services/hedge_venue_migration_executor.rb:728-731`). Because the route is **target_first**,
  Extended opens first, so the entire Ethereal-close-confirmation time is counted as overhedge.
- Ethereal confirms the close via `poll_post_submit_readback`
  (`app/services/ethereal_hedge_execution_service.rb`): `POST_SUBMIT_READBACK_ATTEMPTS = 12`,
  `POST_SUBMIT_READBACK_DELAY_SECONDS = 0.25`. Sleep totals only ~2.75s, so ~34s came from ~12
  position-read API calls at ~2.8s each — the Ethereal `read_position` endpoint / close-settlement
  lag is the bottleneck.
- Systematic, not a one-off: any migration OUT of Ethereal under target_first pays this ~37s window.
  This is also why the production runner never certified this route (same target_first policy).

---

## Exact timing table

| Field | Step 3 ethereal->extended (target_first) | Step 1 extended->nado (source_first) | Step 2 nado->ethereal (target_first) |
|---|---|---|---|
| risky window type | double-exposure (overhedge) | underhedge | not measured |
| window start | 17:07:11.662 (Extended target accepted) | 08:31:51.576 (source flat) | — |
| window end | 17:07:48.825 (Ethereal source flat-confirmed) | 08:31:56.505 (target confirmed) | — |
| risky seconds | 37.163 | 4.929 | null |
| budget | 5s (MAX_DOUBLE_EXPOSURE) | 10s (MAX_UNHEDGED) | — |
| verdict | 37 > 5 -> NOT safe | 4.93 < 10 -> safe | not certified (already READY via prod cycle) |
| route_production_safe | False | True | null |
| total_route_seconds | 114.63 | 87.27 | 41.08 |

Cause leg: Ethereal source-close readback (venue/API + polling), inside the overhedge window.
Extended-open latency is outside the window and is not the cause.

Config references:
- `hedge_venue_migration_executor.rb:728-746` — double-exposure window + threshold.
- `ethereal_hedge_execution_service.rb:15-16` — `POST_SUBMIT_READBACK_ATTEMPTS=12`,
  `POST_SUBMIT_READBACK_DELAY_SECONDS=0.25`.
- `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` default 5s; `MIGRATION_MAX_UNHEDGED_SECONDS` default 10s.

---

## Would retrying target_first pass under 5s?
No (low probability). The 37s is a systematic Ethereal-readback cost (~12 polls x ~2.8s), not jitter.
A retry would need Ethereal to confirm flat in <5s, which the current polling won't deliver.

---

## Recommended safest next option (ranked)

1. **Root-cause fix (preferred):** speed up / re-confirm the Ethereal source-close via the order
   fill/status (Ethereal returned order id `c91e028d-…`) and/or a shorter, fill-gated readback instead
   of 12x slow position polls. Cuts the confirmed double-exposure and lets target_first pass while
   keeping policy alignment. Needs code + test.
2. **Prove ethereal->extended source_first:** close Ethereal first -> risky window becomes Extended-open
   underhedge (10s budget vs 5s), the less-penalized exposure; would likely certify. Diverges from the
   target_first route policy and shifts (not removes) exposure. Needs explicit decision + source_first
   gate. Moderate-high confidence.
3. **Retry target_first** — low confidence.
4. **Weaken MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS** — UNSAFE / NOT RECOMMENDED; would certify a real
   37s of ~2x (~3.37 ETH) directional exposure.

---

## Code/test fix needed before another attempt?
- Option 1 (preferred): YES — change the Ethereal source-close confirmation (fill-gated / bounded
  faster readback) + a test asserting confirmed double-exposure drops below budget. Durable fix, keeps
  target_first policy.
- Option 2: no code change strictly required (source_first via existing gate), but the planner reports
  `source_first_supported=false` for this route (policy target_first), so a small change would help
  clarity if standardizing on source_first.
- Never touch `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS`.

---

## Safety
Read-only receipts + code inspection only. No live canary, no runner start/restart, no gates enabled,
no DB/env/secrets mutation. Current production state unchanged: venue extended, extended short ~1.669,
ethereal/nado flat, open orders zero, inside_tolerance=true, runner inactive, route proofs 5/6.
