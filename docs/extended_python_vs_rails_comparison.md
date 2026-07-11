# Extended read-path comparison: Rails vs neighboring Python project

**VPS:** France · **Date:** 2026-07-08 · **Scope:** READ-ONLY comparison. No `.env`/secrets inspected,
no code change, no live action, no deploy.

## Headline
The Python project is **not a faster implementation of the same task** — its Extended is **dry-run only /
live-blocked** and does **far less**. But its **architecture** validates the fix Rails needs: **capture one
account snapshot (1 GET per endpoint), persist it, and have order-build + safety gates read that snapshot
instead of re-fetching.** Nothing of Python's *execution* can be copied (it has none); the win for Rails is
pure **read-consolidation** in the build path, keeping every live blocker and the post-submit readback.

## Files inspected (Python `/opt/perp-hedge-research-bot`)
- `src/exchanges/extended.py` — public market-data adapter (read-only + demo fallback; `get_positions()=[]`,
  `get_account_state()` = paper stub).
- `src/execution/adapters/extended.py` — `ExtendedExecutionAdapter(DryRunOnlyExecutionAdapter)`;
  `supports_open/close/reduce_only = False`; blocked ("does not implement signing or private keys");
  `build_order_request`/`validate_order_request` are **pure local, no API calls**.
- `src/accounts/extended.py` — read-only account adapter: `get_balances`=1×`/user/balance`,
  `get_positions`=1×`/user/positions`, `get_open_orders`=1×`/user/orders`, `get_account_state`= **0 GETs**.
- `scripts/check_live_execution_readiness.py` — readiness gate loads a **persisted** account snapshot from
  disk (`reports/account_readonly/latest_account_snapshot.json`); **0 live GETs at gate time**.
- `scripts/dry_run_execution.py` — builds the dry-run from the loaded snapshot; **0 account GETs during
  build**.
- Docs: `EXTENDED_HTTP_SMOKE.md`, `LIVE_EXECUTION_DESIGN.md`, `EXTENDED_ADAPTER_AUDIT.md`,
  `EXTENDED_EXECUTION_RESEARCH.md` (status `BLOCKED_SIGNING_POLICY` / `DRY_RUN_ONLY`).
- Tests confirm dry-run-only (`production_live_proven: False`).

## Answers
1. **Extended read-only API calls before submit (Python):** for live execution, **none** (Python never
   submits live on Extended). For its account sync: **3 GETs total** (balance + positions + orders), each
   **once**; `get_account_state()` = 0. Order build/validate = 0 API calls.
2. **Repeated reads or compact snapshot:** compact — **one GET per endpoint, no repeats**, no leverage read
   at all. (Rails repeats: balance ×5, leverage ×3, positions ×2 in a single `account_state`.)
3. **Caches metadata/account data:** effectively yes by structure — it captures ONE snapshot and everything
   downstream reads that snapshot from disk; it never re-fetches within a plan/build.
4. **Order status/fill confirmation vs slow position readback:** Python has **no post-submit readback**
   (dry-run only). (Rails already added the working order-by-id fast fill — 2.36s.)
5. **One readiness snapshot before execution, no recompute inside the leg:** **yes** — this is Python's core
   pattern: snapshot once → persist → gate + build read the snapshot; nothing re-computes account/market
   data inside the (would-be) leg. Rails does the opposite: recomputes `read_position`/`account_state`/
   `blockers`/diagnostics repeatedly inside the leg build.
6. **Required for order-build vs blockers vs diagnostics (Python):** order-build = **local only** (no reads);
   readiness/blockers = the **single snapshot**; diagnostics = the snapshot. Clean separation; no reads
   bundled into order construction.
7. **What Python does differently from the Rails Extended build path:** Python = build order locally +
   one persisted snapshot for all gating. Rails `ExtendedMainnetLifecycleCheck#run` interleaves order
   preview with many live reads, and `read_position` (adds a balance via `account_value_fields`),
   `account_state` (17 GETs), `blockers`, and `read_only_account_diagnostics` each **re-fetch** the same
   endpoints with no shared snapshot.
8. **What Rails can SAFELY copy (design, not code):** fetch each Extended endpoint (positions, balance,
   leverage, account_info, market, open_orders) **once** into a per-leg readiness snapshot and pass it to
   the order preview + ALL blockers + diagnostics, instead of re-reading. Keep `account_state`-style pure
   assembly with no re-fetch. Separate order construction (local) from readiness reads.
9. **What must NOT be copied (would weaken safety):** do **not** adopt Python's "no post-submit readback"
   (Rails must keep the final position readback + the deployed order-by-id fast fill). Do **not** drop any
   live-readiness blocker (leverage=1x, margin isolated, account value ≥ notional, open_orders=0, live
   gates) — Python omits these only because it never executes. Do **not** cache the **volatile** reads
   (positions/balance) across the submit boundary — the post-submit readback must read **fresh** (snapshot
   is build-phase only, invalidated before readback). Do **not** treat demo/fallback data as live.

## Side-by-side call map (before submit)
| Concern | Python | Rails (current) |
|---|---|---|
| positions | 1 (snapshot) | ~4-5 (read_position ×several, each also a balance) |
| balance | 1 (snapshot) | ~8+ (bundled in every read_position; ×5 inside one account_state) |
| account_info | 0-1 | ~3-4 |
| market | 0-1 (public) | ~3 |
| leverage | 0 | ~3-4 |
| open_orders | 1 (snapshot) | ~3-4 |
| order build | 0 (local) | interleaved with the above |
| **total before submit** | **~3 (once)** | **~30-40 sequential** |

## Estimated GET count & latency
- Python: ~3 read-only GETs, captured once (and gate/build then read from disk). Live-execution GETs: N/A.
- Rails now: **~30-40 sequential GETs** in the close-leg build; at `EXTENDED_API_TIMEOUT_SECONDS=1.0` →
  **~34s** (`slow_step=build`, `source_close_submit_latency=43.89s`), the real cause of the ~40s overhedge.
- Rails after snapshot-consolidation: **~6-8 unique GETs** (positions, balance, leverage, account_info,
  market, open_orders — each once) + the post-submit fast fill (order-by-id ~1). Estimated build **~34s →
  ~6-8s**, likely bringing `target_total_latency < 15s` and `double_exposure < 5s` (must re-measure via the
  Part 1 diagnostics).

## Recommended smallest safe Rails patch (unchanged from Part 3, now Python-validated)
1. Introduce a **per-leg Extended readiness snapshot**: fetch positions/balance/leverage/account_info/
   market/open_orders **once** and pass it to `build_orders`/`close_preview`, `structural_blockers`/
   `live_blockers`/`blockers`, and `read_only_account_diagnostics`. Concretely: memoize the STATIC reads
   (market, account_info, fees, leverage) at the venue-instance level (obviously safe), AND thread a single
   positions+balance snapshot through the build.
2. **Scope to build only:** invalidate/bypass the snapshot for the post-submit readback so
   `poll_flat_readback`/`poll_short_readback` (and the order-by-id fast fill) read **fresh**.
3. Files: `app/services/hedge_venues/extended.rb` (`read_position` extra balance, `account_state`
   internal re-fetches, `read_only_account_diagnostics`/`margin_gate_diagnostics`/`account_value_fields`),
   `app/services/extended_mainnet_lifecycle_check.rb` (build sequence), `app/services/hedge_venue_migration_executor.rb`
   `DefaultLegRunner#run_extended_*_leg` (its own extra `read_position`). No `extended_api_client.rb` change
   (endpoints already correct). No order-construction, threshold, route-policy, or blocker change.

## Tests needed
- Counting fake client: ONE close-leg build (and ONE open-leg build) issues **≤1 GET per endpoint**
  (assert total drops from ~30-40 to ≤~8).
- Same blockers still evaluate for the same inputs (no readiness check removed).
- Post-submit readback issues a **fresh** positions/balance GET (a distinct read after submit) — proves the
  snapshot did not leak into the readback.
- Fail-closed preserved; open and close paths both covered.

## Should implementation proceed?
- **Deploy Part 1 observability first** (committed `b91e6aa`, awaiting your deploy approval) so the next
  canary can **measure** the reduction.
- The read-consolidation is the right, Python-validated fix, but it is **not a blind one-liner** (the
  volatile-read / readback-fresh boundary must be correct). **Proceed AFTER review**, with the counting-
  client + readback-fresh tests as the acceptance gate. Do not implement unreviewed.

## ethereal->extended
Still **NOT safe to retry** until this consolidation lands and a canary shows `target_total_latency < 15s`
and `double_exposure < 5s`.

## Safety confirmation
Read-only comparison. No `.env`/secrets/keys inspected or printed, no code change, no live canary, no arm,
no runner, no orders, no route, no deploy/rebuild/push, no DB/env/secrets mutation. Production unchanged
(venue ethereal, runner inactive, gates false, 5/6).
