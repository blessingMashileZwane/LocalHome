# LocalHome — Idea v2: Xiaomi Air Purifier Module

_Last updated: 2026-10-31_

> **Living document.** Update this file when new device or specification
> details are confirmed. Record the corresponding change in `progress.md`.

## Why v2

The second LocalHome module replaces the Xiaomi Home / Mi Home app for one
device class: the **Xiaomi Smart Air Purifier 4 / 4 Pro**. The goal is a local
client that reads air quality, controls the purifier, and tracks filter life
without depending on the Xiaomi cloud at runtime.

The camera module remains the only working module. This document defines the
scope and validation plan for the purifier module; it is not an implementation
claim.

## Local-first rule

This module follows the repository's local-first rule:

- Every normal read and control operation goes to the purifier over the private
  LAN. No cloud call is made for status, control, or history.
- Cloud is allowed only as an **explicit, rare last-resort push** when a needed
  capability has no local path, and only after local discovery is exhausted and
  documented.
- A cloud path is never a silent fallback. It must be opt-in, labeled in the UI,
  and recorded in this file.
- The one-time **token bootstrap** described below is a credential acquisition
  step, not an ongoing cloud dependency. After the token is stored locally, the
  module runs without a Xiaomi account.

## Decisions (2026-10-31)

- **Both models.** Support `zhimi.airp.mb5a` (4) and `zhimi.airp.vb4` (4 Pro);
  choose the map from `miIO.info` at runtime. Unknown models are read-only.
- **Pasted token.** The user supplies the 16-byte token (32 hex characters);
  there is no Xiaomi cloud bootstrap. The token is stored locally.
- **Web first, then Android.** The web panel proves the protocol; the Android
  module follows with the same client rules.
- **Android secure storage.** `flutter_secure_storage` holds the token. The
  profile JSON in `shared_preferences` has no token.
- **History.** The web panel records host-side JSONL readings; Android history
  is deferred.
- **Schedules.** Marked unsupported unless a device-side path is confirmed. No
  cloud call is added.

## Scope and non-goals

In scope:

- Xiaomi Smart Air Purifier 4 (`zhimi.airp.mb5a`) and 4 Pro
  (`zhimi.airp.vb4`), subject to on-device model confirmation.
- Local status: power, mode, fan level, PM2.5, PM10, temperature, humidity, air
  quality, filter life, faults, display state, child lock, alarm.
- Local control: power, mode, manual fan level, favorite level, anion, screen
  brightness, child lock, alarm, filter reset, temperature display unit.
- Local history of readings, stored on the LocalHome host.
- A web panel first, then Android UI, matching the camera module's sequence.

Non-goals:

- Replacing Mi Home for other Xiaomi devices.
- Xiaomi account features, cloud automations, cloud history, or push
  notifications.
- Firmware updates.
- Any cloud fallback for normal operation.
- Preserving every Mi Home screen or marketing feature.

## Target devices

| Marketing name | Model ID | MIoT specification |
| --- | --- | --- |
| Xiaomi Smart Air Purifier 4 | `zhimi.airp.mb5a` | `urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-mb5a:1` |
| Xiaomi Smart Air Purifier 4 Pro | `zhimi.airp.vb4` | `urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-vb4:2` |
| Xiaomi Smart Air Purifier 4 Compact | `xiaomi.airp.cpa4` | `urn:miot-spec-v2:device:air-purifier:0000A007:xiaomi-cpa4:2` |

The target unit reports `xiaomi.airp.cpa4` (Smart Air Purifier 4 Compact),
firmware `2.2.10_0021`, hardware `esp32`. Its exact LAN address is not recorded.
The public specification on 2026-10-31 is the basis for the maps below; the
client still marks unsupported properties per unit.

## Confidence labels

The same confidence labels apply:

- **Public spec** — present in a public specification or public
  implementation; not a guarantee for this unit.
- **Device check** — a request or response actually tested against the
  configured private purifier address.
- **User report** — the user confirmed the physical result.
- **Assumption** — a likely interpretation, not a runtime fact.
- **Unknown** — not yet confirmed.

## Local protocol

### Transport and discovery

The Xiaomi air purifier is a Wi-Fi device that speaks the **miIO/MIoT** local
protocol:

| Item | Value | Status |
| --- | --- | --- |
| Transport | UDP | Public spec |
| Port | `54321` | Public spec |
| Discovery | miIO `hello` broadcast, unicast hello, and mDNS (`_miio._udp`) | Public spec; on the test AP the broadcast was filtered and a unicast `/24` sweep found the unit |
| Payload | JSON-RPC (`get_properties`, `set_properties`, `action`) | Public spec |
| Encryption | Token-derived AES-128-CBC | Public spec |
| Cloud required at runtime | No | Assumption; confirm in P1 |

The device token is a 16-byte secret. Legacy miIO derives the AES key and IV
from `MD5(token)` and `MD5(key || token)`. Newer MIoT firmware may use a
different handshake or packet format; confirm the actual handshake on the
target before implementing.

The limited-broadcast hello can be filtered by the access point. The client's
unicast-hello fallback (`--sweep <private-/24>`) is available; the target on
the test LAN answered only the unicast sweep.

### Token bootstrap

Local control requires the device token. The token is not derivable from
unauthenticated discovery. Acceptable ways to obtain it once:

1. Import it from the user's Mi Home account or a supported export on an owned
   Android device.
2. Import it once from the user's Xiaomi cloud account with an explicit,
   one-time bootstrap step. Implemented as the optional
   `scripts/miio_token_from_cloud.py` (`uv run --with micloud`): it prompts for
   the account locally, writes only `MIIO_TOKEN` to a mode-600 env file, and is
   never used at runtime. The password is not stored. `micloud` cannot complete
   a 2FA/captcha challenge; if it returns `MiCloudAccessDenied`, use a
   supported account export that also checks every server.
3. Import it from a user-controlled account export.

The token is a bearer secret for local control. Store it in Android secure
storage (or the host's protected config for the web panel), never log it, and
never commit it. Re-pairing or resetting the purifier can rotate the token;
handle that as a normal re-bootstrap, not a cloud fallback.

### Request shapes

Read properties:

```json
{
  "id": 1,
  "method": "get_properties",
  "params": [
    {"did": "<device-id>", "siid": 2, "piid": 1},
    {"did": "<device-id>", "siid": 3, "piid": 4}
  ]
}
```

Write a property:

```json
{
  "id": 2,
  "method": "set_properties",
  "params": [
    {"did": "<device-id>", "siid": 2, "piid": 4, "value": 1}
  ]
}
```

Run an action (filter reset):

```json
{
  "id": 3,
  "method": "action",
  "params": {
    "did": "<device-id>",
    "siid": 4,
    "aiid": 1,
    "in": [{"piid": 3, "value": 0}]
  }
}
```

`did` in `params` is a correlation label echoed by the device; the client sends
the property name (or `call-4-1` for an action). It is not the token. The
device id in the 16-byte packet header is separate.

## MIoT service map (4 Pro, to confirm for 4)

From the public 4 Pro specification
(`urn:miot-spec-v2:device:air-purifier:0000A007:zhimi-vb4:2`). Confirm every
siid/piid against the target before writing code.

| Service | siid | Property / action | piid / aiid | Notes |
| --- | --- | --- | --- | --- |
| `air-purifier` | 2 | `on` | 1 | bool, read/write |
| | | `fault` | 2 | uint8, read-only |
| | | `mode` | 4 | 0 auto, 1 sleep, 2 favorite, 3 manual |
| | | `fan-level` | 5 | 1–3 |
| | | `anion` | 6 | bool, read/write |
| | | `toggle` | aiid 1 | action |
| `environment` | 3 | `relative-humidity` | 1 | uint8, 0–100 % |
| | | `pm2.5-density` | 4 | float, 0–1000 |
| | | `temperature` | 7 | float, -30–100 °C |
| | | `pm10-density` | 8 | float |
| | | `air-quality` | 9 | 0 excellent … 5 severe |
| `filter` | 4 | `filter-life-level` | 1 | uint8, 0–100 % |
| | | `filter-used-time` | 3 | uint16 |
| | | `filter-left-time` | 4 | uint16 |
| | | `reset-filter-life` | aiid 1 | action, input piid 3 |
| `alarm` | 6 | `alarm` | 1 | bool, read/write |
| `physical-controls-locked` | 8 | `physical-controls-locked` | 1 | bool, child lock |
| `screen` | 13 | `brightness` | 2 | 0 off, 1 dim, 2 normal |
| `device-display-unit` | 14 | `temperature-display-unit` | 1 | 1 Celsius, 2 Fahrenheit |
| `air-purifier-favorite` | 15 | `fan-level` | 1 | 0–11 favorite level |
| `custom-service` | 9 | `favorite-speed` | 2 | 200–2300 rpm |
| | | `favorite-level` | 5 | 0–11 |
| | | `manual-level` | 9 | 1–3 |
| | | `moto-speed-rpm` | 1 | read-only |
| `aqi` | 11 | `purify-volume` | 1 | uint32, read-only |
| | | `average-aqi` | 2 | read-only |
| `rfid` | 12 | filter identity fields | 1–5 | read-only |

The 4 (`zhimi.airp.mb5a`) specification must be documented separately. If the
target exposes a different service tree, the module must use the target's tree,
not this table.

### 4 vs 4 Pro deltas

The table above is the 4 Pro (`zhimi.airp.vb4:2`) tree. The 4
(`zhimi.airp.mb5a:1`) shares the common services but differs:

| Property | 4 (`mb5a`) | 4 Pro (`vb4`) |
| --- | --- | --- |
| PM10 (`3.8`) | absent | present |
| Air-quality (`3.9`) | absent | present |
| `air-purifier-favorite.fan-level` (`15.1`) | absent | present (0–11) |
| `custom-service.favorite-level` (`9.5`) | present (0–11) | present; used first, with 15.1 as fallback |
| `custom-service.favorite-square` (`9.12`) | absent | present |

Both expose `aqi.aqi-state` (`11.3`, 0–5) and `environment` humidity/PM2.5/
temperature (`3.1`, `3.4`, `3.7`). The client selects the map from
`miIO.info`; unknown models use the common read-only map. If the target exposes
a different tree, use the target's tree, not this table.

Additional notes from the implementation:

- Screen brightness follows the spec's raw values (0 off, 1 dim, 2 normal).
  python-miio uses the opposite internal enum for these models; do not copy that.
- `miIO.info` can echo the token and MAC. Keep only `model`, `fw_ver`, and
  `hw_ver`; never surface or log the raw response.
- Per-property `-4001` means the property is not exposed on this unit and is
  shown as unsupported. Other negative codes are errors.
- `get_properties` is batched at 15 properties per request.
- Writes are allowlisted, range-checked, and read back. Filter reset is an
  action (`4.1`, input piid `3`, value `0`) and is never retried automatically.

### 4 Compact (`xiaomi.airp.cpa4`)

The target unit's tree is smaller; the client uses `CPA4_PROPERTIES`:

| Service | siid | Property / action | piid / aiid | Notes |
| --- | --- | --- | --- | --- |
| `air-purifier` | 2 | `on` | 1 | bool, RW |
| | | `fault` | 2 | uint8, R |
| | | `mode` | 4 | 0 auto, 1 sleep, 2 favorite (no manual) |
| | | `toggle` | aiid 1 | action |
| `environment` | 3 | `pm2.5-density` | 4 | uint16, 0–600, R |
| `filter` | 4 | `filter-life-level` | 1 | uint8, 0–100 % |
| | | `filter-used-time` | 3 | uint16, h |
| | | `filter-left-time` | 4 | uint16, days |
| | | `reset-filter-life` | aiid 1 | action |
| `alarm` | 6 | `alarm` | 1 | bool, RW |
| `physical-controls-locked` | 8 | `physical-controls-locked` | 1 | bool, RW |
| `custom-service` | 9 | `motor-speed-rpm` | 1 | uint16, 0–2500 |
| | | `country-code` | 10 | uint16, RW; not exposed |
| | | `favorite-level` | 11 | uint8, 0–14, RW |
| | | `filter-used-time-dbg` | 12 | uint16, W; not exposed |
| | | `toggle-mode` | aiid 1 | action |
| `aqi` | 11 | `aqi-updata-heartbeat` | 4 | uint16, RW; not exposed |
| `screen` | 13 | `brightness` | 2 | 0 off, 1 dim, 2 normal |

Absent on the Compact: fan level (2.5), anion (2.6), humidity (3.1),
temperature (3.7), temperature unit (14.1), PM10 (3.8), air-quality (3.9),
favorite speed, manual level, and RFID fields. The UI hides controls absent
from the model map and uses the model's `mode`/`favorite` maxima.

Device check (2026-10-31): the token was accepted; PM2.5 was
91–97 µg/m³; filter life 100 %, used 63 h, left 289 days; buzzer on; child lock
off; motor 0 rpm; favorite 14; screen brightness 2. Reversible writes were
verified with read-back: mode 1↔0, favorite 13↔14, screen 1↔2. Power-off and
filter reset were not exercised. The Compact can apply a write one request
late, so the client retries the read-back briefly before reporting a mismatch.

## Feature parity for replacing Mi Home

| Feature | Local path | Status |
| --- | --- | --- |
| Power on/off | `air-purifier.on` (2.1) | Implemented; read confirmed on the Compact; power-off not exercised |
| Auto / sleep / favorite / manual mode | `air-purifier.mode` (2.4) | Implemented; the Compact supports 0–2 (no manual); mode 1↔0 verified |
| Manual fan speed | `air-purifier.fan-level` (2.5) | Implemented on the 4/4 Pro; absent on the Compact |
| Favorite level | `custom-service.favorite-level` (9.5 on 4/4 Pro; 9.11, 0–14 on the Compact) | Implemented; Compact 13↔14 verified |
| Anion | `air-purifier.anion` (2.6) | 4/4 Pro only; absent on the Compact |
| PM2.5 / PM10 / temperature / humidity | `environment` (3.x) | Compact: PM2.5 only (int 0–600); 4/4 Pro add temperature/humidity; 4 Pro adds PM10 |
| Air-quality band | `environment.air-quality` (3.9) / `aqi.aqi-state` (11.3) | 4/4 Pro only; absent on the Compact |
| Filter life / used / left | `filter` (4.1/4.3/4.4) | Implemented; read confirmed on the Compact |
| Filter reset | `filter.reset-filter-life` action | Implemented; confirmation and read-back; not exercised |
| Buzzer / alarm | `alarm.alarm` (6.1) | Implemented; read confirmed; write not exercised |
| Child lock | `physical-controls-locked` (8.1) | Implemented; read confirmed; write not exercised |
| Screen brightness | `screen.brightness` (13.2) | Implemented; Compact 1↔2 verified |
| Temperature unit | `device-display-unit` (14.1) | 4/4 Pro only; absent on the Compact |
| Purify volume / average AQI | `aqi` (11.x) | 4/4 Pro only; absent on the Compact |
| Reading history | LocalHome host storage | Web: implemented JSONL; Android: deferred |
| Schedules / timers | Unknown: device-side or cloud | Unsupported; no cloud call |
| Mi Home automations | Cloud only | Out of scope |
| Firmware update | Vendor path | Out of scope |

Schedules are the main parity risk. If the purifier stores schedules on the
device, implement them locally. If schedules are cloud-only, mark the feature
unsupported rather than emulating it with a cloud call.

## Architecture fit

Do not force the purifier into the camera panel. Add a parallel module and share
only the local-first rules:

```
android-app/lib/
  local_net.dart             shared private-IPv4 guard
  miio_packet.dart           framing + token AES-CBC
  miio_airpurifier.dart      UDP transport, get/set/action
  airpurifier_status.dart    typed status and validation
  airpurifier_profile.dart   saved profile (no token)
  token_store.dart           Android keystore token
  airpurifier_home_page.dart list and add/edit/remove
  airpurifier_controls.dart  power, mode, fan, filter UI
  home_shell.dart            Cameras / Air purifier tabs

web/
  local_net.py               shared private-IPv4 guard
  miio_airpurifier.py        Python local protocol client
  airpurifier_web.py         local panel/API
  static/airpurifier/        panel assets
```

The camera and purifier modules are parallel; the shared core (device
registry, private-address guard, credential storage, connection state) is still
future work. The purifier reuses only the private-address rule and the
local-first conventions, not camera protocol code.

## Phases

### P0 — identify the unit

- Read the model, firmware, and MIoT specification from the device.
- Confirm UDP 54321 reachability and the exact handshake.
- Obtain the token once and store it locally.
- Record the model/spec details in this file; no token or device ID.

Status: target identified as `xiaomi.airp.cpa4` (4 Compact), firmware
`2.2.10_0021`, hardware `esp32`; UDP 54321 and the token were accepted. The
exact LAN address is not recorded.

### P1 — read-only status

- Implement `get_properties` for the service map above.
- Verify every value against the device and against the physical display.
- Add a web panel read-only view with connection status and error states.
- Do not write anything yet.

Status: implemented and verified on the Compact: power off, fault 0, mode 0,
PM2.5 ~91–97 µg/m³, filter life 100 % / 63 h used / 289 days left, buzzer on,
child lock off, motor 0 rpm, favorite 14, screen 2. This model has no fan level,
anion, humidity, or temperature.

### P2 — core control

- Power, mode, manual fan level, favorite level, anion.
- Read back after each write; no optimistic success.
- Handle rejected or out-of-range values as errors.

Status: implemented; verified on the Compact: mode 1↔0 and favorite 13↔14,
each with read-back. Power on/off was not exercised (it would run the fan). The
Compact has no fan level or anion.

### P3 — parity controls

- Filter life and reset (with explicit confirmation).
- Child lock, screen brightness, alarm, temperature unit.
- Fault and event display.

Status: implemented; screen brightness 1↔2 verified on the Compact. Filter
reset, child-lock, and buzzer writes were not exercised. Fault values display;
event streams are not consumed.

### P4 — Android UI

- Device card, detail view, controls, and connection state.
- Secure token storage; never log the token.
- Preserve private-IPv4-only behavior and fail closed.

Status: implemented in the **Xiaomi** tab, which is a generic local miIO/MIoT
device list: purifier models get the status/controls, other models get an
identity-only card. The token is in `flutter_secure_storage`. The debug app has
the purifier profile and token seeded without printing the token
(`scripts/inject_purifier.py` + `lib/debug_token_import.dart`). The Compact is
visually verified in the app; the APK builds and the tests pass.

### P5 — history and schedules

- Store readings locally on the LocalHome host.
- Determine whether schedules are device-side. Implement only the confirmed path.

Status: web history is implemented as JSONL; Android history is deferred.
Schedules remain unsupported and no cloud call was added.

### P6 — verification

- `flutter analyze`, `flutter test`, Python compile checks, JS syntax check.
- Hardware smoke test: read, write, read-back, reconnect, error cases.

Status: automated checks pass (43 Python tests, 61 Flutter tests, analyzer, APK
build). Live reads and three reversible writes are verified; the Compact is
visually verified in the app. Power-off and filter reset remain. The debug app
has the profile and Keystore token seeded.

## Decision gates

1. **Token without ongoing cloud.** A one-time bootstrap is acceptable. If the
   module would need a cloud token refresh for normal operation, stop and
   document why.
2. **Unknown handshake.** If the target uses a firmware-specific encrypted
   handshake that the references do not cover, do not ship a partial write path.
3. **Cloud-only feature.** Mark it unsupported in the UI. Do not add a silent
   cloud call.
4. **Write safety.** Filter reset and power-off require confirmation;
   reversible mode/fan/brightness changes apply directly and are read back. A
   failed write must be shown as failed, never assumed.

## Security boundary

- The token is a local control secret. Store it in secure storage and keep it
  out of logs, screenshots, and commits.
- UDP 54321 has no TLS. Token encryption is not authenticated transport
  encryption. Use the module only on a trusted private LAN.
- Accept only explicit RFC1918 private IPv4 addresses; no hostnames, public
  addresses, or cloud fallback.
- Do not expose the web panel beyond localhost by default.
- Never log raw request bodies; redact `did`, token-derived values, and RFID
  data.

## Acceptance criteria

- Status and control work with no Xiaomi account and no internet access.
- The token is stored locally and never logged.
- Every write is read back and every failure is visible.
- Reading history is local.
- Schedules are either confirmed local or clearly marked unsupported.
- The module fails closed when the purifier is unreachable.
- On the target 4 Compact, status, mode, favorite, and screen brightness are
  verified; power-off, filter reset, child lock, and buzzer writes remain
  unexercised.
- Hardware status/read/write verification is recorded in `progress.md`.

## Open questions

- Which exact model is installed? **Resolved: `xiaomi.airp.cpa4` (4 Compact),
  firmware `2.2.10_0021`, hardware `esp32`.**
- What firmware and MIoT specification version does it report? **Resolved for
  this unit: `2.2.10_0021`, `urn:...:xiaomi-cpa4:2`.**
- How is the token obtained? **Resolved: imported through a supported local
  account export and stored locally; no runtime cloud dependency.**
- Does the 4 use the same service map as the 4 Pro? **No, and the Compact has
  its own smaller map. The client selects the map by model.**
- Are schedules stored on the device or only in the cloud? **Unknown; marked
  unsupported.**
- Does the purifier accept local writes while the Mi Home app is open?
  **Unknown; not exercised.**
- Does the newer firmware require a different handshake than legacy miIO?
  **Resolved for this unit: the legacy hello and token work.**
- Do power-off and filter reset work? **Not exercised; pending.**
- Are child-lock and buzzer writes accepted? **Not exercised; pending.**

## References

- [Xiaomi Smart Air Purifier 4 Pro — MIoT spec](https://home.miot-spec.com/spec/zhimi.airp.vb4)
- [Xiaomi Smart Air Purifier 4 — MIoT spec](https://home.miot-spec.com/spec/zhimi.airp.mb5a)
- [python-miio — air purifier implementation](https://python-miio.readthedocs.io/en/latest/_modules/miio/integrations/zhimi/airpurifier/airpurifier.html)
- [python-miio documentation](https://python-miio.readthedocs.io/en/stable/index.html)
- [`idea.md`](./idea.md) — LocalHome vision and local-first boundary.
