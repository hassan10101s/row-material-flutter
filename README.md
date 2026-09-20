# Material Lab — Flutter Desktop

Offline-first Flutter (Windows) desktop rewrite of the stable PySide6 + Vue
"row material lab" quality-lab application. 1:1 Dart port of the Python/Vue
core: inspection entry with QR labels, reference material library, decision
workflow with versioned history, daily/monthly/lab reports, and a wet-chemistry
lab module (inventory, products, analyses, constants formula engine, sample
tests, shared worksheet, consumption log).

## Highlights

- Local SQLite (`sqflite_common_ffi`) — no server required; legacy
  `app_data/material_lab.db` import supported.
- Byte-compatible security ports: PBKDF2-HMAC-SHA256 password hashing,
  AES-GCM seal format (`enc1:`), QR payload encoding and the local secret at
  `%APPDATA%/MaterialLab/.secret`.
- Faithful ports of the decision rules, entry-code scheme, unit/quantity
  formatting, enriched reference payloads and the safe formula engine
  (no `eval()`).
- Light / Dark / System themes, Arabic + English UI, Cairo font, desktop
  print/PDF via the `pdf`/`printing` packages.

## Stack

Flutter · Dart · flutter_bloc · go_router · get_it · sqflite_common_ffi ·
excel · pdf/printing · qr_flutter ([sqleq `qr`](https://pub.dev/packages/qr))

## Getting started

```bash
flutter pub get
flutter run -d windows
```

Assets bundled with the app seed `Reference.xlsx` + `units.xlsx` on first run.