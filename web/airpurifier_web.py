"""Local web panel and JSON API for a Xiaomi air purifier.

Serves a browser panel on localhost and talks to the purifier over UDP 54321
with the local miIO/MIoT client. No Xiaomi cloud endpoint is used. The token
is read per request from the panel or a protected env file and is never logged
or returned.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import pathlib
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from local_net import is_private_ipv4
from miio_airpurifier import (
    MiiOError,
    MiiOTimeoutError,
    MiioClient,
    discover,
)

STATIC_DIR = pathlib.Path(__file__).resolve().parent / "static"
MAX_BODY_BYTES = 8192
MAX_HISTORY_READINGS = 500
HISTORY_MAX_BYTES = 20 * 1024 * 1024
TOKEN_ENV_FILE = pathlib.Path(
    os.environ.get(
        "MIIO_ENV_FILE",
        str(pathlib.Path.home() / ".config" / "localhome-miio.env"),
    )
)
HISTORY_FILE = pathlib.Path(
    os.environ.get(
        "LOCALHOME_PURIFIER_HISTORY",
        str(pathlib.Path.home() / "LocalHome-purifier" / "readings.jsonl"),
    )
)
HISTORY_LOCK = threading.Lock()


def _read_token_file(path: pathlib.Path) -> str | None:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name.strip() == "MIIO_TOKEN":
            return value.strip()
    return None


def _token_configured() -> bool:
    return bool(
        os.environ.get("MIIO_TOKEN") or _read_token_file(TOKEN_ENV_FILE)
    )


def _resolve_token(body: dict) -> str:
    value = body.get("token")
    if value is None:
        value = os.environ.get("MIIO_TOKEN") or _read_token_file(TOKEN_ENV_FILE)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(
            "A purifier token is required. Add MIIO_TOKEN to "
            f"{TOKEN_ENV_FILE} or enter it in the panel."
        )
    return value.strip()


def _validate_ip(value: object) -> str:
    if not isinstance(value, str) or not is_private_ipv4(value):
        raise ValueError("purifier must be a private IPv4 address")
    return value


def _client(body: dict) -> MiioClient:
    address = _validate_ip(body.get("ip"))
    token = _resolve_token(body)
    return MiioClient(address, token)


def _record_history(status) -> None:
    values = {
        name: value
        for name, value in status.values.items()
        if not name.startswith("filter_rfid")
    }
    line = json.dumps(
        {"ts": status.received_at, "model": status.info.model, "values": values},
        separators=(",", ":"),
    )
    try:
        HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        with HISTORY_LOCK:
            try:
                if (
                    HISTORY_FILE.exists()
                    and HISTORY_FILE.stat().st_size > HISTORY_MAX_BYTES
                ):
                    HISTORY_FILE.replace(HISTORY_FILE.with_suffix(".jsonl.1"))
            except OSError:
                pass
            descriptor = os.open(
                HISTORY_FILE,
                os.O_APPEND | os.O_CREAT | os.O_WRONLY,
                0o600,
            )
            try:
                os.write(descriptor, (line + "\n").encode("utf-8"))
            finally:
                os.close(descriptor)
    except OSError:
        # History is best-effort; a status read must still succeed.
        pass


def _read_history(limit: int) -> list[dict]:
    limit = max(1, min(limit, MAX_HISTORY_READINGS))
    try:
        with HISTORY_LOCK:
            lines = HISTORY_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    readings: list[dict] = []
    for line in lines[-limit:]:
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            readings.append(parsed)
    return readings


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalHomePurifierWeb/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(
            f"[{time.strftime('%H:%M:%S')}] {self.address_string()} {fmt % args}\n"
        )

    def do_GET(self) -> None:  # noqa: N802
        try:
            self._route_get()
        except (MiiOError, ValueError) as error:
            self._json(400, {"error": str(error)})
        except Exception:
            traceback.print_exc()
            self._json(500, {"error": "internal error"})

    def _route_get(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path == "/":
            self._serve_file("airpurifier/index.html")
            return
        if parsed.path == "/purifier/app.js":
            self._serve_file("airpurifier/app.js")
            return
        if parsed.path == "/purifier/style.css":
            self._serve_file("airpurifier/style.css")
            return
        if parsed.path == "/api/health":
            self._json(200, {"ok": True})
            return
        if parsed.path == "/api/purifier/config":
            self._json(200, {"token_configured": _token_configured()})
            return
        if parsed.path == "/api/purifier/discover":
            self._discover(parse_qs(parsed.query))
            return
        if parsed.path == "/api/purifier/history":
            self._history(parse_qs(parsed.query))
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
            if path == "/api/purifier/info":
                self._info(body)
            elif path == "/api/purifier/status":
                self._status(body)
            elif path == "/api/purifier/set":
                self._set(body)
            elif path == "/api/purifier/filter/reset":
                self._filter_reset(body)
            else:
                self._json(404, {"error": "not found"})
        except MiiOTimeoutError as error:
            self._json(504, {"error": str(error)})
        except (MiiOError, ValueError, KeyError) as error:
            self._json(400, {"error": str(error)})
        except Exception:
            traceback.print_exc()
            self._json(500, {"error": "internal error"})

    def _info(self, body: dict) -> None:
        client = _client(body)
        try:
            self._json(200, client.connect().as_dict())
        finally:
            client.close()

    def _status(self, body: dict) -> None:
        client = _client(body)
        try:
            client.connect()
            status = client.read_status()
            _record_history(status)
            self._json(200, status.as_dict())
        finally:
            client.close()

    def _set(self, body: dict) -> None:
        name = body.get("name")
        if not isinstance(name, str) or not name:
            raise ValueError("a control name is required")
        if "value" not in body:
            raise ValueError("a control value is required")
        client = _client(body)
        try:
            client.connect()
            result = client.set_property(name, body["value"])
            _record_history(result.status)
            self._json(200, result.as_dict())
        finally:
            client.close()

    def _filter_reset(self, body: dict) -> None:
        if body.get("confirm") is not True:
            raise ValueError("filter reset requires confirm=true")
        client = _client(body)
        try:
            client.connect()
            result = client.reset_filter()
            _record_history(result.status)
            self._json(200, result.as_dict())
        finally:
            client.close()

    def _discover(self, query: dict) -> None:
        try:
            timeout = float((query.get("timeout") or ["3"])[0])
        except ValueError as error:
            raise ValueError("timeout must be a number") from error
        addresses = discover(timeout=max(1.0, min(timeout, 10.0)))
        self._json(
            200, {"devices": [{"address": address} for address in addresses]}
        )

    def _history(self, query: dict) -> None:
        try:
            limit = int((query.get("limit") or ["100"])[0])
        except ValueError as error:
            raise ValueError("limit must be a number") from error
        self._json(200, {"readings": _read_history(limit)})

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
    parser.add_argument("--port", type=int, default=8091, help="listen port")
    args = parser.parse_args()
    panel_dir = STATIC_DIR / "airpurifier"
    if not (panel_dir / "index.html").is_file():
        print(f"missing panel files under {panel_dir}", file=sys.stderr)
        return 1
    if not (pathlib.Path(__file__).resolve().parent / "miio_airpurifier.py").is_file():
        print("missing miio_airpurifier.py next to this server", file=sys.stderr)
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
        f"LocalHome purifier panel: http://{args.bind}:{args.port}/ "
        f"(purifier traffic stays on the private LAN)",
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
