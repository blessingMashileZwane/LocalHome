# LocalHome for Android

This native Android client is the LocalHome app. It implements the target
camera's **confirmed RTSP live-view path**, the Xiaomi air-purifier module over
the local miIO/MIoT link, and the **Hinen PS3000** Energy dashboard with
confirmed host-bridged controls. It does not use a V380/Xiaomi/Hinen account,
cloud dispatch, or a public relay. The bottom tabs are **Cameras**, **Xiaomi**,
and **Energy**.

## Run and build

For a USB-connected device, the preferred install path is the repository's
install script. It builds the debug APK, installs the LocalHome package
(`com.pyansofyan.localhome`), migrates profiles from the previous HiMost Local
app, injects the LAN passwords from `~/.config/v380decoder-test.env`, and
launches the app without printing any password. If MIUI reports
`INSTALL_FAILED_USER_RESTRICTED`, enable Developer options → **Install via
USB**, keep the phone unlocked, and rerun the script:

```sh
cd ..
bash scripts/install_app.sh
```

For hot reload during development, install Flutter and the Android SDK, then
from this directory run:

```sh
flutter pub get
flutter run
```

Build a locally installable ARM64 APK with:

```sh
flutter build apk --release --target-platform android-arm64
```

For per-architecture APKs instead, use `flutter build apk --release
--split-per-abi`. Release signing is still configured with Flutter's development
debug key; configure a private production signing key before distribution.

The camera list is dynamic: use **Add camera** to create a named profile with a
private IPv4 address and RTSP path. Three camera profiles are included as
defaults; set their private addresses. Profiles can be edited or removed. Use a
camera's **View camera** action to open its own full-width viewer, or select
**View all** to open the separate grid viewer. The grid starts one independent,
direct RTSP stream per profile, staggering starts to reduce decoder startup
contention. While a stream starts, its tile shows a loading spinner and camera
name. Tap any grid tile to open that camera in a large focused viewer; the grid
streams pause while it is open and resume when you return. Pinch to zoom (up to
5x) and pan the enlarged image. Individual feeds can be stopped/reconnected, or
all feeds can be started/stopped from the grid toolbar.

The client uses TCP port 554. The tested HiMost cameras work with
`/live/ch00_0`; other firmware may use a different path. Addresses and paths
are stored locally as non-secret preferences; no camera password is stored or
sent by this RTSP flow. The app requires explicit acknowledgment of the
unauthenticated, unencrypted stream warning before opening a viewer.

## Current support

| Feature                                      | Status                                                                                                                                                                                                          |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Explicit private IPv4 camera address         | Implemented; public addresses, hostnames, and IPv6 are rejected before connection                                                                                                                               |
| Direct RTSP live video                       | Confirmed on the target phone at `/live/ch00_0`; all three supplied feeds rendered simultaneously and remained live for a one-minute foreground check.                                                          |
| Incoming RTSP audio                          | G.711 A-law track is present; audible phone playback not yet verified                                                                                                                                           |
| PTZ                                          | Confirmed working on the target: local ONVIF pan/tilt controls in the focused viewer.                                                                                                                           |
| Camera light (white floodlight)              | Confirmed working on the target: ON/AUTO/OFF over the authenticated LAN IOT session (TCP 8089).                                                                                                                  |
| SD-card search/playback, seek, speed, export | Not supported: the camera exposes no local record-list path through its documented services. |
| Microphone talkback                          | Experimental; sends G.711 A-law over the authenticated LAN IOT session (TCP 8089) using the camera LAN password. Camera-side audibility pending on-device test.                                                   |
| Cloud fallback                               | None                                                                                                                                                                                                            |

The target's RTSP endpoint returned media without authentication in the
recorded LAN test. RTSP here is not encrypted or authenticated. Use the app
only on a trusted private network; a private IP restriction is not a substitute
for camera authentication or transport encryption.

In the focused viewer, open the PTZ control pad. Tap a direction for a short
nudge or press and hold it to continue moving; release to send Stop. PTZ uses
the camera's advertised ONVIF endpoint on local
TCP port 8899, selects a media profile with PTZ configuration, and rejects
service URLs that do not point back to the configured private camera IP. Requests
use a conservative velocity cap of 0.15 and a short camera-side timeout. The
focused live view uses a smaller decoder buffer to reduce the time before camera
movement appears in the video; the multi-camera grid keeps its existing buffer
for stability. Short taps keep the move active for at least 300 ms so a tap
produces a visible nudge before Stop. PTZ is confirmed working on the target:
the local ONVIF controls physically move the camera.

In the focused live view, tap the **bulb icon** in the top overlay to open the
light control. Choose **ON**, **AUTO**, or **OFF**. This uses the camera's
authenticated local IOT session on TCP 8089 and requires the camera LAN password
(QR field 8), the same password used for talkback. ON keeps the white light on
(the camera may turn it off automatically after two hours), OFF keeps it off,
and AUTO lets the camera decide from its light sensor. There is no cloud
fallback. The control is implemented in `lib/lan_light.dart` on top of
`lib/lan_iot.dart`.

In the focused live view (large tile) a **talk button** sits at the lower
right. Tapping it requests microphone permission, captures mono PCM16 at 8 kHz
with the `VOICE_COMMUNICATION` audio source for echo suppression, and sends
G.711 A-law media frames over the camera's authenticated LAN IOT session on TCP
8089. The session uses the camera LAN password (QR field 8) and the media
session prelude implemented in `lib/lan_talkback.dart`. Incoming camera audio is
muted while talking to avoid feedback and restored on stop. Talk stops on toggle
off, leaving the viewer, app pause, permission loss, or connection error; the
microphone is never recorded or logged. Camera-speaker audibility is still an
open on-device test.

## Xiaomi devices (purifier first)

The **Xiaomi** tab is a generic local miIO/MIoT device list. Add a device by
private IPv4 address and device token (32 hex characters). Known purifier
models (4/4 Pro/4 Compact) get the model-aware status and controls below; other
Xiaomi models show their model/firmware and a clear "not implemented yet" state.
The token is entered in the app and stored in the Android keystore via
`flutter_secure_storage`; it is not compiled into the APK, not written to the
profile JSON, and never logged.

Status and controls are model-aware. The target 4 Compact shows power, mode,
PM2.5, filter life, favorite level, child lock, buzzer, and screen brightness;
it has no fan level, anion, humidity, temperature, or temperature unit. Its mode
is 0–2 and favorite level is 0–14. Every write is read back; the read-back
retries briefly because the Compact can apply a write one request late. Filter
reset is confirmed first and then read back. Unknown models are read-only.
There is no cloud fallback.

The client uses UDP port 54321. miIO token encryption is not authenticated
transport encryption; use it only on a trusted private LAN. `allowBackup` is
disabled so encrypted token blobs are not restored without their keystore key.
The implementation is in `lib/miio_packet.dart`, `lib/miio_airpurifier.dart`,
`lib/airpurifier_status.dart`, `lib/airpurifier_profile.dart`, and
`lib/token_store.dart`.

### Seeding the saved token (debug)

For a USB-connected debug build, the repository can seed the profile and token
without printing the token:

```sh
python3 scripts/inject_purifier.py --ip <private-ip>
```

It reads `MIIO_TOKEN` from `~/.config/localhome-miio.env`, verifies it against
the purifier, writes the purifier profile into shared preferences, and stages a
token file in the app's private files directory. On launch the app imports the
token into the Android keystore and deletes the staging file. Release builds
ignore the staging file and require manual token entry.

## Energy devices (Hinen PS3000)

The **Energy** tab is a live dashboard for the Hinen PS3000. The station is a
**Tuya LAN 3.4** device on TCP 6668, identified by a private IPv4 address and
product key (`<product-key>` on this network). The app attempts the direct
phone Tuya read first; the station currently closes that session, so the app
falls back to the LocalHome host bridge (`http://<host>:8092`). The host keeps
the local key; the app does not send it over the bridge.

The dashboard shows battery, AC charging limit, vehicle current, fast charging
(read-only), keystroke sound, charging-pack count, reported output, capacity,
AC/DC/light, device/AC standby, screen-off, and raw DPs. The capacity card shows
the PS3000 base (**2,560 Wh**) and with the connected PS2500B pack (**5,120 Wh**);
remaining Wh is computed from DP 1. Writes are limited to the confirmed DPs (AC
6, DC 7, beep 25, device standby 26, AC limit 105, vehicle current 106, keystroke
108, AC standby 109, screen-off 110, light 113), require confirmation, and are
read back. Fast Charging (DP 107) is read-only locally. The 32°C Smart Life
temperature is cloud-only; it is not shown as a local reading.

The app profile stores `{id,name,address,productKey,model,deviceId,bridgeUrl}`;
the local key is in the Android Keystore for the debug direct path. There is no
runtime cloud fallback. V380 cameras expose no per-camera energy; the PS3000
energy is shared. Solar, car-charge, and AC-energy history are Smart Life cloud
statistics and are not available locally.

### Notification card and control-center tile

The app can pin a **LocalHome** notification card and add a **LocalHome** Quick
Settings tile. The card shows the PS3000 summary plus the camera count and has
AC/DC/Cameras/Light actions. The tile opens a compact sheet with independent
**Energy** and **Cameras** blocks; each camera card opens that camera's specific
single-camera viewer. The tile is a standard Android `TileService`, not an entry
in the proprietary Xiaomi Smart Hub card. On HyperOS 3 Android Device Controls
are broken; the tile/card are the supported third-party paths.

The launcher, tile, and notification share the house+bolt icon. The launcher uses
adaptive and legacy resources; the tile/notification use white vectors.

For a USB-connected debug build, seed the profile, device ID, bridge URL, and
key stage (from the repository root):

```sh
uv run --with tinytuya python3 scripts/inject_hinen.py \
  --ip <private-ip> --bridge-url http://<host>:8092
```

The station is managed by the Hinen/SolisCloud app over its cloud. BLE is
treated as provisioning-only; no runtime cloud path is used.

## Tests

Run the analyzer and tests with:

```sh
flutter analyze
flutter test
```
