"""Local Hinen PS300 discovery and read-only Tuya LAN access.

The PS300 is a Tuya LAN 3.4 device on TCP 6668. Discovery is unauthenticated;
reading data points requires the 16-character Tuya local key. This module never
writes, never controls, and never logs the local key. The Hinen/SolisCloud app is
a Tuya-based device; no cloud call is made here.
"""

from __future__ import annotations

import hashlib
import importlib
import json
import os
import pathlib
import socket
import ssl
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

from local_net import is_private_ipv4

TUYA_PORT = 6668
TUYA_PROTOCOL_VERSION = 3.4
TUYA_LOCAL_KEY_LENGTH = 16
DEFAULT_ENV_FILE = pathlib.Path.home() / ".config" / "localhome-hinen.env"
LOCAL_KEY_ENV = "HINEN_LOCAL_KEY"
DEVICE_ID_ENV = "HINEN_DEVICE_ID"
LOCAL_PORTS = (
    80,
    443,
    502,
    1883,
    5000,
    6668,
    8000,
    8080,
    8443,
    8883,
    8888,
    9000,
)
MAX_RESPONSE_BYTES = 65536
WRITABLE_DPS: dict[int, type] = {
    6: bool,
    7: bool,
    25: bool,
    26: int,
    105: int,
    106: int,
    108: bool,
    109: int,
    110: int,
    113: int,
}


class HinenError(Exception):
    """A local Hinen/Tuya validation or transport error."""


class HinenDependencyError(HinenError):
    """An optional discovery dependency is not installed."""


@dataclass(frozen=True)
class TuyaDevice:
    address: str
    device_id: str
    product_key: str
    version: str
    active: int
    encrypted: bool

    def as_dict(self) -> dict:
        return {
            "address": self.address,
            "device_id_prefix": f"{self.device_id[:6]}…",
            "product_key": self.product_key,
            "version": self.version,
            "active": self.active,
            "encrypted": self.encrypted,
        }


def _require(module: str, hint: str):
    try:
        return importlib.import_module(module)
    except ImportError as error:
        raise HinenDependencyError(
            f"{module} is not installed. {hint}"
        ) from error


def read_env_file(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.expanduser().read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def load_local_key(path: pathlib.Path | None = None) -> str | None:
    value = os.environ.get(LOCAL_KEY_ENV)
    if not value:
        value = read_env_file(path or DEFAULT_ENV_FILE).get(LOCAL_KEY_ENV)
    if not value:
        return None
    value = value.strip()
    if len(value) != TUYA_LOCAL_KEY_LENGTH:
        raise HinenError(
            f"{LOCAL_KEY_ENV} must be exactly {TUYA_LOCAL_KEY_LENGTH} characters."
        )
    return value


def load_device_id(path: pathlib.Path | None = None) -> str | None:
    value = os.environ.get(DEVICE_ID_ENV)
    if not value:
        value = read_env_file(path or DEFAULT_ENV_FILE).get(DEVICE_ID_ENV)
    return value.strip() if value else None


def discover_tuya(timeout: float = 6.0) -> list[TuyaDevice]:
    tinytuya = _require(
        "tinytuya",
        "Run with `uv run --with tinytuya ...` or install tinytuya.",
    )
    scantime = max(3, min(int(timeout), 18))
    try:
        raw = tinytuya.deviceScan(
            verbose=False,
            maxretry=scantime,
            color=False,
            poll=False,
        )
    except Exception as error:
        raise HinenError(
            f"Tuya discovery failed ({error.__class__.__name__})."
        ) from error
    devices: list[TuyaDevice] = []
    for address, data in (raw or {}).items():
        if not is_private_ipv4(address) or not isinstance(data, dict):
            continue
        device_id = data.get("gwId") or data.get("id")
        if not isinstance(device_id, str) or not device_id:
            continue
        devices.append(
            TuyaDevice(
                address=address,
                device_id=device_id,
                product_key=str(data.get("productKey") or ""),
                version=str(data.get("version") or ""),
                active=int(data.get("active") or 0),
                encrypted=bool(data.get("encrypt")),
            )
        )
    return sorted(
        devices,
        key=lambda device: tuple(int(part) for part in device.address.split(".")),
    )


def read_tuya_status(
    address: str,
    local_key: str,
    *,
    device_id: str | None = None,
    timeout: float = 6.0,
) -> dict[str, Any]:
    if not is_private_ipv4(address):
        raise HinenError("The station address must be a private IPv4 address.")
    if len(local_key) != TUYA_LOCAL_KEY_LENGTH:
        raise HinenError(
            f"The Tuya local key must be {TUYA_LOCAL_KEY_LENGTH} characters."
        )
    tinytuya = _require(
        "tinytuya",
        "Run with `uv run --with tinytuya ...` or install tinytuya.",
    )
    if not device_id:
        devices = discover_tuya(timeout=timeout)
        match = next(
            (device for device in devices if device.address == address), None
        )
        if match is None:
            raise HinenError("No Tuya device answered at that address.")
        device_id = match.device_id
    device = tinytuya.Device(
        device_id,
        address=address,
        local_key=local_key,
        version=TUYA_PROTOCOL_VERSION,
        connection_timeout=timeout,
        persist=False,
    )
    try:
        if hasattr(device, "set_socketTimeout"):
            device.set_socketTimeout(timeout)
        status = device.status()
    except Exception as error:
        raise HinenError(
            "The Tuya device did not accept the local key or did not respond."
        ) from error
    finally:
        try:
            device.close()
        except Exception:
            pass
    if not isinstance(status, dict) or not isinstance(status.get("dps"), dict):
        raise HinenError("The Tuya device did not return a data-point map.")
    return {
        "address": address,
        "dps": {str(key): value for key, value in status["dps"].items()},
        "received_at": int(time.time()),
    }


def write_tuya_dp(
    address: str,
    local_key: str,
    dp: int,
    value: bool | int,
    *,
    device_id: str | None = None,
    timeout: float = 6.0,
) -> dict[str, Any]:
    """Write one allowlisted DP and read the full state back."""
    if not is_private_ipv4(address):
        raise HinenError("The station address must be a private IPv4 address.")
    if len(local_key) != TUYA_LOCAL_KEY_LENGTH:
        raise HinenError(
            f"The Tuya local key must be {TUYA_LOCAL_KEY_LENGTH} characters."
        )
    expected = WRITABLE_DPS.get(dp)
    if expected is None:
        raise HinenError(f"DP {dp} is not on the writable allowlist.")
    if expected is bool and not isinstance(value, bool):
        raise HinenError(f"DP {dp} expects a boolean value.")
    if expected is int and (
        isinstance(value, bool) or not isinstance(value, int)
    ):
        raise HinenError(f"DP {dp} expects an integer value.")
    if dp in (26, 109, 110) and not 0 <= value <= 86400:
        raise HinenError(f"DP {dp} is outside the supported range.")
    if dp == 105 and not 0 <= value <= 100:
        raise HinenError("DP 105 AC charging limit must be 0-100.")
    if dp == 106 and not 0 <= value <= 16:
        raise HinenError("DP 106 vehicle charging current must be 0-16 A.")
    if dp == 113 and not 0 <= value <= 4:
        raise HinenError("DP 113 light mode must be 0-4.")
    tinytuya = _require(
        "tinytuya",
        "Run with `uv run --with tinytuya ...` or install tinytuya.",
    )
    if not device_id:
        devices = discover_tuya(timeout=timeout)
        match = next(
            (device for device in devices if device.address == address), None
        )
        if match is None:
            raise HinenError("No Tuya device answered at that address.")
        device_id = match.device_id
    device = tinytuya.Device(
        device_id,
        address=address,
        local_key=local_key,
        version=TUYA_PROTOCOL_VERSION,
        connection_timeout=timeout,
        persist=False,
    )
    try:
        if hasattr(device, "set_socketTimeout"):
            device.set_socketTimeout(timeout)
        result = device.set_value(dp, value)
    except Exception as error:
        raise HinenError(
            "The Tuya device rejected the local write or did not respond."
        ) from error
    finally:
        try:
            device.close()
        except Exception:
            pass
    if not isinstance(result, dict) or "Err" in result:
        raise HinenError("The Tuya device did not acknowledge the write.")
    status = read_tuya_status(
        address,
        local_key,
        device_id=device_id,
        timeout=timeout,
    )
    if str(status["dps"].get(str(dp))) != str(value):
        raise HinenError(
            f"Write verification failed for DP {dp}; check the station state."
        )
    return status


def _port_open(address: str, port: int, timeout: float) -> bool:
    try:
        with socket.create_connection((address, port), timeout=timeout):
            return True
    except OSError:
        return False


def _http_details(
    address: str, port: int, timeout: float
) -> dict[str, Any]:
    request = urllib.request.Request(f"http://{address}:{port}/", method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return {
                "status": response.status,
                "server": response.headers.get("Server"),
                "content_type": response.headers.get("Content-Type"),
            }
    except urllib.error.HTTPError as error:
        return {
            "status": error.code,
            "server": error.headers.get("Server") if error.headers else None,
        }
    except (urllib.error.URLError, OSError, ValueError) as error:
        return {"error": error.__class__.__name__}


def _tls_details(
    address: str, port: int, timeout: float
) -> dict[str, Any]:
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((address, port), timeout=timeout) as raw:
            with context.wrap_socket(raw, server_hostname=address) as tls:
                certificate = tls.getpeercert(binary_form=True)
                cipher = tls.cipher()
                return {
                    "version": tls.version(),
                    "cipher": cipher[0] if cipher else None,
                    "cert_sha256": (
                        hashlib.sha256(certificate).hexdigest()
                        if certificate
                        else None
                    ),
                }
    except (OSError, ssl.SSLError, ValueError) as error:
        return {"error": error.__class__.__name__}


def _ssdp(address: str, timeout: float) -> list[dict[str, str]]:
    message = (
        "M-SEARCH * HTTP/1.1\r\n"
        "HOST: 239.255.255.250:1900\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 2\r\n"
        "ST: ssdp:all\r\n\r\n"
    )
    found: list[dict[str, str]] = []
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        sock.settimeout(0.5)
        sock.sendto(message.encode("utf-8"), ("239.255.255.250", 1900))
        deadline = time.monotonic() + max(1.0, timeout)
        seen: set[tuple[str, str]] = set()
        while time.monotonic() < deadline:
            try:
                data, (source, _) = sock.recvfrom(MAX_RESPONSE_BYTES)
            except socket.timeout:
                continue
            except OSError:
                break
            if source != address:
                continue
            text = data.decode("utf-8", "replace")
            headers: dict[str, str] = {}
            for line in text.splitlines()[1:]:
                if ":" in line:
                    key, value = line.split(":", 1)
                    headers[key.strip().upper()] = value.strip()
            marker = (headers.get("ST", ""), headers.get("USN", ""))
            if marker in seen:
                continue
            seen.add(marker)
            found.append(
                {
                    "st": headers.get("ST", ""),
                    "usn": headers.get("USN", ""),
                    "server": headers.get("SERVER", ""),
                    "location": headers.get("LOCATION", ""),
                }
            )
    finally:
        sock.close()
    return found


def _mdns(address: str, timeout: float) -> dict[str, Any]:
    try:
        zeroconf = importlib.import_module("zeroconf")
    except ImportError:
        return {"available": False, "services": []}
    from zeroconf import ServiceBrowser, ServiceListener, Zeroconf

    services: list[dict[str, Any]] = []

    class Listener(ServiceListener):
        def add_service(self, zc, type_, name):
            info = zc.get_service_info(type_, name, timeout=1500)
            if info is None:
                return
            addresses = info.parsed_addresses()
            if address not in addresses:
                return
            services.append(
                {
                    "type": type_,
                    "name": name,
                    "server": info.server,
                    "addresses": addresses,
                }
            )

        def update_service(self, *args):
            pass

        def remove_service(self, *args):
            pass

    zc = Zeroconf()
    try:
        listener = Listener()
        for service in ("_http._tcp.local.", "_https._tcp.local.", "_mqtt._tcp.local."):
            ServiceBrowser(zc, service, listener)
        time.sleep(max(1.0, timeout))
    finally:
        zc.close()
    return {"available": True, "services": services}


def check_lan(address: str, timeout: float = 2.0) -> dict[str, Any]:
    if not is_private_ipv4(address):
        raise HinenError("The station address must be a private IPv4 address.")
    ports = {
        str(port): _port_open(address, port, timeout) for port in LOCAL_PORTS
    }
    http = {
        str(port): _http_details(address, port, timeout)
        for port in (80, 5000, 8000, 8080, 9000)
        if ports.get(str(port), False)
    }
    tls = {
        str(port): _tls_details(address, port, timeout)
        for port in (443, 8443, 8883)
        if ports.get(str(port), False)
    }
    try:
        ssdp = _ssdp(address, timeout)
    except OSError:
        ssdp = []
    try:
        mdns = _mdns(address, timeout)
    except Exception as error:  # noqa: BLE001 - discovery must fail closed
        mdns = {"available": False, "error": error.__class__.__name__}
    return {
        "address": address,
        "ports": ports,
        "http": http,
        "tls": tls,
        "ssdp": ssdp,
        "mdns": mdns,
    }


def ble_scan(timeout: float = 8.0) -> list[dict[str, Any]]:
    bleak = _require(
        "bleak",
        "Run with `uv run --with bleak ...` or install bleak.",
    )
    import asyncio

    async def scan():
        found: dict[str, dict[str, Any]] = {}

        def callback(device, advertisement):
            found[device.address] = {
                "name": advertisement.local_name or device.name or "",
                "address": device.address,
                "rssi": advertisement.rssi,
                "service_uuids": list(advertisement.service_uuids),
                "manufacturer_data": {
                    str(key): value.hex()
                    for key, value in advertisement.manufacturer_data.items()
                },
            }

        scanner = bleak.BleakScanner(callback, scanning_mode="active")
        await scanner.start()
        await asyncio.sleep(timeout)
        await scanner.stop()
        return list(found.values())

    return asyncio.run(scan())


def ble_gatt(address: str, timeout: float = 10.0) -> dict[str, Any]:
    bleak = _require(
        "bleak",
        "Run with `uv run --with bleak ...` or install bleak.",
    )
    import asyncio

    async def inspect():
        notifications: list[dict[str, Any]] = []
        services: list[dict[str, Any]] = []

        def notify_handler(characteristic, data):
            notifications.append(
                {
                    "uuid": str(characteristic.uuid),
                    "length": len(data),
                    "prefix": data[:24].hex(),
                }
            )

        client = bleak.BleakClient(address, timeout=timeout)
        await client.connect()
        try:
            for service in client.services:
                entry = {
                    "uuid": str(service.uuid),
                    "description": service.description,
                    "characteristics": [],
                }
                for characteristic in service.characteristics:
                    item = {
                        "uuid": str(characteristic.uuid),
                        "properties": list(characteristic.properties),
                    }
                    if "read" in characteristic.properties:
                        try:
                            value = await client.read_gatt_char(characteristic)
                            item["length"] = len(value)
                            item["prefix"] = value[:24].hex()
                        except Exception as error:
                            item["read_error"] = error.__class__.__name__
                    entry["characteristics"].append(item)
                    if "notify" in characteristic.properties:
                        try:
                            await client.start_notify(
                                characteristic, notify_handler
                            )
                        except Exception:
                            pass
                services.append(entry)
            await asyncio.sleep(min(5.0, timeout))
        finally:
            await client.disconnect()
        return {
            "address": address,
            "services": services,
            "notifications": notifications,
        }

    return asyncio.run(inspect())
