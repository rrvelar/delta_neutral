# target_first ~40s double exposure — real root cause (target-open slow readback)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** INVESTIGATION ONLY. No code changed, no live canary, no runner start, no gates, no DB/env/
secrets mutation, no threshold change. Production state unchanged (venue ethereal, runner inactive).

## TL;DR
The ~40s both-legs-open window observed in the exchange UI is **real**, and the previous
"slow-final-readback artifact" explanation was **incomplete**. The dominant cause is on the **target
open** leg, not the source close:

> In target_first, the executor submits the **source close only after the target-open leg's `execute`
> returns**, and for an Ethereal open that `execute` **blocks on a 12-attempt position poll (~34s)**
> after the order has already filled. So the source close is fired ~34s late and both legs stay open
> ~40s. Worse, the executor also **stamps the window start (`target_leg_accepted_at`) only after that
> same slow readback**, so the measured `double_exposure_seconds` *understates* the true overhedge.

Two independent defects, one lever (use the authoritative target **order fill**, not the position poll).

---

## Evidence

### Exchange UI anchor (reposition run, extended→ethereal, target_first)
- Ethereal target **open** filled ~**01:24:15**  → both legs open from here.
- Extended source **close/buy** filled ~**01:24:55** → both legs open until here.
- Real overhedge ≈ **40s**.

### Code-derived latency of the target-open readback
`app/services/ethereal_hedge_execution_service.rb`
- `confirm_post_submit_readback` (L713–720): the fast fill path is **close-only** —
  `if action == "close" && expected_short.zero? && close_fill_confirmation_enabled? …`. An **open**
  always falls through to `poll_post_submit_readback` (L719).
- `poll_post_submit_readback` (L819–829): loops `POST_SUBMIT_READBACK_ATTEMPTS = 12` (L15) times, each
  iteration does `read_position` (~2.8s network) then `@sleeper.call(POST_SUBMIT_READBACK_DELAY_SECONDS =
  0.25)` (L16). The Ethereal position endpoint **lags** the fill, so an open that just filled keeps
  missing until the position catches up ⇒ up to `12 × (2.8 + 0.25) ≈ 36.6s`. Matches the observed ~34–38s.

### Executor blocks the source close on that readback
`app/services/hedge_venue_migration_executor.rb` (`run`, target_first)
- `first_leg = @leg_runner.call(first_planned_leg, …)` — the target open; this call does **not return**
  until the Ethereal `execute` (incl. the slow poll above) completes.
- Immediately after it returns: `mark_time!(:target_leg_submit_finished_at)`.
- Only later: `mark_time!(:source_close_submit_started_at)` → `second_leg = @leg_runner.call(second_planned_leg, …)`
  (the source close). **The source close cannot be submitted until the target-open poll finishes.**

### Window start is stamped *after* the slow readback (measurement understatement)
- `record_target_acceptance_timing!` L692: `receipt[:target_leg_accepted_at] ||= receipt[:target_leg_submit_finished_at]`.
- `compute_double_exposure_latency!` L777: `receipt[:double_exposure_started_at] ||= receipt[:target_leg_accepted_at]`.
- `target_leg_submit_finished_at` is stamped the instant the target leg returns — i.e. **already ~34s
  after the order actually filled**. So `double_exposure_started_at` misses the 34s and the receipt
  reports a *small* window while the exchange shows ~40s. (This is why `reposition_canary.out` carried a
  tiny/absent double-exposure while the UI showed 40s.)

---

## Timeline (reposition, extended→ethereal, target_first)

| t (approx) | event | source of truth | code |
|---|---|---|---|
| 01:24:15 | Ethereal target **open** FILLED — both legs open | exchange UI | order fill |
| 01:24:15 → ~01:24:49 | executor blocked in `leg_runner(target)` → ethereal `execute` → `poll_post_submit_readback` (12× read_position, position endpoint lags) | code | ethereal L819–829 |
| ~01:24:49 | target leg returns; `target_leg_submit_finished_at`; **`double_exposure_started_at` stamped here (already ~34s late)** | code | executor L76, L692, L777 |
| ~01:24:49 | `source_close_submit_started_at`; extended close submitted | code | executor |
| 01:24:55 | Extended source **close** FILLED — both legs flat | exchange UI | order fill |
| 01:24:55+ | extended source-flat readback → `source_close_flat_confirmed_at` → `double_exposure_ended_at` | code | executor L67–71 |

- **Real overhedge:** 01:24:15 → 01:24:55 = **~40s**.
- **Measured `double_exposure_seconds`:** ~01:24:49 → 01:24:55 ≈ **~6s** (understated by the 34s target poll).
- **Where the delay is:** *before source-close submit* — the executor waits for the slow **target-open
  position readback**. It is **not** the source-close submit itself and **not** only the final readback.

### Note on the ethereal→extended proofs (step3 / final_proof, ~37s)
Different leg assignment: target = extended open, **source = ethereal close**. There the ~37s window is
dominated by the **ethereal source-close** slow poll (the mirror image). The prior fix
(`apply_authoritative_source_close_confirmation!`, see
`docs/executor_authoritative_source_close_double_exposure.md`) is the right lever *for that case* — it
ends the window at the ethereal close fill. But it does **nothing** for extended→ethereal (case here),
where Ethereal is the **target open**. So the prior fix is **necessary but not sufficient**.

---

## Root cause (one sentence)
For target_first, the source close is gated on the target-open leg's slow Ethereal position poll (~34s)
instead of the authoritative target **order fill**, so both legs stay open ~40s; and the double-exposure
window start is stamped after that same poll, so the receipt understates the real overhedge.

## Exact files / functions
- `app/services/hedge_venue_migration_executor.rb`
  - `run` (target_first): `first_leg = @leg_runner.call(...)` blocks; `source_close_submit_started_at` /
    `second_leg = @leg_runner.call(...)` fire only after it returns.
  - `record_target_acceptance_timing!` L685–701 — L692 `target_leg_accepted_at ||= target_leg_submit_finished_at`.
  - `compute_double_exposure_latency!` L773–783 — L777 `double_exposure_started_at ||= target_leg_accepted_at`.
- `app/services/ethereal_hedge_execution_service.rb`
  - `confirm_post_submit_readback` L713–720 — fast path is **close-only**; open → slow poll.
  - `poll_post_submit_readback` L819–829 + `POST_SUBMIT_READBACK_ATTEMPTS`/`_DELAY_SECONDS` L15–16.

---

## Smallest safe fix (proposed — NOT implemented)

One lever: **confirm the target open via the authoritative order fill, and use that fill both to (a)
release the source close and (b) start the window** — mirroring the close-side fast-fill mechanism,
fail-closed, behind a default-off flag.

1. **Ethereal service — fast authoritative confirmation for the target `open` leg**
   Add an open counterpart to `fast_close_fill_readback` (e.g. `fast_open_fill_readback` /
   `classify_open_fill`). Return `confirmed: true` **only** when, from `GET /v1/order` (list, incl.
   filled): order status is terminal **FILLED**, **not** `reduceOnly`, and cumulative `filled >=
   expected open size − one lot` (size correct). Surface
   `open_fill_confirmation: { confirmed, source: "ethereal_order_list_open_fill", confirmed_at,
   filled_eth, open_size_eth, order_status }` with `confirmed_at` = the readback-confirmation time.
   Partial / non-FILLED / reduceOnly / 404 / ambiguous ⇒ **fall back to `poll_post_submit_readback`
   unchanged** (fail closed). Gate behind a flag (reuse `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED` or a
   sibling `ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED`), **default OFF** → byte-for-byte current behavior
   when off.
   - Effect: the target-open leg's `execute` returns in ~1–2s on the fill instead of ~34s, so the
     executor submits the source close immediately after the **authoritative** target fill. The
     existing `leg_confirmed?` / `stop_after_unconfirmed_first_leg` guard means a partial/ambiguous
     target still holds and never closes the source (fail closed).

2. **Executor — start the window at the authoritative target fill (measurement correctness)**
   In `record_target_acceptance_timing!` (or `compute_double_exposure_latency!`), prefer the authoritative
   fill time for the window start:
   `target_leg_accepted_at = open_fill_confirmation.confirmed_at || target_exchange_accept_at ||
   target_leg_submit_finished_at`. Never *later* than today ⇒ can only make the measured window **≥**
   current (never masks). Keep the existing fallback when no authoritative fill is present.

3. **Unchanged safety invariants**
   - Final position readback after **both** legs still required (`final_readback_status`, L67) — proof
     will not certify unless both legs independently confirm.
   - `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS = 5` unchanged.
   - Keep the prior source-close authoritative-fill fix (covers ethereal→extended / ethereal-as-source).
   - source_first path untouched.

## Can target_first meet 5s after the fix? (residual venue latency)
Even with an instant source-close submit, the floor is the **source-close fill latency**:
- **Ethereal source close** (e.g. ethereal→extended): fills fast (~1–3s) with the fast-fill path ⇒
  should meet 5s.
- **Extended source close** (e.g. extended→ethereal, the case here): the extended close appears to take
  **~6s** to fill (01:24:15 target fill + ~34s target poll ⇒ submit ~01:24:49, fill 01:24:55). If that
  ~6s holds, extended-source target_first may still **miss 5s by ~1s** — a genuine **venue-latency
  floor**, not an executor artifact. The next canary receipt (with the detailed leg timestamps now
  proposed) is needed to measure the true extended submit→fill latency. If it is confirmed > 5s, options
  are: (a) accept extended→ethereal as latency-bound and do not certify it at 5s, (b) reduce extended
  close fill latency, or (c) reconsider sequencing for that specific route — **without** weakening the
  threshold.

## Tests to add (proposed)
- Ethereal service: target `open` fast-fill confirms on terminal FILLED + correct size before the slow
  poll and surfaces `open_fill_confirmation`; **partial fill → falls back to slow poll** (fail closed);
  reduceOnly/non-FILLED/404 → fall back; **disabled by default → slow poll unchanged**.
- Executor: with an authoritative open fill, `double_exposure_started_at` = fill `confirmed_at` (not
  `target_leg_submit_finished_at`), the source close is submitted right after the fill, and the window
  reflects the **true** (larger, correct) overhedge; without a fill → current behavior byte-for-byte.
- Executor fail-closed: partial/ambiguous target fill ⇒ source close **not** submitted
  (`stop_after_unconfirmed_first_leg`), no double-close.
- Registry guard: `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` still 5; a corrected (larger) window that
  exceeds 5 does **not** certify.

## Safety confirmation
Read-only investigation only. No code, no live canary, no runner start, no gate enablement, no DB/env/
secrets mutation, no threshold change. Production unchanged: venue ethereal, ethereal short held, extended/
nado flat, runner inactive, route proofs 5/6.
