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
| Monitor-only sync disabled by default | PASS | `AERODROME_READ_ONLY_ENABLED=false` is the documented default. |
| HedgeSyncJob skips Aerodrome by default | PASS | `AERODROME_HEDGE_ENABLED=false` or missing skips Aerodrome before `HyperliquidService` construction. |
| Aerodrome kill switch | PASS | `AERODROME_HEDGE_PAUSED` defaults to true when missing. Testnet rehearsal requires explicitly setting `AERODROME_HEDGE_PAUSED=false`. |
| Aerodrome hedge-loop flag | PASS | `AERODROME_HEDGE_ENABLED=true` can only feed complete Aerodrome ETH/WETH-side data into the existing `HedgeSyncJob` path; no new Hyperliquid execution path is added. |
| Aerodrome testnet-only rehearsal | PASS | Even when `AERODROME_HEDGE_ENABLED=true`, Aerodrome hedge processing requires `HYPERLIQUID_TESTNET=true`; missing or false skips before `HyperliquidService` construction. |
| Aerodrome max short ETH | PASS | Optional `AERODROME_MAX_SHORT_ETH` blocks the ETH/WETH side before the order path when target short exceeds the configured value. |
| Aerodrome max notional | PASS | Optional `AERODROME_MAX_SHORT_NOTIONAL_USD` blocks the ETH/WETH side before the order path when target notional exceeds the configured value. |
| Aerodrome max leverage | PASS | Optional `AERODROME_MAX_LEVERAGE` blocks before the order path when `Setting.hyperliquid_leverage` exceeds the configured value; the app does not silently change leverage. |
| Aerodrome USDC hedge exclusion | PASS | The Aerodrome gate skips USDC and unsupported symbols before `check_and_rebalance`, so the stablecoin side is never hedged. |
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

Aerodrome hedge-loop processing is feature-flagged and disabled by default. If an operator sets `AERODROME_HEDGE_ENABLED=true`, `HedgeSyncJob` still requires `HYPERLIQUID_TESTNET=true` before any Aerodrome hedge can construct `HyperliquidService`. This is a testnet-only rehearsal path, not production live approval. Production live must keep `AERODROME_HEDGE_ENABLED=false` until a separate future checklist and code change add an explicit live approval gate. The Aerodrome path reuses the existing HyperliquidService-backed hedge loop unchanged, requires complete persisted position data, supports only ETH/WETH exposure, and skips USDC.

Aerodrome hedge execution is also paused by default through `AERODROME_HEDGE_PAUSED=true`. Missing `AERODROME_HEDGE_PAUSED` is treated as paused. To run any testnet rehearsal, the operator must explicitly set `AERODROME_HEDGE_PAUSED=false`; live trading is still not approved. Optional maximum short ETH, maximum short notional USD, and maximum leverage limits are local pre-order gates for the Aerodrome path only.

Do not enable Aerodrome hedge execution until amount math, USD valuation, hedge preview/proposal behavior, proposal history/staleness handling, proposal safety-limit operations, fee strategy, staking/gauge behavior, manager/factory coverage, and end-to-end comparisons against Aerodrome UI/BaseScan are complete and tested. Current valuation, hedge previews, safety checks, and manual proposals do not make Aerodrome positions hedge-ready.
