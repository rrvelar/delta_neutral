# Extended architecture: fresh Python (8ef8964) vs Rails delta_neutral

**VPS:** France · **Date:** 2026-07-08 · **Scope:** READ-ONLY comparison. No `.env`/secrets inspected/
printed, no code change to either project, no live action, no deploy.

**Python commit confirmed:** `8ef8964000ecfb16811cdcdaa0234062b4e0d8ec` (2026-07-08 17:48) at
`/opt/compare-perp-hedge-research-bot-fresh` (fresh clone; NOT the stale `/opt/perp-hedge-research-bot`).
Unlike the stale copy (dry-run-only), the fresh copy is a **live-capable execution engine** — so this is a
real architecture comparison.

## Files inspected
- Python (fresh): `src/execution/adapters/extended.py`, `src/venues/extended_live.py`,
  `src/execution/admission.py`, `src/execution/hedge_executor.py`, `src/accounts/extended.py`,
  `src/execution/confirmations.py`, `src/exchanges/extended.py`; docs (`EXTENDED_HTTP_SMOKE.md`,
  `LIVE_EXECUTION_DESIGN.md`, `EXTENDED_ADAPTER_AUDIT.md`, `EXTENDED_EXECUTION_RESEARCH.md`); tests
  (`test_extended_adapter.py`, `test_execution_lifecycle.py`).
- Rails: `app/services/hedge_venues/extended.rb`, `extended_api_client.rb`,
  `extended_mainnet_lifecycle_check.rb`, `hedge_venue_migration_executor.rb`,
  `extended_hedge_execution_service.rb` (+ prior call-map from `docs/extended_build_latency_observability_and_callmap.md`).

## The core architectural difference
**Fresh Python: snapshot → gate → submit → readback.**
- Account/market state is captured ONCE into **persisted snapshots** (out-of-band):
  `reports/account_readonly/latest_account_snapshot.json`, `reports/live_evidence/preopen/latest_market_snapshot.json`.
- The pre-submit gate `evaluate_open_admission` (`admission.py`) reads those **snapshots from disk** and
  applies a **freshness/staleness gate** — it makes **ZERO live GETs**. SAFE_FLAT (`positions==0 &&
  open_orders==0`), liquidity/slippage, kill-switch, recovery-lock, paused, signer-health, fleet/route are
  all evaluated against the snapshot (fail closed if stale/missing).
- The submit path `ExtendedExecutionAdapter.place_order` → `ExtendedLiveClient` reads only
  `fetch_metadata()`, which is **memoized** (`extended_live.py:130` `if self._meta and not force: return`).
  `qty_for_notional`/`build_order` use that cached `meta` — **no positions/balance/leverage/account_info
  reads in the submit path**. So a leg does **~0-1 live GETs before submit** (metadata; 0 on the 2nd leg,
  cached).
- Readback = `poll_position` (`extended_live.py:269`): a **position poll** (`/user/positions`) until
  flat/short — read AFTER submit, necessarily fresh.

**Rails: no snapshot; re-read everything inside the leg.**
- `ExtendedMainnetLifecycleCheck#run` build path calls `read_position`, `account_state`, `blockers`,
  `read_only_account_diagnostics`, `market_metadata_diagnostics` — each **re-fetches** live endpoints, with
  no shared snapshot and no memoization. `account_state` alone = **17 GETs** (balance ×5, leverage ×3,
  positions ×2, market ×2, open_orders ×2, fees ×2); every `read_position` bundles an extra `balance`.
  One close-leg build ≈ **30-40 sequential GETs** → **~34s** at `EXTENDED_API_TIMEOUT_SECONDS=1.0`.

## Answers
1. **Python Extended reads before submit (open/close):** ~**0-1 live GETs per leg** — only memoized
   `fetch_metadata`. Account safety = persisted snapshot (0 live GETs in the gate). The snapshot itself,
   captured out-of-band by `accounts/extended.py`, is 3 GETs (`/user/balance`, `/user/positions`,
   `/user/orders`), **once**, not per-leg.
2. **Rails Extended reads before submit (open/close):** ~**30-40 live GETs per leg** (account_state 17 +
   repeated read_position/blockers/diagnostics), no snapshot, no memoization.
3. **Python compact snapshot vs repeated:** YES — one persisted account snapshot + memoized metadata; no
   repeated `account_state`/`read_position`/diagnostics inside the leg.
4. **Python caches metadata/account/leverage/fee:** metadata **memoized** on the client; fee from env/meta;
   account via the persisted snapshot; leverage is **not read** in the Extended live path at all.
5. **Python separates diagnostics from live blockers:** YES — admission blockers come from the snapshot;
   diagnostics are not recomputed by re-reading inside the leg. Clean gate/submit/readback separation.
6. **Python order-by-id vs position readback:** **position readback** (`poll_position`), NOT order-by-id.
   (Rails already has a MORE advanced order-by-id fast fill — 2.36s — which should NOT be replaced by
   Python's poll.) `confirmations.py` is about human confirmation PHRASES, not fill confirmation.
7. **Python safety checks ≈ Rails blockers:** admission — config-profile passing, kill-switch off,
   recovery-lock, not-paused, **SAFE_FLAT (positions=0 & open_orders=0 from a FRESH snapshot)**,
   liquidity/slippage (both legs fillable), signer-health, fleet/route. Rails — live gates on, **leverage=1x,
   margin isolated, account_value ≥ notional, open_orders=0**, confirmation phrase, signer health. Overlap:
   open_orders=0 ↔ SAFE_FLAT, signer health, notional/liquidity. Rails-specific and MUST be kept:
   leverage/margin gates (Python omits them).
8. **Rails duplicated / diagnostics-only before submit:** `read_position` → extra `balance`
   (`account_value_fields`); `account_state` internal balance ×5 / leverage ×3 / positions ×2;
   `read_only_account_diagnostics` (called in `result()` for the RECEIPT — **diagnostics-only**, ~4 GETs);
   `market_metadata` re-read. All duplicate data already fetched.
9. **Rails calls safely memoizable per leg:** STATIC config — `market` metadata, `account_info`, `fees`,
   `leverage` (unchanged during a leg; not used for the post-fill flat readback). Memoize at venue-instance
   level.
10. **Volatile Rails calls that must stay FRESH after submit:** `positions` and `balance` — the post-submit
    readback (`poll_flat_readback`/`poll_short_readback` → `read_position`) and the order-by-id fast fill
    must read fresh. So any positions/balance snapshot is **build-phase only, invalidated before readback**.

## Side-by-side call map (per leg, before submit)
| Endpoint | Fresh Python | Rails now | Rails after fix |
|---|---|---|---|
| market metadata | 1 (memoized; 0 on 2nd leg) | ~3 | 1 |
| positions | 0 in submit path (snapshot) | ~4-5 | 1 |
| balance | 0 in submit path (snapshot) | ~8 | 1 |
| leverage | 0 | ~3-4 | 1 |
| account_info | 0 | ~3-4 | 1 |
| open_orders | 0 in submit path (snapshot) | ~3-4 | 1 |
| **live GETs before submit** | **~0-1** | **~30-40** | **~6-8** |
| post-submit readback | poll positions (fresh) | poll positions + order-by-id fast fill (fresh) | unchanged (fresh) |

## Estimated latency difference
- Fresh Python: ~0-1 live GET before submit ⇒ **sub-second** pre-submit (safety is a snapshot lookup).
- Rails now: ~30-40 sequential GETs × up to 1s ⇒ **~34s** build (`slow_step=build`,
  `source_close_submit_latency=43.89s`) — the cause of the ~40s overhedge.
- Rails after snapshot-consolidation: ~6-8 unique GETs ⇒ **~6-8s**, likely `target_total_latency < 15s`
  and `double_exposure < 5s` (re-measure via the Part 1 diagnostics).

## Safe ideas to adapt (keep every blocker + the readback)
- **Per-leg readiness snapshot:** read positions/balance/leverage/account_info/market/open_orders ONCE at
  leg start; pass the snapshot to `build_orders`/`close_preview`, all blockers, and diagnostics instead of
  re-reading. (Rails in-memory per-leg equivalent of Python's persisted snapshot.)
- **Memoize STATIC reads** (market, account_info, fees, leverage) at the venue instance.
- **Separate diagnostics from the live gate:** feed `read_only_account_diagnostics` from the snapshot rather
  than issuing fresh GETs for the receipt.
- Keep the (better) Rails order-by-id fast-fill readback.

## Unsafe ideas NOT to copy
- Do NOT adopt Python's position-only readback in place of the order-by-id fast fill (Rails's is better).
- Do NOT drop Rails's leverage=1x / margin-isolated / account_value≥notional gates (Python omits them
  because it gates differently, not because they're unnecessary).
- Do NOT cache the VOLATILE `positions`/`balance` across the submit boundary — the readback must read fresh.
- Do NOT move Rails to an out-of-band persisted snapshot with a loose freshness window for a same-moment
  migration (Python's file snapshot + staleness gate suits its scheduler; Rails should snapshot in-memory
  at leg start so the gate data is exactly as fresh as today, just read once).

## Smallest safe Rails patch (proposal — NOT implemented)
1. Introduce an in-memory per-leg Extended readiness snapshot (one GET per endpoint) threaded through the
   build; memoize static reads at the venue instance. Files: `app/services/hedge_venues/extended.rb`
   (`read_position` extra balance; `account_state` internal re-fetches; `read_only_account_diagnostics`/
   `margin_gate_diagnostics`/`account_value_fields`), `app/services/extended_mainnet_lifecycle_check.rb`
   (build sequence), `app/services/hedge_venue_migration_executor.rb` `DefaultLegRunner#run_extended_*_leg`
   (its own extra `read_position`). No `extended_api_client.rb` / order-construction / threshold / route-
   policy / blocker change.
2. Build-phase scope only; readback (`poll_*_readback`) and order-by-id fast fill read fresh.

## Tests needed
- Counting fake client: ONE open-leg and ONE close-leg build issue **≤~8 GETs total, ≤1 per endpoint**
  (down from ~30-40).
- Every existing blocker still evaluates identically for the same inputs (no check removed).
- Post-submit readback issues a **fresh** positions/balance GET (distinct from the build snapshot).
- Fail-closed preserved; open and close paths both covered.

## Whether implementation should proceed
- **Deploy Part 1 observability first** (committed `b91e6aa`, awaiting deploy approval) so the next canary
  MEASURES the reduction via the now-surfaced `slow_step`/`build_latency`/latency fields.
- The read-consolidation is the correct, now doubly-validated (fresh Python) fix, but the volatile-read /
  readback-fresh boundary must be exact → **proceed AFTER review**, with the counting-client + readback-
  fresh tests as the acceptance gate. Not a blind change.

## ethereal->extended
Still **NOT safe to retry** until this consolidation lands and a canary shows `target_total_latency < 15s`
and `double_exposure < 5s`.

## Safety confirmation
Read-only comparison; neither project modified. No `.env`/secrets inspected or printed, no live canary, no
arm, no runner, no orders, no route, no deploy/rebuild/push, no DB/env/secrets mutation. Production
unchanged (venue ethereal, runner inactive, gates false, 5/6).
