# Reposition canary NO-GO: extended->ethereal target_first (Position #6)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Outcome:** Preflight only. **Did NOT arm, did NOT go live.** No orders/signatures, no gates enabled, no
autos touched, no runner start, no deploy/rebuild/push. Production unchanged.

## Purpose (approved)
One supervised extended->ethereal target_first canary to move production venue Extended → Ethereal, using
the freshly deployed fast-fill paths (`EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED=true`,
`ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED=true`).

## Preflight results
Go-conditions that PASSED:
- runner **stopped/inactive**, `pid: null`, `duplicate_runner_process: false`
- current venue **extended**; only active short **extended** (1.816); ethereal 0.0, nado 0.0; open orders zero
- route proofs 5/6; `extended->ethereal` is READY target_first (the route to run); `ethereal->extended` STALE
- `target_first_supported: true`, `expected_final_inside_tolerance: true`, `exposure_stale: false`
- deployed image contains the fast-fill methods (verified read-only earlier)
- no auto-rebalance systemd timers/services active (only the two signer services + apport)

## NO-GO — two hard dry-run blockers (`rehearsal_status: blocked_no_live`, `ready_for_supervised_canary: false`)

### 1. Ethereal target auto cannot be paused by the deployed gates
- `source_target_auto_blockers: ["target venue auto must be disabled during migration canary: ethereal"]`
- `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED = true` (currently enabled).
- The **deployed** gates (`79a7138`) implement only `pause_source_auto!` / `restore_source_auto!` (source
  auto). For extended->ethereal the source auto is EXTENDED (already false → nothing to pause); the TARGET
  ethereal auto is not managed. The both-venue `pause_venue_autos!` / `restore_venue_autos!` /
  `auto_targets` logic is in the **stashed, undeployed** refactor. So `arm` would enable the 3 MIGRATION DB
  gates but would NOT disable the ethereal target auto — the blocker persists after arm, and disarm could
  not restore a target auto it never paused. Risk of leaving the ethereal auto in a bad state → refused.

### 2. Hedge currently marginally outside tolerance
- `current hedge outside tolerance: target_short_eth=1.87317, current_short_eth=1.816, drift_eth=0.05717,
  tolerance_abs_eth=0.05620` → drift (0.05717) > tolerance (0.05620) by ~0.001 ETH.
- The fresh Mellow target rose to 1.8732 vs Extended's 1.816, crossing the tolerance boundary. Dry-run's
  recommended fix is an Extended `increase_short ~0.057` (an order — not part of this canary, not approved).

Approved gating requires `inside_tolerance=true` AND a dry-run with no safety blockers. Both fail →
do not arm, do not go live.

## Options (require separate explicit approval — none taken)
1. Deploy the stashed both-venue gates refactor so `arm` can pause+restore the ethereal target auto
   (requires a rebuild — prohibited this turn).
2. Bring the hedge back inside tolerance first (Extended `increase_short ~0.057`) — a live order needing its
   own approval.
3. Re-check later — the breach is marginal (~0.001 ETH) and may resolve if the target drifts.

## Safety confirmation
Preflight/dry-run only. No live canary, no arm, no gates enabled, no autos paused, no orders/signatures/
cancels, no runner start, no scheduler, no route run, no deploy/rebuild/push, no DB/env/secrets mutation,
thresholds unchanged. Production unchanged: venue extended (1.816), ethereal/nado flat, open orders zero,
runner inactive, gates false, route proofs 5/6.
