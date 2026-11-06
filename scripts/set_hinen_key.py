#!/usr/bin/env python3
"""Import the Tuya local key from a protected file or stdin.

The key is validated and merged into ~/.config/localhome-hinen.env (mode 600)
without being printed. Keep the source file outside the repository and delete it
after importing.

    install -m 600 /dev/null ~/.config/localhome-hinen-key.txt
    # paste only the 16-character key into that file
    scripts/set_hinen_key.py
    rm ~/.config/localhome-hinen-key.txt

The key is a local credential for Tuya LAN TCP 6668, not a cloud token.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

DEFAULT_SOURCE = pathlib.Path.home() / ".config" / "localhome-hinen-key.txt"
DEFAULT_ENV = pathlib.Path.home() / ".config" / "localhome-hinen.env"
KEY_NAME = "HINEN_LOCAL_KEY"
DEVICE_ID_NAME = "HINEN_DEVICE_ID"


def read_key(text: str) -> str:
    candidates: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith(f"{KEY_NAME}="):
            value = line.split("=", 1)[1].strip()
            if len(value) != 16 or any(character.isspace() for character in value):
                raise ValueError(f"{KEY_NAME} must be exactly 16 characters.")
            candidates.append(value)
            continue
        if len(line) == 16 and not any(character.isspace() for character in line):
            candidates.append(line)
    unique = list(dict.fromkeys(candidates))
    if not unique:
        raise ValueError("No 16-character Tuya local key found in the input.")
    if len(unique) != 1:
        raise ValueError(
            "More than one key found; put only the station's local key in the "
            "file."
        )
    return unique[0]


def read_device_id(text: str) -> str | None:
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith(f"{DEVICE_ID_NAME}="):
            value = line.split("=", 1)[1].strip()
            return value or None
    return None


def merge_env(existing: str, updates: dict[str, str]) -> str:
    keys = set(updates)
    lines = [
        line
        for line in existing.splitlines()
        if line.split("=", 1)[0].strip() not in keys
    ]
    for name, value in updates.items():
        lines.append(f"{name}={value}")
    return "\n".join(lines) + "\n"


def write_env_file(path: pathlib.Path, updates: dict[str, str]) -> None:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        existing = path.read_text(encoding="utf-8")
    except OSError:
        existing = ""
    data = merge_env(existing, updates).encode("utf-8")
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--from",
        dest="source",
        default=str(DEFAULT_SOURCE),
        help=(
            "key file (default: ~/.config/localhome-hinen-key.txt; "
            "use '-' for stdin)"
        ),
    )
    parser.add_argument(
        "--env-file",
        default=str(DEFAULT_ENV),
        help="Hinen env file (default: ~/.config/localhome-hinen.env)",
    )
    parser.add_argument(
        "--device-id",
        help="optional Tuya device id (also accepted as HINEN_DEVICE_ID= in the file)",
    )
    args = parser.parse_args()

    try:
        if args.source == "-":
            text = sys.stdin.read()
            source_label = "stdin"
        else:
            path = pathlib.Path(args.source).expanduser()
            text = path.read_text(encoding="utf-8")
            source_label = str(path)
        key = read_key(text)
        device_id = args.device_id or read_device_id(text)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2

    updates = {KEY_NAME: key}
    if device_id:
        updates[DEVICE_ID_NAME] = device_id.strip()

    env_path = pathlib.Path(args.env_file).expanduser()
    try:
        write_env_file(env_path, updates)
    except OSError as error:
        print(f"Could not write {env_path}: {error}", file=sys.stderr)
        return 1

    print(
        f"Local key read from {source_label} (length {len(key)}); "
        f"written to {env_path} (mode 600)."
    )
    if device_id:
        print(f"Device id prefix: {device_id[:6]}…")
    print("The key was not printed. Next:")
    print("  uv run --with tinytuya python3 web/hinen_web.py --bind 0.0.0.0 --port 8092")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
