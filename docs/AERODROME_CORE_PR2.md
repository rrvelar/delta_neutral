# Aerodrome Core PR2

PR2 connects minimal Aerodrome Slipstream read-only position sync.

## Included

- Aerodrome wallet sync runs only when `AERODROME_READ_ONLY_ENABLED=true`.
- Sync uses explicit `AERODROME_SLIPSTREAM_TOKEN_IDS`; there is no wallet enumeration.
- Sync is limited to wallets on the `base` network.
- The synced position uses the existing `positions` schema with `dex` set to `aerodrome_slipstream`.
- Position sync refreshes Aerodrome metadata and amounts through the read-only service.

## Not Included

- No staked position or gauge discovery.
- No Aerodrome PnL snapshots.
- No hedge execution for Aerodrome.
- No `HyperliquidService` changes.
- No controllers, views, migrations, proposal workflow, dry-run tooling, or operator runbooks.

## Next PR

PR3 should add either safe USD valuation for hedge sizing or the disabled hedge gate from the core adaptation plan.
