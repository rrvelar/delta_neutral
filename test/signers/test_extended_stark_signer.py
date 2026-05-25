import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "extended_stark_signer.py"
spec = importlib.util.spec_from_file_location("extended_stark_signer", SCRIPT)
extended_stark_signer = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(extended_stark_signer)


SDK_MARKET_SELL_VECTOR = {
    "private_key": "0x7a7ff6fd3cab02ccdcd4a572563f5976f8976899b03a39773795a3c486d4986",
    "order": {
        "market": "BTC-USD",
        "type": "MARKET",
        "side": "SELL",
        "qty": "0.00100000",
        "price": "49625.0",
        "reduceOnly": False,
        "timeInForce": "IOC",
        "expiryEpochMillis": 1705626536861,
        "fee": "0.0005",
        "nonce": "1473459052",
        "vault": 10002,
        "starkPublicKey": "0x61c5e7e8339b7d56f197f54ea91b776776690e3232313de0f2ecbd0ef76f466",
        "syntheticAssetId": "0x4254432d3600000000000000000000",
        "syntheticResolution": 1000000,
        "collateralAssetId": "0x31857064564ed0ff978e687456963cba09c2c6985d8f9300a1de4962fafa054",
        "collateralResolution": 1000000,
        "starknetDomain": {
            "name": "Perpetuals",
            "version": "v0",
            "chainId": "SN_SEPOLIA",
            "revision": "1",
        },
    },
    "expected": {
        "order_id": "2580220688642480426946040763258220762106230673118492731878319591751617419967",
        "r": "0x28af719b8c9619fadd151a0f9c269058b3240ae2e08ab14e6fa15b8ea081dc6",
        "s": "0x78c518768fe71c8583aee78e756de66ffed2170171fec10da03edc5e9a3d241",
        "collateral_amount": "49625000",
        "fee_amount": "24813",
        "synthetic_amount": "-1000",
    },
}


class ExtendedStarkSignerTest(unittest.TestCase):
    def test_disabled_health_does_not_advertise_support(self):
        payload = extended_stark_signer.health_payload({})

        self.assertFalse(payload["ok"])
        self.assertEqual("delta-neutral-extended-stark-signer", payload["signer_id"])
        self.assertEqual([], payload["supported_exchanges"])
        self.assertEqual([], payload["supported_actions"])
        self.assertFalse(payload["verified_algorithm"])
        self.assertFalse(payload["signing_enabled"])

    def test_health_with_algorithm_flag_false_reports_unverified(self):
        with tempfile.NamedTemporaryFile("w") as key_file:
            key_file.write(SDK_MARKET_SELL_VECTOR["private_key"])
            key_file.flush()
            payload = extended_stark_signer.health_payload(
                {
                    "EXTENDED_SIGNER_ENABLED": "true",
                    "EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM": "false",
                    "EXTENDED_STARK_PRIVATE_KEY_FILE": key_file.name,
                    "EXTENDED_STARK_PUBLIC_KEY": SDK_MARKET_SELL_VECTOR["order"]["starkPublicKey"],
                }
            )

        self.assertFalse(payload["ok"])
        self.assertFalse(payload["verified_algorithm"])
        self.assertFalse(payload["signing_enabled"])
        self.assertEqual([], payload["supported_exchanges"])
        self.assertNotIn(SDK_MARKET_SELL_VECTOR["order"]["starkPublicKey"], str(payload))

    def test_health_with_verified_flag_and_dummy_key_advertises_support(self):
        if extended_stark_signer.get_order_msg_hash is None or extended_stark_signer.stark_sign is None:
            self.skipTest("fast-stark-crypto is not installed")
        with tempfile.NamedTemporaryFile("w") as key_file:
            key_file.write(SDK_MARKET_SELL_VECTOR["private_key"])
            key_file.flush()
            payload = extended_stark_signer.health_payload(
                {
                    "EXTENDED_SIGNER_ENABLED": "true",
                    "EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM": "true",
                    "EXTENDED_STARK_PRIVATE_KEY_FILE": key_file.name,
                    "EXTENDED_STARK_PUBLIC_KEY": SDK_MARKET_SELL_VECTOR["order"]["starkPublicKey"],
                }
            )

        self.assertTrue(payload["ok"])
        self.assertTrue(payload["verified_algorithm"])
        self.assertTrue(payload["signing_enabled"])
        self.assertEqual(["Extended"], payload["supported_exchanges"])
        self.assertEqual(["sign_extended_order"], payload["supported_actions"])
        self.assertEqual("0x61c5e7e8...ef76f466", payload["stark_public_key"])

    def test_validate_order_requires_signing_fields(self):
        error = extended_stark_signer.validate_order_shape({"order": {"market": "BTC-USD"}})

        self.assertIn("order missing required fields", error)

    def test_sdk_market_sell_vector_matches_order_hash_signature_and_amounts(self):
        if extended_stark_signer.get_order_msg_hash is None or extended_stark_signer.stark_sign is None:
            self.skipTest("fast-stark-crypto is not installed")
        vector = SDK_MARKET_SELL_VECTOR
        with tempfile.NamedTemporaryFile("w") as key_file:
            key_file.write(vector["private_key"])
            key_file.flush()
            result = extended_stark_signer.sign_extended_order(
                {"order": vector["order"]},
                {
                    "EXTENDED_SIGNER_ENABLED": "true",
                    "EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM": "true",
                    "EXTENDED_STARK_PRIVATE_KEY_FILE": key_file.name,
                    "EXTENDED_STARK_PUBLIC_KEY": vector["order"]["starkPublicKey"],
                },
            )

        expected = vector["expected"]
        self.assertEqual("signed", result["status"])
        self.assertEqual(expected["order_id"], result["order_id"])
        self.assertEqual(expected["r"], result["settlement"]["signature"]["r"])
        self.assertEqual(expected["s"], result["settlement"]["signature"]["s"])
        self.assertEqual(expected["collateral_amount"], result["debuggingAmounts"]["collateralAmount"])
        self.assertEqual(expected["fee_amount"], result["debuggingAmounts"]["feeAmount"])
        self.assertEqual(expected["synthetic_amount"], result["debuggingAmounts"]["syntheticAmount"])


if __name__ == "__main__":
    unittest.main()
