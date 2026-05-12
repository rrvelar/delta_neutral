# Ethereal Merge Readiness Checklist

Date checked: 2026-05-12

## Merge Position

NO ORDERS. NO CLOSE. NO SIGNING. NO PRODUCTION WIRING.

This branch is intended to be safe to merge only as read-only Ethereal research/probe tooling. It must not be merged if it contains production wiring, order execution, close logic, signing/private-key support, schema changes, or real unsanitized observation files.

Production remains Hyperliquid-only after merge.

## Merge Blockers

- Any production wiring to Ethereal.
- Any order, close, reduce-only close, execution, signing, or private-key path.
- Any `.env` or `.env.production` changes.
- Any `HyperliquidService`, `HedgeSyncJob`, `AerodromeProductionLiveRunner`, or `AerodromeLiveEmergencyClose` behavior changes.
- Failing tests or RuboCop offenses.
- Any committed real observation containing account ids, subaccount ids, balances, positions, or secrets.
- Any migration or schema change.

## Required Commands Before Merge

```bash
git status --short
HOME=/private/tmp XDG_CACHE_HOME=/private/tmp bin/rake
git diff --name-only | grep -E 'hyperliquid_service|hedge_sync_job|aerodrome_production_live_runner|aerodrome_live_emergency_close|\.env$|\.env.production|schema|migration' || true
rg -n 'ETHEREAL_PRIVATE_KEY|ETHEREAL_SIGNING_KEY|ETHEREAL_ORDER_ENABLED|ETHEREAL_CLOSE_ENABLED|ETHEREAL_LIVE_APPROVED' .env.example app lib test docs
git ls-files storage/hedge_backends/ethereal_observations
```

Expected results:

- `bin/rake` passes.
- Safety grep has no output.
- Forbidden Ethereal env names appear only in safety tests/docs as forbidden examples, never as env assignments.
- No real observation files are tracked.

## Branch Merge Strategy

- Merge read-only probe tooling only after review.
- Do not deploy to VPS automatically as part of merge.
- Do not enable Ethereal in production.
- Do not add Ethereal env vars to production secrets.

## Post-Merge Behavior

- Production remains Hyperliquid-only.
- Ethereal tasks remain disabled by default through `ETHEREAL_READ_ONLY_ENABLED=false`.
- No background jobs call Ethereal.
- No Aerodrome production runner calls Ethereal.

## Rollback Plan

If any unexpected production reference appears, revert the merge commits. Then rerun the safety grep and full `bin/rake` before attempting a corrected read-only-only merge.

## Official Sources Checked

- https://docs.ethereal.trade/
- https://docs.ethereal.trade/protocol-reference/api-hosts
- https://docs.ethereal.trade/protocol-reference/contracts
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
