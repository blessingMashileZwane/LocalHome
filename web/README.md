# LocalHome — Web Test Panels

Local browser panels for LocalHome modules, used to test features without
rebuilding the Android app. They talk directly to the device on the private
LAN; there is no cloud service or local media server.

## Camera panel

### What it does

- White floodlight **ON / AUTO / OFF** (`SET_PROPERTIES` over the authenticated
  IOT session on TCP 8089).
- **PTZ** pan/tilt nudges over the camera's local ONVIF endpoint on TCP 8899.
- **Snapshot** and **live MJPEG preview** from the camera's RTSP endpoint on
  TCP 554, converted locally by `ffmpeg`.
- **Local DVR**: record the live RTSP stream to the panel host, list clips,
  play and scrub them in the browser.

### Local DVR

Start recording from the panel's **Local DVR** card. The server runs `ffmpeg`
against the camera's live RTSP stream, writes 5-minute MP4 segments (H.264
video copied, audio transcoded to AAC), and serves them with byte-range
support for browser scrubbing.

- Default directory: `~/LocalHome-recordings`; override with
  `LOCALHOME_DVR_DIR`.
- Endpoints: `POST /api/dvr/start` (`{ip,path}`), `POST /api/dvr/stop`,
  `GET /api/dvr/list`, `GET /api/dvr/file?name=...`.
- The camera's existing SD-card recordings are not exposed by its ONVIF or
  RTSP services; the Local DVR records new footage from the live stream.

## Xiaomi air purifier panel

The purifier panel talks local miIO/MIoT over UDP 54321 and needs the device
token. It does not use a Xiaomi account or cloud endpoint. Controls are
model-aware: the target 4 Compact (`xiaomi.airp.cpa4`) hides the fan, anion,
humidity, temperature, and temperature-unit controls and uses its mode 0–2 /
favorite 0–14 ranges. The 4 and 4 Pro maps are also supported.

- **Status**: power, mode, PM2.5, filter life/used/left, motor speed, favorite
  level, screen brightness on the Compact; the 4/4 Pro add fan, anion,
  temperature, humidity, and (4 Pro) PM10/air-quality.
- **Controls**: model-aware power, mode, favorite level, child lock, buzzer,
  screen brightness; the 4/4 Pro add fan level, anion, and temperature unit.
  Every write is read back, retrying briefly for the Compact's one-request
  apply lag.
- **Filter**: life/used/left and a reset action behind an explicit confirmation.
- **Discovery**: unauthenticated hello broadcast, plus a unicast `/24` sweep in
  the client module; manual IP entry is primary.
- **History**: successful status reads are appended to
  `~/LocalHome-purifier/readings.jsonl` (override with
  `LOCALHOME_PURIFIER_HISTORY`). The file is mode 0600, contains no token,
  MAC, device ID, or RFID tag, and rotates to `.jsonl.1` above 20 MB.

Endpoints:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | Purifier panel. |
| GET | `/api/health` | Liveness. |
| GET | `/api/purifier/config` | Whether a server-side token is configured (no value). |
| GET | `/api/purifier/discover?timeout=3` | Broadcast hello; returns private addresses only. |
| GET | `/api/purifier/history?limit=100` | Last N local readings. |
| POST | `/api/purifier/info` | `{ip,token?}` → model and firmware. |
| POST | `/api/purifier/status` | `{ip,token?}` → status and unsupported properties. |
| POST | `/api/purifier/set` | `{ip,token?,name,value}` → fresh status with `applied`. |
| POST | `/api/purifier/filter/reset` | `{ip,token?,confirm:true}` → fresh status. |

Token handling: use the panel field (not stored by the browser) or put
`MIIO_TOKEN=<32 hex>` in `~/.config/localhome-miio.env` (mode 600; override
with `MIIO_ENV_FILE`). The token is never logged or returned. If you don't have
the token, run the optional one-time bootstrap:
`uv run --with micloud python3 scripts/miio_token_from_cloud.py`. If that
returns `MiCloudAccessDenied`, it is a global login failure (not a region
issue); use a supported account export for 2FA/captcha accounts.

## Hinen PS3000 host bridge

The Hinen panel is the LocalHome host bridge for the PS3000. The station is a
**Tuya LAN 3.4** device on TCP 6668; reads and confirmed writes use the Tuya
local key on the host. The station's app uses Wi-Fi/cloud; the panel never calls
that cloud. The direct phone Tuya read is refused by the station, so the Android
app uses this bridge.

- **Discovery**: Tuya UDP scan (through `tinytuya`); private addresses only;
  returns the product key, protocol version, active state, encryption flag, and
  a device-id prefix (not the full id).
- **LAN check**: local services, HTTP/TLS, SSDP, optional mDNS. On the
  target PS3000 only TCP 6668 is reachable; there is no HTTP/TLS/SSDP/mDNS.
- **Status DPs**: DP 1 battery, 6 AC, 7 DC, 26 device standby, 105 AC charging
  power limit, 106 vehicle current, 107 Fast Charging (read-only locally), 108
  keystroke sound, 109 AC standby, 110 screen-off, 113 light mode, 116 packs,
  117 reported output. DP 25 beep is not reported; 111/112 remain unmapped.
  The 32°C Smart Life temperature is cloud-only; DP 105 is the AC charging
  limit.
- **Writes**: allowlisted to DPs 6, 7, 25, 26, 105, 106, 108, 109, 110, 113;
  each write is verified by a station read-back. Fast Charging (DP 107) is
  read-only locally. No UPS, charge-limit, P-boost, schedule, or firmware write.
- **BLE**: optional advertisement/GATT reading. The station exposes no local
  Bluetooth control; BLE is treated as provisioning-only.
- **Local key**: enter it in the panel for a one-off read, or put
  `HINEN_LOCAL_KEY=<16 chars>` in `~/.config/localhome-hinen.env` (mode 600;
  `HINEN_DEVICE_ID` is optional). The key is never stored by the browser,
  logged, or returned. Import it from a protected drop file with
  `python3 scripts/set_hinen_key.py` (paste only the key into
  `~/.config/localhome-hinen-key.txt` first). The key was imported once through
  the Smart Life path; no runtime cloud call is made.
- **History**: none yet; raw DP reads are not persisted. Solar, car-charge, and
  AC-energy history are Smart Life cloud statistics, not local DPs.

Endpoints:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | Hinen discovery/status/write panel. |
| GET | `/api/health` | Liveness. |
| GET | `/api/hinen/config` | `{local_key_configured,tinytuya_available,bleak_available}` only. |
| POST | `/api/hinen/discover` | Tuya UDP scan; private addresses only. |
| POST | `/api/hinen/check` | `{ip}` → ports, HTTP/TLS, SSDP, mDNS. |
| POST | `/api/hinen/status` | `{ip,key?}` → raw DPs; 400 without a key. |
| POST | `/api/hinen/write` | `{ip,key?,dp,value}` → allowlisted write + read-back. |
| POST | `/api/hinen/ble/scan` | BLE advertisements (optional `bleak`). |
| POST | `/api/hinen/ble/gatt` | Read-only GATT read (optional `bleak`). |

The server binds `127.0.0.1:8092` by default; for the Android host bridge bind
`0.0.0.0:8092` on a trusted private LAN. It rejects cross-origin POSTs, caps the
request body, validates private IPv4, and never logs request bodies or keys.
Writes are restricted to the confirmed DPs and are read back; Fast Charging
(DP 107) is read-only locally.

```sh
uv run --with tinytuya python3 web/hinen_web.py --bind 0.0.0.0 --port 8092
```

For a stable bridge that survives terminal exits and reboots, install the
provided systemd user service:

```sh
cp scripts/localhome-hinen.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now localhome-hinen.service
loginctl enable-linger "$USER"
```

The service uses `Restart=always`. If the host IP changes, update the app bridge
URL or reserve the host address in DHCP.

The Tuya LAN link is encrypted with the local key but does not provide a
verified server identity. Use it only on a trusted private network.

## Run

From the repository root:

```sh
# Camera panel, port 8090
python3 web/camera_web.py

# Air purifier panel, port 8091
python3 web/airpurifier_web.py

# Hinen PS3000 host bridge, port 8092
uv run --with tinytuya python3 web/hinen_web.py --bind 0.0.0.0 --port 8092
```

Then open <http://127.0.0.1:8090/>, <http://127.0.0.1:8091/>, or
<http://127.0.0.1:8092/>.

Enter the camera's private IPv4 address, its LAN password (QR field 8, used only
for light control), and the RTSP path (default `/live/ch00_0`). The password is
sent to the local server per request and is never written to disk or logged.

For the purifier, enter its private IPv4 address and either the device token or
leave the field blank when `MIIO_TOKEN` is configured on the host. The token is
sent per request and is never stored by the browser.

For the PS300, use **Find Tuya device** or enter the private IPv4 address, then
**Check LAN**. **Read status** needs the 16-character Tuya local key (one-off in
the field, or `HINEN_LOCAL_KEY` in the mode-600 env file). The key is sent per
request and is never stored by the browser or logged. Allowlisted writes use
the confirmed DP IDs and are read back; they are intended for the LocalHome app
on the same private LAN, not the public internet.

To access a panel from another device on the same private network:

```sh
python3 web/camera_web.py --bind 0.0.0.0 --port 8090
python3 web/airpurifier_web.py --bind 0.0.0.0 --port 8091
uv run --with tinytuya python3 web/hinen_web.py --bind 0.0.0.0 --port 8092
```

Only do that on a trusted private network. The panels have no user accounts and
no transport encryption.

## Requirements

- Python 3.11+ with `cryptography` (already used by the repository helpers).
- `ffmpeg` on `PATH` for camera snapshot/live preview.
- The camera's RTSP endpoint reachable on TCP 554. The target firmware serves
  it without RTSP authentication.
- The purifier reachable on UDP 54321 on the same private LAN.
- `tinytuya` for the Hinen panel's Tuya discovery, status, and allowlisted
  writes; install on demand with `uv run --with tinytuya`. `bleak`/`zeroconf` are
  optional for the BLE and mDNS checks.
- The PS3000 reachable on TCP 6668 on the same private LAN.

## Security notes

- The servers bind to `127.0.0.1` by default.
- Camera, purifier, and Hinen addresses must be RFC1918 private IPv4 addresses.
- RTSP paths are validated before being passed to `ffmpeg`; no shell is used.
- The LAN password is not stored by the browser (`localStorage` holds only the
  camera IP and RTSP path, plus the purifier/Hinen IP) and is not logged by the
  server.
- The purifier token and the Hinen Tuya local key are not stored by the browser
  and are not logged or returned. Prefer the mode-600 env file over typing them
  into the panel.
- The underlying camera protocol is legacy and does not provide authenticated
  transport encryption. Use this only on a trusted LAN.
- miIO token encryption is not authenticated transport encryption either; a
  device token does not make the LAN link safe on an untrusted network.
- Tuya LAN is encrypted with the local key but does not provide a verified
  server identity. The Hinen bridge exposes allowlisted writes only; every
  write is read back. No UPS, charge-limit, P-boost, schedule, or firmware
  write exists.
