# Env Update + Deploy of eba6b3c (fragile ethereal->extended <5s attempt) — 2026-07-10

Scope executed: append 3 verified non-secret Ethereal product constants to
`.env.production` and rebuild/recreate the prod web container at eba6b3c.
No canary, no gates, no runner, no orders, no route, no push, no threshold or
policy changes, no DB/secret mutation.

## Pre-deploy checks

- HEAD: `eba6b3c 2026-07-09 18:26:02 +0000 Reduce ethereal to extended double exposure path` ✓
- Runner `delta-neutral-random-production-6.service`: `inactive` ✓
- The three `ETHEREAL_*` constants: absent from `.env.production` before update ✓
- Uncommitted changes: `.dockerignore` (adds `audit/` to build-context ignore — build-hygiene
  only, no runtime effect) and a test-file change (not shipped behavior). Untracked
  `docs/`, `audit/`, `extended` artifacts. Nothing runtime-relevant to the deploy.

## Env update

Backed up first: `.env.production.backup.20260710_*` (timestamped copy, `cp -p`).

Appended (now verified at lines 170–172):

```
# Ethereal ETH-USD product constants for migration critical path
ETHEREAL_LOT_SIZE=0.0001
ETHEREAL_TICK_SIZE=0.1
ETHEREAL_ONCHAIN_ID=2
```

## Deploy

- `docker compose -f docker-compose.prod.yml build web` — success
- `docker compose -f docker-compose.prod.yml up -d web` — container recreated and started
- Image: `delta_neutral-web:latest`, ID `75c9b7c6df53`, created `2026-07-10T17:14:40Z`, 293MB
- Commit in running image: not embedded (`.git` excluded from image); repo HEAD at build
  time was `eba6b3c`.

## In-container ENV verification

```
{ETHEREAL_LOT_SIZE: "0.0001", ETHEREAL_TICK_SIZE: "0.1", ETHEREAL_ONCHAIN_ID: "2", head: ""}
```

## Production state after deploy (read-only)

- Current production venue: extended; direct venue shorts: extended `1.687`,
  ethereal `0.0`, nado `0.0`
  - **Note:** expected "around 1.857" — actual is **1.687**. Heartbeat shows
    `target_short_eth 1.709`, `combined_short_eth 1.672`, `inside_tolerance: true`,
    so 1.687 is consistent with the recorded target; the 1.857 expectation appears
    to be a typo/stale figure. Flagged, not acted on.
- Open orders: zero on all three venues ✓
- `inside_tolerance`: true ✓
- Gates: `MIGRATION_LIVE_ENABLED=false`, `MIGRATION_AUTO_ENABLED=false`,
  `MIGRATION_RANDOM_ROTATION_LIVE_ENABLED=false` ✓
- Runner: status `stopped`, systemd unit `inactive`, no pid/lock, no duplicate process ✓
- Route proofs: 5/6 READY_FOR_RANDOM; `ethereal->extended` **STALE** (blocker:
  "proof is stale and must be repeated") ✓ — restart blocked by route proofs, as expected
- `orders_submitted: 0`, `orders_placed: 0`, `signatures_created: 0`

## Confirmations

- No live canary run, no gates armed, no runner start/restart, no scheduler run,
  no orders/signatures/cancels, no route run, no push, no threshold/policy changes,
  no blockers removed, no secrets/keys touched, no DB mutation.
- Only production mutations: the 3-line env append (plus a timestamped backup copy
  of `.env.production`) and the web image rebuild/container recreate.

## Next step

Read-only preflight/dry-run of the fragile ethereal->extended <5s path before any
supervised canary.
