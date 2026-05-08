# Aerodrome Core PR4

PR4 adds a minimal disabled-by-default Aerodrome hedge gate.

## Included

- Aerodrome hedge processing is skipped unless `AERODROME_HEDGE_ENABLED=true`.
- Missing `AERODROME_HEDGE_ENABLED` behaves as disabled.
- Aerodrome hedge processing also requires `HYPERLIQUID_TESTNET=true`.
- The existing `HedgeSyncJob` path is reused when Aerodrome hedge processing is explicitly enabled and data is complete.
- The existing `HyperliquidService` is reused unchanged.
- Only the ETH/WETH side is eligible for Aerodrome hedging.
- The USDC side is never hedged.

## Not Included

- No live execution is enabled by default.
- No new order execution path.
- No UI changes.
- No controllers, migrations, proposal workflow, dry-run tooling, or operator runbooks.
- No `HyperliquidService` or `UniswapService` changes.

## Default State

The default remains monitor-only. Operators must explicitly set `AERODROME_HEDGE_ENABLED=true` and keep `HYPERLIQUID_TESTNET=true` before Aerodrome positions can enter the existing hedge loop.
