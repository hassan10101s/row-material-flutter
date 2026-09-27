# PLAN_V3.md — Material Lab: Windows + Mobile + Quality Management

> **الحالة:** خطة تنفيذية نشطة.
> **المؤرشفة:** `PLAN_V2_ORG_FIREBASE_OFFLINE_FIRST.md` (مراحلها P1–P12 منفَّذة بالكامل).
> **المؤرشفة أيضاً:** `PLAN_V1_PORT_DONE.md` (ترحيل Python → Flutter، منفَّذ).
> **المرجع الأصلي:** وثيقة "Material Lab — خطة التنفيذ المعمارية" (40 مرحلة)، أُعيدت صياغتها هنا على الكود الفعلي بعد جرد كامل.
>
> **القاعدة الذهبية:** نحافظ على Material Lab الحالي، نفهمه، ثم نطوره — لا نبدأ مشروعاً جديداً وننقل القديم إليه.
> **Build Once — Reuse Everywhere.** **Simple UX — Flexible Data Model.** **One Repository — Shared Logic — Adaptive UI.**

---

## 0) تصحيحات جوهرية على الخطة الأصلية

الخطة الأصلية كُتبت مقابل صورة قديمة للمشروع. أربع تصحيحات، كلها مُتحقَّق منها من الكود لا مُقدَّرة:

| الخطة الأصلية تفترض | الواقع المُتحقَّق منه |
|---|---|
| يحتاج Audit كامل | **منجز** في هذه الجلسة → انظر `PROJECT_AUDIT.md` |
| لا توجد طبقة Responsive | موجودة جزئياً: breakpoint واحد (`app_shell.dart:151`) + 8 `LayoutBuilder` + mobile drawer |
| لا توجد مزامنة | محرك offline-first كامل: `sync_queue`/`sync_metadata`/`sync_conflicts`/`device_registry` + 15 `SyncEntity` + Firestore rules + emulator tests |
| "نستخدم Unit System الموجودة" (§8) | ⚠️ **معطّلة.** `lab_units` لا يقرأها المحرك أبداً؛ التحويل hard-coded لـ 5 وحدات في `formula_engine.dart:17-31`؛ الـ 52 وحدة المضافة من `units.xlsx` **غير قابلة للتحويل** |

**تغييرات ترويجية** (ثبتّها القناة، وليست تحسينات تجميلية):

1. **تجميد الـ baseline** — 82 ملف غير محفوظ. هذا يحجب كل شيء.
2. **إصلاح نظام الوحدات** — يُنفَّذ **قبل** Checklists، لأن §16 يتطلب نقاطاً رقمية تستخدم وحدات النظام.
3. **الالتزام باختبارات المعمارية** — بوابة صريحة. `repository_boundary_test.dart` و `firebase_isolation_test.dart` يفشلان على أنماط ستنتجها الخطة الأصلية.

---

## 1) القرارات المغلقة

| القرار | الاختيار | السبب |
|---|---|---|
| Evidence | ملف device-local + صف بيانات وصف فقط | البايتات لا تدخل حمولة المزامنة أبداً ⇒ لا اقتراب من حد 900KB في `push_worker` ولا من 1MiB في Firestore |
| Quality modules | device-local أولاً | أسرع بناءً واختباراً؛ الجداول مصممة ليضاف لها `SyncEntity` لاحقاً بلا migration |
| ScreenUtil | يبقى + إصلاح `designSize` + تدقيق المعتدين | 198 استدعاء في 34 ملف؛ `.spMax` يضمن ألا يصغر النص عن حجمه المؤلَّف |
| Mobile milestone | تكامل كامل، شاشة بشاشة | الترتيب الأصلي (§38) |
| Baseline | commit واحد + tag `v2-baseline` | قابل للعكس بـ `git reset --hard v2-baseline` |

---

## 2) ممنوعات مُلزِمة (اختبارات تفشل — ليست تفضيلات)

| القاعدة | الاختبار | الأثر على الكود الجديد |
|---|---|---|
| `presentation/` لا تستورد `data/` أبداً | `repository_boundary_test.dart:175` (ratchet، 40 مدخلاً مجمّداً) | Quality تعتمد على **domain interfaces فقط** |
| لا `DatabaseHelper` ولا `package:sqflite` ولا `SELECT`/`INSERT` في `presentation/` | `repository_boundary_test.dart:217` | كل SQL في `data/` |
| الميزة تملك `data/ domain/ presentation/ core/` فقط | `repository_boundary_test.dart:236` | ⚠️ **`lib/features/quality/equipment/data/` يُرفض.** Quality = `lib/features/quality/{data,domain,presentation}/` مع بادئة في اسم الملف |
| كل domain contract مسجَّل في DI | `repository_boundary_test.dart:258` | المستودعات الجديدة تُسجَّل في `service_locator.dart` |
| لا `cloud_firestore`/`firebase_auth` خارج `core/sync/remote/` | `firebase_isolation_test.dart` | Quality device-local لا تحتاج أي remote code |
| تطابق `permissions.dart` ↔ `firestore.rules` حرفياً | `permissions_parity_test.dart` | الصلاحيات الجديدة تُضاف للملفين معاً حتى قبل المزامنة |

---

# 3) المرحلة 0 — تجميد الـ Baseline

**بوابة كل شيء.**

```bash
git add -A
git commit -m "v2-baseline: org auth + offline-first sync + device registry + audit trail"
git tag v2-baseline
```

**لماذا أولاً:** 82 ملف (+3743/−1730) على `feature/v2-org-firebase-sync`. `main` لا يحتويها. لا يمكن بدء عمل mobile على شجرة متسخة — لا توجد نقطة رجوع.

**التحقق:**

```bash
flutter --version        # 3.44.8 / Dart 3.12.2  ✓ مُتحقَّق
flutter doctor -v
flutter pub get
flutter analyze          # 0 errors
flutter test             # 34 ملف اختبار خضراء
flutter build windows --release
```

**مخرجات هذه المرحلة:** `PROJECT_AUDIT.md` بالأقسام الأربعة (وحدات / كيانات / قائمة منع التكرار / وحدات قياس).

**Acceptance:** analyze 0 · tests خضراء · Windows release يبني · الـ tag موجود.

**Commit:** `v2-baseline` (tag فقط — كل العمل السابق له)

---

# 4) المرحلة 1 — إضافة Mobile لنفس الـ Repository

**الحقيقة المُتحقَّق منها:** الطبقات Dart نظيفة جداً للموبايل. صفر `Process`، صفر registry، صفر مسارات بأحرف أقراص، و `database_helper.dart:26-33` يفرّع sqflite FFI (desktop) مقابل native (mobile) بشكل صحيح أصلاً. `pdf_renderer.dart` **بدون** `dart:io` أصلاً. العوائق الحقيقية ثلاثة فقط.

## 1.1 إنشاء المشروع

```bash
flutter create --platforms=android .
```

`.metadata:14-20` يسجّل `platforms: [root, windows]` فقط — لا يوجد `android/`.

**في `android/app/src/main/AndroidManifest.xml`:**

- `android:allowBackup="false"` — **إلزامي.** Auto Backup سينسخ قاعدة بيانات المؤسسة (`.secret` و `orgs/<orgId>/material_lab.db`) إلى Google Drive، فيُلغى العزل الفيزيائي الموثَّق في `app_paths.dart:11-12`.
- `android:usesCleartextTraffic="false"`
- `INTERNET` + `CAMERA` (لـ `image_picker` في المرحلة 5)
- **لا** تضف `WRITE_EXTERNAL_STORAGE` — evidence يذهب إلى sandbox الخاص بالتطبيق.

## 1.2 الحزم — أربع حزم بالضبط

| الحزمة | الأولوية | السبب الدقيق |
|---|---|---|
| `open_filex` | P0 | كل تصدير PDF يكتب إلى `report_service.dart:388` ⇒ `/data/user/0/<pkg>/files/MaterialLab/exports/...` — **لا يمكن لأي file manager الوصول إليه**. الواجهة تنتهي بـ snackbar (`inspections_screen.dart:126`) و `_openPdfFolder` مجرد stub (`app_shell.dart:110-116`) |
| `share_plus` | P0 | نفس المخرج، ومخرج بديل للـ `.db` الاحتياطي (`settings_screen.dart:359`) |
| `image_picker` | P0 | مطلوب لـ §16 (نقطة photo) و §10 (Evidence) |
| `workmanager` | P1 | `BackupManager.autoBackup()` يعمل مرة واحدة عند ربط المؤسسة (`service_locator.dart:258`). Android يقتل العملية ⇒ **لا نسخ احتياطي دوري إطلاقاً** بدون هذه |

```bash
flutter pub add open_filex share_plus image_picker
flutter pub add workmanager
```

**ممنوع إضافتها:**

- ⛔ `sqlite3_flutter_libs` — `database_helper.dart:28` يستثني Android من مسار FFI؛ إضافتها هي التغيير الذي **يكسر** البناء.
- ⛔ `device_info_plus` — محذوف عمداً (`pubspec.yaml:60-63`)، يُستخدم `Platform.operatingSystem` بدلاً منه.

## 1.3 تحصين `flutter_secure_storage`

في `session_store.dart:11-13` و `token_storage.dart:13-15`:

- أضف `resetOnError: true`. بدونه، `KeyStoreException` بعد استرجاع جهاز **يرمي استثناء** بدل أن يتعافى.
- احذف `encryptedSharedPreferences: true` — مهجورة و no-op في 9.2.4.

## 1.4 Google Sign-In على Android

الفرع في `auth_remote_data_source.dart:54` (`if (!Platform.isWindows) return;`) **يعمل**، و `google_sign_in: 6.3.0` يُحلّ إلى `google_sign_in_android`. إذن sign-in **يُنفَّذ فعلاً**. ثلاثة أشياء خاطئة:

1. **`firebase_options.dart:117`** لا يحتوي مفتاح `googleAndroidClientId`. أضفه كمفتاح `--dart-define`.
2. **`isConfigured` (`:574`)** يفحص `googleClientId.isNotEmpty` — أي **Desktop** client id. على Android، `GoogleSignIn(clientId:)` **يُتجاهل** و Play Services يستخدم المعرّف في `google-services.json`. اجعل الفحص platform-correct.
3. **نصوص الخطأ (`:58-63`, `:87-90`)** تقول للمستخدم أن ينشئ OAuth client من نوع "Desktop app" — خطأ على الهاتف.

**عمل الـ console:** تسجيل package name + SHA-1 في مشروع `materiallab-63405`، إضافة Android OAuth client، ثم commit لـ `google-services.json`.

## 1.5 عدم كسر Windows

```bash
flutter build windows --release
flutter test    # يشمل firebase_isolation_test.dart
```

**Acceptance:** APK debug يُبنى ويشغَّل · Google sign-in يعمل على المنصتين · Windows release أخضر.

**Commit:** `add-android-platform`

---

# 5) المرحلة 2 — طبقة Responsive

**تحذير:** المرحلة 2.1 **تغيّر معنى 198 استدعاء ScreenUtil.** لذلك كل تحويل شاشة في المرحلة 3 هو أيضاً **تحقق بصري**. هذا هو البوابة، ليس اختيارياً.

## 2.1 `designSize` واعي لشكل الجهاز

`main.dart:45-48` اليوم: `designSize: Size(1280, 720)`.

**المشكلة محسوبة:** على هاتف 360dp → `scaleWidth = 360/1280 = 0.281`، `scaleHeight = 800/720 = 1.111`.

- `280.w` (`app_shell.dart:158`) → **79dp** — sidebar غير قابل للاستخدام
- `height: 680.h` (`material_editor.dart:420`) → **755dp** — أطول من الشاشة

**الحل** — في `main()` قبل `runApp`، اقرأ الحجم المنطقي الحقيقي:

```dart
final view = WidgetsBinding.instance.platformDispatcher.views.first;
final logical = view.physicalSize / view.devicePixelRatio;
final designSize = (logical.width >= 1000)
    ? const Size(1280, 720)   // desktop: سلوك غير متغيّر تماماً
    : const Size(400, 860);   // mobile
```

**لماذا هذا آمن:** على mobile يصبح `.w` ≈ كسر من عرض الشاشة، و **`.r` ≈ 1.0** ⇒ الـ 143 استدعاء نصف القطر تحتفظ بحجمها المؤلَّف. و `.spMax` (`max(absolute, scaled)`) مستخدم في كل مكان بدلاً من `.sp` ⇒ **النص لا يصغر أبداً عن حجمه المؤلَّف**. هاتان الخاصيتان هما سبب الاحتفاظ بـ ScreenUtil.

## 2.2 مُساعد الـ breakpoints

`lib/core/responsive/breakpoints.dart` (جديد):

```dart
abstract final class Breakpoints {
  static const double compact = 720;   // هاتف عمودي
  static const double medium   = 1100;  // تابلت / نافذة صغيرة
  static bool isCompact(BuildContext c) => MediaQuery.sizeOf(c).width < compact;
  static bool isExpanded(BuildContext c) => MediaQuery.sizeOf(c).width >= medium;
}
```

`app_shell.dart:151` تصبح `Breakpoints.isExpanded(context)`. الـ 8 `LayoutBuilder` الحالية تأخذ ثوابت مُسمّاة بدل الأرقام السحرية.

## 2.3 العرض التكيّفي للبيانات — أعلى تغيير مردود

`design_system/widgets/app_adaptive_list.dart` (جديد): يعرض `AppPaginatedTable` عند expanded و**قائمة بطاقات** عند compact، من **نموذج صف واحد** — بلا تكرار business logic.

**يخدم 7 مواقع `DataTable` موجودة** وكلها مغلّفة بـ horizontal scroll: `units_tab:106`, `products_tab:131`, `params_tab:117`, `analyses_tab:96`, `constants_tab:94`, `inventory_tab:76`, `test_history_tab:349`.

## 2.4 ارتفاع الجدول

`app_paginated_table.dart:36` — `height = 470` عدد خام غير مُقيَّس. غيّرها إلى `double? height` بقيمة `null` = املأ المساحة المتاحة. على هاتف 640dp، 470dp من الجدول تترك ~100dp للفلاتر.

## 2.5 التنقل على الموبايل

`NavigationBar` سفلي بـ 5 فتحات: **Home · Inspections · Lab · Reports · More**. "More" يفتح `_Sidebar` الحالية كـ modal sheet يحمل Reference و Settings و Members و Sync و Audit و logout.

**الـ sidebar على desktop لا يُمس.**

أضف `PopScope` على الـ drawer overlay (`app_shell.dart:200-219`) — زر رجوع Android لا يُغلقه حالياً.

## 2.6 الحوارات الثلاثة بأبعاد ثابتة

| الملف | الحالي | يصبح |
|---|---|---|
| `material_editor.dart:419-420` | `880.w × 680.h` | full-screen route |
| `products_tab.dart:358-359` | `760.w × 620.h` | full-screen route |
| `test_history_tab.dart:112` | `maxWidth: 1040, maxHeight: 780` | full-screen route |

## 2.7 تسليم الملفات — تنفيذ الـ stub

`report_service.dart` يُعيد `Uint8List` (`ReportDoc`, `:20-35`)، و `pdf_renderer.dart` Dart خالص بلا `dart:io` ⇒ **توليد PDF يعمل على Android اليوم**. الناقص هو التسليم فقط.

`AppFeedback.exportActions(context, doc)` جديد: **فتح** (`open_filex`) · **مشاركة** (`share_plus`) · **حفظ في Downloads**. استبدل كل `AppFeedback.success(..., file.path)` في `inspections_screen:126` و `reports_screen:47` و `lab_reports_cubit:27`.

## 2.8 أهداف اللمس

- `app_button.dart:99` — `height: (small ? 34 : 42).h` مُقيَّس. اجعله حداً أدنى ثابتاً 48dp على compact.
- `app_paginated_table.dart:100` — `itemExtent: 52` → 56 على compact.

**Acceptance:** Windows + Android + بيانات قديمة + تنقّل — الأربعة، أو نوقف.

**Commit:** `responsive-shell`

---

# 6) المرحلة 3 — التحويل شاشة بشاشة

الترتيب الأصلي. كل شاشة commit واحد، وتُجتاز البوابة الأربعة قبل التالي.

```
3.1  Dashboard          dashboard_screen.dart
3.2  Inspections list   inspections_screen.dart        → AppAdaptiveList
3.3  Inspection detail  inspection_detail_screen.dart
3.4  Inspection form    inspection_form_screen.dart    → 1401 سطر، أخير
3.5  Lab center         lab_screen.dart + 7 tabs
3.6  Run test           run_test_tab.dart              → أثقل إدخال رقمي
3.7  Test history       test_history_tab.dart
3.8  Reference          reference_screen.dart + 4 tabs
3.9  Reports            reports_screen.dart
3.10 Settings           settings_screen.dart + 5 tabs
3.11 Members            members_screen.dart
3.12 Audit + Sync       audit_screen.dart, sync_screen.dart
3.13 Mobile regression  جولة كاملة، منصتين
```

**قائمة الانحدار لكل شاشة** (§36 الأصلية): Material · Sample · Lab · Reports · Authentication · Settings · Quality · Windows · Android. أي فشل يمنع التالي.

**إضافي:** استبدل اختصارات `Ctrl+1..6` (`app_shell.dart:229-250`) بـ long-press على عناصر الـ bottom nav، ليحصل الموبايل على مسار مكافئ لكل الوجهات.

**Commits:** `responsive-dashboard`, `responsive-inspections`, …

---

# 7) المرحلة 4 — تعميم نموذج البيانات

**لا يُحذف ولا يُعاد تسمية أي بيانات قائمة. هذا إضافي بالكامل.**

## 4.1 إصلاح نظام الوحدات أولاً

**الحقيقة:** أربعة أنظمة متوازية، لا واحد منها مرجعي:

| # | النظام | الحالة |
|---|---|---|
| 1 | جدول `lab_units` | **لا يقرأه المحرك أبداً.** CRUD فقط في `units_tab.dart` |
| 2 | `formula_engine.dart:14-31` | **محرك التحويل الفعلي**، hard-coded: `['L','mL','kg','g','pc']` + `_unitFactors` + `_unitDims` |
| 3 | `parameters.unit` | نص حر، من `units.xlsx` (52 وحدة: `mg/kg`, `ppm`, `g/L`, `mmol/kg`, `mgKOH/g`, `ug/kg`) |
| 4 | أعمدة `unit` نصية على 8 جداول | بلا مرجعية |

**النتيجة:** `convertQuantity` (`formula_engine.dart:64-72`) **يُرجع المدخل بلا تغيير بصمت** لأي وحدة ليست في `_unitFactors` — أي لأغلب معاملات التطبيق الحقيقية.

**الخطوات:**

1. أضف `base_symbol` و `conversion_factor` لجدول `lab_units` عبر `_ensureColumn` الموجودة (`database_helper.dart:470`).
2. زرع العوامل للـ 52 وحدة من `units.xlsx`؛ اشتقاق `dimension` من `unitDimOf` للاتساق.
3. `formula_engine.dart:14-31` يقرأ من `lab_units`، مع إبقاء الـ maps hard-coded كـ fallback عند فراغ الجدول (تثبيت جديد قبل الزرع).
4. `units_tab.dart` يصبح محرر الوحدات الحقيقي الوحيد.

**بعدها يسري §8 الأصلي:** كل ميزة جديدة — checklists, equipment, quality tasks, tests, specs — تستخدم `lab_units`. ممنوع `ChecklistUnit`، ممنوع `EquipmentUnit`.

## 4.2 أنواع العناصر غير المقيّدة بصناعة

**الحقيقة:** `lab_sample_tests.source_type` ثابت من قيمتين (`formula_engine.dart:15`) — هذا هو القفل المطلوب فكّه.

1. جدول جديد `item_types(id, key, label_ar, label_en, sort_order, is_active)`، يُزرع بـ `raw_material` و `product` **باستخدام القيم النصية الحالية** ⇒ كل صف `lab_sample_tests` موجود يستمر في التحلّل بلا migration. أضف `intermediate`, `packaging`, `other`.
2. `source_type` يصبح بحثاً في `item_types` بدل `const` list. صفر migration.
3. **لا تدمج** `reference_materials` مع `lab_products`. الأولى: مواد واردة عند البوابة، لها entry code ومواصفة فيزيائية، وهي هدف الـ FK `inspections.material_id`. الثانية: منتجات تامة. الدمج يكسر الـ FK.

## 4.3 توحيد حدود المواصفات

**الحقيقة:** المواصفات في **مكانين**:

- أعمدة typed: `lab_material_analyses`, `lab_product_analyses`, `lab_constants`
- JSON نصي: `reference_materials.chemical_reference_json` / `physical_reference_json`، يُحلَّل بـ regex وقت التشغيل (`parseNumericRange` في `formula_engine.dart:898`، `isPhysicalOutOfRange` في `:973`)

1. **مسار قراءة واحد** `SpecResolver`: يفضّل الأعمدة typed، ويسقط على تحليل JSON. **لا يتغير شيء للبيانات القائمة.**
2. جدول معمَّم جديد `lab_item_analyses(item_type_id, item_id, analysis_id, min_value, max_value, unit)`؛ انقل الصفوف من الجدولين القائمين.
3. اترك `lab_material_analyses` و `lab_product_analyses` **read-only لإصدار واحد** كمسار رجوع. احذفهما في مرحلة لاحقة.
4. **المواصفات الفيزيائية:** `lab_products` اليوم بلا جدول مواصفة فيزيائية إطلاقاً. أضف `lab_item_physical_specs(item_type_id, item_id, key, value_text, numeric_value, min_value, max_value, unit)`.

**Acceptance:** min/max/target/precision كلها **بيانات** لا كود. المستخدم يضيف `Viscosity / cP / 100-250` أو `pH / pH / 6.5-7.5` بلا تغيير كود. التقارير الحالية تُنتج بايت-ببايت مطابقة.

**Commits:** `generalize-item-types-and-specs`, `repair-unit-system`

---

# 8) المرحلة 5 — Quality Core

الأقسام 9 و 10 و 11 و 29. هذا هو البناء الجديد الحقيقي.

## 5.1 الجداول

**مهم:** أضف DDL إلى `_createSchema` فقط. `version: 1` **ثابت** و `_runLegacyGuarantees` تُشغَّل عند كل فتح (`database_helper.dart:184-195`) ⇒ **لا ترقية إصدار مطلوبة**. هذا هو النمط المستخدم أصلاً لـ 20+ عموداً سابقاً (`:644-664`).

```sql
CREATE TABLE IF NOT EXISTS quality_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  description TEXT,
  type TEXT NOT NULL,                    -- action | investigation | calibration | corrective
  assigned_to INTEGER REFERENCES users(id),
  reviewer INTEGER REFERENCES users(id),
  created_at TEXT NOT NULL,
  due_date TEXT,
  priority TEXT NOT NULL DEFAULT 'normal',
  status TEXT NOT NULL DEFAULT 'new',
  source_kind TEXT,                      -- objective|checklist|nc|complaint|equipment|NULL
  source_id INTEGER,
  verified_by INTEGER REFERENCES users(id),
  verified_at TEXT,
  rejection_reason TEXT,
  closed_at TEXT,
  created_by INTEGER REFERENCES users(id),
  updated_at TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  updated_by INTEGER
);
CREATE INDEX IF NOT EXISTS idx_qtasks_status_due ON quality_tasks(status, due_date);
CREATE INDEX IF NOT EXISTS idx_qtasks_source      ON quality_tasks(source_kind, source_id);
CREATE INDEX IF NOT EXISTS idx_qtasks_assignee    ON quality_tasks(assigned_to, status);

CREATE TABLE IF NOT EXISTS quality_task_evidence (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES quality_tasks(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,                    -- photo|pdf|document|lab_result|comment
  local_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  mime_type TEXT,
  size_bytes INTEGER,
  sha256 TEXT,
  caption TEXT,
  uploaded_by INTEGER REFERENCES users(id),
  uploaded_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_qevidence_task ON quality_task_evidence(task_id, uploaded_at);

CREATE TABLE IF NOT EXISTS quality_task_events (   -- append-only: timeline
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES quality_tasks(id) ON DELETE CASCADE,
  action TEXT NOT NULL,
  from_status TEXT,
  to_status TEXT,
  reason TEXT,
  actor_id INTEGER REFERENCES users(id),
  actor_name TEXT,
  occurred_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_qevents_task ON quality_task_events(task_id, id);
```

**حالات Workflow** (§9 الأصلي): `new · in_progress · waiting_verification · rejected · completed · closed`.

**Overdue محسوب، لا مخزَّن** — تماماً كما نصّت الخطة الأصلية:

```sql
due_date < date('now') AND status NOT IN ('completed','closed')
```

**تحذير مهم:** لا تُضِف `quality_*` إلى `syncedTables` (`database_helper.dart:566-583`). تلك القائمة تضيف `remote_version` و `remote_synced_at` و `sync_state` و `deleted_at` لكل جدول فيها.

## 5.2 Evidence = ملف device-local + صف بيانات وصف

- **البايتات** → `<orgRoot>/evidence/<yyyy>/<mm>/<sha256>.<ext>` عبر `AppPaths.evidenceDirFor()` جديدة (على نمط `backupsDirFor()` في `app_paths.dart:105`).
- **الصف** يخزّن path + name + mime + size + sha256 + من + متى. **البايتات لا تدخل حمولة مزامنة أبداً** ⇒ حد 900KB في `push_worker` وحد 1MiB في Firestore لا يُقربان. رفع Storage لاحقاً = عمود جديد، ليس migration.
- `image_picker` على mobile، `file_picker` على desktop، خلف واجهة واحدة `EvidencePicker`.
- بايتات غير متاحة تُعرض كحالة صريحة "الملف غير على هذا الجهاز" — **أبداً** tap مكسور.
- `sha256` يمنع الازدواج: نفس الشهادة المرفوعة مرتين = مرجع واحد.

## 5.3 سجل التدقيق يصبح system-wide

**الحقيقة:** `AuditLogger` فيه **16 action مُعلَنة، 5 مُفعَّلة فقط**، و `reference_materials` و `parameters` و `lab_units` وكل lab config و inventory و settings **غير مُسجَّلة إطلاقاً**.

**الآلية موجودة بالفعل** — `AuditLogger.log(txn, action:, entityType:, entityId:, details:)` في نفس الـ transaction (`audit_logger.dart:57`). هذا **توصيل، لا معمارية جديدة**:

1. لفّ مسارات الكتابة غير المُسجَّلة: `ReferenceRepo` (materials/parameters/units)، lab-config CRUD في `LabRepo` + `adjustStock`، `SettingsRepo`، `BackupManager`.
2. أضف Quality actions إلى `AuditAction` (`audit_logger.dart:11-28`).
3. `quality_task_events` = timeline لكل مهمة. `audit_logs` = السجل المؤسسي. **نطاقان مختلفان، كلاهما مطلوب** — لا تدمجهما.

**تحذيران موجودان في الكود:**

- `audit_logger.dart:106-116` فيه `assert` **يفشل بصوت عالٍ** إذا تجاوز الـ payload أي مفتاح خارج العشرة المسموحة في الـ rules. الـ actions الجديدة تُخزَّن في `action` (نص حر) — آمنة.
- `audit_logger.dart:129-138` إخفاء الأسرار **أعلى مستوى فقط، غير recursive**. لا تضع بيانات متداخلة حساسة في `details_json`.

## 5.4 الصلاحيات

وسّع `permissions.dart` **و** `firestore.rules` معاً — `permissions_parity_test.dart` يقارن القوائم حرفياً ويفشل عند تعديل جانب واحد.

جديدة: `quality.read · quality.write · quality.verify · quality.manage`

| Role | read | write | verify | manage |
|---|:--:|:--:|:--:|:--:|
| admin | ✔ | ✔ | ✔ | ✔ |
| quality_manager | ✔ | ✔ | ✔ | ✔ |
| lab | ✔ | ✔ | | |
| viewer | ✔ | | | |

## 5.5 إعادة الاستخدام — لا بناء موازٍ

| الحاجة | إعادة الاستخدام |
|---|---|
| assignee / reviewer / actor | جدول `users` |
| الوحدات | `lab_units` (§4.1) |
| تفويض الكتابة | `WriteGuard.allows()` (`member_write_guard.dart:64`) |
| التدقيق | `AuditLogger` |
| المرفقات | **جديد — لا يوجد شيء لإعادة استخدامه** (مؤكد: لا جدول attachments؛ `inspections.last_pdf_path` cache يُفرَّغ عند كل تعديل) |
| القوائم/النماذج/الشارات | `AppPaginatedTable`, `AppCard`, `AppField`, `AppStatusBadge`, `AppEmptyState` |
| التنبيهات | استعلامات مشتقّة — لا push، ولا OS notifications في v1 |

## 5.6 مسار التحقق

`in_progress → waiting_verification → completed → closed`، مع `rejected → رجوع للمالك + سبب إلزامي`.

**مفروض في طبقة domain باختبارات unit**، لا في الـ widget.

## 5.7 مصيدة التخطيط

كل شيء في `lib/features/quality/{data,domain,presentation}/`.

**`lib/features/quality/equipment/data/` يُرفض** بواسطة `repository_boundary_test.dart:236` — لأن الفحص يأخذ `parts.sublist(3).first` ويجب أن يكون في {`data`, `domain`, `presentation`, `core`}. استخدم بادئات في أسماء الملفات:

```
lib/features/quality/domain/quality_task.dart
lib/features/quality/domain/quality_task_status.dart
lib/features/quality/data/quality_repo.dart
lib/features/quality/data/quality_task_evidence_store.dart
lib/features/quality/presentation/quality_tasks_screen.dart
lib/features/quality/presentation/quality_task_detail_screen.dart
lib/features/quality/presentation/cubit/quality_cubit.dart
```

**Acceptance:** analyze 0 · tests خضراء (بما فيها اختباري المعمارية + parity) · مهمة تُنشأ، تُسند، تُعطى evidence، تُقدَّم، تُرفض، تُصحَّح، تُتحقق، تُغلق — مع الـ timeline كاملاً ظاهراً.

**Commit:** `quality-core`

---

# 9) المرحلة 6 — ميزات الجودة

كل ميزة commit واحد، وتُجتاز النقاط العشر من §35.

| # | الميزة | جداول | ملاحظات |
|---|---|---|---|
| 6.1 | **Quality Objectives** (§12) | `quality_objectives` | أول مستهلك لـ Quality Core. `title · target · owner · reviewer · due`. الإجراءات = `quality_tasks` بـ `source_kind='objective'` |
| 6.2 | **Equipment** (§13) | `equipment`, `equipment_calibrations`, `equipment_maintenance` | المعايرة **تاريخ** لا عمود "آخر معايرة". الحالة مشتقّة من `next_calibration_date` + `frequency_days` ⇒ `Current / Due Soon / Overdue` |
| 6.3 | **Equipment alerts** (§14) | — | استعلام مشتق. **لا** عمود مُعلَّم، **لا** OS push |
| 6.4 | **Checklists** (§15-17) | `checklists`, `checklist_items`, `checklist_runs`, `checklist_run_items` | `daily / weekly / monthly` فقط. **لا** custom scheduler في v1 |
| 6.5 | **أنواع الإجابة** (§16) | — | `yes_no · numeric · choice · text · photo`. الرقمي يستخدم `lab_units` (§4.1) |
| 6.6 | **التذكيرات** (§18) | `checklist_run_reminders` | لكل مستخدم، لكل دورة، تختفي عند التنفيذ |
| 6.7 | **نقطة فاشلة → Quality Action** (§19) | — | النقطة الفاشلة تنشئ صف `quality_tasks` بـ `source_kind='checklist'`. **نفس النواة، لا نظام جديد** |
| 6.8 | **Non-Conformity** (§20-23) | `non_conformities` | `problem · immediate_correction · root_cause · corrective_action · preventive_action`. السبب الجذري **حقل نصي واحد** — لا 5-Why، لا Fishbone (§22) |
| 6.9 | **CAPA** (§23) | — | الإجراءات التصحيحية **هي** `quality_tasks`. لا نظام tasks موازٍ |
| 6.10 | **Customer Complaints** (§24-26) | `complaints` | ربط **بالبيانات القائمة** بالمرجع لا بإعادة إدخال: `sample_id → inspections.id`، `product_id → lab_products.id`. المنتج والـ batch اختياريان ليتمكن نشاط غير تصنيعي من فتح شكوى |
| 6.11 | **Notification Center** (§27) | — | شاشة استعلامات مشتقّة واحدة: overdue, due today, waiting verification, calibration due, open NC, open complaints. كل صف deep-link للعنصر المصدر |
| 6.12 | **Quality Dashboard** (§28) | — | عدّادات فقط. الرسوم لاحقاً، على بيانات حقيقية |

**بوابة كل ميزة (§35):** Windows · Android · بيانات قديمة · إنشاء · تعديل · حذف (إن كان مسموحاً) · الصلاحيات · المرفقات · التنبيهات · الرجوع للشاشة السابقة.

---

# 10) المرحلة 7 — التنقل، الداشبورد، الإطلاق

## 7.1 دمج الـ Sidebar (§31)

Desktop: `Dashboard · Inspections · Lab · Reference · Quality · Reports · Settings`

**Quality مدخل واحد** بتبويبات فرعية (Objectives · Tasks · Checklists · Equipment · NC/CAPA · Complaints · Notifications) — **لا** سبعة عناصر علوية.

Mobile bottom bar: `Home · Tasks · Quality · Equipment · More`

## 7.2 قاعدة UX (§32) — مفروضة كـ widget test

كل شاشة جودة تجيب في أول viewport عن: ماذا حدث · ماذا أفعل · ماذا ينتظر مني.

مثال: `Calibration overdue → Open Equipment → Upload Certificate → Submit → Waiting Verification` — **بدون** المرور بخمس قوائم.

## 7.3 الانحدار الكامل (§36)

المصفوفة الكاملة، منصتين، على بيانات قديمة حقيقية:

```
Existing Material Module      PASS
Existing Sample Module       PASS
Existing Lab Module          PASS
Existing Reports             PASS
Existing Authentication      PASS
Existing Settings            PASS
Quality Feature              PASS
Windows                      PASS
Android                      PASS
```

أي فشل في وظيفة قديمة يمنع اعتبار المرحلة مكتملة.

## 7.4 الإطلاق

```bash
flutter build windows --release
flutter build apk --release
```

كلاهما مثبَّت ومُختبر على جهاز حقيقي.

## 7.5 التوثيق

`README.md` **ما زال يقول "Flutter Desktop"** ويسرد `printing` و `qr_flutter` — ولا واحد منهما في `pubspec.yaml`. صحّحه.

وسّع `test/manual/v1_acceptance_checklist.md` الموجود — **لا** أنشئ checklist موازياً.

---

# 11) Backlog — صريحاً خارج v1

من §39 الأصلي، بلا تغيير:

AI Quality Assistant · Advanced Risk Management · 5 Why Wizard · Fishbone Builder · Advanced Supplier Scoring · Advanced Analytics · Automatic Root Cause Suggestions · Complex Workflow Designer · Advanced Automation Rules

**مضاف من هذا التدقيق:**

| البند | لماذا مؤجَّل |
|---|---|
| Evidence storage upload | المخطط يسمح به (عمود واحد). Evidence device-local كافٍ للإصدار الأول |
| Custom checklist scheduler | §17 تمنعه صراحة |
| حذف `lab_material_analyses` / `lab_product_analyses` | بعد إصدار واحد كمسار رجوع |
| دمج `parameters.unit` في `lab_units` | ما زال قاموسين منفصلين |
| OS-level push notifications | التنبيهات داخل التطبيق فقط |
| توحيد استيرادات `sqflite` | 7 ملفات تستورد `sqflite_common_ffi` بلا شرط |

---

# 12) تدرّج Root Cause — §22

النسخة الأولى: `Root Cause` كحقل نصي واحد. يُضاف لاحقاً كـ**مكوّن داخل الـ investigation view** — لا ككيان جديد، لأن `non_conformities` يملك حقول `root_cause` و `corrective_action` و `preventive_action` بالفعل. 5-Why و Fishbone presentation فقط.

---

# 13) تسلسل الـ Commits

```
v2-baseline (tag)
  → add-android-platform
  → responsive-shell
  → responsive-dashboard → responsive-inspections → responsive-inspection-detail
  → responsive-inspection-form → responsive-lab → responsive-run-test
  → responsive-test-history → responsive-reference → responsive-reports
  → responsive-settings → responsive-members → responsive-audit-sync
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

قاعدة: commit واحد لكل مرحلة مستقرة. لا amend، لا force-push، ولا دمج عشر ميزات في commit واحد.

---

# 14) تعريف النجاح

1. كل وظائف Material Lab الحالية تعمل بلا فقدان — الـ regression matrix (§36) خضراء بالكامل.
2. `flutter analyze` = 0 و `flutter test` خضراء — **بما فيها** `repository_boundary_test` و `firebase_isolation_test` و `permissions_parity_test`.
3. التطبيق يبني من repository واحد: `flutter build windows --release` و `flutter build apk --release`.
4. الواجهة تتكيف بلا نسخ business logic — مثال: `saveSample()` واحد، layout مختلف.
5. `Material` / `Product` / أي صنف يُستخدم بلا افتراض صناعة واحدة.
6. كل وحدة في `lab_units` قابلة للتحويل و**مستخدمة فعلياً** من `convertQuantity`.
7. كل Quality Action لها: `Owner · Due Date · Evidence · Verification · History`.
8. كل feature جديدة تبني على الموجود — لا نظام موازٍ واحد.
9. المستخدم يفهم `ماذا حدث / ماذا أفعل / ماذا ينتظر مني` من أول شاشة.

---

## 15) ثلاث نقاط تستحق انتباه قبل التنفيذ

1. **المرحلة 2.1 تغيّر معنى 198 استدعاء ScreenUtil.** الاحتفاظ بـ ScreenUtil قرار صحيح و `.spMax` يجعله آمناً، لكن كل تحويل شاشة في المرحلة 3 هو أيضاً **تراجع بصري**. المرحلة 3 هي المكلفة في هذه الخطة، لا المرحلة 1.

2. **`repository_boundary_test.dart:236` سيرفض تخطيط المجلدات الذي توحي به الخطة الأصلية.** Quality يجب أن يكون `lib/features/quality/{data,domain,presentation}/` ببادئات في أسماء الملفات، لا مجلدات فرعية لكل ميزة. فخ سهل، وفشله صامت.

3. **§8 في الخطة الأصلية كان يفترض نظام وحدات صالحاً لإعادة استخدامه. هو غير صالح.** الخطوة الأولى هي إصلاحه، وبعدها فقط يسري القاعدة.
