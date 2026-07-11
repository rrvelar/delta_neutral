# Ethereal API latency deep-dive: can ethereal->extended meet double_exposure < 5s?

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-09
**Scope:** READ-ONLY. No code/deploy/canary/gates/DB/env change. Verdict: **< 5s is technically reachable
(~4.35s floor) but only with 4 coordinated changes and essentially ZERO margin against Ethereal API jitter
— the single irreducible cost is one ~3.1s Ethereal `/v1/order` fill-confirmation GET that no code change
can remove.**

## 1. Precise Ethereal source-close timeline (2026-07-09 canary receipt)
Window = target fill (04:36:30.786) → source-close fill (04:36:46.136) = **15.350s**.
```
+0.000s  target_open_fill_confirmed              04:36:30.786   (Extended fast-fill = window start)
+2.991s  target_leg_submit_finished (leg returns) 04:36:33.778   <== Extended target leg post-fill (~3.0s)
+0.012s  source_close_submit_started              04:36:33.790
+3.125s  ethereal build_started                   04:36:36.915   <== leg-runner PRE-READ read_position (~3.1s)
+5.317s  ethereal build_finished                  04:36:42.232   <== ethereal build reads (~5.3s)
+0.064s  sign_finished                            04:36:42.296
+0.754s  submit_finished                          04:36:43.050
+3.085s  readback_confirmed (order-list fill)     04:36:46.136   <== one /v1/order GET (poll_attempts=1)
```
Source-close leg = 12.35s = **3.1s pre-read + 5.3s build + 0.75s submit + 3.1s fill GET**.

## 2/3. Every Ethereal API call in the source-close critical path
| call | endpoint | purpose | before/after submit | ~latency | required? | deferrable off window? |
|---|---|---|---|---|---|---|
| `read_position` (leg-runner pre-read) | `GET /v1/position/active` | close SIZE (`current_short`) | before | **~3.1s** | for sizing | **yes** — frozen/planned position (see Q A/C) |
| `market_metadata` | `GET /v1/product` | tick_size + onchain_id → **order construction** | before | **~2.8s** | yes | avoidable via env (Q, below) |
| `account_state` | `GET /v1/subaccount/balance` | summary `account_value_usd`/`effective` | before | **~2.8s** | **DIAGNOSTIC only** | **yes** — defer |
| sign + submit | signer + `POST /v1/order` | place order | — | ~0.8s | yes | no |
| fill confirmation | `GET /v1/order?subaccountId&productIds&limit=100` | authoritative fill (`ethereal_order_list_fill`) | **after** | **~3.1s** | **yes (safety)** | **no — irreducible** |

Verified: `eth_price` reuses `current_position[:mark_price]` (no mark-price GET); `market_metadata` memoized;
`account_state` read once and feeds only the summary (not `preview_blockers` :1075-1083, not `live_blockers`,
not order construction).

## 4. Direct answers
- **A. Is the pre-submit `read_position` strictly required for the close size?** Not intrinsically. The close
  size is `current_short`; under the manual-canary invariants (source auto **paused**, open orders **zero**,
  runner inactive, no other route) the Ethereal position is **frozen since pre-arm** (the target opened on
  Extended, not Ethereal), and the plan already carries that size (`planned_second_leg.size_eth` = 1.8703).
  A frozen/planned source position is safe **as long as** the final position readback still verifies flat
  (fail-closed on mismatch). Saves ~3.1s. Tension: it changes the *sizing source* (fresh read → frozen), a
  gray area vs "don't change order construction" (the quantity is identical).
- **B. Is `account_state` diagnostic-only?** **Yes** — feeds only `account_value_usd`/`estimated_effective_leverage`
  in the summary; no blocker/order use. Safe to defer (~2.8s), at the cost of that receipt diagnostic.
- **C. Can source close submit from a frozen source snapshot without a fresh read?** Yes, safely, IF (a)
  gates armed + source auto paused + open orders zero (all true in the canary) and (b) the final readback
  still runs. This is the single biggest lever (~3.1s).
- **D. Faster Ethereal fill endpoint?** **No.** Implemented probe endpoints: `/v1/product`,
  `/v1/product/market-price`, `/v1/position/active`, `/v1/subaccount/balance`, `/v1/order` (list). Ethereal
  `GET /v1/order/{id}` 404s (known); there is **no trades/fills endpoint and no websocket** implemented. The
  fill confirmation must use the `/v1/order` list (~3.1s). No faster path exists in code or repo docs.
- **E. Cause of the 3.085s fill confirmation?** **API latency of ONE `/v1/order` GET** (`poll_attempts=1`,
  confirmed FILLED on the first read) — NOT the polling interval (0.25s) and NOT a position-readback wait.
  It is the raw Ethereal order-list endpoint latency.
- **F. Can Ethereal close submit+fill be < 5s total without changing thresholds?** submit (0.75s) + fill GET
  (~3.1s) = ~3.85s even with a zero-cost build — so the leg alone can be ~4s, but only if the pre-read and
  build reads are removed from the window.
- **G. Route-specific optimization for ethereal->extended only?** The frozen-position (A/C) is effectively
  route/canary-specific (it relies on the paused-auto + zero-open-orders invariant that the supervised
  canary guarantees).

## Config finding (not a secret)
`ETHEREAL_TICK_SIZE`, `ETHEREAL_LOT_SIZE`, `ETHEREAL_ONCHAIN_ID` are **all unset** in prod, so the build
reads `/v1/product` (~2.8s) for tick_size + onchain_id. Setting `ETHEREAL_TICK_SIZE` + `ETHEREAL_ONCHAIN_ID`
to the correct ETH-PERP constants would **eliminate that ~2.8s read** (env overrides the API read). This is
an env change (out of my allowed scope) — a clean recommendation, needs the correct values.

## Is < 5s reachable? Minimum floor
**Barely.** With all levers applied:
- Extended target leg returns at fill (defer post-fill diagnostics): −3.0s.
- Ethereal skips pre-read (frozen position): −3.1s.
- Ethereal skips `/v1/product` (env tick/onchain): −2.8s.
- Ethereal defers `account_state`: −2.8s.
⇒ source-close leg = build ~0.5s + submit 0.75s + **fill GET ~3.1s ≈ 4.35s**; Extended post-fill ≈ 0.
**double_exposure floor ≈ 4.35s.**

**Irreducible core = the ~3.1s Ethereal `/v1/order` fill-confirmation GET + ~0.75s submit ≈ ~3.9s.** With a
~4.35s best case against a 5s threshold, there is **~0.65s of margin** — and the fill GET alone is variable
(~3s observed), so a slightly slow Ethereal response would push a given canary back over 5s. Certification
would be **real but fragile/flaky**, not comfortably safe.

## Exact blockers to < 5s
1. The Ethereal order-list fill-confirmation GET (~3.1s, irreducible — no faster endpoint).
2. The Extended target-leg post-fill window (~3.0s) — only removable by deferring its post-submit
   diagnostics.
3. The Ethereal pre-read (~3.1s) — only removable by trusting a frozen/planned source position.
4. The Ethereal `/v1/product` read (~2.8s) — only removable via env config.
All four must fall for double_exposure < 5s; #1 then sets the ~3.9s hard floor.

## Safe code options, ranked by seconds saved
1. **Frozen/planned source position for the Ethereal close** (skip the leg-runner pre-read): **~3.1s**.
   Guard on the canary invariants (source auto paused, open orders zero) + keep the mandatory final readback
   (fail-closed on mismatch). Biggest lever; mild order-construction-sizing tension.
2. **Extended target leg returns at its authoritative fill** (defer its post-submit *diagnostics*, not the
   final readback): **~3.0s**. Receipt-diagnostic trade-off; skips (not caches) the post-submit read.
3. **Defer the diagnostic-only Ethereal `account_state`** off the pre-submit path (migration-only): **~2.8s**.
   Cleanest; loses `account_value_usd`/`effective` in that receipt.

## Non-code option
4. **Set `ETHEREAL_TICK_SIZE` + `ETHEREAL_ONCHAIN_ID` env** to correct constants: **~2.8s**, removes the
   `/v1/product` read (env override already coded). Needs the right values; env change is out of my scope.

## Unsafe options to REJECT
- Confirm the close on submit/accepted (skip the fill GET) — fail-open. REJECT.
- Skip the final position readback — unsafe. REJECT.
- Drop the `/v1/product` read without env-providing tick/onchain — breaks order construction. REJECT.
- Lower `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` — forbidden (threshold). REJECT.
- Use a frozen position WITHOUT the paused-auto/zero-open-orders invariant or WITHOUT the final readback
  safety net — unsafe. REJECT.

## Recommendation
< 5s is reachable only at ~4.35s with **all four** levers, and the residual is dominated by one ~3.1s
Ethereal GET we cannot speed up in code — so certification would be **fragile** (no comfortable margin, and
subject to Ethereal API jitter). Two paths:
- **(Pursue)** Implement options 1–3 (code+tests) and set the env constants (option 4). Expect
  double_exposure ~4–4.5s: usually under 5s, occasionally over on a slow Ethereal GET. Re-measure with a
  supervised canary before trusting it.
- **(Accept)** Treat `ethereal->extended` (and any Ethereal-source target_first route) as **venue-latency-
  bound at the 5s double-exposure gate** — the Ethereal order-list fill GET (~3.1s) plus submit make a
  comfortable < 5s impractical without a faster Ethereal fill signal (e.g., an account websocket/trade
  stream Ethereal does not expose today). Getting to a durable 6/6 may then require a route-policy/threshold
  decision (explicitly outside my allowed scope) or an Ethereal-API/infra change.

My honest read: `target_total_latency < 15s` and `total_migration < 45s` are comfortably met; the **5s
double-exposure gate is the one bound this route cannot reliably clear at Ethereal's current fill-read
latency**. I'd recommend deciding between "implement 1–4 and accept a fragile ~4.4s" vs "accept the venue
floor and take it to a policy/infra decision" — before I write any code.

## Safety confirmation
Read-only. No code, no deploy, no live canary, no arm, no runner/scheduler, no orders, no route, no
threshold/route-policy/order-construction change, no blocker removed, no DB/env/secrets mutation. Production
unchanged: venue extended (1.857), ethereal/nado flat, open orders zero, gates false, runner inactive, 5/6.
