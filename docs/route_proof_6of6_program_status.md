# Route-proof 6/6 program — consolidated status

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Branch:** feature/dashboard-hedge-execution-controls (not pushed)

## Objective
Get Position #6's 6 migration route proofs to 6/6 READY_FOR_RANDOM so the production runner can restart,
without ever compromising safety. The one remaining stale route is `ethereal->extended`; certifying it
requires being on Ethereal, and the venue is currently Extended — hence the planned `extended->ethereal`
reposition.

## Current production state (read-only)
- Venue **extended** (short 1.816); ethereal 0.0, nado 0.0; open orders zero; `inside_tolerance` (status
  field) true, but the fresh-target rehearse shows a marginal breach (see blockers).
- Runner **stopped / inactive**, `pid: null`; gates (MIGRATION_LIVE/AUTO/RANDOM) all **false**.
- Route proofs **5/6**; `ethereal->extended` **STALE** (the only one). Restart blocked by route proofs.

## Root cause established (target_first latency)
target_first legs confirmed via **slow position readback**, which both delayed the next leg (real
overhedge) and inflated `target_total_latency`. Fix = authoritative **order-fill** confirmation so a leg
returns fast. Ethereal already had it (needed a committed `find_order`); Extended's API exposes the reads
(validated live: `GET /user/orders/{id}` returns terminal FILLED + `filledQty` + `reduceOnly`), so an
Extended fast-fill was built. Full analysis: `docs/route_proof_latency_map.md`,
`docs/target_first_real_double_exposure_root_cause.md`, `docs/extended_fill_confirmation_feasibility.md`.

## Commits on the branch
| Commit | Summary | Deployed? |
|---|---|---|
| `79a7138` | Executor authoritative Ethereal target-open fill (+ source-close fill) | **Yes** (image 4e2439) |
| `d9d3212` | Ethereal read-only `find_order` (deployed service depended on it; was missing) | **Yes** |
| `310ee63` | Extended authoritative fast fill confirmation (default-OFF) | **Yes** |
| `4a58350` | Both-venue (source+target) auto pause/restore in manual canary gates | **No** (needs rebuild) |

Running image `4e2439` was built 2026-07-08 08:21 from `310ee63`; it does **not** contain `4a58350`.

## What is deployed and inert
The Extended + Ethereal fast-fill paths are live but **OFF by default**
(`EXTENDED_OPEN/CLOSE_FILL_CONFIRMATION_ENABLED`, `ETHEREAL_OPEN/CLOSE_FILL_CONFIRMATION_ENABLED` all
unset). They only activate when passed inline on an approved canary. Verified in the running image:
`ExtendedApiClient#order_by_id`, `HedgeBackends::ExtendedReadOnlyProbe`, `EtherealReadOnlyProbe#find_order`,
Extended `fast_*_fill_readback`/`classify_*_fill`, executor `authoritative_*` methods all present.

## Live canary history (Position #6)
- `ethereal->extended` final-proof canary (before this deploy): finalized safely (venue → extended) but
  **did not certify** — `target_total_latency 64.8s > 15s` (Extended target-open readback) and
  `double_exposure 13.1s > 5s`. This exposed the Extended-latency wall the fast-fill now addresses.
  (`docs/route_proof_ethereal_to_extended_canary_result.md`.)
- `extended->ethereal` reposition (this session): **NO-GO at preflight** — did not arm, no live action.

## extended->ethereal reposition — two blockers (both must clear)
1. **Ethereal target auto enabled, un-pausable by deployed gates.** `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED=true`;
   the deployed gates pause only the source auto. **Fixed in code by `4a58350` (committed, not deployed).**
   Deploying it makes `arm` pause+restore the target auto. (`docs/route_proof_reposition_extended_to_ethereal_nogo.md`.)
2. **Marginal tolerance breach.** Fresh target 1.87317 vs Extended 1.816 → drift 0.05717 > tolerance
   0.05620 (~0.001 ETH over). Not fixed here (no order taken, per instruction). Must resolve (Extended
   `increase_short ~0.057`, or wait for the target to drift back) before the canary.

## Working tree (uncommitted, inert)
- `.dockerignore` (M) — adds `audit/` exclusion (keeps 2.1M audit pack out of the image). Beneficial.
- `test/services/migration_route_proof_registry_test.rb` (M) — test-only (fill-cert tests + relative
  staleness dates). Inert at runtime.
- `audit/` (untracked) — excluded via `.dockerignore`. Do not commit.
- Various `docs/*.md` (untracked) — reports; inert.
No uncommitted **runtime** app/ changes remain.

## Next steps (each its own explicit approval — none taken)
1. **Deploy `4a58350`** (both-venue gates): `docker compose -f docker-compose.prod.yml build web && up -d web`
   (no stash needed; `audit/` excluded). Read-only verify `gate_status` shows a `target_auto` section.
2. **Clear the tolerance breach** (Extended `increase_short ~0.057`, or wait).
3. Then re-run the `extended->ethereal` reposition preflight; if `ready_no_live` with the fill flags, arm →
   one live canary (`EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED=true`, `ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED=true`)
   → disarm. Expect venue → ethereal with authoritative fill sources and much lower latency.
4. Separately, retry the final stale route `ethereal->extended` (Extended as target → the new Extended
   fast-fill should keep `target_total_latency` well under 15s and `double_exposure` under 5s → certify → 6/6).

## Safety posture
All work to date: code + tests + one careful deploy of the fast-fill paths (default OFF). No runner start,
no route run, no gates left enabled, no autos left paused, no orders/signatures/cancels, no threshold or
route-policy change, no push. Production unchanged: venue extended, runner inactive, gates false, 5/6.
