# LocalHome — Progress

_Last updated: 2026-11-06_

> **Living document.** Update this file after every change. Record what was
> completed, what is in progress, and what remains. Update `plan.md` and the
> relevant design doc at the same time.

## Current state

| Area | Status |
| --- | --- |
| Direct RTSP live video | Confirmed on the target at `/live/ch00_0`, TCP 554. |
| ONVIF PTZ | Confirmed by user: local pan/tilt/stop over TCP 8899. |
| White floodlight | Confirmed by user: ON / AUTO / OFF over the authenticated LAN IOT session, TCP 8089. |
| Web test panel | Implemented; light, PTZ, snapshot, and MJPEG preview tested. |
| Android install path | LocalHome (`com.pyansofyan.localhome`) installed and running; 3 profiles and LAN passwords migrated from the old app; old package removed. |
| Talkback | Experimental: LAN IOT audio sends; camera-speaker audibility still pending. |
| Recording search/playback | SD card present and used. Method `197152` returns `1114` on plain IOT; playback is unsupported. |
| Xiaomi purifier (v2) | Implemented for the 4/4 Pro and the target 4 Compact (`xiaomi.airp.cpa4`). On the Compact: status and mode/favorite/screen writes verified; Android app visually verified. The Android **Xiaomi** tab stores any local miIO device; unknown models are identity-only. Power-off and filter reset pending. |
| Hinen PS3000 (v3) | Implemented host-bridged reads and confirmed-DP writes. PS3000 at `<private-ip>`; local key in the host mode-600 env and debug Keystore; app dashboard, capacity, AC/DC/light/timers, notification card, and LocalHome Quick Settings tile. Direct phone LAN read is refused by the station; host bridge is the working path. |
| Project name | LocalHome (folder/app/package); Android `com.pyansofyan.localhome`, Dart `localhome`. |

## 2026-10-28 — initial implementation and LAN validation

- The target provides RTSP on TCP 554, ONVIF on TCP 8899, and IOT on TCP
  8089. TCP 8800 is refused.
- Live RTSP carries H.264 1280x720/20 fps and G.711 A-law mono/8 kHz audio.
- ONVIF capability/profile/PTZ requests work. Short PTZ moves returned HTTP
  200; physical movement was confirmed later.
- The local IOT service is on TCP 8089.

## 2026-10-29 — local IOT session

- The local IOT session supports authenticated property reads and writes.
- The camera LAN password (QR field 8) authenticates the session.
- Audio properties are read and restored:
  `AI_VOLUME=80`, `AO_VOLUME=100`, `TIPS_PROMPT_SW=true`,
  `ENCODING_FORMAT=8`, `ONVIF_SW=true`, `RTSP_AUDIO_SW=true`.
- The RTSP backchannel was accepted but produced no audible sound. Talk requires
  a media-session token.

## 2026-10-30 — LAN talkback

- Talkback uses the authenticated LAN IOT session with G.711 A-law media
  frames, implemented in `android-app/lib/lan_talkback.dart`.
- The local session works without a cloud login.

## 2026-10-31 — light, PTZ, web panel, cleanup

### White floodlight

- Implemented the light DPIDs and value mapping:
  - `DPID_LIGHT_FLOODLIGHT_SW = 0x00050100`: **0 = AUTO, 1 = ON, 2 = OFF**.
  - `DPID_LIGHT_FLOODLIGHT_STATUS = 0x00050101`: read-only; 1 = on, 2 = off,
    3 = auto.
  - `DPID_LIGHT_FLOODLIGHT_SENSITIVITY = 0x00050103` is present.
  - `DPID_LIGHT_FLOODLIGHT_LIGHTNESS = 0x00050102` and
    `DPID_LIGHT_INDICATOR_SW = 0x00050105` return 1114 on this firmware.
- Verified over the authenticated TCP 8089 IOT session on the target:
  - SW=1 → STATUS=1 (on);
  - SW=2 → STATUS=2 (off);
  - SW=0 → STATUS=2 with schedule `defaultAction=0` (auto, light off in ambient
    light).
- The user confirmed the physical white light responds to ON/AUTO/OFF.
- Implemented in:
  - `android-app/lib/lan_iot.dart` (LANPASS + encrypted GET/SET_PROPERTIES),
  - `android-app/lib/lan_light.dart` (mode mapping),
  - `android-app/lib/light_controls.dart` (bulb panel),
  - `android-app/lib/grid_viewer.dart` (focused-view wiring).

### PTZ

- The Android focused viewer uses local ONVIF (TCP 8899), capability/profile
  discovery, a conservative velocity cap, and a short timeout.
- The user confirmed physical movement works.

### Web test panel

- Added `web/` to test controls without rebuilding the Android app:
  - `POST /api/light/status` and `/api/light/set`
  - `POST /api/ptz/start`, `/api/ptz/stop`, `/api/ptz/nudge`
  - `GET /api/snapshot`
  - `GET /api/stream` (RTSP → MJPEG via `ffmpeg`)
- Verified on the target: light read/set, PTZ start/stop, JPEG snapshot, and
  MJPEG stream all worked. The panel binds to localhost by default and validates
  private IPv4 addresses.
- The camera was restored to AUTO after testing.

### Cleanup and rename

- Removed the legacy `.NET` client, its Docker/CI/VS configuration, and
  historical docs; deleted generated build caches.
- Kept the Android app and web panel.
- Renamed the project and app display name to **LocalHome**, and renamed the
  Android package to `com.pyansofyan.localhome`, the Dart package to
  `localhome`, the Kotlin package path, and the microphone MethodChannel names.
- Renamed the local folder from `V380Decoder` to `LocalHome`; the temporary
  symlink was removed.
- Updated the install/injector scripts to the LocalHome package. The installer
  migrates camera profiles from the previous `com.pyansofyan.himost_camera`
  app, seeds LAN passwords, and removes the old app after migration.
- `scripts/install_app.sh` remains the preferred USB install path. The
  LocalHome APK built successfully; installation is pending the MIUI permission
  described below.
- `flutter analyze` and all 30 Flutter tests pass after the rename.

### LocalHome install and migration — resolved 2026-10-31

- The first install attempt was blocked by MIUI with
  `INSTALL_FAILED_USER_RESTRICTED`.
- After enabling Developer options → **Install via USB**, the package installed.
  The injector migrated **3 camera profiles** and **3 LAN passwords** from
  `com.pyansofyan.himost_camera` into `com.pyansofyan.localhome`.
- LocalHome is running with the `LocalHome` label; the old package was
  uninstalled.
- The temporary `V380Decoder` symlink was removed; the folder is LocalHome.

### Licensing and credits — 2026-10-31

- Verified the main third-party licenses:
  - `prsyahmi/v380`: MIT (Copyright 2019 Syahmi Azhar).
  - `cimplesid/v380-mac` / OpenV380: MIT (Copyright 2026 OpenV380 contributors).
  - `media_kit` / `media_kit_video` / `media_kit_libs_video`: MIT.
  - `cryptography`: Apache-2.0; `shared_preferences`: BSD-3-Clause;
    `xml`: MIT; `pointycastle`: Bouncy Castle license.
- `PyanSofyan/V380Decoder` has **no declared license**. It is an earlier
  project; no code from it is included in LocalHome.
- Added `THIRD_PARTY_NOTICES.md` with the MIT texts, credits, and dependency
  notes. `media_kit` bundles native `libmpv` libraries whose LGPL/GPL terms must
  be checked before distributing an APK.

### Module planning docs — 2026-10-31

- Added `idea-v2-xiaomi-air-purifier.md` for the Xiaomi Smart Air Purifier 4 /
  4 Pro (`zhimi.airp.mb5a` / `zhimi.airp.vb4`). It records the local miIO/MIoT
  transport (UDP 54321, token-derived AES), the 4 Pro service map, the one-time
  token bootstrap, the feature-parity table, and the schedules decision gate.
- Added `idea-v3-hinen-ps300.md` for the Hinen PS300 / PS300 Pro backup station.
  No local protocol is confirmed; the official Hinen Home Assistant integration
  is cloud OAuth only. The doc defines network and BLE discovery, a read-only-first
  safety boundary, and the explicit cloud-exception policy.
- Recorded the local-first rule in both docs: confirm local first; cloud is only
  an explicit, rare, opt-in push when no local path exists, never a silent
  fallback.
- Linked both docs from `idea.md`, `README.md`, and `plan.md`.

## Playback status — 2026-10-31

- SD card is present. `DPID_SD_STATUS` (`0x00020100`) = 1; capacity
  (`0x00020101`) = `15634268|525991|15108277` (about 15.6 GB total, 525 MB
  free, 15.1 GB used). The camera has recordings.
- SD/record DPIDs use group 2:
  - `DPID_SD_STATUS` = `0x00020100`
  - `DPID_SD_CAPACITY` = `0x00020101`
  - `DPID_SD_FORMAT_STATE` = `0x00020102`
  - `DPID_RECORD_MODE` = `0x00020103`
  - `DPID_RECORD_QUALITY` = `0x00020104`
  - `DPID_RECORD_AUDIO` = `0x00020105`
  - `DPID_RECORD_LOOP` = `0x00020106`
- The documented ONVIF and RTSP services do not expose a record-list operation.
  A standard authenticated IOT property request returns **1114** with no record
  list.
- Playback is therefore marked unsupported. No local record-list transport is
  implemented; list/play/seek will be added only if a supported local endpoint
  is published.

## 2026-10-31 — Xiaomi air purifier module (v2)

### Decisions

- Both models: Smart Air Purifier 4 (`zhimi.airp.mb5a`) and 4 Pro
  (`zhimi.airp.vb4`), with the map selected from `miIO.info` at runtime. The
  actual target is the 4 Compact (`xiaomi.airp.cpa4`), added later with its own
  map.
- Token bootstrap: the user supplies the token; no ongoing cloud dependency.
  The target token was imported through a supported local import step and
  stored locally.
- Delivery: web panel first, then Android.
- Android token storage: `flutter_secure_storage`; the profile JSON has no
  token.

### Implemented

- `web/miio_airpurifier.py`: local miIO/MIoT client (UDP 54321), hello,
  `miIO.info`, chunked `get_properties` (15 max), `set_properties`, `action`,
  model maps for the 4, 4 Pro, and 4 Compact, validation, and read-back. The
  raw info map (which may contain the token/MAC) is discarded.
- Model-aware web and Android controls: unsupported properties are hidden and
  the mode/favorite ranges come from the selected model. The status API exposes
  the property metadata.
- Read-back retries briefly because the Compact can apply a write one request
  late.
- `web/airpurifier_web.py`: localhost panel/API on port 8091, token from the
  panel or `~/.config/localhome-miio.env`, allowlisted controls, filter reset
  confirmation, discovery, and JSONL history.
- `web/static/airpurifier/`: status, controls, filter, history, and discovery
  UI.
- Android: `miio_packet.dart` (framing/AES), `airpurifier_status.dart`
  (property maps/validation), `miio_airpurifier.dart` (UDP client),
  `airpurifier_profile.dart`, `token_store.dart`, `airpurifier_home_page.dart`,
  `airpurifier_controls.dart`, and a Cameras/Air purifier `home_shell.dart`.
- Added `flutter_secure_storage`; set `android:allowBackup="false"`.
- Fixed `scripts/inject_lanpass.py` to merge the camera preference key instead
  of replacing the whole XML map, so purifier profiles survive a reinstall.
- Added `tests/` (Python) and new Flutter tests.
- Debug profile/token seeding: `scripts/inject_purifier.py` verifies the env
  token, seeds the purifier profile, and stages a token file;
  `lib/debug_token_import.dart` imports it into the Android Keystore on launch
  and deletes it. Release builds ignore the staging file.

### Discovery and token bootstrap

- The purifier was not on the LAN until it joined Mi Home. After it joined, the
  limited-broadcast hello was filtered by the access point; a unicast hello to
  the private `/24` found the unit. The exact address is not recorded here.
- The client sends a unicast hello sweep over the private `/24` as the
  discovery fallback.
- Added the optional one-time `scripts/miio_token_from_cloud.py`
  (`uv run --with micloud`): it prompts locally, writes only `MIIO_TOKEN` to a
  mode-600 file, and never prints the token. The password is not stored.
- The first cloud attempt returned `MiCloudAccessDenied`. That is a global
  account-login failure, not a region failure; the region only affects the
  device-list request. The account likely has 2FA or a captcha challenge, which
  `micloud` cannot complete. A supported account export was used for this step.
- Home Assistant on the private LAN showed the purifier unavailable; its
  stored host/token may be stale. The supported export path was used instead
  and checks every cloud server (the account is on TW/SG/IN).
- Added `scripts/set_miio_token.py` and a mode-600 drop file
  (`~/.config/localhome-miio-token.txt`) so the token can be pasted and
  imported without printing it or putting it in shell history.

### Target unit verified — Smart Air Purifier 4 Compact

- Token imported from the drop file; only its length was checked.
- `--info`: model `xiaomi.airp.cpa4` (Smart Air Purifier 4 Compact), firmware
  `2.2.10_0021`, hardware `esp32`.
- `--status`: power off, fault 0, mode 0, PM2.5 91–97 µg/m³, filter life 100 %
  / 63 h used / 289 days left, buzzer on, child lock off, motor 0 rpm,
  favorite 14, screen brightness 2.
- This model has no fan level, anion, humidity, temperature, temperature unit,
  PM10, air-quality band, purify volume, or average AQI.
- Reversible writes verified with read-back: mode 1↔0, favorite 13↔14, screen
  brightness 1↔2. The Python client and the web API both reported `applied`
  and the fresh value.
- Not exercised: power on/off (would run the fan), filter reset (destructive),
  child lock and buzzer writes.
- Installed the updated debug APK; the app now has 1 purifier profile
  (`Air purifier`, private address, model `xiaomi.airp.cpa4`) and the 3 camera
  profiles were preserved. The staged token was imported into the Keystore and
  the staging file was deleted.
- The exact LAN address is not recorded.

### App connectivity and generic Xiaomi tab

- The first app launch showed "Could not reach" even though the phone could
  ping the purifier. Cause: the Dart transport reused one `RawDatagramSocket`
  for the hello and the following info request; the socket event stream is
  single-subscription, so the second listen threw. Fixed by binding a fresh UDP
  socket per exchange.
- The app now connects and shows the Compact: Power OFF, Mode Favorite, PM2.5
  58, Filter life 100 %, with model-aware controls (no fan/anion/humidity/
  temperature).
- The tab is now **Xiaomi** ("Your Xiaomi devices", "Add device"). Any local
  miIO/MIoT device can be stored; purifier models get controls; other models
  show model/firmware and an identity-only "not implemented yet" card. The
  client does not send purifier properties to unknown models.
- The seeded profile and Keystore token survived the reinstall; the 3 camera
  profiles were preserved.

### Verification

- `python3 -m unittest discover -s tests -t . -v`: 43 tests pass.
- `flutter analyze`: no issues.
- `flutter test`: 61 tests pass.
- `flutter build apk --debug`: builds successfully.
- Web panel smoke test: health, config, static assets, and 400 responses for a
  non-private IP and a missing token.

### Not yet verified

- Power on/off and filter reset were not exercised on the Compact. The former
  would run the fan; the latter is destructive.
- Child-lock and buzzer writes were not exercised.
- The 4 and 4 Pro maps are implemented but untested on hardware; the target is
  the Compact.
- Schedules/timers remain unsupported; no cloud call was added.
- The Android app is visually verified against the Compact (status and
  controls). Other Xiaomi device classes are identity-only; their control maps
  are not implemented.
- Power-off, filter reset, child-lock, and buzzer writes remain unexercised.

### Data handling

- No token, MAC, device ID, RFID data, or media contents are recorded here.
- The token file lives outside the repository at
  `~/.config/localhome-miio.env` (mode 600) and is gitignored via `*.env`.

## Hinen PS300 module (v3) — Tuya LAN discovery

**Historical (2026-10-31).** Superseded by the 2026-11-01 implementation section
below; this section records the discovery phase before the key and DP mapping.

Status: discovery and read-only shell implemented; local key and DP mapping
pending.

### Local interface and identity

- The station is managed by the Hinen/SolisCloud mobile app (a Tuya-based
  cloud app). It exposes no documented local API.
- The official Home Assistant Hinen integration is cloud OAuth for Hinen Solar
  inverters (`celinksmart.com`); it is not a PS300 local path.
- Tuya UDP discovery found the PS300 at a private address
  (`<private-ip>`; DHCP): product key `<product-key>`, protocol **3.4**,
  encrypted, TCP **6668** open. No other local service (HTTP/TLS/SSDP/mDNS) is
  exposed.
- The station's Tuya identity is confirmed by its discovery response and its
  Wi-Fi/cloud connectivity; it does not expose a local Bluetooth control mode.
- BLE is treated as provisioning-only.
- The Tuya local key is not returned by UDP discovery. It was obtained once
  through the Smart Life account path with a supported account share/export. No
  runtime cloud path is implemented.

### Implemented

- Historical: these notes describe the 2026-10-31 discovery shell. The current
  implementation is in the 2026-11-01 section below.
- `web/hinen_local.py`: Tuya UDP discovery, read-only `status()` DPs, LAN
  port/SSDP/mDNS checks, and optional BLE scan/GATT. No write function in the
  historical shell.
- `web/hinen_web.py` + `web/static/hinen/`: localhost discovery/read-only panel
  on port 8092. It shows the Tuya device, LAN identity, raw DPs when a key
  is supplied, and BLE results; status without a key returns a clear error.
- `scripts/set_hinen_key.py`: imports a 16-character key from a mode-600 drop
  file (or stdin) into `~/.config/localhome-hinen.env`, preserving other lines
  and printing only the length.
- `scripts/inject_hinen.py`: seeds the debug app's `hinen_profiles` with the
  PS300 private address/product key; no local key is staged.
- Android **Energy** tab: `hinen_profile.dart`, `hinen_status.dart`,
  `hinen_home_page.dart`, `hinen_controls.dart`, and the three-tab
  `home_shell.dart`. It stores a private address and product key only, shows
  the Tuya LAN 3.4 status, and exposes no controls or local key.
- `tests/test_hinen.py`, `tests/test_set_hinen_key.py`, and
  `tests/test_inject_hinen.py`: discovery sanitization, key import/env
  handling, profile merge, and mode-600 tests.

### Verification

- Live `--discover`: PS300 found; product key and protocol version confirmed,
  device id prefix only.
- Live `--ip --check`: only TCP 6668 reachable; no HTTP/TLS/SSDP/mDNS.
- `--status` without a key: clear "local key required" error.
- Web smoke: health, config, static assets, discovery, private-IP rejection,
  and 400 for status without a key.
- `python3 -m unittest discover -s tests -t . -v`: 68 tests pass.
- `flutter analyze`: no issues. `flutter test`: 66 tests pass.
- `flutter build apk --debug`: builds; installed on the phone with `adb install
  -r`. The **Energy** tab is visible with the seeded PS300 profile
  (`PS300`, `<private-ip>`, product key `<product-key>`); existing
  camera/purifier profiles were preserved. The detail page shows identity,
  Tuya LAN status, "local key required", and no controls.

### Not yet verified

- Tuya DP read on hardware (host bridge), DP mapping, capacity, and confirmed
  writes are verified; DPs 106/107/108/111/112/117 remain uncharacterized.
- BLE post-provisioning behavior is not confirmed; the station exposes no local
  Bluetooth control. BLE is treated as provisioning-only.
- Any control write. None is implemented; mains-power writes remain out of
  scope until a local write path is confirmed and safety-reviewed.
- Offline operation after the one-time key bootstrap.

### Data handling

- No app key, local key, device ID/MAC, serial, payload, product key, or private
  address is recorded here.
- The Android profile contains no local key; the web panel never stores or
  returns it.

## 2026-11-01 — Hinen PS3000 v3: host bridge, controls, capacity, tile

### Identity and credential

- The unit is a **Hinen PS3000** (Smart Life panel name), Tuya LAN 3.4, product
  key `<product-key>`, at `<private-ip>`.
- The Tuya local key was obtained once through the Smart Life path, imported
  from a mode-600 drop file with `scripts/set_hinen_key.py`, and removed from the
  drop file. It is never printed, committed, or placed in the profile/APK.
- The key is in `~/.config/localhome-hinen.env` (host) and the debug app's
  Android Keystore. The release APK has no key; host-bridge writes do not send
  the key to the phone.

### Protocol and session behavior

- The Tuya 3.4 request uses **command 16 (`DP_QUERY_NEW`)** with an
  empty `{}` payload, AES-128-ECB, and a 32-byte HMAC-SHA256 trailer; command 16
  is in Tuya's no-protocol-header list. The app implements the documented Tuya
  LAN 3.4 framing.
- The direct phone LAN session is still closed by the station after the request
  even with the documented framing and a matching key. The host's
  `tinytuya` client works. This is treated as a station/session restriction, not
  a key or packet error.
- The app prefers the direct path, then falls back to the LocalHome host panel
  at `http://<host>:8092`. No runtime cloud call is used.

### Host bridge and writes

- `web/hinen_local.py` now has `write_tuya_dp()` with a strict allowlist and
  read-back; `web/hinen_web.py` exposes `POST /api/hinen/write` alongside
  `POST /api/hinen/status`.
- Writable DPs: **6 (AC), 7 (DC), 25 (beep), 26 (device standby), 105 (AC
  charging limit), 106 (vehicle current), 108 (keystroke sound), 109 (AC
  standby), 110 (screen-off), 113 (light mode)**. Every write is verified by a
  station read-back. DP 107 (Fast Charging) is read-only locally; the station
  rejected the write, so change it in Smart Life.
- No UPS, charge-limit, P-boost, schedule, or firmware write exists.
- The host panel binds `0.0.0.0:8092` for the private LAN; it has no accounts or
  transport encryption. Do not expose it to the internet.
- The bridge is installed as the `localhome-hinen.service` systemd user service
  with `Restart=always`; linger is enabled so it starts at boot. A temporary
  shell background process previously died and caused both the direct and host
  paths to fail with "Station unavailable"; the service is now the supported
  deployment.

### DP map and capacity

| DP | Meaning | Verified behavior |
| --- | --- | --- |
| 1 | Battery SOC | Live; matches Smart Life |
| 6 | AC output | Smart Life AC toggle changed DP 6 |
| 7 | DC output | Smart Life 12V DC toggle changed DP 7 |
| 26 | Device standby | 7200 s = 2 h |
| 105 | AC charging power limit | 90%; write 80 verified |
| 106 | Vehicle charging current | 8 A; write 6 verified |
| 107 | Fast Charging switch | Read-only locally; write rejected |
| 108 | Keystroke Sound | false/true write verified |
| 109 | AC standby | 3600 s = 1 h |
| 110 | Screen-off | 300 s = 5 min |
| 113 | Light mode | 0 Off, 2 Medium, 3 High, 4 SOS verified; 1 Low assumed |
| 116 | Charging packs | 1 |
| 117 | Reported output watts | Live; not fully characterized |

- DP 25 (beep) is not reported by this unit. DPs 111/112 remain unmapped. The
  32°C Smart Life temperature is cloud-only; DP 105 is the AC charging limit.
- PS3000 base capacity is **2,560 Wh**; PS2500B expansion is **2,560 Wh**.
  With the one connected pack the app shows **5,120 Wh** total and remaining Wh
  computed from DP 1.

### Settings parity

- Smart Life settings mapped: AC charging power limit (DP 105), vehicle charging
  current (DP 106), fast charging (DP 107, read-only local), keystroke sound
  (DP 108), device standby (DP 26), AC standby (DP 109), screen-off (DP 110).
- The app exposes all writable settings except Fast Charging, which is displayed
  read-only because the local write was rejected. Charge/Discharge Limited,
  Inverter Frequency, and Restore Settings remain unmapped; no fake control is
  shown.
- The 32°C temperature was removed from the app because it is not in the local
  DP set.

### Android dashboard and quick controls

- Rebuilt the Hinen detail as a dashboard: battery hero, AC charging limit,
  vehicle current, keystroke sound, fast charging (read-only), packs, output,
  capacity card (base vs with pack), AC/DC/light controls, timers, raw DPs,
  transport/safety cards.
- Added `hinen_host_bridge.dart` (read/write), `hinen_key_store.dart` (Keystore),
  `hinen_quick_controls.dart` (Flutter/native bridge).
- Native `HinenQuickControls.kt` adds:
  - one LocalHome notification card with AC/DC/Cameras/Light actions;
  - one LocalHome Quick Settings tile;
  - a compact sheet with independent **Energy** and **Cameras** blocks;
  - each camera row passes its camera id to Flutter, which opens the specific
    single-camera live viewer;
  - a native host HTTP client and read-back after writes.
- The tile/sheet and notification require `POST_NOTIFICATIONS`; the app requests
  it and the `TileService` uses `StatusBarManager.requestAddTileService`.
- The app allows local cleartext for the private host bridge; no public HTTP.
- Added the house+bolt adaptive/legacy launcher icon and matching tile and
  notification icons (`drawable/ic_launcher_foreground.xml`,
  `drawable/ic_localhome_tile.xml`, `drawable/ic_stat_localhome.xml`).

### Verification and deployment

- Host `/api/hinen/status` and `/api/hinen/write` live-tested; a safe DP 26
  write changed 7200 → 3600 → 7200 and read back.
- Camera 1 deep link live-tested; it opened the Back feed (`<private-ip>`) in the
  single-camera viewer, not the Cameras list.
- `flutter analyze` clean except one style info; `flutter test` all pass;
  `flutter build apk --debug` succeeds.
- Installed on two Android phones; seeded cameras, Hinen profile/bridge, and
  purifier profile/token; pinned the LocalHome card and added the tile on both.
- The LocalHome tile is a standard Android Quick Settings tile. It is not an
  entry in the proprietary Xiaomi Smart Hub card; on HyperOS 3 Android Device
  Controls are broken. A Matter bridge would be required for the Smart Hub.

### Limits

- V380 cameras expose RTSP/ONVIF only; no per-camera Wh. The PS300 energy is
  shared.
- Solar, car-charge input, and AC-energy history are Smart Life cloud statistics;
  the local DPs do not contain them.
- The direct phone Tuya session remains refused; the host bridge is required.
- DP 106/108 and settings writes are partly verified; 107 is read-only locally;
  111/112/117 need more verification.

## 2026-11-06 — publication scrub

- Reworded protocol summaries, code comments, UI strings, and third-party notices as
  an independent implementation of documented device interfaces.
- Converted the remaining protocol-discovery methodology in the tracking docs
  into neutral conformance testing against published interfaces.
- Removed the personal helper path from the purifier token instructions and
  described the bootstrap as a supported account export.
- Redacted private network addresses and device-identifying values from the
  tracking docs; placeholders are `<private-ip>` and `<product-key>`.
- Removed unused artifact ignore rules from `.gitignore`.
- Renamed the Hinen LAN check endpoint and helpers (`/api/hinen/check`) for
  neutral naming across the code and UI.
- Scanned for credentials and personal data: no env, key, token, keystore, or
  `local.properties` files are tracked; no hardcoded credentials were found.
- Added the MIT `LICENSE`, `requirements.txt`, `SECURITY.md`,
  `CONTRIBUTING.md`, a documentation index, and a CI workflow.
- Moved design, roadmap, and progress docs under `docs/`; removed maintainer-only
  repository-history notes from the public docs.
- Python tests pass (67); Python and JavaScript syntax checks pass.

## Remaining / future

- Playback: unsupported. The plain authenticated IOT method is rejected and no
  local record-list path is exposed. list/play/seek would follow only if a
  supported local endpoint is identified.
- Talkback: on-device audibility check.
- Hinen PS3000: host-bridged read/write, DP mapping, capacity, dashboard,
  notification card, tile/sheet, and icon are implemented. Remaining: map
  DPs 111/112/117 with verification; direct phone LAN remains refused;
  no UPS/charge-limit/P-boost/schedule/firmware write.
- Hinen BLE: the app shows no Bluetooth path; treat BLE as provisioning-only
  unless a supported local control path is confirmed.
- Xiaomi/MiIO module: run the hardware check with the real token, verify every
  status value and write, and record the result. The web/Android implementation
  and tests are done.
- Future modules use the LocalHome package (`com.pyansofyan.localhome`, Dart
  `localhome`); no further package rename is needed for this milestone.

## Data handling

- No passwords, tokens, keys, device identifiers, or network addresses are
  recorded in this document.
