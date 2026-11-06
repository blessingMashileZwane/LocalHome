#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <private-ipv4> <device-id> <camera-username> --allow-insecure-camera-protocol [password-env-file]" >&2
  echo "Password file defaults to V380_PASSWORD_FILE or ~/.config/v380decoder-test.env." >&2
}

if [[ $# -lt 4 || $# -gt 5 ]]; then
  usage
  exit 2
fi

camera_ip=$1
device_id=$2
username=$3
acknowledgement=$4
password_env_file=${5:-${V380_PASSWORD_FILE:-"$HOME/.config/v380decoder-test.env"}}
image=${V380DECODER_IMAGE:-v380decoder:local-test}

if [[ "$acknowledgement" != "--allow-insecure-camera-protocol" ]]; then
  echo "Explicitly acknowledge the legacy camera protocol with --allow-insecure-camera-protocol." >&2
  exit 2
fi

if ! python3 - "$camera_ip" "$device_id" "$username" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv4Address(sys.argv[1])
except ipaddress.AddressValueError:
    print("Camera address must be a numeric IPv4 address.", file=sys.stderr)
    raise SystemExit(1)

private_ranges = (
    ipaddress.IPv4Network("10.0.0.0/8"),
    ipaddress.IPv4Network("172.16.0.0/12"),
    ipaddress.IPv4Network("192.168.0.0/16"),
)
if not any(address in network for network in private_ranges):
    print("Camera address must be within an RFC1918 private IPv4 range.", file=sys.stderr)
    raise SystemExit(1)

try:
    device_id = int(sys.argv[2], 10)
except ValueError:
    print("Device ID must be a decimal integer.", file=sys.stderr)
    raise SystemExit(1)
if not 1 <= device_id <= 2147483647:
    print("Device ID is outside the supported range.", file=sys.stderr)
    raise SystemExit(1)

try:
    username = sys.argv[3].encode("ascii")
except UnicodeEncodeError:
    print("Camera username must contain ASCII characters only.", file=sys.stderr)
    raise SystemExit(1)
if not 1 <= len(username) <= 32:
    print("Camera username must be 1-32 ASCII bytes.", file=sys.stderr)
    raise SystemExit(1)
PY
then
  exit 2
fi

if [[ ! -f "$password_env_file" || -L "$password_env_file" ]]; then
  echo "Password env file must be a regular, non-symlink file." >&2
  exit 2
fi
if [[ "$(stat -c '%u' "$password_env_file")" != "$(id -u)" ]]; then
  echo "Password env file must be owned by the current user." >&2
  exit 2
fi
if [[ "$(stat -c '%a' "$password_env_file")" != "600" ]]; then
  echo "Password env file must have mode 600; use chmod 600 on it." >&2
  exit 2
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "Docker image '$image' not found; build it with: docker build -t '$image' ." >&2
  exit 2
fi

exec docker run --rm --network host --env-file "$password_env_file" "$image" \
  --id "$device_id" \
  --username "$username" \
  --ip "$camera_ip" \
  --port 8800 \
  --source lan \
  --allow-insecure-camera-protocol
