# Contributing

Thanks for taking a look. LocalHome is a small hobby project, so keep changes
focused and explain the device or behavior they affect.

## Ground rules

- **Local first.** Every normal read and write goes to the device over the
  private LAN. Do not add a silent cloud fallback. If a feature has no local
  path, mark it unsupported.
- **Private addresses only.** Accept explicit RFC1918 IPv4 addresses; reject
  hostnames, public addresses, and IPv6 for device connections.
- **No secrets in the tree.** Never commit `.env` files, tokens, local keys,
  keystores, device IDs, MAC addresses, or real private addresses. Use
  `<private-ip>` and `<product-key>` in docs and tests.
- **No vendor binaries or captured traffic.** Do not commit vendor apps,
  firmware, packet captures, or extracted assets.
- **Write safety.** Every device write needs an allowlist, explicit
  confirmation where it can interrupt power, and a read-back check.

## Development

Web and Python checks:

```sh
python3 -m pip install -r requirements.txt
python3 -m unittest discover -s tests -t . -v
python3 -m py_compile web/*.py scripts/*.py
node --check web/static/app.js
node --check web/static/airpurifier/app.js
node --check web/static/hinen/app.js
```

Android checks:

```sh
cd android-app
flutter pub get
flutter analyze
flutter test
```

## Pull requests

- Keep the change scoped; separate unrelated refactors.
- Add or update tests for behavior changes.
- Update the relevant doc under `docs/` and the progress log
  (`docs/progress.md`) when behavior or status changes.
- Describe any change to endpoints, payloads, credentials, or write allowlists
  explicitly.

## License

By contributing, you agree that your contribution is licensed under the
project's MIT License (see `LICENSE`).
