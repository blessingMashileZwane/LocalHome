"""Local miIO/MIoT client for Xiaomi air purifiers.

Talks to the purifier on UDP 54321 using the token-derived AES-CBC framing.
Status reads and allowlisted controls stay on the private LAN; no Xiaomi
account, cloud endpoint, or relay is used.

The token is a bearer secret. It is never printed, logged, or included in an
error message. `miIO.info` can echo the token and the device MAC, so only the
model and firmware fields are kept.
"""

from __future__ import annotations

import hashlib
import json
import socket
import struct
import time
from dataclasses import dataclass, field
from ipaddress import ip_address, ip_network
from typing import Callable

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from local_net import is_private_ipv4

MIIO_PORT = 54321
MAX_PROPERTIES_PER_REQUEST = 15
MAX_PACKET_BYTES = 4096
MIIO_MAGIC = 0x2131
DEFAULT_TIMEOUT = 4.0
HANDSHAKE_TTL_SECONDS = 300.0
HELLO_PACKET = bytes.fromhex(
    "21310020ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
)


class MiiOError(Exception):
    """A local miIO validation or transport error."""


class MiiOAuthError(MiiOError):
    """The device rejected the token or the packet checksum."""


class MiiOTimeoutError(MiiOError):
    """The device did not answer on the local network."""


def parse_token(value: str | bytes) -> bytes:
    """Return a 16-byte token from 32 hex characters or raw bytes."""
    if isinstance(value, bytes):
        token = value
    elif isinstance(value, str):
        text = value.strip()
        if len(text) != 32:
            raise MiiOError("The token must be 32 hexadecimal characters.")
        try:
            token = bytes.fromhex(text)
        except ValueError as error:
            raise MiiOError("The token must be 32 hexadecimal characters.") from error
    else:
        raise MiiOError("The token must be text or bytes.")
    if len(token) != 16:
        raise MiiOError("The token must be 16 bytes.")
    return token


def _key_iv(token: bytes) -> tuple[bytes, bytes]:
    key = hashlib.md5(token).digest()  # noqa: S324 - protocol requirement
    iv = hashlib.md5(key + token).digest()  # noqa: S324 - protocol requirement
    return key, iv


def _encrypt(plaintext: bytes, token: bytes) -> bytes:
    key, iv = _key_iv(token)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plaintext) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return encryptor.update(padded) + encryptor.finalize()


def _decrypt(ciphertext: bytes, token: bytes) -> bytes:
    key, iv = _key_iv(token)
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    padded = decryptor.update(ciphertext) + decryptor.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


def _header(length: int, device_id: bytes, stamp: int) -> bytes:
    if len(device_id) != 4:
        raise MiiOError("The device identifier is not valid.")
    return (
        struct.pack(">HHI", MIIO_MAGIC, length, 0)
        + device_id
        + struct.pack(">I", stamp & 0xFFFFFFFF)
    )


def build_hello() -> bytes:
    return HELLO_PACKET


def build_request(
    payload: dict, token: bytes, device_id: bytes, stamp: int
) -> bytes:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\x00"
    encrypted = _encrypt(body, token)
    header = _header(len(encrypted) + 32, device_id, stamp)
    checksum = hashlib.md5(header + token + encrypted).digest()  # noqa: S324
    return header + checksum + encrypted


def parse_response(
    packet: bytes, token: bytes
) -> tuple[bytes, int, dict | None]:
    """Return (device_id, stamp, payload) from a device packet."""
    if len(packet) < 32 or len(packet) > MAX_PACKET_BYTES:
        raise MiiOError("The purifier sent an invalid packet.")
    magic, length = struct.unpack(">HH", packet[:4])
    if magic != MIIO_MAGIC or length != len(packet):
        raise MiiOError("The purifier sent an invalid packet.")
    device_id = packet[8:12]
    stamp = struct.unpack(">I", packet[12:16])[0]
    if length == 32:
        return device_id, stamp, None

    checksum = packet[16:32]
    encrypted = packet[32:]
    expected = hashlib.md5(packet[:16] + token + encrypted).digest()  # noqa: S324
    if checksum != expected:
        raise MiiOAuthError("The purifier rejected the token.")
    try:
        plaintext = _decrypt(encrypted, token).rstrip(b"\x00")
    except ValueError as error:
        raise MiiOAuthError("The purifier rejected the token.") from error
    try:
        payload = json.loads(plaintext.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MiiOError("The purifier sent a response that could not be read.") from error
    if not isinstance(payload, dict):
        raise MiiOError("The purifier sent a response that could not be read.")
    return device_id, stamp, payload


def discover(timeout: float = 3.0) -> list[str]:
    """Return addresses that answered the unauthenticated hello broadcast."""
    deadline = time.monotonic() + max(1.0, min(timeout, 10.0))
    addresses: list[str] = []
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(0.4)
        for _ in range(3):
            try:
                sock.sendto(HELLO_PACKET, ("255.255.255.255", MIIO_PORT))
            except OSError:
                break
        while time.monotonic() < deadline:
            try:
                data, (address, _) = sock.recvfrom(MAX_PACKET_BYTES + 1)
            except socket.timeout:
                continue
            except OSError:
                break
            if len(data) < 32 or len(data) > MAX_PACKET_BYTES:
                continue
            magic, length = struct.unpack(">HH", data[:4])
            if magic != MIIO_MAGIC or length != len(data):
                continue
            if address not in addresses and is_private_ipv4(address):
                addresses.append(address)
    finally:
        sock.close()
    return addresses


def discover_hosts(network: str, timeout: float = 4.0) -> list[str]:
    """Send unicast hellos to a private /24 and return the responders.

    Use this when the access point filters the limited broadcast used by
    :func:`discover`.
    """
    try:
        net = ip_network(network, strict=False)
    except ValueError as error:
        raise MiiOError("The sweep network is not a valid CIDR.") from error
    if net.version != 4 or net.prefixlen != 24:
        raise MiiOError("The sweep network must be a private IPv4 /24.")
    hosts = [str(host) for host in net.hosts()]
    if not hosts or not all(is_private_ipv4(host) for host in hosts):
        raise MiiOError("The sweep network must be a private IPv4 /24.")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(0.2)
        for host in hosts:
            try:
                sock.sendto(HELLO_PACKET, (host, MIIO_PORT))
            except OSError:
                continue
        found: set[str] = set()
        deadline = time.monotonic() + max(1.0, min(timeout, 10.0))
        while time.monotonic() < deadline:
            try:
                data, (source, _) = sock.recvfrom(MAX_PACKET_BYTES + 1)
            except socket.timeout:
                continue
            except OSError:
                break
            if len(data) < 32 or len(data) > MAX_PACKET_BYTES:
                continue
            magic, length = struct.unpack(">HH", data[:4])
            if (
                magic == MIIO_MAGIC
                and length == len(data)
                and is_private_ipv4(source)
            ):
                found.add(source)
        return sorted(found, key=ip_address)
    finally:
        sock.close()


@dataclass(frozen=True)
class Property:
    name: str
    siid: int
    piid: int
    kind: str
    minimum: float | None = None
    maximum: float | None = None
    writable: bool = False
    label: str = ""
    unit: str | None = None
    hidden: bool = False


def _p(
    name: str,
    siid: int,
    piid: int,
    kind: str,
    *,
    minimum: float | None = None,
    maximum: float | None = None,
    writable: bool = False,
    label: str = "",
    unit: str | None = None,
    hidden: bool = False,
) -> Property:
    return Property(
        name=name,
        siid=siid,
        piid=piid,
        kind=kind,
        minimum=minimum,
        maximum=maximum,
        writable=writable,
        label=label or name,
        unit=unit,
        hidden=hidden,
    )


COMMON_PROPERTIES: dict[str, Property] = {
    "power": _p("power", 2, 1, "bool", writable=True, label="Power"),
    "fault": _p("fault", 2, 2, "int", label="Fault"),
    "mode": _p(
        "mode", 2, 4, "int", minimum=0, maximum=3, writable=True, label="Mode"
    ),
    "fan_level": _p(
        "fan_level", 2, 5, "int", minimum=1, maximum=3, writable=True,
        label="Fan level",
    ),
    "anion": _p("anion", 2, 6, "bool", writable=True, label="Anion"),
    "humidity": _p(
        "humidity", 3, 1, "int", minimum=0, maximum=100, label="Humidity",
        unit="%",
    ),
    "pm25": _p(
        "pm25", 3, 4, "float", minimum=0, maximum=1000, label="PM2.5",
        unit="µg/m³",
    ),
    "temperature": _p(
        "temperature", 3, 7, "float", minimum=-30, maximum=100,
        label="Temperature", unit="°C",
    ),
    "filter_life": _p(
        "filter_life", 4, 1, "int", minimum=0, maximum=100, label="Filter life",
        unit="%",
    ),
    "filter_used_time": _p(
        "filter_used_time", 4, 3, "int", minimum=0, maximum=65000,
        label="Filter used", unit="h",
    ),
    "filter_left_time": _p(
        "filter_left_time", 4, 4, "int", minimum=0, maximum=1000,
        label="Filter left", unit="days",
    ),
    "alarm": _p("alarm", 6, 1, "bool", writable=True, label="Buzzer"),
    "child_lock": _p(
        "child_lock", 8, 1, "bool", writable=True, label="Child lock"
    ),
    "motor_rpm": _p(
        "motor_rpm", 9, 1, "int", label="Motor speed", unit="rpm"
    ),
    "favorite_speed": _p(
        "favorite_speed", 9, 2, "int", minimum=200, maximum=2300, writable=True,
        label="Favorite speed", unit="rpm", hidden=True,
    ),
    "favorite_level": _p(
        "favorite_level", 9, 5, "int", minimum=0, maximum=11, writable=True,
        label="Favorite level",
    ),
    "door": _p("door", 9, 6, "bool", label="Filter door"),
    "manual_level": _p(
        "manual_level", 9, 9, "int", minimum=1, maximum=3, writable=True,
        label="Manual level", hidden=True,
    ),
    "purify_volume": _p(
        "purify_volume", 11, 1, "int", minimum=0, maximum=2147483600,
        label="Purified volume", unit="m³",
    ),
    "average_aqi": _p(
        "average_aqi", 11, 2, "int", minimum=0, maximum=600, label="Average AQI"
    ),
    "aqi_state": _p(
        "aqi_state", 11, 3, "int", minimum=0, maximum=5, label="Air quality"
    ),
    "filter_rfid_product": _p(
        "filter_rfid_product", 12, 3, "str", label="Filter type"
    ),
    "screen_brightness": _p(
        "screen_brightness", 13, 2, "int", minimum=0, maximum=2, writable=True,
        label="Screen brightness",
    ),
    "temperature_unit": _p(
        "temperature_unit", 14, 1, "int", minimum=1, maximum=2, writable=True,
        label="Temperature unit",
    ),
}

MB5A_PROPERTIES: dict[str, Property] = dict(COMMON_PROPERTIES)

VB4_PROPERTIES: dict[str, Property] = {
    **COMMON_PROPERTIES,
    "pm10": _p(
        "pm10", 3, 8, "float", minimum=1, maximum=100, label="PM10",
        unit="µg/m³",
    ),
    "air_quality": _p(
        "air_quality", 3, 9, "int", minimum=0, maximum=5, label="Air quality"
    ),
    "favorite_square": _p(
        "favorite_square", 9, 12, "str", label="Favorite area", hidden=True
    ),
}

CPA4_PROPERTIES: dict[str, Property] = {
    "power": _p("power", 2, 1, "bool", writable=True, label="Power"),
    "fault": _p("fault", 2, 2, "int", label="Fault"),
    "mode": _p(
        "mode", 2, 4, "int", minimum=0, maximum=2, writable=True, label="Mode"
    ),
    "pm25": _p(
        "pm25", 3, 4, "int", minimum=0, maximum=600, label="PM2.5",
        unit="µg/m³",
    ),
    "filter_life": _p(
        "filter_life", 4, 1, "int", minimum=0, maximum=100, label="Filter life",
        unit="%",
    ),
    "filter_used_time": _p(
        "filter_used_time", 4, 3, "int", minimum=0, maximum=65535,
        label="Filter used", unit="h",
    ),
    "filter_left_time": _p(
        "filter_left_time", 4, 4, "int", minimum=0, maximum=1000,
        label="Filter left", unit="days",
    ),
    "alarm": _p("alarm", 6, 1, "bool", writable=True, label="Buzzer"),
    "child_lock": _p(
        "child_lock", 8, 1, "bool", writable=True, label="Child lock"
    ),
    "motor_rpm": _p(
        "motor_rpm", 9, 1, "int", minimum=0, maximum=2500,
        label="Motor speed", unit="rpm",
    ),
    "favorite_level": _p(
        "favorite_level", 9, 11, "int", minimum=0, maximum=14, writable=True,
        label="Favorite level",
    ),
    "screen_brightness": _p(
        "screen_brightness", 13, 2, "int", minimum=0, maximum=2, writable=True,
        label="Screen brightness",
    ),
}

MODEL_ALIASES: dict[str, str] = {
    "zhimi.airp.mb5": "zhimi.airp.mb5a",
    "zhimi.airp.mb5a": "zhimi.airp.mb5a",
    "zhimi.airp.va2": "zhimi.airp.vb4",
    "zhimi.airp.vb4": "zhimi.airp.vb4",
    "xiaomi.airp.cpa4": "xiaomi.airp.cpa4",
}

MODEL_PROPERTIES: dict[str, dict[str, Property]] = {
    "zhimi.airp.mb5a": MB5A_PROPERTIES,
    "zhimi.airp.vb4": VB4_PROPERTIES,
    "xiaomi.airp.cpa4": CPA4_PROPERTIES,
}

ALTERNATE_PROPERTIES: dict[str, dict[str, Property]] = {
    "zhimi.airp.vb4": {
        "favorite_level": _p(
            "favorite_level", 15, 1, "int", minimum=0, maximum=11,
            writable=True, label="Favorite level",
        )
    }
}


def properties_for_model(model: str) -> dict[str, Property]:
    canonical = MODEL_ALIASES.get(model)
    if canonical is None:
        return {
            name: prop
            for name, prop in COMMON_PROPERTIES.items()
            if not prop.hidden
        }
    return {
        name: prop
        for name, prop in MODEL_PROPERTIES[canonical].items()
        if not prop.hidden
    }


@dataclass
class DeviceInfo:
    address: str
    model: str
    firmware: str | None = None
    hardware: str | None = None

    def as_dict(self) -> dict:
        return {
            "address": self.address,
            "model": self.model,
            "firmware": self.firmware,
            "hardware": self.hardware,
        }


@dataclass
class AirPurifierStatus:
    info: DeviceInfo
    values: dict[str, object]
    unsupported: list[str]
    errors: dict[str, int]
    received_at: int
    properties: dict[str, Property] = field(default_factory=dict)

    def as_dict(self) -> dict:
        payload = self.info.as_dict()
        payload.update(
            {
                "values": self.values,
                "unsupported": self.unsupported,
                "errors": self.errors,
                "received_at": self.received_at,
                "properties": [
                    {
                        "name": prop.name,
                        "label": prop.label,
                        "kind": prop.kind,
                        "minimum": prop.minimum,
                        "maximum": prop.maximum,
                        "writable": prop.writable,
                        "unit": prop.unit,
                    }
                    for prop in self.properties.values()
                    if not prop.hidden
                ],
            }
        )
        return payload


@dataclass
class ControlResult:
    status: AirPurifierStatus
    applied: bool
    error: str | None = None

    def as_dict(self) -> dict:
        payload = self.status.as_dict()
        payload["applied"] = self.applied
        payload["error"] = self.error
        return payload


Transport = Callable[[bytes, float], bytes]


def _udp_exchange(address: str, port: int) -> Transport:
    def exchange(packet: bytes, timeout: float) -> bytes:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.settimeout(timeout)
            try:
                sock.sendto(packet, (address, port))
            except OSError as error:
                raise MiiOTimeoutError(
                    "Could not reach the purifier on UDP 54321."
                ) from error
            deadline = time.monotonic() + timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise MiiOTimeoutError(
                        "No response from the purifier on UDP 54321."
                    )
                sock.settimeout(remaining)
                try:
                    data, (source, _) = sock.recvfrom(MAX_PACKET_BYTES + 1)
                except socket.timeout as error:
                    raise MiiOTimeoutError(
                        "No response from the purifier on UDP 54321."
                    ) from error
                except OSError as error:
                    raise MiiOTimeoutError(
                        "Could not reach the purifier on UDP 54321."
                    ) from error
                if source != address:
                    continue
                if len(data) > MAX_PACKET_BYTES:
                    raise MiiOError("The purifier sent an invalid packet.")
                return data
        finally:
            sock.close()

    return exchange


def _coerce(prop: Property, value: object) -> object:
    if value is None:
        return None
    if prop.kind == "bool":
        if isinstance(value, bool):
            return value
        if isinstance(value, int):
            return bool(value)
        return None
    if prop.kind == "int":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return int(value)
    if prop.kind == "float":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return float(value)
    if prop.kind == "str":
        return value if isinstance(value, str) else None
    return None


def _validate_value(prop: Property, value: object) -> object:
    if prop.kind == "bool":
        if isinstance(value, bool):
            return value
        raise MiiOError("That value must be true or false.")
    if prop.kind == "int":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise MiiOError("That value must be a number.")
        number = int(value)
        if value != number:
            raise MiiOError("That value must be a whole number.")
        if prop.minimum is not None and number < prop.minimum:
            raise MiiOError("That value is out of range.")
        if prop.maximum is not None and number > prop.maximum:
            raise MiiOError("That value is out of range.")
        return number
    if prop.kind == "float":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise MiiOError("That value must be a number.")
        number = float(value)
        if prop.minimum is not None and number < prop.minimum:
            raise MiiOError("That value is out of range.")
        if prop.maximum is not None and number > prop.maximum:
            raise MiiOError("That value is out of range.")
        return number
    if prop.kind == "str":
        if isinstance(value, str):
            return value
        raise MiiOError("That value must be text.")
    raise MiiOError("That purifier setting is not supported.")


def _device_error_message(code: object) -> str:
    if code == -4001:
        return "The device does not expose that property."
    if code in (-30001, -9999):
        return "The device is busy."
    if code == -5001:
        return "The device rejected that value."
    if isinstance(code, int):
        return f"The device rejected the request (code {code})."
    return "The device rejected the request."


class MiioClient:
    def __init__(
        self,
        address: str,
        token: str | bytes,
        *,
        port: int = MIIO_PORT,
        timeout: float = DEFAULT_TIMEOUT,
        readback_timeout: float = 3.0,
        transport: Transport | None = None,
    ):
        if not is_private_ipv4(address):
            raise MiiOError("The purifier address must be a private IPv4 address.")
        self.address = address
        self.port = port
        self.timeout = timeout
        self.readback_timeout = readback_timeout
        self._token = parse_token(token)
        self._transport = transport
        self._device_id: bytes | None = None
        self._device_stamp = 0
        self._handshake_at = 0.0
        self._request_id = 0
        self._closed = False
        self.model = ""
        self._known_model = False
        self._properties: dict[str, Property] = {
            name: prop
            for name, prop in COMMON_PROPERTIES.items()
            if not prop.hidden
        }
        self._favorite_alternate: Property | None = None
        self.info: DeviceInfo | None = None

    def _exchange(self, packet: bytes) -> tuple[bytes, int, dict | None]:
        if self._transport is None:
            self._transport = _udp_exchange(self.address, self.port)
        data = self._transport(packet, self.timeout)
        return parse_response(data, self._token)

    def _handshake(self) -> None:
        device_id, stamp, _ = self._exchange(build_hello())
        if len(device_id) != 4:
            raise MiiOError("The purifier sent an invalid handshake.")
        self._device_id = device_id
        self._device_stamp = stamp
        self._handshake_at = time.monotonic()

    def _request(self, method: str, params: object, *, retry: bool = True) -> object:
        if self._closed:
            raise MiiOError("The purifier session is closed.")
        attempts = 2 if retry else 1
        for attempt in range(attempts):
            if (
                self._device_id is None
                or time.monotonic() - self._handshake_at > HANDSHAKE_TTL_SECONDS
            ):
                self._handshake()
            self._request_id = self._request_id % 9998 + 1
            payload = {
                "id": self._request_id,
                "method": method,
                "params": params,
            }
            packet = build_request(
                payload,
                self._token,
                self._device_id or b"\x00\x00\x00\x00",
                self._device_stamp + 1,
            )
            try:
                _, stamp, response = self._exchange(packet)
            except MiiOTimeoutError:
                self._handshake_at = 0.0
                if attempt + 1 < attempts:
                    continue
                raise
            self._device_stamp = stamp
            if response is None:
                raise MiiOError("The purifier sent an incomplete response.")
            response_id = response.get("id")
            if response_id is not None and response_id != self._request_id:
                raise MiiOError("The purifier response did not match the request.")
            error = response.get("error")
            if isinstance(error, dict):
                code = error.get("code")
                if code in (-30001, -9999) and attempt + 1 < attempts:
                    self._handshake_at = 0.0
                    continue
                raise MiiOError(_device_error_message(code))
            return response.get("result")
        raise MiiOError("The purifier did not answer.")

    def connect(self) -> DeviceInfo:
        self._handshake()
        info = self._request("miIO.info", [])
        if not isinstance(info, dict):
            raise MiiOError("The purifier did not return device information.")
        model = info.get("model")
        if not isinstance(model, str) or not model:
            raise MiiOError("The purifier did not report its model.")
        self.model = model
        self._known_model = model in MODEL_ALIASES
        self._properties = properties_for_model(model)
        self._favorite_alternate = (
            ALTERNATE_PROPERTIES.get(MODEL_ALIASES.get(model, ""), {}).get(
                "favorite_level"
            )
        )
        firmware = info.get("fw_ver")
        hardware = info.get("hw_ver")
        self.info = DeviceInfo(
            address=self.address,
            model=model,
            firmware=firmware if isinstance(firmware, str) else None,
            hardware=hardware if isinstance(hardware, str) else None,
        )
        # Drop the raw info mapping: some firmware echoes the token and MAC.
        del info
        return self.info

    def _get_properties(
        self, properties: list[Property]
    ) -> tuple[dict[str, object], list[str], dict[str, int]]:
        values: dict[str, object] = {}
        unsupported: list[str] = []
        errors: dict[str, int] = {}
        for start in range(0, len(properties), MAX_PROPERTIES_PER_REQUEST):
            chunk = properties[start : start + MAX_PROPERTIES_PER_REQUEST]
            params = [
                {"did": prop.name, "siid": prop.siid, "piid": prop.piid}
                for prop in chunk
            ]
            result = self._request("get_properties", params)
            if not isinstance(result, list):
                raise MiiOError("The purifier did not return property values.")
            by_name = {prop.name: prop for prop in chunk}
            by_pair = {(prop.siid, prop.piid): prop.name for prop in chunk}
            for entry in result:
                if not isinstance(entry, dict):
                    continue
                name = entry.get("did")
                if not isinstance(name, str) or name not in by_name:
                    name = by_pair.get((entry.get("siid"), entry.get("piid")))
                if name is None:
                    continue
                code = entry.get("code")
                if code != 0:
                    if code == -4001:
                        unsupported.append(name)
                    elif isinstance(code, int):
                        errors[name] = code
                    else:
                        errors[name] = -1
                    continue
                values[name] = _coerce(by_name[name], entry.get("value"))
        return values, unsupported, errors

    def read_status(self) -> AirPurifierStatus:
        if self.info is None:
            self.connect()
        info = self.info
        if info is None:
            raise MiiOError("The purifier session is not connected.")
        if not self._known_model:
            return AirPurifierStatus(
                info=info,
                values={},
                unsupported=[],
                errors={},
                received_at=int(time.time()),
                properties={},
            )
        properties = [
            prop for prop in self._properties.values() if not prop.hidden
        ]
        values, unsupported, errors = self._get_properties(properties)
        alternate = self._favorite_alternate
        if (
            alternate is not None
            and self._properties.get("favorite_level") is not alternate
            and "favorite_level" in unsupported
        ):
            alt_values, alt_unsupported, _ = self._get_properties([alternate])
            if "favorite_level" not in alt_unsupported:
                self._properties["favorite_level"] = alternate
                values["favorite_level"] = alt_values.get("favorite_level")
                unsupported = [
                    name for name in unsupported if name != "favorite_level"
                ]
                errors.pop("favorite_level", None)
        info = self.info
        if info is None:
            raise MiiOError("The purifier session is not connected.")
        return AirPurifierStatus(
            info=info,
            values=values,
            unsupported=unsupported,
            errors=errors,
            received_at=int(time.time()),
            properties=dict(self._properties),
        )

    def _wait_for_value(
        self, name: str, expected: object
    ) -> AirPurifierStatus:
        """Read until a write is visible, or the read-back timeout expires.

        The device can apply a write one request late, so an immediate read
        may still return the previous value.
        """
        deadline = time.monotonic() + max(0.0, self.readback_timeout)
        status = self.read_status()
        while status.values.get(name) != expected:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(0.4, remaining))
            status = self.read_status()
        return status

    def set_property(self, name: str, value: object) -> ControlResult:
        if self.info is None:
            self.connect()
        if not self._known_model:
            raise MiiOError("Writing to an unknown purifier model is not supported.")
        prop = self._properties.get(name)
        if prop is None or not prop.writable:
            raise MiiOError("That purifier setting is not supported.")
        checked = _validate_value(prop, value)
        params = [
            {
                "did": prop.name,
                "siid": prop.siid,
                "piid": prop.piid,
                "value": checked,
            }
        ]
        result = self._request("set_properties", params, retry=False)
        entries = result if isinstance(result, list) else [result]
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            code = entry.get("code")
            if code not in (0, None):
                raise MiiOError(_device_error_message(code))
        status = self._wait_for_value(prop.name, checked)
        applied = status.values.get(prop.name) == checked
        if not applied:
            return ControlResult(
                status=status,
                applied=False,
                error="The purifier did not apply that change.",
            )
        return ControlResult(status=status, applied=True)

    def reset_filter(self) -> ControlResult:
        if self.info is None:
            self.connect()
        if not self._known_model:
            raise MiiOError(
                "Resetting the filter on an unknown model is not supported."
            )
        params = {
            "did": "call-4-1",
            "siid": 4,
            "aiid": 1,
            "in": [{"piid": 3, "value": 0}],
        }
        try:
            result = self._request("action", params, retry=False)
        except MiiOTimeoutError:
            status = self.read_status()
            return ControlResult(
                status=status,
                applied=False,
                error=(
                    "No response from the purifier; check the filter values "
                    "before retrying."
                ),
            )
        code = None
        if isinstance(result, dict):
            code = result.get("code")
        elif isinstance(result, list) and result and isinstance(result[0], dict):
            code = result[0].get("code")
        if code not in (0, None):
            raise MiiOError(_device_error_message(code))
        status = self._wait_for_value("filter_used_time", 0)
        if status.values.get("filter_used_time") != 0:
            return ControlResult(
                status=status,
                applied=False,
                error="The purifier did not reset the filter counter.",
            )
        return ControlResult(status=status, applied=True)

    def close(self) -> None:
        self._closed = True
        self._transport = None
