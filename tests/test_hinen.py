from __future__ import annotations

import json
import os
import pathlib
import tempfile
import types
import unittest
from unittest import mock

import hinen_local as hinen


class DeviceSanitizationTests(unittest.TestCase):
    def test_as_dict_hides_device_id_and_key(self) -> None:
        device = hinen.TuyaDevice(
            address="192.168.1.50",
            device_id="00112233445566778899",
            product_key="YOURPRODUCTKEY00",
            version="3.4",
            active=2,
            encrypted=True,
        )
        payload = device.as_dict()
        self.assertEqual(payload["address"], "192.168.1.50")
        self.assertEqual(payload["product_key"], "YOURPRODUCTKEY00")
        self.assertEqual(payload["device_id_prefix"], "001122…")
        self.assertNotIn("device_id", payload)
        self.assertNotIn("key", payload)
        self.assertNotIn("00112233445566778899", json.dumps(payload))


class DiscoveryTests(unittest.TestCase):
    def test_discovery_filters_public_addresses_and_sanitizes(self) -> None:
        scanned = {
            "192.168.1.50": {
                "gwId": "00112233445566778899",
                "productKey": "YOURPRODUCTKEY00",
                "version": "3.4",
                "active": 2,
                "encrypt": True,
                "key": "0123456789abcdef",
            },
            "8.8.8.8": {
                "gwId": "public-device",
                "productKey": "public",
                "version": "3.4",
                "active": 1,
                "encrypt": False,
            },
            "192.168.1.51": {
                "productKey": "missing-id",
                "version": "3.3",
            },
        }
        fake = types.SimpleNamespace(deviceScan=lambda **_: scanned)
        with mock.patch.object(hinen, "_require", return_value=fake):
            devices = hinen.discover_tuya(timeout=3)
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0].address, "192.168.1.50")
        self.assertEqual(devices[0].product_key, "YOURPRODUCTKEY00")
        self.assertNotIn("0123456789abcdef", json.dumps(devices[0].as_dict()))


class KeyTests(unittest.TestCase):
    def test_local_key_reads_protected_env_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "hinen.env"
            path.write_text(
                "# comment\nHINEN_LOCAL_KEY=0123456789abcdef\n"
                "HINEN_DEVICE_ID=00112233445566778899\n",
                encoding="utf-8",
            )
            os.chmod(path, 0o600)
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(hinen.load_local_key(path), "0123456789abcdef")
                self.assertEqual(
                    hinen.load_device_id(path), "00112233445566778899"
                )

    def test_local_key_environment_wins(self) -> None:
        with mock.patch.dict(
            os.environ, {"HINEN_LOCAL_KEY": "fedcba9876543210"}, clear=True
        ):
            self.assertEqual(
                hinen.load_local_key(pathlib.Path("/missing")), "fedcba9876543210"
            )

    def test_invalid_local_key_length_is_rejected(self) -> None:
        with mock.patch.dict(
            os.environ, {"HINEN_LOCAL_KEY": "too-short"}, clear=True
        ):
            with self.assertRaises(hinen.HinenError):
                hinen.load_local_key()

    def test_missing_local_key_is_none(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "missing.env"
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertIsNone(hinen.load_local_key(path))


class StatusValidationTests(unittest.TestCase):
    def test_rejects_public_address_before_transport(self) -> None:
        with self.assertRaises(hinen.HinenError):
            hinen.read_tuya_status("8.8.8.8", "0123456789abcdef")

    def test_rejects_short_key_before_transport(self) -> None:
        with self.assertRaises(hinen.HinenError):
            hinen.read_tuya_status("192.168.1.50", "short")

    def test_status_returns_dps_without_exposing_key(self) -> None:
        calls: dict[str, object] = {}

        class FakeDevice:
            def __init__(self, device_id, address, local_key, **kwargs):
                calls["device_id"] = device_id
                calls["address"] = address
                calls["local_key"] = local_key
                calls["kwargs"] = kwargs

            def set_socketTimeout(self, timeout):
                calls["timeout"] = timeout

            def status(self):
                return {"dps": {"1": 74, "2": 31.5}}

            def close(self):
                calls["closed"] = True

        fake = types.SimpleNamespace(Device=FakeDevice)
        with mock.patch.object(hinen, "_require", return_value=fake):
            result = hinen.read_tuya_status(
                "192.168.1.50",
                "0123456789abcdef",
                device_id="00112233445566778899",
            )

        self.assertEqual(result["dps"], {"1": 74, "2": 31.5})
        self.assertNotIn("0123456789abcdef", json.dumps(result))
        self.assertEqual(calls["device_id"], "00112233445566778899")
        self.assertEqual(calls["kwargs"]["version"], 3.4)
        self.assertTrue(calls["closed"])


class LanTests(unittest.TestCase):
    def test_local_ports_include_tuya_lan(self) -> None:
        self.assertIn(6668, hinen.LOCAL_PORTS)

    def test_check_rejects_public_address(self) -> None:
        with self.assertRaises(hinen.HinenError):
            hinen.check_lan("8.8.8.8")


if __name__ == "__main__":
    unittest.main()
