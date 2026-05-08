# Aerodrome Rollback

This document covers disabling and backing out read-only Aerodrome Slipstream monitoring. It does not include private key, trading, or order-management instructions.

## Disable Read-Only Aerodrome

Set:

```env
AERODROME_READ_ONLY_ENABLED=false
```

Clear configured token ids:

```env
AERODROME_SLIPSTREAM_TOKEN_IDS=
```

Keep hedge execution disabled:

```env
AERODROME_HEDGE_ENABLED=false
```

Do not edit `.env` through automated tooling. Make local/operator env changes manually.

## Confirm HedgeSyncJob Is Not Using Aerodrome Positions

Run:

```bash
bin/rails runner 'puts Hedge.joins(position: :dex).where(dexes: { name: "aerodrome_slipstream" }).count'
```

If any rows exist, `HedgeSyncJob` should still skip them because Aerodrome positions are monitor-only. Confirm recent logs show:

```text
Aerodrome positions are monitor-only
```

Also verify no new `ShortRebalance` records were created for Aerodrome positions.

## Restore From Git

To inspect local changes:

```bash
git status --short
git diff
```

To restore files, use normal git review practices and avoid destructive commands unless you explicitly intend to discard local changes.

## Remove Monitor-Only Positions Manually If Needed

Only remove database records if they were created during monitor-only testing and you have confirmed they are not needed.

Suggested inspection:

```bash
bin/rails runner 'puts Position.joins(:dex).where(dexes: { name: "aerodrome_slipstream" }).pluck(:id, :external_id, :pool_address).inspect'
```

Manual removal should be deliberate and backed up. Do not remove Uniswap positions.

## What Not To Delete

- Do not delete `.env`.
- Do not delete Uniswap positions.
- Do not delete Hyperliquid settings or subaccount records.
- Do not delete historical `ShortRebalance` records unless you are performing a deliberate database restore.
- Do not remove `AERODROME_HEDGE_ENABLED=false`; keep it explicitly disabled if present.

## No Trading Instructions

Rollback does not require:

- private keys;
- Hyperliquid API credentials;
- order placement;
- approvals;
- swaps;
- NFT transfers;
- transaction signing.

If rollback appears to require live trading actions, stop and reassess. The current Aerodrome integration is read-only and should not require trading operations to disable.
