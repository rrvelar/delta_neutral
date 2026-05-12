# Ethereal Read-Only PR Review

Date checked: 2026-05-12

ETHEREAL READ-ONLY PR REVIEW - NO ORDERS

## Summary

This branch adds Ethereal read-only probe tooling, observation recording, observation summaries, endpoint safety mapping, docs, and static guardrails. It does not add an Ethereal live adapter.

Production remains Hyperliquid-only.

## What Changed

Services:

- `app/services/hedge_backends/errors.rb`
- `app/services/hedge_backends/position_snapshot.rb`
- `app/services/hedge_backends/market_metadata.rb`
- `app/services/hedge_backends/account_health.rb`
- `app/services/hedge_backends/probe_result.rb`
- `app/services/hedge_backends/ethereal_read_only_probe.rb`
- `app/services/hedge_backends/ethereal_observation_recorder.rb`
- `app/services/hedge_backends/ethereal_observation_summary.rb`
- `app/services/hedge_backends/ethereal_endpoint_policy.rb`
- `app/services/hedge_backends/ethereal_safety_check.rb`

Tasks:

- `hedge_backends:ethereal_probe`
- `hedge_backends:ethereal_probe_record`
- `hedge_backends:ethereal_observation_summary`
- `hedge_backends:ethereal_safety_check`

Tests:

- Hedge backend value object tests.
- Ethereal read-only probe tests.
- Observation recorder tests.
- Hedge backend task tests.
- Ethereal static safety integration tests.

Docs:

- `docs/ETHEREAL_READ_ONLY_PROBE.md`
- `docs/ETHEREAL_OPENAPI_ENDPOINT_MAP.md`
- `docs/ETHEREAL_TESTNET_READ_ONLY_RUNBOOK.md`
- `docs/ETHEREAL_MERGE_READINESS_CHECKLIST.md`
- `docs/ETHEREAL_SANDBOX_ORDER_PROOF_PLAN.md`
- `docs/ETHEREAL_READ_ONLY_PR_REVIEW.md`
- `docs/HEDGE_BACKEND_ADAPTER_RESEARCH.md`

Env examples:

- `.env.example` includes read-only Ethereal probe variables only.

## What Did Not Change

- No `HyperliquidService` behavior change.
- No `HedgeSyncJob` behavior change.
- No `AerodromeProductionLiveRunner` behavior change.
- No `AerodromeLiveEmergencyClose` behavior change.
- No production safety gate change.
- No migrations or schema changes.
- No UI live buttons.
- No unattended automation.
- No Ethereal production routing.

## Production Safety Statement

Production remains Hyperliquid-only. Ethereal tasks are disabled by default and are manual read-only tools. There is no Ethereal order path, close path, reduce-only close path, signing path, private-key support, or production runner integration.

## Review Code Safely

Start with static checks:

```bash
git status --short
HOME=/private/tmp XDG_CACHE_HOME=/private/tmp bin/rake
FORMAT=json bin/rails hedge_backends:ethereal_safety_check
git diff --name-only | grep -E 'hyperliquid_service|hedge_sync_job|aerodrome_production_live_runner|aerodrome_live_emergency_close|\.env$|\.env.production|schema|migration' || true
```

Review `app/services/hedge_backends/ethereal_read_only_probe.rb` and confirm it calls only the read-only allowlist:

- `GET /v1/product`
- `GET /v1/product/market-price`
- `GET /v1/position/active`
- `GET /v1/subaccount/balance`

## Verify No Production Wiring

```bash
rg -n 'Ethereal|ETHEREAL|HedgeBackends' app/jobs/hedge_sync_job.rb app/services/hyperliquid_service.rb app/services/aerodrome_production_live_runner.rb app/services/aerodrome_live_emergency_close.rb lib/tasks/aerodrome.rake
```

Expected result: no production runtime references.

## Verify No Order, Close, Or Signing Paths

```bash
rg -n 'open_short|close_short|rebalance_short|place_order|cancel_order|set_leverage|ensure_leverage|transfer|withdraw|deposit|sign_order|execute' app/services/hedge_backends lib/tasks/hedge_backends.rake
rg -n 'POST /v1/order|/cancel|/withdraw|/linked-signer|/sign|/trade|/execute' app/services/hedge_backends lib/tasks/hedge_backends.rake
```

Expected result: dangerous terms appear only in policy/docs/tests as forbidden classifications, not as executable probe calls.

## Verify No Secrets

```bash
rg -n 'ETHEREAL_PRIVATE_KEY|ETHEREAL_SIGNING_KEY|ETHEREAL_TRADING_KEY|ETHEREAL_ORDER_ENABLED|ETHEREAL_CLOSE_ENABLED|ETHEREAL_LIVE_APPROVED' .env.example app lib test docs
git diff -- .env .env.production
```

Expected result: forbidden env names appear only in safety tests/docs as forbidden examples. `.env` and `.env.production` are unchanged.

## Run Tests

```bash
HOME=/private/tmp XDG_CACHE_HOME=/private/tmp bin/rake
FORMAT=json bin/rails hedge_backends:ethereal_safety_check
```

## Run Read-Only Probe Locally

Use testnet:

```bash
ETHEREAL_READ_ONLY_ENABLED=true ETHEREAL_API_BASE_URL=https://api.etherealtest.net ETHEREAL_MARKET_SYMBOL=ETH-USD bin/rails hedge_backends:ethereal_probe
```

Record a local sanitized observation only after review:

```bash
ETHEREAL_READ_ONLY_ENABLED=true ETHEREAL_API_BASE_URL=https://api.etherealtest.net ETHEREAL_MARKET_SYMBOL=ETH-USD bin/rails hedge_backends:ethereal_probe_record
```

Do not commit real observations unless manually reviewed and sanitized.

## VPS Deployment

Do not deploy this branch to the VPS automatically. This branch adds manual read-only tooling only. It does not need to run on production, and enabling Ethereal in production is outside this branch.

## Merge Decision Checklist

- `bin/rake` passes.
- `hedge_backends:ethereal_safety_check` passes.
- No production files reference Ethereal.
- No order/close/signing/private-key path exists.
- No `.env` or `.env.production` changes exist.
- No migrations/schema changes exist.
- No real observation files are tracked.
- Reviewer accepts that the next approved step is manual read-only testnet observation only.

## Rollback Instructions

If unexpected production references or execution paths are found after merge, revert the merge commit. Then rerun:

```bash
HOME=/private/tmp XDG_CACHE_HOME=/private/tmp bin/rake
FORMAT=json bin/rails hedge_backends:ethereal_safety_check
```

## Remaining Unknowns

- `min_notional_usd` is not proven from official product metadata.
- Safe production read-only auth model is not proven.
- Position zero/no-position semantics are not proven.
- Account health/margin semantics are not fully proven.
- Order status, fills, partial fills, reduce-only close, and final zero readback are not proven.

## Next Approved Step

Manual read-only testnet observation only. Sandbox order proof requires a separate explicit task, separate branch, and new review.

## Official Sources Checked

- https://docs.ethereal.trade/
- https://docs.ethereal.trade/protocol-reference/api-hosts
- https://docs.ethereal.trade/protocol-reference/contracts
- https://docs.ethereal.trade/trading/perpetual-futures/ethereal-testnet
- https://docs.ethereal.trade/developer-guides/trading-api/quick-start
- https://docs.ethereal.trade/developer-guides/trading-api/products
- https://docs.ethereal.trade/developer-guides/trading-api/accounts-and-signers
- https://docs.ethereal.trade/developer-guides/trading-api/message-signing
- https://docs.ethereal.trade/developer-guides/trading-api/order-placement
- https://docs.ethereal.trade/developer-guides/trading-api/system-limits
- https://docs.ethereal.trade/developer-guides/trading-api/websockets
- https://docs.ethereal.trade/developer-guides/sdk/python-sdk
- https://api.ethereal.trade/openapi.json
- https://api.etherealtest.net/openapi.json
- https://api.ethereal.trade/docs
- https://api.etherealtest.net/docs
