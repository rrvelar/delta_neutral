# Random Production Runner

The production random runner is a thin wrapper around the proven `MigrationRandomBurnInRunner` path. It uses direct preflight, `READY_FOR_RANDOM` route proofs, active-venue one-shot rebalance hooks, migration execution, hold monitoring, bounded readback/recheck, final direct safety readback, and gate disable-on-exit behavior.

## Commands

24 hour canary:

```bash
bin/rails migration:random_production_runner \
  position_id=6 \
  live=true \
  interval_seconds=3900 \
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

The dashboard 24/7 button writes `mode=production_24x7`. The stop button first writes `stop_position_6.json` through the existing production runner stop path, then writes a bridge stop request. The bridge stops both the canary and production services so either active mode receives the safe stop.

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

[Service]
Type=simple
WorkingDirectory=/opt/delta_neutral
ExecStart=/usr/bin/bash -lc 'cd /opt/delta_neutral && docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:random_production_runner position_id=6 live=true interval_seconds=3900 rebalance_hold_interval_seconds=300 duration_minutes=1440 confirmation=I_UNDERSTAND_THIS_RUNS_PRODUCTION_RANDOM_ROTATION'
ExecStop=/usr/bin/bash -lc 'cd /opt/delta_neutral && docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:random_production_stop position_id=6'
Restart=on-failure
RestartSec=60
StartLimitIntervalSec=3600
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
```

For indefinite production, remove `duration_minutes=1440` or set `duration_minutes=0` after the 24 hour canary passes.
