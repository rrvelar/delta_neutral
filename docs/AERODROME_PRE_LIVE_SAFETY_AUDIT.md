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
| HedgeSyncJob skips Aerodrome positions | PASS | Aerodrome positions are monitor-only and skipped. |
| Amount0/amount1 implemented | PASS | Verified amount math is implemented for read-only service, dry-run, and monitor-only sync. |
| USDC-pool valuation preview | PASS | Supported only when one token matches configured `AERODROME_USDC_ADDRESS`; unsupported pairs keep prices nil. |
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

Do not enable Aerodrome hedge execution until amount math, USD valuation, fee strategy, staking/gauge behavior, manager/factory coverage, and end-to-end comparisons against Aerodrome UI/BaseScan are complete and tested. Current valuation preview does not make Aerodrome positions hedge-ready.
