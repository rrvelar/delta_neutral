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
```

## systemd

Example 24 hour canary unit:

```ini
[Unit]
Description=Delta Neutral Random Production Runner Position 6
After=docker.service
Requires=docker.service

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

Install and inspect:

```bash
systemctl daemon-reload
systemctl enable delta-neutral-random-production-6.service
systemctl start delta-neutral-random-production-6.service
systemctl status delta-neutral-random-production-6.service
journalctl -u delta-neutral-random-production-6.service -f
```

For indefinite production, remove `duration_minutes=1440` or set `duration_minutes=0` after the 24 hour canary passes.
