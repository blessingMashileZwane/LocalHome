# Third-Party Notices and Credits

_Last updated: 2026-11-06_

LocalHome is a local-first client for cameras, Xiaomi purifiers, and Hinen
PS3000 power stations. This file records the third-party projects and the
licenses of the components used or consulted.

This is not legal advice. Before distributing binaries, verify the obligations
of every bundled dependency, especially the native media libraries.

## Protocol and code references

### prsyahmi/v380

- Repository: <https://github.com/prsyahmi/v380>
- License: MIT
- Copyright (c) 2019 Syahmi Azhar
- Use: open-source V380 project.

### cimplesid/v380-mac (OpenV380)

- Repository: <https://github.com/cimplesid/v380-mac>
- License: MIT
- Copyright (c) 2026 OpenV380 contributors
- Use: direct-LAN V380 client.

### PyanSofyan/V380Decoder

- Repository: <https://github.com/PyanSofyan/V380Decoder>
- License: **none declared** at the time of this check.
- Use: earlier .NET client. **No code from this
  repository is included in LocalHome.** LocalHome's client code is a new
  Dart/Python implementation. If you own that project, add an explicit
  license there before reusing its code elsewhere.

### butterbgud/v380-alternative-client

- Repository: <https://github.com/butterbgud/v380-alternative-client>
- License: MIT
- Use: related open-source V380 project.

### V380 usage documentation

- <https://v380.net/docs/real-time-preview/light-control-function/light-control-usage>
- <https://v380.app/how-to-use-the-light-control-function/>
- Use: behavior notes for the ON/AUTO/OFF light control semantics.

## Xiaomi miIO/MIoT references

### MIoT device specifications

- Xiaomi Smart Air Purifier 4 (`zhimi.airp.mb5a`):
  <https://home.miot-spec.com/spec/zhimi.airp.mb5a>
- Xiaomi Smart Air Purifier 4 Pro (`zhimi.airp.vb4`):
  <https://home.miot-spec.com/spec/zhimi.airp.vb4>
- Xiaomi Smart Air Purifier 4 Compact (`xiaomi.airp.cpa4`):
  <https://home.miot-spec.com/spec/xiaomi.airp.cpa4>
- Use: public property/service identifiers (siid/piid/aiid), value ranges, and
  the model differences. The client reads the target's model and marks
  unsupported properties rather than assuming the public spec exactly matches
  the unit.

### python-miio

- Repository: <https://github.com/rytilahti/python-miio>
- License: GPL-3.0
- Use: **miIO/MIoT library**. The miIO framing, handshake, and
  checksum behavior are implemented independently. No python-miio code
  is copied into LocalHome; the Python and Dart implementations are independent.
  Its air-purifier model mappings follow the public MIoT specifications.

### Xiaomi marks

- Xiaomi, Mi, Mi Home, and Smart Air Purifier are trademarks of their owners.
  LocalHome is not affiliated with or endorsed by Xiaomi. No vendor code,
  assets, tokens, or device data are included.

### micloud

- Repository: <https://github.com/squachen/micloud>
- License: MIT
- Use: optional one-time Xiaomi cloud login used only by
  `scripts/miio_token_from_cloud.py` to read the purifier token. It is not a
  runtime dependency and is not bundled; install it on demand with
  `uv run --with micloud`. The script writes only `MIIO_TOKEN` to a mode-600
  file and never prints the token.

### Xiaomi token helper

- Use: optional account-export helper for accounts with 2FA or a captcha
  challenge, which `micloud` cannot complete. It is not bundled or committed;
  run it from a temporary location.

## Hinen PS3000 / Tuya references

### Hinen / SolisCloud app

- The station is managed by the Hinen/SolisCloud mobile app, a Tuya-based
  cloud application.
- The app is not part of this project and is not required at runtime. No vendor
  source, binaries, assets, keys, tokens, or device data are included in this
  repository.

### Tuya / ThingClips

- The station uses the Tuya LAN protocol. No SDK code or
  assets are copied into LocalHome. LocalHome's Tuya LAN implementation is
  independent.
- Tuya, ThingClips, Hinen, and SolisCloud are trademarks of their owners.

### Tinytuya

- Repository: <https://github.com/jasonacox/tinytuya>
- License: MIT.
- Use: external runtime dependency of the Hinen checks and host bridge for Tuya
  LAN discovery, status, and allowlisted writes. It is installed on demand
  (`uv run --with tinytuya ...`) and is not bundled or committed in this
  repository. No source code is copied into LocalHome.

### Tuya Local Key tool

- The station's local key was obtained once through its Smart Life account
  path. No source, assets, keys, or device data from that step are included in
  this repository; the key is kept in the protected host env and debug Keystore.
  LocalHome is not affiliated with or endorsed by them.

### bleak

- Repository: <https://github.com/hbldh/bleak>
- License: MIT
- Use: optional read-only BLE advertisement/GATT access in the Hinen module
  and panel. Installed on demand (`uv run --with bleak`); not bundled. No GATT
  writes are implemented.

### python-zeroconf

- Repository: <https://github.com/python-zeroconf/python-zeroconf>
- License: LGPL-2.1-or-later
- Use: optional mDNS discovery in the Hinen LAN check. Installed on demand; not
  bundled. If redistributed, review the LGPL obligations.

## MIT-licensed components

The full MIT license text is reproduced below. The following components are
provided under it:

| Component | Copyright |
| --- | --- |
| prsyahmi/v380 | Copyright (c) 2019 Syahmi Azhar |
| cimplesid/v380-mac (OpenV380) | Copyright (c) 2026 OpenV380 contributors |
| media_kit | Copyright (c) 2021 & onwards Hitesh Kumar Saini |
| media_kit_video | Copyright (c) 2021 & onwards Hitesh Kumar Saini |
| media_kit_libs_video | Copyright (c) 2021 & onwards Hitesh Kumar Saini |
| xml | Copyright (c) 2006-2025 Lukas Renggli |
| butterbgud/v380-alternative-client | See repository |
| tinytuya | Copyright (c) Jason A. Cox and contributors |
| bleak | Copyright (c) Henrik Blidh and contributors |

```text
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Other dependencies

| Component | License | Notes |
| --- | --- | --- |
| Flutter / Dart | BSD-3-Clause | Framework and SDK. |
| shared_preferences | BSD-3-Clause | Flutter plugin; Copyright 2013 The Flutter Authors. |
| cryptography (Dart) | Apache-2.0 | <https://pub.dev/packages/cryptography/license> |
| pointycastle | Bouncy Castle license | <https://pub.dev/packages/pointycastle/license> |
| flutter_secure_storage | BSD-3-Clause | Android keystore token storage for the purifier module. |
| path_provider | BSD-3-Clause | Android app-support directory used by the debug token seed import. |
| micloud | MIT | Optional one-time Xiaomi cloud token bootstrap (`scripts/miio_token_from_cloud.py`); installed on demand with `uv run --with micloud`, not bundled. |
| ffmpeg | Depends on the build | System dependency of the web panel; not bundled by this repository. |
| Python cryptography | Apache-2.0 / BSD | System dependency of the web panel; see the installed package. |
| libmpv | LGPL-2.1-or-later or GPL-2.0-or-later | Native media engine behind media_kit's prebuilt video libraries. Verify the exact build and obligations before distributing an APK. |
| python-zeroconf | LGPL-2.1-or-later | Optional mDNS discovery in the Hinen LAN check; installed on demand, not bundled. |
| AndroidX / Kotlin | Apache-2.0 | Android platform dependencies. |

## LocalHome license

LocalHome is released under the MIT License. See [`LICENSE`](./LICENSE) for the
full text. Third-party components keep their own licenses as listed above.
