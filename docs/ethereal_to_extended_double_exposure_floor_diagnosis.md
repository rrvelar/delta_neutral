# ethereal->extended double_exposure: root-cause diagnosis (why Parts A/B as specified don't apply)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-09
**Scope:** READ-ONLY diagnosis. No code changed, no live canary, no arm, no runner, no orders, no route,
no deploy. This report explains why the two requested changes are either already-satisfied or inapplicable,
and lays out the real (venue-latency) floor + the one safe option, for your decision.

## Why no code was changed
The task asked to implement (A) an Ethereal source-close build-read consolidation and (B) "start the source
close after the target authoritative fill, not after the target position readback." Tracing the canary's
exact timestamps and the code shows **A has nothing to consolidate and B is already how the code behaves** —
implementing either would be a no-op or would change diagnostics/receipts without reducing double_exposure
below 5s. Implementing changes that don't help (or that touch a diagnostic broadly) would violate the
"don't weaken safety / don't change more than needed" spirit, so this returns the diagnosis instead.

## Exact timeline (from the 2026-07-09 canary executor receipt)
```
+0.000s  target_leg_submit_started_at        04:36:21.585
+9.201s  target_open_fill_confirmed_at        04:36:30.786   (Extended fast-fill; = double_exposure_started_at)
+12.193s target_leg_submit_finished_at        04:36:33.778   (target leg RETURNS, 3.0s after its fill)
+12.204s target_readback_confirmed_at         04:36:33.790
+12.205s source_close_submit_started_at       04:36:33.790   (source close begins)
+24.551s source_close_fill_confirmed_at       04:36:46.136   (Ethereal fast-fill; = double_exposure_ended_at)
```
Gaps:
- **target_readback_confirmed → source_close_submit_started = 0.000513s** — the executor already starts the
  source close ~0.5ms after the target leg returns. **Part B is already satisfied; there is no ~3s executor
  wait to remove.**
- target fill → target leg returns = **3.003s** — this is the **Extended target leg's own post-fill work**
  (its `result()` re-reads volatile balance/open_orders FRESH after submit — required by the "no volatile
  cache across submit" rule), not an executor readback wait.
- source_close_submit_started → source_close_fill = **12.352s** — the **Ethereal source-close leg** (the
  real cost).

double_exposure (15.35s) = 3.0s (Extended post-fill) + 12.35s (Ethereal source-close leg).

## Part A — Ethereal source-close build has NO read duplication to consolidate
Unlike Extended (whose `account_state` fanned out to 17 GETs, balance ×5), the Ethereal close build issues
distinct, single reads:
- `eth_price` (`ethereal_hedge_execution_service.rb:1132`) **reuses `current_position[:mark_price]`** — no
  separate mark-price GET.
- `market_metadata` is memoized (`@market_metadata ||=` / probe `@product_for ||=`), and lot/tick/onchain
  prefer env (`ETHEREAL_LOT_SIZE`/`TICK_SIZE`/`ONCHAIN_ID`) — often zero market reads.
- `@venue.account_state` is called **exactly once** (`:234`); `@venue.read_position` once (via the leg
  runner's pre-read, then passed as `current_position`).
So the read-consolidation technique that fixed Extended (dedup ~30-40 → ≤8) has **nothing to dedup** here.
The Ethereal build (~5.3s) is ~2-3 DISTINCT necessary reads at Ethereal's ~2.8s-per-read API latency, not
duplication.

## The one safe lever found: the Ethereal `account_state` read is DIAGNOSTIC-ONLY (~2.8s)
`account_state` (probe `account_health`, ~2.8s) is read in `build_order_preview` (:234) only to populate
the order summary's `account_value_usd` and `estimated_effective_leverage` (:277-278). It does **NOT** feed
`preview_blockers` (:1075-1083, which uses rounded_size/price/onchain_id/subaccount/mapping_error only),
`live_blockers`, or order construction (typed_data/quantity/price don't use it). So it could be deferred off
the pre-submit critical path, saving ~2.8s of the Ethereal build — **without removing any blocker or
changing order construction**. Trade-off: the receipt summary's `account_value_usd`/`estimated_effective_leverage`
would be computed later or omitted (a diagnostic change, applying to all Ethereal executions unless threaded
to migration-only). It also does NOT get double_exposure under 5s on its own.

## Why < 5s is not reachable via read consolidation (venue-latency floor)
Even removing the diagnostic `account_state` read, the Ethereal source-close leg floor is:
- `read_position` (needed for the close size): ~2.8s (Ethereal API).
- submit: ~0.75s.
- post-submit order-list FILL confirmation (`ethereal_order_list_fill`, required, fresh): ~3.1s.
≈ ~6.6s. Plus the Extended target-leg post-fill (~3s) ⇒ double_exposure floor ≈ ~9-10s. The dominant costs
are Ethereal's ~2.8s-per-read API latency and the necessary post-submit order-list fill readback — neither
is read duplication, so consolidation can't remove them. This is the Ethereal-side analog of the Extended
finding: Extended's problem was duplication (fixed); Ethereal's is raw per-read latency (not fixable by
dedup).

## Options (each needs your decision; none implemented)
1. **Defer the diagnostic-only Ethereal `account_state` read** off the pre-submit path (migration-only via a
   threaded flag to avoid changing other callers' receipts). Safe (no blocker/order-construction change);
   saves ~2.8s; does NOT reach < 5s alone. Modest, honest win.
2. **Defer the Extended target-leg post-submit account diagnostics (~3s)** so the target leg returns right
   at its fill. Tension with the "no volatile cache across submit" rule (it would SKIP, not cache, the
   post-submit diagnostic) — reviewable, but it changes the Extended receipt diagnostics.
3. **Accept that ethereal->extended target_first cannot meet double_exposure < 5s** at current Ethereal API
   latency, and treat it as a venue-latency-bound route (a policy/threshold conversation — explicitly OUT of
   my allowed scope to change here).
4. **Reduce Ethereal per-read latency** (infra/API — out of scope).

## Recommendation
Options 1+2 together would take double_exposure from ~15.3s to ~9-10s — a real improvement but still > 5s.
No combination of the *allowed, safe* read-consolidation changes reaches < 5s, because the Ethereal
source-close leg's necessary reads (position + post-submit fill confirmation) plus the Extended post-fill
window already exceed ~9s. I recommend deciding between (1)+(2) as an incremental latency win (with the
diagnostic trade-offs) vs. (3) accepting the venue floor — before I write any code.

## ethereal->extended status
Remains **NOT certified / STALE** (double_exposure 15.35s > 5s). It stays blocked until either a safe change
brings double_exposure < 5s (not achievable via read consolidation per this diagnosis) or the venue-latency
floor is addressed/accepted. Production is unchanged and safe: venue extended (1.857), ethereal/nado flat,
open orders zero, gates false, runner inactive, route proofs 5/6.

## Safety confirmation
Read-only diagnosis. No code changed, no live canary, no arm, no runner/scheduler, no orders, no route, no
deploy/rebuild/push, no threshold/route-policy/order-construction change, no blocker removed, no DB/env/
secrets mutation.
