# Material Lab — Flutter Desktop

Server-confirmed Flutter (Windows) desktop rewrite of the stable PySide6 + Vue
"row material lab" quality-lab application. 1:1 Dart port of the Python/Vue
core: inspection entry with QR labels, reference material library, decision
workflow with versioned history, daily/monthly/lab repoirts, and a wet-chemistry
lab module (inventory, products, analyses, constants formula engine, sample
tests, shared worksheet, consumption log).

Shared creates, edits and deletes require explicit online submission and a
verified server receipt before success. SQLite provides the offline read cache;
offline changes can only be saved as local drafts for manual review/submission.
Startup, reconnect and resume refresh reads and check attempted-operation
receipts; they never automatically submit drafts or upload local rows.

## Highlights

- Local SQLite (`sqflite_common_ffi`) —
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
flutter build windows --release
flutter run -d windows --dart-define-from-file=tool/firebase/dev.json
flutter run -d windows --dart-define-from-file=tool/firebase/dev.json --release 
flutter build apk --dart-define-from-file=ven/firebase-android.json
flutter run --dart-define-from-file=ven/firebase-android.json  
flutter build apk --dart-define-from-file=ven/firebase-android.json --debug 
adb uninstall com.materiallab

flutter run -d CPH2043 --dart-define-from-file=ven/firebase-android.json --release 
```

Shared reference data comes from the approved Firestore archive. Bundled Excel
assets are migration inputs; signing in never seeds or uploads business data.
See [the current synchronization contract](SYNC_CURRENT_CONTRACT.md).
