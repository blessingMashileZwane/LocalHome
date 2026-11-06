# LocalHome

Local-first Android client and local web panels for home devices. Camera,
Xiaomi purifier, and Hinen PS3000 traffic stays on the private LAN. There is no
vendor account, cloud dispatch, relay server, or silent cloud fallback at
runtime.

Modules:

- **Cameras** — direct RTSP live view, local ONVIF PTZ, white floodlight, and
  experimental LAN talkback.
- **Xiaomi** — local miIO/MIoT status and control for supported air purifiers.
- **Energy** — Hinen PS3000 dashboard and allowlisted controls through a local
  host bridge.

> **Status: experimental hobby project.** It is not production software. The
> Energy module can switch mains power; every write requires confirmation and is
> read back, but you use it at your own risk. Local-first means traffic stays on
> your LAN; it does not mean the link is cryptographically secure.
>
> LocalHome is not affiliated with or endorsed by V380/HiMost, Xiaomi, Hinen,
> Tuya, or Smart Life.

## Requirements

| Component | Needed for |
| --- | --- |
| Python 3.11+ and `cryptography` | Web panels and helper scripts |
| `ffmpeg` on `PATH` | Camera snapshot/MJPEG and Local DVR |
| Flutter and the Android SDK | Building the Android app |
| `adb` | USB install and profile-seeding scripts |
| `uv` (optional) | On-demand `tinytuya`, `micloud`, `bleak`, `zeroconf` |

```sh
python3 -m pip install -r requirements.txt
```

## Quick start

```sh
# Camera panel (http://127.0.0.1:8090)
python3 web/camera_web.py

# Air-purifier panel (http://127.0.0.1:8091)
python3 web/airpurifier_web.py

# Hinen PS3000 host bridge (http://127.0.0.1:8092)
uv run --with tinytuya python3 web/hinen_web.py

# Android app (USB-connected device)
bash scripts/install_app.sh
```

All servers bind to `127.0.0.1` by default. Device credentials are read from
mode-600 env files under `~/.config/` or entered per request; they are never
logged or committed. See the module sections below for each device.

## Repository layout

| Path | Purpose |
| --- | --- |
| `android-app/` | Flutter Android app: camera viewer (RTSP live view, ONVIF PTZ, white floodlight, experimental talkback), the Xiaomi module, and the **Energy** tab for the Hinen PS3000 dashboard, allowlisted controls, capacity, notification card, and LocalHome Quick Settings tile. |
| `web/` | Local browser panels: the camera test panel (light, PTZ, snapshot, MJPEG, Local DVR), the air-purifier status/control panel, and the Hinen PS3000 discovery/read/write host panel. |
| `scripts/` | Local helper scripts: the LAN-password QR helper, the protected key/token importers, the Hinen profile/key seeder, and the optional one-time Xiaomi token bootstrap. |
| `tests/` | Python unit tests for the miIO client, Hinen discovery/key handling, shared IP guard, and profile-injector merge. |
| `docs/` | Architecture, protocol, module, roadmap, and progress documents. |

LocalHome is a local-first hub for cameras, Xiaomi air purifiers, and Hinen
PS3000 backup power. The camera module is the working baseline; the Xiaomi
air-purifier module is implemented and verified on the target 4 Compact; the
Hinen v3 module is implemented with host-bridged read/write, confirmed DP
mapping, capacity, notification card, and LocalHome tile. The direct phone LAN
path is still refused by the station, so the host bridge is the working path.
Cloud is a rare, explicit last resort, never a silent fallback.

## Documentation

| File | Purpose |
| --- | --- |
| [`docs/README.md`](./docs/README.md) | Documentation index. |
| [`docs/idea.md`](./docs/idea.md) | Vision, scope, local-first rule, and acceptance criteria. |
| [`docs/implementation.md`](./docs/implementation.md) | Architecture, protocols, endpoints, and behavior contracts. |
| [`docs/idea-v2-xiaomi-air-purifier.md`](./docs/idea-v2-xiaomi-air-purifier.md) | Xiaomi air-purifier module design. |
| [`docs/idea-v3-hinen-ps300.md`](./docs/idea-v3-hinen-ps300.md) | Hinen PS3000 module design, DP map, and write-safety gates. |
| [`docs/plan.md`](./docs/plan.md) | Roadmap and current phase status. |
| [`docs/progress.md`](./docs/progress.md) | Maintainer progress log with dated results. |
| [`docs/roadmap-next.html`](./docs/roadmap-next.html) | Product notes: candidate next features. |
| [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md) | Credits, licenses, and distribution caveats. |

Maintainers: update `docs/progress.md` and `docs/plan.md` with each change.

## Confirmed on the target camera

Tested firmware: `Hw_EV2X_NA1_XHR_E_V1.0_WF_20250312`.

| Feature | Status |
| --- | --- |
| Direct RTSP live video | Confirmed at `/live/ch00_0` on TCP 554. |
| Local ONVIF PTZ | Confirmed: pan/tilt/stop work over TCP 8899. |
| White floodlight | Confirmed: ON / AUTO / OFF over the authenticated LAN IOT session on TCP 8089. |
| Camera-to-phone audio | G.711 A-law track present; audible phone playback not verified. |
| LAN talkback | Experimental; sends audio to the camera over the LAN IOT session. Camera-side audibility still pending. |
| SD-card search/playback/export | Not exposed by the camera's ONVIF or RTSP services. The plain authenticated IOT path returns no record list; playback is unsupported. |
| Local DVR | Implemented in the web panel: records the live RTSP stream to the panel host and plays/scrubs the clips in the browser. Verified end-to-end. |
| Cloud fallback | None. |

An earlier `.NET` client targeted the legacy TCP 8800 interface, which this
firmware refuses. It is not part of the current working client.

## Xiaomi air purifier (v2)

Implemented for the Xiaomi Smart Air Purifier 4 (`zhimi.airp.mb5a`), 4 Pro
(`zhimi.airp.vb4`), and 4 Compact (`xiaomi.airp.cpa4`) over the local
miIO/MIoT protocol on UDP 54321. No Xiaomi account or cloud endpoint is used.
The target unit is a 4 Compact (`xiaomi.airp.cpa4`, firmware `2.2.10_0021`,
ESP32); its status and reversible mode/favorite/brightness writes are verified.

In the Android app the tab is now **Xiaomi**: add any local miIO/MIoT device by
private IP and token. Purifier models get the model-aware controls below; other
models are identified (model and firmware) and shown as not yet supported for
control. The web panel remains purifier-specific.

| Feature | Status |
| --- | --- |
| Local status | Implemented per model. On the target 4 Compact: power, mode, PM2.5, filter life/used/left, motor speed, favorite level, screen brightness. |
| Local controls | Implemented per model. On the target 4 Compact: power, mode (auto/sleep/favorite), favorite level 0–14, child lock, buzzer, screen brightness. No fan level/anion/humidity/temperature on the Compact. |
| Verified writes | On the target 4 Compact: mode, favorite level, and screen brightness, each with a read-back. Power-off and filter reset are not exercised yet. |
| Filter reset | Implemented behind an explicit confirmation and a read-back. |
| Read-back | Retries briefly because the Compact can apply a write one request late. |
| Token storage | Android keystore (`flutter_secure_storage`); the host panel reads `MIIO_TOKEN` from a mode-600 env file or the panel field. |
| History | Web panel only: JSONL readings under `~/LocalHome-purifier/`. |
| Schedules/timers | Unsupported; no cloud fallback. |

Run the purifier panel:

```sh
python3 web/airpurifier_web.py
```

Open <http://127.0.0.1:8091/>. The token is a 16-byte local control secret (32
hex characters); store it in `~/.config/localhome-miio.env` (mode 600) or paste
it into the panel. It is never logged or stored by the browser. In the Android
app, open the **Xiaomi** tab and add the private IP plus token; the token goes
into the Android keystore, not the profile JSON.

For a USB-connected debug build, seed the saved token without typing it:

```sh
python3 scripts/inject_purifier.py --ip <private-ip>
```

It verifies the token against the purifier, seeds the profile in shared
preferences, and stages a token file. On launch the app imports it into the
Android keystore and deletes the staging file. Release builds ignore the debug
staging file and require manual token entry.

If you don't have the token, use the optional one-time bootstrap (it prompts
locally, writes only `MIIO_TOKEN` to the mode-600 env file, and is never used
at runtime):

```sh
uv run --with micloud python3 scripts/miio_token_from_cloud.py
```

Use `--region` if the account is not on the European cloud and `--list` to see
matching purifiers first.

If `micloud` reports `MiCloudAccessDenied`, the region is not the cause — that
login is global. The account most likely has 2FA or a captcha challenge. Use a
supported account export for those accounts, then copy only the purifier's
token. Do not paste the token into chat.

To keep the token out of shell history and chat, paste only the purifier token
into the protected drop file and import it:

```sh
install -m 600 /dev/null ~/.config/localhome-miio-token.txt
# open the file in your editor and paste only the token
scripts/set_miio_token.py
rm ~/.config/localhome-miio-token.txt
```

The importer validates one 32-hex token, writes it to
`~/.config/localhome-miio.env` (mode 600), and prints only the length.

Start the local purifier panel and add the device there:

```sh
python3 web/airpurifier_web.py
```

See [`docs/idea-v2-xiaomi-air-purifier.md`](./docs/idea-v2-xiaomi-air-purifier.md)
for the protocol summary and decision gates.

## Hinen PS3000 (v3) — host-bridged energy

Status 2026-11-01: implemented local reads and confirmed-DP writes. The station
is a **Tuya LAN 3.4** device on TCP 6668, encrypted, product key
`<product-key>`; the device is managed by the Hinen/SolisCloud app. The direct
phone LAN read is still closed by the station even though the request follows
the documented Tuya LAN 3.4 framing; this is a station/session restriction. The
app therefore falls back to the LocalHome host panel. The host keeps the local key
and performs the Tuya read or write; the phone does not send the key over the
bridge.

The 16-character **local key** was imported once through the Smart Life account
path and saved from a mode-600 drop file. It is never printed, committed, placed in the
Android profile, or included in the APK. The host uses the mode-600 env file;
there is no runtime cloud call.

```sh
# one-time protected key import; paste only the key into the drop file
install -m 600 /dev/null ~/.config/localhome-hinen-key.txt
python3 scripts/set_hinen_key.py
rm ~/.config/localhome-hinen-key.txt

# seed profile, device ID, bridge URL, and key for a debug app
uv run --with tinytuya python3 scripts/inject_hinen.py \
  --ip <private-ip> --bridge-url http://<host>:8092
```

```sh
# host bridge: discovery, read, and allowlisted write on port 8092
uv run --with tinytuya python3 web/hinen_web.py --bind 0.0.0.0 --port 8092
```

For a stable bridge that survives terminal exits and reboots, install the
provided systemd user service:

```sh
cp scripts/localhome-hinen.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now localhome-hinen.service
loginctl enable-linger "$USER"   # start at boot without a login session
```

`systemctl --user status localhome-hinen.service` and
`journalctl --user -u localhome-hinen.service -f` show its state and logs. The
service runs `Restart=always`; if the host IP changes, update the bridge URL in
the app profile or add a DHCP reservation for the host.

Open <http://127.0.0.1:8092/>. The panel can take a one-off local key or read
`HINEN_LOCAL_KEY` from `~/.config/localhome-hinen.env` (mode 600; an optional
`HINEN_DEVICE_ID` line). It never stores or returns the key. It exposes:

- `POST /api/hinen/status` — read the station DPs.
- `POST /api/hinen/write` — write one allowlisted DP and read the station back.

Writes are limited to DPs **6, 7, 25, 26, 105, 106, 108, 109, 110, 113**: AC,
DC, beep, device standby, AC charging limit, vehicle charging current, keystroke
sound, AC standby, screen-off, and light mode. DP 107 (Fast Charging) is
read-only locally; the station rejects that write, so change it in Smart Life.
There is no write path for UPS, charge/discharge limits, P-boost, schedules, or
firmware. The Android app sends writes through this bridge, not through the
phone's direct Tuya session.

The app profile contains `{id,name,address,productKey,model,deviceId,bridgeUrl}`
and no local key. The **Energy** tab is a live dashboard: PS3000 status, AC/DC/
light, timers, and capacity. A write requires confirmation and is verified by a
station read-back. The **LocalHome** notification card and Quick Settings tile
expose Energy plus the camera list; the tile sheet uses independent Energy and
Cameras blocks, and each camera row opens that camera's live viewer directly.

Confirmed DP mapping:

| DP | Meaning | Verified behavior |
| --- | --- | --- |
| 1 | Battery state of charge | Live read; matches Smart Life |
| 6 | AC output | Toggling Smart Life AC changed DP 6 |
| 7 | DC output | Toggling Smart Life 12V DC changed DP 7 |
| 26 | Device standby seconds | 7200 = 2 h; Smart Life setting |
| 105 | AC charging power limit (%) | Smart Life shows 90%; write 80 verified |
| 106 | Vehicle charging current (A) | Smart Life shows 8 A; write 6 verified |
| 107 | Fast Charging switch | Read-only locally; write true did not verify |
| 108 | Keystroke Sound | Write false/true verified |
| 109 | AC standby seconds | 3600 = 1 h |
| 110 | Screen-off seconds | 300 = 5 min |
| 113 | Light mode | 0 Off, 1 Low, 2 Medium, 3 High, 4 SOS; 2/3/4 verified, 1 assumed |
| 116 | Connected charging packs | 1 on this unit |
| 117 | Reported output watts | Read live; not yet fully characterized |

DP 25 (beep) is not reported by this unit. DPs 111/112 remain unmapped. The
32°C temperature shown in Smart Life is not exposed by the local DP set; the app
no longer derives a false temperature from DP 105. The PS3000 base capacity is
**2,560 Wh**; the PS2500B expansion pack is **2,560 Wh**. With the one connected
pack the app shows **5,120 Wh** total and the corresponding remaining Wh from DP
1.

The host bridge binds to `0.0.0.0` only for a trusted private LAN. The panel has
no user accounts or transport encryption; do not expose it to the internet. The
LocalHome Quick Settings tile is a standard Android tile, not an entry in the
proprietary Xiaomi Smart Hub card. On HyperOS 3, Android Device Controls are
broken; the tile and notification card are the supported third-party paths. The
V380 cameras expose no per-camera energy; the PS3000 energy is shared. Solar,
car-charge, and AC-energy history are Smart Life cloud statistics and are not
available from the local DP set.

Historical key/bootstrap notes are recorded in `docs/progress.md`; do not reset
or re-add the PS3000 unless you accept another binding change.

BLE is treated as provisioning-only and is not presented as local monitoring:

The Tuya LAN link is encrypted with the local key but does not provide a
verified server identity. Use this only on a trusted private network.

## Android app

For a USB-connected device, the preferred install path is:

```sh
bash scripts/install_app.sh
```

It builds the debug APK, installs the LocalHome package
(`com.pyansofyan.localhome`), migrates camera profiles from the previous
HiMost Local app, injects the LAN passwords from
`~/.config/v380decoder-test.env`, launches the app, and removes the old app
after migration. Password values are never printed.

If MIUI reports `INSTALL_FAILED_USER_RESTRICTED`, enable Developer options →
**Install via USB**, keep the phone unlocked, and rerun the script.

For hot reload during development:

```sh
cd android-app
flutter pub get
flutter run
```

Build an ARM64 APK:

```sh
flutter build apk --release --target-platform android-arm64
```

The app stores camera profiles locally, connects only to explicit private IPv4
addresses, and requires the camera LAN password for light control and talkback.
The **Xiaomi** tab stores purifier profiles in shared preferences and the device
token in the Android keystore. The **Energy** tab stores the PS3000 profile, device
ID, and host bridge URL but no local key; the key is in the host env and the
debug app's Android Keystore. The Energy dashboard includes AC/DC/light/timers,
AC charging limit, vehicle current, keystroke sound, fast charging (read-only),
capacity, and raw DPs. See
[`android-app/README.md`](./android-app/README.md) for the full feature notes
and tests.

The app also provides a **LocalHome** notification card and Quick Settings tile.
The tile opens a sheet with independent Energy and Cameras blocks; each camera
row opens that camera's live viewer. The launcher, tile, and notification use the
house+bolt icon. The tile is a standard Android tile, not a Xiaomi Smart Hub
card.

## Web test panel

The web panel is the fast path for testing controls without rebuilding the
Android app:

```sh
# camera panel, port 8090
python3 web/camera_web.py

# purifier panel, port 8091
python3 web/airpurifier_web.py

# Hinen PS3000 host bridge, port 8092
uv run --with tinytuya python3 web/hinen_web.py --bind 0.0.0.0 --port 8092
```

Open <http://127.0.0.1:8090/>. Enter the camera's private IPv4 address, LAN
password (QR field 8), and RTSP path (default `/live/ch00_0`).

The **Local DVR** card records the live RTSP stream to the panel host
(`~/LocalHome-recordings` by default, override with `LOCALHOME_DVR_DIR`) and
plays the clips in the browser with scrubbing. This is the testable playback
path on this firmware; the camera's existing SD-card clips are not exposed by
its ONVIF or RTSP services.

Requirements: Python 3.11+, `cryptography`, and `ffmpeg` for snapshot/live
preview. The server binds to localhost by default. See
[`web/README.md`](./web/README.md) for details and the LAN-binding warning.

## Security boundary

- Camera connections use explicit RFC1918 private IPv4 addresses; hostnames,
  public addresses, and cloud fallbacks are rejected.
- The camera's legacy protocol does not provide authenticated transport
  encryption. A password prompt is not a guarantee of encrypted or authenticated
  traffic. Use the app and panel only on a trusted private network.
- The LAN password is stored in the Android profile for talkback and light
  control. Do not commit it. The web panel keeps it in the browser request only
  and does not log it.
- Purifier connections use the same explicit private-IPv4 rule. The token is a
  bearer secret for local control: it is stored in the Android keystore and is
  never written to the profile JSON, browser storage, logs, or commits.
- miIO token encryption is not authenticated transport encryption. Use the
  purifier module only on a trusted private LAN.
- The purifier panel binds to `127.0.0.1` by default and reads the token from a
  mode-600 env file when the panel field is blank.
- The web panel binds to `127.0.0.1` by default. Binding it to a LAN address
  exposes an unauthenticated control panel; only do that on a trusted network.
- Hinen PS3000 connections use explicit private IPv4 addresses and the Tuya
  local key. The key is kept in the mode-600 host env and the debug app's
  Android Keystore; it is not in the profile or APK and is never logged.
- The host bridge binds `0.0.0.0:8092` for the app on the same private LAN. It
  has no accounts or transport encryption; do not expose it to the internet.
  Writes are allowlisted to DPs 6, 7, 25, 26, 105, 106, 108, 109, 110, 113 and
  are read back; DP 107 Fast Charging is read-only locally. No UPS,
  charge-limit, P-boost, schedule, or firmware write exists.
- The app enables local cleartext HTTP only for the private host bridge. There
  is no runtime cloud path. V380 cameras expose no per-camera energy; the PS300
  energy is shared.

## Credits and licenses

LocalHome is built on open-source work and publicly documented protocols. The
full notices and license texts are in
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md).

| Project | Use | License |
| --- | --- | --- |
| [prsyahmi/v380](https://github.com/prsyahmi/v380) | Open-source V380 project. | MIT |
| [cimplesid/v380-mac (OpenV380)](https://github.com/cimplesid/v380-mac) | Direct-LAN V380 client. | MIT |
| [PyanSofyan/V380Decoder](https://github.com/PyanSofyan/V380Decoder) | Earlier .NET client; no code included. | None declared |
| [butterbgud/v380-alternative-client](https://github.com/butterbgud/v380-alternative-client) | Related open-source V380 project. | MIT |
| [python-miio](https://github.com/rytilahti/python-miio) | miIO/MIoT library; no code copied. | GPL-3.0 |
| [micloud](https://github.com/squachen/micloud) | Optional one-time Xiaomi cloud token bootstrap; not bundled. | MIT |
| [MIoT spec: zhimi.airp.mb5a](https://home.miot-spec.com/spec/zhimi.airp.mb5a) / [vb4](https://home.miot-spec.com/spec/zhimi.airp.vb4) | Purifier property map. | Public device spec |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter video/audio playback. | MIT |
| [tinytuya](https://github.com/jasonacox/tinytuya) | Tuya LAN client for the Hinen host bridge; installed on demand. | MIT |
| `flutter_secure_storage` | Android keystore token storage. | BSD-3-Clause |
| `cryptography`, `pointycastle`, `xml`, `shared_preferences`, Flutter | App and web-panel dependencies. | See notices file |

`media_kit` is MIT, but its bundled native `libmpv` libraries have their own
LGPL/GPL terms. Verify those obligations before distributing an APK. `ffmpeg`
is a system dependency of the web panel and is not bundled here.

## License

LocalHome is released under the MIT License. See [`LICENSE`](./LICENSE).

Third-party components keep their own licenses; see
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md). Contributions are accepted
under the same MIT License.

## Reporting security issues

See [`SECURITY.md`](./SECURITY.md) for the threat model and how to report a
vulnerability. Do not include real credentials, device IDs, or private addresses
in a report.
