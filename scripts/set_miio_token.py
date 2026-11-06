#!/usr/bin/env python3
"""Import a Xiaomi miIO token from a protected file or stdin.

The token is validated and merged into ~/.config/localhome-miio.env (mode 600)
without being printed. Keep the source file outside the repository and delete
it after importing.

    install -m 600 /dev/null ~/.config/localhome-miio-token.txt
    # paste only the purifier token into that file
    scripts/set_miio_token.py
    rm ~/.config/localhome-miio-token.txt
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

from miio_token_from_cloud import write_token_file

DEFAULT_SOURCE = pathlib.Path.home() / ".config" / "localhome-miio-token.txt"
DEFAULT_ENV = pathlib.Path.home() / ".config" / "localhome-miio.env"
TOKEN_RE = re.compile(r"(?<![0-9a-fA-F])([0-9a-fA-F]{32})(?![0-9a-fA-F])")


def read_token(text: str) -> str:
    matches = TOKEN_RE.findall(text)
    if not matches:
        raise ValueError("No 32-hex token found in the input.")
    unique = list(dict.fromkeys(match.lower() for match in matches))
    if len(unique) != 1:
        raise ValueError(
            "More than one token found; put only the purifier token in the file."
        )
    return unique[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--from",
        dest="source",
        default=str(DEFAULT_SOURCE),
        help=(
            "token file (default: ~/.config/localhome-miio-token.txt; "
            "use '-' for stdin)"
        ),
    )
    parser.add_argument(
        "--env-file",
        default=str(DEFAULT_ENV),
        help="MIIO env file (default: ~/.config/localhome-miio.env)",
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
        token = read_token(text)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2

    env_path = pathlib.Path(args.env_file).expanduser()
    try:
        write_token_file(env_path, token)
    except OSError as error:
        print(f"Could not write {env_path}: {error}", file=sys.stderr)
        return 1

    print(
        f"Token read from {source_label} (length {len(token)}); "
        f"written to {env_path} (mode 600)."
    )
    print("The token was not printed. Next:")
    print("  python3 web/airpurifier_web.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
