# Ethereal ETH-USD Product Constants — Read-Only Fetch (2026-07-10)

Read-only fetch of authoritative Ethereal ETH-USD product constants for the
fragile ethereal->extended <5s attempt, via
`HedgeBackends::EtherealReadOnlyProbe#market_metadata` in the running prod web
container. No auth, no signer, no orders, no env changes.

## Results (two runs, 10 seconds apart)

Run 1:

```json
{"market":"ETH-USD","status":"ACTIVE","ETHEREAL_LOT_SIZE":"0.0001","ETHEREAL_TICK_SIZE":"0.1","ETHEREAL_ONCHAIN_ID":2}
```

Run 2 (10s later):

```json
{"market":"ETH-USD","status":"ACTIVE","ETHEREAL_LOT_SIZE":"0.0001","ETHEREAL_TICK_SIZE":"0.1","ETHEREAL_ONCHAIN_ID":2}
```

Values are byte-for-byte identical across both runs — stable.

Key-source check: the `2` comes from the product's `onchainId` field directly
(`raw["onchainId"] = 2`), not the `id` fallback (`raw["id"]` is the UUID
`480014cc-536e-4fd4-958b-b2afcf8ce09f`).

## Proposed env lines (NOT applied)

```
ETHEREAL_LOT_SIZE=0.0001
ETHEREAL_TICK_SIZE=0.1
ETHEREAL_ONCHAIN_ID=2
```

## Where to set them

The prod web container loads env from `/opt/delta_neutral/.env.production`
(`docker-compose.prod.yml` → `services.web.env_file: .env.production`).
Append the three lines there, then recreate the web container for them to take
effect. None of the three vars currently exist in `.env.production`
(verified — grep returned no matches).

## Confirmations

- No env file was changed.
- No live action taken: no deploy, no canary, no gates armed, no runner
  start/restart, no orders/signatures/cancels, no route run, no push, no
  DB/env/secret mutation. Only two read-only metadata fetches were executed.
