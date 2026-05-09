# Aerodrome Pre-Live Safety Audit

This is not approval to go live. It is a conservative status snapshot for the current read-only Aerodrome Slipstream work.

## Safety Status

| Item | Status | Notes |
| --- | --- | --- |
| Hyperliquid untouched | PASS | `HyperliquidService` is not modified by Aerodrome dry-run tooling. |
| Aerodrome read-only service | PASS | `AerodromeSlipstreamService` uses read-only `eth_call` paths. |
| Dry-run no DB writes | PASS | Dry-run returns reports and does not save records. |
| Dry-run no Hyperliquid | PASS | Dry-run does not instantiate or call `HyperliquidService`. |
| Config verification no DB writes | PASS | `aerodrome:verify_config` validates config and optional read-only RPC only. |
| Config verification no Hyperliquid | PASS | No Hyperliquid calls are used. |
| Pre-live readiness check | PASS | `aerodrome:pre_live_check` is read-only, performs no DB writes, places no orders, and only uses optional mocked/read-only `get_position("ETH")` when `CHECK_HYPERLIQUID=true`. |
| Monitor-only sync disabled by default | PASS | `AERODROME_READ_ONLY_ENABLED=false` is the documented default. |
| HedgeSyncJob skips Aerodrome by default | PASS | `AERODROME_HEDGE_ENABLED=false` or missing skips Aerodrome before `HyperliquidService` construction. |
| Aerodrome kill switch | PASS | `AERODROME_HEDGE_PAUSED` defaults to true when missing. Testnet rehearsal requires explicitly setting `AERODROME_HEDGE_PAUSED=false`. |
| Aerodrome hedge-loop flag | PASS | `AERODROME_HEDGE_ENABLED=true` can only feed complete Aerodrome ETH/WETH-side data into the existing `HedgeSyncJob` path; no new Hyperliquid execution path is added. |
| Aerodrome testnet rehearsal gate | PASS | Testnet rehearsal still requires `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, and `HYPERLIQUID_TESTNET=true`. |
| Aerodrome live approval gate | PASS | Hyperliquid mainnet Aerodrome hedge processing skips before `HyperliquidService` unless `AERODROME_LIVE_APPROVED=true`; this flag is not enough by itself. |
| Aerodrome max short ETH | PASS | Optional `AERODROME_MAX_SHORT_ETH` blocks the ETH/WETH side before the order path when target short exceeds the configured value. |
| Aerodrome max notional | PASS | Optional `AERODROME_MAX_SHORT_NOTIONAL_USD` blocks the ETH/WETH side before the order path when target notional exceeds the configured value. |
| Aerodrome max leverage | PASS | Optional `AERODROME_MAX_LEVERAGE` blocks before the order path when `Setting.hyperliquid_leverage` exceeds the configured value; the app does not silently change leverage. |
| Aerodrome USDC hedge exclusion | PASS | The Aerodrome gate skips USDC and unsupported symbols before `check_and_rebalance`, so the stablecoin side is never hedged. |
| Aerodrome testnet open rehearsal | PASS | A tiny WETH/ETH-side testnet short opened successfully; this is not live approval. |
| Aerodrome testnet close-path rehearsal | BLOCKED PENDING RETEST | The close path exposed a false-success bug, then an SSL ambiguity during explicit close. `HedgeSyncJob` now reconciles ambiguous open/close errors by fetching actual Hyperliquid position state before recording success or failure. Live remains blocked until open and close reconciliation retests pass on testnet. |
| Amount0/amount1 implemented | PASS | Verified amount math is implemented for read-only service, dry-run, and monitor-only sync. |
| USDC-pool valuation preview | PASS | Supported only when one token matches configured `AERODROME_USDC_ADDRESS`; unsupported pairs keep prices nil. |
| WETH/USDC hedge preview | PASS | Preview-only calculation; `execution_enabled=false`, no orders, no Hyperliquid calls. |
| Manual hedge proposals | PASS | Local records only; create/review/reject/regenerate actions do not call Hyperliquid, do not place orders, and do not create executable `Hedge` records. |
| Proposal history/status | PASS | Recent proposal history and current/stale status are display-only and computed from local proposal and position records. |
| Proposal safety limits | PASS | Optional env-configured local checks can mark proposals `PASSED`, `WARNINGS`, or `BLOCKED`; blocked proposals cannot be marked reviewed. |
| UI monitor-only display | PASS | Dashboard/position views label Aerodrome as monitor-only and show no order execution controls. |
| USD valuation for non-USDC pairs | UNKNOWN | No trusted external USD valuation source is implemented. |
| Advanced fees deferred | UNKNOWN | Only raw owed-token fields are safe first reads. |
| Staking/gauge discovery unresolved | UNKNOWN | User-provided token ids remain the conservative starting point. |
| Manager/factory multi-deployment risk | UNKNOWN | Multiple deployments exist; config remains explicit. |
| Tests mock RPC | PASS | Tests use mocks/WebMock for Aerodrome RPC behavior. |
| No real RPC in tests | PASS | No tests require internet or live Base RPC. |
| No `.env` committed | PASS | `.env` remains untouched. |
| No private keys | PASS | Dry-run/config verification do not require private keys. |
| Live order placement | PASS | No Aerodrome path places orders. |
| Approvals/transfers/swaps/NFT transfers | PASS | No write transaction paths are implemented. |

## Recommendation

NOT READY FOR LIVE HEDGE INTEGRATION.

READY ONLY FOR READ-ONLY MANUAL DRY-RUN AND MONITOR-ONLY TESTING.

Manual hedge proposals are not execution approval. Proposal review/rejection only updates local status and timestamps and does not place orders. Safety limits are local proposal checks only. Missing limits are warnings. Blocked proposals must not be used for execution and cannot be marked reviewed. Stale proposals must be regenerated before any manual review. `AERODROME_HEDGE_ENABLED` remains false/default-off.

Aerodrome hedge-loop processing is feature-flagged and disabled by default. Testnet rehearsal requires `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, and `HYPERLIQUID_TESTNET=true`. Hyperliquid mainnet Aerodrome hedge processing requires the separate hard approval flag `AERODROME_LIVE_APPROVED=true`, but that flag is not sufficient by itself: `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, complete readiness data, risk limits, and WETH/ETH-only filtering are still required. Production live must keep `AERODROME_HEDGE_ENABLED=false` and `AERODROME_HEDGE_PAUSED=true` until a separate future first-live procedure is approved. The Aerodrome path reuses the existing HyperliquidService-backed hedge loop unchanged, requires complete persisted position data, supports only ETH/WETH exposure, and skips USDC.

Aerodrome hedge execution is also paused by default through `AERODROME_HEDGE_PAUSED=true`. Missing `AERODROME_HEDGE_PAUSED` is treated as paused. To run any testnet rehearsal, the operator must explicitly set `AERODROME_HEDGE_PAUSED=false`; live trading is still not approved. Optional maximum short ETH, maximum short notional USD, and maximum leverage limits are local pre-order gates for the Aerodrome path only.

Testnet rehearsal found that the open path can submit a tiny WETH/ETH short, but the close path previously used SDK `market_close`, logged `No open position to close for ETH`, and still recorded a successful `ShortRebalance` with `new_short_size=0`. False successful close rebalances created before the close-path fix must not be trusted as evidence that a Hyperliquid short was closed. The close path now uses an explicit opposite market order with the known `current_short` size when `HedgeSyncJob` is closing to zero.

The explicit close retest then encountered `SSL_read: unexpected eof while reading`; the short remained open and the app correctly recorded failure. Similar SSL ambiguity can occur after open orders, where the order may execute even if the client receives a network exception. `HedgeSyncJob` now reconciles ambiguous post-order errors by fetching actual Hyperliquid position state and comparing the actual short size with the intended target before writing the final `ShortRebalance` status. Explicit API rejections remain failures. Live remains blocked until both open and close reconciliation retests pass on testnet.

`bin/rails aerodrome:pre_live_check` and `FORMAT=json bin/rails aerodrome:pre_live_check` provide a read-only readiness report across environment safety, `AERODROME_LIVE_APPROVED` state, local DB readiness, configured risk limits, rehearsal `ShortRebalance` evidence, and optional Hyperliquid readback. Passing this check is not permission for live trading. Live remains disabled by default and requires a separate future approval/change and first-live procedure.

Do not enable Aerodrome hedge execution until amount math, USD valuation, hedge preview/proposal behavior, proposal history/staleness handling, proposal safety-limit operations, fee strategy, staking/gauge behavior, manager/factory coverage, and end-to-end comparisons against Aerodrome UI/BaseScan are complete and tested. Current valuation, hedge previews, safety checks, and manual proposals do not make Aerodrome positions hedge-ready.
