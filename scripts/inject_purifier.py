#!/usr/bin/env python3
"""Seed a LocalHome purifier profile and import the saved token (debug builds).

Reads MIIO_TOKEN from the protected env file, verifies it against the purifier,
writes the purifier profile into the debug app's shared preferences, and stages
a debug token file. The app imports it into the Android keystore on launch and
deletes the staging file. The token is never printed.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from inject_lanpass import adb, merge_string_preference  # noqa: E402
from local_net import is_private_ipv4  # noqa: E402
from miio_airpurifier import MiiOError, MiioClient  # noqa: E402

PACKAGE = "com.pyansofyan.localhome"
KEY = "flutter.airpurifier_profiles"
PROFILE_ID = "purifier-1"
TOKEN_ENV = pathlib.Path.home() / ".config" / "localhome-miio.env"


def read_token(env_file: pathlib.Path) -> str | None:
    try:
        lines = env_file.expanduser().read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith("MIIO_TOKEN="):
            value = line.split("=", 1)[1].strip()
            if len(value) == 32 and all(
                character in "0123456789abcdefABCDEF" for character in value
            ):
                return value
    return None


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
        raise ValueError("purifier profile data is not a list")
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
    parser.add_argument("--ip", required=True, help="purifier private IPv4")
    parser.add_argument("--name", default="Air purifier")
    parser.add_argument("--id", default=PROFILE_ID)
    parser.add_argument("--package", default=PACKAGE)
    parser.add_argument("--env-file", default=str(TOKEN_ENV))
    args = parser.parse_args()

    if not is_private_ipv4(args.ip):
        print(
            "Refusing: --ip must be a private RFC1918 address.",
            file=sys.stderr,
        )
        return 2

    token = read_token(pathlib.Path(args.env_file))
    if not token:
        print(
            f"No MIIO_TOKEN in {args.env_file}; run scripts/set_miio_token.py "
            "first.",
            file=sys.stderr,
        )
        return 2

    try:
        client = MiioClient(args.ip, token, timeout=5)
        info = client.connect()
        client.close()
    except MiiOError as error:
        print(f"Token/host check failed: {error}", file=sys.stderr)
        return 1

    profile = {
        "id": args.id,
        "name": args.name,
        "address": args.ip,
        "modelId": info.model,
    }
    pref_file = (
        f"/data/data/{args.package}/shared_prefs/"
        "FlutterSharedPreferences.xml"
    )
    token_stage = f"/data/data/{args.package}/files/localhome-miio.env"

    adb("shell", "am", "force-stop", args.package)
    result = adb("shell", "run-as", args.package, "cat", pref_file)
    xml = result.stdout if result.returncode == 0 else None
    raw = existing_profiles(xml)

    try:
        profiles = update_profiles(raw, profile)
        new_xml = merge_string_preference(xml, KEY, json.dumps(profiles))
    except (json.JSONDecodeError, ValueError) as error:
        print(f"Could not update the purifier profile store: {error}", file=sys.stderr)
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
            "Could not write the purifier profile. Is the debug LocalHome app "
            "installed?",
            file=sys.stderr,
        )
        return 1

    adb(
        "shell",
        "run-as",
        args.package,
        "mkdir",
        "-p",
        f"/data/data/{args.package}/files",
    )
    payload = (
        f"MIIO_TOKEN={token}\nMIIO_PROFILE_ID={profile['id']}\n"
    ).encode("utf-8")
    write = adb(
        "shell",
        f"run-as {args.package} sh -c 'cat > {token_stage}'",
        input=payload,
    )
    if write.returncode != 0:
        print("Could not stage the token for the app.", file=sys.stderr)
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
        f"Seeded purifier '{profile['name']}' at {profile['address']} "
        f"({info.model})."
    )
    print(
        f"Token staged for {args.package} (length {len(token)}, not printed); "
        "the app imports it into the Android keystore on launch."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
