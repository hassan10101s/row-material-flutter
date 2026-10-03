# PLAN_V4.md — Material Lab: Android + Per-Feature Desktop/Mobile UI Split

> **Status:** active execution plan.
> **Builds on:** `PLAN_V3.md` (Phases 0–3 target the same goal but contain verified factual
> errors and one blocking bug — see [Corrections](#1-corrections-to-plan_v3-verified-against-the-tree)).
> **Supersedes:** `PLAN_V3.md` §1, §2.1, §2.2, §5. PLAN_V3 Phases 4–7 are still carried
> forward unchanged as Phases 6–8 of this plan.
> **Golden rule (inherited):** understand the existing Material Lab, then extend it. We do not
> start a new project and port into it. **Build Once — Reuse Everywhere. One Repository —
> Shared Logic — Adaptive UI.**

---

## 0) Locked decisions

| Decision | Choice | Why |
|---|---|---|
| UI split | **Full per-feature file split** — `presentation/desktop/` + `presentation/mobile/` behind a router dispatcher | Maximum design control; each form factor gets a purpose-built screen instead of a degraded one |
| ScreenUtil | **Kept** — `designSize` selected per **platform**, never per width | 400 call sites across 43 files. Desktop must not move a pixel. See [§2 The invariant](#2-the-one-invariant) |
| Platforms | **Android only** | Matches PLAN_V3 Phase 1's reasoning; iOS is a follow-up |
| Scope | PLAN_V3 Phases 0–7, i.e. everything through Quality features + launch | |
| Form factor | Resolved once from `defaultTargetPlatform` at startup, then carried down `ResponsiveScope` | A *platform* decision, not a *width* decision. See [§2](#2-the-one-invariant) |

### Why form factor must never be width-derived

The entire split rests on this. If form factor came from `MediaQuery`/`LayoutBuilder`:

1. `designSize` is a process-wide singleton set once in `main.dart` **before** `runApp`. A
   width-derived form factor would either be stale (decided from the launch window, never
   updated on resize) or would have to be re-initialised mid-flight, re-scaling all 400 call
   sites under the user.
2. PLAN_V3 §2.1 proposed `designSize = (logical.width >= 1000) ? Size(1280,720) : Size(400,860)`.
   A Windows user launching with a half-snapped window (<1000 logical px) would get the **mobile**
   design size: `280.w` becomes 672dp and `.spMax` inverts. This is a live bug in PLAN_V3.
3. A width-derived form factor also makes the router dispatch wrong, because `pageBuilder` would
   need to re-run on every resize.

`responsive_guard_test.dart` (§4) enforces this mechanically.

### What keeping ScreenUtil buys, and its one cost

With `designSize` per platform, a 360×800 dp phone resolves `scaleWidth = 360/400 = 0.90` and
`scaleHeight = 800/860 = 0.93`. Therefore:

- `.w` behaves as *fraction of a 400 dp reference* — correct on a phone.
- `.r ≈ 0.90` — authored corner radii are preserved.
- `.spMax` is `max(absolute, scaled)`, so the theme's text never shrinks below its authored size.
  This is why `.spMax` is used throughout and must stay.

**The cost:** the 400 call sites keep desktop semantics *forever*, and the design system is
shared by both variants. So **shared design-system widgets must stay form-factor-neutral**
(fixed rhythm from `AppSpacing`, proportional things from `.w`); only files under
`presentation/desktop/` and `presentation/mobile/` may branch. Also enforced by the guard test.

---

## 1) Corrections to PLAN_V3 (verified against the tree)

| PLAN_V3 states | Actual | Impact |
|---|---|---|
| §1: ScreenUtil = "198 calls in 34 files" | **400 calls, 43 files** | §2.1's cost estimate is 2× too low |
| §2.2: create `lib/core/responsive/breakpoints.dart` | `design_system/tokens/app_breakpoints.dart` **already exists and has zero importers — dead code** | Consolidate into the existing file; do not add a third source of truth |
| §2.1: `designSize` from `logical.width >= 1000` | Breaks on a snapped Windows window (see above) | **Blocking.** Replaced by a platform decision |
| §2.1–2.8 line refs (`app_shell.dart:151/158/229-250`, `app_paginated_table.dart:36/100`) | Shifted — real positions are `app_shell.dart:186` (breakpoint), `:193` and `:249` (`280.w`), `:235-257` (drawer overlay), `:263-287` (shortcuts) | Re-verify every reference before editing |
| §2.2: "8 LayoutBuilder" | 9 (excluding one in a doc comment): `dashboard_screen` ×4, `inspections_screen`, `inspection_detail_screen`, `inspection_form_screen`, `test_history_tab`, `app_paginated_table` | Minor |
| Phase 0 "82 uncommitted files" | 29 on `main`, and **no `v2-baseline` tag exists** | Phase 0 was never completed |

---

## 2) Invariants — every phase passes or the phase does not close

Existing guards (unchanged, still binding):

| Guard | Rule |
|---|---|
| `repository_boundary_test.dart:172` | ratchet — `presentation/` never gains a `data/` import |
| `repository_boundary_test.dart:191` | the frozen ratchet list has no stale entries |
| `repository_boundary_test.dart:214` | no `DatabaseHelper` / `package:sqflite` / `SELECT` / `INSERT` in `presentation/` |
| `repository_boundary_test.dart:233` | a feature may only own `data/ domain/ presentation/ core/` |
| `repository_boundary_test.dart:255` | every declared domain contract is registered in DI |
| `firebase_isolation_test.dart` | no `cloud_firestore` / `firebase_auth` outside `core/sync/remote/` |
| `permissions_parity_test.dart` | `permissions.dart` ≡ `firestore.rules`, compared literally |

New guard added in Phase 2:

| Guard | Rule |
|---|---|
| `responsive_guard_test.dart` | (a) no form factor derived from `MediaQuery`/`LayoutBuilder`/window size; (b) every `presentation/desktop/x.dart` has a `presentation/mobile/x.dart` sibling and vice versa; (c) no variant imports `data/`; (d) shared design-system widgets contain no form-factor branch |

Command run at the end of every phase:

```bash
flutter analyze               # 0 errors
flutter test                  # green, including all guards
flutter build windows --release
```

---

## 3) Phase 0 — Freeze the baseline

The gate for everything else.

```bash
git add -A
git commit -m "v2-baseline: org auth + offline-first sync + audit trail + reports templates"
git tag v2-baseline
```

**Why:** 29 changed files on `main` (15 modified, 14 untracked) and no tag. There is no revert
point today, so no other phase is safe to start.

**Acceptance:** tag exists · `analyze` 0 · tests green · Windows release builds.

---

## 4) Phase 1 — Add Android to the same repository

### 4.1 Project scaffolding

```bash
flutter create --platforms=android .
```

`.metadata` currently records `platforms: [root, windows]`. There is no `android/` directory.

`android/app/src/main/AndroidManifest.xml`:

| Setting | Value | Reason |
|---|---|---|
| `android:allowBackup` | `false` | **Mandatory.** Auto Backup would copy the organization database (`orgs/<orgId>/material_lab.db` and `.secret`) into Google Drive, voiding the physical isolation documented at `app_paths.dart:11-12` |
| `android:usesCleartextTraffic` | `false` | |
| permissions | `INTERNET` | Firebase sync |
| permissions | `CAMERA` | `image_picker`, Phase 7 |
| permissions | **no** `WRITE_EXTERNAL_STORAGE` | evidence goes to the app sandbox |

### 4.2 Packages

```bash
flutter pub add open_filex share_plus image_picker
flutter pub add workmanager
```

| Package | Priority | Exact reason |
|---|---|---|
| `open_filex` | P0 | every PDF export writes to `report_service.dart` ⇒ `/data/user/0/<pkg>/files/MaterialLab/exports/…`, unreachable by any file manager |
| `share_plus` | P0 | same destination, and the alternate delivery for the `.db` backup (`settings_screen.dart`) |
| `image_picker` | P0 | required by Phase 7 (photo checklist answer) and evidence capture |
| `workmanager` | P1 | `BackupManager.autoBackup()` runs **once** at org bind time (`service_locator.dart`). Android kills the process, so **there is currently no periodic backup at all** without this |

**Forbidden:**

- ⛔ `sqlite3_flutter_libs` — `database_helper.dart:35-37` deliberately excludes Android from the
  FFI path. Adding it is the change that *breaks* the build.
- ⛔ `device_info_plus` — removed on purpose; `Platform.operatingSystem` is used instead.

### 4.3 Harden `flutter_secure_storage`

In `session_store.dart` and `token_storage.dart`:

- add `resetOnError: true`. Without it a `KeyStoreException` after a device restore **throws**
  instead of recovering.
- delete `encryptedSharedPreferences: true` — abandoned and a no-op in 9.2.4.

### 4.4 Google Sign-In on Android

The branch at `auth_remote_data_source.dart:54` (`if (!Platform.isWindows) return;`) is already
correct, and `google_sign_in: 6.3.0` resolves to `google_sign_in_android`, so sign-in does execute.
Three things are wrong:

1. `firebase_options.dart:117` has no `googleAndroidClientId` — add it as a `--dart-define`.
2. `isConfigured` (`:574`) checks `googleClientId.isNotEmpty`, i.e. a **Desktop** client id. On
   Android `GoogleSignIn(clientId:)` is *ignored* and Play Services uses the id in
   `google-services.json`. Make the check platform-correct.
3. Error copy (`:58-63`, `:87-90`) tells the user to create a "Desktop app" OAuth client — wrong
   on a phone.

Console work: register the package name + SHA-1 in project `materiallab-63405`, add an Android
OAuth client, commit `google-services.json`.

**Acceptance:** debug APK builds and runs · sign-in works on both platforms · Windows release green.

---

## 5) Phase 2 — Responsive foundation

### 5.1 `ResponsiveScope`

New `lib/core/responsive/responsive_scope.dart`: an `InheritedWidget` above `MaterialApp`
carrying one resolved `LayoutSpec { formFactor, gutter, density, textScale }`. The form factor is
resolved **once** in `main()` from `defaultTargetPlatform` and handed down, so no descendant ever
consults the window size to decide *which* experience it is in.

### 5.2 `designSize` per platform

`main.dart:57` becomes the platform-selected size:

- desktop → `const Size(1280, 720)` — desktop is byte-for-byte unchanged
- mobile → `const Size(400, 860)`

### 5.3 Consolidate breakpoints

`design_system/tokens/app_breakpoints.dart` is revived as the **single** source. Do not create
PLAN_V3 §2.2's competing `lib/core/responsive/breakpoints.dart`. Reassign the five stray magic
numbers (600 / 700 / 720 / 760 / 900) to named tokens and replace the 9 `LayoutBuilder` sites.
Note `app_shell.dart:186`'s hard-coded `720` and PLAN_V3's differing `720 / 1100` pair — one set
of values, chosen once, used by every screen.

### 5.4 `responsive_guard_test.dart`

Four rules, described in [§2](#2-invariants--every-phase-passes-or-the-phase-does-not-close).

### 5.5 Platform ports

`Platform.is*` is currently branched inline in 8 files and is untestable. Introduce ports with two
implementations each, all registered in `service_locator.dart` (required by
`repository_boundary_test.dart:255`):

| Port | Desktop | Mobile |
|---|---|---|
| `FileOpener` | `explorer` / `open` / `xdg-open` | `open_filex` |
| `FileSharer` | — | `share_plus` |
| `FolderPicker` | Windows folder picker | no-op / share sheet |
| `DatabaseOpener` | `databaseFactoryFfi` | native `sqflite` — **dropped**, see below |
| `AutoBackupScheduler` | OS task | `workmanager` |

Layout: `lib/core/platform/<port>/<port>.dart` (interface), `…_desktop.dart`, `…_mobile.dart`.

`FileOpener` and `FileSharer` ship as one `FileDelivery` port: they are two verbs on the same
question, and the capability pair (`canReveal` / `canShare`) is what the UI actually branches on.

**As implemented:** `FileDelivery`, `FolderPicker`, `AutoBackupScheduler` and the Android
`workmanager` adapter are in `lib/core/platform/` + `lib/app/auto_backup_task.dart`, all registered
in `service_locator.dart`. `lib/di/platform_ports.dart` resolves a port without throwing when the
locator is empty, because every caller sits on a path that is already reporting a *successful*
operation — a missing registration there would replace good news with a red error.

`DatabaseOpener` was **dropped from the plan**, deliberately. `DatabaseHelper.ensureDesktopFactory`
already does the only thing a port would do — pick `databaseFactoryFfi` on desktop, leave the
native factory alone on mobile — and the native factory is installed by `SqflitePlugin.registerWith`
(`databaseFactoryOrNull ??= databaseFactorySqflitePlugin`) *before* DI runs, so the ordering is
already correct. An interface here would add a layer and rewrite 16 test call sites without changing
behaviour. What was missing was proof, so `test/database/factory_selection_test.dart` now pins the
three properties that actually matter: idempotence, FFI on desktop, and the plugin's factory
surviving on mobile.

**Consumers of these ports:**
- `AppFeedbackExport` (see below) — the export dead end.
- `settings_screen.dart` — the "choose folder" / "open" buttons are now driven by
  `FolderPicker.supported` and `FileDelivery.canReveal`, so a phone shows neither and explains that
  reports are saved inside the app.
- `app_shell.dart` — the sidebar's "open PDF folder" button is hidden when the folder cannot be
  shown.

`lib/core/utils/app_launcher.dart` was deleted; it was the inline `Platform.is*` version of the same
two ports, and it returned `false` on mobile after silently doing nothing.

**The first consumer of these ports was the export dead end.** `AppFeedback.success(context,
'Exported: <path>')` told the user about a file living in
`/data/user/0/<pkg>/files/MaterialLab/exports/`, which no Android file manager can open — a success
message with no way to act on it. `design_system/feedback/app_feedback_export.dart` replaces it with
a sheet offering exactly the actions `FileDelivery` reports, and a plain message when neither is
available. Covered by `test/design_system/app_feedback_export_test.dart`.

**Acceptance:** Windows + Android + old data + navigation — all four, or stop.

---

## 6) Phase 3 — Domain contracts *(load-bearing; not in PLAN_V3)*

**Splitting a screen moves it to a new path, which breaks the frozen ratchet twice at once:** the
old entry goes stale (`repository_boundary_test.dart:191` fails) and the new path is an unlisted
violation (`:172` fails). The only fix that is not bookkeeping is to give each split feature a real
domain contract so **neither variant needs `data/` at all**.

| Feature | Exists today | Action |
|---|---|---|
| inspections | `domain/inspection_repository.dart` ✓ | point both variants at `InspectionRepository`; delete its 7 ratchet entries |
| members | `domain/` (62 ln) ✓ | confirm `MemberRepository` is real and in DI |
| lab | `domain/lab_result_repository.dart` only | add `LabConfigurationRepository` (verify the DI list) |
| dashboard | none | new `domain/dashboard_repository.dart` |
| reference | none | new `domain/reference_repository.dart` |
| reports | none | new `domain/report_repository.dart` |
| sync | none | new `domain/sync_repository.dart` |

Every one is registered in `service_locator.dart`. The ratchet list shrinks monotonically — never
grows.

### 6.1 Two global-state leaks to close first

- **`AppText.t(ar, en)` is a global static.** `AppText.arabic` is set in `main.dart:30` and `:82`
  and read imperatively all over the app, *coexisting* with ARB `context.l10n`. With 21 screens
  duplicated, a single missed write silently desyncs half the labels. Fold it into `context.l10n`
  before splitting.
- **`getIt<X>()` called inside widget `build()`** (`app_shell.dart:145-155`, `:339`, `:353`). This
  is untestable and would have to be copied into every variant. Move to router / cubit injection.

---

## 7) Phase 4 — Per-feature split

A dispatcher in `app_router.dart` selects the variant from the platform-derived form factor.

### 7.1 Tier A — split (data surface, wide form, or fixed dialog)

shell · dashboard · inspections ×3 · lab host + analyses · test history · constants · inventory ·
run test · reference host + products · params · units · materials · material_editor · reports ·
settings · audit · login. **21 units.**

### 7.2 Tier B — single adaptive file (carve-out)

`waiting_activation_screen` (125 ln) · `create_organization_screen` (119) · `activity_tab` (66) ·
`members_screen` (380) · `sync_screen` (370) · `sync_badge` (129, lives inside the split topbar).
Too small or too reflowable for a split to buy anything.

> Folder layout is legal: `repository_boundary_test.dart:233` checks
> `parts.sublist(3).first ∈ {data, domain, presentation, core}`, so
> `lib/features/x/presentation/desktop/y.dart` passes.

### 7.3 Per-unit checklist

- table → `AdaptiveDataView` (one row model; table ⇄ card list) — covers the 7 `DataTable` sites
  (`units_tab`, `products_tab`, `params_tab`, `analyses_tab`, `constants_tab`, `inventory_tab`,
  `test_history_tab`)
- `app_paginated_table.dart:36` `height: 470` → `double?` where `null` fills available space;
  `:100` `itemExtent: 52` → 56 on compact; `:37` `minTableWidth: 640`
- the 3 fixed-size dialogs → full-screen routes on mobile: `material_editor` 880×680,
  `products_tab` 760×620, `test_history_tab` 1040×780
- `app_button.dart:99` `(small ? 34 : 42).h` → 48 dp floor on compact
- `PopScope` on the drawer overlay (`app_shell.dart:235-257`) — Android back does not close it today
- `Ctrl+1..9` (`app_shell.dart:263-287`) → long-press on bottom-nav items, for mobile parity
- desktop variants are **visual-only**; with `designSize` 1280×720 unchanged, desktop must not move

---

## 8) Phase 5 — Mobile regression

Extend `test/manual/v1_acceptance_checklist.md` (do not create a parallel checklist). Two platforms,
real legacy data:

```
Material Module      PASS
Sample Module        PASS
Lab Module           PASS
Reports              PASS
Authentication       PASS
Settings             PASS
Windows              PASS
Android              PASS
```

Any regression in an existing function blocks completion.

---

## 9) Phases 6–8 — carried forward from PLAN_V3 §7–11

**Phase 6 — Generalize the data model.** Repair the unit system **first**: `convertQuantity`
(`formula_engine.dart`) returns its input unchanged for any unit outside 5 hard-coded symbols, which
covers most of the application's real parameters. Add `base_symbol` / `conversion_factor` to
`lab_units`, seed from the 52 units in `units.xlsx`, make the engine read the table with the maps
as fallback. Then `item_types` and a single `SpecResolver` over a generic `lab_item_analyses` table.
Zero data loss; existing reports must stay byte-identical.

**Phase 7 — Quality Core.** 3 new tables (`quality_tasks`, `quality_task_evidence`,
`quality_task_events`) via DDL in `_createSchema` only — `version: 1` stays fixed. Evidence bytes
are device-local and **never** enter a sync payload. `quality_*` must **not** join `syncedTables`.
Wire the already-existing `AuditLogger` into the unlogged write paths. Widen `permissions.dart`
**and** `firestore.rules` together or `permissions_parity_test.dart` fails.

**Phase 8 — Quality features + launch.** 12 features, each gated on Windows · Android · old data ·
CRUD · permissions · evidence · alerts · back-navigation. Then
`flutter build windows --release` + `flutter build apk --release`, and correct `README.md` (still
says "Flutter Desktop", lists `printing` and `qr_flutter` which are not in `pubspec.yaml`).

---

## 10) Commit sequence

```
v2-baseline (tag)
  → add-android-platform
  → responsive-foundation            (scope + designSize + breakpoints + guard test)
  → platform-ports
  → domain-contracts                 (dashboard, reference, reports, lab-config, sync)
  → l10n-and-di-cleanup              (AppText.t → context.l10n, getIt out of build)
  → adaptive-design-system           (AdaptiveDataView, touch targets, table height)
  → split-shell
  → router-dispatcher
  → split-dashboard → split-inspections → split-inspection-detail
  → split-inspection-form → split-lab → split-run-test
  → split-test-history → split-reference → split-reports
  → split-settings → split-audit → split-login
  → mobile-regression
  → repair-unit-system
  → generalize-item-types-and-specs
  → quality-core
  → quality-objectives → equipment → equipment-alerts
  → checklists → checklist-reminders → checklist-failed-to-action
  → non-conformity → capa → customer-complaints
  → notification-center → quality-dashboard → final-permissions
  → full-regression → windows-release → android-release → documentation
```

One commit per stable phase. No amend, no force-push, never ten features in one commit.

---

## 11) Definition of success

1. Every existing Material Lab function still works — the regression matrix is fully green.
2. `flutter analyze` = 0 and `flutter test` green, **including** `repository_boundary_test`,
   `firebase_isolation_test`, `permissions_parity_test`, and `responsive_guard_test`.
3. The app builds from one repository: `flutter build windows --release` **and**
   `flutter build apk --release`.
4. The UI adapts with **no duplicated business logic** — e.g. one `saveSample()`, two layouts.
5. Desktop visuals are unchanged by the split.
6. Form factor is a platform decision, enforced by a test.
7. Every `desktop/` unit has a `mobile/` sibling and both depend on domain contracts only.

---

## 12) Risk register

| Risk | Mitigation |
|---|---|
| ScreenUtil is a process-wide singleton; its 400 call sites keep desktop semantics forever | Variants may branch; shared design-system widgets must stay form-factor-neutral. Guard rule (d) |
| Splitting a screen breaks the frozen ratchet twice | Phase 3 lands before Phase 4, so the contract exists before the move |
| 21 duplicated units drift apart | Guard rule (b) fails on a missing sibling; per-screen regression checklist |
| `.spMax` floors text at the authored size; a font-scale change compounds with the `designSize` swap | A visual pass is the Phase 2 gate, not `analyze` |
| Android kills the process → no scheduled backup at all | `workmanager` is P1 in Phase 1, not deferred |
| Folder pick / "open PDF folder" has no mobile equivalent | `FolderPicker` port returns null on mobile; the shell hides the affordance rather than showing a broken tap |
