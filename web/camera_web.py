#!/usr/bin/env python3
"""Local web control panel for HiMost/V380 cameras.

Serves a small browser UI for the white floodlight, ONVIF PTZ nudges, snapshots,
and an RTSP-to-MJPEG live preview. It binds to localhost by default and only
accepts private IPv4 camera addresses.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from v380_lan import (
    LIGHT_SWITCH,
    LanError,
    LanIotSession,
    is_private_ipv4,
    read_light,
    set_light,
)
from v380_onvif import OnvifError, OnvifPtz

STATIC_DIR = Path(__file__).resolve().parent / "static"
MAX_BODY_BYTES = 8192
RTSP_PATH_RE = re.compile(r"^/[A-Za-z0-9._~!$&'()*+,;=:@/-]*$")
PTZ_CLIENTS: dict[str, OnvifPtz] = {}
PTZ_LOCK = threading.Lock()

DVR_DIR = Path(
    os.environ.get("LOCALHOME_DVR_DIR", str(Path.home() / "LocalHome-recordings"))
)
DVR_NAME_RE = re.compile(r"^rec-\d{8}-\d{6}\.mp4$")
DVR_LOCK = threading.Lock()
DVR_PROCESS: subprocess.Popen | None = None


def _validate_ip(value: object) -> str:
    if not isinstance(value, str) or not is_private_ipv4(value):
        raise ValueError("camera must be a private IPv4 address")
    return value


def _validate_path(value: object) -> str:
    if (
        not isinstance(value, str)
        or not RTSP_PATH_RE.fullmatch(value)
        or value.startswith("//")
        or "/../" in value
        or value.endswith("/..")
    ):
        raise ValueError("RTSP path is not valid")
    return value


def _rtsp_url(ip: str, path: str) -> str:
    return f"rtsp://{ip}:554{path}"


def _ptz(ip: str) -> OnvifPtz:
    with PTZ_LOCK:
        client = PTZ_CLIENTS.get(ip)
        if client is None:
            client = OnvifPtz(ip)
            PTZ_CLIENTS[ip] = client
        return client


def _drop_ptz(ip: str) -> None:
    with PTZ_LOCK:
        PTZ_CLIENTS.pop(ip, None)


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalHomeWeb/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(
            f"[{time.strftime('%H:%M:%S')}] {self.address_string()} {fmt % args}\n"
        )

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlsplit(self.path)
        if parsed.path == "/":
            self._serve_file("index.html")
            return
        if parsed.path in ("/style.css", "/app.js"):
            self._serve_file(parsed.path.lstrip("/"))
            return
        if parsed.path == "/api/health":
            self._json(200, {"ok": True})
            return
        if parsed.path == "/api/snapshot":
            self._snapshot(parse_qs(parsed.query))
            return
        if parsed.path == "/api/stream":
            self._stream(parse_qs(parsed.query))
            return
        if parsed.path == "/api/dvr/list":
            self._dvr_list()
            return
        if parsed.path == "/api/dvr/file":
            self._dvr_file(parse_qs(parsed.query))
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
            if path == "/api/light/status":
                self._light_status(body)
            elif path == "/api/light/set":
                self._light_set(body)
            elif path == "/api/ptz/start":
                self._ptz_start(body)
            elif path == "/api/ptz/stop":
                self._ptz_stop(body)
            elif path == "/api/ptz/nudge":
                self._ptz_nudge(body)
            elif path == "/api/dvr/start":
                self._dvr_start(body)
            elif path == "/api/dvr/stop":
                self._dvr_stop(body)
            else:
                self._json(404, {"error": "not found"})
        except (LanError, OnvifError, ValueError, KeyError) as error:
            self._json(400, {"error": str(error)})
        except subprocess.TimeoutExpired:
            self._json(504, {"error": "camera media request timed out"})
        except Exception:
            traceback.print_exc()
            self._json(500, {"error": "internal error"})

    def _serve_file(self, name: str) -> None:
        path = (STATIC_DIR / name).resolve()
        if STATIC_DIR not in path.parents or not path.is_file():
            self._json(404, {"error": "not found"})
            return
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _light_status(self, body: dict) -> None:
        ip = _validate_ip(body.get("ip"))
        password = body.get("password")
        if not isinstance(password, str) or not password:
            raise ValueError("camera LAN password is required")
        with LanIotSession(ip, password) as session:
            state = read_light(session)
        self._json(200, state.as_dict())

    def _light_set(self, body: dict) -> None:
        ip = _validate_ip(body.get("ip"))
        password = body.get("password")
        mode = body.get("mode")
        if not isinstance(password, str) or not password:
            raise ValueError("camera LAN password is required")
        if mode not in LIGHT_SWITCH:
            raise ValueError("light mode must be on, off, or auto")
        with LanIotSession(ip, password) as session:
            state = set_light(session, mode)
        self._json(200, state.as_dict())

    def _ptz_start(self, body: dict) -> None:
        ip = _validate_ip(body.get("ip"))
        direction = body.get("direction")
        try:
            _ptz(ip).start(str(direction))
        except OnvifError:
            _drop_ptz(ip)
            raise
        self._json(200, {"ok": True})

    def _ptz_stop(self, body: dict) -> None:
        ip = _validate_ip(body.get("ip"))
        try:
            _ptz(ip).stop()
        except OnvifError:
            _drop_ptz(ip)
            raise
        self._json(200, {"ok": True})

    def _ptz_nudge(self, body: dict) -> None:
        ip = _validate_ip(body.get("ip"))
        direction = body.get("direction")
        duration = body.get("duration", 0.4)
        try:
            _ptz(ip).nudge(str(direction), float(duration))
        except OnvifError:
            _drop_ptz(ip)
            raise
        self._json(200, {"ok": True})

    def _snapshot(self, query: dict[str, list[str]]) -> None:
        try:
            ip = _validate_ip((query.get("ip") or [""])[0])
            path = _validate_path((query.get("path") or ["/live/ch00_0"])[0])
        except ValueError as error:
            self._json(400, {"error": str(error)})
            return
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-rtsp_transport",
            "tcp",
            "-i",
            _rtsp_url(ip, path),
            "-an",
            "-frames:v",
            "1",
            "-f",
            "image2pipe",
            "-vcodec",
            "mjpeg",
            "-q:v",
            "4",
            "-",
        ]
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                timeout=12,
                check=False,
            )
        except FileNotFoundError:
            self._json(503, {"error": "ffmpeg is not installed"})
            return
        if result.returncode != 0 or not result.stdout:
            message = result.stderr.decode("utf-8", "replace").strip()
            self._json(502, {"error": message[-400:] or "snapshot failed"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(result.stdout)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(result.stdout)

    def _stream(self, query: dict[str, list[str]]) -> None:
        try:
            ip = _validate_ip((query.get("ip") or [""])[0])
            path = _validate_path((query.get("path") or ["/live/ch00_0"])[0])
        except ValueError as error:
            self._json(400, {"error": str(error)})
            return
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-rtsp_transport",
            "tcp",
            "-i",
            _rtsp_url(ip, path),
            "-an",
            "-vf",
            "scale=960:-2",
            "-r",
            "10",
            "-q:v",
            "5",
            "-f",
            "mpjpeg",
            "-",
        ]
        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
        except FileNotFoundError:
            self._json(503, {"error": "ffmpeg is not installed"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=ffmpeg")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            assert process.stdout is not None
            while True:
                chunk = process.stdout.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            process.kill()
            process.wait()

    def _dvr_start(self, body: dict) -> None:
        global DVR_PROCESS
        ip = _validate_ip(body.get("ip"))
        path = _validate_path(body.get("path") or "/live/ch00_0")
        with DVR_LOCK:
            if DVR_PROCESS is not None and DVR_PROCESS.poll() is None:
                raise ValueError("a DVR recording is already running")
            DVR_DIR.mkdir(parents=True, exist_ok=True)
            output = str(DVR_DIR / "rec-%Y%m%d-%H%M%S.mp4")
            command = [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-rtsp_transport",
                "tcp",
                "-i",
                _rtsp_url(ip, path),
                "-c:v",
                "copy",
                "-c:a",
                "aac",
                "-b:a",
                "64k",
                "-f",
                "segment",
                "-segment_time",
                "300",
                "-segment_format",
                "mp4",
                "-reset_timestamps",
                "1",
                "-strftime",
                "1",
                "-movflags",
                "+faststart",
                output,
            ]
            try:
                DVR_PROCESS = subprocess.Popen(
                    command,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except FileNotFoundError as error:
                raise ValueError("ffmpeg is not installed") from error
        self._json(200, {"ok": True, "dir": str(DVR_DIR)})

    def _dvr_stop(self, body: dict) -> None:
        global DVR_PROCESS
        with DVR_LOCK:
            process = DVR_PROCESS
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        with DVR_LOCK:
            DVR_PROCESS = None
        self._json(
            200,
            {"ok": True, "running": False, "recordings": self._dvr_entries()},
        )

    def _dvr_entries(self) -> list[dict]:
        if not DVR_DIR.is_dir():
            return []
        entries = []
        for path in DVR_DIR.glob("rec-*.mp4"):
            try:
                stat = path.stat()
            except OSError:
                continue
            entries.append(
                {
                    "name": path.name,
                    "size": stat.st_size,
                    "modified": int(stat.st_mtime),
                }
            )
        entries.sort(key=lambda item: item["modified"], reverse=True)
        return entries

    def _dvr_list(self) -> None:
        with DVR_LOCK:
            running = DVR_PROCESS is not None and DVR_PROCESS.poll() is None
        self._json(200, {"running": running, "recordings": self._dvr_entries()})

    def _dvr_file(self, query: dict[str, list[str]]) -> None:
        name = (query.get("name") or [""])[0]
        if not DVR_NAME_RE.fullmatch(name):
            self._json(400, {"error": "invalid recording name"})
            return
        path = (DVR_DIR / name).resolve()
        if DVR_DIR.resolve() not in path.parents or not path.is_file():
            self._json(404, {"error": "recording not found"})
            return
        size = path.stat().st_size
        start = 0
        end = size - 1
        status = 200
        range_header = self.headers.get("Range", "")
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
        if match:
            if match.group(1):
                start = int(match.group(1))
            if match.group(2):
                end = min(int(match.group(2)), size - 1)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            with path.open("rb") as handle:
                handle.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = handle.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

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
    parser.add_argument("--port", type=int, default=8090, help="listen port")
    args = parser.parse_args()
    if not STATIC_DIR.is_dir():
        print(f"missing static directory: {STATIC_DIR}", file=sys.stderr)
        return 1
    if not (Path(__file__).resolve().parent / "v380_lan.py").is_file():
        print("missing v380_lan.py next to this server", file=sys.stderr)
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
        f"LocalHome web panel: http://{args.bind}:{args.port}/ "
        f"(camera traffic stays on the private LAN)",
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
