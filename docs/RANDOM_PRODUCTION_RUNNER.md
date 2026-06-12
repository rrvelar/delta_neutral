# Random Production Runner

The production random runner is a thin wrapper around the proven `MigrationRandomBurnInRunner` path. It uses direct preflight, `READY_FOR_RANDOM` route proofs, active-venue one-shot rebalance hooks, migration execution, hold monitoring, bounded readback/recheck, final direct safety readback, and gate disable-on-exit behavior.

## Commands

24 hour canary:

```bash
bin/rails migration:random_production_runner \
  position_id=6 \
  live=true \
  interval_seconds=28800 \
  rebalance_hold_interval_seconds=300 \
  duration_minutes=1440 \
  confirmation=I_UNDERSTAND_THIS_RUNS_PRODUCTION_RANDOM_ROTATION
```

Indefinite production mode after the canary passes:

```bash
bin/rails migration:random_production_runner \
  position_id=6 \
  live=true \
  confirmation=I_UNDERSTAND_THIS_RUNS_PRODUCTION_RANDOM_ROTATION
```

Status, tail, and stop:

```bash
bin/rails migration:random_production_status position_id=6
bin/rails migration:random_production_tail position_id=6 lines=300
bin/rails migration:random_production_stop position_id=6
```

Production defaults are `interval_seconds=28800` and `rebalance_hold_interval_seconds=300`, which gives three migrations per day with five-minute active-venue checks during each hold. A 24 hour canary uses `duration_minutes=1440`, so it should attempt about three migration cycles. Indefinite production uses `duration_minutes=0`.

Runtime files are written under `storage/random_rotation_production/`:

```text
latest_position_6.jsonl
heartbeat_position_6.json
status_position_6.json
lock_position_6.json
stop_position_6.json
control_position_6.json
control_result_position_6.json
```

## systemd

Rails usually runs inside Docker and cannot call host `systemctl`. Dashboard start/stop controls therefore write `storage/random_rotation_production/control_position_6.json`. The host watches that file with a systemd path unit and runs `bin/random_production_systemd_bridge`, which executes host systemd and writes `control_result_position_6.json`.

Install the host units:

```bash
cd /opt/delta_neutral
sudo cp docs/systemd/delta-neutral-random-production-6.service /etc/systemd/system/
sudo cp docs/systemd/delta-neutral-random-production-6-canary.service /etc/systemd/system/
sudo cp docs/systemd/delta-neutral-random-production-control-6.service /etc/systemd/system/
sudo cp docs/systemd/delta-neutral-random-production-control-6.path /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable delta-neutral-random-production-control-6.path
sudo systemctl start delta-neutral-random-production-control-6.path
sudo systemctl status delta-neutral-random-production-control-6.path
```

Inspect bridge handling and runner logs:

```bash
sudo systemctl status delta-neutral-random-production-control-6.service
sudo systemctl status delta-neutral-random-production-6-canary.service
sudo systemctl status delta-neutral-random-production-6.service
sudo journalctl -u delta-neutral-random-production-control-6.service -f
sudo journalctl -u delta-neutral-random-production-6-canary.service -f
sudo journalctl -u delta-neutral-random-production-6.service -f
```

The dashboard canary button writes:

```json
{
  "action": "start",
  "mode": "canary_24h",
  "position_id": 6,
  "confirmation_present": true
}
```

The dashboard 24/7 button writes `mode=production_24x7`. The stop button first writes `stop_position_6.json` through the existing production runner stop path, then writes a bridge stop request. The bridge also writes the stop request itself, stops both the canary and production services, and runs `systemctl reset-failed` for both so an intentional stop does not resurrect the runner.

`bin/random_production_systemd_bridge` is host-safe: it uses bash and `python3` only. It does not require host Ruby.

The host unit files live in `docs/systemd/`:

```text
delta-neutral-random-production-6-canary.service
delta-neutral-random-production-6.service
delta-neutral-random-production-control-6.path
delta-neutral-random-production-control-6.service
```

Reference 24 hour canary unit:

```ini
[Unit]
Description=Delta Neutral Random Production Runner Position 6 24h Canary
After=docker.service
Requires=docker.service
Conflicts=delta-neutral-random-production-6.service
StartLimitIntervalSec=3600
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=/opt/delta_neutral
ExecStart=/usr/bin/bash -lc 'cd /opt/delta_neutral && docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:random_production_runner position_id=6 live=true interval_seconds=28800 rebalance_hold_interval_seconds=300 duration_minutes=1440 confirmation=I_UNDERSTAND_THIS_RUNS_PRODUCTION_RANDOM_ROTATION'
ExecStop=/usr/bin/bash -lc 'cd /opt/delta_neutral && docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:random_production_stop position_id=6'
Restart=on-failure
RestartSec=60
SuccessExitStatus=0 130 143
RestartPreventExitStatus=0 130 143

[Install]
WantedBy=multi-user.target
```

For indefinite production, remove `duration_minutes=1440` or set `duration_minutes=0` after the 24 hour canary passes.

## Extra Venue Recovery

Production start refuses multiple venue exposure. Do not let the production runner auto-recover this state.

For the incident class where the app production venue is Ethereal and Extended is the extra source exposure, run dry-run first:

```bash
bin/rails migration:recover_target_first_source_close \
  position_id=6 \
  from=extended \
  to=ethereal \
  dry_run=true
```

If dry-run proves it will close Extended only and preserve Ethereal, run the live recovery with the task confirmation required by `MigrationTargetFirstSourceRecovery`:

```bash
bin/rails migration:recover_target_first_source_close \
  position_id=6 \
  from=extended \
  to=ethereal \
  live=true \
  dry_run=false \
  confirmation=I_UNDERSTAND_THIS_CLOSES_SOURCE_AFTER_TARGET_CONFIRMED
```

After recovery, verify direct open orders are zero, Extended is flat, only Ethereal has short exposure, combined short is inside tolerance, and all migration gates are disabled.
