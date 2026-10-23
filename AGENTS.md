# AGENTS.md — Material Lab (Flutter Windows desktop + Firebase)

Offline-first Flutter desktop app (Windows primary, Android secondary) — 1:1 Dart port of a PySide6/Vue "row material lab" app. Stack: flutter_bloc, go_router, get_it, sqflite_common_ffi (local SQLite), Firebase (auth/firestore/messaging).

## Commands

```bash
flutter pub get
flutter analyze                # lints; expect 0 issues
flutter test                   # plain test run (no emulator needed)
flutter test test/security     # security suites — see below, need emulators
flutter run -d windows
flutter build windows --release
```

- **Emulator-tagged tests** (`emulator` tag, see `dart_test.yaml`) are skipped by plain `flutter test`. Run them with:
  `firebase emulators:exec --only firestore,auth --project demo-materiallab "flutter test test/security"`
  The `demo-` project prefix guarantees emulators never touch a real project.
- Localizations are generated (`pubspec.yaml` has `generate: true`; output in `lib/l10n/generated/`). Edit `app_en.arb` / `app_ar.arb`, never the generated files. If `.dart_tool` build output is missing, run `flutter gen-l10n` or `pub get`.

## Firebase / build config

- Firebase config resolves in order: `--dart-define` flags → git-ignored `assets/firebase/firebase.local.json` → not-configured screen. Use the directory `assets/firebase/` in builds, not a single filename (the file is git-ignored and would break clean clones).
- Dev run: `flutter run -d windows --dart-define-from-file=tool/firebase/dev.json`. Android: `--dart-define-from-file=ven/firebase-android.json` (keys in `tool/firebase/README.md`).
- Windows Google sign-in requires a **Desktop app** OAuth client id (`GOOGLE_DESKTOP_CLIENT_ID`) with loopback redirect `http://127.0.0.1` (no port) — a Web client id fails with `redirect_uri_mismatch`. Details: `tool/firebase/README.md` §5.
- Firestore rules rule: always end `firestore.rules` with a catch-all `allow: if false`; deploy to a staging project first, read the rules diff before any deploy.
- **Important:** `firebase_auth` uses a patched local copy via `dependency_overrides` → `third_party/firebase_auth` (fixes Android worker-thread event posting). Don't publish-face it as a stock dependency.

## Platform / plugin gotchas

- Several plugins are **Android-only and must never initialize on desktop**: `mobile_scanner` (never construct `QrScanScreen` on Windows), `flutter_local_notifications`, `workmanager`. `permission_handler` camera permission goes through the app's own channel (`lib/core/platform/camera_permission.dart`), because the plugin's Windows implementation downloads a NuGet package at build time and breaks `flutter run` on Windows.
- Windows release builds need a **recent MSVC toolchain** (VS 17.14 / MSVC 14.44+) — the Firebase C++ SDK 13.12 fails to link on older VS with `__std_find_first_of_trivial_pos_1` etc. Fix: update VS 2022; do NOT try `MSVC_RUNTIME_MODE=MT`. See `tool/firebase/README.md` §7.
- Debug/release run/build combos with `--dart-define-from-file` require the matching JSON path; wrong combos crash at startup on missing Firebase keys.

## Architecture

- `lib/` layout: `main.dart`, `app/`, `router/`, `di/` (get_it registration), `features/` (audit, auth, backup, dashboard, inspections, lab, members, notifications, organizations, qc_manager, reference, reports, settings, shell, sync), `core/` (database, firebase, security, services, sync, settings, utils, …), `design_system/`, `l10n/`.
- Local DB is SQLite via `sqflite_common_ffi` (`core/database/database_helper.dart` — connection-lock diagnostics go through `sqflite_common` directly; version pinned at 2.4.0).
- Security is a byte-compatible port of the Python original: PBKDF2-HMAC-SHA256 password hashing, AES-GCM seals with `enc1:` prefix, QR payloads, local secret at `%APPDATA%/MaterialLab/.secret`. Don't change these formats casually — cross-runtime compatibility matters.
- The formula engine is safe (no `eval`), decision rules / entry-code scheme are faithful ports of the Python/Vue app.
- Sync model (Release 1): **one writing device + N read-only viewers.** Enforced in three layers — `AppSession.canDo`/`canWrite`, route guard blocking `/inspection-new`, and Firestore Rules (`readOnlyDevice`, `version` optimistic concurrency, `sync_conflicts` table). Don't relax any layer casually.

## Testing conventions

- 143 test files; widget/unit suites meshed under `test/` grouped by area (architecture, security, sync, features…). Use `mocktail` for fakes.
- Security/emulator suites: always run against emulators (see Commands). Never point tests at a production Firebase project.
- Squad/banner conventions: tests detect the emulator env and skip plain runs on purpose — don't "fix" skipped green suites by pointing them at real Firebase.

## Repo map

- Chinese-language planning docs at root (`PLAN_V*.md`, `PROJECT_AUDIT.md`) — historical design notes; `tool/firebase/README.md` is the authoritative build/deploy doc.
- `tools/migrate_legacy_inspections.py` — one-off legacy data migration from the Python original.
- Assets seed first run with data: `Reference.xlsx`, `units.xlsx` (images/templates/fonts under `assets/`).
