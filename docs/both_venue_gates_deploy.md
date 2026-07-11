# Deploy report — both-venue manual canary gates (commit 4a58350)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** Deploy only (rebuild + web restart). No live canary, no arm, no runner/scheduler, no orders/
signatures/cancels, no route run, no threshold/route-policy change, no push. Feature flags remain OFF.

## What was deployed
Commit **`4a58350`** — "Pause and restore both source and target venue autos in manual canary gates."
`arm!` now pauses BOTH the source and target venue auto-rebalance gates (recording each prior value);
`disarm!` restores every paused gate; `gate_status` reports `source_auto` and `target_auto` separately;
restore is idempotent and fail-closed on missing/corrupt/legacy records.

## Pre-build state
- HEAD = `4a58350`; **no uncommitted app/ runtime changes** (only `.dockerignore` audit-exclusion,
  an inert test-only file, and untracked docs/`audit/` — `audit/` excluded via `.dockerignore`).

## Build + restart
- `docker compose -f docker-compose.prod.yml build web` → OK
- `docker compose -f docker-compose.prod.yml up -d web` → container Recreated + Started

## Post-deploy verification (read-only)
- **Image** `75d8094` **Created 2026-07-08T18:53:08** — after commit `4a58350` (18:46:44). ✓
- **Methods live in image:** `pause_venue_autos!`, `pause_auto!`, `auto_status` (instance);
  `restore_venue_autos!`, `paused_autos`, `paused_auto_record`, `upsert_paused_auto`, `pending_restore?`
  (class). Old source-only methods removed. ✓
- **`gate_status extended->ethereal`** now returns both sections:
  - `source_auto`: extended, `currently_enabled: false`, `would_pause: false`
  - `target_auto`: ethereal, `currently_enabled: true`, **`would_pause: true`** ← the fix: ethereal target
    auto is now visible and would be paused on arm / restored on disarm.
- **Production unchanged / safe:** runner **stopped/inactive**, `pid: null`, `duplicate_runner_process:
  false`; venue **extended** (1.816), ethereal 0.0, nado 0.0, open orders zero; DB gates
  MIGRATION_LIVE/AUTO/RANDOM all **false**; autos ethereal `true` (not paused), extended `false`, nado
  `false`; `pending_restore?=false` (nothing paused); route proofs **5/6** (`ethereal->extended` STALE).

## Result
The both-venue gates fix is deployed and functional. NO-GO blocker #1 (ethereal target auto un-pausable) is
now resolved at the gate layer — a future `arm` for `extended->ethereal` would pause the ethereal target
auto and `disarm` would restore it.

## Remaining before an extended->ethereal reposition (separate approvals; NOT done here)
- **Tolerance breach** — fresh target 1.87317 vs Extended 1.816 → drift 0.05717 > tolerance 0.05620
  (~0.001 ETH over). Must resolve (Extended `increase_short ~0.057`, or wait for drift) before the canary.
- Then: preflight → arm → one live canary (`EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED=true`,
  `ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED=true`) → disarm.

## Commits now on the branch (feature/dashboard-hedge-execution-controls, not pushed)
| Commit | Deployed image |
|---|---|
| `79a7138` executor authoritative fills | ✅ |
| `d9d3212` Ethereal find_order | ✅ |
| `310ee63` Extended fast fill (default-OFF) | ✅ |
| `4a58350` both-venue gates | ✅ (image 75d8094) |

## Safety confirmation
Deploy only. No live canary, no arm, no gates enabled, no autos paused, no orders/signatures/cancels, no
runner/scheduler start, no route run, no DB/env/secrets mutation beyond the web restart, no threshold/
route-policy change, no push. Feature flags OFF. Production unchanged.
