# LocalHome — Idea v3: Hinen PS3000 Backup Module

_Last updated: 2026-11-01_

> **Living document.** Update this file when new device or specification
> details are confirmed. Record the corresponding change in `progress.md`.

## Why v3

The third LocalHome module replaces the **Hinen app** for the **PS300 / PS300
Pro portable power station** used as a home backup solution. The goal is local
monitoring and, only where a safe local write path is confirmed, local control of
the station without depending on the Hinen cloud at runtime.

This is a power device, not a camera. A wrong write can drop power to connected
equipment or stress the battery. The module started read-only and now exposes
only confirmed, bounded controls through the LocalHome host bridge.

## Current implementation (2026-11-01)

- The target is a **PS3000** (Smart Life panel name), Tuya LAN 3.4, product key
  `<product-key>`, at `<private-ip>`.
- The Tuya local key was imported once through the Smart Life path and saved
  without printing it. It is stored in the host's mode-600 env file and in the
  debug app's Android Keystore; it is absent from the profile and APK.
- A direct phone LAN read is **still refused by the station** even though the
  request follows the Tuya LAN 3.4 specification (AES-ECB + HMAC-SHA256,
  command 16, empty `{}` payload). The host's Tuya client works. The app
  therefore prefers the direct path and falls back to the host bridge at
  `http://<host>:8092`.
- The host panel exposes `POST /api/hinen/status` and `POST /api/hinen/write`.
  Writes are limited to DPs **6, 7, 25, 26, 105, 106, 108, 109, 110, 113**
  (AC, DC, beep, device standby, AC charging limit, vehicle current, keystroke
  sound, AC standby, screen-off, light) and are verified by reading the station
  back. DP 107 (Fast Charging) is read-only locally; the station rejects that
  write, so change it in Smart Life. No UPS, charge-limit, P-boost, schedule, or
  firmware write exists.
- The Android **Energy** tab is a dashboard with AC, DC, light, device standby,
  AC standby, screen-off, AC charging limit, vehicle current, fast charging
  (read-only), keystroke sound, battery, charging-pack count, output, and
  capacity. `_CapacityCard` shows the PS3000 base (2,560 Wh) and the PS2500B
  pack (2,560 Wh); one pack gives 5,120 Wh. The 32°C Smart Life temperature is
  cloud-only and is not shown as a local DP.
- A **LocalHome** notification card and Quick Settings tile expose Energy plus
  the cameras. The tile sheet uses independent Energy and Cameras blocks; each
  camera row deep-links to that camera's live viewer.
- The V380 cameras have no per-camera energy telemetry. Solar, car-charge, and
  AC-energy history are Smart Life cloud statistics; the local DP set does not
  contain them.
- The Xiaomi Smart Hub card itself is proprietary. On HyperOS 3, Android Device
  Controls are broken; the supported third-party paths are the Quick Settings
  tile and notification card. A Matter bridge would be required to enter the
  Xiaomi Smart Hub panel.

## Local-first rule

This module follows the repository's local-first rule:

- Prefer a local protocol on the private LAN or a direct BLE link for every
  read and control operation.
- Use the cloud only as an **explicit, rare last-resort push** when a needed
  capability has no local path, and only after local discovery is exhausted and
  documented.
- A cloud path is never a silent fallback. It must be opt-in, visibly labeled,
  credential-scoped, and recorded here.
- If a feature is cloud-only, the default is to mark it unsupported. The cloud
  exception is a deliberate decision, not an automatic fallback.

## Scope and non-goals

In scope:

- Hinen PS3000 (this unit); PS300/PS300 Pro variants may differ.
- Local monitoring: battery state of charge, input power, output power, port
  states, remaining runtime, temperature, BMS alerts, firmware version.
- Local control only after it is confirmed and reviewed: AC/DC/USB output toggles,
  UPS mode, charge/discharge limits, P-boost.
- A web panel first, then Android UI.
- Local history of readings, stored on the LocalHome host.

Non-goals:

- Firmware updates.
- Unlocking hidden service modes or bypassing BMS limits.
- Automating power-output switching before a safety review.
- Cloud history, cloud automations, or push notifications as default features.
- Replacing the Hinen app for the company's inverters or solar systems; this
  module is for the PS300 backup station.

## Target devices

| Item | Observation | Status |
| --- | --- | --- |
| Family | Hinen PS3000 portable power station | Smart Life panel + device |
| Rated output | 3000 W, 5000 W peak | Product spec |
| Battery | LiFePO4 | Product spec |
| Capacity | 2560 Wh base; PS2500B expansion 2560 Wh | Product spec + DP 116 |
| Connected packs | 1 on this unit; total 5,120 Wh | Live read |
| UPS | 24/7 UPS; switchover spec | Product spec |
| Connectivity | Wi-Fi/cloud; no local Bluetooth control | Verified |
| App | Hinen/SolisCloud mobile app, Tuya-based | Verified |
| Wi-Fi local protocol | Tuya LAN 3.4 on TCP 6668, encrypted; local key required | Verified |
| Product key | `<product-key>` | Verified |
| BLE | No post-provisioning control exposed; likely provisioning-only | Verified; provisioning-only |
| Exact model / firmware | PS3000; firmware is not shown | Verified / unknown |
| Private address | `<private-ip>` on this network (DHCP; confirm on the router) | Verified |

The Wi-Fi module is a Tuya LAN 3.4 device. The PS3000 model and one PS2500B
pack are confirmed; firmware remains unknown. The direct phone Tuya read is
refused by the station while the host client works.

## Interoperability notes

What is known:

- **Public documentation:** Hinen publishes an official Home Assistant
  integration (`Hinen-IoT/ha_hinen_power`). It uses the Hinen Open API at
  `celinksmart.com` with OAuth2, a developer Client ID/Secret, and a Hinen Solar
  account. This documents a cloud API for Hinen Solar inverters; it does
  **not** document a local API for the PS300.
- **Public documentation:** the PS300 product page advertises Wi-Fi and Bluetooth
  app monitoring. It does not document a local protocol.
- **App:** the Hinen/SolisCloud mobile app is a Tuya-based cloud
  application. It is not part of this project and is not required at runtime.
- **Local interface (2026-10-31):** the PS300 is a **Tuya LAN device** at a
  private IPv4 address (`<private-ip>` on this network; DHCP), product key
  `<product-key>`, Tuya protocol **3.4**, encrypted, with **TCP 6668** reachable.
  No other local service is exposed (no HTTP/TLS/SSDP/mDNS). The Tuya UDP
  discovery returns the device id, product key, version, and encryption flag; it
  does **not** return the local key.
- **Identity:** the station's Tuya identity is confirmed by its discovery
  response, and its WAN/signal state confirms Wi-Fi/cloud connectivity.
- **BLE:** the station exposes no local Bluetooth control. BLE is likely
  provisioning-only on this unit.
- **Local key:** the Tuya LAN protocol needs a 16-character local key. It was
  imported once through the Smart Life path and saved from a mode-600 drop
  file with `scripts/set_hinen_key.py`; it is never printed by LocalHome. The key
  is in the host env and the debug app's Android Keystore, not in the profile or
  APK. The direct phone read is refused by the station; the host bridge works.
  This is a credential bootstrap, not a cloud control path.
- **Implemented v3 (2026-11-01):** the host panel and Android **Energy** tab
  read live DPs through the local key. Because the station closes the direct
  phone LAN session, the app uses the host bridge (`/api/hinen/status`,
  `/api/hinen/write`) when the direct path fails. AC (DP 6), DC (DP 7), light
  (DP 113), AC charging limit (DP 105), vehicle current (DP 106), fast
  charging (DP 107, read-only locally), keystroke sound (DP 108), packs (DP 116),
  and the confirmed timers are mapped. Writes are allowlisted, confirmed, and
  read back; UPS, charge limits, P-boost, schedules, and firmware remain out of
  scope.
- **Implementation:** the PS3000's local monitoring/control path is Tuya LAN 3.4
  on TCP 6668, using command 16 (`DP_QUERY_NEW`) with an empty `{}` payload,
  AES-128-ECB, and HMAC-SHA256. BLE remains provisioning-only.

The direct phone LAN session is still closed by the station even with the
documented Tuya LAN 3.4 packet. That is a station/session restriction, not a key
error. The
host bridge is the working local path; no runtime cloud call is made. The
confirmed controls are not a claim that every Hinen app feature is mapped:
solar, car-charge, and AC-energy history are cloud-only. The 32°C Smart Life
temperature is also cloud-only; DP 105 is the AC charging limit. DPs 111/112
remain unmapped.

## Local-interface conformance plan

The camera module showed that a private-IP field does not guarantee local
behavior. Apply the same discipline here.

### P0 — identity

- Verify the exact model, firmware, and radio module; do not record serials.
- Confirm from vendor documentation whether a local interface is documented and
  whether the app requests local-network permission or uses a SoftAP during
  provisioning.

### P1 — network reachability

- Resolve the station's private IPv4 address and DHCP hostname.
- Check the documented local services (HTTP/TLS, SSDP, mDNS) and the station's
  own address. Do not assume local routing from a private address alone.

### P2 — BLE conformance

- Verify the advertised services and whether the station exposes a documented
  local BLE interface.
- Determine whether BLE works after provisioning or only during setup.

### P3 — local interface conformance

- Use read-only requests only.
- Verify request/response framing and authentication against the documented
  interface, and whether values match the physical display.
- If the only successful path is the cloud, stop and record that result.

## Implementation status (2026-11-01)

- **P0 — identify: done.** The station is a Tuya LAN device managed by the
  Hinen/SolisCloud app.
- **P1 — discovery: done.** Tuya UDP discovery found the PS3000; TCP 6668 is the
  only local service exposed. No HTTP/TLS/SSDP/mDNS; no BLE control.
- **P2 — local read: done through the host.** The local key was obtained
  through the Smart Life path and imported without printing it. The host's
  `tinytuya` client reads the 14/15 DPs. The direct phone path uses the same
  documented framing but is closed by the station; the app falls back to the
  host bridge. The Tuya request is command 16 (`DP_QUERY_NEW`), empty `{}`
  payload, AES-128-ECB, HMAC-SHA256, with the 3.4 no-protocol-header rule.
- **P3 — read-only/write host panel: done.** `web/hinen_web.py` on port 8092
  exposes status and allowlisted write. Writes are DPs 6, 7, 25, 26, 105, 106,
  108, 109, 110, and 113; each is read back. DP 107 Fast Charging is read-only
  locally. The panel never stores or returns the key.
- **P4 — safe control: implemented for confirmed DPs.** AC, DC, light, AC
  charging limit, vehicle current, keystroke sound, and the standby/screen
  timers are writable through the host bridge with confirmation and read-back.
  Fast Charging (DP 107) is read-only locally. There is no UPS, charge-limit,
  P-boost, schedule, or firmware write.
- **P5 — Android UI: done.** The Energy dashboard shows live status, a capacity
  card (2,560/5,120 Wh), and controls. The LocalHome notification card and Quick
  Settings tile expose Energy and Cameras; the tile sheet uses independent blocks
  and each camera row opens its own live viewer. The new house+bolt icon is
  applied to the app, tile, and notification.
- **P6 — cloud exception: not implemented.** The one-time key bootstrap is the
  only cloud-shaped step; runtime traffic is local. Solar/car-charge/AC-energy
  history remains a Smart Life cloud feature and is not shown.

Files:

```
web/hinen_local.py              Tuya discovery, read/write, LAN/BLE checks
web/hinen_web.py                host bridge/API on port 8092
web/static/hinen/               discovery/read panel
scripts/set_hinen_key.py        protected local-key importer
scripts/inject_hinen.py         seeds profile, device ID, bridge URL, key stage
android-app/lib/hinen_*.dart    Energy dashboard, host bridge, key store, status
android-app/lib/hinen_quick_controls.dart  Flutter bridge to native card/tile
android-app/android/.../HinenQuickControls.kt  card, tile, sheet, deep links
tests/test_hinen.py             discovery/key/status/sanitization tests
tests/test_set_hinen_key.py     key extraction/env merge/mode tests
tests/test_inject_hinen.py      profile merge and preference tests
```

## Feature matrix for replacing the Hinen app

| Feature | Direction | Local status |
| --- | --- | --- |
| Tuya LAN discovery / identity | Read | Confirmed: UDP discovery, TCP 6668, product key, protocol 3.4 |
| Battery state of charge | Read | Confirmed DP 1; matches Smart Life |
| Input / output power | Read | Output read on DP 117; input is not exposed by the local DP set |
| Remaining runtime estimate | Read | Not derived; device/AC standby are DP 26/109, screen-off DP 110 |
| AC / DC port states | Read | Confirmed DP 6 (AC), DP 7 (DC); USB not mapped |
| Light mode | Read/write | DP 113: Off/Low/Medium/High/SOS |
| AC charging power limit | Read/write | DP 105: 90% in Smart Life; 80% write verified |
| Vehicle charging current | Read/write | DP 106: 8 A in Smart Life; 6 A write verified |
| Fast Charging switch | Read | DP 107: local write rejected; change in Smart Life |
| Keystroke Sound | Read/write | DP 108: false/true write verified |
| Temperature | Cloud only | 32°C in Smart Life; not in the local DP set |
| Charging packs / capacity | Read | DP 116; PS3000 2,560 Wh base + PS2500B 2,560 Wh per pack |
| Firmware / model identity | Read | PS3000 named in Smart Life; firmware unknown |
| AC output on/off | Write | Implemented via host bridge; confirmation + read-back |
| DC output on/off | Write | Implemented via host bridge; confirmation + read-back |
| UPS mode | Write | Not implemented; safety-gated |
| Charge / discharge limits | Write | Not implemented; safety-gated |
| P-boost mode | Write | Not implemented; safety-gated |
| Schedules / timers | Write | Device/AC standby and screen-off only; no schedules |
| Energy history | Read | Cloud-only in Smart Life; not available from the local DPs |
| Per-camera energy | Read | Not available; V380 exposes RTSP/ONVIF only |
| Firmware update | Write | Out of scope |
| Notifications | Push | LocalHome notification card and Quick Settings tile; no cloud |

The confirmed writes are bounded to DPs 6, 7, 25, 26, 105, 106, 108, 109, 110,
and 113. Every write is read back; a verification failure is reported. DP 107
Fast Charging is read-only locally. The direct phone Tuya session remains
refused, so writes go through the host bridge. No UPS, charge limit, P-boost,
schedule, or firmware write is implemented.

## Safety boundary

This module controls mains power. The following rules are not optional:

- **Read-only first.** Ship monitoring before any write.
- **Explicit confirmation.** Any write that can interrupt power requires a
  confirmation that names the affected port and the consequence.
- **Conservative bounds.** Validate charge/discharge limits against the
  device's reported range; never send values outside it.
- **No automation until reviewed.** A schedule or automation that toggles AC
  output can cut power to a fridge or medical device. Do not ship one without a
  documented safety review.
- **Fail safe.** On timeout or an unknown response, show "unknown" and do not
  retry a write blindly.
- **No internet exposure.** The web panel binds to localhost by default and
  accepts only private IPv4 station addresses.
- **No credential logging.** App tokens, BLE keys, and cloud tokens stay out of
  logs and commits.
- **No firmware update path.**

## Cloud exception policy

The user's rule is local first, with cloud only as a rare push when local is
impossible. For this module that means:

1. Complete P0–P3 first. Document what local can and cannot do.
2. If local read works but local write does not, ship read-only and mark writes
   unsupported. Do not silently route writes to the cloud.
3. If no local path exists, the module may offer an **explicit cloud mode**:
   - opt-in during setup, with a clear "cloud required" label;
   - OAuth or developer credentials supplied by the user;
   - credentials stored securely, never bundled or hard-coded;
   - rate-limited polling, not a high-frequency stream;
   - read-only unless a separate safety review approves writes;
   - disabled by default and easy to remove.
4. Record the decision in this file and in `progress.md`.

The PS300-specific one-time step is different from a runtime cloud exception:
the one-time Smart Life/local-key credential step is used only to obtain the
16-character local key; after that, discovery and status/write use TCP 6668 and
no cloud request is made. The key is a credential, not a control path. Do not
add OEM cloud telemetry or control.

The official Hinen integration's cloud OAuth flow is an example of a genuine
cloud exception, not a default implementation.

## Architecture fit

```
android-app/lib/
  hinen_profile.dart         saved station profile (no key; bridge URL)
  hinen_status.dart          nullable snapshot, capacity, and mapped DPs
  hinen_key_store.dart       Android Keystore local-key storage
  hinen_host_bridge.dart     read/write client for the host panel
  hinen_home_page.dart       Energy tab list and add/edit/remove
  hinen_controls.dart        dashboard, controls, capacity, raw DPs
  hinen_quick_controls.dart  Flutter bridge to the native card/tile
  home_shell.dart            Cameras / Xiaomi / Energy tabs

android-app/android/.../HinenQuickControls.kt
  notification card, LocalHome tile, compact Energy/Cameras sheet,
  camera deep links, host HTTP client

web/
  hinen_local.py             Tuya LAN discovery, read/write, LAN/BLE checks
  hinen_web.py               host bridge/API on port 8092
  static/hinen/              discovery/read panel

scripts/
  set_hinen_key.py           protected key importer
  inject_hinen.py            profile/key/bridge seeder
```

The Android profile stores the bridge URL and device ID but no key. The direct
phone Tuya read is attempted first; on failure the app uses the host bridge.
The host panel holds the key and performs the Tuya operation. The native tile
sheet reads camera profiles for the camera blocks and passes the camera id to
Flutter for the specific live viewer.

Do not restructure the camera module for this. Share only the local-first rules
and, later, the device registry, private-address guard, credential storage, and
connection-state core.

## Phases

Status: see **Implementation status (2026-11-01)** above.

### P0 — identify

- Record model, firmware, radios, and app behavior.
- Confirm from vendor documentation and the app's public UI whether a local
  protocol is documented.
- Write the findings into this file with redactions.

### P1 — discovery report

- Network and BLE discovery, no writes.
- Report local services and protocols with confidence labels.

### P2 — local read

- Confirm at least one local read path, or document that none exists.
- Compare values with the physical display.

### P3 — read-only panel

- Web panel: state of charge, power, ports, temperature, alerts, freshness.
- Explicit "local" or "cloud exception" badge in the UI.
- Implemented; the allowlisted write endpoint was added in P4.

### P4 — safe control (implemented for confirmed DPs)

- AC (DP 6), DC (DP 7), light (DP 113), and the standby/screen timers are
  writable through the host bridge with confirmation and read-back.
- UPS, charge/discharge limits, and P-boost remain blocked pending a separate
  safety review.

### P5 — Android UI

- Monitoring card and detail view.
- Secure credential storage.
- Fail-closed behavior and clear unsupported states.
- Implemented: dashboard, capacity card, host bridge, Keystore, notification
  card, LocalHome tile/sheet, camera deep links, and icon.

### P6 — cloud exception (only if needed)

- Implement only after local discovery is documented as exhausted.
- Explicit opt-in, secure credentials, rate limiting, read-only by default.

## Decision gates

1. **No local read path.** Ship no control. Either mark the module unsupported
   or implement the explicit cloud exception; do not fake local.
2. **Local read, no local write.** Ship read-only. Do not route writes to the
   cloud by default.
3. **Undocumented write.** Do not implement it. A power station is not a place
   for guessed registers.
4. **Cloud-only write.** Requires a separate safety review and explicit user
   opt-in. Default answer is no.
5. **BLE provisioning only.** Do not present provisioning as local control.

## Security boundary

- The Tuya LAN link is encrypted with the local key, but the protocol does not
  provide a verified server identity. A private address does not guarantee
  authenticity.
- The local key is a credential. Keep it out of logs, commits, the Android
  profile, and browser storage; the web panel reads it per request or from a
  mode-600 env file.
- Keep cloud/OAuth credentials, BLE pairing keys, and device identifiers out of
  logs and commits.
- Accept only explicit RFC1918 private IPv4 addresses for the LAN path.
- Do not expose the panel to the internet or port-forward the station.
- Writes are limited to the confirmed DPs (6, 7, 25, 26, 105, 106, 108, 109,
  110, 113), require confirmation, and are read back. Fast Charging (DP 107) is
  read-only locally. No UPS, charge-limit, P-boost, schedule, or firmware write
  exists.
- The host bridge has no user accounts and no transport encryption; use it only
  on a trusted private LAN. The Android app allows cleartext only for local
  private host addresses.

## Acceptance criteria

- Discovery works locally with no Hinen account and no internet access; this is
  confirmed (Tuya UDP + TCP 6668).
- Local reads work through the host bridge after the one-time Tuya key
  bootstrap; runtime traffic stays on TCP 6668/host LAN and no cloud request is
  needed. The direct phone LAN path is still refused by the station.
- Every displayed value has a source and freshness; raw DPs are labeled as
  unmapped until confirmed.
- Unsupported controls are visibly unsupported; there is no silent cloud
  fallback. Confirmed writes are bounded, confirmed, and read back.
- The LocalHome notification card and Quick Settings tile expose Energy and
  cameras; camera rows open the specific live viewer.
- The optional one-time key bootstrap is labeled as a credential step, not
  runtime cloud.

## Open questions

- Is the unit a PS300 or PS300 Pro, and what firmware does it run? The Smart
  Life panel names it **PS3000**; the base capacity is 2,560 Wh. Firmware is
  still not shown.
- Can the Tuya local key be obtained at all? **Resolved:** obtained through the
  Smart Life path and imported without printing it. The direct phone read is
  refused by the station; the host bridge works.
- Which Tuya DPs map to input power, USB, alerts, runtime, Charge/Discharge
  Limited, and Inverter Frequency? DPs 111/112 and 117 still need verification;
  no fake meaning is assigned. DP 117 is shown as reported output watts.
- Does BLE carry any post-provisioning status? No local Bluetooth control is
  exposed; it is likely provisioning-only.
- Does the station keep working locally when the internet is down? The host
  bridge uses TCP 6668 only; verify the station remains reachable in an
  internet-outage test.
- Which controls are safe enough to expose? AC/DC/light and the confirmed
  standby/screen timers; UPS, charge limits, P-boost, schedules, and firmware
  remain out of scope.

## References

- [Hinen PS3000 product page](https://www.hinen.com/products/3000w-portable-power-station)
- [Hinen PS2500B 2,560 Wh expansion pack](https://offgridowo.pl/en/product/hinen-ps2500b-2560wh-extra-battery/)
- [Hinen PS300 Pro product page](https://www.hinen.com/products/ps-300-pro)
- [Hinen official Home Assistant integration](https://github.com/Hinen-IoT/ha_hinen_power)
- [SolisCloud Bluetooth SDK integration](https://doc.soliscloud.com/en/05.Integrated%20Document/01.SolisCloud%20Bluetooth%20SDK%20Integration.html)
  — inverter/logger BLE SDK documentation; not the PS300 protocol.
- [tinytuya](https://github.com/jasonacox/tinytuya) — Tuya LAN client used by
  the web panel and host bridge; installed on demand.
- [`idea.md`](./idea.md) — LocalHome vision and local-first boundary.
- [`idea-v2-xiaomi-air-purifier.md`](./idea-v2-xiaomi-air-purifier.md) — parallel module pattern.
