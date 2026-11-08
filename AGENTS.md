# AGENTS.md — Material Lab (Flutter Windows desktop + Firebase)

Server-confirmed writes with an offline SQLite read cache. Flutter desktop app (Windows primary, Android secondary) — 1:1 Dart port of a PySide6/Vue "row material lab" app. Stack: flutter_bloc, go_router, get_it, sqflite_common_ffi (local SQLite), Firebase (auth/firestore/messaging).

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

- November 9 maximum-capacity follow-up supersedes the older fixed 25-entry / generic four-effect notes for its verified scoped families. Production ruleset `ee858067-8cd9-41af-89df-f882087c3dce`, published SHA256 `fbaaad23c3ef6a8457341d75bea66b8353ac02f3d650dc075aed01fd825ae8c0`, is verified active. `simpleEntityTypes` use a weighted limit up to 12 effects, with one immutable same-commit proof for 11/12 images; uniqueness and external parents lower the limit. Packed chemical definitions support up to 36 entries across nine four-entry proof blocks when the reference budget permits. Other families retain their own limits (QC definitions 10 effects / 9 columns, lab definitions 6, result/consumption 10, product-reference updates 7, unclassified/mixed 4). Never split operations. Foreground refresh is **30 seconds**, explicitly requested by the user. Quota resumption is manual only, including receipt verification/retry; automatic recovery must not clear the store's pause. The artifact compiled to **255781/256000 bytes**, leaving only 219 bytes: every future rule change requires a new compiled-size preflight. Verification passed 2139 general tests (93 skipped), 135 emulator security tests and 34 Node contract/migration tests; analysis had zero issues. Staging was explicitly waived for this batch. No new application binary was built. See `docs/FINAL_FIREBASE_REVIEW_2026-11-08.md`, `docs/RELEASE_EVIDENCE_2026-11-09.json`, and the top of `SYNC_CURRENT_CONTRACT.md`.

- November 7 analysis-value advisory: a numeric measurement strictly greater than twice its material/product analysis upper bound shows a warning only. Use the selected inspection/reference snapshot and shared `analysis_value_warning.dart` / `AnalysisValueAdvisory` on both platforms. Equality does not warn. Never turn this advisory into a save gate, altered measurement, automatic rejection or NIR exclusion; absent/minimum-only/textual references do not supply a guessed maximum. See `docs/ANALYSIS_DOUBLE_MAX_ADVISORY_2026-11-07.md`.

- November 7 NIR inclusion follow-up supersedes the earlier ruleset below: verified ruleset `5d258d69-2051-427b-855d-93c10602a676`, published SHA256 `2576b2d834c810698ee2a22aeb89cebdf56de5413f5d1100526116480a38c645`. Shared Yes/No selection is calibration-only lab-result metadata (`nirExclusionsJson`) bound to global source/sample/parameter identities. No excludes every metric/fit while retaining the visible reading; Yes restores it. Source measurements and inventory remain unchanged. Reset snapshots capture excluded identities/counts. Only `shape_labResult` changed; 127 emulator tests passed. The user requested no new application build. See `docs/FORMULATION_NIR_SELECTION_2026-11-07.md` and the top of `SYNC_CURRENT_CONTRACT.md`.

- November 7 review is verified deployed: ruleset `7475e7d0-1a26-4854-a610-fbc2699a3bac`, published SHA256 `4040aae7b417c66c28082be03c657fad6503c820a152ec813f75b856d3e00f2f`. New NIR resets use typed global material/product parents, retain an immutable previous-cycle calibration summary and optional operator-reported applied coefficients, and are append-only after approval. Legacy reset numeric IDs never identify a target on another device. The user explicitly waived staging for this deployment after emulator verification. See the top of `SYNC_CURRENT_CONTRACT.md` and `docs/REVIEW_FIXES_2026-11-07.md`. Application changes still require building/running the updated client.

- November 3 deletion audit supersedes earlier deployment IDs below: verified ruleset `5e5bf57b-9847-4c0a-82fc-92a3e8ea6052` (published compact SHA256 `c78361eec14ee8b1da01a9b1749513f9f9ba252ef5c1105f4a0ae4cf6e41a3b1`). Captured business deletes keep candidate tombstones until server approval; never hard-remove a source row before central serialization. Consumption returns subtract earlier linked and legacy unlinked returns before restoring only outstanding draws. New return lines bind to their original consumption; quantity is positive and bounded by that draw. Stable `result_text == FAILURE` marks failed lab attempts: bypass missing formula values, retain real consumption, exclude failures and tombstones from NIR/numeric comparisons. See `SYNC_CURRENT_CONTRACT.md` and `docs/DELETE_AUDIT_2026-11-03.md` for scope and evidence.

- November 3 actual-result follow-up: the user's rejected draft was a result with two chemical deductions (9 business effects), not an analysis definition. `labResult` + related consumption/ledger/lot/item writes have a separate max-10 family only when `effects + 7 + externalParents + updatedLots <= 20`. Never extend unrelated/mixed operations. `consumptionPaths` bind reported consumption to the ledger and stock/lot deltas; unchanged admitted inventory/lot unique keys do not need another reservation lookup, while creates/renames retain reservation checks. Exact-case emulator approval, tamper refusals and idempotent replay passed. Ruleset `32ece407-b07b-4a6e-b638-ac8f3c83fab2` is verified deployed; see the top of `SYNC_CURRENT_CONTRACT.md`. The earlier 25-entry limit refers to definition configuration, not arbitrary stock-deduction effects.

- November 3 consumption follow-up supersedes the earlier separate-child authoring below: analysis consumption definitions are packed in the root's native `chemicalDefinitions` field (local formula metadata `chemical_definitions`), with global inventory IDs resolved per device. Up to 25 entries; one immutable summary plus one proof per four entries validates the inventory references within the same atomic commit. Budget includes those proofs and distinct inventory parents; 25 arbitrary distinct parents are not promised. Standard intrinsic units do not create independent catalogue effects for an analysis. `protocol.chemicalDefinitionAware` gates result writes for packed definitions; legacy child writes under a packed root are denied. Membership disable/leave must atomically revoke both membership and user authorization. See `SYNC_CURRENT_CONTRACT.md` for verified tests and deployment evidence.

- November 3 final user decision: Auth + Firestore on the free plan only; no Firebase Functions or billing activation. Analysis choices/fixed values live inside `formula_json.field_configs`, preserving chemical links as separate records with real server-validated parents. 25 and 1000 choice fields have been tested as one analysis effect, bounded by Firestore document size rather than a four-field UI cap. Direct lab-definition operations allow up to 6 physical effects only when `7 + 2*effects + distinct_external_parents <= 20`; the app lowers the bound for additional parents. QC definitions keep 10 effects / 9 columns, other/mixed operations keep 4. No splitting, automatic resubmission or relaxation of receipt/version/role rules. See `SYNC_CURRENT_CONTRACT.md` and `docs/CODE_OPERATIONAL_REVIEW_2026-11-03.md`; code/rule changes are local until deployment is verified.

- `lib/` layout: `main.dart`, `app/`, `router/`, `di/` (get_it registration), `features/` (audit, auth, backup, dashboard, inspections, lab, members, notifications, organizations, qc_manager, reference, reports, settings, shell, sync), `core/` (database, firebase, security, services, sync, settings, utils, …), `design_system/`, `l10n/`.
- Local DB is SQLite via `sqflite_common_ffi` (`core/database/database_helper.dart` — connection-lock diagnostics go through `sqflite_common` directly; version pinned at 2.4.0).
- Security is a byte-compatible port of the Python original: PBKDF2-HMAC-SHA256 password hashing, AES-GCM seals with `enc1:` prefix, QR payloads, local secret at `%APPDATA%/MaterialLab/.secret`. Don't change these formats casually — cross-runtime compatibility matters.
- The formula engine is safe (no `eval`), decision rules / entry-code scheme are faithful ports of the Python/Vue app.
- Write policy (November 1): every shared create/edit/delete requires an explicit online send and verified server receipt before showing success. Offline actions offer Save draft / Cancel; drafts stay local until manual review/submission. Startup/reconnect/resume must never send automatically: only refresh reads and look up receipts of attempted operations. Preserve immutable operation IDs for uncertain results and manual retries. Session lifetime is 10 days from explicit sign-in, never extended by profile/token refresh. Retired sending engines exist under test/support/retired only for historical regression tests and must never enter production imports.
- Sync model (Release 1): **multiple authorized writing devices + read-only viewers (protocol v3).** Enforced in three layers — `AppSession.canDo`/`canWrite`, route guard blocking `/inspection-new`, and Firestore Rules (registered device, role permissions, expected versions and atomic command receipts). Older business-write protocols are denied; offline drafts require explicit submission. Don't relax any layer casually.
- Current sync authority: `SYNC_CURRENT_CONTRACT.md`. The October 29 user decision caps QC custom tables at **9 columns**, allowing **10 business effects** atomically for custom-table definitions and columns only. Other families and mixed operations retain **4 effects**. Larger operations remain unsent drafts with submission disabled; enabled operation combinations require rules-budget proof. Never split a business operation to evade the limit. A deleted local cache is rebuilt from a complete permission-scoped Firestore snapshot, never by auto-seeding/uploading local rows.

## Testing conventions

- 143 test files; widget/unit suites meshed under `test/` grouped by area (architecture, security, sync, features…). Use `mocktail` for fakes.
- Security/emulator suites: always run against emulators (see Commands). Never point tests at a production Firebase project.
- Squad/banner conventions: tests detect the emulator env and skip plain runs on purpose — don't "fix" skipped green suites by pointing them at real Firebase.

## Repo map

- Chinese-language planning docs at root (`PLAN_V*.md`, `PROJECT_AUDIT.md`) — historical design notes; `tool/firebase/README.md` is the authoritative build/deploy doc.
- `tools/migrate_legacy_inspections.py` — one-off legacy data migration from the Python original.
- Bundled `Reference.xlsx` / `units.xlsx` are migration inputs, never automatic shared-data seeds on sign-in. Shared data downloads from the approved Firestore archive; images/templates/fonts remain under `assets/`.
