#!/usr/bin/env python3
"""One-time Xiaomi cloud token bootstrap for LocalHome.

This is an explicit credential-acquisition step, not a runtime dependency. It
logs in to the user's Xiaomi cloud account, finds the purifier, and writes only
`MIIO_TOKEN=<32 hex>` to ~/.config/localhome-miio.env (mode 600). The token is
never printed. The password is prompted locally and is never stored.

`micloud` cannot complete a captcha or 2FA challenge. If the login is rejected
with `MiCloudAccessDenied`, the account likely has 2FA/captcha enabled; use a
QR-capable Xiaomi token helper instead.

Run it with the optional dependency:

    uv run --with micloud python3 scripts/miio_token_from_cloud.py

The normal local path is still to paste an existing token. Use this helper only
when the token is not available from Mi Home data.
"""

from __future__ import annotations

import argparse
import getpass
import os
import pathlib
import re
import sys

DEFAULT_TOKEN_FILE = pathlib.Path.home() / ".config" / "localhome-miio.env"
DEFAULT_REGION = "de"
REGIONS = ("cn", "de", "us", "sg", "i2", "ru", "tw")
TOKEN_RE = re.compile(r"^[0-9a-fA-F]{32}$")


def merge_token(existing: str, token: str) -> str:
    """Replace MIIO_TOKEN while preserving other lines in the env file."""
    lines = [
        line
        for line in existing.splitlines()
        if not line.strip().startswith("MIIO_TOKEN=")
    ]
    lines.append(f"MIIO_TOKEN={token}")
    return "\n".join(lines) + "\n"


def write_token_file(path: pathlib.Path, token: str) -> None:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        existing = path.read_text(encoding="utf-8")
    except OSError:
        existing = ""
    data = merge_token(existing, token).encode("utf-8")
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        0o600,
    )
    try:
        os.write(descriptor, data)
    finally:
        os.close(descriptor)
    os.chmod(path, 0o600)


def is_purifier(device: dict) -> bool:
    name = str(device.get("name", "")).lower()
    model = str(device.get("model", "")).lower()
    return (
        "purifier" in name
        or model.startswith("zhimi.airp.")
        or model.startswith("zhimi.airpurifier.")
        or model.startswith("xiaomi.airp.")
    )


def select_candidates(devices: list[dict], needle: str | None) -> list[dict]:
    candidates = [device for device in devices if is_purifier(device)]
    if needle:
        text = needle.lower()
        candidates = [
            device
            for device in candidates
            if text in str(device.get("name", "")).lower()
            or text in str(device.get("model", "")).lower()
        ]
    return candidates


def describe(device: dict) -> str:
    name = device.get("name") or "(unnamed)"
    model = device.get("model") or "(unknown model)"
    local_ip = device.get("localip") or "no cached LAN IP"
    return f"{name} | {model} | {local_ip}"


def prompt_credentials() -> tuple[str, str]:
    username = os.environ.get("XIAOMI_USER", "").strip()
    password = os.environ.get("XIAOMI_PASS", "")
    if not username:
        username = input("Xiaomi account (email/phone): ").strip()
    if not password:
        password = getpass.getpass("Xiaomi password (not stored): ")
    return username, password


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--region",
        default=DEFAULT_REGION,
        choices=REGIONS,
        help="Xiaomi cloud region (default: de)",
    )
    parser.add_argument(
        "--device",
        help="case-insensitive name/model filter for the purifier",
    )
    parser.add_argument(
        "--token-file",
        default=str(DEFAULT_TOKEN_FILE),
        help="where to write MIIO_TOKEN (default: ~/.config/localhome-miio.env)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="list matching purifiers and exit without writing a token",
    )
    args = parser.parse_args()

    username, password = prompt_credentials()
    if not username or not password:
        print("A Xiaomi account and password are required.", file=sys.stderr)
        return 2

    try:
        from micloud import MiCloud
        from micloud.micloudexception import MiCloudAccessDenied
    except ImportError:
        print(
            "micloud is not installed. Run this script with:\n"
            "  uv run --with micloud python3 scripts/miio_token_from_cloud.py",
            file=sys.stderr,
        )
        return 2

    cloud = MiCloud(username, password)
    try:
        if not cloud.login():
            print(
                "Xiaomi cloud login failed. Check the exact Mi Home account "
                "identifier and password. The --region value does not affect "
                "this login step; it is only used to list devices afterward.",
                file=sys.stderr,
            )
            return 1
    except MiCloudAccessDenied:
        print(
            "Xiaomi cloud rejected the login (MiCloudAccessDenied).\n"
            "The region does not affect this step; it is only used to list "
            "devices after login. Check the exact Mi Home account identifier "
            "and password. If the account has 2FA or a captcha challenge, "
            "micloud cannot complete it; use a QR-capable Xiaomi token "
            "helper instead.",
            file=sys.stderr,
        )
        return 1
    except Exception as error:
        print(
            f"Xiaomi cloud login failed ({error.__class__.__name__}). Check the "
            "account/password/2FA; no credentials were stored.",
            file=sys.stderr,
        )
        return 1

    try:
        devices = cloud.get_devices(country=args.region)
    except Exception as error:
        print(
            f"Could not read the device list ({error.__class__.__name__}). "
            "Check the region and try again.",
            file=sys.stderr,
        )
        return 1
    if not devices:
        print(
            f"No devices returned from the '{args.region}' region. Try another "
            "--region (cn, de, us, sg, i2, ru, tw).",
            file=sys.stderr,
        )
        return 1

    candidates = select_candidates(devices, args.device)
    if not candidates:
        print(
            "No air purifier matched. Devices visible to this account:",
            file=sys.stderr,
        )
        for device in devices[:20]:
            print(f"  {describe(device)}", file=sys.stderr)
        print("Use --device <part of the name/model> to narrow it.", file=sys.stderr)
        return 1

    if len(candidates) > 1:
        print("Matching purifiers:")
        for index, device in enumerate(candidates, start=1):
            print(f"  {index}. {describe(device)}")
        if args.list:
            return 0
        raw = input(f"Select 1-{len(candidates)}: ").strip()
        if not raw.isdigit() or not 1 <= int(raw) <= len(candidates):
            print("Invalid selection.", file=sys.stderr)
            return 2
        device = candidates[int(raw) - 1]
    else:
        device = candidates[0]
        if args.list:
            print(f"  {describe(device)}")
            return 0

    token = device.get("token")
    if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
        print(
            "The selected device has no usable 32-hex token in the cloud response.",
            file=sys.stderr,
        )
        return 1

    path = pathlib.Path(args.token_file).expanduser()
    try:
        write_token_file(path, token)
    except OSError as error:
        print(f"Could not write {path}: {error}", file=sys.stderr)
        return 1

    print(f"Selected: {describe(device)}")
    print(f"Token written to {path} (mode 600). The token was not printed.")
    print("Next:")
    print("  python3 web/airpurifier_web.py")
    print(
        "Note: micloud may cache a cloud session; the Xiaomi password is not "
        "stored by this script."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
