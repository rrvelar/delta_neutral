# BACKLOG: executor auto-restore gap after defensive recovery (found 2026-07-11)

**Defect:** during a random-production cycle, the executor's defensive path
`apply_target_open_source_still_open_manual_action!` pauses the venue autos
(audit reason "migration executor pauses after target-open source-still-open
manual action"). When the situation subsequently reconciles safe
(`blocker_status: recovered_after_direct_market_safe_preflight`), the paused
auto is **not restored**.

**Observed impact (cycle 2, 2026-07-11):** at 12:40:42 finalization enabled
`AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` (false→true) and the defensive pause
immediately set it true→false; recovery completed but the flag stayed false. At
15:14 the hold check went out of tolerance; the runner's one-shot hold rebalance
was blocked by exactly that flag ("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED
must be true") and the runner stopped cleanly. The position then drifted to
−0.072 vs tolerance 0.048 until an operator repair (audit id 2495 restore +
`ethereal:auto_rebalance_once live=true`, order `5ec77f85-358c-4868-b194-63779e4f4c6a`)
returned it to 1.6076 inside tolerance.

**Fix direction:** when the manual-action state reconciles safe (the
`recovered_after_direct_market_safe_preflight` path, and/or the stale-action
reconciler), restore any venue autos the defensive path paused — mirroring how
`disarm_manual_canary_gates` restores paused autos. Add a runner/executor test:
defensive pause + safe recovery ⇒ active-venue auto restored; unresolved
manual-action state ⇒ auto stays paused (fail-closed).

**Related, same family:** frozen-proof `unsafe_gates_left_enabled` fix
(`d024ca0`), finalization-flag propagation (`8c0cf5b`). Also still pending from
the 2026-07-11 dashboard audit: server-side runner-active blockers for manual
live endpoints; venue gate checks in `AerodromeDashboardHedgeAction` for
nado/ethereal/extended; "Stop Safely" semantics + confirmation.

---
**IMPLEMENTED 2026-07-11** (see commit): defensive pauses now record
`defensively_paused_venue_autos` in the receipt; the burn-in runner restores the
active venue's auto (via `ActiveVenueAutoPolicy#enable_current!`, audited reason
"restore venue auto after defensive recovery reconciled safe") at the cycle-success
and hold-rebalance-recovery points, gated on `direct_market_safe?` plus live/venue-match/
already-enabled guards. Shutdown (`disable_after`) intentionally still quiesces all
autos — the fail-closed exit posture is preserved.
