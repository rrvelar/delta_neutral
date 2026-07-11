# ethereal→extended double-exposure reduction — commit + deploy readiness

**Commit:** `eba6b3c` — "Reduce ethereal to extended double exposure path" (branch `feature/dashboard-hedge-execution-controls`).
**Not deployed. Not pushed. No canary/gates/runner/orders. No env mutated.**

## Committed files (8)

Runtime:
- `app/services/migration_manual_live_canary_runner.rb`
- `app/services/hedge_venue_migration_executor.rb`
- `app/services/extended_mainnet_lifecycle_check.rb`
- `app/services/ethereal_hedge_execution_service.rb`

Tests:
- `test/services/hedge_venue_migration_executor_test.rb`
- `test/services/migration_manual_live_canary_runner_test.rb`
- `test/services/ethereal_hedge_execution_service_test.rb`
- `test/services/extended_mainnet_lifecycle_check_test.rb`

`8 files changed, 390 insertions(+), 7 deletions(-)`

## Scope proof (from the committed diff)

- **No threshold changes** — no `MIGRATION_MAX_*` constant touched; the 5/10/15/45 defaults are unchanged (guarded by a new test).
- **No route policy changes** — no strategy/route-selection code touched.
- **No proof registry changes** — `app/services/migration_route_proof_registry.rb` and `migration_live_route_capability.rb` are NOT in the commit; the 6-route set is guarded by a new test.
- **No order-construction semantic changes** — side / reduce_only / limit price / rounded_size / submit payload / EIP-712 build are unchanged. Only added receipt-diagnostic fields (`account_diagnostics_deferred`, `product_metadata_env_status`) and conditionally skipped the diagnostic-only `account_state` read.
- **No blocker removed** — `preview_blockers` and `live_blockers` are untouched.
- **Final readback still mandatory** — executor `final_readback_status` / `mark_time!(:source_close_position_readback_confirmed_at)` unchanged; the frozen source position only *sizes* the close.
- **Ethereal close still requires order-list fill / fresh final readback, not submit/accepted** — `apply_authoritative_source_close_confirmation!` and the Ethereal close confirmation path are unchanged.

## Tests

`210 runs, 1285 assertions, 0 failures, 0 errors, 0 skips`; RuboCop `8 files inspected, no offenses detected` (throwaway test container, isolated sqlite).

## Remaining working-tree changes (intentionally NOT committed)

Pre-existing / unrelated to this work — left untouched:
- `.dockerignore` (M) — adds `audit/`
- `test/services/migration_route_proof_registry_test.rb` (M) — earlier-session registry test additions + date relativization
- untracked: `audit/`, `extended`, and prior `docs/*.md` reports

## Env-constants verification step (read-only — DO NOT set env yet)

The <5s floor needs `ETHEREAL_LOT_SIZE`, `ETHEREAL_TICK_SIZE`, `ETHEREAL_ONCHAIN_ID` so the ~3s `GET /v1/product` read is skipped on the critical path (Part D reports this; it does not invent values). All three are currently unset in prod.

**Source endpoint (already used by the app):** `GET {ETHEREAL_API_BASE_URL}/v1/product?ticker=ETHUSD&limit=100`
(public product metadata; no auth headers, no signer, no order — genuinely read-only). The app picks the `data[]` entry where `displayTicker == "ETH-USD"`.

**Response field → env value mapping** (`EtherealReadOnlyProbe#market_metadata`, `product_for`):

| Env var | Product response field | Notes |
|---|---|---|
| `ETHEREAL_LOT_SIZE` | `data[].lotSize` | |
| `ETHEREAL_TICK_SIZE` | `data[].tickSize` | |
| `ETHEREAL_ONCHAIN_ID` | `data[].onchainId` (fallback `data[].id`) | matches `ethereal_onchain_id` resolution |

**Proposed read-only command (recommended — exact app code path, resolves market + base URL from prod env, no secrets printed):**

```
docker exec delta_neutral-web-1 bin/rails runner '
  md = HedgeBackends::EtherealReadOnlyProbe.new(env: ENV).market_metadata
  puts({
    market: md.market, status: md.status,
    ETHEREAL_LOT_SIZE:   md.lot_size,
    ETHEREAL_TICK_SIZE:  md.tick_size,
    ETHEREAL_ONCHAIN_ID: (md.raw["onchainId"] || md.raw["id"])
  }.to_json)
'
```

This performs a single `GET /v1/product` (the read the app already makes), mutates nothing, and prints only the three product constants (no keys/secrets). Proposed env values are exactly its output; **do not set env from this until the values are eyeballed against a second call for stability.**

## Deploy plan (LATER — DO NOT run now)

1. Run the read-only command above (twice) to capture stable `ETHEREAL_LOT_SIZE` / `ETHEREAL_TICK_SIZE` / `ETHEREAL_ONCHAIN_ID`.
2. Set those three in production env (separate, explicit step).
3. Rebuild + restart the web image so `eba6b3c` goes live.
4. Read-only preflight/dry-run for `ethereal->extended`.
5. One supervised manual live canary under the full gated arm/disarm sequence; measure `double_exposure_seconds`.
6. Only if measured value is safely < 5s does the route proof advance.

**`ethereal->extended` remains 5/6 until deployed + re-measured by one supervised canary.** This is a fragile <5s attempt (~4.35s modelled floor, ~0.65s margin against Ethereal API jitter).
