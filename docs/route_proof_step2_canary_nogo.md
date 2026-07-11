# Position #6 — Step 2 Supervised Canary (nado → ethereal) — NO-GO

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Outcome:** Fail-closed before arming. **No gates armed, no canary run, no DB mutated, runner untouched.**

Scope attempted: **Step 2 preflight only** (nado → ethereal, target_first reposition). Nothing live ran.
Step 3 not run.

---

## Go/no-go evaluation

| Condition | Actual | Result |
|---|---|---|
| runner stopped / pid null / duplicate=false | stopped / None / false | ✅ |
| current venue nado | nado | ✅ |
| only active short venue nado | ["nado"] | ✅ |
| extended & ethereal flat | 0.0 / 0.0 | ✅ |
| open orders zero | zero on all | ✅ |
| inside_tolerance true | True | ✅ |
| target_first supported | True | ✅ |
| expected_final_inside_tolerance true | True | ✅ |
| dry-run has only expected gate blockers | extra safety blocker present | ❌ BLOCK |

Preflight status: `status=stopped, pid=None, venue=nado, active_short_venues=["nado"],
direct_venue_shorts={nado:1.757, ethereal:0.0, extended:0.0}, open_orders zero,
inside_tolerance=true, current_direct_market_safe=true`.

---

## Why it was blocked

The `rehearse_route … nado→ethereal target_first dry_run=true` output included an additional safety
blocker that is NOT a gate blocker:

```
source venue auto must be disabled during migration canary: nado
```

Confirmed cause (read-only):

```
AERODROME_NADO_AUTO_REBALANCE_ENABLED:     enabled=true  source=DB setting  raw="true"
AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED: enabled=false source=DB setting  raw="false"
EXTENDED_AUTO_REBALANCE_ENABLED:           enabled=false source=DB setting  raw="false"
```

The source venue (nado) has auto-rebalance enabled. The canary planner refuses to migrate out of a
venue whose auto-rebalance could fire mid-migration. Extended and Ethereal auto are both false — which
is why Step 1 (migrating from extended) did not hit this.

To proceed, `AERODROME_NADO_AUTO_REBALANCE_ENABLED` must be temporarily disabled — a DB mutation
**outside** the arm/disarm-gates scope authorized for this step ("do NOT mutate DB except arm/disarm
manual canary gates for this single route"). So execution was halted before arming any gate.

---

## Safety confirmation

- Did NOT arm gates — all five manual-canary DB gates verified `false` (nothing to disarm).
- Did NOT run the canary; no live orders, no signatures.
- Did NOT mutate any DB/env/secrets; runner untouched (systemd inactive).
- Only read-only commands were run: `random_production_status`, `rehearse_route … dry_run=true`,
  `OperationalSettings.get`, `manual_canary_gate_status`.

---

## What is required to run Step 2 (needs explicit approval — not done)

Every route from the current venue (nado) to Ethereal has nado as the source, so nado auto-rebalance
must be paused for the canary regardless of path. Options:

1. **Scoped auto-pause DB change** alongside the gate flow: disable
   `AERODROME_NADO_AUTO_REBALANCE_ENABLED` before the canary and re-enable immediately after (mirrors
   arm/disarm). This is a DB mutation beyond the gates and needs explicit approval.
2. **Extend the arm/disarm tasks** to auto-pause/restore the source venue's auto-rebalance as part of
   the canary flow (cleaner + testable), but that is a code change requiring redeploy before use.

Holding here. No Step 3, no runner start, no gates left enabled.
