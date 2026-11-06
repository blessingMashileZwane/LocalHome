# Security Policy

LocalHome is an experimental, local-first home-automation client. It handles
device credentials and can switch mains power through allowlisted Hinen PS3000
writes. Treat it as hobby software, not a production control system.

## Supported versions

Only the `main` branch is supported. There are no maintained release branches.

## Reporting a vulnerability

Open a private security advisory through the repository's **Security** tab
("Report a vulnerability"). Do not open a public issue for a vulnerability that
could expose credentials or device control. If private advisories are not
available, open a minimal issue asking for a private contact channel and do not
include exploit details.

Never include real passwords, tokens, local keys, device IDs, MAC addresses, or
private IP addresses in a report. Redact them with `<redacted>`.

## Scope

In scope:

- Credential handling and leakage in the app, web panels, scripts, or logs.
- Local-only enforcement bypasses (public address, hostname, or cloud fallback).
- Missing or incorrect write allowlists and read-back checks.
- Command injection, path traversal, or cross-origin write issues in the web
  panels.
- Android intent or exported-component issues that expose device control.

Out of scope:

- The security of the underlying vendor protocols. The camera IOT protocol,
  miIO/MIoT link, and Tuya LAN link do not provide authenticated transport
  encryption; that is documented in the module design docs.
- Devices reachable from an untrusted network, or panels deliberately exposed to
  the internet.
- Physical access, firmware vulnerabilities, or vendor cloud services.

## Threat model

- The device and the host running the panels are on a trusted private LAN.
- The web panels bind to `127.0.0.1` by default. Binding the Hinen bridge to
  `0.0.0.0:8092` is only for the Android app on the same private LAN; it has no
  accounts or transport encryption.
- Credentials live in mode-600 env files under `~/.config/` or the Android
  Keystore. They must never be committed, logged, or returned by an API.
- A local-first guarantee means traffic stays on the LAN. It does not mean the
  link is encrypted or authenticated.
