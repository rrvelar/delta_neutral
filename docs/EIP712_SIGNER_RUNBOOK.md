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
export EIP712_SIGNER_PRIVATE_KEY_FILE=/etc/delta-neutral/keys/eip712-signer.key
/opt/delta_neutral/signer-venv/bin/python /opt/delta_neutral/scripts/eip712_external_signer.py
```

If both `EIP712_SIGNER_PRIVATE_KEY_FILE` and `EIP712_SIGNER_PRIVATE_KEY` are
set, the signer reads the key file and ignores the raw environment value. If the
configured key file cannot be read, the signer fails closed instead of falling
back to the raw environment value.

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

## Move Existing Signer Key to a Root-Only File

Run these steps on the VPS as the operator. They update files under `/etc`; do
not put the key in the Rails repo, `.env`, `.env.production`, credentials,
deploy config, logs, or receipts.

```bash
sudo install -d -o root -g root -m 700 /etc/delta-neutral/keys
sudo sh -c 'umask 177; cat > /etc/delta-neutral/keys/eip712-signer.key'
# Paste the existing signer private key, then press Ctrl-D.
sudo chown root:root /etc/delta-neutral/keys/eip712-signer.key
sudo chmod 600 /etc/delta-neutral/keys/eip712-signer.key
sudo sed -i.bak '/^EIP712_SIGNER_PRIVATE_KEY=/d' /etc/delta-neutral/eip712-signer.env
sudo systemctl daemon-reload
sudo systemctl restart delta-neutral-eip712-signer
curl -s http://172.18.0.1:8766/health
```

Verify that `/health` returns the expected `signer_address` and still includes
`Nado` in `supported_exchanges`.

## Stronger Future Systemd Credential Option

On hosts with suitable systemd support, `LoadCredential=` or
`LoadCredentialEncrypted=` can provide a stronger key delivery mechanism. That
is optional; the current production template uses a root-owned key file because
it is simple, auditable, and does not expose the raw key through an environment
variable.

## Safety

- Do not put `EIP712_SIGNER_PRIVATE_KEY` in `.env`, `.env.production`, Rails
  credentials, deploy config, logs, receipts, or the UI.
- Store the signer key outside the repo, preferably at
  `/etc/delta-neutral/keys/eip712-signer.key`, owned by `root:root` with mode
  `600`.
- Do not start a second signer on the same host/port until the current signer is
  intentionally stopped by the operator.
