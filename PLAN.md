# Material Lab — Flutter Desktop Full Rewrite Plan

> الوثيقة المرجعية الشاملة لإعادة بناء **مختبر المواد الخام / Material Lab** من تطبيق
> (PySide6 + Qt WebEngine + Vue) إلى **Flutter Desktop** بنفس معمارية مشروع
> `morattab` (offline-first + sqflite + flutter_bloc + get_it + go_router + Firebase).

---

## 1) Executive Snapshot

- **المصدر:** `row material lab_vue` — تطبيق سطح مكتب Windows (PySide6) بواجهة Vue داخل WebEngine.
- **الهدف:** `row material flutter` — تطبيق Flutter Desktop (Windows) مكافئ وظيفياً 1:1.
- **لا Python إطلاقاً:** كل المنطق التجاري يُنقل إلى Dart. قاعدة البيانات SQLite محلياً عبر `sqflite_common_ffi`.
- **بنية البيانات:** offline-first مثل morattab تماماً؛ طبقة الـ repositories مصممة بحيث يُضاف لاحقاً
  **Django REST API** للمزامنة دون إعادة كتابة.
- **المصادقة:** حساب محلي PBKDF2 + تسجيل دخول **Google عبر Firebase** (Firebase يُفعَّل لاحقاً،
  والتطبيق يعمل كاملاً دون Firebase).
- **اللغات:** عربي (RTL) / إنجليزي (LTR) — كل النصوص ثنائية اللغة.
- **الثيم:** Light / Dark / System (مواد 3) بخط **Cairo**.
- **أهداف عامة:**
  - محرك صيغ موحّد (Formula Engine) منقول من Python و JS.
  - تقارير PDF وملصقات QR بنفس الخصائص والمخرجات.
  - نسخ احتياطي/استعادة DB بنفس قواعد الأمان.
  - معالج ترحيل في v1 يستورد `app_data/material_lab.db` القديم.

---

## 2) Architecture Summary (morattab-mirror)

```
lib/
├── main.dart                     # Entry: error handlers + init sequence
├── app/app.dart                  # MaterialApp.router, theme, locale, ScreenUtilInit
├── router/app_router.dart        # GoRouter + auth gate
├── core/
│   ├── di.dart                   # GetIt registrations
│   ├── database/database_helper.dart, result_wrapper.dart
│   ├── constants/app_strings.dart, app_colors.dart, app_assets.dart
│   ├── security/password_hash.dart, seal_codec.dart, local_secret.dart, qr_builder.dart
│   ├── services/formula_engine.dart, unit_converter.dart, aggregation.dart,
│   │            report_renderer.dart, label_renderer.dart, batch_label.dart,
│   │            aggregate_report.dart, excel_exporter.dart, qr_decrypt.dart,
│   │            seed_service.dart, backup_manager.dart
│   ├── settings/app_preferences.dart
│   └── utils/app_dates.dart, app_format.dart, validators.dart, app_exceptions.dart
├── design_system/
│   ├── tokens/ (app_colors.dart, app_text_theme.dart, app_spacing.dart, app_font_weights.dart)
│   ├── widgets/ (app_button, app_card, app_icon, app_top_app_bar, app_skeleton,
│   │             app_empty_state, app_export_buttons, app_status_badge, ...)
│   ├── cards/ (app_summary_card, app_menu_card, app_expandable_card)
│   ├── dialogs/ (app_alert_dialog, app_confirmation_dialog)
│   ├── animations/ (app_stagger, app_page_transitions, app_entrance, app_shimmer, ...)
│   └── feedback/app_feedback.dart
└── features/
    ├── auth/          (data: auth_repo, token_storage, user_repo · domain: user · presentation: setup/login + cubit)
    ├── reference/     (data: reference_repo, seed_repo · domain: reference_material, parameter, lab_unit · presentation: materials editor)
    ├── dashboard/     (data: dashboard_repo · presentation: dashboard screen + cubit)
    ├── inspections/   (data: inspection_repo · domain: inspection, decision, inspection_rules · presentation: list/detail/create + sheets + cubit)
    ├── reports/       (data: report_repo · presentation: preview + d/m/y screens + cubit + widgets)
    ├── lab/           (data: lab_repo, lab_activity_repo · domain: 6 entities · presentation: lab shell + 13 panels/modals + cubits)
    ├── settings/      (data: settings_repo · presentation: 5 panels + users + cubit)
    ├── backup/        (backup_manager)
    ├── migration/     (presentation: import wizard + cubit)
    └── shared/        (widgets: paginated table, status pill, kpi card, busy overlay)
```

**مبدأ التصميم:** "Backend/بيزنس ثابت، واجهة حديثة" — النقل 1:1 للقواعد والتحقق وبنية الجداول،
باستبدال QWebChannel باستهلاك repositories مباشرة في Dart.

---

## 3) Dependencies (pubspec.yaml)

| الفئة | الحزم |
|---|---|
| DB | `sqflite`, `sqflite_common_ffi`, `path` |
| Auth | `firebase_core`, `firebase_auth`, `google_sign_in`, `flutter_secure_storage` |
| State/DI | `flutter_bloc`, `equatable`, `get_it` |
| UI | `flutter_screenutil`, `data_table_2`, `font_awesome_flutter`, `fl_chart` |
| PDF/Excel/QR | `pdf`, `printing`, `syncfusion_flutter_xlsio`, `excel`, `qr_flutter`, `qr` |
| Crypto | `pointycastle`, `crypto` |
| Backup/File | `file_picker`, `path_provider`, `permission_handler` |
| Navigation | `go_router` |
| Network/Share | `dio`, `connectivity_plus`, `url_launcher`, `share_plus` |
| Firebase | `firebase_crashlytics`, `firebase_analytics` |
| Utils | `intl`, `shared_preferences`, `package_info_plus`, `dart_jsonwebtoken`, `device_info_plus`, `workmanager` |

> Dart SDK: `^3.12.2` (Flutter 3.44.8 مثبت). جميع الحزم بنفس إصدارات مشروع morattab حيثما أمكن.

---

## 4) SQLite Schema (port 1:1)

قاعدة البيانات الجديدة تحاكي `plans/current_schema.sql` تماماً (20 جدول + 15 فهرس + WAL).
الكيان-KEY كالتالي (ملخص):

| الجدول | الأعمدة الأساسية |
|---|---|
| `users` | id, username UNIQUE, full_name, password_hash, role, is_active, created_at |
| `reference_materials` | id, material_name UNIQUE, material_code, physical_reference_json, chemical_reference_json, source_row, imported_at, active |
| `parameters` | id, parameter_name UNIQUE, unit, parameter_type |
| `inspections` | id, entry_code UNIQUE, material_id FK, material_name, material_code, inspection_date, supplier, truck_number, quantity, sample_taken_by, specialist_name, physical_results_json, chemical_results_json, physical_reference_json, chemical_reference_json, decision_status, decision_reason, follow_up_note, rejected_quantity, report_html, snapshot_json, sample_names_json, decision_version, created_by, created_by_name, last_pdf_path, created_at, updated_at, expiry_date |
| `inspection_status_history` | id, inspection_id FK CASCADE, version, old_status, new_status, change_reason, follow_up_note, rejected_quantity, changed_by, changed_by_name, changed_at |
| `settings` | key PK, value |
| `lab_products` | id, name UNIQUE, category, description, created_by, created_at, active |
| `lab_product_analyses` | id, product_id FK, analysis_id FK, min_value REAL, max_value REAL, unit, UNIQUE(product_id, analysis_id) |
| `lab_analyses` | id, name UNIQUE, unit, description, dynamic_fields_json, formula_json, created_at, active |
| `lab_analysis_items` | id, analysis_id FK, inventory_id FK, qty_per_sample, unit, UNIQUE(analysis_id, inventory_id) |
| `lab_inventory` | id, name UNIQUE, category('liquid','powder'), unit, current_qty, min_qty, description, created_by, created_at, updated_at |
| `lab_constants` | id, name UNIQUE, symbol, value_text, unit, unit_dim, is_expression, expression, min_value, max_value, precision, description, is_global, created_at, updated_at |
| `lab_units` | id, symbol UNIQUE, name, dimension, is_active, created_at |
| `lab_sample_tests` | id, analysis_id FK, source_type, source_ref_id, source_name, sample_name, result_text, dynamic_values_json, entry_code, worksheet_row_id, tested_by, tested_at, created_by, updated_by, updated_at |
| `lab_worksheet` | id, source_type, source_ref_id, source_name, sample_number, entry_code, created_by, created_at, updated_by, updated_at, status, void_reason, voided_by, voided_at |
| `lab_consumption_log` | id, sample_test_id, inventory_id, qty_used, requested_qty, applied_qty, shortfall_qty, event_type, reversal_of_log_id, created_at |
| `lab_stock_adjustments` | id, inventory_id, old_qty, new_qty, reason, adjusted_by, adjusted_at |
| `lab_field_chemical_links` | id, analysis_id FK CASCADE, dynamic_field, inventory_id FK, unit, created_at, UNIQUE(analysis_id, dynamic_field) |
| `lab_material_analyses` | id, material_id FK, analysis_id FK, is_default |
| `lab_material_analyses` (admin ranges) | id, material_id, analysis_id, min_value, max_value, unit |

- المفاتيح: `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000`.
- الترقيات: إنشاء إضافي للأعمدة/الجداول (نمط `_ensure_table/_ensure_column`) في `migrations.dart`.

---

## 5) Security Layer (byte-compatible ports)

### 5.1 Password Hashing (من core/utils.py + core/domain/rules.py)

```
ALGO_LEGACY = "pbkdf2_sha256"         # بدون pepper
ALGO_V2     = "pbkdf2_sha256_v2"      # + pepper
ALGO_DEV    = "pbkdf2_sha256_v2_dev"  # + pepper × 2 rounds
ROUNDS      = 390_000
DEV_ROUNDS  = 780_000
```

- الصيغة: `algo$rounds$salt_hex(16 bytes)$digest_hex`
- `material = utf8(password) + pepper`
- خوارزمية: PBKDF2-HMAC-SHA256 عبر `pointycastle`، تُنفَّذ في **Isolate** (780k iteration ثقيلة).
- `verifyPassword` تدعم: الصيغة الرباعية + legacy fallback `SHA256(password)` المعرّف بـ64 hex.

### 5.2 Seal/Unseal (تشفير QR والـ expiry) — من core/utils.py:654-688

```
enc1:base64url_nopad(nonce[12] + tag[16] + ciphertext)
cipher = XOR(HMAC-SHA256(key, nonce + counter4BE))  # block كل 32 بايت
tag    = HMAC-SHA256(key, nonce + cipher)[:16]
```

### 5.3 Local Secret — من load_or_create_local_secret

- مسار ويندوز: `%APPDATA%/MaterialLab/.secret`
- قيمة: `base64url_nopad` لـ32 byte عشوائية.
- نفس منطق "read أو create" بالضبط.

### 5.4 QR Payload — من build_qr_payload_text

- JSON مضغوط بمفاتيح: `ec, m, mc, d, s, t, q, by, sn, dec, ph, ch`
- `ensure_ascii: false`, فواصل `,` و `:` بلا مسافات.
- تقليم عند >2400 بايت + لاحقة `...[truncated]`.
- عَرَض: `qr_flutter` (EC=M, version auto).

> التحقق: `qr_decrypt.py` القديم يجب أن يفك التشفير الناتج من Dart — معيار قبول.

---

## 6) Formula Engine (port 1:1 من lab.py + 56_lab_formula_engine.js)

- الثوابت: `F_PROT=6.25, F_WHEAT=5.70, F_DAIRY=6.38, K_LIPID=1.4007, D_WATER=1.0, MV_DIL=1.0, C_NACL=58.44, C_NAOH=40.0, C_HCL=36.46`
- تحويل وحدات: `L↔mL (×0.001)، kg↔g (×0.001), pc`.
- Tokenizer: أرقام، identifiers، `+-*/^()`, فواصل، `%`, `{}`.
- Parser: recursive descent بالأسبقية `+-` < `*/` < `^` < `-` (unary).
- دوال: `abs, round, min, max, sqrt, pow, log, log10, exp`.
- متغيرات: قيم الحقول الديناميكية + الثوابت.
- النتيجة: تُحسب بالوحدة الأساسية (kg/L) ثم تُحوَّل للوحدة الهدف المخزنة في DB.

---

## 7) Reports (Dart pdf بدل Jinja2)

| التقرير | الملف المكتوب |
|---|---|
| شهادة فحص مفردة | `core/services/report_renderer.dart` `buildInspectionPdf()` |
| يومي / شهري / سنوي | `core/services/aggregate_report.dart` |
| تقرير متابعة | `core/services/aggregate_report.dart` `buildFollowUpReportPdf()` |
| تقرير فحوصات المختبر | `core/services/aggregate_report.dart` `buildLabReportPdf()` |
| ملصق مفرد (PNG/PDF) | `core/services/label_renderer.dart` |
| ملصقات دفعة (حتى 100) | `core/services/batch_label.dart` |

- PNG: الملصق يُرسم كـ `Widget` داخل `RepaintBoundary` ثم `toImage(pixelRatio: 4)` — بلا PyMuPDF.
- نافذة الشيفت اليومي: 8:00 ص → 8:00 ص اليوم التالي.
- QR داخل الملصق من نفس الـ payload المشفَّر.

---

## 8) Seed & Excel Import

- عند أول تشغيل (و`reference_materials` فارغة): قراءة `assets/Reference.xlsx` و `assets/units.xlsx`
  عبر حزمة `excel`، التحقق من الأعمدة المطلوبة، ثم upsert + تعيين `reference_seed_done='1'`.
- إعادة استيراد جداول المواد/الوحدات من ملف `.db` خارجي عبر `file_picker` وقراءة للقراءة فقط.

---

## 9) Backup / Restore

1. Checkpoint: `PRAGMA wal_checkpoint(TRUNCATE)`.
2. نسخة متسقة: `VACUUM INTO '<file>'`.
3. تحقق `PRAGMA integrity_check` = `ok`.
4. الاحتفاظ بآخر 5 نسخ (تنظيف تلقائي عند الإقلاع).
5. الاستعادة: فحص integrity + الجداول المطلوبة (`users, reference_materials, inspections, settings`)
   + نسخة أمان تلقائية قبل الاستبدال + preflight migration + إعادة فتح DB + إنهاء الجلسة.
6. مستقبلاً (اختياري): `CloudBackupDataSource` → Google Drive عبر `google_sign_in` + `dio` (scope `drive.appdata`).

---

## 10) Migration (v1)

- معالج `import_wizard_screen.dart`: اختيار `app_data/material_lab.db` → ملخص
  (عدد المستخدمين/الفحوصات/المواد/سجلات المختبر) → نسخ 1:1 كامل لكل الجداول في transaction واحدة:
  `users, reference_materials, parameters, inspections, inspection_status_history, settings, lab_*`.
- كلمات مرور المستخدمين تُنقل كما هي (يظل `verify_password` القديم يعمل).
- هاش القديم يُرقّى تلقائياً عند نجاح التحقق (مثل `password_hash_needs_upgrade`).

---

## 11) Roles & Permissions

`developer / admin / labUser / viewer`
- canEdit = ليس viewer.
- canManageSettings = admin/developer.
- canRunLabs = developer/admin/labUser.
- developer يعفي من `usage_expiry_date` (المشفر seal) + كشف العبث بالساعة (>12h فرق).

---

## 12) Entry Code

`generateEntryCode(materialCode, date)` → `{MaterialCode}-{YYYYMMDD}-{seq:03d}`
بنفس استعلام `MAX(CAST(SUBSTR(entry_code, ?)))`.

---

## 13) Google Sign-In + Firebase (ويندوز)

- `google_sign_in` يدعم Windows عبر `google_sign_in_windows` (endorsed).
- Flow: `GoogleSignIn.signIn()` → `idToken` → `FirebaseAuth.signInWithCredential(GoogleAuthProvider...)` → UID = namespace key للـ DB.
- بلا ملفات Firebase: التطبيق يعمل **local mode** (تخطي شاشة Google) مع حسابات PBKDF2 المحلية.
- `ensureFirebaseReady()` كلها داخل try/catch.

---

## 14) Startup Sequence

```
main() → setupFlutterErrorHandler + setupPlatformErrorHandler
→ WidgetsFlutterBinding.ensureInitialized()
→ setupLocator() (GetIt)
→ load preferences → SettingsCubit
→ runApp(MaterialLabApp(router, settingsCubit))
→ _runPostStartupTasks():
    _bindAccountDatabase()        # UID namespace
    DatabaseHelper.database       # create/migrate schema
    SeedService.ensureInitialImport()
    BackupManager.autoBackupIfNeeded()
```

---

## 15) Design Tokens (من web/styles.css)

- `--bg:#f3f6fb, --surface:#fff, --primary:#0284c7, --accent:#6366f1, --success:#10b981,
  --warning:#f59e0b, --partial:#f97316, --danger:#ef4444, --info:#3b82f6, --text:#0f172a,
  --muted:#64748b, --line:#d9e1ec`.
- Dark: `--bg:#070b14, --primary:#38bdf8` + بدائل pastel للنجاح/تحذير/جزئي/خطر.
- RTL عبر `Directionality` في builder الـ MaterialApp.router (نفس نمط morattab).

---

## 16) Phases & LOC Estimates

| المرحلة | المحتوى | LOC تقديري |
|---|---|---|
| 1 | Foundation + Auth + Dashboard + Design system | ~5,400 |
| 2 | Reference + Inspections + Reports | ~7,600 |
| 3 | Lab module (formula engine + screens) | ~7,500 |
| 4 | Settings + Backup + Migration + Polish | ~6,400 |
| **الإجمالي** | | **~27,000** |

---

## 17) Tests

- Unit: password_hash (قيم معروفة من Python)، seal/unseal (تتبادل مع qr_decrypt.py)،
  formula_engine، inspection_rules، aggregation (حدود شيفت 8:00)، entry_code، seed_service.
- Widget: login/setup، نموذج الفحص، لوحة المختبر.
- Integration: دورة فحص كاملة (إنشاء→نتائج→قرار→سجل→PDF→ملصق)، دورة مختبر
  (مخزون→تحليل→اختبار→استهلاك→ورقة عمل→إلغاء/عكس)، backup↔restore.

---

## 18) Build & Packaging

- Dev: `flutter run -d windows`
- Release: `flutter build windows --release` → `build/windows/x64/runner/Release/material_lab.exe`
- توزيع: Inno Setup / MSIX تضم exe + DLLs + assets.

---

# PART II — Business-Logic Parity Audit & Fix Plan (فحص عميق للمنطق التجاري)

> الملخص: تمت مقارنة منطق الأعمال في المشروع المرجعي `row material lab_vue`
> (Python `core/services/*` + `core/utils.py` + Vue `web/src`/`web/app.legacy.js`)
> مع تطبيق Flutter الحالي سطراً بسطر. النتيجة: النواة مُنقولة بنسبة كبيرة
> (Security Layer، Schema، Formula Engine، Reports، Dashboard، Seed، Backup)
> لكن يوجد **مشكلة حاجزة: الشيفرة لا تُترجم حالياً**، إضافة إلى **9 انحرافات مؤكدة
> 1:1 في قواعد الأعمال**، وفراغ إلزامي في تخزين `report_html`.
> هذا الجزء يوثّق من أين جاء كل استنتاج (file:line)، لماذا يؤثر سلوكياً،
> وكيف يُصلَح بالضبط، وترتيب التنفيذ، وأدلة التحقق.

---

## 1) Methodology — منهجية الفحص

1. **قراءة العمود الفقري المرجعي** `core/services/*.py` (inspection, auth, settings,
   aggregation, report, backup, lab, reference) + `core/utils.py` + `core/controller.py`.
2. **قراءة كل Dart بموازاة كل بايثون** للدوال المنقولة ومعايرة القيم حرفياً
   (الثوابت، الحدود، الرسائل، الأرقام).
3. تشغيل **`flutter analyze`** (فقط-قراءة) → نتيجة **36 issue**: 34 error + warning + info
   ⇒ المشروع لا يُبني حالياً ويجب إصلاح البنية أولاً قبل أي تحقق.
4. **Usage قاعدة:** Python هو مصدر الحقيقة `source of truth`؛ أي اختلاف في
   سلوك الحقول/الحسابات/الرسائل/التخزين يُصنَّف `DIVERGENCE` ويُصلَح 1:1.
5. بعض الاختلافات اجتهاد مسموح (مرونة `const`، المزامنة اليومية، اختيار الشعار)
   وُضعت خارج النطاق أو في قسم **مؤجل** بموافقة المستخدم.

---

## 2) PHASE 0 — Build blockers (حاجز البناء: يجب إصلاحه أولاً)

المشروع لا يُترجم حالياً. `flutter analyze` يذكر الأخطاء التالية:

| # | الملف | السطر | الخطأ |
|---|---|---|---|
| 1 | `lib/features/inspections/presentation/inspections_screen.dart` | 190 | `const_eval_method_invocation` — استدعاء `AppText.t(...)` داخل تعبير `const` (`AppEmptyState(title:)`) |
| 2 | نفسه | 202–207 | `const` على `DataColumn(label: Text(AppText.t(...)))` — نفس السبب |
| 3 | `lib/features/lab/presentation/run_test_tab.dart` | 136,156,161,162,176,197,222,232 | `AppText.t(...)` داخل `const InputDecoration` / `const items` |
| 4 | `lib/features/lab/presentation/test_history_tab.dart` | 36,44,54–60,93–95 | `AppText` غير معرّف (`undefined_identifier`) — import مفقود |
| 5 | `lib/features/inspections/domain/inspection_rules.dart` | 1 | `unused_import` (warning) — يُزاد أثناء إعادة كتابة القاعدة في Phase 1 |

### الإصلاح بدقة
1. **`inspections_screen.dart:188`** — أزل `const` من وسيط `AppEmptyState(title: ...)`؛
   **`inspections_screen.dart:201`** — حوّل `columns: const [...]` إلى `columns: [...]`
   (أبقِ `const` على `DataColumn(label: Text(''))` الأخير وحده).
2. **`run_test_tab.dart`** — أزل `const` عن مواضع `InputDecoration`/`DropdownMenuItem`
   التي تحتوي `AppText.t(...)` فقط؛ ابقِ `const` حيث لا استدعاء دالة.
3. **`test_history_tab.dart`** — أضف `import '../../../core/constants/app_strings.dart';`
   (يُعرّف `AppText` وباقي الأعضاء المستخدمة في الـ switch-expression:92–96).
4. تحقق: `flutter analyze` → 0 errors (يُسمح بـ warnings غير مؤثرة).

> **سبب الجدية:** لا يمكن `flutter test` أو `flutter run` إلا بعد هذه الخطوة.
> لذلك هي مرافِق إلزامي لأي تحقق لاحق وليست "تحسيناً تجميلياً".

---

## 3) PHASE 1 — Confirmed Business-Logic Divergences (الانحرافات المؤكدة)

الجدول أدناه يُلخّص القاعدة ← المرجع → الحالي ← السياق، ثم تُشرح كل قاعدة
بعمق مع مواصفة الإصلاح الدقيقة.

| # | القاعدة | Python (مصدر الحقيقة) | Dart (الحالي) | الأثر |
|---|---|---|---|---|
| 1 | تحقق القرار | `inspection.py:52-93` | `inspection_rules.dart:25-51` | قبول/رفض غير صحيح؛ `CONDITIONAL` يفشل خطأً |
| 2 | تطبيع القرار | `inspection.py:94-99` | `inspection_rules.dart:9-23` | بقايا بيانات في قيود غير مطابقة |
| 3 | تقريب النسب 1 عشري | `aggregation.py:83` + `report.py` (19 موضع) | `aggregation.dart:72` + `report_builder.dart` (16 موضع) | أرقام تقارير مغلوطة (83% بدل 83.3%) |
| 4 | سعة QR / الاختزال | `utils.py:548-597` | `qr_render.dart:14-22` | فشل تصدير ملصقات كبيرة بدل نجاحها بالاختزال |
| 5 | عبث الترخيص (seal) | `settings.py:118-124` | `auth_repo.dart:138-141` | عبث بـ DB يفتح التطبيق بدل أن يقفله |
| 6 | قيم الإعدادات الافتراضية | `settings.py:32-45` | `settings_repo.dart:40-58` | مفاتيح أمان غير موجودة + `''` بدل `'0'` |
| 7 | حذف مستخدم مرتبط بسجلات | `auth.py:139-155` | `settings_repo.dart:161-170` | فقدان سلامة التدقيق (referential integrity) |
| 8 | نسخ احتياطي + PRAGMAs | `backup.py` + `sqlite_db.py` | `backup_manager.dart:210,238` + `database_helper.dart` | سلوك Checkpoint مختلف + خسائر أداء |
| 9 | نضارة `snapshot_json` عند تعديل البيانات | `inspection.py:843-852` | `inspection_repo.dart:393-452` | snapshot قديم مخالف للبيانات المخزنة |

---

### 3.1 قاعدة 1 — التحقق من حقول القرار (`validateDecisionFields`)

#### ما يفعل Python الآن (مصدر الحقيقة، `inspection.py:52-93`)
1. `decision_status` يجب أن يكون ضمن {APPROVED, CONDITIONAL_APPROVAL, PARTIAL_REJECTION, FULL_REJECTION} وإلا رفض.
2. **`decision_reason` مطلوب لجميع الحالات غير النهائية المرفوضة**:
   `CONDITIONAL_APPROVAL`, `PARTIAL_REJECTION`, `FULL_REJECTION` (رسالة عربية:
   `سبب القرار مطلوب (يجب ادخال البيانات)`).
3. `follow_up_note` مطلوب فقط في `CONDITIONAL_APPROVAL`.
4. `rejected_quantity`:
   - في `PARTIAL_REJECTION`: **مطلوب** + رقم غير سالب وفق `validate_non_negative_numeric_text`
     (regex `\d+(\.\d+)?`، `allow_empty=False`، max 10) + **لا يتجاوز كمية الشحنة** (`_safe_float(rejected) <= _safe_float(quantity)`).
   - في أي حالة أخرى **عندما لا يكون فارغاً**: نفس التحقق الرقمي فقط (فرع `elif`).

#### ما يفعله Dart الآن (`inspection_rules.dart:25-51`)
```dart
switch (status) {
  case 'CONDITIONAL_APPROVAL':
    if (followUp.isEmpty) { throw ...; }   // لا break/return
  case 'PARTIAL_REJECTION':
    if (rejectedQty.isEmpty) { throw ...; } // يسقط من case السابق!
  case 'FULL_REJECTION':
    if (reason.isEmpty) { throw ...; }      // يسقط من case السابق!
}
```
- **لا `decision_reason`-required إطلاقاً لـ CONDITIONAL / PARTIAL.**
- **لا تحقق رقمي إطلاقاً على `rejected_quantity`** ولا شرط `<= quantity`.
- الـ switch **بدون break/return** ⇒ سلوك cascade: في `CONDITIONAL_APPROVAL` بقيمة
  follow_up غير فارغة، تسقط الحالة للـ `PARTIAL_REJECTION` فتُرفض إن كانت الكمية فارغة،
  ثم قد تسقط للـ `FULL_REJECTION` فتُرفض إن نُقل السبب. النتيجة: **فحص CONDITIONAL
  صحيح قد يُرفض خطأً**. (المحلّل Dart يقبلها بلا تحذير، لذا العيب سلوكي وليس ترجمة.)

#### مواصفة الإصلاح (تطابق Python بالضبط)
```dart
void validateDecisionFields(Map<String, dynamic> d) {
  final status = '${d['decision_status'] ?? ''}';
  if (!isDecisionStatus(status)) throw const ValidationError('Unsupported decision status.');
  final reason = '${d['decision_reason'] ?? ''}'.trim();
  final followUp = '${d['follow_up_note'] ?? ''}'.trim();
  final rejectedQty = '${d['rejected_quantity'] ?? ''}'.trim();
  final notApproved = status == 'CONDITIONAL_APPROVAL' ||
      status == 'PARTIAL_REJECTION' || status == 'FULL_REJECTION';
  if (notApproved && reason.isEmpty) {
    throw const ValidationError('سبب القرار مطلوب (يجب ادخال البيانات)');
  }
  if (status == 'CONDITIONAL_APPROVAL' && followUp.isEmpty) {
    throw const ValidationError('ملاحظة المتابعة مطلوبة في القبول المبدئي.');
  }
  if (status == 'PARTIAL_REJECTION') {
    if (rejectedQty.isEmpty) {
      throw const ValidationError('الكمية المرفوضة مطلوبة للرفض الجزئي.');
    }
    validateNonNegativeNumericText(rejectedQty, 'Rejected quantity',
        allowEmpty: false, maxLength: rejectedQuantityMaxLength);
    final quantity = '${d['quantity'] ?? ''}'.trim();
    if (quantity.isNotEmpty) {
      final rj = safeFloat(rejectedQty) ?? 0;
      final q = safeFloat(quantity) ?? 0;
      if (rj > q) {
        throw const ValidationError('الكمية المرفوضة لا يمكن أن تتجاوز كمية الشحنة.');
      }
    }
  } else if (rejectedQty.isNotEmpty) {
    validateNonNegativeNumericText(rejectedQty, 'Rejected quantity',
        allowEmpty: false, maxLength: rejectedQuantityMaxLength);
  }
}
```
- حافظ على الصيغ ثنائية اللغة (`ar | en`) في رسائل UI لكن بنفس الشروط العربية.
- **لا switch cascade:** استخدم ifs مستقلين (كما أعلاه) أو cases مزوّدة بـ `break/return`.

---

### 3.2 قاعدة 2 — تطبيع حقول القرار (`normalizeDecisionFields`)

#### Python (`inspection.py:94-99`)
- `if status != "CONDITIONAL_APPROVAL": payload["follow_up_note"] = ""`
- `if status != "PARTIAL_REJECTION": payload["rejected_quantity"] = ""`
- **`decision_reason` لا يُمسح أبداً.**

#### Dart الآن (`inspection_rules.dart:17-21`)
```dart
if (decisionStatus == 'APPROVED') {
  normalized['decision_reason'] = '';
  normalized['follow_up_note'] = '';
  normalized['rejected_quantity'] = '';
}
```
يُمسح الكل فقط في APPROVED ⇒ عند `FULL_REJECTION` تتبقى `follow_up_note` و
`rejected_quantity` كما أدخلها المستخدم، وعند `CONDITIONAL` تتبقى `rejected_quantity`.

#### الإصلاح
```dart
if (decisionStatus != 'CONDITIONAL_APPROVAL') normalized['follow_up_note'] = '';
if (decisionStatus != 'PARTIAL_REJECTION') normalized['rejected_quantity'] = '';
// decision_reason يبقى كما هو دائماً
```
> ملاحظة: يُستدعى التطبيع قبل التحقق في كل من `create` (`inspection_repo.dart:171`)
> و `updateDecision` (`inspection_repo.dart:342`) — فلا يكفي إصلاح الدالة،
> بل إعادة خلط القيم الترتيبية لتطابق Python (تطبيع → ثم تحقق).

---

### 3.3 قاعدة 3 — تقريب النسب (عشرية واحدة)

#### Python — مصدر الحقيقة
```python
round((accepted_total_count / len(inspections)) * 100, 1)   # aggregation.py:83
round(((rejected_count + partial_count) / len(inspections)) * 100, 1)  # report.py:518
```
كل حساب نسبة في `aggregation.py` و `report.py` يستخدم `round(..., 1)`.
مثال: 5 من 6 مقبول = **83.3** (وليس 83).

#### Dart الآن
`.roundToDouble()` ≈ `round() → int`
- `lib/core/services/aggregation.dart:72`
- `lib/features/reports/data/report_builder.dart`: 448, 501, 504, 546, 615, 686, 688, 770, 773, 819, 869, 872, 896, 899, 987, 994.

#### الإصلاح
أنشئ أداة في `app_format.dart`:
```dart
double roundPct(num x) => double.parse((x).toStringAsFixed(1));
```
واستبدل كل `.roundToDouble()` في المواضع أعلاه بـ `roundPct(...)`.
تأكد من أن المتغيرات تُمرَّر كنسبة عشرية (`0.8333`) لا كنسبة صحيحة (`83`).

---

### 3.4 قاعدة 4 — سعة QR والاختزال عند الامتلاء

#### Python (`utils.py:548-597`) — خوارزمية دقيقة
1. `payload_text` فارغ → `("", "QR payload is empty.")`.
2. `qrcode.QRCode(version=None, error_correction=M, box_size=8, border=3)` + `make(fit=True)`.
3. إذا `qr_code.version > 40` (تجاوز السعة):
   - إن لم نكن في محاولة مختزلة: خذ `payload.encode('utf-8')[:2380]` ثم
     `decode('utf-8', errors='ignore')` + `"..."[truncated]"` (ليصير المجموع 2400)
     وأعد المحاولة بـ `is_truncated=True`.
   - وإن كنا مختزلين أيضاً: أرجِع خطأ `Data exceeds QR code capacity`.
4. عند النجاح: `data:image/png;base64,<png>` و warning إن كان مختزلاً:
   `"تحذير: تم اختزال محتوى الباركود لتناسب الحد الأقصى | Warning: QR content was truncated."`

#### Dart الآن (`qr_render.dart:14-22`)
```dart
try { code = QrCode.fromData(data: payloadText, errorCorrectLevel: QrErrorCorrectLevel.M); }
catch (_) { throw const AppError('QR payload exceeds capacity.'); }
```
**لا اختزال، لا warning، لا فحص version** — الملصقات الكبيرة تفشل بدل أن تُختزل.

#### الإصلاح
- أضف:
  ```dart
  ({String dataUri, String warning}) generateQrDataUri(String payloadText) { ... }
  ```
  تحاكي الخوارزمية أعلاه: ترجمة UTF-8، إن نسخة الـ QR (moduleCount) تجاوز حد
  version 40 (~177x177 module) فتكرر مع `utf8.encode(payload)[:2380]` + لاحقة
  `...[truncated]`؛ تُرجع `data:image/png;base64,` + الـ PNG + warning ثنائي اللغة.
- احتفظ بـ `qrPngBytes` raw للـ PDF/`pdf_renderer` لكن أعد استخدام نفس منطق
  الاختزال قبل التشفير.
- **معيار قبول:** `qr_decrypt.py` القديم يفك التشفير الناتج من Dart، والـ warning
  يظهر ضمن سياق التقرير عند التصدير.

---

### 3.5 قاعدة 5 — عبث شيفرة الترخيص (seal → قفل فوري)

#### Python (`settings.py:106-142`)
- `get_usage_expiry_date()` يفتح الـ `usage_expiry_date` المشفّر (مقدمة `enc1:`).
- **إذا كان الـ seal غير صالح (invalid) ⇒ "someone tampered" ⇒ يُرجع تاريخ أمس**
  (`date.today() - 1`) فيُفعل حظر انتهاء الصلاحية في `controller.login` (`controller.py:988-991`).

#### Dart الآن (`auth_repo.dart:138-141`)
```dart
final (plain, ok) = unsealText(sealed, secretKey);
if (!ok) return;   // ← عبث = يُسمح بالدخول!  (خطأ)
```
العبث المباشر بقاعدة البيانات يفتح التطبيق بدل أن يقفله.

#### الإصلاح
```dart
final (plain, ok) = unsealText(sealed, secretKey);
if (!ok) { // seal تالف / عبث
  _currentUser = null;
  throw const AuthorizationError(
      'انتهت صلاحية استخدام النظام. يرجى الاتصال بالمطور.');
}
final expiry = DateTime.tryParse(plain.trim());
if (expiry != null && DateTime.now().isAfter(expiry)) { /* block */ }
```
- المطابقة مع `settings.py`: أي `unseal` فاشل = أمس = منتهي. أي نص غير تاريخ = منتهي.
- **ملاحظة مؤجلة:** كشف فارق الساعة > 12h المذكور في وثيقة الـ Plan الأصلية لا وجود له
  في Python فعلياً (فقط علامات `security_*` تُزوع). لا نضيفه الآن.

---

### 3.6 قاعدة 6 — قيم الإعدادات الافتراضية

#### Python (`settings.py:32-45`) — defaults كاملة
| المفتاح | القيمة |
|---|---|
| `pdf_export_dir` | `str(paths.default_pdf_dir)` |
| `export_root_path` | `str(paths.export_dir)` |
| `whatsapp_launch_url` | `"https://web.whatsapp.com/"` |
| `department_label` | `"Quality Assurance Department"` |
| `usage_expiry_date` | `""` |
| `report_logo_path` | `""` |
| `reference_seed_done` | **`"0"`** |
| `security_clock_tamper_flag` | `"0"` |
| `security_max_seen_date` | `""` |
| `security_last_online_check` | `""` |

#### Dart الآن (`settings_repo.dart:42-46`)
```dart
'department_label': 'Quality Assurance Department',
'usage_expiry_date': '',
'reference_seed_done': '',   // ≠ '0'
```
ناقص: `pdf_export_dir`, `export_root_path`, `whatsapp_launch_url`, `report_logo_path`,
ثلاثة مفاتيح أمان، والقيمة `''` بدل `'0'`.

#### الإصلاح
```dart
final defaults = <String, String>{
  'department_label': 'Quality Assurance Department',
  'usage_expiry_date': '',
  'reference_seed_done': '0',
  'pdf_export_dir': paths.defaultPdfDir,
  'export_root_path': paths.exportsRoot,
  'whatsapp_launch_url': 'https://web.whatsapp.com/',
  'report_logo_path': '',
  'security_clock_tamper_flag': '0',
  'security_max_seen_date': '',
  'security_last_online_check': '',
};
```
- `settings_repo` يحتاج حقن `AppPaths` (أو path defaults) ليُقيّم المسارين.
- `seed_service.isSeedDone()` (`seed_service.dart:28-33`) يقارن `value == '1'` —
  لا يتأثر بتغيير الـ default إلى `'0'`، والتقارير (`report_service.dart:359`) تقرأ
  `export_root_path` — سيصبح معرفاً الآن (كان يعمل بلا key فسقوطاً للـ fallback).

---

### 3.7 قاعدة 7 — حذف مستخدم مرتبط بسجلات

#### Python (`auth.py:139-155`, `delete_user`)
- يحسب `inspections (created_by)` و `inspection_status_history (changed_by)`.
- أكثر من 0 في أي منهما ⇒ `ValidationError` يمنع الحذف مع رسالتين عربيتين.

#### Dart الآن (`settings_repo.dart:161-170`)
```dart
await db.delete('users', where: 'id = ?', whereArgs: [id]);
```
حذف مباشر بلا فحص ⇒ تُترك سجلات `created_by` بلا مستخدم (تُفقد هوية المراجع).

#### الإصلاح
```dart
final insp = await db.rawQuery(
    'SELECT COUNT(*) AS c FROM inspections WHERE created_by = ?', [id]);
if ((Sqflite.firstIntValue(insp) ?? 0) > 0) {
  throw const ValidationError('لا يمكن حذف المستخدم: لديه سجلات فحوصات قائمة.');
}
final hist = await db.rawQuery(
    'SELECT COUNT(*) AS c FROM inspection_status_history WHERE changed_by = ?', [id]);
if ((Sqflite.firstIntValue(hist) ?? 0) > 0) {
  throw const ValidationError('لا يمكن حذف المستخدم: لديه سجلات في سجل القرارات.');
}
```

---

### 3.8 قاعدة 8 — نسخ احتياطي + PRAGMAs

#### Python
- نسخ الاحتياطي يستخدم SQLite backup API + `checkpoint` ثم integrity.
- `sqlite_db.py` يضبط: `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`,
  `temp_store=MEMORY`, `cache_size=-20000`, `mmap_size=268435456`.

#### Dart الآن
- `backup_manager.dart:210,238`: `PRAGMA wal_checkpoint(FULL)` — المرجع يستخدم `TRUNCATE`.
- `database_helper.dart:95-100`: لا `temp_store`/`cache_size`/`mmap_size`.

#### الإصلاح
```dart
// backup_manager.dart — موضعان
await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
// database_helper.dart — بعد WAL
await db.execute('PRAGMA temp_store=MEMORY');
await db.execute('PRAGMA cache_size=-20000');
await db.execute('PRAGMA mmap_size=268435456');
// وأدر foreign_keys=ON في الاقتران read-only والـ preflight migration
```

---

### 3.9 قاعدة 9 — نضارة `snapshot_json` عند تعديل البيانات

#### Python (`inspection.py:697-913`, `update_inspection`)
بعد تعديل البيانات/النتائج: يُعاد بناء `snapshot_json` بـ `_build_snapshot_payload`
(بما فيه `physical_results` و `chemical_results` و `sample_names` المحدّثة)
ويُخزَّن مع التعديل، ثم يُعاد توليد `report_html` عبر `refresh_report_html`.

#### Dart الآن (`inspection_repo.dart:393-452`, `update`)
يحدّث الأعمدة فقط (`supplier, truck_number, quantity, sample_taken_by,
physical_results_json, chemical_results_json, sample_names_json, updated_at`)
**دون إعادة بناء `snapshot_json`** ولا تحديث `report_html`.

#### الإصلاح
- داخل `update` بعد تجميع `physical/chemical/sampleNames` النهائية:
  أعد بناء الـ snapshot بنفس بنية `buildSnapshot` الحالية وأضف العمود
  `snapshot_json` لقائمة UPDATE مع `jsonDumps(...)`.
- أعد توليد `report_html` (راجع Phase 2) بعد التحديث — كحدث منفصل قابل للفشل
  الاستثنائي دون كسر التعديل (wrap في try/catch مع تسجيل).

---

### 3.10 قواعد جزئية/ثانوية (Minor parity) — تُنفَّذ مع ما سبق
| الموقع | الحالي | المرجع | الإصلاح |
|---|---|---|---|
| `lib/core/utils/app_format.dart` (safeFloat) | `replaceAll(',','.')` | `_safe_float` يستدعي `replace` على الفاصلة فقط | اجعل `.replaceAll(',', '')` للمدخلات بعملة/فواصل آلاف ثم parse |
| `lib/features/reports/data/qr_builder.dart` | `??` للـ `by` | `or` (يرصد نصاً فارغاً) | استخدم `(x?.isNotEmpty ?? false) ? x! : fallback` |
| `lib/core/security/local_secret.dart` | sha256 fallback للملف التالف | Python يرمي ويعيد إنشاء | (اختياري) أزل الـ fallback ليطابق إعادة الإنشاء |

---

## 4) PHASE 2 — Full HTML Renderer for `report_html` (محرك HTML كامل)

### 4.1 لماذا هو إلزامي الآن
- Python يخزّن في `inspections.report_html` **HTML كاملاً** مولّداً من
  `templates/report_template.html` عبر `ReportService.render_html`
  (`report.py:209`) ويُعيد توليده عند كل إنشاء/تعديل/قرار (`inspection.py:328-342,373,438,677,899`).
- Dart الآن يخزّن ثابتاً `_simplePreviewHtml` (`inspection_repo.dart:197,243-246`):
  ```dart
  return '<html><body><h3>Material Lab</h3><p>$name</p></body></html>';
  ```
  هذا كسر 1:1 لأي استهلاك خارجي/ترحيل/معاينة HTML للقاعدة القديمة.

### 4.2 البنية المقترحة
```
lib/features/reports/data/
├── report_html_builder.dart   # (جديد) render_html الكامل + builders البيانات
└── (الموجود) report_service.dart, report_builder.dart, pdf_renderer.dart
assets/
└── templates/
    └── report_template.html   # (جديد) نسخة من templates/report_template.html
```
1. **تضمين القالب كأصل بيانات:** انسخ `templates/report_template.html` من المشروع
   المرجعي إلى `assets/templates/` وسجّله في `pubspec.yaml` تحت `assets:`.
2. **محرك mini-Jinja لـ Dart** (لا نضيف مكتبة خارجية — عدد البنيات المستخدمة صغير):
   - تعويض المتغيرات: `{{ var }}` مع **escape HTML** (`& < > " '`) — مطابقة autoescape
     فيjinja2.
   - الشروط: `{% if report_logo_data_uri %}...{% endif %}`،
     `{% if show_status_timeline %}`، `{% if show_decision_reason %}`،
     `{% if show_follow_up_note %}`، `{% if show_rejected_quantity %}`،
     `{% if qr_image_data_uri %}`، `{% if qr_warning %}`، `{% if base_url %}`.
   - الحلقات: `{% for sn in sample_names %}`, `{% for item in physical_data %}`,
     `{% for step in status_timeline %}` مع `loop.index`, `loop.index0`, `loop.last`,
     `loop.index is odd`.
   - فلاتر/دوال مستخدمة: `or "Quality Control Department"`, `or "-"`,
     `status_timeline|length > 4`, `step.version or loop.index`.
3. **بنّاؤو البيانات (Dart ports):**
   - `_build_physical_data` (`report.py:…`): من `physical_reference` + `physical_results`
     + `sample_names`، مع `is_outs` = `is_physical_out_of_range` لكل نتيجة.
   - `_build_chemical_data`: من `chemical_reference` + `chemical_results` مع
     `min_display/max_display` عبر `format_value_with_unit` + Enrichment للوحدات
     (`api` من `reference.py`).
   - `_merge_lab_tests` (`report.py:167-207`): مزج نتائج المختبر المرفوعة بـ
     `injectLabTests` مع البادئة `(Lab) ` وفحص `is_out_of_range` لوحداتهم.
   - `status_timeline`: عكس `status_history`، تجاهل الحالات غير المعروفة، وإخراج
     `{status_code, label_ar, label_en, css_class, reason, version, changed_at}`.
   - `build_qr_payload_text` (موجود `qr_builder.dart`) ثم `generateQrDataUri` (Phase 1-قاعدة 4).
   - سياق الدالة: `inspection_id, date, expiry_date, sample_number, material_name,
     quantity, supplier, truck_number, sample_taken_by, specialist_name,
     created_by_name, sample_names, decision_*, department_label, report_logo_data_uri`.
4. **واجهة الخدمة:**
   ```dart
   class ReportHtmlBuilder {
     Future<String> renderInspectionHtml(Map<String, dynamic> inspection); // يحمّل القالب مرة واحدة
   }
   ```
   تُسجَّل في `get_it` وتمرَّر إلى `InspectionRepo` (أو يستدعى عبر `ReportService`).
5. **مواضع الحفظ** (تطابق `refresh_report_html`):
   - `InspectionRepo.create` (`inspection_repo.dart:197`) — بعد الإدراج، استبدل
     `base['report_html']` بالنتيجة الكاملة واحفظ بالـ UPDATE ذاته.
   - `InspectionRepo.updateDecision` (`inspection_repo.dart:358-387`) — أضف
     `report_html` إلى الـ UPDATE أو UPDATE منفصلة بعدها.
   - `InspectionRepo.update` (قاعدة 3.9) — أعد التوليد.
   - بنفس الطريقة أعد بناء `report_html` عند قراءة سجلات قديمة، لا ضرورة.

> **لماذا ليس استبدالاً كاملاً للـ PDF؟** التطبيق يعرض PDF بأسلوب `pdf`/`printing`
> لأي شاشة، و`report_html` مخزن للاستهلاك/الترحيل المطابق للمرجع فقط. خلاص:
> مرجع 1:1 للمحتوى (نفس الحقول والنسب والجداول والـ QR data-URI المشفّر) دون
> اعتماد السلسلة النصية الأمامية.

---

## 5) PHASE 3 — Tests & Verification (الاختبارات والتحقق)

### 5.1 أوامر التحقق
```bash
flutter analyze                 # 0 errors
flutter test                    # كل المجموعات الأربع الحالية خضراء
flutter run -d windows          # Smoke يدوي
```
### 5.2 اختبارات Unit جديدة (بمرجعية Python)
| الاختبار | المرجع | المتوقع |
|---|---|---|
| `decision_reason` مطلوب لـ CONDITIONAL/PARTIAL/FULL | `inspection.py:57-61` | ValidationError للثلاثة |
| `rejected_quantity > quantity` في PARTIAL | `inspection.py:79-85` | ValidationError عربي |
| `rejected_quantity` رقمي لكل الحالات عند وروده | `inspection.py:86-92` | رفض النصوص |
| تطبيع: CONDITIONAL يمسح `rejected_quantity`؛ FULL يمسح `follow_up_note`؛ APPROVED يمسح الكل والسبب | `inspection.py:94-99` | قيم ممسوحة حسب الحالة |
| نسبة 5/6 = 83.3 لا 83 | `aggregation.py:83`، `report.py` | `83.3` |
| QR: payload > 2400 بايت يُختزل 2380 + `...[truncated]` + warning | `utils.py:548-597` | data-URI ناجحة + warning |
| QR: payload فارغ | « | `('', 'QR payload is empty.')` |
| seal تالف ⇒ حظر دخول | `settings.py:118-124` | AuthorizationError |
| defaults تعطي 10 مفاتيح بالضبط وقيمة `reference_seed_done='0'` | `settings.py:32-45` | مساواة |
| حذف مستخدم له فحوصات ⇒ مرفوض | `auth.py:145-155` | ValidationError |
| `report_html` يعاد توليده بعد القرار والتعديل | `inspection.py:328-342` | نشوئه الجديد ≠ القديم |

### 5.3 معايير قبول النهاية
1. `flutter analyze` نظيف.
2. كل اختبارات Phase 0–2 خضراء.
3. إنشاء فحص ← قرار CONDITIONAL ← تعديل ← قرار يظهر النتائج والـ QR و
   `report_html` مطابقاً للمرجع حقلاً بحقل.
4. `qr_decrypt.py` يفك QR الناتج من Dart (معيار أمان قائم).

---

## 6) Sequencing — ترتيب تنفيذي مقترح
1. **Phase 0** (Build): يُنفَّذ أولاً؛ بدونها لا تحقق.
2. **قاعدة 1+2** (قرارات) ثم **قاعدة 3** (نسب) — أسرع أثر على السلوك اليومي.
3. **قاعدة 4** (QR) ثم **قاعدة 7** (حذف المستخدم) — أمان/سلامة.
4. **قاعدة 5** (ترخيص) و**قاعدة 6** (defaults) — أمان/إعدادات.
5. **قاعدة 8** (backup/PRAGMA) و**قاعدة 9** (snapshot) — أداء/اتساق.
6. **Phase 2** (HTML renderer) — يتطلب اكتمال قاعدة 4.
7. **Phase 3** (اختبارات) — يُبنى تدريجياً مع كل خطوة، والتشغيل النهائي.

مع كل خطوة: `flutter analyze` + اختبار الوحدة المرتبط قبل الانتقال للتالية.

---

## 7) Deferred (مؤجلة بناءً على طلب المستخدم)
1. **Developer rules:** (أ) تشديد أن اسم أول مدير = `hassan10101s` في الـ Setup،
   (ب) إخفاء صف المطور من قوائم المستخدمين، (ج) بوابة `pbkdf2_sha256_v2_dev` عند
   دخول المطور. إضافة لاحقة بمراجعة المنتج.
2. **ميزات مطرودة (موجودة لكن بلا ربط):** `followUpReport` بلا كود UI،
   `report_logo_data_uri` بلا مُنتج (اختيار الشعار)، نسخ احتياطي "يومي" يشتغل
   عند الإقلاع فقط، لوحة Export الإعدادات نصية placeholder.
3. **تحسين أداء اختياري:** كشف فارق الساعة > 12h المذكور في وثائق الـ Plan الأصلية
   (لا يُنفَّذ في Python فعلياً اليوم).

---

## 8) TL;DR
- **المشكلة الأولى:** الشيفرة لا تُبنى (fix: 4 ملفات تسطيح `const` + import لـ `AppText`).
- **النواة:** 9 انحرافات مؤكدة 1:1 (تحقق/تطبيع القرار، تقريب النسب، اختزال QR،
  عبث الترخيص، defaults، حذف المستخدم، checkpoint/PRAGMAs، snapshot، `report_html`).
- **الحل:** إصلاح حرفي وفق الجداول أعلاه + محرك HTML كامل للمرجع المخزن + اختبارات
  مرجعية من Python.
- **يشغَّل بترتيب:** Build → Decision/Percent → QR/Security/Defaults → Backup/Snapshot
  → HTML renderer → Tests.