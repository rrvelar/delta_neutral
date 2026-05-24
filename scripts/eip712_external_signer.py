#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

try:
    from eth_account import Account
    from eth_account.messages import encode_typed_data
except Exception:  # pragma: no cover - exercised on hosts without signer deps
    Account = None
    encode_typed_data = None


ETHEREAL_DOMAIN = {
    "name": "Ethereal",
    "version": "1",
    "chainId": 5064014,
    "verifyingContract": "0xB3cDC82035C495c484C9fF11eD5f3Ff6d342e3cc",
}

ETHEREAL_TRADE_ORDER_FIELDS = {
    "sender",
    "subaccount",
    "quantity",
    "price",
    "reduceOnly",
    "side",
    "engineType",
    "productId",
    "nonce",
    "signedAt",
}

DEFAULT_ACTIONS = "place_order,close_order,close_position"


class Eip712SignerHandler(BaseHTTPRequestHandler):
    server_version = "DeltaNeutralEip712ExternalSigner/0.1"

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/health":
            self._json(404, {"ok": False, "reason": "not found"})
            return
        self._json(200, health_payload(os.environ))

    def do_POST(self) -> None:  # noqa: N802
        if self.path not in {"/sign/eip712", "/verify/eip712"}:
            self._json(404, {"status": "error", "reason": "not found"})
            return
        payload = self._read_json()
        if payload is None:
            self._json(400, {"status": "error", "error_classification": "invalid_json", "reason": "invalid JSON"})
            return
        if self.path == "/sign/eip712":
            response = sign_eip712_request(payload, os.environ)
            self._json(200 if response.get("status") == "signed" else 400, response)
            return
        response = verify_eip712_signature(
            payload.get("typed_data") or {},
            str(payload.get("signature") or ""),
            payload.get("expected_signer_address"),
        )
        self._json(200 if response.get("ok") else 400, response)

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        return

    def _read_json(self) -> dict[str, Any] | None:
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            return json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except json.JSONDecodeError:
            return None

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def health_payload(env: dict[str, str]) -> dict[str, Any]:
    account = _load_account(env)
    enabled = _bool(env.get("EIP712_SIGNER_ENABLED"))
    ok = bool(enabled and account)
    return {
        "ok": ok,
        "reason": "ok" if ok else "signer disabled or key unavailable",
        "signer_id": env.get("EIP712_SIGNER_ID", "delta-neutral-eip712-external-signer"),
        "mode": "eip712_external" if enabled else "disabled",
        "supported_exchanges": sorted(allowed_exchanges(env)),
        "supported_actions": sorted(allowed_actions(env)),
        "signer_address": account.address if account else None,
    }


def sign_eip712_request(request: dict[str, Any], env: dict[str, str]) -> dict[str, Any]:
    if not _bool(env.get("EIP712_SIGNER_ENABLED")):
        return _blocked("signer_disabled", "EIP712 signer is disabled")
    exchange = str(request.get("exchange") or "")
    action = str(request.get("action") or "")
    if exchange not in allowed_exchanges(env):
        return _blocked("exchange_not_allowed", f"exchange {exchange or '<missing>'} is not allowed")
    if action not in allowed_actions(env):
        return _blocked("action_not_allowed", f"action {action or '<missing>'} is not allowed")
    typed_data = request.get("typed_data")
    if not isinstance(typed_data, dict):
        return _blocked("invalid_request", "typed_data object is required")
    shape_error = validate_typed_data_shape(exchange, typed_data)
    if shape_error:
        return _blocked("invalid_typed_data", shape_error)
    account = _load_account(env)
    if account is None:
        if Account is None or encode_typed_data is None:
            return _blocked("signing_dependency_unavailable", "eth-account is not installed for signer process")
        return _blocked("key_unavailable", f"{private_key_env_name(env)} is not configured for signer process")
    expected = request.get("expected_signer_address")
    if _bool(env.get("EIP712_SIGNER_REQUIRE_EXPECTED_ADDRESS", "true")) and expected and str(expected).lower() != account.address.lower():
        return _blocked("expected_address_mismatch", "expected signer address does not match configured signer")
    forbidden = request.get("forbidden_signer_address")
    if forbidden and str(forbidden).lower() == account.address.lower():
        return _blocked("forbidden_signer_address", "configured signer address is explicitly forbidden")
    try:
        signable = encode_typed_data(full_message=typed_data)
        signed = Account.sign_message(signable, account.key)
        recovered = Account.recover_message(signable, signature=signed.signature)
    except Exception as exc:
        return _blocked("signing_error", f"typed-data signing failed: {exc}")
    return {
        "status": "signed",
        "signer_id": env.get("EIP712_SIGNER_ID", "delta-neutral-eip712-external-signer"),
        "signer_address": account.address,
        "signature": "0x" + signed.signature.hex(),
        "typed_data_hash": request.get("typed_data_hash"),
        "recovered_signer_address": recovered,
    }


def verify_eip712_signature(typed_data: dict[str, Any], signature: str, expected_signer_address: str | None = None) -> dict[str, Any]:
    if Account is None or encode_typed_data is None:
        return {"ok": False, "reason": "eth-account is not installed for signer process", "classification": "signing_dependency_unavailable"}
    try:
        signable = encode_typed_data(full_message=typed_data)
        recovered = Account.recover_message(signable, signature=signature)
    except Exception as exc:
        return {"ok": False, "reason": f"verification failed: {exc}", "classification": "verification_error"}
    ok = expected_signer_address is None or recovered.lower() == expected_signer_address.lower()
    return {
        "ok": ok,
        "recovered_signer_address": recovered,
        "reason": "ok" if ok else "recovered address does not match expected signer",
        "classification": "ok" if ok else "address_mismatch",
    }


def validate_typed_data_shape(exchange: str, typed_data: dict[str, Any]) -> str | None:
    required = {"types", "primaryType", "domain", "message"}
    missing = sorted(required - set(typed_data))
    if missing:
        return f"typed_data missing required fields: {', '.join(missing)}"
    primary = typed_data.get("primaryType")
    if exchange == "Nado" and primary != "Order":
        return "Nado EIP-712 primaryType must be Order"
    if exchange == "Ethereal" and primary != "TradeOrder":
        return "Ethereal EIP-712 primaryType must be TradeOrder"
    if not isinstance(typed_data.get("message"), dict):
        return "typed_data.message must be an object"
    if exchange == "Ethereal":
        return validate_ethereal_trade_order_shape(typed_data)
    return None


def validate_ethereal_trade_order_shape(typed_data: dict[str, Any]) -> str | None:
    domain = typed_data.get("domain")
    if not isinstance(domain, dict):
        return "Ethereal EIP-712 domain must be an object"
    for key, expected in ETHEREAL_DOMAIN.items():
        if str(domain.get(key)) != str(expected):
            return f"Ethereal EIP-712 domain {key} must be {expected}"
    message = typed_data.get("message") or {}
    missing = sorted(ETHEREAL_TRADE_ORDER_FIELDS - set(message))
    if missing:
        return f"Ethereal TradeOrder message missing required fields: {', '.join(missing)}"
    if message.get("side") not in {0, 1, "0", "1"}:
        return "Ethereal TradeOrder side must be 0 or 1"
    if not isinstance(message.get("reduceOnly"), bool):
        return "Ethereal TradeOrder reduceOnly must be boolean"
    return None


def allowed_exchanges(env: dict[str, str]) -> set[str]:
    allowed = _csv(env.get("EIP712_SIGNER_ALLOWED_EXCHANGES") or "Nado")
    if _bool(env.get("EIP712_SIGNER_ALLOW_ETHEREAL")):
        allowed.add("Ethereal")
    else:
        allowed.discard("Ethereal")
    return allowed


def allowed_actions(env: dict[str, str]) -> set[str]:
    return _csv(env.get("EIP712_SIGNER_ALLOWED_ACTIONS") or DEFAULT_ACTIONS)


def private_key_env_name(env: dict[str, str]) -> str:
    return env.get("EIP712_SIGNER_PRIVATE_KEY_ENV_NAME") or "EIP712_SIGNER_PRIVATE_KEY"


def _load_account(env: dict[str, str]):
    if Account is None:
        return None
    raw = env.get(private_key_env_name(env))
    if not raw:
        return None
    try:
        return Account.from_key(raw)
    except Exception:
        return None


def _csv(value: str | None) -> set[str]:
    return {item.strip() for item in (value or "").split(",") if item.strip()}


def _bool(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def _blocked(classification: str, reason: str) -> dict[str, Any]:
    return {"status": "blocked", "error_classification": classification, "reason": reason}


def main() -> None:
    host = os.environ.get("EIP712_SIGNER_HOST", "127.0.0.1")
    port = int(os.environ.get("EIP712_SIGNER_PORT", "8766"))
    server = HTTPServer((host, port), Eip712SignerHandler)
    print(f"Delta Neutral EIP-712 signer listening on http://{host}:{port}; enabled={_bool(os.environ.get('EIP712_SIGNER_ENABLED'))}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Delta Neutral EIP-712 signer stopped")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
