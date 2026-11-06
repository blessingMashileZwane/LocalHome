# LocalHome — Implementation Guide

_Last updated: 2026-11-01_

> **Living document.** Update this file when behavior, architecture, protocols,
> or feature status changes. Record the change in `progress.md` too.

## Objective and non-goals

The current implementation covers the camera module, the Xiaomi purifier module,
and the Hinen PS3000 energy module. Camera and purifier traffic stays on the
private LAN; the Hinen direct phone path is refused by the station, so reads and
confirmed writes use the LocalHome host bridge on the private LAN. No vendor
account, cloud dispatch, relay, hostname, or public fallback address is used at
runtime.

Non-goals for the Hinen module:

- Claiming end-to-end cryptographic security for the Tuya LAN link; it has no
  verified server identity.
- UPS, charge/discharge limits, P-boost, schedules, firmware updates, or any
  write outside the confirmed DP allowlist.
- Replacing Smart Life cloud statistics (solar, car-charge, AC-energy history)
  that do not exist in the local DP set.
- Injecting controls into the proprietary Xiaomi Smart Hub card.

## Architecture

```
android-app/                  Flutter Android app
  lib/main.dart               app entry
  lib/home_shell.dart         Cameras / Xiaomi / Energy tabs
  lib/lan_iot.dart            LANPASS + encrypted IOT requests
  lib/lan_light.dart          floodlight DPIDs and mode mapping
  lib/light_controls.dart     ON / AUTO / OFF UI
  lib/onvif_ptz.dart          local ONVIF PTZ client
  lib/ptz_controls.dart       PTZ pad UI
  lib/lan_talkback.dart       LAN IOT talkback transport
  lib/talk_controls.dart      talk button UI
  lib/camera_profile.dart     saved camera profile
  lib/grid_viewer.dart        focused/grid viewer and overlays
  lib/local_net.dart          shared private-IPv4 guard
  lib/miio_packet.dart        miIO framing + token AES-CBC
  lib/airpurifier_status.dart miIO property maps, status, validation
  lib/miio_airpurifier.dart   UDP transport + purifier client
  lib/airpurifier_profile.dart saved purifier profile (no token)
  lib/token_store.dart        Android keystore token storage
  lib/airpurifier_home_page.dart purifier list and add/edit/remove
  lib/airpurifier_controls.dart  purifier status/control UI
  lib/debug_token_import.dart  debug-only token seed import
  lib/hinen_profile.dart       saved Hinen station profile (no key; bridge URL)
  lib/hinen_status.dart        nullable snapshot, capacity, mapped DPs
  lib/hinen_key_store.dart     Android Keystore local-key storage
  lib/hinen_host_bridge.dart   read/write host-bridge client
  lib/hinen_home_page.dart     Energy tab list and add/edit/remove
  lib/hinen_controls.dart      dashboard, controls, capacity, raw DPs
  lib/hinen_quick_controls.dart Flutter bridge to native notification/tile
  android/.../HinenQuickControls.kt  card, tile, sheet, camera deep links

web/                          Local browser panels
  camera_web.py               camera HTTP API + static server + MJPEG proxy
  airpurifier_web.py          purifier HTTP API + static server + history
  local_net.py                shared private-IPv4 guard
  miio_airpurifier.py         local miIO/MIoT client and model maps
  hinen_local.py              Tuya LAN discovery, read/write, LAN/BLE checks
  hinen_web.py                Hinen host bridge/API (8092)
  v380_lan.py                 shared IOT/LANPASS/light helpers
  v380_onvif.py               shared ONVIF PTZ helpers
  static/                     camera panel assets
  static/airpurifier/         purifier panel assets
  static/hinen/               Hinen discovery/read/write panel assets

scripts/                      Helper scripts
  install_app.sh              preferred USB build/install/seed/launch path
  inject_lanpass.py           merges LAN passwords into debug app profiles
  miio_token_from_cloud.py    optional one-time Xiaomi token bootstrap
  set_miio_token.py           imports a token from a protected drop file
  inject_purifier.py          seeds the purifier profile and debug token
  set_hinen_key.py            mode-600 Tuya local-key drop-file importer
  inject_hinen.py             seeds the debug Android Energy profile

tests/                        Python unit tests
  test_miio_airpurifier.py    packet, status, validation, read-back, action
  test_local_net.py           strict RFC1918 validation
  test_inject_lanpass.py      preference-map merge preserves other keys
  test_miio_token_from_cloud.py  token-file merge and purifier selection
  test_set_miio_token.py      drop-file token parsing and normalization
  test_inject_purifier.py     purifier profile seeding and merge
  test_hinen.py               Tuya discovery sanitization, key handling, status
  test_set_hinen_key.py       key import and mode-600 env writing
  test_inject_hinen.py        profile merge and preference preservation
```

The Android app and web panel share the same protocol definitions but have
separate implementations: Dart for the app, Python for the panel. Keep the
confirmations in this document in sync when either path changes.

## Transport and protocol summary

| Function | Transport | Notes |
| --- | --- | --- |
| Live video/audio | RTSP TCP 554 | `/live/ch00_0`; unauthenticated on the target firmware. |
| Light control / talkback | IOT TCP 8089 | LANPASS + AES-CBC encrypted requests. |
| PTZ | ONVIF HTTP TCP 8899 | Local SOAP; no cloud. |
| Purifier status/control | miIO/MIoT UDP 54321 | Token-derived AES-CBC; no cloud. |
| Hinen PS3000 discovery/status/write | Tuya LAN TCP 6668 | Encrypted with the 16-char local key; host-bridged reads and allowlisted writes; no cloud. |
| Legacy V380 path | TCP 8800 | Refused by the target; do not use. |

### LAN IOT session

1. Validate that the camera address is a private IPv4 address.
2. Open TCP 8089.
3. Generate an X25519 key pair.
4. Send `LANPASS` (method 196870) with `cKM = publicKey XOR magic` and
   `cS = sha256(cKM || LAN password)`, encrypted with the fixed bootstrap key.
5. Verify the reply `dS == sha256(dK)` and derive the session key from the
   X25519 shared secret.
6. Send requests with the 16-byte header:
   - command `0x38030818`,
   - version 1,
   - secure type 2,
   - session id as a single byte at offset 6,
   - magic at offset 7,
   - body length at offset 12.
7. Encrypt request bodies with AES-CBC using `sessionKey[0:16]` /
   `sessionKey[16:32]`; decrypt replies the same way.

Do not log the LAN password or the session key.

### White floodlight

Confirmed on the target firmware:

| DPID | Name | Direction | Values |
| --- | --- | --- | --- |
| `0x00050100` | `DPID_LIGHT_FLOODLIGHT_SW` | read/write | 0 = AUTO, 1 = ON, 2 = OFF |
| `0x00050101` | `DPID_LIGHT_FLOODLIGHT_STATUS` | read-only | 1 = on, 2 = off, 3 = auto |
| `0x00050103` | `DPID_LIGHT_FLOODLIGHT_SENSITIVITY` | read/write | integer; camera default 2 |

`0x00050102` (lightness) and `0x00050105` (indicator switch) return 1114
(`PROPERTY_NOT_SUPPORT`) on this firmware.

Write a mode with `SET_PROPERTIES`:

```json
{"dplist":[{"dpid":327936,"value":1}]}
```

where `327936` is `0x00050100`. Read the result with `GET_PROPERTIES` for
`0x00050100` and `0x00050101`. The camera accepts a single switch write; writing
`STATUS` returns 1114.

Android behavior:

- The focused viewer shows a bulb icon.
- The panel offers ON / AUTO / OFF and requires the profile LAN password.
- The session is opened lazily, read on open, and closed on panel dispose or
  app pause.
- A rejected property, bad password, or unreachable camera is shown as an error;
  there is no optimistic success.

### PTZ

The Android client uses the camera's advertised ONVIF services:

1. `GetCapabilities` → PTZ and Media `XAddr`.
2. Reject service URLs that do not point back to the configured private camera
   IP and port 8899.
3. `GetProfiles` → first profile with a `PTZConfiguration`.
4. `ContinuousMove` with a velocity cap of 0.15 and a short timeout.
5. `Stop` on release or after the timeout.

The web panel uses the same flow. A press-and-hold sends repeated moves every
350 ms and stops on release; a tap produces a short nudge.

### Talkback

`lan_talkback.dart` uses the authenticated LAN IOT session and the
media-session prelude used by the camera firmware, then sends G.711 A-law media
frames (`0x38030820`, secure type 2) with a 16-byte IV prefix and 16-byte header. The
camera-side audibility is still an open test. Do not claim it works until a
physical speaker test passes.

## Playback status

- SD/record DPIDs use group 2 (`0x00020100`–`0x00020106`); the target SD card
  is present and used.
- New-platform record list uses method `197152` (`0x00030220`), response
  `197153`; replay control is `197154`/`197155`/`197156`. The request JSON is
  `{filter, mode, start, end}` under `params`.
- Sending method `197152` on the plain authenticated IOT session (or a second
  socket with the same key/sid) returns `1114`.
- See `plan.md` for the current playback status.

## Xiaomi purifier module (v2)

Files: `web/miio_airpurifier.py`, `web/airpurifier_web.py`,
`web/static/airpurifier/`, `android-app/lib/miio_*.dart`,
`android-app/lib/airpurifier_*.dart`, `android-app/lib/token_store.dart`,
`android-app/lib/home_shell.dart`.

### Protocol

- UDP 54321. The unauthenticated hello is the exact 32-byte packet
  `21310020` + `ff`*28; the reply header gives the device id and device time.
- Discovery: the limited broadcast can be filtered by the AP; the client's
  `--sweep <private-/24>` sends unicast hellos as the fallback.
- Request header: magic `0x2131`, total length, zero, 4-byte device id,
  4-byte big-endian stamp. `checksum = MD5(header || token || encrypted)`.
- AES-128-CBC, key `MD5(token)`, IV `MD5(key || token)`, PKCS#7, UTF-8 JSON
  plus one trailing NUL.
- Requests after hello: `miIO.info`, `get_properties` (max 15 per request),
  `set_properties`, `action`.
- `did` in MIoT `params` is a correlation label (`power`, `call-4-1`) echoed by
  the device. Per-property `-4001` is recorded as unsupported; other negative
  codes are errors.
- `miIO.info` may echo the token and MAC. Only `model`, `fw_ver`, and `hw_ver`
  are retained; the raw response is discarded.
- Model maps: `zhimi.airp.mb5a`/`mb5` (4), `zhimi.airp.vb4`/`va2` (4 Pro), and
  `xiaomi.airp.cpa4` (4 Compact). The 4 Pro adds PM10, air-quality, and a 15.1
  favorite-level alternate; the 4 uses `9.5`. The Compact has no fan level,
  anion, humidity, temperature, temperature unit, PM10, or air-quality; it uses
  mode 0–2, favorite `9.11` (0–14), PM2.5 as an int, and screen brightness
  `13.2`. Unknown models are read-only.
- Writes are allowlisted and range-checked, then read back. The read-back
  retries for up to 3 s because some firmware applies a write one request late;
  a persistent mismatch is reported as `applied: false`. `filter reset`
  (action `4.1`, input piid `3`) is sent once and read back; it is never
  retried automatically.
- The status JSON includes a `properties` list (name, label, kind, minimum,
  maximum, writable, unit) so the web panel hides unsupported controls and uses
  the model's mode/favorite ranges.
- Re-handshake after 5 minutes or a read timeout. Reads retry once; writes and
  actions do not.
- Android transport: each request binds a fresh UDP socket because
  `RawDatagramSocket` exposes a single-subscription event stream. Reusing one
  socket for the hello and the following info request caused a false "could not
  reach" error.
- Unknown/non-purifier models: only `miIO.info` is read. The client returns an
  identity-only status and does not send purifier property requests. The
  **Xiaomi** tab stores any miIO device; purifier models get controls, other
  models get an identity card saying control is not implemented yet.
- Screen brightness uses the spec's raw values (0 off, 1 dim, 2 normal); verify
  on hardware because python-miio's internal enum is the opposite.

### Storage

- Android: `shared_preferences` key `airpurifier_profiles` contains only
  `{id, name, address, modelId}`. The token is in `flutter_secure_storage`
  under `localhome.purifier.token.<id>`.
- The injector (`scripts/inject_lanpass.py`) merges the camera key into the
  existing preference XML, preserving `airpurifier_profiles` and other keys.
- Web: the token is per request or from `MIIO_TOKEN` in
  `~/.config/localhome-miio.env`; it is never persisted by the browser or
  logged. History is `~/LocalHome-purifier/readings.jsonl` (mode 0600, no
  token/MAC/device id/RFID), rotating to `.jsonl.1` above 20 MB.
- Optional one-time bootstrap:
  `scripts/miio_token_from_cloud.py` (`uv run --with micloud`) prompts for the
  Xiaomi account locally, writes only the token to the env file, and is never
  used at runtime. The password is not stored. For a token obtained manually,
  paste it into a mode-600 drop file and run `scripts/set_miio_token.py`; the
  value is validated and written without being printed.
- Debug seeding: `scripts/inject_purifier.py --ip <private-ip>` verifies the env
  token, writes the purifier profile into `shared_preferences`, and stages
  `files/localhome-miio.env`. The app reads it only in debug mode, writes the
  token to the Keystore, and deletes the staging file. Release builds ignore it.

### Purifier web endpoints

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/` | GET | Purifier panel. |
| `/api/purifier/config` | GET | `{token_configured}` only. |
| `/api/purifier/discover` | GET | Broadcast hello; private addresses only. |
| `/api/purifier/history` | GET | Last N local readings. |
| `/api/purifier/info` | POST | `{ip,token?}` → model/firmware. |
| `/api/purifier/status` | POST | `{ip,token?}` → status + unsupported. |
| `/api/purifier/set` | POST | `{ip,token?,name,value}` → fresh status + `applied`. |
| `/api/purifier/filter/reset` | POST | `{ip,token?,confirm:true}` → fresh status. |

The purifier server binds `127.0.0.1:8091` by default and rejects cross-origin
POSTs. It never logs request bodies or the token.

## Hinen PS3000 module (v3)

Files: `web/hinen_local.py`, `web/hinen_web.py`, `web/static/hinen/`,
`android-app/lib/hinen_*.dart`, `android-app/lib/home_shell.dart`.

### Protocol

- The PS3000 is a **Tuya LAN 3.4** device at a private IPv4 address. TCP 6668 is
  the only reachable local port; there is no HTTP/TLS/SSDP/mDNS service.
- Discovery uses Tuya UDP scanning (ports 6666/6667 through `tinytuya`) and
  returns the device id, product key, version, active state, and encryption
  flag. It does not return the local key. Only private addresses are accepted.
- Reading DPs requires the 16-character Tuya local key. The host uses
  `tinytuya.Device(...).status()` and `set_value()`; `write_tuya_dp()` has a
  strict allowlist and reads the station back after every write.
- The 3.4 request is command **16 (`DP_QUERY_NEW`)** with an empty `{}` payload,
  AES-128-ECB, and a 32-byte HMAC-SHA256 trailer. Command 16 is in Tuya's
  no-protocol-header list. The Android client implements the same documented
  Tuya LAN 3.4 framing.
- The direct phone TCP session is closed by the station after the request even
  with the documented framing and matching key. The host client works. The app
  attempts the direct path first and falls back to the host bridge.
- The key is read per request or from `HINEN_LOCAL_KEY` in
  `~/.config/localhome-hinen.env` (mode 600); `HINEN_DEVICE_ID` is optional. It
  is never logged, returned by the API, stored in the Android profile, or put in
  browser storage. The device id is shown only as a short prefix in discovery.
- The local key was imported once through the Smart Life path and saved from
  a protected drop file. This is a credential bootstrap, not a runtime cloud
  path; no Hinen/Tuya cloud request is made by the module.
- Writes are limited to DPs **6, 7, 25, 26, 105, 106, 108, 109, 110, 113**.
  No UPS, charge-limit, P-boost, schedule, or firmware write exists. Fast
  Charging (DP 107) is read-only locally; the station rejects that write.
- LAN checks cover 80, 443, 502, 1883, 5000, 6668, 8000, 8080, 8443, 8883,
  8888, and 9000, plus HTTP/TLS, SSDP, and optional mDNS. Only
  read-only requests are sent.
- BLE: the station exposes no local Bluetooth control and shows Wi-Fi/cloud.
  BLE is treated as provisioning-only. `web/hinen_local.py` has optional
  read-only `ble_scan`/`ble_gatt` helpers. No GATT writes are implemented.

### Storage and privacy

- Android: `shared_preferences` key `hinen_profiles` contains only
  `{id, name, address, productKey, model, deviceId, bridgeUrl}`. No local key is
  stored there. The debug app imports a staged key into the Android Keystore;
  the release APK has no key. `scripts/inject_hinen.py` seeds the profile,
  device ID, bridge URL, and key stage for a debug build.
- Web: the Tuya local key is per request or from the mode-600 env file; it is
  never persisted by the browser or logged. `scripts/set_hinen_key.py` imports
  the key from a protected drop file or stdin and prints only its length.
- No app key, local key, device id/MAC, serial, product key, or payload is
  recorded in this document.

### Hinen web endpoints

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/` | GET | Hinen discovery/status/write panel. |
| `/api/health` | GET | Liveness. |
| `/api/hinen/config` | GET | `{local_key_configured,tinytuya_available,bleak_available}` only. |
| `/api/hinen/discover` | POST | Tuya UDP scan; private addresses only, device-id prefix. |
| `/api/hinen/check` | POST | `{ip}` → ports, HTTP/TLS, SSDP, mDNS. |
| `/api/hinen/status` | POST | `{ip,key?}` → raw DPs; 400 without a key. |
| `/api/hinen/write` | POST | `{ip,key?,dp,value}` → allowlisted write + read-back. |
| `/api/hinen/ble/scan` | POST | BLE advertisements (optional `bleak`). |
| `/api/hinen/ble/gatt` | POST | Read-only GATT read (optional `bleak`). |

The Hinen server binds `127.0.0.1:8092` by default; for the Android host bridge
it binds `0.0.0.0:8092` on a trusted private LAN. It rejects cross-origin POSTs,
caps the request body, validates private IPv4, and never logs request bodies or
keys. Writes are restricted to DPs 6, 7, 25, 26, 105, 106, 108, 109, 110, 113
and every write is read back. DP 107 Fast Charging is read-only locally.

For a stable deployment, `scripts/localhome-hinen.service` is a systemd user
service with `Restart=always`; install it under `~/.config/systemd/user/`,
enable it, and enable linger for boot-without-login. This prevents the temporary
shell-process failure that made the app show "Station unavailable".

### Android shell and quick controls

The **Energy** tab is a dashboard: PS3000 status, capacity (2,560/5,120 Wh),
AC/DC/light, AC charging limit, vehicle current, fast charging (read-only),
keystroke sound, device/AC standby, screen-off, packs, output, and raw DPs.
`hinen_status.dart` keeps nullable fields and an explicit unsupported state
so no fake readings are shown. `hinen_host_bridge.dart` attempts the direct Tuya
path first and falls back to `/api/hinen/status`/`/api/hinen/write`.

The native `HinenQuickControls.kt` adds:
- one LocalHome notification card with AC, DC, Cameras, and Light actions;
- one LocalHome Quick Settings tile;
- a compact sheet with independent **Energy** and **Cameras** cards;
- each camera card passes its camera id to Flutter, which opens the specific
  single-camera live viewer;
- a native host HTTP client and read-back after writes.

The tile is a standard Android `TileService`; it is not part of the proprietary
Xiaomi Smart Hub card. On HyperOS 3, Android Device Controls are broken. The
app uses local cleartext only for the private host bridge; no public HTTP. The
launcher, tile, and notification use the house+bolt icon
(`ic_launcher_*`, `ic_localhome_tile`, `ic_stat_localhome`).

### DP mapping and limits

| DP | Meaning | Status |
| --- | --- | --- |
| 1 | Battery SOC | Confirmed |
| 6 | AC output | Confirmed by toggle |
| 7 | DC output | Confirmed by toggle |
| 26 | Device standby | Confirmed (7200 s = 2 h) |
| 105 | AC charging power limit | Confirmed (90%); 80% write verified |
| 106 | Vehicle charging current | Confirmed (8 A); 6 A write verified |
| 107 | Fast Charging switch | Read-only locally; write rejected |
| 108 | Keystroke Sound | Writable; false/true verified |
| 109 | AC standby | Confirmed (3600 s) |
| 110 | Screen-off | Confirmed (300 s) |
| 113 | Light mode | 0 Off, 2 Medium, 3 High, 4 SOS verified; 1 Low assumed |
| 116 | Charging packs | Confirmed (1) |
| 117 | Output watts | Read; not fully characterized |

DP 25 beep is not reported. DPs 111/112 remain unmapped. The 32°C Smart Life
temperature is cloud-only and is not shown as a local DP. The PS3000 base is
2,560 Wh; the PS2500B pack is 2,560 Wh; with one pack the app shows 5,120 Wh and
remaining Wh from DP 1. Solar, car-charge, and AC-energy history are Smart Life
cloud statistics and are not shown. V380 cameras expose no per-camera energy.

## Camera web panel

Endpoints:

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `/` | GET | Static control panel. |
| `/api/health` | GET | Liveness. |
| `/api/light/status` | POST | Read light state; JSON `{ip,password}`. |
| `/api/light/set` | POST | Set `{ip,password,mode}`; mode `on/auto/off`. |
| `/api/ptz/start` | POST | `{ip,direction}`; direction `up/down/left/right`. |
| `/api/ptz/stop` | POST | `{ip}`. |
| `/api/ptz/nudge` | POST | `{ip,direction,duration}`. |
| `/api/snapshot` | GET | One JPEG from `{ip,path}` via ffmpeg. |
| `/api/stream` | GET | MJPEG from `{ip,path}` via ffmpeg. |

Security behavior:

- Binds to `127.0.0.1` by default.
- Accepts only RFC1918 private IPv4 camera addresses.
- Validates RTSP paths before passing them to ffmpeg; no shell is used.
- Rejects cross-origin POSTs.
- Does not log request bodies or passwords.

The live preview uses `ffmpeg -f mpjpeg` and relays
`multipart/x-mixed-replace; boundary=ffmpeg`. The server kills the ffmpeg child
when the client disconnects.

## Install path

Preferred USB install:

```sh
bash scripts/install_app.sh
```

It runs:

1. `flutter build apk --debug` in `android-app/`.
2. `adb install -r build/app/outputs/flutter-apk/app-debug.apk`.
3. `python3 scripts/inject_lanpass.py` to migrate/seed the camera profiles from
   the previous app or the new app store and update LAN passwords from
   `~/.config/v380decoder-test.env`. It merges only the camera key into the
   existing preference XML, so purifier profiles and other preferences survive
   a reinstall.
4. Launch `com.pyansofyan.localhome`.

The LocalHome package is `com.pyansofyan.localhome` (Dart package `localhome`).
The install script migrates camera profiles from the previous
`com.pyansofyan.himost_camera` app when it is still installed, seeds the LAN
passwords, and then removes the old app after migration.

If MIUI reports `INSTALL_FAILED_USER_RESTRICTED`, enable Developer options →
**Install via USB**, keep the device unlocked, and rerun the script.

## Future LocalHome module layout

Do not restructure until the second module is confirmed. The proposed structure is:

```
core/                 shared device registry, private-address guards,
                      credential handling, connection state
modules/camera_v380/  current camera client (moved behind a module boundary)
modules/energy_hinen/ implemented host-bridged Tuya read/write (present layout)
modules/miio/         current Xiaomi/MiIO local protocol
web/                  shared local test/control panel
android/              shared shell and module UI
```

Rules for the second module:

- Confirm a local protocol/API first; do not assume from a cloud API.
- Keep credentials local and out of logs.
- Fail closed when only a cloud path exists.
- Keep each module independently testable.

## Tests and verification

Android:

```sh
cd android-app
flutter pub get
flutter analyze
flutter test
```

Web / Python:

```sh
python3 -m unittest discover -s tests -t . -v
python3 -m py_compile \
  web/local_net.py web/miio_airpurifier.py web/airpurifier_web.py \
  web/v380_lan.py web/v380_onvif.py web/camera_web.py web/hinen_local.py \
  web/hinen_web.py scripts/inject_lanpass.py \
  scripts/miio_token_from_cloud.py scripts/set_miio_token.py \
  scripts/set_hinen_key.py scripts/inject_hinen.py
node --check web/static/app.js
node --check web/static/airpurifier/app.js
node --check web/static/hinen/app.js
```

Hardware smoke test (with a private camera and LAN password):

- light read/set ON, AUTO, OFF;
- PTZ start/stop or nudge;
- snapshot;
- live MJPEG for a few seconds;
- confirm the camera returns to its original light mode.

Purifier smoke test (with the private address and token):

```sh
python3 web/airpurifier_web.py
```

- Add the private address and token in the panel and compare every status value
  with the device display / Mi Home.
- Web panel: mode, favorite level, child lock, buzzer, and screen brightness on
  the Compact; fan level/anion/humidity/temperature controls are hidden because
  the model lacks them. One at a time, checking the read-back.
- Filter reset last, after recording the current filter life (not yet exercised
  on the Compact).
- Android: add the profile and verify status plus the same controls; reinstall
  and confirm the purifier profile survives.
- Target 4 Compact verified on 2026-10-31: status, mode 1↔0, favorite 13↔14,
  and screen brightness 1↔2, each with read-back. Power-off, filter reset,
  child lock, and buzzer writes remain.
- If the token is rejected or the handshake differs, stop and record the
  result. Do not guess writes or mark the module verified.

Hinen PS3000 smoke test (host bridge; private LAN):

```sh
curl -sS -X POST http://<host>:8092/api/hinen/status \
  -H 'Content-Type: application/json' -d '{"ip":"<private-ip>"}'
```

- Compare DP 1/6/7/105/106/107/108/113/116 with the Smart Life panel and the
  physical unit.
- Safe write: DP 26 to the current value or a harmless standby value, then read
  back; stop if the read-back mismatches.
- Confirm AC/DC/light writes one at a time; return the station to its original
  state.
- Android: open the Energy dashboard, verify host-bridge source, capacity
  (2,560/5,120 Wh), and controls; verify the notification card and LocalHome
  tile sheet (Energy/Cameras, specific camera deep links).
- The direct phone Tuya session is expected to be refused; record the error
  rather than treating it as a key failure.

Verified on 2026-11-01: host status and a DP 26 write/read-back; Camera 1 deep
link; Flutter analyze/tests/build; notification card and tile installed. The
remaining DP 111/112/117; DP 107 is read-only locally.

## Credits and licenses

See [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) for the third-party V380
projects, the earlier-project credit, dependency licenses, and the `libmpv`/`ffmpeg`
distribution caveats.

## Security boundary

- Use only on a trusted private network.
- The legacy camera protocol does not provide authenticated transport
  encryption; a password prompt is not a guarantee of encryption.
- The purifier token is a bearer secret for local control. It is stored in the
  Android keystore and is never written to the profile JSON, browser storage,
  logs, or commits. Prefer the mode-600 env file for the host panel.
- miIO token encryption is not authenticated transport encryption; a token does
  not make an untrusted network safe.
- Do not commit the LAN password, purifier token, Hinen local key, device
  identifiers, or private network details.
- The Hinen host bridge has no accounts or transport encryption; bind it to
  `0.0.0.0:8092` only on a trusted private LAN. Writes are allowlisted to DPs 6,
  7, 25, 26, 105, 106, 108, 109, 110, 113 and read back; DP 107 is read-only.
- The web panels are local test tools, not internet-facing services.
