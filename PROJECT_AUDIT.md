# PROJECT_AUDIT.md — Material Lab

> **تاريخ التدقيق:** 2026-09-27 · **الفرع:** `feature/v2-org-firebase-sync` · **Flutter:** 3.44.8 / Dart 3.12.2
> **بوابة المرحلة 0:** `flutter analyze` = **No issues found** · `flutter test` = **305 نجحت / 30 مُتخطّاة** · `flutter build windows --release` = **نجح**
>
> هذا هو مخرج المرحلة 0 من `PLAN_V3.md`. كل رقم في هذا الملف مُستخرَج من الكود، لا مقدَّر.

---

## A — الوحدات الحالية (11 وحدة)

| # | الوحدة | الشاشات / الملفات | الجداول | الحالة |
|---|---|---|---|---|
| 1 | **Auth** | `login_screen`, `create_organization_screen`, `waiting_activation_screen` | `users` | Firebase Google + جلسات offline عبر `SessionStore` |
| 2 | **Shell** | `app_shell.dart` (581 سطر) | — | responsive جزئياً: breakpoint واحد عند 720 |
| 3 | **Dashboard** | `dashboard_screen` + cubit×2 | استعلامات فقط | KPIs + رسوم |
| 4 | **Inspections** | `inspections_screen`, `inspection_form_screen` (1401 سطر), `inspection_detail_screen` | `inspections`, `inspection_status_history` | V1 port كامل + قرار versioned |
| 5 | **Lab** | `lab_screen` + 7 tabs + 8 cubits | `lab_inventory`, `lab_sample_tests`, `lab_worksheet`, `lab_consumption_log`, `lab_stock_adjustments` | Wet chemistry كامل |
| 6 | **Reference** | `reference_screen` + 4 tabs | `reference_materials`, `parameters`, `lab_units`, `lab_products`, `lab_product_analyses`, `lab_material_analyses` | Master data |
| 7 | **Lab config** | ضمنLab tabs | `lab_analyses`, `lab_analysis_items`, `lab_field_chemical_links`, `lab_constants` | محرك معادلات آمن (بلا `eval`) |
| 8 | **Reports** | `reports_screen` | — | PDF (`pdf_renderer`, 973 سطر) + HTML + QR |
| 9 | **Sync** | `sync_screen`, `sync_badge` | `sync_queue`, `sync_metadata`, `sync_conflicts`, `device_registry` | offline-first كامل |
| 10 | **Audit** | `audit_screen` | `audit_logs` | ⚠️ 5 من 16 action مُفعَّلة |
| 11 | **Members** | `members_screen` | `users` | invites + activation + الأدوار |

### الحزم المستخدمة (33)

`flutter_bloc` (Cubit فقط، صفر `Bloc` event-based) · `get_it` · `go_router` · `sqflite` + `sqflite_common_ffi` · `pdf` · `excel` · `qr` · `image` · `pointycastle` · `crypto` · `file_picker` · `path_provider` · `flutter_secure_storage` · `shared_preferences` · `flutter_screenutil` · `intl` · `equatable` · `firebase_core` · `firebase_auth` · `cloud_firestore` · `connectivity_plus` · `uuid` · `google_sign_in 6.3.0` · `google_sign_in_dartio 0.3.0`

**غائبة لازم معرفتها:** `open_filex` · `share_plus` · `image_picker` · `workmanager` — وجميعها مطلوبة للموبايل (المرحلة 1 من الخطة).

---

## B — البيانات الحالية (24 جدولاً)

### B1. نطاق العمل (Inspections)

| الجدول | الغرض | ملاحظات |
|---|---|---|
| `inspections` | صف العمل الأساسي: عيّنة واردة (entry code، مادة، نتائج، قرار، HTML التقرير مخزَّن) | **FK حقيقي**: `material_id → reference_materials`, `created_by → users` |
| `inspection_status_history` | سجل append-only لكل تغيير قرار، versioned | FK + `ON DELETE CASCADE` |
| `lab_sample_tests` | نتيجة تحليل مختبر واحد | `source_type` polymorphic — انظر B3 |

### B2. Chemistry / Lab

| الجدول | الغرض |
|---|---|
| `lab_inventory` | مخزون الكواشف: اسم، فئة (`liquid`/`powder`)، وحدة، كمية حالية/دنيا |
| `lab_analyses` | تعريف التحليل: وحدة، أسماء حقول ديناميكية، معادلة، ثوابت |
| `lab_analysis_items` | فاتورة الكواشف لكل تحليل (`qty_per_sample`) |
| `lab_field_chemical_links` | ربط حقل ديناميكي ← كاشف / قيمة ثابتة / قائمة مسموحة |
| `lab_constants` | ثوابت كيميائية عامة مع `min_value`/`max_value`/`precision` |
| `lab_worksheet` | صف worksheet مشترك = عيّنة تُملأ عبر عدة تحليلات |
| `lab_consumption_log` | استهلاك الكواشف + صفوف `REVERSAL` + `shortfall_qty` |
| `lab_stock_adjustments` | لقطة قبل/بعد لتغيير كمية المخزون |

### B3. Master data

| الجدول | الأعمدة المهمة | حدود المواصفة | الوحدة |
|---|---|---|---|
| `reference_materials` | `chemical_reference_json`, `physical_reference_json` | **نص JSON** يُحلَّل بـ regex وقت التشغيل | ❌ لا يوجد |
| `parameters` | `unit`, `parameter_type` | ❌ | `unit TEXT` |
| `lab_units` | `symbol`, `name`, `dimension`, `is_active` | ❌ | `symbol` — **والجدول لا يُقرأ أبداً** |
| `lab_products` | `name`, `category`, `description`, `active` | ❌ ( living في join ) | ❌ |
| `lab_product_analyses` | `min_value`, `max_value`, `unit` | ✅ typed | ✅ |
| `lab_material_analyses` | `min_value`, `max_value`, `unit` | ✅ typed | ✅ |

**مشكلة بنيوية #1 — مصدران للحقيقة:** المواصفات في أعمدة typed **و** في JSON نصي.
**مشكلة بنيوية #2 — 4 أنظمة وحدات متوازية، لا مرجع منها.** انظر القسم D.
**مشكلة بنيوية #3 — تغطية FK: 4 جداول من 24 فقط.** `lab_*_analyses`, `lab_analysis_items`, `lab_products`, `lab_sample_tests` تعتمد على application-level joins بلا قيود.

### B4. Users / Org

`users` — مرآة محلية لـ `organizations/{o}/members/{m}`. الهوية في Firebase، **لا كلمات مرور محلية**. الصف `id=0` محجوز كـ "مستخدم غير معروف" لFk.

### B5. البنية التحتية للمزامنة

`sync_queue` (outbox، فهرس فريد جزئي على `(entity_type, entity_id)`)، `sync_metadata` (KV: device_id, cursors)، `sync_conflicts`، `device_registry`، `audit_logs` (append-only، تنظيف 90 يوم / سقف 20,000).

**نطاق المزامنة (15 `SyncEntity`):** `inspections`, `inspection_status_history`, `lab_sample_tests`, `users`, + 8 lab config، + `audit_logs` (push فقط).
**device-local عمداً:** `lab_inventory`, `lab_consumption_log`, `lab_stock_adjustments`, `lab_worksheet`, `settings`, `reference_materials`, `parameters`, `sync_*`.

### B6. العزل المؤسسي

قاعدة بيانات **واحدة لكل مؤسسة**: `%APPDATA%/MaterialLab/orgs/<orgId>/material_lab.db` (`app_paths.dart:40-48`). **لا `organization_id` في أي جدول** — العزل فيزيائي.

---

## C — قائمة الوحدات الممنوع تكرارها

⚠️ أي feature جديدة **يجب** أن تبني على ما في هذه القائمة. ممنوع بناء نظام موازٍ.

| الحاجة | استخدم هذا | ممنوع بناء هذا |
|---|---|---|
| Tasks + مسؤول + موعد + مرفقات + تحقق + تاريخ | **Quality Core (§5.1)** — يُبنى مرة واحدة | نظام Tasks لكل feature |
| Owner / Reviewer / Actor | جدول `users` | جدول موظفين |
| الصلاحيات | `permissions.dart` + `WriteGuard` | نظام أدوار جديد |
| التدقيق المؤسسي | `AuditLogger` + `audit_logs` | سجل لكل feature |
| Timeline لكل مهمة | `quality_task_events` (نواة Quality) | سجل منفصل |
| الوحدات | `lab_units` (بعد إصلاحه — §D) | `ChecklistUnit` / `EquipmentUnit` / `TestUnit` |
| المواصفات | `SpecResolver` (يُبنى في §4.3) | مواصفة داخل كل feature |
| المرفقات | نظام Evidence (يُبنى في §5.2) | `FilePicker` في كل شاشة |
| التنبيهات | استعلامات مشتقّة (Notification Center) | نظام إشعار لكل module |
| الـ Sync | `entity_registry.dart` — سطر واحد لكل جدول | كود مزامنة جديد |
| القوائم والنماذج | `AppPaginatedTable`, `AppCard`, `AppField`, `AppStatusBadge`, `AppEmptyState` | widgets جديدة |
| التقارير | `ReportService` + `PdfRenderer` + `ReportHtmlBuilder` | عارض PDF جديد |
| الـ Backup | `BackupManager` | نظام نسخ |
| التنقل | `go_router` + `AppShell` | نظام تنقل |

**الاستثناء الوحيد — لا يوجد ما يُعاد استخدامه:** ❌ **لا يوجد نموذج attachments/evidence/documents في المشروع إطلاقاً.** لا جدول، ولا blob storage، ولا `image_picker`. `inspections.last_pdf_path` عمود `TEXT` مفرد، **cache لآخر تصدير يُفرَّغ عند كل تعديل** (`inspection_repo.dart:211, 239, 421, 515`)، ومُستبعَد من المزامنة (`entity_registry.dart:356`). ⇒ **هذا يُبنى من الصفر في §5.2 — ولا شيء آخر.**

---

## D — وحدات القياس: 4 أنظمة متوازية، **لا مرجع منها**

| # | النظام | الموقع | يُقرأ من المحرك؟ |
|---|---|---|---|
| 1 | جدول `lab_units` | `database_helper.dart:325` | ❌ **لا** — CRUD فقط (`units_tab.dart`) |
| 2 | `formula_engine` hard-coded | `formula_engine.dart:14-31` | ✅ **نعم** — هذا المحرك الفعلي |
| 3 | `parameters.unit` نص حر | `database_helper.dart:238` | للعرض فقط |
| 4 | أعمدة `unit` على 8 جداول | متفرقة | للعرض فقط |

**المحرك الفعلي (hard-coded):**

```dart
// formula_engine.dart:14-31
const List<String> inventoryUnits = ['L', 'mL', 'kg', 'g', 'pc'];
const Map<String, double> _unitFactors = {'l':1000.0,'ml':1.0,'kg':1000.0,'g':1.0,'pc':1.0};
const Map<String, String> _unitDims   = {'l':'volume','ml':'volume','kg':'mass','g':'mass','pc':'count'};
const List<String> unitOptions = ['L', 'mL', 'kg', 'g', 'pc'];
```

**الوحدات المزروعة فعلياً في `assets/units.xlsx` (52):**
`%` · `g/L` · `U/g` · `mg/100g` · `mgKOH/g` · `mmol/kg` · `g/100g` · `ug/kg` · `mg/kg` · `Presence/Absence`

⚠️ **لا واحدة منها** — عدا `%` — موجودة في `_unitFactors`.

**النتيجة المؤكدة:** `convertQuantity` (`formula_engine.dart:64-72`) **يُرجع القيمة بلا تغيير بصمت** لأي وحدة خارج `_unitFactors`. أي أن التحويل غير موجود فعلياً لأغلب معاملات التطبيق.

**وحدات أخرى hard-coded:** `mL` كـ default في `lab_analyses`/`lab_field_chemical_links` DDL، `%` كـ default في `lab_material_analyses`/`lab_product_analyses`، و`g` في `analyses_tab.dart:371,830,903`.

### ⇒ هذا هو **السبب**-promotion لـ §8 إلى ما قبل §16

الخطة الأصلية (§8) قالت "استخدم Unit System الموجود". النظام موجود **نيابةً** فقط. خطوته الأولى في `PLAN_V3.md` §4.1 هي إصلاحه، وبعدها فقط تسري القاعدة.

---

## E — قفل الصناعة (يجب فكّه في §4.2)

`lab_sample_tests.source_type` ثابت من قيمتين في `formula_engine.dart:15`:
`raw_material | product`

هذا **هو** القفل المطلوب فكّه. الحل: جدول `item_types` يُزرع بالقيم النصية الحالية ⇒ صفر migration.

**-hard-coded، مرتبط بصناعة محددة، في طبقة الكود (3 مواقع):**
1. ثوابت Kjeldahl/المعايرة — `formula_engine.dart:89-110`: `F_PROT=6.25` (بروتين عام)، `F_WHEAT=5.70` (قمح)، `F_DAIRY=6.38` (ألبان)، `K_LIPID=1.4007`
2. 4 تحليلات افتراضية مع فواتير كواشف — `formula_engine.dart:113-139` (بروتين، دهن، رطوبة، رماد)
3. استنتاج وحدات السموم الفطريّة — `formula_engine.dart:963-965` (`afla`, `ochra`, …)

`assets/Reference.xlsx` (96 خامة) و `units.xlsx` (52) **بيانات**، لكن عقد أعمدتهما hard-coded في `seed_service.dart:22-27, 79-83, 122-124`.

**معايير فيزيائية** لـ `isPhysicalOutOfRange` (`:994-1012`): `'negative'`, `'abnormal'`, `'غير طبيعي'`, `'سيء'`, `'pale'` … — مفردات **تصنيف الحبوب**.

---

## F — جاهزية الموبايل (ملخص)

### ✅ لا عوائق Dart

| الفحص | النتيجة |
|---|---|
| `Process.run` / `Process.start` | **صفر** |
| `FileSystemEntity` | **صفر** |
| `Platform.environment` | **صفر** في `lib/` |
| مسارات بأحرف أقراص (`C:\`) | **صفر** |
| `stdout` / `stderr` / `exitCode` | **صفر** |
| `dart:ffi` / `DynamicLibrary` | **صفر** |
| `dart:io` (10 مواقع) | كلها **غير ضارة** — `Directory`/`File` من `path_provider`، وفرع `Platform.isWindows` |
| `sqflite` FFI branch | **صحيح أصلاً** — `database_helper.dart:26-33` |
| `pdf_renderer.dart` | **بلا `dart:io`** — توليد PDF يعمل على Android |
| `flutter_secure_storage` | مُهيّأ بـ `AndroidOptions` أصلاً |
| `google_sign_in` | يفريع على `Platform.isWindows` أصلاً |

### ❌ العوائق الحقيقية (3)

1. **لا يوجد `android/`** — `.metadata:14-20` يسجّل `[root, windows]` فقط. يلزم `flutter create --platforms=android .`
2. **`main.dart:46`** — `designSize: Size(1280, 720)`. على هاتف 360dp: `scaleWidth = 0.281` ⇒ `280.w` → **79dp**؛ `scaleHeight = 1.111` ⇒ `680.h` → **755dp** (أطول من الشاشة)
3. **لا `open_filex` ولا `share_plus`** — كل PDF يُكتب إلى `/data/user/0/<pkg>/files/...` غير قابل للوصول، و`_openPdfFolder` في `app_shell.dart:110-116` مجرد stub

### حالة الـ ScreenUtil

| الامتداد | العدد | الملفات |
|---|---:|---:|
| `.r` | 143 | 27 |
| `.w` | 40 | 20 |
| `.h` | 15 | 11 |
| `.spMax` | 181 | 33 |
| `.sp` | **0** | 0 |

**`.sp` غير مستخدم إطلاقاً** — كل النصوص تستخدم `.spMax` (`max(absolute, scaled)`) ⇒ النص لا يصغر عن حجمه المؤلَّف. هذه هي الخاصية التي تجعل الاحتفاظ بـ ScreenUtil قراراً آمناً.

**`MediaQuery` — موقع واحد فقط**، وهو breakpoint حقيقي: `app_shell.dart:151` (`>= 720`).
**`LayoutBuilder` — 8 مواقع**، كلها breakpoints حقيقية.
**`DataTable` — 7 مواقع، كلها** مغلّفة بـ horizontal scroll.
**`AppPaginatedTable` — `height = 470`** عدد خام غير مُقيَّس (`app_paginated_table.dart:36`).

### حوارات بأبعاد ثابتة تحتاج full-screen على compact

`material_editor.dart:419-420` (`880.w × 680.h`) · `products_tab.dart:358-359` (`760.w × 620.h`) · `test_history_tab.dart:112` (`1040 × 780`)

---

## G — فجوات التدقيق (يجب سدّها في §5.3)

`AuditLogger` (**16 action مُعلَنة، 5 مُفعَّلة**):

| المُفعَّل | الموقع |
|---|---|
| `SAMPLE_CREATED` · `SAMPLE_UPDATED` · `QC_APPROVED` · `QC_REJECTED` · `SAMPLE_DELETED` | `offline_first_inspection_repository.dart:72,96,125,153,230` |
| `LAB_RESULT_SAVED` | `offline_first_lab_repository.dart:151` (فقط `runSampleTest`) |
| `DENIED_ENTRY` · `SYNC_CONFLICT` | `push_worker.dart:192, 205` |
| `DEVICE_REGISTERED` | `device_registry.dart:218` |

**غير مُسجَّل إطلاقاً:** `reference_materials` · `parameters` · `lab_units` · كل lab-config CRUD · `lab_inventory` · `addInventoryItem`/`adjustStock` · `saveWorksheet` · كل `settings` · `BackupManager` · `MEMBER_*` + `ORGANIZATION_CREATED` (مُعلَنة وغير مستخدمة).

**الآلية موجودة** — `AuditLogger.log(txn, ...)` في نفس الـ transaction (`audit_logger.dart:57`). السدّ **توصيل، لا معمارية**.

**تحذيران:**
- `audit_logger.dart:106-116` — `assert` **يفشل بصوت عالٍ** إذا تجاوز الـ payload أي مفتاح خارج العشرة المسموحة في الـ rules
- `audit_logger.dart:129-138` — إخفاء الأسرار **أعلى مستوى فقط، غير recursive**

---

## H — Decision Log (5 قرارات)

| # | القرار | السبب |
|---|---|---|
| D1 | Evidence = ملف device-local + صف وصف فقط | البايتات لا تدخل حمولة المزامنة ⇒ حد 900KB في `push_worker` وحد 1MiB في Firestore لا يُقربان |
| D2 | Quality modules device-local أولاً | أسرع بناءً؛ الجداول مصممة ليضاف لها `SyncEntity` لاحقاً بلا migration |
| D3 | ScreenUtil يبقى + `designSize` واعي للشكل | 198 استدعاء في 34 ملف؛ `.spMax` يضمن أن النص لا يصغر |
| D4 | تخطيط Quality = `lib/features/quality/{data,domain,presentation}/` | `repository_boundary_test.dart:236` يرفض المجلدات الفرعية لكل ميزة — **فشل صامت** |
| D5 | لا دمج `reference_materials` مع `lab_products` | `inspections.material_id` FK يعتمد عليها؛ المنتجات التائمة مفهوم مختلف |

---

## I — بوابات التحقق لكل مرحلة

```bash
flutter analyze     # 0 errors  ← إلزامي
flutter test        # أخضر كامل  ← إلزامي
```

بالإضافة، يجب أن يبقى أخضراً:

| الاختبار | ما يمنعه |
|---|---|
| `test/architecture/repository_boundary_test.dart` | `presentation` يستورد `data/` · SQL في العرض · تخطيط مجلدات خاطئ · contract غير مسجَّل في DI |
| `test/architecture/firebase_isolation_test.dart` | Firebase خارج `core/sync/remote/` |
| `test/security/permissions_parity_test.dart` | انحراف `permissions.dart` عن `firestore.rules` |
| `test/security/firestore_rules_test.dart` | ثغرة في القواعد (يعمل على Emulator) |
| `test/sync/atomicity_test.dart` | كتابة بلا `enqueue` في نفس الـ transaction |
