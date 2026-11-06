# LocalHome — Idea and Target

_Last updated: 2026-11-01_

## Vision

Build one local-first app for the home, replacing multiple third-party apps
where practical. The first module is a direct-LAN HiMost/V380 camera client. The same
app should later cover:

- **Hinen** home-energy devices (inverter/battery monitoring and control where a
  local protocol or local API exists).
- **Xiaomi Home / MiIO** devices on the local network.
- Other home devices only when their traffic can be kept on the private LAN.

The goal is not a cloud aggregator. It is a local control surface: explicit
private addresses, local credentials, no vendor account dependency, and a clear
failure when a device only exposes a cloud path.

## Current scope

The repository currently contains the **camera module**:

- A Flutter Android client (`android-app/`) with RTSP live view, ONVIF PTZ,
  white floodlight ON/AUTO/OFF, and experimental LAN talkback.
- A local browser test panel (`web/`) for light, PTZ, snapshots, and live MJPEG.
- Helper scripts (`scripts/`).

Target camera firmware:

```text
Hw_EV2X_NA1_XHR_E_V1.0_WF_20250312
```

The target camera is reached at an explicit RFC1918 IPv4 address. The exact
address and LAN password are not recorded in this document.

## What “local-only” means

- Camera sessions connect to an explicitly entered private IPv4 address.
- Do not use cloud dispatch, relay discovery, vendor accounts, hostnames, or
  fallback cloud behavior.
- Verify the actual destinations during testing; a private-IP field alone is not
  a guarantee that a feature stays local.
- Do not expose camera ports to the public internet with port forwarding.
- A Tailscale subnet router can provide remote private reachability, but the
  segment between that router and the camera still uses the camera's protocol.

## Important security distinction

The camera asking for a password is **application authentication**, not a guarantee of
encrypted transport. The V380 login uses reversible password encoding, and the
camera protocol does not currently establish cryptographically authenticated
encryption for login, control, audio, or video.

Therefore:

- The practical goal is **local-only routing**, not a claim of end-to-end
  cryptographic security.
- A login prompt or encrypted-looking payload is not a guarantee that credentials and
  all traffic are protected on the network.
- Keep an explicit risk acknowledgement before enabling the legacy protocol.
- If confidentiality/authenticity is mandatory, use a trusted gateway or a
  camera that supports a secure protocol. A client-only wrapper cannot encrypt
  the camera-facing side.

## Camera features and current status

1. Camera setup with Device ID, username, device password, and private LAN IPv4.
   **Partially implemented:** profiles store IP, RTSP path, and LAN password.
2. Login and live video, including reconnect and video/audio handling.
   **Live RTSP confirmed.** The proprietary live path is not used by the current
   Android viewer.
3. Live speaker audio where the firmware sends decodable audio.
   **Partially confirmed:** G.711 A-law is present; audible phone playback has
   not been verified.
4. PTZ start/stop and camera light controls.
   **Confirmed:** local ONVIF PTZ works; white floodlight ON/AUTO/OFF works over
   the authenticated LAN IOT session.
5. SD-card recording search by day and recording-type display.
   **Not implemented; next milestone.**
6. Recording playback, seeking, and supported playback speeds.
   **Not implemented; next milestone.**
7. Single-clip and date-range export.
   **Not implemented.**
8. Microphone talkback start, streaming, and stop.
   **Experimental:** LAN IOT audio sends, camera-side audibility pending.
9. Clear connection status, errors, and safe credential handling in the UI.
   **Implemented for the current camera features.**

## Beyond cameras

The longer-term LocalHome direction is a set of local device modules behind one
UI:

- **Camera module (current):** V380/HiMost direct-LAN video, PTZ, light, and
  recordings.
- **Xiaomi air purifier module (v2, implemented; target 4 Compact verified):**
  local miIO/MIoT status and control for the Smart Air Purifier 4 / 4 Pro /
  4 Compact. See
  [`idea-v2-xiaomi-air-purifier.md`](./idea-v2-xiaomi-air-purifier.md).
- **Hinen PS3000 module (v3, implemented):** Tuya LAN 3.4 discovery plus a
  LocalHome host bridge for local reads and confirmed-DP writes. The Energy
  dashboard, capacity, notification card, Quick Settings tile, and camera/energy
  sheet are implemented. The direct phone Tuya read is still refused by the
  station; the host bridge is the working path. See
  [`idea-v3-hinen-ps300.md`](./idea-v3-hinen-ps300.md).
- **Shared core (future):** device registry, private-address validation,
  credential storage, connection status, and a common web/Android shell.

Each module is local-first: confirm the local protocol before adding any cloud
call. Cloud is a last resort only — an explicit, rare, opt-in push when no local
path exists, never a silent fallback. Each module must be independently testable
and must fail closed when only a cloud path exists. The camera and purifier code
stay in parallel modules; avoid a speculative shared-core rewrite until the
remaining module boundaries are confirmed. Hinen now has a confirmed local host path.

## Protocol conformance testing

For every feature, verify the implementation against the device's documented
local interfaces:

- Confirm the device is reachable on its private address without a cloud
  endpoint.
- Verify the implemented transport, port, message framing, command identifiers,
  and request/response order against the published interface definition.
- Confirm whether the feature opens a new connection or reuses the current
  session.
- Verify session key handling and encryption behavior against the documented
  protocol.
- Record which behavior was tested on this firmware and which remains an
  assumption.
- Do not record credentials, device IDs, tokens, session values, MAC addresses,
  or media contents.

## Acceptance criteria

- The app and web panel connect only to explicitly configured private camera
  addresses.
- Live RTSP, light, and PTZ work on the target firmware; a working live stream
  does not confirm the other features.
- Playback is implemented only if a local path is verified; otherwise it
  is marked unsupported.
- Unsupported features fail clearly and never fall back to cloud.
- Documentation states the local-only boundary and the legacy protocol's lack
  of authenticated transport encryption.
- Tracking docs (`progress.md`, `plan.md`, `implementation.md`) are updated with
  each change.

## Work plan

1. Keep the current camera module healthy and documented.
2. Confirm and implement SD-card recording search and playback over the LAN.
3. Verify talkback audibility on the target.
4. Use the purifier module as the second protocol, then add Hinen before
   restructuring into a shared core; use that remaining protocol to drive the
   module boundaries.
5. Use the LocalHome Android/Dart package (`com.pyansofyan.localhome`, Dart
   `localhome`) for future modules. The previous HiMost Local package is
   migrated and removed during install.
6. Exercise the full feature matrix on the target firmware and record outcomes
   in `progress.md`.

## Current status — 2026-11-01

- Live RTSP: confirmed.
- White floodlight ON/AUTO/OFF: confirmed.
- ONVIF PTZ: confirmed by user.
- Web test panel: implemented and tested.
- Install script: preferred USB path; LocalHome is installed, 3 profiles were
  migrated, and the previous HiMost Local app was removed.
- Recording search/playback: SD card is present; the documented ONVIF and RTSP
  services do not expose a record list and the plain IOT session rejects the
  request. Playback is unsupported; see `progress.md` and `plan.md`.
- Xiaomi air purifier module (v2): implemented for the 4/4 Pro and the target
  4 Compact (`xiaomi.airp.cpa4`, firmware `2.2.10_0021`, ESP32). On the
  Compact, status, mode, favorite, and screen-brightness writes are verified
  with read-back, and the app is visually verified. The Android **Xiaomi** tab
  is a generic local miIO device list; other models are identity-only until
  their control maps exist. Power-off and filter reset are pending. See
  `idea-v2-xiaomi-air-purifier.md` and `progress.md`.
- Purifier web panel: implemented on port 8091; Python and Flutter tests pass,
  `flutter analyze`, and the debug APK build pass.
- Hinen PS3000 module (v3): implemented host-bridged reads and confirmed-DP
  writes. The Energy dashboard, capacity card, AC/DC/light, timers, notification
  card, and LocalHome Quick Settings tile are live; the tile sheet has
  independent Energy/Cameras blocks and specific-camera deep links. The direct
  phone Tuya session is still refused; the host bridge is the working path. See
  `idea-v3-hinen-ps300.md`.
- Camera energy: V380 cameras expose RTSP/ONVIF only; no per-camera Wh. The
  PS3000 energy is shared. Solar, car-charge, and AC-energy history remain Smart
  Life cloud statistics.
- Credits and licenses are in `THIRD_PARTY_NOTICES.md`.
