# LocalHome — Plan and Status

_Last updated: 2026-11-01_

> **Living document.** Move items between **Done**, **Next**, and **Later** as
> work happens, and update `progress.md` with the actual result.

## Goal

Build a local-first home client, starting with the HiMost/V380 camera module,
then adding other local device modules (Hinen energy, Xiaomi/MiIO) behind one
app. No vendor account, cloud dispatch, relay, or public fallback address.

## Device

- Target firmware: `Hw_EV2X_NA1_XHR_E_V1.0_WF_20250312`.
- Private LAN access only; the exact address and LAN password are not recorded
  in the repository.
- Current camera ports: RTSP 554, ONVIF 8899, IOT 8089. TCP 8800 is refused.

## Done

### Camera module

- Direct RTSP live view at `/live/ch00_0`.
- Direct IOT LANPASS session on TCP 8089 with AES-CBC request bodies.
- White floodlight ON / AUTO / OFF using
  `DPID_LIGHT_FLOODLIGHT_SW = 0x00050100` (0=auto, 1=on, 2=off).
- Local ONVIF PTZ with a conservative velocity cap.
- Focused viewer overlays for PTZ, light, and talk.
- Multi-camera grid and per-camera profiles.
- Private-IPv4 validation and no cloud fallback.

### Tooling

- Local web panel for light, PTZ, snapshot, and MJPEG live preview.
- Python LAN IOT and ONVIF helpers.
- USB install script that builds, installs, seeds LAN passwords, and launches.
- Flutter analyze/tests and web syntax checks pass.

### Repository

- Renamed the project/app display name, Android package
  (`com.pyansofyan.localhome`), Dart package (`localhome`), Kotlin path, and
  microphone MethodChannels to LocalHome.
- Updated the installer to migrate profiles from the previous
  `com.pyansofyan.himost_camera` app and remove the old app after migration.
- Removed the legacy `.NET` client and its CI/Docker/VS configuration.
- Restored the five tracking docs.
- Verified third-party licenses and added `THIRD_PARTY_NOTICES.md` with credits.
  The earlier `PyanSofyan/V380Decoder` project has no declared license and no code
  is included from it.

### Install and migration

- LocalHome (`com.pyansofyan.localhome`) is installed and running.
- The injector migrated 3 camera profiles and 3 LAN passwords from
  `com.pyansofyan.himost_camera`; the old package was uninstalled.
- MIUI required Developer options → **Install via USB** before the install was
  accepted.

## Playback — current status (2026-10-31)

### Known local behavior

- The SD card is present and in use (about 15.6 GB total, 525 MB free,
  15.1 GB used).
- The record-list method **197152** (`0x00030220`) and replay methods
  **197154**/**197156** are not exposed over the documented ONVIF or RTSP
  services. The plain authenticated IOT request returns **1114** with no record
  list.
- SD/record DPIDs use group 2 (`0x00020100`–`0x00020106`).

### Next — P3: supported playback path

- Playback is currently marked unsupported: the camera exposes no local
  record-list path through its documented services.
- If a supported local endpoint is identified, implement list/play/seek in the
  web panel first, then in the Android app.

### Phase P4 — web-first playback

- Add record search/list, play, and seek to the web panel first for fast
  iteration.
- Use a local player for the returned media; do not claim success from metadata
  alone.
- Validate seeking and record-type display.

### Phase P5 — Android playback

- Add recording search/list and playback/seek to the Android focused viewer
  only after the web path works.
- Preserve the private-IP-only and fail-closed behavior.
- Add tests for date/range parsing, record metadata bounds, and error states.

### Later playback work

- Speed control.
- Single-clip and date-range export.
- Recording-type display polish.
- Reconnect/seek behavior across segment boundaries.

## v2 — Xiaomi air purifier (implemented; target Compact verified)

Scope and protocol summary:
[`idea-v2-xiaomi-air-purifier.md`](./idea-v2-xiaomi-air-purifier.md).

### Done

- Local miIO/MIoT client on UDP 54321 with token-derived AES-CBC framing,
  hello, `miIO.info`, chunked `get_properties` (15 max), `set_properties`, and
  `action`.
- Runtime model maps for the Smart Air Purifier 4 (`zhimi.airp.mb5a`), 4 Pro
  (`zhimi.airp.vb4`), and 4 Compact (`xiaomi.airp.cpa4`), including the 15.1
  fallback on the 4 Pro and the Compact's smaller tree. Unknown models are
  read-only.
- Model-aware web and Android controls: unsupported properties are hidden and
  the mode/favorite ranges come from the selected model. Read-back retries
  briefly because the Compact applies a write one request late.
- Android **Xiaomi** tab: any local miIO/MIoT device can be stored; purifier
  models get controls, other models get an identity-only status and a clear
  "not implemented yet" card.
- Fixed the Android UDP transport (fresh socket per exchange); the Compact is
  visually verified in the app (status and controls).
- Web panel `web/airpurifier_web.py` on port 8091: status, allowlisted controls
  with read-back, filter reset with confirmation, discovery, and host-side
  JSONL history.
- Android: new **Air purifier** tab; profiles in shared preferences, token in
  the Android keystore; status and controls with read-back, a 15 s refresh
  timer, and a filter-reset confirmation.
- `flutter_secure_storage` dependency, `allowBackup=false`, and the injector
  now merges camera profiles instead of replacing the preference map.
- Token import via a supported local account export and the mode-600 drop file.
- Debug seeding: `scripts/inject_purifier.py` verifies the env token, seeds the
  purifier profile, and stages a token file; `lib/debug_token_import.dart`
  imports it into the Android Keystore on launch and deletes it.
- Target 4 Compact verified: model/firmware/status, plus mode, favorite, and
  screen brightness writes with read-back. The app is visually verified, and
  the seeded profile/Keystore token survived a reinstall.
- Tests: 43 Python unit tests and 61 Flutter tests pass; `flutter analyze` and
  the debug APK build pass.

### Next

- Add control maps for other Xiaomi device classes (lights, plugs, etc.); the
  **Xiaomi** tab already stores them as identity-only.
- Exercise power-off, filter reset, child lock, and buzzer writes on the
  Compact (filter reset with explicit confirmation).
- The 4 and 4 Pro maps remain untested on hardware. Schedules/timers remain
  unsupported unless a device-side path is confirmed.

## Hinen PS3000 module (v3) — host-bridged read/write

Status: implemented 2026-11-01. The station is a PS3000 Tuya LAN 3.4 device.
The direct phone LAN read is refused by the station; the host bridge is the
working path. Confirmed-DP writes are implemented through the host bridge.

Done:

- Confirmed the PS3000 is a Tuya LAN 3.4 device (TCP 6668, product key
  `<product-key>`, encrypted); it is managed by the Hinen/SolisCloud app.
- Obtained the Tuya local key through the Smart Life path and imported it
  without printing it; the key is in the mode-600 host env and the debug app's
  Android Keystore, never in the profile or APK.
- Added `web/hinen_local.py`, `web/hinen_web.py` (host bridge, port 8092), and
  `web/static/hinen/`. The panel exposes status and allowlisted write; every
  write is read back.
- Added the Android **Energy** dashboard (`hinen_profile.dart`,
  `hinen_status.dart`, `hinen_key_store.dart`, `hinen_host_bridge.dart`,
  `hinen_home_page.dart`, `hinen_controls.dart`): SOC, capacity, AC/DC/light,
  timers, AC charging limit, vehicle current, keystroke sound, fast charging
  (read-only), packs, output, raw DPs. The direct path is attempted,
  then the host bridge.
- Added `hinen_quick_controls.dart` and native `HinenQuickControls.kt`: a
  LocalHome notification card, Quick Settings tile, compact Energy/Cameras
  sheet, and camera deep links to the specific live viewer.
- Added the house+bolt adaptive/legacy app icon and matching tile/notification
  icons.
- Verified the host `/api/hinen/status` and `/api/hinen/write` with a safe
  DP 26 write and read-back; Flutter analyze/tests/build pass.

Next:

- Map the remaining DPs (111/112/117) with verification; do not assign fake
  meanings. DP 117 is reported output; 111/112 are unmapped.
- Consider a local history/log of known DPs if required; solar, car-charge, and
  AC-energy history remain Smart Life cloud features.
- The direct phone Tuya session is still refused; investigate only if a
  reproducible station-side fix appears. The host bridge is the supported path.
- The Xiaomi Smart Hub card itself is proprietary; the LocalHome tile/card are
  the supported notification/control-center paths. A Matter bridge is the only
  route into the Smart Hub panel.

Safety gates:

- Writes are limited to DPs 6, 7, 25, 26, 105, 106, 108, 109, 110, 113;
  confirmation and read-back are mandatory. Fast Charging (DP 107) is read-only
  locally.
- No UPS, charge-limit, P-boost, schedule, or firmware write.
- Fail closed on timeout/unknown; no silent cloud fallback.
- The local key is a credential, never logged or committed.

## Later — LocalHome modules

Do not restructure the app until the remaining modules have confirmed local
protocols.

### Hinen PS3000 module (v3)

See the v3 section above. Host-bridged read/write is implemented for the
confirmed DPs; the direct phone LAN session is still refused. No UPS, charge
limit, P-boost, schedule, or firmware write is approved.

### Shared core

- Device registry, private-address guards, credential storage, connection state.
- Module interfaces that the camera, Hinen, and MiIO modules implement.
- Shared web/Android shell.

## Success criteria

- Live, light, and PTZ remain working on the target.
- Playback is either verified end-to-end over the LAN or explicitly marked
  unsupported.
- On the target 4 Compact, status, mode, favorite, and screen brightness are
  verified over the LAN with no Xiaomi account; power-off and filter reset are
  pending.
- On the Hinen PS3000, Tuya LAN discovery and the host bridge work without an
  account; live DPs, capacity, AC/DC/light, timers, and the LocalHome
  notification card/tile are implemented. Confirmed writes are host-bridged,
  confirmed, and read back. The direct phone LAN path remains refused; no UPS,
  charge-limit, P-boost, schedule, or firmware write exists.
- Every module connects only to private addresses and has no silent cloud
  fallback.
- Unsupported features show a clear error.
- `progress.md`, `implementation.md`, and this plan stay current.

## Repository status

LocalHome is the project and app display name. The Android applicationId is
`com.pyansofyan.localhome` and the Dart package is `localhome`.

Credits and license texts for the third-party projects are in
[`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## References

- [`idea.md`](./idea.md) — vision and target.
- [`idea-v2-xiaomi-air-purifier.md`](./idea-v2-xiaomi-air-purifier.md) — v2 air purifier scope.
- [`idea-v3-hinen-ps300.md`](./idea-v3-hinen-ps300.md) — v3 Hinen PS3000 host bridge, confirmed controls, capacity, tile, and safety gates.
- [`progress.md`](./progress.md) — chronological progress and current state.
- [`implementation.md`](./implementation.md) — architecture and behavior.
- [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) — credits and licenses.
- [`README.md`](../README.md) — project overview and run instructions.
