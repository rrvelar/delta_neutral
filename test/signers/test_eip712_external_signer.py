import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[2] / "scripts" / "eip712_external_signer.py"
spec = importlib.util.spec_from_file_location("eip712_external_signer", SCRIPT_PATH)
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


def ethereal_trade_order():
    return {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "TradeOrder": [
                {"name": "sender", "type": "address"},
                {"name": "subaccount", "type": "bytes32"},
                {"name": "quantity", "type": "uint128"},
                {"name": "price", "type": "uint128"},
                {"name": "reduceOnly", "type": "bool"},
                {"name": "side", "type": "uint8"},
                {"name": "engineType", "type": "uint8"},
                {"name": "productId", "type": "uint32"},
                {"name": "nonce", "type": "uint64"},
                {"name": "signedAt", "type": "uint64"},
            ],
        },
        "primaryType": "TradeOrder",
        "domain": signer.ETHEREAL_DOMAIN.copy(),
        "message": {
            "sender": "0x0000000000000000000000000000000000000001",
            "subaccount": "0x7072696d61727900000000000000000000000000000000000000000000000000",
            "quantity": "10000000",
            "price": "2000000000000",
            "reduceOnly": False,
            "side": 1,
            "engineType": 0,
            "productId": 2,
            "nonce": "2687929537462333",
            "signedAt": "1712019600",
        },
    }


class Eip712ExternalSignerTest(unittest.TestCase):
    def test_default_health_is_nado_only(self):
        payload = signer.health_payload({"EIP712_SIGNER_ENABLED": "true"})

        self.assertEqual(["Nado"], payload["supported_exchanges"])
        self.assertNotIn("Ethereal", payload["supported_exchanges"])

    def test_ethereal_hidden_unless_opt_in_flag_true(self):
        env = {"EIP712_SIGNER_ALLOWED_EXCHANGES": "Nado,Ethereal"}
        self.assertEqual({"Nado"}, signer.allowed_exchanges(env))

        env["EIP712_SIGNER_ALLOW_ETHEREAL"] = "true"
        self.assertEqual({"Ethereal", "Nado"}, signer.allowed_exchanges(env))

    def test_private_key_loads_from_env_var_for_backward_compatibility(self):
        key = "0x" + "11" * 32

        self.assertEqual(key, signer.private_key_value({"EIP712_SIGNER_PRIVATE_KEY": key}))

    def test_private_key_file_is_preferred_and_trimmed(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as key_file:
            key_file.write("0x" + "22" * 32 + "\n")
            key_file.flush()

            loaded = signer.private_key_value(
                {
                    "EIP712_SIGNER_PRIVATE_KEY": "0x" + "11" * 32,
                    "EIP712_SIGNER_PRIVATE_KEY_FILE": key_file.name,
                },
            )

        self.assertEqual("0x" + "22" * 32, loaded)

    def test_unreadable_private_key_file_fails_closed_without_env_fallback(self):
        loaded = signer.private_key_value(
            {
                "EIP712_SIGNER_PRIVATE_KEY": "0x" + "11" * 32,
                "EIP712_SIGNER_PRIVATE_KEY_FILE": "/path/that/does/not/exist/eip712.key",
            },
        )

        self.assertIsNone(loaded)

    def test_ethereal_trade_order_blocked_until_opt_in_then_reaches_key_gate(self):
        request = {"exchange": "Ethereal", "action": "place_order", "typed_data": ethereal_trade_order()}
        blocked = signer.sign_eip712_request(request, {"EIP712_SIGNER_ENABLED": "true"})
        allowed = signer.sign_eip712_request(
            request,
            {"EIP712_SIGNER_ENABLED": "true", "EIP712_SIGNER_ALLOW_ETHEREAL": "true"},
        )

        self.assertEqual("blocked", blocked["status"])
        self.assertEqual("exchange_not_allowed", blocked["error_classification"])
        self.assertEqual("blocked", allowed["status"])
        self.assertIn(allowed["error_classification"], {"key_unavailable", "signing_dependency_unavailable"})

    def test_malformed_ethereal_trade_order_rejected(self):
        typed_data = ethereal_trade_order()
        typed_data["domain"]["chainId"] = 1

        response = signer.sign_eip712_request(
            {"exchange": "Ethereal", "action": "place_order", "typed_data": typed_data},
            {"EIP712_SIGNER_ENABLED": "true", "EIP712_SIGNER_ALLOW_ETHEREAL": "true"},
        )

        self.assertEqual("blocked", response["status"])
        self.assertEqual("invalid_typed_data", response["error_classification"])
        self.assertIn("chainId", response["reason"])

    def test_invalid_exchange_and_action_blocked_without_secret_echo(self):
        response = signer.sign_eip712_request(
            {"exchange": "Extended", "action": "withdraw", "typed_data": ethereal_trade_order()},
            {
                "EIP712_SIGNER_ENABLED": "true",
                "EIP712_SIGNER_PRIVATE_KEY": "0x" + "11" * 32,
            },
        )

        self.assertEqual("blocked", response["status"])
        self.assertEqual("exchange_not_allowed", response["error_classification"])
        self.assertNotIn("11" * 32, str(response))

    def test_missing_key_fails_closed_without_secret_echo(self):
        response = signer.sign_eip712_request(
            {
                "exchange": "Nado",
                "action": "place_order",
                "typed_data": {"types": {}, "primaryType": "Order", "domain": {}, "message": {}},
            },
            {
                "EIP712_SIGNER_ENABLED": "true",
                "EIP712_SIGNER_PRIVATE_KEY_FILE": "/path/that/does/not/exist/eip712.key",
            },
        )

        self.assertEqual("blocked", response["status"])
        self.assertIn(response["error_classification"], {"key_unavailable", "signing_dependency_unavailable"})
        self.assertNotIn("EIP712_SIGNER_PRIVATE_KEY", str(response))
        self.assertNotIn("/path/that/does/not/exist", str(response))


if __name__ == "__main__":
    unittest.main()
