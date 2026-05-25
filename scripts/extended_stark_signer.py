#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any


REQUIRED_ORDER_FIELDS = {
    "market",
    "side",
    "qty",
    "price",
    "reduceOnly",
    "timeInForce",
    "expiryEpochMillis",
    "fee",
    "nonce",
}


class ExtendedStarkSignerHandler(BaseHTTPRequestHandler):
    server_version = "DeltaNeutralExtendedStarkSigner/0.1"

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/health":
            self._json(404, {"ok": False, "reason": "not found"})
            return
        self._json(200, health_payload(os.environ))

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/sign/extended_order":
            self._json(404, {"status": "error", "reason": "not found"})
            return
        payload = self._read_json()
        if payload is None:
            self._json(400, {"status": "error", "classification": "invalid_json", "reason": "invalid JSON"})
            return
        response = sign_extended_order(payload, os.environ)
        self._json(200 if response.get("status") == "signed" else 400, response)

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
    enabled = _bool(env.get("EXTENDED_SIGNER_ENABLED"))
    key_file = env.get("EXTENDED_STARK_PRIVATE_KEY_FILE")
    key_available = bool(key_file and Path(key_file).is_file())
    ok = bool(enabled and key_available)
    return {
        "ok": ok,
        "mode": "extended_stark_external" if enabled else "disabled",
        "reason": "ok" if ok else "signer disabled or Stark key file unavailable",
        "supported_exchanges": ["Extended"] if ok else [],
        "supported_actions": ["sign_extended_order"] if ok else [],
        "stark_public_key": env.get("EXTENDED_STARK_PUBLIC_KEY"),
        "signing_algorithm_verified": False,
    }


def sign_extended_order(request: dict[str, Any], env: dict[str, str]) -> dict[str, Any]:
    health = health_payload(env)
    if not health["ok"]:
        return _blocked("signer_disabled", health["reason"])
    shape_error = validate_order_shape(request)
    if shape_error:
        return _blocked("invalid_order", shape_error)
    return _blocked(
        "signing_algorithm_not_verified",
        "Extended Stark order hash/signature algorithm is not verified in delta_neutral; refuse signing.",
    )


def validate_order_shape(request: dict[str, Any]) -> str | None:
    order = request.get("order")
    if not isinstance(order, dict):
        return "order object is required"
    missing = sorted(REQUIRED_ORDER_FIELDS - set(order))
    if missing:
        return f"order missing required fields: {', '.join(missing)}"
    if str(order.get("side")).upper() not in {"BUY", "SELL"}:
        return "order.side must be BUY or SELL"
    if not isinstance(order.get("reduceOnly"), bool):
        return "order.reduceOnly must be boolean"
    return None


def _blocked(classification: str, reason: str) -> dict[str, Any]:
    return {"status": "blocked", "classification": classification, "reason": reason}


def _bool(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def main() -> None:
    host = os.environ.get("EXTENDED_SIGNER_HOST", "127.0.0.1")
    port = int(os.environ.get("EXTENDED_SIGNER_PORT", "8776"))
    HTTPServer((host, port), ExtendedStarkSignerHandler).serve_forever()


if __name__ == "__main__":
    main()
