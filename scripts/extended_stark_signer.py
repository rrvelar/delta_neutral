#!/usr/bin/env python3
from __future__ import annotations

import json
import decimal
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from decimal import Decimal
from typing import Any

try:
    from fast_stark_crypto import get_order_msg_hash, sign as stark_sign
except Exception:  # pragma: no cover - exercised on hosts without signer deps
    get_order_msg_hash = None
    stark_sign = None


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
REQUIRED_SIGNING_FIELDS = {
    "vault",
    "starkPublicKey",
    "syntheticAssetId",
    "syntheticResolution",
    "collateralAssetId",
    "collateralResolution",
    "starknetDomain",
}

ROUNDING_SELL_CONTEXT = decimal.Context(rounding=decimal.ROUND_DOWN)
ROUNDING_BUY_CONTEXT = decimal.Context(rounding=decimal.ROUND_UP)
ROUNDING_FEE_CONTEXT = decimal.Context(rounding=decimal.ROUND_UP)


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
    algorithm_enabled = _bool(env.get("EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM"))
    key_file = env.get("EXTENDED_STARK_PRIVATE_KEY_FILE")
    key_available = bool(key_file and Path(key_file).is_file())
    dependencies_available = bool(get_order_msg_hash and stark_sign)
    ok = bool(enabled and key_available and dependencies_available and algorithm_enabled)
    return {
        "ok": ok,
        "mode": "extended_stark_external" if enabled else "disabled",
        "reason": "ok" if ok else "signer disabled, dependency unavailable, algorithm disabled, or Stark key file unavailable",
        "supported_exchanges": ["Extended"] if ok else [],
        "supported_actions": ["sign_extended_order"] if ok else [],
        "stark_public_key": env.get("EXTENDED_STARK_PUBLIC_KEY"),
        "signing_algorithm_verified": dependencies_available,
        "signing_algorithm_enabled": algorithm_enabled,
    }


def sign_extended_order(request: dict[str, Any], env: dict[str, str]) -> dict[str, Any]:
    health = health_payload(env)
    if not health["ok"]:
        return _blocked("signer_disabled", health["reason"])
    shape_error = validate_order_shape(request)
    if shape_error:
        return _blocked("invalid_order", shape_error)
    if get_order_msg_hash is None or stark_sign is None:
        return _blocked("signing_dependency_unavailable", "fast-stark-crypto is not installed for signer process")
    try:
        signed = sign_order_request(request, _read_private_key(env))
    except Exception as exc:
        return _blocked("signing_error", f"Extended Stark signing failed: {exc}")
    return {"status": "signed", **signed}


def sign_order_request(request: dict[str, Any], private_key_hex: str) -> dict[str, Any]:
    if get_order_msg_hash is None or stark_sign is None:
        raise RuntimeError("fast-stark-crypto is not installed")
    order = request["order"]
    amounts = calculate_debugging_amounts(order)
    order_hash = calculate_order_hash(order, amounts)
    r, s = stark_sign(private_key=int(private_key_hex, 16), msg_hash=order_hash)
    return {
        "order_hash": str(order_hash),
        "order_id": str(order_hash),
        "settlement": {
            "signature": {"r": hex(r), "s": hex(s)},
            "starkKey": _hex_int(order["starkPublicKey"]),
            "collateralPosition": str(int(order["vault"])),
        },
        "debuggingAmounts": {
            "collateralAmount": str(amounts["collateral_amount"]),
            "feeAmount": str(amounts["fee_amount"]),
            "syntheticAmount": str(amounts["synthetic_amount"]),
        },
    }


def calculate_order_hash(order: dict[str, Any], amounts: dict[str, int]) -> int:
    domain = order["starknetDomain"]
    return get_order_msg_hash(
        position_id=int(order["vault"]),
        base_asset_id=int(str(order["syntheticAssetId"]), 16),
        base_amount=amounts["synthetic_amount"],
        quote_asset_id=int(str(order["collateralAssetId"]), 16),
        quote_amount=amounts["collateral_amount"],
        fee_amount=amounts["fee_amount"],
        fee_asset_id=int(str(order["collateralAssetId"]), 16),
        expiration=settlement_expiration_seconds(order["expiryEpochMillis"]),
        salt=int(order["nonce"]),
        user_public_key=int(str(order["starkPublicKey"]), 16),
        domain_name=domain["name"],
        domain_version=domain["version"],
        domain_chain_id=domain["chainId"],
        domain_revision=domain["revision"],
    )


def calculate_debugging_amounts(order: dict[str, Any]) -> dict[str, int]:
    side = str(order["side"]).upper()
    rounding_context = ROUNDING_BUY_CONTEXT if side == "BUY" else ROUNDING_SELL_CONTEXT
    synthetic = _to_stark_amount(Decimal(str(order["qty"])), Decimal(str(order["syntheticResolution"])), rounding_context)
    collateral = _to_stark_amount(
        Decimal(str(order["qty"])) * Decimal(str(order["price"])),
        Decimal(str(order["collateralResolution"])),
        rounding_context,
    )
    fee = _to_stark_amount(
        Decimal(str(order["fee"])) * Decimal(str(order["qty"])) * Decimal(str(order["price"])),
        Decimal(str(order["collateralResolution"])),
        ROUNDING_FEE_CONTEXT,
    )
    if side == "BUY":
        collateral = -collateral
    else:
        synthetic = -synthetic
    return {"synthetic_amount": synthetic, "collateral_amount": collateral, "fee_amount": fee}


def settlement_expiration_seconds(expiry_epoch_millis: int | str) -> int:
    # Matches SDK calculate_order_settlement_expiration: order expiry + 14 days, ceil seconds.
    return int((int(expiry_epoch_millis) + 14 * 24 * 60 * 60 * 1000 + 999) // 1000)


def validate_order_shape(request: dict[str, Any]) -> str | None:
    order = request.get("order")
    if not isinstance(order, dict):
        return "order object is required"
    missing = sorted(REQUIRED_ORDER_FIELDS - set(order))
    if missing:
        return f"order missing required fields: {', '.join(missing)}"
    missing_signing = sorted(REQUIRED_SIGNING_FIELDS - set(order))
    if missing_signing:
        return f"order missing required signing fields: {', '.join(missing_signing)}"
    if str(order.get("side")).upper() not in {"BUY", "SELL"}:
        return "order.side must be BUY or SELL"
    if not isinstance(order.get("reduceOnly"), bool):
        return "order.reduceOnly must be boolean"
    return None


def _read_private_key(env: dict[str, str]) -> str:
    key_file = env.get("EXTENDED_STARK_PRIVATE_KEY_FILE")
    if not key_file:
        raise RuntimeError("EXTENDED_STARK_PRIVATE_KEY_FILE is not configured")
    return Path(key_file).read_text(encoding="utf-8").strip()


def _to_stark_amount(value: Decimal, resolution: Decimal, rounding_context: decimal.Context) -> int:
    return int(rounding_context.multiply(value, resolution).to_integral(context=rounding_context))


def _hex_int(value: Any) -> str:
    return hex(int(str(value), 16))


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
