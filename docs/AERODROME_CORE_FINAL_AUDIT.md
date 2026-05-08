# Aerodrome Core Final Audit

## 1. Summary

Branch: `aerodrome-core-original`

This branch is a minimal core adaptation of the original `delta_neutral` Rails bot from Uniswap V3 LP monitoring toward Aerodrome Slipstream LP monitoring on Base, while keeping Hyperliquid as the perp hedge venue.

The branch adds read-only Aerodrome Slipstream position reads, Slipstream amount math, USDC-quoted valuation, minimal read-only sync into the existing `positions` schema, and a disabled-by-default Aerodrome hedge gate in the existing `HedgeSyncJob`.

## 2. Core Files Added/Changed

Added:

- `app/services/aerodrome_slipstream_math.rb`
- `app/services/aerodrome_slipstream_service.rb`
- `app/services/aerodrome_slipstream_valuation.rb`
- `docs/AERODROME_CORE_PR1.md`
- `docs/AERODROME_CORE_PR2.md`
- `docs/AERODROME_CORE_PR3.md`
- `docs/AERODROME_CORE_PR4.md`
- `docs/AERODROME_CORE_FINAL_AUDIT.md`
- `test/services/aerodrome_slipstream_math_test.rb`
- `test/services/aerodrome_slipstream_service_test.rb`
- `test/services/aerodrome_slipstream_valuation_test.rb`

Changed:

- `.env.example`
- `app/jobs/wallet_sync_job.rb`
- `app/jobs/position_sync_job.rb`
- `app/jobs/hedge_sync_job.rb`
- `test/jobs/wallet_sync_job_test.rb`
- `test/jobs/position_sync_job_test.rb`
- `test/jobs/hedge_sync_job_test.rb`

## 3. Files Not Changed

Confirmed unchanged versus upstream/main:

- `app/services/hyperliquid_service.rb`
- `app/services/uniswap_service.rb`
- `app/controllers/**`
- `app/views/**`
- `app/models/**`
- `db/migrate/**`
- `db/schema.rb`
- `.env`

## 4. Optional Workflow Check

The branch does not contain the optional/product workflow items that were intentionally excluded:

- No dry-run rake tasks.
- No Aerodrome hedge preview service.
- No manual hedge proposal model/table/controller.
- No proposal history/review/reject workflow.
- No stale proposal UI.
- No safety-limit UI.
- No Mac mini deployment docs.
- No operator runbooks.
- No rollback docs.
- No extra Aerodrome controllers or views.

The only Aerodrome docs present are minimal core PR documents and this audit.

## 5. Test Status

`bin/rake` is the required validation command. Current branch test status: passed.

Latest run:

- `153 runs, 495 assertions, 0 failures, 0 errors, 0 skips`
- RuboCop: `102 files inspected, no offenses detected`

The current Aerodrome coverage includes mocked tests for:

- Slipstream amount math.
- Read-only Aerodrome RPC decoding.
- USDC-quoted valuation.
- Wallet sync with explicit token IDs.
- Position sync refresh without Aerodrome PnL snapshots.
- Disabled-by-default Aerodrome hedge gate.
- Testnet guard.
- WETH/ETH-only hedge filtering.
- Existing Uniswap behavior.

## 6. Safety Status

- `AERODROME_HEDGE_ENABLED=false` is present in `.env.example`.
- Missing `AERODROME_HEDGE_ENABLED` behaves as disabled.
- Aerodrome hedge path requires `HYPERLIQUID_TESTNET=true`.
- Aerodrome hedges skip before `HyperliquidService.new` unless enabled, testnet is true, and data is complete.
- USDC side is skipped for Aerodrome hedges.
- Only `WETH`/`ETH` sides can enter the existing `check_and_rebalance` path.
- `HyperliquidService` is reused unchanged.
- No new order execution path exists.

## 7. Remaining Known Limitations

- Aerodrome sync uses explicit `AERODROME_SLIPSTREAM_TOKEN_IDS` only.
- No wallet enumeration.
- No staked position or gauge discovery.
- No Aerodrome UI labels in this core branch.
- Operator must configure manager, factory, USDC, WETH, token IDs, and Base RPC values.
- Live execution still requires separate review, verification, and approval beyond this branch.

## 8. Suggested Upstream PR Description

This PR adapts the core bot infrastructure for Aerodrome Slipstream on Base while preserving existing Uniswap and Hyperliquid behavior.

It adds a read-only Aerodrome Slipstream service, verified-style Slipstream amount math, USDC-quoted valuation for configured USDC pools, and minimal position sync using explicit token IDs. Aerodrome hedge processing is added behind `AERODROME_HEDGE_ENABLED=false` and requires `HYPERLIQUID_TESTNET=true`; when enabled, it reuses the existing `HedgeSyncJob` and `HyperliquidService` paths and only permits the WETH/ETH side for WETH/USDC positions.

The branch intentionally does not add UI, controllers, migrations, proposal workflows, dry-run tooling, operator runbooks, wallet enumeration, or staked/gauge discovery. Existing Uniswap behavior and `HyperliquidService` remain unchanged.
