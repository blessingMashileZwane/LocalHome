#!/usr/bin/env python3
"""Read a device-QR password (field 8) from an image or `HSC^...` string,
verify it as the camera LAN password, and save it to the protected env file
without printing the value.

    python scripts/save_lanpass_from_qr.py --image shot.png --ip 192.168.1.102
    python scripts/save_lanpass_from_qr.py --text 'HSC^{...}' --ip 192.168.1.102
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web"))

from v380_lan import LanError, LanIotSession  # noqa: E402


def qr_text(args) -> str:
    if args.text:
        return args.text.strip()
    if not args.image:
        raise SystemExit("need --image or --text")
    import numpy as np
    import zxingcpp
    from PIL import Image

    img = Image.open(args.image).convert("RGB")
    results = zxingcpp.read_barcodes(np.array(img))
    if not results:
        raise SystemExit("no QR found in image")
    return results[0].text


def env_path(name: str) -> Path:
    return Path.home() / ".config" / f"{name}.env"


def save(key: str, value: str, path: Path) -> None:
    lines = []
    if path.is_file():
        lines = [l for l in path.read_text().splitlines() if not l.startswith(key + "=")]
    lines.append(f"{key}={value}")
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o600)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--image")
    ap.add_argument("--text")
    ap.add_argument("--ip", required=True)
    ap.add_argument("--env", default="v380decoder-test")
    ap.add_argument("--field", default="8")
    args = ap.parse_args()

    text = qr_text(args)
    if not text.startswith("HSC^"):
        print("not an HSC^ device QR")
        return 1
    try:
        data = json.loads(text.split("^", 1)[1])
    except Exception as exc:
        print("QR JSON parse failed:", exc)
        return 1
    pw = data.get(args.field, "")
    if not pw:
        print("field missing")
        return 1

    ok = True
    try:
        with LanIotSession(args.ip, pw, timeout=2):
            pass
    except LanError as exc:
        print("LANPASS error:", type(exc).__name__)
        ok = False
    suffix = args.ip.rsplit(".", 1)[-1]
    path = env_path(args.env)
    if ok:
        save(f"V380_LANPASS_{suffix}", pw, path)
        print(f"LANPASS OK; saved V380_LANPASS_{suffix} (len {len(pw)})")
    else:
        save(f"V380_DEVICE_PASSWORD_{suffix}", pw, path)
        print(f"LANPASS FAILED; saved V380_DEVICE_PASSWORD_{suffix} (len {len(pw)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
