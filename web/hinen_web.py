"""Local web panel for the Hinen PS300 (Tuya LAN 3.4).

Discovery and read-only data-point reads. No control, no runtime cloud. The
local key is read from the request or the protected env file and is never logged
or returned.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import mimetypes
import pathlib
import re
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from hinen_local import (
    HinenDependencyError,
    HinenError,
    ble_gatt,
    ble_scan,
    discover_tuya,
    load_device_id,
    load_local_key,
    check_lan,
    read_tuya_status,
    write_tuya_dp,
)
from local_net import is_private_ipv4

STATIC_DIR = pathlib.Path(__file__).resolve().parent / "static"
MAX_BODY_BYTES = 8192
BLE_ADDRESS_RE = re.compile(r"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$")
DEVICE_CACHE: dict[str, str] = {}
DEVICE_LOCK = threading.Lock()


def _validate_ip(value: object) -> str:
    if not isinstance(value, str) or not is_private_ipv4(value):
        raise ValueError("station must be a private IPv4 address")
    return value


def _resolve_key(body: dict) -> str:
    value = body.get("key")
    if not isinstance(value, str) or not value.strip():
        value = load_local_key()
    if not value or not isinstance(value, str):
        raise ValueError(
            "A Tuya local key is required. Add HINEN_LOCAL_KEY to "
            "~/.config/localhome-hinen.env or enter it in the panel."
        )
    value = value.strip()
    if len(value) != 16:
        raise ValueError("The Tuya local key must be 16 characters.")
    return value


def _remember(devices) -> None:
    with DEVICE_LOCK:
        for device in devices:
            DEVICE_CACHE[device.address] = device.device_id


def _device_id(address: str) -> str | None:
    with DEVICE_LOCK:
        cached = DEVICE_CACHE.get(address)
    if cached:
        return cached
    configured = load_device_id()
    if configured:
        return configured
    devices = discover_tuya(timeout=6.0)
    _remember(devices)
    match = next((device for device in devices if device.address == address), None)
    return match.device_id if match else None


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalHomeHinenWeb/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(
            f"[{time.strftime('%H:%M:%S')}] {self.address_string()} {fmt % args}\n"
        )

    def do_GET(self) -> None:  # noqa: N802
        try:
            self._route_get()
        except (HinenError, ValueError) as error:
            self._json(400, {"error": str(error)})
        except Exception:
            traceback.print_exc()
            self._json(500, {"error": "internal error"})

    def _route_get(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path == "/":
            self._serve_file("hinen/index.html")
            return
        if parsed.path == "/hinen/app.js":
            self._serve_file("hinen/app.js")
            return
        if parsed.path == "/hinen/style.css":
            self._serve_file("hinen/style.css")
            return
        if parsed.path == "/api/health":
            self._json(200, {"ok": True})
            return
        if parsed.path == "/api/hinen/config":
            self._json(
                200,
                {
                    "local_key_configured": load_local_key() is not None,
                    "tinytuya_available": importlib.util.find_spec("tinytuya")
                    is not None,
                    "bleak_available": importlib.util.find_spec("bleak")
                    is not None,
                },
            )
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        origin = self.headers.get("Origin")
        host = self.headers.get("Host")
        if origin and host and origin not in (f"http://{host}", f"https://{host}"):
            self._json(403, {"error": "cross-origin request rejected"})
            return
        try:
            body = self._read_json()
            path = urlsplit(self.path).path
            if path == "/api/hinen/discover":
                self._discover(body)
            elif path == "/api/hinen/check":
                self._check(body)
            elif path == "/api/hinen/status":
                self._status(body)
            elif path == "/api/hinen/write":
                self._write(body)
            elif path == "/api/hinen/ble/scan":
                self._ble_scan(body)
            elif path == "/api/hinen/ble/gatt":
                self._ble_gatt(body)
            else:
                self._json(404, {"error": "not found"})
        except HinenDependencyError as error:
            self._json(503, {"error": str(error)})
        except (HinenError, ValueError, KeyError) as error:
            self._json(400, {"error": str(error)})
        except Exception:
            traceback.print_exc()
            self._json(500, {"error": "internal error"})

    def _discover(self, body: dict) -> None:
        timeout = body.get("timeout", 6.0)
        try:
            timeout = float(timeout)
        except (TypeError, ValueError) as error:
            raise ValueError("timeout must be a number") from error
        devices = discover_tuya(timeout=max(3.0, min(timeout, 18.0)))
        _remember(devices)
        self._json(200, {"devices": [device.as_dict() for device in devices]})

    def _check(self, body: dict) -> None:
        address = _validate_ip(body.get("ip"))
        self._json(200, check_lan(address))

    def _status(self, body: dict) -> None:
        address = _validate_ip(body.get("ip"))
        key = _resolve_key(body)
        device_id = _device_id(address)
        if not device_id:
            raise ValueError(
                "The station was not found. Run discovery again or check the "
                "private address."
            )
        status = read_tuya_status(address, key, device_id=device_id)
        self._json(
            200,
            {
                "address": address,
                "device_id_prefix": f"{device_id[:6]}…",
                "dps": status["dps"],
                "received_at": status["received_at"],
            },
        )

    def _write(self, body: dict) -> None:
        address = _validate_ip(body.get("ip"))
        try:
            dp = int(body.get("dp"))
        except (TypeError, ValueError) as error:
            raise ValueError("dp must be an integer") from error
        value = body.get("value")
        if not isinstance(value, (bool, int)):
            raise ValueError("value must be a boolean or integer")
        key = _resolve_key(body)
        device_id = _device_id(address)
        if not device_id:
            raise ValueError(
                "The station was not found. Run discovery again or check the "
                "private address."
            )
        status = write_tuya_dp(
            address,
            key,
            dp,
            value,
            device_id=device_id,
        )
        self._json(
            200,
            {
                "address": address,
                "dp": dp,
                "value": value,
                "dps": status["dps"],
                "received_at": status["received_at"],
            },
        )

    def _ble_scan(self, body: dict) -> None:
        try:
            timeout = float(body.get("timeout", 8.0))
        except (TypeError, ValueError) as error:
            raise ValueError("timeout must be a number") from error
        self._json(
            200,
            {
                "devices": ble_scan(timeout=max(3.0, min(timeout, 20.0))),
                "note": (
                    "The host scans only advertisements. The station may "
                    "use Wi-Fi/cloud; BLE can be provisioning-only."
                ),
            },
        )

    def _ble_gatt(self, body: dict) -> None:
        address = body.get("address")
        if not isinstance(address, str) or not BLE_ADDRESS_RE.fullmatch(address):
            raise ValueError("a valid BLE address is required")
        try:
            timeout = float(body.get("timeout", 10.0))
        except (TypeError, ValueError) as error:
            raise ValueError("timeout must be a number") from error
        self._json(
            200,
            ble_gatt(address, timeout=max(3.0, min(timeout, 20.0))),
        )

    def _serve_file(self, name: str) -> None:
        path = (STATIC_DIR / name).resolve()
        if STATIC_DIR not in path.parents or not path.is_file():
            self._json(404, {"error": "not found"})
            return
        content_type = (
            mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        )
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ValueError("missing request body")
        try:
            length = int(raw_length)
        except ValueError as error:
            raise ValueError("invalid request length") from error
        if length < 0 or length > MAX_BODY_BYTES:
            raise ValueError("request body is too large")
        content_type = self.headers.get("Content-Type", "")
        if not content_type.lower().startswith("application/json"):
            raise ValueError("expected application/json")
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("invalid JSON body") from error
        if not isinstance(parsed, dict):
            raise ValueError("JSON body must be an object")
        return parsed

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bind", default="127.0.0.1", help="listen address")
    parser.add_argument("--port", type=int, default=8092, help="listen port")
    args = parser.parse_args()
    panel_dir = STATIC_DIR / "hinen"
    if not (panel_dir / "index.html").is_file():
        print(f"missing panel files under {panel_dir}", file=sys.stderr)
        return 1
    if not (pathlib.Path(__file__).resolve().parent / "hinen_local.py").is_file():
        print("missing hinen_local.py next to this server", file=sys.stderr)
        return 1
    try:
        server = ThreadingHTTPServer((args.bind, args.port), Handler)
    except OSError as error:
        print(
            f"could not bind {args.bind}:{args.port}: {error}. "
            "Stop the other panel or use --port <port>.",
            file=sys.stderr,
        )
        return 1
    if args.bind not in ("127.0.0.1", "localhost", "::1"):
        print(
            "WARNING: listening on a non-loopback address; only use this on a "
            "trusted private network.",
            file=sys.stderr,
        )
    print(
        f"LocalHome Hinen panel: http://{args.bind}:{args.port}/ "
        f"(discovery and read-only Tuya LAN)",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
