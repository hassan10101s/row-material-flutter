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