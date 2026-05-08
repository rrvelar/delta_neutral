# Aerodrome Core Adaptation Plan

Date: 2026-05-08

## 1. Original Repo Goal

The original app is a self-hosted Rails bot for Uniswap V3 concentrated liquidity positions. It discovers LP positions, tracks current token amounts and USD values, and uses the existing `HedgeSyncJob` plus `HyperliquidService` to rebalance short hedges on Hyperliquid.

The Aerodrome adaptation goal is narrower than the current branch has become: replace or add the LP position source for Aerodrome Slipstream positions on Base while keeping Hyperliquid as the perp hedge venue and preserving the original bot workflow.

Core parity means:

- discover/read Aerodrome Slipstream LP positions;
- compute current token amounts from Slipstream position math;
- provide USD values needed for display, snapshots, and hedge sizing;
- feed supported Aerodrome exposure into the existing hedge loop behind safety gates;
- keep `HyperliquidService` and existing Uniswap behavior unchanged.

## 2. Current Branch Summary

Compared with `origin/main`, the current branch is much larger than a minimal source-adaptation branch:

- 51 files changed;
- roughly 6,759 insertions;
- core Aerodrome service/math/valuation code was added;
- wallet and position sync now have Aerodrome monitor paths;
- `HedgeSyncJob` has Aerodrome gates, testnet-only rehearsal checks, and ETH/WETH-only filtering;
- substantial UI labels and dashboard/position-page changes were added;
- a manual hedge proposal model, migration, controller, services, lifecycle UI, and safety checks were added;
- dry-run rake tasks and extensive operator documentation were added.

This branch is useful as a local safe-monitor branch, but it is not shaped like a clean upstream-style adaptation PR. It mixes core protocol adaptation with optional product workflow and operational tooling.

## 3. Core-Required Files

These files or equivalent changes are core-required for adapting the bot from Uniswap V3 LP positions to Aerodrome Slipstream LP positions:

- `app/services/aerodrome_slipstream_service.rb`
  - Required for read-only Aerodrome position manager, factory, pool, and token metadata reads.
  - Should remain read-only and dependency-inject RPC clients in tests.

- `app/services/aerodrome_slipstream_math.rb`
  - Required for Slipstream amount math.
  - Must keep tests for in-range, below-range, above-range, rounding, and malformed input.

- `app/services/aerodrome_slipstream_valuation.rb`
  - Required if WETH/USDC or configured-USDC pools are the first supported hedgeable Aerodrome scope.
  - If generalized pricing is not ready, unsupported pairs should remain non-hedgeable.

- `app/jobs/wallet_sync_job.rb`
  - Core if Aerodrome positions are discovered or registered by the scheduled wallet sync.
  - Minimal version should route by source/config and persist only fields required by existing `Position` shape.

- `app/jobs/position_sync_job.rb`
  - Core if Aerodrome position amounts/prices must refresh over time.
  - Minimal version should update existing position amount/price fields and defer fee snapshots unless fee semantics are verified.

- `app/jobs/hedge_sync_job.rb`
  - Core only for small Aerodrome gates before the existing hedge loop.
  - Required pieces are default-off flag, data readiness checks, testnet/live guard while rehearsing, and ETH/WETH-only filtering for WETH/USDC.
  - The existing `check_and_rebalance`, subaccount, margin, circuit breaker, rebalance record, and mailer behavior should stay unchanged.

- `.env.example`
  - Core for non-secret Aerodrome config examples:
    - `AERODROME_READ_ONLY_ENABLED=false`
    - `AERODROME_HEDGE_ENABLED=false`
    - `AERODROME_REQUIRE_HYPERLIQUID_TESTNET=true`
    - `AERODROME_SLIPSTREAM_POSITION_MANAGER=`
    - `AERODROME_SLIPSTREAM_FACTORY=`
    - `AERODROME_SLIPSTREAM_TOKEN_IDS=`
    - `AERODROME_USDC_ADDRESS=`
    - `AERODROME_WETH_ADDRESS=`

- `app/services/dex_position_source_factory.rb`
  - Core only if the project wants explicit source selection instead of direct branching in jobs.
  - Keep it small; avoid turning it into a product workflow.

- Tests:
  - `test/services/aerodrome_slipstream_service_test.rb`
  - `test/services/aerodrome_slipstream_math_test.rb`
  - `test/services/aerodrome_slipstream_valuation_test.rb`
  - Aerodrome additions to `test/jobs/wallet_sync_job_test.rb`
  - Aerodrome additions to `test/jobs/position_sync_job_test.rb`
  - Aerodrome additions to `test/jobs/hedge_sync_job_test.rb`
  - Regression tests proving existing Uniswap behavior still passes unchanged.

## 4. Safety-Required Files

These changes are safety-required if Aerodrome exposure can ever reach the hedge loop:

- `app/jobs/hedge_sync_job.rb`
  - `AERODROME_HEDGE_ENABLED` defaults to false or missing-as-false.
  - Aerodrome hedging requires complete persisted data before `HyperliquidService.new`.
  - Testnet rehearsal requires `HYPERLIQUID_TESTNET=true`.
  - ETH/WETH side only for WETH/USDC; USDC and unsupported symbols are skipped before `check_and_rebalance`.
  - No new execution path; reuse the existing `check_and_rebalance`.

- `.env.example`
  - Must show disabled-by-default flags.
  - Must not make Aerodrome required for existing Uniswap development.

- `test/jobs/hedge_sync_job_test.rb`
  - Must prove Aerodrome flag false skips before `HyperliquidService.new`.
  - Must prove missing/false `HYPERLIQUID_TESTNET` skips before `HyperliquidService.new`.
  - Must prove complete testnet Aerodrome WETH/ETH reaches the existing path with mocked Hyperliquid only.
  - Must prove USDC is skipped and cannot create a hedge order.
  - Must keep existing Uniswap hedge tests passing.

- Existing `app/services/hyperliquid_service.rb`
  - Safety requirement is that this file remains unchanged.

- Existing `app/services/uniswap_service.rb`
  - Safety requirement is that existing Uniswap query behavior remains unchanged unless a later PR intentionally removes Uniswap support.

## 5. Optional / Extra Files

These are optional or probably extra for the original bot adaptation. They may be valuable for this local deployment, but they are not required for upstream-style parity:

- `app/models/aerodrome_hedge_proposal.rb`
- `db/migrate/20260508000000_create_aerodrome_hedge_proposals.rb`
- `app/controllers/aerodrome_hedge_proposals_controller.rb`
- `app/services/aerodrome_hedge_proposal_builder.rb`
- `app/services/aerodrome_hedge_proposal_safety.rb`
- `test/models/aerodrome_hedge_proposal_test.rb`
- `test/services/aerodrome_hedge_proposal_builder_test.rb`
- `test/services/aerodrome_hedge_proposal_safety_test.rb`
- Proposal/history/review/stale UI in `app/views/positions/show.html.erb`
- Routes for proposal lifecycle actions in `config/routes.rb`
- Proposal-specific controller tests in `test/controllers/positions_controller_test.rb`

Likely optional tooling/docs:

- `app/services/aerodrome_slipstream_dry_run.rb`
- `lib/tasks/aerodrome.rake`
- `test/services/aerodrome_slipstream_dry_run_test.rb`
- `test/tasks/aerodrome_task_test.rb`
- `docs/AERODROME_DRY_RUN.md`
- `docs/AERODROME_OPERATOR_RUNBOOK.md`
- `docs/AERODROME_PRE_LIVE_SAFETY_AUDIT.md`
- `docs/AERODROME_ROLLBACK.md`

Likely optional UI polish:

- Aerodrome-specific dashboard labels in `app/views/dashboard/index.html.erb`
- Aerodrome-specific position index labels in `app/views/positions/index.html.erb`
- Broad helper additions in `app/helpers/application_helper.rb`
- Any monitor-only wording that is not needed to prevent accidental execution.

Unrelated or local-environment drift to review separately:

- `app/views/sessions/new.html.erb`
- `config/environments/production.rb`
- `docker-compose.prod.yml`
- `Gemfile.lock` change, if it is not caused by a required dependency.

## 6. Proposed Clean PR Sequence

### PR 1: Aerodrome Read-Only Service + Math + Tests

Scope:

- Add `AerodromeSlipstreamService`.
- Add `AerodromeSlipstreamMath`.
- Add minimal `AerodromeSlipstreamValuation` only for configured WETH/USDC or configured-USDC pools.
- Add `.env.example` Aerodrome read-only config.
- Add mocked RPC tests.
- Add or keep `docs/AERODROME_SLIPSTREAM_VERIFICATION.md` only as protocol verification evidence.

Do not include:

- Hedge loop changes.
- Proposal tables/workflow.
- Large UI changes.
- Dry-run product UI.

### PR 2: Aerodrome Position Sync Replacing/Alongside Uniswap Source

Scope:

- Update `WalletSyncJob` to optionally sync Aerodrome positions for Base wallets.
- Update `PositionSyncJob` to refresh Aerodrome amounts/prices.
- Keep existing `Position` fields where possible.
- Keep Uniswap sync behavior unchanged.
- Add job tests for Aerodrome read-only sync and Uniswap regression.

Do not include:

- Hedge execution enablement.
- Proposal/review workflow.
- New persistent tables unless required for source identity.

### PR 3: Aerodrome Hedge Gate Behind Disabled Flag Using Existing HyperliquidService

Scope:

- Update only the minimal Aerodrome branch in `HedgeSyncJob`.
- Require `AERODROME_HEDGE_ENABLED=true`.
- Require `HYPERLIQUID_TESTNET=true` for rehearsal until a future live approval change exists.
- Require complete persisted Aerodrome data.
- Filter to ETH/WETH side only; never hedge USDC.
- Reuse existing `check_and_rebalance`.
- Add mocked tests proving no Hyperliquid construction on blocked paths and unchanged Uniswap behavior.

Do not include:

- New Hyperliquid services.
- New order methods.
- Manual proposal records.
- Review/approval UI.

### PR 4: Optional UI Labels Only

Scope:

- Add minimal source labels so users can distinguish Uniswap vs Aerodrome positions.
- Add clear disabled/testnet wording only where it prevents unsafe operation.
- Avoid adding new product workflow.

Do not include:

- Proposal history.
- Review/reject lifecycle.
- Stale proposal UI.
- Operator dashboards beyond existing bot needs.

## 7. Files/Changes That Should Not Be Part Of A Minimal Original-Repo Adaptation

Exclude from a clean upstream-style adaptation unless a maintainer explicitly asks for them:

- `AerodromeHedgeProposal` model and migration.
- Proposal builder/safety services.
- Proposal controller and routes.
- Proposal history/review/reject/regenerate UI.
- Stale proposal display.
- Proposal safety-limit UI.
- Extensive operator runbooks that describe local operational process rather than code behavior.
- Rollback docs specific to the current local deployment.
- Dry-run tasks if the clean PR already has mocked service tests and a small verification doc.
- Any docs tied to a local Mac mini, local operator workflow, or local deployment conventions.
- Any UI changes unrelated to source identity, safety labels, or existing bot parity.
- Any production/docker/session changes not directly required by Aerodrome source support.

## 8. Recommendation

Keep this current branch as the local safe monitor version. It contains useful operational guardrails, manual proposal tooling, and local safety checks that are appropriate for a cautious single-operator deployment.

If targeting the original repository or an upstream-style PR, create a cleaner core branch from `origin/main` and replay only the core sequence:

1. Aerodrome read-only service, Slipstream math, valuation, and mocked tests.
2. Aerodrome wallet/position sync with Uniswap regression tests.
3. Minimal Aerodrome hedge gate behind disabled/testnet flags using the existing `HyperliquidService`.
4. Optional minimal UI labels only.

The clean branch should not include the manual proposal lifecycle or extra operator-product workflow unless it becomes explicitly required for parity or safety.
