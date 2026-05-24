# Delta Neutral EIP-712 Signer Runbook

Delta Neutral owns its external signer at `scripts/eip712_external_signer.py`.
Do not run the production signer from `/opt/perp-hedge-research-bot`.

The signer is a separate process. Rails sends EIP-712 typed data to it through
`EXECUTION_SIGNER_URL`; Rails must never receive, store, log, or render the raw
private key.

## Install

On the VPS, from `/opt/delta_neutral`:

```bash
python3 -m venv /opt/delta_neutral/signer-venv
/opt/delta_neutral/signer-venv/bin/python -m pip install -U pip setuptools wheel
/opt/delta_neutral/signer-venv/bin/python -m pip install -r /opt/delta_neutral/requirements-eip712-signer.txt
```

## Nado-Only Runtime

Nado is the default and remains supported without enabling Ethereal:

```bash
export EIP712_SIGNER_ENABLED=true
export EIP712_SIGNER_HOST=172.18.0.1
export EIP712_SIGNER_PORT=8766
export EIP712_SIGNER_ALLOWED_EXCHANGES=Nado
export EIP712_SIGNER_ALLOW_ETHEREAL=false
export EIP712_SIGNER_ALLOWED_ACTIONS=place_order,close_order,close_position
export EIP712_SIGNER_PRIVATE_KEY_ENV_NAME=EIP712_SIGNER_PRIVATE_KEY
export EIP712_SIGNER_PRIVATE_KEY="$(cat /etc/delta-neutral/eip712-signer-key)"
/opt/delta_neutral/signer-venv/bin/python /opt/delta_neutral/scripts/eip712_external_signer.py
```

Expected `/health` shape:

```json
{
  "mode": "eip712_external",
  "ok": true,
  "supported_exchanges": ["Nado"],
  "supported_actions": ["close_order", "close_position", "place_order"]
}
```

## Add Ethereal Signer Support

This only allows the external signer to sign Ethereal `TradeOrder` typed data.
It does not enable Ethereal live trading in Rails. Rails live trading still
requires `AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED=true`, exact confirmation, and
all dashboard live gates.

```bash
export EIP712_SIGNER_ALLOW_ETHEREAL=true
```

Expected `/health` shape:

```json
{
  "mode": "eip712_external",
  "ok": true,
  "supported_exchanges": ["Ethereal", "Nado"],
  "supported_actions": ["close_order", "close_position", "place_order"]
}
```

## Health Check

```bash
curl -s http://172.18.0.1:8766/health
```

Nado remains supported when `supported_exchanges` contains `Nado`.
Ethereal Rails preflight remains blocked until `/health` also contains
`Ethereal` and `place_order`.

## Safety

- Do not put `EIP712_SIGNER_PRIVATE_KEY` in `.env`, `.env.production`, Rails
  credentials, deploy config, logs, receipts, or the UI.
- Store the signer key outside the repo, such as
  `/etc/delta-neutral/eip712-signer-key`, owned by root and readable only by the
  signer runtime user.
- Do not start a second signer on the same host/port until the current signer is
  intentionally stopped by the operator.
