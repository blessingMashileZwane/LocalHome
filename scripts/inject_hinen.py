#!/usr/bin/env python3
"""Seed a Hinen PS300 profile and stage the Tuya local key (debug builds).

The profile contains the private address, Tuya product key/model, and Tuya
Virtual ID. The local key is never written to the profile; it is staged in the
app's private support directory so the debug app can import it into the Android
keystore and delete the staging file. Values are never printed.

    uv run --with tinytuya python3 scripts/inject_hinen.py --ip 192.168.1.50
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import socket
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from hinen_local import (  # noqa: E402
    DEFAULT_ENV_FILE,
    HinenDependencyError,
    HinenError,
    discover_tuya,
    load_device_id,
    load_local_key,
)
from inject_lanpass import adb, merge_string_preference  # noqa: E402
from local_net import is_private_ipv4  # noqa: E402

PACKAGE = "com.pyansofyan.localhome"
KEY = "flutter.hinen_profiles"
PROFILE_ID = "hinen-1"
PRODUCT_KEY_RE = re.compile(r"^[A-Za-z0-9]{16}$")
DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9]{20,22}$")


def existing_profiles(xml: bytes | None) -> str | None:
    if xml is None:
        return None
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return None
    for node in root.findall("string"):
        if node.get("name") == KEY and node.text:
            return node.text
    return None


def update_profiles(raw: str | None, profile: dict) -> list[dict]:
    profiles = json.loads(raw) if raw else []
    if not isinstance(profiles, list):
        raise ValueError("Hinen profile data is not a list")
    for index, item in enumerate(profiles):
        if not isinstance(item, dict):
            continue
        if item.get("id") == profile["id"] or item.get("address") == profile[
            "address"
        ]:
            profiles[index] = {**item, **profile}
            return profiles
    profiles.append(profile)
    return profiles


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ip", required=True, help="PS300 private IPv4")
    parser.add_argument("--name", default="Hinen PS300")
    parser.add_argument(
        "--product-key",
        default="YOURPRODUCTKEY00",
        help="Tuya product key (16 alphanumeric characters; default for this PS300)",
    )
    parser.add_argument("--model", default="PS3000")
    parser.add_argument("--id", default=PROFILE_ID)
    parser.add_argument("--package", default=PACKAGE)
    parser.add_argument("--device-id", default="")
    parser.add_argument("--bridge-url", default="")
    parser.add_argument("--env-file", default=str(DEFAULT_ENV_FILE))
    args = parser.parse_args()

    if not is_private_ipv4(args.ip):
        print("Refusing: --ip must be a private RFC1918 address.", file=sys.stderr)
        return 2
    product_key = args.product_key.strip()
    if product_key and not PRODUCT_KEY_RE.fullmatch(product_key):
        print(
            "Refusing: --product-key must be 16 alphanumeric characters or empty.",
            file=sys.stderr,
        )
        return 2

    env_file = pathlib.Path(args.env_file).expanduser()
    try:
        local_key = load_local_key(env_file)
    except HinenError as error:
        print(str(error), file=sys.stderr)
        return 2

    device_id = args.device_id.strip() or load_device_id(env_file) or ""
    if not device_id:
        try:
            devices = discover_tuya(timeout=6.0)
            match = next(
                (device for device in devices if device.address == args.ip),
                None,
            )
            if match is not None:
                device_id = match.device_id
                if not product_key:
                    product_key = match.product_key
        except HinenDependencyError:
            print(
                "tinytuya is not installed; pass --device-id or run with "
                "`uv run --with tinytuya`.",
                file=sys.stderr,
            )
        except HinenError as error:
            print(f"Tuya discovery failed: {error}", file=sys.stderr)
    if device_id and not DEVICE_ID_RE.fullmatch(device_id):
        print(
            "Refusing: --device-id must be 20-22 alphanumeric characters.",
            file=sys.stderr,
        )
        return 2

    bridge_url = args.bridge_url.strip()
    if not bridge_url:
        try:
            host_ip = socket.gethostbyname(socket.gethostname())
        except OSError:
            host_ip = ""
        if is_private_ipv4(host_ip):
            bridge_url = f"http://{host_ip}:8092"

    profile = {
        "id": args.id,
        "name": args.name.strip() or "Hinen PS300",
        "address": args.ip,
        "productKey": product_key,
        "model": args.model.strip(),
        "deviceId": device_id,
        "bridgeUrl": bridge_url,
    }
    pref_file = (
        f"/data/data/{args.package}/shared_prefs/"
        "FlutterSharedPreferences.xml"
    )

    adb("shell", "am", "force-stop", args.package)
    result = adb("shell", "run-as", args.package, "cat", pref_file)
    xml = result.stdout if result.returncode == 0 else None
    raw = existing_profiles(xml)

    try:
        profiles = update_profiles(raw, profile)
        new_xml = merge_string_preference(xml, KEY, json.dumps(profiles))
    except (json.JSONDecodeError, ValueError) as error:
        print(f"Could not update the Hinen profile store: {error}", file=sys.stderr)
        return 1

    adb(
        "shell",
        "run-as",
        args.package,
        "mkdir",
        "-p",
        f"/data/data/{args.package}/shared_prefs",
    )
    write = adb(
        "shell",
        f"run-as {args.package} sh -c 'cat > {pref_file}'",
        input=new_xml,
    )
    if write.returncode != 0:
        print(
            "Could not write the Hinen profile. Is the debug LocalHome app "
            "installed?",
            file=sys.stderr,
        )
        return 1

    if local_key:
        key_stage = f"/data/data/{args.package}/files/localhome-hinen.env"
        adb(
            "shell",
            "run-as",
            args.package,
            "mkdir",
            "-p",
            f"/data/data/{args.package}/files",
        )
        payload = (
            f"HINEN_LOCAL_KEY={local_key}\n"
            f"HINEN_PROFILE_ID={profile['id']}\n"
        ).encode("utf-8")
        write = adb(
            "shell",
            f"run-as {args.package} sh -c 'cat > {key_stage}'",
            input=payload,
        )
        if write.returncode != 0:
            print("Could not stage the Hinen local key for the app.", file=sys.stderr)
            return 1

    adb(
        "shell",
        "monkey",
        "-p",
        args.package,
        "-c",
        "android.intent.category.LAUNCHER",
        "1",
    )

    print(
        f"Seeded Hinen profile '{profile['name']}' at {profile['address']} "
        f"(product {profile['productKey'] or 'not set'}, "
        f"device {device_id[:6] + '…' if device_id else 'not discovered'})."
    )
    if bridge_url:
        print(
            f"Host bridge seeded as {bridge_url}; start web/hinen_web.py "
            "with --bind 0.0.0.0."
        )
    else:
        print("No host bridge URL was seeded; direct LAN only.")
    if local_key:
        print(
            f"Local key staged for {args.package} (length {len(local_key)}, not "
            "printed); the app imports it into the Android keystore on launch."
        )
    else:
        print(
            "No HINEN_LOCAL_KEY was found; the app profile is seeded but live "
            "status stays unavailable."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
