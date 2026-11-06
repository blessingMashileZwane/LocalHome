"""Authenticated local V380/HiMost IOT session and white-light control.

The session is intentionally small: LANPASS over TCP 8089, AES-CBC encrypted
method requests, and the floodlight DPIDs confirmed on the target firmware.
No vendor cloud endpoint is used.
"""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
import socket
import struct
import time
from dataclasses import dataclass

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from local_net import is_private_ipv4

CMD_IOT = 0x38030818
METHOD_LANPASS = 196870
METHOD_GET_PROPERTIES = 197376
METHOD_SET_PROPERTIES = 197378

DPID_LIGHT_SW = 0x00050100
DPID_LIGHT_STATUS = 0x00050101
DPID_LIGHT_SENSITIVITY = 0x00050103

LIGHT_SWITCH = {"auto": 0, "on": 1, "off": 2}
LIGHT_MODE = {0: "auto", 1: "on", 2: "off"}
LIGHT_STATUS = {0: "not_supported", 1: "on", 2: "off", 3: "auto"}

STATIC_KEY = bytes.fromhex(
    "363ae5281638cf84969a634e9f966a98b573d1ffe937b277d1f1d62b38748ae5"
)


class LanError(Exception):
    """A local camera protocol or validation error."""


def _pkcs7_pad(data: bytes) -> bytes:
    padder = padding.PKCS7(128).padder()
    return padder.update(data) + padder.finalize()


def _pkcs7_unpad(data: bytes) -> bytes:
    try:
        unpadder = padding.PKCS7(128).unpadder()
        return unpadder.update(data) + unpadder.finalize()
    except ValueError as error:
        raise LanError("camera sent invalid encrypted padding") from error


def _encrypt(key32: bytes, plain: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key32[:16]), modes.CBC(key32[16:32]))
    encryptor = cipher.encryptor()
    return encryptor.update(_pkcs7_pad(plain)) + encryptor.finalize()


def _decrypt(key32: bytes, cipher_text: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key32[:16]), modes.CBC(key32[16:32]))
    decryptor = cipher.decryptor()
    return _pkcs7_unpad(decryptor.update(cipher_text) + decryptor.finalize())


class LanIotSession:
    def __init__(self, ip: str, password: str, port: int = 8089, timeout: float = 5.0):
        self.ip = ip
        self.password = password
        self.port = port
        self.timeout = timeout
        self._socket: socket.socket | None = None
        self.key32 = STATIC_KEY
        self.sid = 0
        self._request_id = 0

    def __enter__(self) -> "LanIotSession":
        self.connect()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def connect(self) -> None:
        if not is_private_ipv4(self.ip):
            raise LanError("camera address must be a private IPv4 address")
        if not self.password:
            raise LanError("camera LAN password is required")
        try:
            sock = socket.create_connection((self.ip, self.port), timeout=self.timeout)
        except OSError as error:
            raise LanError(f"could not reach the camera on port {self.port}") from error
        sock.settimeout(self.timeout)
        self._socket = sock

        private = X25519PrivateKey.generate()
        public = private.public_key().public_bytes_raw()
        magic = secrets.randbelow(126) + 1
        pkm = bytes(byte ^ magic for byte in public)
        challenge = hashlib.sha256(pkm + self.password.encode()).digest()
        now = int(time.time())
        message = {
            "id": self._next_request_id(),
            "method_id": METHOD_LANPASS,
            "chn": 1,
            "ts": now,
            "params": {
                "act": 1,
                "verify": {
                    "cKM": base64.b64encode(pkm).decode(),
                    "cS": base64.b64encode(challenge).decode(),
                    "tz": 200,
                    "ts": now,
                },
            },
        }
        body = _encrypt(STATIC_KEY, json.dumps(message, separators=(",", ":")).encode())
        self._write_frame(body, secure=2, sid=0, magic=magic)
        reply = self._read_frame()
        if reply["secure"] == 2:
            plain = _decrypt(STATIC_KEY, reply["body"])
        else:
            plain = reply["body"]
        parsed = self._parse_json(plain)
        code = (parsed.get("result") or {}).get("code")
        if code != 1000:
            raise LanError(f"camera rejected the LAN password ({code})")
        verify = ((parsed.get("data") or {}).get("verify") or {})
        dk_b64 = verify.get("dK")
        ds_b64 = verify.get("dS")
        sid = verify.get("sid")
        if not dk_b64 or not ds_b64 or not isinstance(sid, int):
            raise LanError("camera reply is missing session keys")
        dk = base64.b64decode(dk_b64)
        if len(dk) != 32:
            raise LanError("camera session key has an invalid length")
        if base64.b64encode(hashlib.sha256(dk).digest()).decode() != ds_b64:
            raise LanError("camera session key failed verification")
        self.key32 = private.exchange(X25519PublicKey.from_public_bytes(dk))
        self.sid = sid

    def request(self, method: int, params: dict) -> dict:
        if self._socket is None:
            raise LanError("the local session is not connected")
        message = {
            "id": self._next_request_id(),
            "method_id": method,
            "chn": 1,
            "ts": int(time.time()),
            "params": params,
        }
        body = _encrypt(self.key32, json.dumps(message, separators=(",", ":")).encode())
        self._write_frame(body, secure=2, sid=self.sid, magic=0)
        reply = self._read_frame()
        if reply["secure"] == 2:
            plain = _decrypt(self.key32, reply["body"])
        else:
            plain = reply["body"]
        parsed = self._parse_json(plain)
        code = (parsed.get("result") or {}).get("code")
        if code != 1000:
            raise LanError(f"camera rejected the request ({code})")
        return parsed

    def get_properties(self, dpids: list[int]) -> dict:
        return self.request(METHOD_GET_PROPERTIES, {"dplist": dpids})

    def set_properties(self, entries: list[tuple[int, object]]) -> dict:
        return self.request(
            METHOD_SET_PROPERTIES,
            {
                "dplist": [
                    {"dpid": dpid, "value": value} for dpid, value in entries
                ]
            },
        )

    def close(self) -> None:
        if self._socket is not None:
            try:
                self._socket.close()
            finally:
                self._socket = None

    def _next_request_id(self) -> int:
        self._request_id = (self._request_id + 1) & 0x7FFFFF
        if self._request_id == 0:
            self._request_id = 1
        return self._request_id

    def _write_frame(self, body: bytes, *, secure: int, sid: int, magic: int) -> None:
        if self._socket is None:
            raise LanError("the local session is not connected")
        header = (
            struct.pack("<I", CMD_IOT)
            + bytes([1, secure, sid & 0xFF, magic & 0xFF])
            + struct.pack("<II", 0, len(body))
        )
        try:
            self._socket.sendall(header + body)
        except OSError as error:
            raise LanError("the camera closed the local session") from error

    def _read_frame(self) -> dict:
        if self._socket is None:
            raise LanError("the local session is not connected")
        header = self._read_exact(16)
        command, _version, secure, _sid, _magic = struct.unpack("<IBBBB", header[:8])
        (length,) = struct.unpack("<I", header[12:16])
        if command != CMD_IOT or length > 200_000:
            raise LanError("camera sent an invalid frame")
        body = self._read_exact(length) if length else b""
        return {"secure": secure, "body": body}

    def _read_exact(self, size: int) -> bytes:
        if self._socket is None:
            raise LanError("the local session is not connected")
        data = bytearray()
        deadline = time.monotonic() + self.timeout
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise LanError("timed out waiting for the camera")
            self._socket.settimeout(remaining)
            try:
                chunk = self._socket.recv(size - len(data))
            except OSError as error:
                raise LanError("the camera closed the local session") from error
            if not chunk:
                raise LanError("the camera closed the local session")
            data.extend(chunk)
        return bytes(data)

    @staticmethod
    def _parse_json(data: bytes) -> dict:
        try:
            parsed = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise LanError("camera sent an invalid JSON reply") from error
        if not isinstance(parsed, dict):
            raise LanError("camera sent an invalid reply")
        return parsed


@dataclass
class LightState:
    mode: str | None
    status: str | None
    is_on: bool | None

    def as_dict(self) -> dict:
        return {
            "mode": self.mode,
            "status": self.status,
            "is_on": self.is_on,
        }


def _properties(reply: dict) -> dict[int, dict]:
    data = reply.get("data") or {}
    entries = data.get("dplist_result")
    if not isinstance(entries, list):
        raise LanError("camera reply is missing light properties")
    return {
        entry["dpid"]: entry
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("dpid"), int)
    }


def _value(properties: dict[int, dict], dpid: int):
    entry = properties.get(dpid)
    if not entry or entry.get("code") != 1000:
        return None
    return entry.get("value")


def read_light(session: LanIotSession) -> LightState:
    properties = _properties(
        session.get_properties([DPID_LIGHT_SW, DPID_LIGHT_STATUS])
    )
    switch = _value(properties, DPID_LIGHT_SW)
    status = _value(properties, DPID_LIGHT_STATUS)
    if not isinstance(switch, int):
        raise LanError("this camera does not expose white light control")
    return LightState(
        mode=LIGHT_MODE.get(switch),
        status=LIGHT_STATUS.get(status) if isinstance(status, int) else None,
        is_on=(status == 1) if isinstance(status, int) else None,
    )


def set_light(session: LanIotSession, mode: str) -> LightState:
    if mode not in LIGHT_SWITCH:
        raise LanError("light mode must be on, off, or auto")
    reply = session.set_properties([(DPID_LIGHT_SW, LIGHT_SWITCH[mode])])
    properties = _properties(reply)
    entry = properties.get(DPID_LIGHT_SW) or {}
    code = entry.get("code")
    if code is not None and code != 1000:
        raise LanError(f"camera rejected the light setting ({code})")
    return read_light(session)
