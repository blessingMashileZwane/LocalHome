from __future__ import annotations

import hashlib
import json
import struct
import unittest

import miio_airpurifier as miio

TOKEN_HEX = "00112233445566778899aabbccddeeff"
TOKEN = bytes.fromhex(TOKEN_HEX)
DEVICE_ID = bytes.fromhex("01020304")
STAMP = 0x11223344


def encode_response(
    payload: dict,
    *,
    token: bytes = TOKEN,
    checksum_ok: bool = True,
) -> bytes:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\x00"
    encrypted = miio._encrypt(body, token)
    header = miio._header(len(encrypted) + 32, DEVICE_ID, STAMP)
    checksum = hashlib.md5(header + token + encrypted).digest()
    if not checksum_ok:
        checksum = b"\x00" * 16
    return header + checksum + encrypted


def hello_response() -> bytes:
    return miio._header(32, DEVICE_ID, STAMP) + b"\x00" * 16


def decode_request(packet: bytes) -> dict:
    _, _, payload = miio.parse_response(packet, TOKEN)
    assert isinstance(payload, dict)
    return payload


class FakeTransport:
    def __init__(self, handler):
        self.handler = handler
        self.packets: list[bytes] = []

    def __call__(self, packet: bytes, timeout: float) -> bytes:
        self.packets.append(packet)
        return self.handler(packet)


def device_handler(
    *,
    model: str = "zhimi.airp.mb5a",
    values: dict[tuple[int, int], tuple[int, object]] | None = None,
    set_effect: bool = True,
    action_effect: bool = True,
    action_timeout: bool = False,
):
    state = dict(values or {})
    calls = {"get": 0, "set": [], "action": 0}

    def handler(packet: bytes) -> bytes:
        if packet == miio.HELLO_PACKET:
            return hello_response()
        payload = decode_request(packet)
        method = payload["method"]
        if method == "miIO.info":
            return encode_response(
                {
                    "id": payload["id"],
                    "result": {
                        "model": model,
                        "fw_ver": "1.2.3",
                        "hw_ver": "4.0",
                        "mac": "AA:BB:CC:DD:EE:FF",
                        "token": TOKEN_HEX,
                    },
                }
            )
        if method == "get_properties":
            calls["get"] += 1
            result = []
            for item in payload["params"]:
                key = (item["siid"], item["piid"])
                entry = {
                    "did": item["did"],
                    "siid": item["siid"],
                    "piid": item["piid"],
                }
                if key in state:
                    code, value = state[key]
                    entry["code"] = code
                    if code == 0:
                        entry["value"] = value
                else:
                    entry["code"] = -4001
                result.append(entry)
            return encode_response({"id": payload["id"], "result": result})
        if method == "set_properties":
            calls["set"].append(payload["params"])
            result = []
            for item in payload["params"]:
                result.append(
                    {
                        "did": item["did"],
                        "siid": item["siid"],
                        "piid": item["piid"],
                        "code": 0,
                    }
                )
                if set_effect:
                    state[(item["siid"], item["piid"])] = (0, item["value"])
            return encode_response({"id": payload["id"], "result": result})
        if method == "action":
            calls["action"] += 1
            if action_timeout:
                raise miio.MiiOTimeoutError("simulated timeout")
            if action_effect:
                state[(4, 3)] = (0, 0)
            return encode_response(
                {"id": payload["id"], "result": {"did": "call-4-1", "code": 0}}
            )
        return encode_response(
            {"id": payload["id"], "error": {"code": -1}}
        )

    return handler, calls, state


def make_client(
    handler,
    *,
    address: str = "192.168.1.50",
    readback_timeout: float = 3.0,
) -> miio.MiioClient:
    return miio.MiioClient(
        address,
        TOKEN_HEX,
        transport=FakeTransport(handler),
        readback_timeout=readback_timeout,
    )


class TokenTests(unittest.TestCase):
    def test_accepts_hex_and_raw_tokens(self) -> None:
        self.assertEqual(miio.parse_token(TOKEN_HEX), TOKEN)
        self.assertEqual(miio.parse_token(TOKEN), TOKEN)

    def test_rejects_bad_tokens(self) -> None:
        for bad in ("00" * 15, "00" * 17, "zz" * 16, "", "0011"):
            with self.subTest(value=bad):
                with self.assertRaises(miio.MiiOError):
                    miio.parse_token(bad)


class PacketTests(unittest.TestCase):
    def test_hello_is_the_reference_packet(self) -> None:
        self.assertEqual(miio.build_hello().hex(), "21310020" + "ff" * 28)
        self.assertEqual(len(miio.build_hello()), 32)

    def test_request_round_trip(self) -> None:
        payload = {
            "id": 7,
            "method": "get_properties",
            "params": [{"did": "power", "siid": 2, "piid": 1}],
        }
        packet = miio.build_request(payload, TOKEN, DEVICE_ID, 1234)
        magic, length = struct.unpack(">HH", packet[:4])
        self.assertEqual(magic, 0x2131)
        self.assertEqual(length, len(packet))

        device_id, stamp, decoded = miio.parse_response(packet, TOKEN)
        self.assertEqual(device_id, DEVICE_ID)
        self.assertEqual(stamp, 1234)
        self.assertEqual(decoded, payload)

    def test_corrupt_checksum_is_rejected(self) -> None:
        packet = bytearray(
            miio.build_request({"id": 1, "method": "miIO.info", "params": []},
                               TOKEN, DEVICE_ID, 1)
        )
        packet[16] ^= 0xFF
        with self.assertRaises(miio.MiiOAuthError):
            miio.parse_response(bytes(packet), TOKEN)

    def test_wrong_token_is_rejected(self) -> None:
        packet = miio.build_request(
            {"id": 1, "method": "miIO.info", "params": []},
            TOKEN,
            DEVICE_ID,
            1,
        )
        with self.assertRaises(miio.MiiOAuthError):
            miio.parse_response(packet, b"\x00" * 16)

    def test_invalid_length_is_rejected(self) -> None:
        packet = miio.build_request(
            {"id": 1, "method": "miIO.info", "params": []},
            TOKEN,
            DEVICE_ID,
            1,
        )
        with self.assertRaises(miio.MiiOError):
            miio.parse_response(packet[:-1], TOKEN)


class ClientValidationTests(unittest.TestCase):
    def test_rejects_non_private_addresses(self) -> None:
        for address in ("8.8.8.8", "127.0.0.1", "camera.local", "::1"):
            with self.subTest(address=address):
                with self.assertRaises(miio.MiiOError):
                    miio.MiioClient(address, TOKEN_HEX)

    def test_sweep_rejects_public_or_wide_networks(self) -> None:
        for network in (
            "8.8.8.0/24",
            "192.168.0.0/16",
            "not-a-cidr",
            "::1/128",
        ):
            with self.subTest(network=network):
                with self.assertRaises(miio.MiiOError):
                    miio.discover_hosts(network, timeout=1)

    def test_connect_hides_token_and_mac(self) -> None:
        handler, calls, _ = device_handler()
        client = make_client(handler)
        info = client.connect()
        self.assertEqual(info.model, "zhimi.airp.mb5a")
        self.assertEqual(info.firmware, "1.2.3")
        self.assertEqual(info.hardware, "4.0")
        self.assertEqual(
            set(info.as_dict()),
            {"address", "model", "firmware", "hardware"},
        )
        self.assertNotIn(TOKEN_HEX, json.dumps(info.as_dict()))
        self.assertNotIn("AA:BB", json.dumps(info.as_dict()))
        self.assertEqual(calls["get"], 0)


class StatusTests(unittest.TestCase):
    def test_reads_mb5a_values_and_chunks_requests(self) -> None:
        handler, calls, _ = device_handler(
            values={
                (2, 1): (0, True),
                (2, 4): (0, 2),
                (2, 5): (0, 3),
                (3, 1): (0, 45),
                (3, 4): (0, 18.0),
                (3, 7): (0, 22.3),
                (4, 1): (0, 80),
                (6, 1): (0, False),
                (13, 2): (0, 2),
            }
        )
        client = make_client(handler)
        client.connect()
        status = client.read_status()

        self.assertEqual(status.values["power"], True)
        self.assertEqual(status.values["mode"], 2)
        self.assertEqual(status.values["fan_level"], 3)
        self.assertEqual(status.values["humidity"], 45)
        self.assertEqual(status.values["pm25"], 18.0)
        self.assertEqual(status.values["temperature"], 22.3)
        self.assertEqual(status.values["filter_life"], 80)
        self.assertIn("anion", status.unsupported)
        self.assertNotIn("pm10", status.values)
        self.assertGreaterEqual(calls["get"], 2)

    def test_vb4_reads_pm10_and_air_quality(self) -> None:
        handler, _, _ = device_handler(
            model="zhimi.airp.vb4",
            values={
                (2, 1): (0, True),
                (3, 8): (0, 12.0),
                (3, 9): (0, 1),
                (9, 5): (0, 4),
            },
        )
        client = make_client(handler)
        client.connect()
        status = client.read_status()
        self.assertEqual(status.values["pm10"], 12.0)
        self.assertEqual(status.values["air_quality"], 1)
        self.assertEqual(status.values["favorite_level"], 4)

    def test_vb4_favorite_level_falls_back_to_15_1(self) -> None:
        handler, _, _ = device_handler(
            model="zhimi.airp.vb4",
            values={(2, 1): (0, True), (15, 1): (0, 7)},
        )
        client = make_client(handler)
        client.connect()
        first = client.read_status()
        self.assertEqual(first.values["favorite_level"], 7)
        self.assertNotIn("favorite_level", first.unsupported)

        second = client.read_status()
        self.assertEqual(second.values["favorite_level"], 7)

    def test_unknown_model_reports_identity_only(self) -> None:
        handler, calls, _ = device_handler(
            model="zhimi.unknown.test",
            values={(2, 1): (0, True)},
        )
        client = make_client(handler)
        client.connect()
        status = client.read_status()
        self.assertEqual(status.info.model, "zhimi.unknown.test")
        self.assertEqual(status.values, {})
        self.assertEqual(status.unsupported, [])
        self.assertEqual(calls["get"], 0)
        with self.assertRaises(miio.MiiOError):
            client.set_property("power", False)
        self.assertEqual(calls["set"], [])

    def test_cpa4_reads_compact_values(self) -> None:
        handler, _, _ = device_handler(
            model="xiaomi.airp.cpa4",
            values={
                (2, 1): (0, False),
                (2, 4): (0, 0),
                (3, 4): (0, 97),
                (4, 1): (0, 100),
                (4, 3): (0, 63),
                (4, 4): (0, 289),
                (6, 1): (0, True),
                (8, 1): (0, False),
                (9, 1): (0, 0),
                (9, 11): (0, 5),
                (13, 2): (0, 2),
            },
        )
        client = make_client(handler)
        client.connect()
        status = client.read_status()

        self.assertEqual(status.values["pm25"], 97)
        self.assertEqual(status.values["favorite_level"], 5)
        self.assertEqual(status.values["filter_used_time"], 63)
        self.assertNotIn("fan_level", status.values)
        self.assertNotIn("fan_level", status.unsupported)
        self.assertEqual(status.properties["mode"].maximum, 2)
        self.assertEqual(status.properties["favorite_level"].siid, 9)
        self.assertEqual(status.properties["favorite_level"].piid, 11)
        self.assertEqual(status.properties["favorite_level"].maximum, 14)

        properties = status.as_dict()["properties"]
        mode = next(prop for prop in properties if prop["name"] == "mode")
        self.assertEqual(mode["maximum"], 2)

        with self.assertRaises(miio.MiiOError):
            client.set_property("mode", 3)


class ControlTests(unittest.TestCase):
    def test_rejects_invalid_writes_before_sending(self) -> None:
        handler, calls, _ = device_handler(values={(2, 1): (0, False)})
        client = make_client(handler)
        client.connect()
        for name, value in (
            ("fan_level", 4),
            ("mode", 9),
            ("screen_brightness", 3),
            ("temperature_unit", 0),
            ("pm25", 10),
            ("unknown", 1),
        ):
            with self.subTest(name=name):
                with self.assertRaises(miio.MiiOError):
                    client.set_property(name, value)
        self.assertEqual(calls["set"], [])

    def test_set_property_reads_back(self) -> None:
        handler, calls, _ = device_handler(values={(2, 1): (0, False)})
        client = make_client(handler)
        client.connect()
        result = client.set_property("power", True)
        self.assertTrue(result.applied)
        self.assertIsNone(result.error)
        self.assertTrue(result.status.values["power"])
        self.assertEqual(len(calls["set"]), 1)

    def test_set_property_reports_a_mismatch(self) -> None:
        handler, _, _ = device_handler(
            values={(2, 1): (0, False)}, set_effect=False
        )
        client = make_client(handler, readback_timeout=0.01)
        client.connect()
        result = client.set_property("power", True)
        self.assertFalse(result.applied)
        self.assertIn("did not apply", result.error or "")
        self.assertFalse(result.status.values["power"])

    def test_reset_filter_sends_one_action_and_reads_back(self) -> None:
        handler, calls, _ = device_handler(
            values={(4, 1): (0, 50), (4, 3): (0, 1234)}
        )
        client = make_client(handler)
        client.connect()
        result = client.reset_filter()
        self.assertTrue(result.applied)
        self.assertEqual(calls["action"], 1)
        self.assertEqual(result.status.values["filter_used_time"], 0)

    def test_reset_filter_does_not_retry_after_timeout(self) -> None:
        handler, calls, _ = device_handler(
            values={(4, 1): (0, 50), (4, 3): (0, 1234)},
            action_timeout=True,
        )
        client = make_client(handler)
        client.connect()
        result = client.reset_filter()
        self.assertFalse(result.applied)
        self.assertEqual(calls["action"], 1)
        self.assertIn("check the filter", result.error or "")


if __name__ == "__main__":
    unittest.main()
