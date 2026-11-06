#!/usr/bin/env python3
"""Migrate/seed camera LAN passwords into LocalHome's debug profile store.

Reads profiles from the previous package when it is still installed, otherwise
from the new package, updates the LAN passwords from the protected env file, and
writes the result under the new package. Values are never printed.
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import xml.etree.ElementTree as ET

PACKAGE = "com.pyansofyan.localhome"
OLD_PACKAGE = "com.pyansofyan.himost_camera"
ENV_FILE = pathlib.Path.home() / ".config" / "v380decoder-test.env"
KEY = "flutter.camera_profiles"
PREF_FILE = f"/data/data/{PACKAGE}/shared_prefs/FlutterSharedPreferences.xml"
OLD_PREF_FILE = (
    f"/data/data/{OLD_PACKAGE}/shared_prefs/FlutterSharedPreferences.xml"
)
PASSWORD_KEY_PREFIX = "V380_LANPASS_"


def adb(*args: str, input: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["adb", *args],
        input=input,
        capture_output=True,
        check=False,
    )


def read_env() -> dict[str, str]:
    values: dict[str, str] = {}
    if ENV_FILE.is_file():
        for line in ENV_FILE.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                values[key] = value
    return values


def read_pref_xml(package: str, pref_file: str) -> bytes | None:
    result = adb("shell", "run-as", package, "cat", pref_file)
    if result.returncode != 0 or not result.stdout:
        return None
    return result.stdout


def profiles_from_xml(data: bytes | None) -> str | None:
    if data is None:
        return None
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return None
    for node in root.findall("string"):
        if node.get("name") == KEY and node.text:
            return node.text
    return None


def merge_string_preference(data: bytes | None, key: str, text: str) -> bytes:
    """Update one SharedPreferences string key without dropping other keys."""
    if data is None:
        root = ET.Element("map")
    else:
        try:
            root = ET.fromstring(data)
        except ET.ParseError as error:
            raise ValueError(
                "the existing preference store is not valid XML"
            ) from error
        if root.tag != "map":
            raise ValueError("the existing preference store is not a map")

    node = None
    for child in root.findall("string"):
        if child.get("name") == key:
            node = child
            break
    if node is None:
        node = ET.SubElement(root, "string", name=key)
    node.text = text
    return (
        b"<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n"
        + ET.tostring(root, encoding="utf-8")
    )


def merge_camera_profiles(data: bytes | None, profiles: list) -> bytes:
    """Update the camera profile key without dropping other preferences."""
    return merge_string_preference(data, KEY, json.dumps(profiles))


def password_key(address: str) -> str:
    suffix = address.rsplit(".", 1)[-1] if address else ""
    return f"{PASSWORD_KEY_PREFIX}{suffix}"


def update_profiles(raw: str, env: dict[str, str]) -> tuple[list, int]:
    profiles = json.loads(raw)
    if not isinstance(profiles, list):
        raise ValueError("profile data is not a list")
    updated = 0
    for profile in profiles:
        if not isinstance(profile, dict):
            continue
        password = env.get(password_key(profile.get("address", "")))
        if password:
            profile["lanPassword"] = password
            updated += 1
    return profiles, updated


def main() -> int:
    env = read_env()
    for package in (PACKAGE, OLD_PACKAGE):
        adb("shell", "am", "force-stop", package)

    old_xml = read_pref_xml(OLD_PACKAGE, OLD_PREF_FILE)
    new_xml = read_pref_xml(PACKAGE, PREF_FILE)

    raw = profiles_from_xml(old_xml)
    source = "previous app"
    if raw is None:
        raw = profiles_from_xml(new_xml)
        source = "LocalHome app"
    if raw is None:
        print(
            "Could not read a camera profile store. Launch the app once, then retry."
        )
        return 1

    try:
        profiles, updated = update_profiles(raw, passwords)
    except (json.JSONDecodeError, ValueError):
        print("Could not parse the saved camera profiles.")
        return 1

    try:
        data = merge_camera_profiles(new_xml, profiles)
    except ValueError as error:
        print(f"Could not update the LocalHome preference store: {error}.")
        return 1

    adb(
        "shell",
        "run-as",
        PACKAGE,
        "mkdir",
        "-p",
        f"/data/data/{PACKAGE}/shared_prefs",
    )
    write = adb(
        "shell",
        f"run-as {PACKAGE} sh -c 'cat > {PREF_FILE}'",
        input=data,
    )
    if write.returncode != 0:
        print("Could not write the LocalHome profile store.")
        return 1

    print(
        f"Migrated {len(profiles)} camera profile(s) from the {source} and "
        f"injected LAN passwords for {updated}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
