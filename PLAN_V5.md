# PLAN_V5.md — Material Lab: consolidated execution plan

> **Status:** active execution plan. One authoritative document.
> **Supersedes:** `PLAN_V4.md` (kept — its Phase 1–3 are closed and its §1 corrections are
> folded in here) and `PLAN_V3.md` (archived; its Phases 4–7 survive as P4–P8 below).
> Also archived: `PLAN_V1_PORT_DONE.md`, `PLAN_V2_ORG_FIREBASE_OFFLINE_FIRST.md`,
> `PROJECT_AUDIT.md`.
> **Golden rule (inherited, unchanged):** understand the existing Material Lab, then extend
> it. We do not start a new project and port into it. **Build Once — Reuse Everywhere.
> One Repository — Shared Logic — Adaptive UI.**

Every factual claim below was read out of the tree at commit `b06f2ff`. Claims are tagged:

- **[verified]** — read directly in this session; `file:line` is exact.
- **[agent]** — verified by a repository audit pass against source, `file:line` exact.
- **[re-verify]** — the reference came from an earlier plan and the file has since
  changed. **Re-read before editing.** These are marked individually and none of them is
  load-bearing on its own.

---

## 0) Verified current state

### 0.1 What has actually landed

PLAN_V4's Phases 1–3 are **closed**. Evidence:

| Phase | Closed by | Evidence |
|---|---|---|
| 1 — Android | `android/` + hardened manifest + 4 packages | `android/app/src/main/AndroidManifest.xml` has `allowBackup="false"`, `usesCleartextTraffic="false"`, `INTERNET` + `CAMERA`, **no** `WRITE_EXTERNAL_STORAGE` **[verified]** · `.metadata` records `android` **[verified]** · `pubspec.yaml:62-65` `open_filex ^4.7.0`, `share_plus ^12.0.2`, `image_picker ^1.2.3`, `workmanager ^0.10.10` **[verified]** · `lib/core/platform/` (7 files) + `lib/app/auto_backup_task.dart` **[verified]** |
| 2 — Responsive foundation | `core/responsive/` + adaptive primitives | `form_factor.dart` (67 ln), `layout_spec.dart` (72 ln), `responsive_scope.dart` **[verified]** · `main.dart:75-77` picks `designSize` from `FormFactor.current.isMobile`; `main.dart:120-126` puts `ResponsiveScope` **above** `MaterialApp` so dialogs resolve it **[verified]** · `app_adaptive.dart:35-41` `appAdaptiveVariant`, `:44-60` `AppAdaptive` **[verified]** · `app_adaptive_list.dart:19-35` `AppDataRow`, `:46-58` `AppAdaptiveDataView`, `:249` `supportsDataTable` **[verified]** · `app_paginated_table.dart:31,42,50-51` already parameterised (`height`, `rowHeight`, `minTableWidth = 640`) **[verified]** · `responsive_guard_test.dart` (221 ln, 5 tests) **[verified]** |
| 3 — Domain contracts | 11 contracts, all in DI | `repository_boundary_test.dart:170-182` lists 11 contract names; `service_locator.dart` registers every one **[verified]** |
| 4 — Per-feature split | **5 of 21** Tier-A units | §0.3 |

### 0.2 Three corrections to the prior plans

1. **PLAN_V4 §6.1 is wrong about `getIt`.** No `getIt` call sits inside `build()`. All of
   them are in `initState` or callbacks: `analyses_tab.dart:210-211`,
   `lab_screen.dart:81-83`, `reference_screen.dart:40-41`, `test_history_tab.dart:85-87`,
   `inspections_screen.dart:46,80,118`, `app_shell.dart:46-49` **[verified]**. They are
   still untestable and still must move to constructor injection, but the failure mode
   PLAN_V4 described does not exist.

2. **PLAN_V3's ratchet count is stale by an order of magnitude.** It is **6 entries /
   7 import targets** (`repository_boundary_test.dart:21-41`), not 40 **[verified]**.

3. **`mutableFields` is documentation-only, and `entity_registry.dart` claims otherwise.**
   `firestore.rules:106-112` states it in a comment: the real payload is *every* column of
   the backing table because `buildRemotePayload` ignores `mutableFields`. The four synced
   blocks have **no `hasOnly`** — `samples :382`, `qualityChecks :390`, `labResults :400`,
   `labConfig :407` — while all seven hand-written blocks do **[agent]**.
   `entity_registry.dart:34-35` says the list "must match the `hasOnly([...])` list in
   `firestore.rules`", which is false for those four **[agent]**.

### 0.3 The split: 5 of 21 done, and the shape they establish

Already split — both variants present:

| Unit | desktop | mobile | dispatcher | shared editor |
|---|---:|---:|---:|---|
| `reference/units_tab` | 179 | 211 | 18 | `units_editor.dart` (154) |
| `reference/params_tab` | 183 | 224 | 20 | `params_editor.dart` (175) |
| `reference/materials_tab` | 218 | 223 | 28 | — |
| `reference/material_editor` | 62 | 40 | (in host) | — |
| `lab/constants_tab` | 193 | 272 | 31 | `constants_editor.dart` (200) |

All line counts **[verified]**.

**The dispatcher is the whole of the host** — `lab/presentation/constants_tab.dart:26-30`:

```dart
@override
Widget build(BuildContext context) => appAdaptiveVariant(
  context,
  desktop: (_) => DesktopConstantsTab(repo: repo),
  mobile: (_) => MobileConstantsTab(repo: repo),
);
```

The repository is a **constructor parameter**, never a `getIt` lookup, so both variants get
the same instance and the variant is constructible in a test. This is the shape every
remaining unit copies.

**The parity harness is the real defence.** `presentation_split_test.dart` (525 ln) holds
both variants of a unit to a payload written out *independently of either*
(`:35-43 expectedConstant()`), drives both through `pumpAs(tester, factor, …)`
(`:219-230`) on the grid each was authored against (`:28-29`), and asserts the desktop
editor is a dialog while the phone editor is a full-screen route (`:335-365`).

---

## 1) The two findings that reorder the roadmap

### 1.1 The ratchet → zero is the highest-leverage single move

Only one remaining Tier-A unit touches the ratchet: `settings_screen.dart`. Splitting it
makes its ratchet key **stale** (`:103` fails) and creates an **unlisted** violation
(`:84` fails) simultaneously. Three contracts clear all six entries:

| Contract to add | Registered as | Frees | Entries deleted |
|---|---|---|---|
| `auth/domain/auth_repository.dart` — interface; `data/auth_repository.dart` implements it | `<AuthRepository>` | `login_cubit`, `create_organization_cubit` | 2 |
| `settings/domain/settings_repository.dart` — interface over `SettingsRepo` | `<SettingsRepository>` | `general_settings_cubit`, `settings_screen` | 2 |
| `backup/domain/backup_service.dart` — interface over `BackupManager` | `<BackupService>` | `migration_panel`, `database_settings_cubit`, `settings_screen` | 3 |

Each is appended to the `contracts` list at `repository_boundary_test.dart:170` — the test
at `:167-192` requires the name to appear as `<Name>` in `service_locator.dart`.

**When the map is empty, delete `_legacyPresentationDataImports` and turn `:84` from a
ratchet into a hard failure.** After that the boundary is permanent, not a promise.

### 1.2 The shell must be split first, not last

`app_shell.dart` (615 ln) has **no** `NavigationBar`, no `PopScope`, and no `appAdaptive`
call **[verified]**. Until it is split, the mobile build has no way to reach any screen on
a device — a split unit can only be verified on Windows, which defeats the point.

Splitting it first means every later unit is verified inside a real phone frame. Risk is
contained because the desktop variant is a **verbatim** move: `_Sidebar` (`:395`), the
`280.w` widths (`:199`, `:255`), `_TopBar` (`:296`), `_NavItem` (`:596`) and the
`CallbackShortcuts` (`:266`) must not move a pixel.

---

## 2) The remaining 16 Tier-A units — execution table

Ordered for **verifiability**, not size. `getIt` = sites that must become constructor
injection so the variant is constructible in a test. Dialog figures are **[verified]** from
the source.

| # | Unit | Lines | `DataTable` | Fixed dialogs / width reads | `getIt` | Contract | Parity cases to add |
|---|---|---:|---|---|---|---|---|
| 1 | `shell/app_shell.dart` | 615 | — | — | 46-49, 117 | none (`core/sync`) | bottom-nav targets ≡ sidebar targets · `Ctrl+1..9` ↔ long-press · drawer `PopScope` closes on system back |
| 2 | `auth/login_screen.dart` | 161 | — | AlertDialog `:72-74` | — | none | both variants reach the same `LoginCubit` |
| 3 | `reports/reports_screen.dart` | 286 | — | — | — | `ReportRepository` ✓ | `AppFeedbackExport` sheet offered on both |
| 4 | `audit/audit_screen.dart` | 350 | — | — | — | `AuditTrail` ✓ | same rows, same filters, same action labels |
| 5 | `inspections/inspections_screen.dart` | 305 | — (ledger) | 260.w panel `:172` · `AppBreakpoints.expanded` `:207` | 46, 80, 118 | `InspectionRepository` ✓ `ReferenceRepository` ✓ `ReportRepository` ✓ | same ledger rows both sides · panel → full-screen route on mobile |
| 6 | `inspections/inspection_detail_screen.dart` | 544 | — | `DecisionDialog` `:49` · AlertDialog `:66` · `LayoutBuilder` `:128` | — | ✓ | the decision writes an identical payload from both |
| 7 | `reference/reference_screen.dart` (host) | 127 | — | — | 40, 41 | ✓ | all 4 tabs reachable on both |
| 8 | `reference/products_tab.dart` | 578 | `:131` | **760.w × 620.h** `:359-360` · AlertDialog `:37` | — | ✓ | upsert payload + delete-guard identical |
| 9 | `lab/lab_screen.dart` (host) | 182 | — | — | 81-83, 131 | ✓ | all tabs reachable on both |
| 10 | `lab/analyses_tab.dart` | 1236 | `:111` | **720.w** `:1045` · AlertDialog `:1042` · SimpleDialog `:993` | 210, 211 | `LabConfigurationRepository` ✓ `LabLocalRepository` ✓ | upsert payload · field-picker result identical |
| 11 | `lab/inventory_tab.dart` | 443 | `:92` | **420.w** `:267` · **400.w** `:412` · AlertDialog `:264`, `:409` | 206, 364 | ✓ | `adjustStock` arguments identical |
| 12 | `lab/test_history_tab.dart` | 1028 | `:615` | **1040×780** `:95` · **760×640** `:226` · `LayoutBuilder` `:741` | 85-87 | ✓ | both filters build the same query |
| 13 | `dashboard/dashboard_screen.dart` | 938 | — | `LayoutBuilder` ×4 — `:205`, `:399`, `:706`, `:783` | — | `DashboardRepository` ✓ | identical KPI values both sides |
| 14 | `lab/run_test_tab.dart` | 737 | — | — | 36 | ✓ | identical consumption + result payload |
| 15 | `inspections/inspection_form_screen.dart` | 1385 | — | `LayoutBuilder` `:1095`, reads `constraints.maxWidth` `:1100` | 537 | ✓ | **heaviest numeric entry** — field-for-field parity |
| 16 | `settings/settings_screen.dart` | 738 | — | — | 107, 112-113, 264, 341 | **blocked on §1.1** | 5 tabs both sides · folder/open buttons hidden when `!FileDelivery.canReveal` |

**Tier B — stay single adaptive files.** Tier B is not "unsplit"; it is *deliberately
unsplit*, because a split would buy nothing:

`members_screen.dart` (380) + `leave_organization_section.dart` (177) · `sync_screen.dart`
(429) · `auth/waiting_activation_screen.dart` (125) · `auth/create_organization_screen.dart`
(119) · `lab/activity_tab.dart` (74) · **`lab/lab_reports_tab.dart` (174)** — the last one
is in **neither** PLAN_V4 tier list; assigning it Tier B here closes that gap **[verified]**.

**Never split — shared by construction.** `inspections/presentation/inspection_widgets.dart`
(204, holds `DecisionDialog`) · everything under `core/sync/` · everything under
`design_system/`.

### 2.1 Per-unit recipe

Five mechanical steps. Copy the shape of `lab/constants_tab.dart`.

1. **Extract** shared logic into `<unit>_editor.dart` if the unit has a dialog. Never copy
   it — a copy lets the two drift silently.
2. **`presentation/desktop/<unit>.dart`** = the current file, **verbatim**. It is a move,
   reviewed as a move.
3. **`presentation/mobile/<unit>.dart`** = card list via `AppAdaptiveDataView`; every fixed
   dialog becomes a `Navigator.push` full-screen route with its own `Scaffold` + `AppBar`.
4. **`presentation/<unit>.dart`** = ~30-line dispatcher using
   `appAdaptiveVariant(context, desktop: …, mobile: …)`, with every repository passed in
   the constructor.
5. **Parity cases** in `test/features/<feature>/<unit>_split_test.dart`, modelled on
   `presentation_split_test.dart:290-430`: hold both variants to a payload written out
   independently of either, and assert dialog-on-desktop / route-on-mobile.

Two mechanical rules make this safe, both already true and worth stating so they are not
undone:

- `responsive_guard_test.dart:137` requires a sibling to **exist**. It does not check it is
  real.
- `app_paginated_table.dart` carries no form-factor branch, by design (`:17-21`). The
  per-experience knobs are the `height` / `rowHeight` **parameters**, supplied by the
  variant that calls it.

### 2.2 Guard gap to close

`responsive_guard_test.dart:137` passes for a stub. Add **rule (e)**: both variants of a
unit must exceed 80 lines and neither may contain `TODO`. Rule (e) is a smoke detector;
the parity test is the real defence, which is why step 5 is not optional.

---

## 3) Phases

### P0 — Baseline

```bash
git tag v2-baseline b06f2ff
```

**Nothing else is safe until this tree is proven green.** No `v2-baseline` tag exists
**[verified]**, and `flutter analyze` / `flutter test` have never been recorded as passing
at `b06f2ff`. Run them before anything else — the baseline is a measurement, not an
assumption.

**Gate:** tag exists · `flutter analyze` = 0 · all 70 test files green · `flutter build
windows --release` succeeds.

### P1 — Ratchet → zero

The three contracts in §1.1. Then delete `_legacyPresentationDataImports`
(`repository_boundary_test.dart:21-41`) and rewrite `:84` as a hard failure.

**Gate:** `repository_boundary_test` green with **no** ratchet map. **Commit:**
`ratchet-to-zero`.

### P2 — Split the 16 units

§2 order, one commit each. **Gate per unit:** `flutter analyze` 0 · `flutter test` green ·
`flutter build windows --release` · `flutter build apk --debug` · **visual pass on both
platforms**.

> The visual pass, not the analyzer, is the gate. Changing `designSize` from 1280×720 to
> 400×860 reinterprets every `.w` / `.h` / `.spMax` call site. `flutter analyze` is
> completely blind to that, and `.spMax` means text can never shrink below its authored
> size — so the failure mode is "looks slightly wrong", not "does not compile".

### P3 — Mobile regression

Extend `test/manual/v1_acceptance_checklist.md` — **it exists**; do not create a parallel
checklist.

```
Material Module      PASS        Settings            PASS
Sample Module        PASS        Quality Feature     PASS
Lab Module           PASS        Windows             PASS
Reports              PASS        Android             PASS
Authentication       PASS
```

Two platforms, real legacy data. Any regression in an existing function blocks completion.

### P4 — Repair the unit system

**The defect:** `convertQuantity` (`formula_engine.dart:14-31`, `:64-72`) hard-codes five
symbols and **silently returns its input unchanged** for anything else **[re-verify]**.
Five hard-coded symbols covers a small fraction of the application's real parameters —
`parameters.unit` is free text seeded from `units.xlsx` (52 units: `mg/kg`, `ppm`, `g/L`,
`mmol/kg`, `mgKOH/g`, `µg/kg`). The `lab_units` table has a CRUD screen
(`units_editor.dart`) and **is never read by the engine**.

**Steps:**

1. Add `base_symbol` and `conversion_factor` to `lab_units` through the existing
   `_ensureColumn` helper **[re-verify: `database_helper.dart` changed by 127 lines in
   `b06f2ff`; `PLAN_V3` cited `:470`]**.
2. Seed all 52 factors from `units.xlsx`; derive `dimension` via `unitDimOf` so the seed
   and the engine agree by construction.
3. Make the engine read the table, keeping the hard-coded maps as the fallback **for the
   window in which the table is still empty** — one release, then delete the maps.
4. `units_editor.dart` becomes the only place a unit is defined.

**Do not bump the DB version.** `version: 1` is fixed and the legacy-guarantee pass runs on
every open **[re-verify]**; the established pattern for adding columns is DDL in
`_createSchema` plus `_ensureColumn`, used for 20+ columns already **[re-verify]**.

**Gate:** every row in `lab_units` round-trips through `convertQuantity`; one test per
dimension; min/max/target/precision become **data**, not code.

### P5 — Generalize the data model

Additive only. No existing row is deleted or renamed.

1. **`item_types(id, key, label_ar, label_en, sort_order, is_active)`** seeded with the
   **literal strings currently in `lab_sample_tests.source_type`** (`raw_material`,
   `product`) — so every existing row keeps resolving with **zero migration**. Then
   `source_type` becomes a lookup instead of a `const` list, and `intermediate`,
   `packaging`, `other` become available.
2. **One `SpecResolver` read path**: prefer the typed columns, fall back to parsing
   `chemical_reference_json` / `physical_reference_json` **[re-verify: `formula_engine.dart`
   `parseNumericRange` / `isPhysicalOutOfRange`]**. Nothing changes for existing data.
3. **`lab_item_analyses(item_type_id, item_id, analysis_id, min_value, max_value, unit)`**
   as the general table; migrate rows out of `lab_material_analyses` /
   `lab_product_analyses`.
4. Leave those two tables **read-only for one release** as a fallback path, then delete.
5. **`lab_item_physical_specs(...)`** — `lab_products` has no physical-spec table at all
   today.

**Do not merge `reference_materials` with `lab_products`.** The first holds incoming
materials with an entry code and a physical spec and is the target of the
`inspections.material_id` FK; the second holds finished products. Merging breaks the FK.

**Gate:** min/max/target/precision are data. A user can add
`Viscosity / cP / 100-250` with no code change. **Existing reports render byte-identically.**

### P6 — Quality Core

1. **Three tables**, `quality_tasks`, `quality_task_evidence`, `quality_task_events`, added
   as DDL in `_createSchema` only — `version: 1` stays fixed **[re-verify]**.
2. **`quality_*` must NOT join `syncedTables`** **[re-verify: `PLAN_V3` cited
   `database_helper.dart:566-583`]**. That list adds `remote_version`, `remote_synced_at`,
   `sync_state` and `deleted_at` to every table in it.
3. **Evidence = device-local file + descriptor row.** Bytes go to
   `<orgRoot>/evidence/<yyyy>/<mm>/<sha256>.<ext>` via a new `AppPaths.evidenceDirFor()`,
   modelled on `backupsDirFor()` **[re-verify: `app_paths.dart:105`]**. The row stores
   path + name + mime + size + sha256 + who + when. **Bytes never enter a sync payload**,
   so the 900KB `push_worker` limit and the 1MiB Firestore limit are never approached.
   `sha256` de-duplicates. A file absent from this device renders as an explicit state —
   **never a broken tap**.
4. **Wire `AuditLogger` into the unlogged write paths.** `AuditLogger.log(txn, action:,
   entityType:, entityId:, details:)` already exists and already runs inside the same
   transaction **[re-verify]**. This is connection work, not architecture. There are
   **23 unlogged `settingsUpdated` sites**: 16 in `offline_first_lab_repository.dart`
   (`:87,113,147,192,224,251,270,294,344,383,407,433,455,638,659,677`) and 7 in
   `offline_first_reference_repository.dart` (`:67,107,130,154,174,207,239`) **[agent]**.
5. **Fix the audit vocabulary before adding Quality actions.** 16 actions are declared,
   10 are used, 6 are declared-and-unused, and **4 more exist only as string literals
   written straight to `remote.writeAudit`**, bypassing the class that asserts the
   10-key payload — `INVITE_CLAIMED`, `ORG_UPDATED`, `MEMBER_REMOVED`, `MEMBER_LEFT` at
   `firestore_organization_repository.dart:81,112,228,254` **[agent]**. Twenty distinct
   strings in production. Any Quality enum must cover both paths or the drift continues.
6. **Two existing hazards:** `audit_logger.dart:106-116` **asserts loudly** if a payload
   carries any key outside the ten the rules allow — new actions go in `action` (free
   text), which is safe; and secret redaction at `:129-138` is **top-level only, not
   recursive** — do not put nested sensitive data in `details_json` **[agent]**.
7. **`quality_task_events` is the per-task timeline; `audit_logs` is the institutional
   record.** Two different scopes, both required. Do not merge them.

**Gate:** a task is created, assigned, given evidence, submitted, rejected, corrected,
verified and closed — with the whole timeline visible.

### P7 — Quality features

Twelve features, one commit each. Gate per feature: Windows · Android · old data · create ·
edit · delete (where permitted) · permissions · evidence · alerts · back-navigation.

| # | Feature | Tables | Note |
|---|---|---|---|
| 7.1 | Quality Objectives | `quality_objectives` | first consumer of Quality Core; actions **are** `quality_tasks` with `source_kind='objective'` |
| 7.2 | Equipment | `equipment`, `equipment_calibrations`, `equipment_maintenance` | calibration is **history**, not a "last calibrated" column; status derives from `next_calibration_date` + `frequency_days` |
| 7.3 | Equipment alerts | — | derived query. No flag column, no OS push |
| 7.4 | Checklists | `checklists`, `checklist_items`, `checklist_runs`, `checklist_run_items` | `daily`/`weekly`/`monthly` only — no custom scheduler in v1 |
| 7.5 | Answer types | — | `yes_no` · `numeric` · `choice` · `text` · `photo`; numeric uses `lab_units` (P4) |
| 7.6 | Reminders | `checklist_run_reminders` | per user, per cycle, vanish on completion |
| 7.7 | Failed point → action | — | a failed point writes a `quality_tasks` row with `source_kind='checklist'`. **Same kernel, no second system** |
| 7.8 | Non-Conformity | `non_conformities` | `problem` · `immediate_correction` · `root_cause` · `corrective_action` · `preventive_action`. Root cause is **one text field** — no 5-Why, no Fishbone in v1 |
| 7.9 | CAPA | — | corrective actions **are** `quality_tasks`. No parallel task system |
| 7.10 | Customer Complaints | `complaints` | joins existing data **by reference**, never by re-entry: `sample_id → inspections.id`, `product_id → lab_products.id`. Product and batch stay optional so a non-production activity can raise one |
| 7.11 | Notification Center | — | one derived-queries screen: overdue · due today · waiting verification · calibration due · open NC · open complaints. Every row deep-links to its source |
| 7.12 | Quality Dashboard | — | counters only. Charts come later, on real data |

**Navigation:** desktop sidebar gains **one** Quality entry with sub-tabs (Objectives ·
Tasks · Checklists · Equipment · NC/CAPA · Complaints · Notifications) — **not** seven
top-level items. Mobile bottom bar: `Home · Tasks · Quality · Equipment · More`.

### P8 — Launch

```bash
flutter build windows --release
flutter build apk --release
```

Both installed and exercised on real hardware.

**`README.md` is wrong and must be corrected.** It still says "Flutter Desktop", and its
Stack section lists `printing` and `qr_flutter` — **neither is in `pubspec.yaml`**
(`pdf`, `qr` and the in-house `html_pdf_exporter` are what actually exist) **[verified]**.

---

## 4) Decisions carried forward, restated against the code

- **Evidence stays device-local** (inherited from PLAN_V3 §1). Consequence: the `hasOnly`
  hole in §0.2(3) is **not inherited** by `quality_tasks`. If sync is ever added, author an
  explicit `hasOnly` — do not copy the shape of `samples`.
- **`quality.verify` is distinct from `qc.approve`.** Template the rules block on
  `firestore.rules:390-398` (`qualityChecks`) — the only block whose write permission is
  **status-dependent**, which is exactly the shape a verify transition needs **[agent]**.
- **Role grants.** `permissions.dart` **and** `firestore.rules` change in the same commit;
  `permissions_parity_test.dart` compares the two literally.

  | Role | read | write | verify | manage |
  |---|:--:|:--:|:--:|:--:|
  | admin | ✔ | ✔ | ✔ | ✔ |
  | quality_manager | ✔ | ✔ | ✔ | ✔ |
  | lab | ✔ | ✔ | | |
  | viewer | ✔ | | | |

  **Load-bearing detail:** `rolePermissions('viewer')` returns `devicesRegister`, and
  `technical: true` is the *only* thing keeping `roleIsReadOnly('viewer') == true`
  (`permissions.dart:178-179`) **[agent]**. Grant `quality.read` to viewer as
  **`technical: true`**, or viewer devices silently become read-write.
- **ScreenUtil stays, and `designSize` stays a platform decision.** With `400×860` on
  mobile, `scaleWidth` is 0.90 and `scaleHeight` 0.93 at 360×800dp, so `.w` becomes a
  fraction of a 400dp reference, `.r` lands near 1.0, and `.spMax` floors text at its
  authored size. `responsive_guard_test.dart:109` enforces that nothing re-derives the form
  factor from the window; `:204` enforces the `designSize` choice in `main.dart`.

---

## 5) Commit sequence

```
v2-baseline (tag)
  → ratchet-to-zero
  → split-shell → split-login → split-reports → split-audit
  → split-inspections → split-inspection-detail
  → split-reference-host → split-products
  → split-lab-host → split-analyses → split-inventory → split-test-history
  → split-dashboard → split-run-test → split-inspection-form
  → split-settings
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

One commit per unit. No amend, no force-push, never ten features in one commit.

---

## 6) Risk register

| Risk | Mitigation |
|---|---|
| Changing `designSize` reinterprets every `.w`/`.h`/`.spMax` call site, and `flutter analyze` cannot see it | The per-unit **visual pass on both platforms** is the gate, not the analyzer |
| `responsive_guard_test.dart:137` accepts a stub sibling | New rule (e) (non-trivial, no `TODO`) + a parity test per unit |
| 16 desktop copies drift from current behaviour | Desktop variants are **verbatim moves**, reviewed as moves; parity tests hold both sides to an independently written payload |
| Mobile is unreachable mid-phase if the shell is not split first | P2 order puts `app_shell` at #1 |
| `settings_screen` is the one unit that cannot move until contracts exist | P1 lands the three contracts first, so P2's last unit is unblocked |
| A future DB version bump is needed and untested | P4/P5/P6 add DDL only, per the established pattern. Do not bump the version in this plan |
| The four synced Firestore blocks accept arbitrary columns | New synced collections author explicit `hasOnly`. Retrofitting `samples` would reject today's pushes — backlog, not this plan |

---

## 7) Definition of done

1. Every existing Material Lab function still works; the P3 matrix is fully green.
2. `flutter analyze` = 0 and `flutter test` green, **including** `repository_boundary_test`
   (with **no** ratchet), `firebase_isolation_test`, `permissions_parity_test`,
   `responsive_guard_test`, `presentation_split_test`.
3. One repository builds both: `flutter build windows --release` **and**
   `flutter build apk --release`.
4. The UI adapts with **no duplicated business logic** — one `saveSample()`, two layouts.
5. Desktop visuals are unchanged by the split.
6. Form factor is a platform decision, enforced by a test.
7. Every `desktop/` unit has a `mobile/` sibling, both depend on domain contracts only, and
   both hold the same payload.
8. Every unit in `lab_units` is convertible **and actually used** by `convertQuantity`.
9. `Material` / `Product` / any item is usable with no single-industry assumption.
10. Every Quality action has Owner · Due Date · Evidence · Verification · History.
11. Every new feature builds on what exists — no parallel system.