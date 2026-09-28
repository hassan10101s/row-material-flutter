# Material Lab — V2 Architecture Plan
## Organization + Google/Firebase Auth + Offline-First Sync + Repository Seam

> **هذه الوثيقة هي الخطة التنفيذية النشطة للنسخة الثانية (V2).**
> الوثيقة السابقة (ترحيل Python → Flutter + تدقيق منطق الأعمال) مكتملة ومؤرشفة في
> `PLAN_V1_PORT_DONE.md`. كل إصلاحاتها التسعة مُنفَّذة ومغطاة باختبارات في `test/rules/*`.
>
> **المرجع الأصلي لهذه الخطة:** وثيقة "Material Lab — خطة التنفيذ المعمارية" (V1 Architecture)
> المقصودة بـ Flutter Desktop + SQLite + Firebase + Offline First.
> هذه الوثيقة هي **التنفيذ الدقيق** لذلك التصميم على الكود الموجود فعلياً، مع إغلاق
> الفجوات التي يمنعها الواقع التقني (انظر §3 و §9.4 و §10.7).

---

## 0) كيف تُنفَّذ هذه الخطة (منهجية الإلزام)

1. **مرحلة واحدة في كل مرة.** لا تبدأ مرحلة قبل اجتياز بوابة Acceptance الخاصة بها.
2. **بوابة إلزامية في كل مرحلة:**
   ```powershell
   flutter analyze      # 0 errors
   flutter test         # كل الاختبارات خضراء
   ```
3. **Commit واحد لكل مرحلة** برسالة واحدة واضحة. لا amend ولا force-push.
4. **لا بيانات حقيقية قبل P4.** Firestore Security Rules تُنشر وتُختبر قبل أول سجل إنتاجي.
5. **عند فشل أي بوابة:** ارجع للمرحلة، لا تتجاوزها بـ "حل مؤقت".
6. **كل تعديل على قاعدة البيانات المحلية يجب أن يكون داخل معاملة (transaction) واحدة**
   مع الإضافة إلى `sync_queue` — لا استثناء (§10.2).
7. **لا يُحذف أي سجل مهم.** الحذف = Tombstone (§10.6). النسخ الاحتياطي قبل أي عملية
   تغيّر المخطط (`BackupManager.autoBackup()`موجود ولا يُستدعى عن بُعد قبل P1 مباشرة).

---

## 1) الهدف والمحددود

### 1.1 الهدف
بناء Material Lab كتطبيق Desktop يعمل **Offline First**، يدعم **عدة مؤسسات**
(Organization) و**عدة مستخدمين** بأدوار وصلاحيات، و**عدة أجهزة** (جهاز تشغيل +
أجهزة Dashboard للقراءة)، مع **تسجيل دخول Google عبر Firebase**، ومزامنة
تلقائية، وطبقة **Repository** هي نقطة الفصل الوحيدة التي تسمح لاحقاً بالانتقال
إلى **Django + PostgreSQL** دون إعادة بناء الواجهة أو النطاق.

### 1.2 Definition of Goal (ما يعنيه "نجح")
- مستخدم واحد (UID) ↔ مؤسسة واحدة ↔ عدة أجهزة.
- كل كتابة تُحفظ في SQLite **أولاً** وتظهر في الواجهة فوراً، ثم تُدفع لـ Firestore.
- انقطاع الإنترنت لا يمنع أي عملية على بيانات المختبر، ولا يمنع إعادة فتح التطبيق.
- جهاز Dashboard يعرض آخر بيانات متاحة ( sync ) ولا يعرض أي زر كتابة.
- **لا يمكن** لأي مستخدم (مهما عدّل طلبه يدوياً) قراءة/كتابة بيانات مؤسسة أخرى.
- استبدال `FirestoreSampleDataSource` بـ `DjangoSampleDataSource` لاحقاً = تغيير
  ملف واحد مسجَّل في GetIt، بلا تعديل UI.

### 1.3 خارج النطاق (V1)
- تطبيق Web / Mobile (المسار المعماري له جاهز، التنفيذ لاحقاً).
- تعديل **`role → permissions` من داخل التطبيق** (V1: الخريطة ثابتة في `permissions.dart` وفي `firestore.rules` ومتسقة باختبار).
- مصادقة بدون Google (لا يوجد زر "دخول محلي").
- ترحيل بيانات من الـ DB القديم عبر `pullUsersFromSourceDb` (الogprimitiveهوية أصبحت_remote) — انظر §14-P1.
- Cloud Functions / Cloud Run / Redis / Celery (V2/V3).
- تعديل الفيزياء/الكيمياء/Reports/QR (سلوكها كما هو ولا يُمس).

---

## 2) القرارات المُثبَّتة (لا تُفتح للنقاش أثناء التنفيذ)

| # | القرار | السبب |
|---|---|---|
| D1 | الخطة في ملف جديد، والقديمة مؤرشفة | الخطة القديمة منتهية (مُنفَّذة)؛ خلطها بالجديدة يُفسد المرجعية |
| D2 | **حذف تسجيل الدخول المحلي بالكامل** (PBKDF2 + `password_hash` + `usage_expiry_date` seal + `setup_screen`) | هويّة واحدة فقط = Google/UID ⇒ لا يمكن تجاوز قواعد المؤسسة. ملاحظة: `seal_codec.dart` + `local_secret.dart` **يبقيان** (يستخدمهما QR) |
| D3 | **قاعدة بيانات واحدة لكل مؤسسة**: `%APPDATA%\MaterialLab\orgs\<orgId>\material_lab.db` | صفر تعديل على الـ 20 جدول وعلى ~60 موضع كتابة، وعزل فيزيائي (جهاز Dashboard لا يستطيع أصلاً فتح ملف مؤسسة أخرى)، ونسخ احتياطي مستقل |
| D4 | الـ Invitation يُخزَّن **مفتاحه=B(email)**، والـ UID يُربط عند أول دخول |التضارب: الـ UID غير موجود قبل أول تسجيل دخول؛ حلّ يحترم نص خطتك (`status: invited`) دون Cloud Functions |
| D5 | Firebase على Windows رغم أنه **beta رسمياً** | مع قيود صريحة: لا `runTransaction`، لا اعتماد على كاش Firestore، و`RemoteDataSource` هو الملف الوحيد الذي يعرف Firebase |
| D6 | سجل واحد (Sync Entity) لكل جدول منظم في `entity_registry.dart` | إضافة أي جدول للمزامنة لاحقاً = سطر واحد في السجل، بلا مساس بالمحرك |
| D7 | **نطاق V1 للمزامنة = النطاق الأساسي + إعدادات المختبر** (§6.3) | satisfies طلبك "Core + lab config" |
| D8 | كل استعلامات الترشيح/الترتيب/البحث تبقى في **SQLite**؛ Firestore هدف نسخ فقط | تقليل التكلفة + استبعاد الحاجة لـ composite indexes معقّدة + احترام "لا تحميل كل البيانات" |

---

## 3) حقائق مُتحقَّق منها (ليست افتراضات)

| الحقيقة | المصدر/الدليل | أثرها على التنفيذ |
|---|---|---|
| `google_sign_in` 7.2.0 **لا يدعم Windows**، و`google_sign_in_windows` غير موجود على pub.dev | pub.dev API: منصات `android,ios,macos,web` | **لا تستخدم** `google_sign_in` المنطقيمباشرة على Windows |
| المسار الرسمي الوحيد لـ Google Sign-In على Windows هو `google_sign_in_dartio ^0.3.0` (نفس ما يستخدمه example الخاص بـ `firebase_auth`) | pub.dev `google_sign_in_dartio` + `firebase_auth/example/lib/main.dart` | P1/§4.3 |
| `firebase_auth` يدعم Windows (C-API) وGoogle Sign-In منذ 4.14.0 | firebase_auth changelog + `pluginClass: FirebaseAuthPluginCApi` | تسجيل الدخول ممكن |
| `runTransaction()` **يُسقط التطبيق على Windows** بعد أي `.get()` | flutterfire issue #13177 | **ممنوع** في كل كود المشروع؛ التعارض يُحل بـ `version` + Rules |
| Firebase على Windows = **beta**، ووثائق Google تقول غير مقصود للإنتاج | firebase.google.com/docs/flutter/setup | D5 + §17 |
| `google_sign_in 6.3.0` و`firebase_auth 5.2.0` موجودة في Pub Cache؛ `cloud_firestore` و`google_sign_in_dartio` تحتاج تنزيل (الإنترنت متاح ✓) | `$env:LOCALAPPDATA\Pub\Cache` + `pub.dev/api` | `pub get` سيعمل |
| Flutter 3.44.8 / Dart 3.12.2 · VS 2022 **17.12.1** (شرط Windows 17.12 ✓) · Java 23 · Node 22 · `firebase` CLI 15.22.1 | `flutter doctor -v`, `java -version`, `firebase --version` | كل الأدوات المطلوبة موجودة؛ Firestore Emulator قابل للتشغيل |
| مشروع Firebase `materiallab-63405` يستخدم **Google Auth بالفعل** (صفحة الهبوط) | `material lab page/src/services/auth.js:53-68` | مزوّد Google مفعّل مسبقاً ✓ |
| الـ DB الحالي في `%APPDATA%` وليس OneDrive ✓ | `lib/core/app_paths.dart:16-20` + `path_provider_windows` | لا تعديل |
| التطبيق **غير منشور** (لا مستخدمين حقيقيين بعد) | طلبك | الهوية والمؤسسة تبدأان من الصفر على ملف جديد؛ لا مسار نقل بيانات من الـ DB القديم |
| `String.lower()` و`Map.diff()` و`get()`/`getAfter()` متاحة في Rules | firebase.google.com/docs/reference/rules | الـ rules في §11 صحيحة نحوياً |
| 76 استدعاء `getIt<>` داخل طبقة العرض، و~8 ملفات Widget تستدعي `getIt<Repo>()` وتكتب مباشرة | تقرير الاستطلاع | الحل: **Facade** بنفس الأسماء (§14-P5) ⇒ صفر تعديل في 30 Cubit و8 Widgets |

---

## 4) P0 — متطلبات مسبقة (تنفيذ أنت، قبل أي كود)

> **لا يوجد استثناء لـ P0.** بدون Firebase OAuth Client ID لن يفتح Dialog تسجيل الدخول.

### 4.1 Firebase Console (مشروع `<YOUR_PROJECT_ID>`)
| # | الخطوة | تحقّق |
|---|---|---|
| 1 | **Firestore Database → Create database** (Native، نفس region لـ Storage) | يظهر `firestore.googleapis.com` في Project |
| 2 | **Authentication → Sign-in method → Google = Enabled** (مُفعّل مسبقاً — تأكّد فقط) | الحالة "Enabled" |
| 3 | **نسخ Web OAuth Client ID**: Project settings → General → **Your apps → Web app → SDK setup and configuration** | قيمة تنتهي بـ `.apps.googleusercontent.com` |
| 4 | **إنشاء `Desktop app` OAuth client** في Google Cloud Console → Credentials → OAuth client ID → Application type: **Desktop app**، ثم إضافة `http://127.0.0.1` إلى Authorized redirect URis | **هذه هي قيمة `GOOGLE_DESKTOP_CLIENT_ID` وهي الواجبة فعلاً.** الـ Web client id لا يصلح للتسجيل: تدفّق Windows loopback يرسل `http://127.0.0.1:<port عشوائي>`، وGoogle يتجاهل الـ port فقط لعملاء `Desktop app` (RFC 8252 §7.3) ⇒ `400: redirect_uri_mismatch` مع أي Web client |
| 5 | **Billing → Budget alerts**: حدّ 50 USD، تنبيه 50% و90% | Guard للتكلفة |
| 6 | **Google Cloud Console → OAuth consent screen**: External + اختبار/إنتاج حسب الحالة | بريدك مضاف كـ Test user إن كانت الشاشة External بحالة Testing |

### 4.2 القيم التي سأبنيها منها ملفات المشروع
```
FIREBASE_API_KEY           = <YOUR_FIREBASE_API_KEY>
FIREBASE_PROJECT_ID        = <YOUR_PROJECT_ID>
FIREBASE_AUTH_DOMAIN       = <YOUR_AUTH_DOMAIN>
FIREBASE_STORAGE_BUCKET    = <YOUR_STORAGE_BUCKET>
FIREBASE_MESSAGING_SENDER_ID = <YOUR_SENDER_ID>
FIREBASE_APP_ID            = <YOUR_APP_ID>
GOOGLE_WEB_CLIENT_ID       = <من خطوة 3 — للتشغيل على الويب فقط>
GOOGLE_DESKTOP_CLIENT_ID   = <من خطوة 4 —Required لتسجيل دخول Windows>
```
> `VITE_MEASUREMENT_ID` تُتجاهل: `firebase_analytics` غير مطلوب في V1.
> **لا يوجد Secret في التطبيق**: `API_KEY` مفتاح عميل عام (يُقيَّد بـ Security Rules + App Check لاحقاً)؛
> كل شيء يُمرَّر عبر `--dart-define` ولا يُكتب في Git.

### 4.3 أوامر التهيئة (أُنفِّذها أنا بعد P0)
```powershell
flutter pub add firebase_core firebase_auth cloud_firestore `
  google_sign_in:^6.3.0 google_sign_in_dartio:^0.3.0 `
  connectivity_plus device_info_plus uuid
firebase use --add            # project id: materiallab-63405
firebase deploy --only firestore:rules,firestore:indexes
```

---

## 5) المعمارية المستهدفة

```
┌───────────────────────────────────────────────────────────────────────┐
│ Presentation  (screens · cubits · widgets)                             │
│   لا يستورد أي data source · لا يعرف شيئاً عن Firebase               │
└───────────────────────────────┬───────────────────────────────────────┘
                                │  domain interfaces (abstract)
┌───────────────────────────────▼───────────────────────────────────────┐
│ Repositories (abstract)                                                │
│  AuthRepository · OrganizationRepository · MemberRepository            │
│  SampleRepository · LabResultRepository · QualityCheckRepository        │
│  AuditRepository · DeviceRepository · SyncRepository                    │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│ OfflineFirst*Repository   (المكان الوحيد الذي يقرر: محلي أم سحابي)     │
└──────┬─────────────────────────────────────────────┬──────────────────┘
       │                                             │
┌──────▼─────────────────────┐        ┌──────────────▼──────────────────┐
│ LocalDataSource (SQLite)   │        │ RemoteDataSource (Firestore)    │
│  = الـ repos الحالية كما هي│        │  lib/core/sync/remote/**        │
│  بلا أي سطر جديد في SQL    │        │  **الملف الوحيد** الذي يستورد    │
└──────┬─────────────────────┘        │  cloud_firestore                 │
       │                              └──────────────┬──────────────────┘
       │                                             │
┌──────▼─────────────────────────────────────────────▼──────────────────┐
│ SQLite (مصدر الحقيقة المحلي)      │      Sync Engine + Sync Queue     │
│  + sync_queue · sync_metadata ·   │      (دفع/سحب/تعارض/إعادة محاولة) │
│    sync_conflicts · audit_logs     │                                    │
└────────────────────────────────────────────────────────────────────────┘
```

### 5.1 ممنوعات مُلزِمة (مراجعة + اختبار آلي)
```
❌ FirebaseFirestore.instance / FirebaseAuth.instance خارج lib/core/sync/remote/
❌ db.insert/update/delete من أي Widget أو Cubit
❌ استيراد data source في presentation/
❌ runTransaction على Firestore (يسقط على Windows)
❌ إرسال organizationId من العميل كمرجع للثقة (يُشتق من path + Rules)
❌ حذف نهائي لأي سجل (Tombstone فقط)
❌ قراءة/كتابة Firestore بدون permissions check محلي أولاً
```
**التنفيذ:** `test/architecture/firebase_isolation_test.dart` يمسح `lib/` ويفشل إن ظهر
`package:cloud_firestore` أو `package:firebase_auth` خارج `lib/core/sync/remote/`
(باستثناء `lib/core/firebase/firebase_bootstrap.dart` المسموح بالـ initializeApp).

### 5.2 شجرة المجلدات الجديدة
```
lib/
├── core/
│   ├── firebase/
│   │   ├── firebase_options.dart          # جديد: من --dart-define + fail-fast
│   │   └── firebase_bootstrap.dart        # جديد: initializeApp + result صريح
│   ├── network/
│   │   └── connectivity_service.dart      # جديد: online/offline stream
│   ├── auth/
│   │   ├── permissions.dart              # جديد: Permission + rolePermissions()
│   │   ├── app_session.dart               # جديد: كيان الجلسة
│   │   └── session_store.dart             # جديد: كاش آمن في flutter_secure_storage
│   ├── database/
│   │   ├── database_helper.dart           # تعديل: org binding + جداول المزامنة
│   │   └── org_database_provider.dart    # جديد: يربط orgId بالـ DB
│   └── sync/
│       ├── entity_registry.dart           # جديد: تعريف الكيانات القابلة للمزامنة
│       ├── sync_queue.dart                # جديد: enqueue/claim/complete/fail
│       ├── sync_metadata.dart             # جديد: cursors + last sync
│       ├── sync_engine.dart               # جديد: المنسّق (مؤقتات + connectivity)
│       ├── push_worker.dart               # جديد
│       ├── pull_worker.dart               # جديد
│       ├── conflict_resolver.dart         # جديد
│       ├── audit_logger.dart              # جديد
│       └── remote/                        # ✅ المسموح الوحيد لـ Firebase
│           ├── firestore_client.dart
│           ├── auth_remote_data_source.dart
│           ├── organization_remote_data_source.dart
│           ├── member_remote_data_source.dart
│           ├── sample_remote_data_source.dart
│           ├── lab_result_remote_data_source.dart
│           ├── quality_check_remote_data_source.dart
│           ├── lab_config_remote_data_source.dart
│           ├── device_remote_data_source.dart
│           └── audit_remote_data_source.dart
├── features/
│   ├── auth/
│   │   ├── domain/          (AppSession, AuthState)
│   │   ├── data/            (auth_repository.dart, offline_first_auth_repository.dart, google_auth_data_source.dart)
│   │   └── presentation/    (login_screen · create_organization_screen · waiting_activation_screen · auth_cubit)
│   ├── organizations/       (domain/organization.dart, data/organization_repository.dart)
│   ├── members/             (domain/member.dart, data/member_repository.dart, presentation/members_screen.dart + cubit)
│   └── sync/                (presentation/sync_status_badge.dart, sync_screen.dart + cubit)
```

---

## 6) نموذج البيانات

### 6.1 Firestore (مبني على خطتك §14 + إصلاح الـ invite)
```
organizations/{orgId}
  ├─ meta                       # مستند واحد: lastWriteAt, lastWriteBy, lastEntity  (نبض Dashboard)
  ├─ invites/{inviteKey}        # {email, role, memberId, status:'invited', invitedBy, invitedByName, createdAt}
  ├─ members/{memberId}         # {uid?, email, displayName, role, status, invitedBy, invitedAt, activatedAt, updatedAt, updatedBy, version}
  ├─ samples/{entryCode}        # inspections → remote id = entry_code
  ├─ qualityChecks/{qcKey}      # inspection_status_history → qc_<inspectionId>_<version>
  ├─ labResults/{ltKey}         # lab_sample_tests → lt_<localId>
  ├─ labConfig/{cfgKey}         # lab_analyses · lab_constants · lab_products · lab_units (D7)
  ├─ devices/{deviceId}         # {name, platform, osVersion, appVersion, role, readOnly, lastSeenAt, lastWriteAt}
  └─ auditLogs/{alKey}          # al_<deviceId>_<epochMs>_<seq>
users/{uid}                     # حسب خطتك §6 حرفياً: email, organizationId, role, status, memberId
```
`inviteKey = base64url_nopad(utf8(email.trim().toLowerCase()))` — حتمي، آمن كـ document id،
ويحسبه جهاز الموظف محلياً ⇒ **لا فهرس بريد عام ولا Cloud Function**.

**مراسلة الكيانات المحلية (بلا تعديل المخطط):**
| المحلي | الجدول | مفتاح المستند البعيد |
|---|---|---|
| عيّنة/فحص | `inspections` | `entry_code` (موجود و UNIQUE) |
| قرار QC | `inspection_status_history` | `qc_<inspection_id>_<version>` |
| نتيجة مختبر | `lab_sample_tests` | `lt_<id>` |
| تحليل/ثابت/منتج/وحدة/ارتباط/مدى | `lab_analyses`, `lab_constants`, `lab_products`, `lab_units`, `lab_field_chemical_links`, `lab_material_analyses` | `lc_<table>_<id>` |
| مستخدم | `users` | `member_<users.id>` |
| سجل تدقيق | `audit_logs` (جديد) | `al_…` |

**حقول النسخة السحابية الإلزامية (خطتك §26):** `createdAt, updatedAt, version, updatedBy, deviceId, organizationId, deletedAt?`.
- `createdAt/updatedAt` = **وقت الخادم** (`FieldValue.serverTimestamp()`) ⇒ لا انحراف ساعات بين الأجهزة، والمؤشر (cursor) موثوق.
- الطابع الزمني المحلي (`inspections.updated_at`) يبقى كما هو للعرض والطباعة (تقرير المختبر).
- `organizationId` يُكتب داخل المستند أيضاً (تطابق خطتك §15/§37-python) **لكنه ليس مصدر ثقة**؛ مصدر الثقة = path + Rules.

### 6.2 Firestore — مخطط `samples` (نموذج كامل)
```json
{
  "organizationId": "ORG_...",
  "entryCode": "SMPL-SOY-20260924-0001",
  "localId": 412,
  "materialId": "SOYBEAN_MEAL", "materialName": "...", "materialCode": "...",
  "inspectionDate": "2026-09-24", "supplier": "...", "truckNumber": "...",
  "quantity": "30", "sampleTakenBy": "...", "specialistName": "...",
  "physicalResultsJson": "{...}", "chemicalResultsJson": "{...}",
  "physicalReferenceJson": "{...}", "chemicalReferenceJson": "{...}",
  "sampleNamesJson": "[...]", "snapshotJson": "{...}", "reportHtml": "<html…>",
  "decisionStatus": "APPROVED", "decisionReason": "", "followUpNote": "",
  "rejectedQuantity": "", "decisionVersion": 3, "expiryDate": null,
  "createdBy": "UID_...", "createdByName": "...",
  "createdAt": "<server ts>", "updatedAt": "<server ts>",
  "version": 4, "updatedBy": "UID_...", "deviceId": "DEV_...",
  "payloadBytes": 84213, "deletedAt": null
}
```
- **حد Firestore 1 MiB:** `reportHtml` هو الحقل الوحيد القابل للتضخم. القاعدة: قبل الـ push،
  إن تجاوز `payloadBytes` **900000** ⇒ يُرفض الصف من المزامنة ويُسجَّل في `sync_conflicts`
  برسالة صريحة (و`report_html` قابل لإعادة التوليد محلياً ⇒ لا فقدان بيانات).
- كل الأرقام/التواريخ المنطقية تُخزَّن كنص/JSON string تماماً كما في SQLite (سلوك التقارير لا يتغير).

### 6.3 نطاق المزامنة المعتمد (D7)
| يُزامن (V1) | يبقى محلياً على كل جهاز |
|---|---|
| `inspections` (samples) · `inspection_status_history` (QC) · `lab_sample_tests` (lab results) · `users` (roster) · `devices` · `audit_logs` · `lab_analyses` · `lab_analysis_items` · `lab_field_chemical_links` · `lab_constants` · `lab_products` · `lab_product_analyses` · `lab_material_analyses` · `lab_units` | `lab_inventory` · `lab_consumption_log` · `lab_stock_adjustments` · `lab_worksheet` · `settings` · كل جداول `sync_*` |
> **لماذا استُثني المخزون:** كل مختبر له مخزون وأرقام خاصة به؛ مزامنته تولّد تعارضات بلا فائدة
> لجهاز Dashboard. التوسعة future = إضافة صف في `entity_registry.dart` فقط.
> `parameters` و`reference_materials` لا تُزامن لأن كل عيّنة تحمل نسخة `*_reference_json` كاملة داخلها.

### 6.4 SQLite — أضف الجداول التالية (DDL حرفي)
```sql
CREATE TABLE IF NOT EXISTS sync_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_type TEXT NOT NULL,            -- اسم من entity_registry
  entity_id TEXT NOT NULL,              -- المفتاح البعيد
  local_ref INTEGER,                    -- id المحلي (nullable لaudit/device)
  operation TEXT NOT NULL,              -- create | update | tombstone
  payload TEXT NOT NULL,                -- JSON كامل للمستند
  base_version INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  retry_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT,
  status TEXT NOT NULL DEFAULT 'pending',  -- pending|in_flight|blocked|failed|conflict
  last_error TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_queue_entity
  ON sync_queue(entity_type, entity_id) WHERE status IN ('pending','in_flight','blocked');
CREATE INDEX IF NOT EXISTS idx_sync_queue_ready
  ON sync_queue(status, next_attempt_at, id);

CREATE TABLE IF NOT EXISTS sync_metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);   -- مفاتيح: device_id, pull_cursor_<entity_type> (JSON {ts, id}),
    -- last_pull_at, last_push_at, last_error, heartbeat_seen_at, org_bound_at

CREATE TABLE IF NOT EXISTS sync_conflicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  direction TEXT NOT NULL,        -- push_rejected | remote_newer | payload_too_large
  local_payload TEXT,
  remote_payload TEXT,
  detected_at TEXT NOT NULL,
  resolution TEXT,                -- null | keep_local | keep_remote
  resolved_at TEXT
);

CREATE TABLE IF NOT EXISTS device_registry (
  id TEXT PRIMARY KEY,            -- deviceId (UUID v4)
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  os_version TEXT,
  app_version TEXT,
  role TEXT NOT NULL,
  read_only INTEGER NOT NULL DEFAULT 0,
  registered_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  last_write_at TEXT
);

CREATE TABLE IF NOT EXISTS audit_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT, user_name TEXT, organization_id TEXT NOT NULL,
  action TEXT NOT NULL,                    -- SAMPLE_CREATED · QC_APPROVED · MEMBER_INVITED …
  entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
  details_json TEXT,
  device_id TEXT NOT NULL,
  occurred_at TEXT NOT NULL,               -- وقت محلي ISO
  synced INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_logs(entity_type, entity_id, id);
```

### 6.5 SQLite — أعمدة تُضاف للجداول المُزامَنة
لكل جدول في §6.3 أضف (عبر `_ensureColumn` الموجودة في `database_helper.dart:470`):
```sql
remote_version INTEGER NOT NULL DEFAULT 0,
remote_synced_at TEXT,
sync_state TEXT NOT NULL DEFAULT 'local',   -- local|queued|synced|conflict
deleted_at TEXT                             -- Tombstone (NULL = حيّ)
```
> **لا يُضاف عمود `organization_id` لأي جدول** — العزل فيزيائي (D3). يُستعمل `organizationId`
> من الجلسة فقط عند البناء/الاستقبال.

### 6.6 SQLite — إعادة بناء جدول `users` مرة واحدة (D2 + roster)
`users` كان جدول بيانات دخول بـ `password_hash TEXT NOT NULL` (لا يمكن تخفيف NOT NULL بـ ALTER).
نستخدم نفس نمط إعادة البناء الموجود أصلاً في `database_helper.dart:424-446`:
```sql
CREATE TABLE users_new (
  id INTEGER PRIMARY KEY,                  -- لم يعد AUTOINCREMENT: id =محلي ثابت داخل الجهاز
  uid TEXT UNIQUE,                         -- Firebase UID (NULL حتى أول ربط)
  email TEXT NOT NULL,
  full_name TEXT NOT NULL,
  role TEXT NOT NULL,                      -- admin|quality_manager|lab|viewer
  status TEXT NOT NULL,                    -- invited|active|disabled
  permissions_json TEXT NOT NULL DEFAULT '[]',
  display_name TEXT, photo_url TEXT,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL, updated_by TEXT,
  remote_version INTEGER NOT NULL DEFAULT 0,
  remote_synced_at TEXT, sync_state TEXT NOT NULL DEFAULT 'local',
  deleted_at TEXT, created_at TEXT NOT NULL
);
INSERT INTO users_new (id, email, full_name, role, status, created_at)
  SELECT id, username, full_name,
         CASE role WHEN 'Admin' THEN 'admin' WHEN 'Lab User' THEN 'lab' ELSE 'viewer' END,
         CASE is_active WHEN 1 THEN 'active' ELSE 'disabled' END,
         created_at
  FROM users;
DROP TABLE users; ALTER TABLE users_new RENAME TO users;
```
- `inspections.created_by INTEGER` و`inspection_status_history.changed_by INTEGER` **يبقيان كما هما**
  (FK صحيح + ترقية بلا مساس بـ 60 موضع كتابة). الـ `updatedBy` البعيد يُشتق من `users.uid`.
- **Gate بـ `PRAGMA foreign_keys=OFF` داخل معاملة** ثم `integrity_check` ثم إعادة تفعيل (§14-P1).

---

## 7) الأدوار والصلاحيات

### 7.1 المصفوفة (الوحيدة المعتمدة — خطتك §13)
| Permission | admin | quality_manager | lab | viewer |
|---|:--:|:--:|:--:|:--:|
| `org.read` | ✔ | ✔ | ✔ | ✔ |
| `org.update` | ✔ | | | |
| `users.read` | ✔ | ✔ | | |
| `users.create` | ✔ | | | |
| `users.update` | ✔ | | | |
| `users.disable` | ✔ | | | |
| `samples.read` | ✔ | ✔ | ✔ | ✔ |
| `samples.create` | ✔ | ✔ | ✔ | |
| `samples.update` | ✔ | ✔ | ✔ | |
| `lab_results.read` | ✔ | ✔ | ✔ | ✔ |
| `lab_results.create` | ✔ | ✔ | ✔ | |
| `lab_results.update` | ✔ | ✔ | ✔ | |
| `qc.read` | ✔ | ✔ | | ✔ |
| `qc.approve` | ✔ | ✔ | | |
| `qc.reject` | ✔ | ✔ | | |
| `reports.read` | ✔ | ✔ | ✔ | ✔ |
| `reports.create` | ✔ | ✔ | | |
| `reports.export` | ✔ | ✔ | | |
| `devices.read` | ✔ | | | |
| `devices.register` | ✔ | ✔ | ✔ | ✔ |
| `audit.read` | ✔ | ✔ | | |
> `admin` = `ALL` (خطتك §13) — ويُقصد به "كل ما ورد أعلاه" وليس صلاحية جذرية مفتوحة.
> **لا يوجد `*` حرف حرفي** — كل permission تُعدّدة صريحة في Dart وفي Rules (أمان).

### 7.2 مكان التعريف (مصدران + اختبار تطابق)
- `lib/core/auth/permissions.dart` → `rolePermissions(role) : Set<Permission>`
- `firestore.rules` → `function rolePermissions(role)` (نفس القوائم حرفية)
- `test/security/permissions_parity_test.dart` → يقرأ `firestore.rules` كنص ويستخرج
  القوائم ويقارنها بـ Dart ⇒ **اختبار يمنع انحراف الإذن بين العميل والسيرفر**.
- **لا يُكتب `permissions` في المستند** (غير قابل للتصعيد من العميل)؛ يُشتق من `role` في كلي الطرفين.

### 7.3 إعادة ربط موجودة التطبيق (بلا تعديل شاشة واحدة)
`lib/features/auth/domain/user.dart:21-28` يحوي `isDeveloper / canManageSettings /
canEditInspections / canCreateInspection / canEditUsers / canSeeSettings` — تُعاد كتابة أجسامها:
```dart
bool get canSeeSettings   => permissions.contains(Permission.usersRead);
bool get canEditInspections => permissions.contains(Permission.samplesUpdate);
bool get canCreateInspection => permissions.contains(Permission.samplesCreate);
bool get canEditUsers     => permissions.contains(Permission.usersUpdate);
bool get isReadOnly       => !permissions.any((p) => p.writes);
```
- `isDeveloper` **يُحذف** (دور المطور لم يعد موجوداً).
- `lib/core/domain/rules.dart:76-84` (نسخ مكرّرة وميتة) **تُحذف**.
- كل مواضع الاستدعاء القائمة (`app_router.dart:178`, `app_shell.dart:44,250`,
  `inspections_screen.dart:139`, `inspection_detail_screen.dart:131,286`,
  `settings_screen.dart:41,96,450,494,517,528`) تبقى **كما هي** ⇒ صفر تعديل شاشات.
- `roles` القديمة `'Developer'|'Admin'|'Lab User'|'Viewer'` في `settings_repo.dart:134-140`
  و`:142-166` و`:168-192` و`:194-216` **تُحذف كلها** (تُستبدل بـ Members).

---

## 8) تدفقات المصادقة

### 8.1 آلة الحالات (تستبدل `_redirect` في `app_router.dart:165-181`)
```
boot ──► needsBootstrap(Firebase not ready / dart-define ناقص) ──► Settings error screen
      └─► signedOut ──(Google)──► noProfile ──(user.isNew)──► createOrganizationScreen
                                        └─(profile exists)──► awaitingActivation (status != active)
                                                              └─(status==active)──► READY
                                                                              └─ offline & session cache صالح ⇒ READY(offline)
```
- `AuthGate` (`lib/app/auth_gate.dart`) يصير `ChangeNotifier` فوق `AuthRepository` بدل `AuthRepo`.
- `initialLocation` يبقى `/login`؛ `redirect` يُعاد كتابته بالكامل ليحترم Cases أعلاه.
- `SetupScreen` + `SetupCubit/State` **تُحذف**؛ `LoginScreen` = زر Google واحد + 4 حالات عرض
  (idle / signing-in / error / firebase-unavailable) + رابط الدعم الحالي.

### 8.2 Google Sign-In على Windows (التسلسل الدقيق)
```dart
// lib/core/sync/remote/auth_remote_data_source.dart
if (Platform.isWindows) {
  await GoogleSignInDart.register(clientId: const String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID'));
}
final account = await GoogleSignIn().signIn();          // يفتح المتصفح + loopback 127.0.0.1
final credential = GoogleAuthProvider.credential(idToken: account.authentication.idToken);
final cred = await FirebaseAuth.instance.signInWithCredential(credential);  // uid + idToken
```
- **لا نحتاج `exchangeEndpoint`** (مستند الباقة:مع FirebaseAuth يكفي الـ idToken).
- إن فشل بـ `400: redirect_uri_mismatch` ⇒ الـ client id المستخدَم **Web** لا Desktop.
  التدفّق يستمع على منفذ عشوائي (`token_sign_in.dart:29-31,49`) ⇒ لا يمكن مطابقته
  إلا مع عميل `Desktop app` (Google يتجاهل الـ port عند loopback له فقط).
  **الإصلاح**: خطوة 4 في §4.1 ثم تمرير الـ client id في `GOOGLE_DESKTOP_CLIENT_ID`.
- إن فشل بـ `auth/invalid-credential` ⇒ الـ client id ليس من مشروع `materiallab-63405`.
- `signIn` يفتح المتصفح ⇒ **Internet إلزامي عند تسجيل الدخول فقط** (وليس للعمل اليومي).

### 8.3 حلقة Invitation → UID (D4، مطابق لخطتك §8/§9)
```
Admin device : MembersScreen → Add(email, role)
                ├─ local : INSERT users(status='invited', email, role) + enqueue(member create)
                └─ remote: batch { organizations/{o}/members/{memberId}, organizations/{o}/invites/{inviteKey} }
                          memberId = member_<localUserId>  (يولّده Admin جهاز)

Employee dev : Google sign-in → uid
                1) inviteKey = b64url(lower(email))
                2) get organizations/{o}/invites/{inviteKey}   (Rule يسمح فقط لو تطابق البريد)
                   → لا يوجد ⇒ "Access Denied" + audit DENIED_ENTRY (خطتك §9)
                   → موجود  ⇒ organizationId + role + memberId
                3) create users/{uid} {email, organizationId, role, status:'invited', memberId, inviteKey}
                   (Rule يتحقق: الدعوةexist + بريدها = بريد الـ token + role متطابقة)
                4) UI: "Account waiting for activation." (نصّ خطتك §6)
                5) الـ local DB للمؤسسة يُفتح الآن (D3) ⇒ الجهاز جاهز للعمل offline
                   فقط الصلاحيات الممنوحة حتى التفعيل: قراءة فقط ⇒
                   force writes ممنوعة محلياً حتى status=active  (قاعدة أمان §9.4)

Admin device : Activate member
                batch { members/{m}: status='active', activatedAt, version+1,
                        users/{uid}: status='active', version+1 }
                → جهاز الموظف: pull incremental ⇒ يكتسب الصلاحيات ⇒ يكتب
```
> **لماذا `status='invited'` مرفوض الكتابة:** يمنع حساباً أُضيف بخطأ من تلويث بيانات المؤسسة قبل مراجعة الـ Admin.

### 8.4 الجلسة دون إنترنت (ثغرة تُغلق صراحةً)
Google يحتاج إنترنت ⇒ إعادة تشغيل الجهاز بلا إنترنت كانت ستُخرج المستخدم من التطبيق،
وهذا يناقض "Offline First". الحل:
```json
// flutter_secure_storage : ml_session_v2
{ "uid":"…", "email":"…", "organizationId":"…", "memberId":"…",
  "role":"lab", "permissions":["…"], "signedInAt":"…", "idToken":"…", "idTokenExpiresAt":"…" }
```
| الحالة | السلوك |
|---|---|
| دخول بارد + Internet | Firebase يعيد الجلسة ⇒ تُحدَّث الـ cache بـ idToken جديد |
| دخول بارد + Offline | تُفتح جلسة من الـ cache ⇒ التطبيق يعمل كاملاً (قراءة/كتابة المختبر) |
| عملية امتيازية (إدارة مستخدمين / إعدادات مؤسسة / اعتماد QC) | تتطلب `sessionIsFresh` (توكن < 12 ساعة **و** Connectivity online) ⇒ وإلا "أعد الاتصال بالمتصفح" |
| `status != active` |ممنوع حتى online للتأكيد (§8.3) |
| توكن منتهي + Online | silent `getIdToken(true)` ⇒ كل شيء طبيعي |
| Sign out | مسح الـ cache + إغلاق الـ DB + تعطيل Sync Engine |
> **الأمان:** الـ cache لا يمنح صلاحيات جديدة ولا يكتب على Firestore؛ الكتابة عن بُعد
> تبقى **مرفوضة** حتى يخرج توكن صالح (الـ Rules ترفض `auth != null` فقط، وFirestore
> لا يقبل الطلب أصلاً بلا توكن).

### 8.5 إنشاء المؤسسة (أولمُنشئ)
```
Google (لا profile) ─► CreateOrganizationScreen (name, admin display name)
  1) orgId = 'org_' + base32(12 bytes عشوائية)  ⇒ غير قابل للتخمين
  2) batch Firestore:
       organizations/{orgId} {name, ownerUid:uid, status:'active', createdAt, schemaVersion:2}
       organizations/{orgId}/meta  {lastWriteAt:server, lastWriteBy:uid, lastEntity:'org'}
       organizations/{orgId}/members/{member_<uid>} {uid, email, role:'admin', status:'active', ...}
       users/{uid} {email, organizationId:orgId, role:'admin', status:'active', memberId}
  3) محلياً: اربط orgId بالـ DB (§6.5 rebuild) → SettingsRepo.ensureDefaults → SeedService
             → LabRepo.ensureDefaultAnalyses → BackupManager.autoBackup → كتابة sync_metadata.org_bound_at
  4) device_registry: سجّل هذا الجهاز (role=admin, readOnly=0) + doc بالمسار organizations/{o}/devices/{id}
  5) Audit: ORGANIZATION_CREATED
```
**شرط حصريّة العلامة (1:1):** قبل التنفيذ، الاستعلام `organizations where ownerUid == uid`
يُرفض عملياً بـ Rules (لا يمكن قراءة مجموعة `organizations` كلها) — لذلك نضمن العلامة
بـ **فهرس معرّف مشتق من UID**: `orgId = 'org_' + sha256(uid)[0..8] base32`.
هكذا `orgId` حتمي ⇒ إعادة المحاولة لا تنشئ مؤسسة ثانية. (single-owner-per-account by construction)

---

## 9) طبقة المزامنة

### 9.1 القاعدة الحاكمة
> **SQLite هو مصدر الحقيقة للجهاز. Firestore هو هدف نسخ مُصنَّف بالصلاحية، ومصدر تنزيل
> للجهاز الثاني. لا يوجد استعلام ترشيح/بحث في Firestore إطلاقاً (D8).**

### 9.2 `entity_registry.dart` — سجل واحد
```dart
class SyncEntity {
  final String type;                    // 'sample'
  final String collection;              // 'samples'
  final String localTable;              // 'inspections'
  final String Function(Map) docId;     // 'entry_code' أو 'qc_${id}_${version}'
  final Set<String> mutableFields;      // الحقول المسموح تعديلها (يطابق Rules.hasOnly)
  final bool appendOnly;                // qualityChecks/auditLogs
}
final syncEntities = <SyncEntity>[ ... 15 مدخلاً حسب §6.3 ... ];
```
هذا السجل هو **العقد الوحيد** بين `push_worker` و`pull_worker` و`entity` handlers؛
إضافة جدول = مدخل واحد + handler، بلا تعديل المحرك.

### 9.3 دورة الحياة
```
Write (repo) ─┬─► SQLite (same txn) ─┬─► row updated (sync_state='local')
              │                      └─► sync_queue UPSERT (status='pending', base_version=remote_version)
              └─► UI StreamBuilder rebuild (فوراً، بلا شبكة)
                                          │
                       SyncEngine.timer (60s) أو Connectivity→online أو manual refresh
                                          ▼
push_worker: صفوف status='pending' و next_attempt_at <= now, حد 400/دفعة
   ├─ success ─► queue row DELETE + row.remote_version=doc.version, sync_state='synced'
   │             + meta.last_push_at + meta doc (نبض) مرة واحدة لكل دفعة
   ├─ permission-denied ─► queue status='conflict' + sync_conflicts(remote_payload=get())
   │                        + audit + إشعار (لا إعادة محاولة تلقائية)
   ├─ unavailable / deadline-exceeded / network ─► backoff (§9.5)
   └─ payload>900000 ─► status='conflict' direction=payload_too_large + audit
```
`pull_worker` (كل جهاز، عند: بدء التشغيل Online · نبض جديد · Refresh يدوي · كل 5 دقائق
أثناء ظهور Dashboard كحد أقصى):
```
per collection: orderBy('updatedAt').orderBy(FieldPath.documentId())
                .startAt([lastTs, lastId]) .limit(300)
  → لكل مستند: إن remote.version == row.remote_version ⇒ skip
                إن remote.version  <  row.remote_version ⇒ local أحدث ⇒ enqueue update (push)
                غير ذلك ⇒ UPSERT داخل معاملة + تحديث المؤشر + bump stream
  → حد 5 صفحات لكل دورة (1500 مستند) ثم، إن بقي، دورة فورية أخرى
```

### 9.4 الحواجز المحلية الإلزامية (لاكتشافBUG قبل الشبكة)
في **كل** عملية كتابة (داخل الـ transaction):
1. `session.isActiveMember` (وليس `invited`/`disabled`) وإلا ⇒ `AuthorizationError`.
2. `session.permissions.contains(<perm of operation>)` وإلا ⇒ `AuthorizationError`.
3. `!device.readOnly` (جهاز Dashboard لا يُنتج كتابة أصلاً).
4. وضع الجهاز: `SyncMode.onlineOnly` للعمليات الامتيازية (إدارة مستخدمين/اعتماد QC عند انقطاع الإنترنت).

### 9.5 Polly/backoff
```
delay(n) = min(5s * 2^n, 15min) ± 20% jitter     n = retry_count
retry_count >= 20  ⇒ status='failed' + إشعار + يتحول لـ 'blocked' حتى حل يدوي من SyncScreen
```
### 9.6 التعارض (لا `last-write-wins` صامت)
القاعدة: `version` في كل مستند + Rule `request.resource.data.version == resource.data.version + 1`.
- Writer A يكتب offline (v5)، Writer B يكتب offline (v5) — أولهما يمر (v5→v6)، والثاني
  يُرفض بـ permission-denied ⇒ نقرأ البعيد ⇒ `sync_conflicts` ⇒ **لا overwrite صامت** (§26 خطتك).
- **V1 Writers=1** (جهاز التشغيل) + Dashboard read-only ⇒ التعارض نادر، لكن المسار آمن لو حدث.
- الحل اليدوي من `SyncScreen`: `keep_local` (إعادة دفع بـ version البعيد+1) أو `keep_remote`
  (استبدال المحلي). كلاهما audit.

### 9.7 سجل التدقيق (خطتك §27)
- يكتب **في نفس transaction** مع كل عملية مهمة (نمط "outbox"): يُضاف صف `audit_logs`
  + صف `sync_queue(entity_type='auditLog')`.
- حقول خطتك §27: `userId, organizationId, action, entityType, entityId, timestamp, deviceId`
  + `details_json` (بدون أي بيانات حساسة/كلمات مرور) + `userName` للعرض.
- **Append-only في Firestore** (`allow update, delete: if false`).
- تنظيف محلي: حذف الصفوف `synced=1` الأقدم من 90 يوماً فقط، وبحدّ أقصى 20,000 صف محلياً.

### 9.8 ميزانية القراءة (D8)
قراءة جهاز واحد في يوم عادي: ~1 قراءة نبض + بضع صفحات سحب ≤ 1,500 مستند ⇒
**≤ 10k قراءة/يوم/جهاز**، سقف قابل للضبط `settings.sync.max_pull_docs_per_cycle` (default 1500).

---

## 10) `firestore.rules` (النص الكامل — يُنشر في P4)

```rules
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // ── helpers ─────────────────────────────────────────────────────────
    function signedIn() { return request.auth != null; }
    function verifiedEmail() {
      return signedIn() && request.auth.token.email_verified == true
             && request.auth.token.email is string;
    }
    function userDoc(uid) { return get(/databases/$(database)/documents/users/$(uid)); }
    function hasProfile() { return signedIn() && userDoc(request.auth.uid) != null; }
    function myOrg() { return hasProfile() ? userDoc(request.auth.uid).data.organizationId : ''; }
    function myRole() { return hasProfile() ? userDoc(request.auth.uid).data.role : ''; }
    function myStatus() { return hasProfile() ? userDoc(request.auth.uid).data.status : ''; }

    // role -> permissions. MUST stay identical to lib/core/auth/permissions.dart
    function rolePermissions(role) {
      return role == 'admin' ? [
        'org.read','org.update',
        'users.read','users.create','users.update','users.disable',
        'samples.read','samples.create','samples.update',
        'lab_results.read','lab_results.create','lab_results.update',
        'qc.read','qc.approve','qc.reject',
        'reports.read','reports.create','reports.export',
        'devices.read','devices.register','audit.read'
      ] : role == 'quality_manager' ? [
        'org.read','users.read',
        'samples.read','samples.create','samples.update',
        'lab_results.read','lab_results.create','lab_results.update',
        'qc.read','qc.approve','qc.reject',
        'reports.read','reports.create','reports.export','audit.read'
      ] : role == 'lab' ? [
        'org.read',
        'samples.read','samples.create','samples.update',
        'lab_results.read','lab_results.create','lab_results.update',
        'reports.read','devices.register'
      ] : role == 'viewer' ? [
        'org.read','samples.read','lab_results.read','qc.read','reports.read','devices.register'
      ] : [];
    }
    function inOrg(orgId) { return myOrg() == orgId; }
    function activeInOrg(orgId) { return inOrg(orgId) && myStatus() == 'active'; }
    function can(orgId, perm) {
      return activeInOrg(orgId) && perm in rolePermissions(myRole());
    }
    function stampOk() {
      return request.resource.data.keys().hasOnly(
        ['organizationId','version','createdAt','updatedAt','updatedBy','deviceId','deletedAt','localId'])
        && request.resource.data.version == 1
        && request.resource.data.organizationId != ''
        && request.resource.data.updatedBy == request.auth.uid;
    }
    function versionedUpdate(orgId, perm, mutable) {
      return can(orgId, perm)
        && request.resource.data.version == resource.data.version + 1
        && request.resource.data.organizationId == resource.data.organizationId
        && request.resource.data.createdAt == resource.data.createdAt
        && request.resource.data.createdBy == resource.data.createdBy
        && request.resource.data.diff(resource.data).affectedKeys()
             .affectedKeys().hasOnly(mutable);
    }
    function adminOf(uid) {
      return userDoc(uid) != null
             && can(userDoc(uid).data.organizationId, 'users.update');
    }

    // ── global users (خطتك §6) ───────────────────────────────────────────
    match /users/{uid} {
      allow get: if signedIn() && request.auth.uid == uid;
      allow list: if false;                       // لا تُكشف دليل المستخدمين العالمي أبداً
      allow create: if signedIn() && request.auth.uid == uid && verifiedEmail()
        && request.resource.data.keys().hasOnly(
             ['email','organizationId','role','status','memberId','inviteKey','createdAt','updatedAt','version','updatedBy','deviceId'])
        && request.resource.data.email.lower() == request.auth.token.email.lower()
        && request.resource.data.status == 'invited'
        && request.resource.data.version == 1
        && exists(/databases/$(database)/documents/organizations/$(request.resource.data.organizationId)
                  /invites/$(request.resource.data.inviteKey))
        && get(/databases/$(database)/documents/organizations/$(request.resource.data.organizationId)
               /invites/$(request.resource.data.inviteKey)).data.email.lower()
             == request.auth.token.email.lower()
        && get(/databases/$(database)/documents/organizations/$(request.resource.data.organizationId)
               /invites/$(request.resource.data.inviteKey)).data.role
             == request.resource.data.role
        && get(/databases/$(database)/documents/organizations/$(request.resource.data.organizationId)
               /invites/$(request.resource.data.inviteKey)).data.memberId
             == request.resource.data.memberId;
      allow update: if signedIn() && (
            (request.auth.uid == uid
              && request.resource.data.diff(resource.data).affectedKeys()
                   .hasOnly(['displayName','photoUrl','lastSeenAt','lastDeviceId'])
              && request.resource.data.organizationId == resource.data.organizationId
              && request.resource.data.role == resource.data.role
              && request.resource.data.status == resource.data.status)
         || adminOf(uid));
      allow delete: if false;
    }

    // ── organizations ────────────────────────────────────────────────────
    match /organizations/{orgId} {
      allow get: if inOrg(orgId) || (signedIn() && resource.data.ownerUid == request.auth.uid);
      allow list: if false;                       // لا كشف قائمة المؤسسات
      allow create: if signedIn()
        && request.resource.data.keys().hasOnly(
             ['name','ownerUid','status','createdAt','schemaVersion'])
        && request.resource.data.ownerUid == request.auth.uid
        && request.resource.data.status == 'active';
      allow update: if can(orgId,'org.update')
        && request.resource.data.ownerUid == resource.data.ownerUid
        && request.resource.data.diff(resource.data).affectedKeys()
             .hasOnly(['name','schemaVersion','updatedAt']);
      allow delete: if false;

      match /meta/{docId} {
        allow get: if inOrg(orgId);
        allow list: if false;
        allow create, update: if activeInOrg(orgId)
          && request.resource.data.keys().hasOnly(['lastWriteAt','lastWriteBy','lastEntity','updatedAt']);
        allow delete: if false;
      }

      // الدعوة: قراءتها مشروعة لصاحب البريد فقط (قبل وجود user profile)
      match /invites/{inviteKey} {
        allow get: if verifiedEmail()
          && resource.data.email.lower() == request.auth.token.email.lower();
        allow list: if can(orgId,'users.read');
        allow create: if can(orgId,'users.create')
          && request.resource.data.status == 'invited'
          && request.resource.data.email is string
          && request.resource.data.email.size() > 3
          && request.resource.data.role in ['admin','quality_manager','lab','viewer'];
        allow update: if can(orgId,'users.create')
          && request.resource.data.email == resource.data.email;   // لا تغيير البريد
        allow delete: if can(orgId,'users.update');
      }

      match /members/{memberId} {
        allow read: if activeInOrg(orgId);
        allow create: if can(orgId,'users.create')
          && request.resource.data.status == 'invited'
          && request.resource.data.version == 1
          && request.resource.data.role in ['admin','quality_manager','lab','viewer'];
        allow update: if can(orgId,'users.update')
          && request.resource.data.diff(resource.data).affectedKeys()
               .hasOnly(['role','status','displayName','activatedAt','updatedAt','updatedBy','version']);
        allow delete: if can(orgId,'users.disable')
          && request.resource.data.status == 'disabled';
      }

      match /samples/{docId} {
        allow read: if can(orgId,'samples.read');
        allow create: if can(orgId,'samples.create') && stampOk()
          && request.resource.data.createdBy == request.auth.uid;
        allow update: if versionedUpdate(orgId, 'samples.update', [
            'materialId','materialName','materialCode','inspectionDate','supplier','truckNumber',
            'quantity','sampleTakenBy','specialistName','physicalResultsJson','chemicalResultsJson',
            'physicalReferenceJson','chemicalReferenceJson','sampleNamesJson','snapshotJson','reportHtml',
            'decisionStatus','decisionReason','followUpNote','rejectedQuantity','decisionVersion',
            'expiryDate','localId','payloadBytes',
            'version','updatedAt','updatedBy','deviceId','deletedAt']);
        allow delete: if false;   // Tombstone فقط
      }

      match /qualityChecks/{docId} {
        allow read: if can(orgId,'qc.read');
        allow create: if (request.resource.data.decision == 'approved' && can(orgId,'qc.approve'))
                    || (request.resource.data.decision != 'approved' && can(orgId,'qc.reject'));
        allow update: if false;   // append-only
        allow delete: if false;
      }

      match /labResults/{docId} {
        allow read: if can(orgId,'lab_results.read');
        allow create: if can(orgId,'lab_results.create') && stampOk();
        allow update: if versionedUpdate(orgId, 'lab_results.update', [
            'analysisId','sourceType','sourceRefId','sourceName','sampleName','resultText',
            'dynamicValues','entryCode','worksheetRowId','testedBy','testedAt','localId',
            'version','updatedAt','updatedBy','deviceId','deletedAt']);
        allow delete: if false;
      }

      match /labConfig/{docId} {
        allow read: if can(orgId,'samples.read');            // مرجع + تحليلات
        allow create: if can(orgId,'lab_results.create') && stampOk();
        allow update: if versionedUpdate(orgId, 'lab_results.update', [
            'payload','configType','localId','version','updatedAt','updatedBy','deviceId','deletedAt']);
        allow delete: if false;
      }

      match /devices/{docId} {
        allow read: if can(orgId,'devices.read') || inOrg(orgId);
        allow create: if activeInOrg(orgId) && docId == request.resource.data.id
          && request.resource.data.keys().hasOnly(
               ['id','name','platform','osVersion','appVersion','role','readOnly','registeredAt','lastSeenAt']);
        allow update: if (docId == request.auth.uid) || can(orgId,'devices.read');
        allow delete: if false;
      }

      match /auditLogs/{docId} {
        allow read: if can(orgId,'audit.read');
        allow create: if activeInOrg(orgId)
          && request.resource.data.keys().hasOnly(
               ['userId','userName','organizationId','action','entityType','entityId',
                'detailsJson','deviceId','occurredAt'])
          && request.resource.data.action is string
          && request.resource.data.action.size() <= 64;
        allow update, delete: if false;      // append-only
      }

      // أي مسار آخر داخل المؤسسة = ممنوع
      match /{document=**} { allow read, write: if false; }
    }

    match /{document=**} { allow read, write: if false; }   // catch-all
  }
}
```

---

## 11) الفهارس والتهيئة

`firestore.indexes.json` — V1 لا يحتاج composite (§D8: سحب بلا ترشيح):
```json
{ "indexes": [], "fieldOverrides": [
  { "collectionGroup": "samples",      "fieldPath": "updatedAt", "indexes": [{ "order": "ASCENDING" }] },
  { "collectionGroup": "qualityChecks","fieldPath": "updatedAt", "indexes": [{ "order": "ASCENDING" }] },
  { "collectionGroup": "labResults",   "fieldPath": "updatedAt", "indexes": [{ "order": "ASCENDING" }] },
  { "collectionGroup": "labConfig",    "fieldPath": "updatedAt", "indexes": [{ "order": "ASCENDING" }] }
]}
```
`firebase.json`:
```json
{ "firestore": { "rules": "firestore.rules", "indexes": "firestore.indexes.json" } }
```
`.firebaserc`: `{ "projects": { "default": "materiallab-63405" } }`

**نشر آمن (مرتين):** أولاً `firebase deploy --only firestore:rules --project <emulator-id>` مع
المحاكي للاختبار، ثم الإنتاج بعد نجاح §15-R (اختبار cross-org على المحاكي).

---

## 12) التغييرات ملفاً بملف

### 12.1 حذف نهائي
| الملف | السبب |
|---|---|
| `lib/features/auth/presentation/setup_screen.dart` + `cubit/setup_cubit.dart` + `setup_state.dart` | D2 |
| `lib/core/security/password_hash.dart` | D2 |
| `lib/features/auth/data/auth_repo.dart` (+ `token_storage.dart` كما هو، يُعاد استخدامه كـ `SessionStore`) | D2 |
| `lib/core/domain/rules.dart` | تكرار ميت (§7.3) |
| `test/rules/seal_tamper_test.dart` · `test/rules/user_delete_guard_test.dart` | كانا يختبران ما حُذف |

### 12.2 تعديل
| الملف | التعديل |
|---|---|
| `lib/core/app_paths.dart` | `databasePathFor(orgId)`, `orgRoot()`, `backupsDirFor(orgId)`, `autoBackupDirFor(orgId)`؛ `databasePath()` القديمة تبقى للترحيل (تُحذف في P11) |
| `lib/core/database/database_helper.dart` | `OrgDatabaseProvider` بدل path ثابت؛ `_createSchema` += 5 جداول (§6.4)؛ `_runLegacyGuarantees` += أعمدة §6.5 + **rebuild جدول users** (§6.6)؛ `close()`/فتح جديد عند تبديل المؤسسة |
| `lib/app/app_bootstrap.dart` | تفكيك: `initServiceLocator()` ثم `await AuthRepository.restoreSession()` ثم (إن وُجدت مؤسسة) `postBindBootstrap()` = settings+seed+lab+backup |
| `lib/di/service_locator.dart` | تسجيل: `ConnectivityService`, `SessionStore`, `FirebaseBootstrap`, `AuthRepository`, `OrganizationRepository`, `MemberRepository`, `SyncQueue`, `SyncMetadata`, `SyncEngine`, `AuditLogger`, `*RemoteDataSource`, `*DataSource`, `*Repository` (كلها lazySingleton)؛ **واجهات مسجَّلة factories** لتنفيذ Django لاحقاً |
| `lib/app/auth_gate.dart` | فوق `AuthRepository` + `AuthState` (§8.1) |
| `lib/router/app_router.dart` | `_redirect` جديد (§8.1)؛ إضافة `/create-organization` و`/waiting-activation`؛ إبقاء كل guard على `canSeeSettings` |
| `lib/features/auth/domain/user.dart` | getters ⇒ permissions (§7.3)؛ `isDeveloper` حذف |
| `lib/features/settings/data/settings_repo.dart` | حذف `createUser/updateUser/deleteUser` (`:142-216`) و`listUsers` (`:134-140`) → `MemberRepository`؛ إبقاء `updateSettings/ensureDefaults/setReportLogo*` |
| `lib/features/settings/presentation/settings_screen.dart` | استبدال `_UsersPanel` (`:414-575`) بزر ينقل إلى `MembersScreen`؛ إضافة تبويب "المزامنة" (SyncScreen) |
| `lib/features/backup/data/backup_manager.dart` | `backupRequiredTables` (+`sync_metadata`)؛ مسارات per-org؛ `pullUsersFromSourceDb` **تعطَّل** (هوية صارت remote) مع رسالة واضحة في MigrationPanel؛ `importInspectionsFromSource` تبقى لكن `created_by` يُسند للمستخدم الحالي (انظر ملاحظة P1) |
| `lib/features/shell/presentation/app_shell.dart` | إضافة شارة حالة المزامنة (Online/Offline + Pending + Last Sync)؛ `isDeveloper` ⇒ `role == 'admin'` |
| 8 ملفات Widget تستدعي `getIt<Repo>()` | **بلا تعديل** — تعمل عبر Facade (§14-P5) |

### 12.3 جديد (ملخص)
`lib/core/firebase/*` · `lib/core/network/connectivity_service.dart` ·
`lib/core/auth/{permissions,app_session,session_store}.dart` ·
`lib/core/sync/{entity_registry,sync_queue,sync_metadata,sync_engine,push_worker,pull_worker,conflict_resolver,audit_logger}.dart` ·
`lib/core/sync/remote/*` (9 ملفات) · `lib/features/auth/{domain,data,presentation}` (جديد/معدّل) ·
`lib/features/organizations/*` · `lib/features/members/*` · `lib/features/sync/presentation/*` ·
`test/{architecture,auth,sync,security,backup}/*` · `firestore.rules` · `firestore.indexes.json` ·
`firebase.json` · `.firebaserc` · `tool/firebase/README.md`.

---

## 13) نقل الإقلاع (تسلسل دقيق — نقطة الفشل الأشيع)
```
main()
 └─ WidgetsFlutterBinding.ensureInitialized()
 └─ initServiceLocator()                 // لا يفتح DB
 └─ FirebaseBootstrap.initialize()       // try/catch ⇒ degraded flag إن فشل
 └─ SessionStore.restore()               // جلسة محلية أو null
 └─ runApp(...)
 └─ postFrame / AuthGate.drive():
      ├─ online ⇒ FirebaseAuth state ⇒ signIn silently أو signedOut
      │           ⇒ AuthRepository.resolveProfile()  (Users/{uid} أو invites)
      │           ⇒ status active ⇒ bindOrg(orgId)
      ├─ offline ⇒ session cache ⇒ bindOrg(orgId) إن وُجدت ⇒ READY(offline)
      └─ bindOrg(orgId):
           DatabaseHelper.bindOrg(orgId)   // يفتح أو ينشئ ملف المؤسسة
           SettingsRepo.ensureDefaults()
           SeedService.ensureInitialImport()
           if (!device.readOnly) LabRepo.ensureDefaultAnalyses()
           BackupManager.autoBackup()      // نسخة قبل أي تعديل مخطط
           DeviceRegistry.ensureRegistered()
           SyncEngine.start()              // يبدأ طابور الدفع/السحب
```

---

## 14) المراحل P1 → P12

### P1 — الأسس (Foundation)
**الهدف:** بناء الطبقات الفارغة وتأكيد أن البناء يعمل قبل لمس أي منطق قائم.
1. `git branch feature/v2-org-firebase-sync` (لا تلمس `main`).
2. `flutter pub add` (§4.3) + `flutter pub get` ⇒ تأكد من عدم كسر `analysis_options.yaml`.
3. `lib/core/firebase/firebase_options.dart`: قراءة `--dart-define` + **fail-fast واضح**
   (`MissingFirebaseConfig` ⇒ شاشة إعداد بدل crash عند أول `runApp`).
4. `ConnectivityService`: `Stream<bool>` عبر `connectivity_plus` + `dart:io` InternetAddress
   probe (connectivity_plus يقول "متصل بشبكة" بدون إنترنت فعلاً ⇒ فحص مزدوج).
5. جداول §6.4 + الأعمدة §6.5 + **rebuild `users`** (§6.6) في `DatabaseHelper`، داخل
   transaction واحدة مع `PRAGMA foreign_keys=OFF` ثم `PRAGMA integrity_check` ثم rollback عند أي خطأ.
6. `OrgDatabaseProvider` + `AppPaths` (§12.2) + ربط في `service_locator` (lazy).
7. تفكيك `app_bootstrap` (§13) — **مرحلة لا بديل عنها**، لأن فتح DB قبل ربط المؤسسة خطأ معماري.
8. `BackupManager`: نسخ per-org + تعطيل `pullUsersFromSourceDb` برسالة في `MigrationPanel`.
9. `test/architecture/firebase_isolation_test.dart` (يبدأ حارساً بـ 0 مخالفات).
**Acceptance:** `flutter analyze` 0 · `flutter test` أخضر (18 ملف اختبار سابق) ·
تشغيل مرتين متتاليتين ⇒ ملف `%APPDATA%\MaterialLab\orgs\<fakeOrg>\material_lab.db` واحد ·
`users` بلا `password_hash` وقيم الأدوار الجديدة.

### P2 — المصادقة
1. `app_session.dart` + `session_store.dart` (flutter_secure_storage، تشفير OS).
2. `auth_remote_data_source.dart` (§8.2) + `google_auth_data_source.dart`.
3. `auth_repository.dart` (abstract) + `offline_first_auth_repository.dart`:
   `signInWithGoogle()` · `signOut()` · `restoreSession()` · `resolveProfile()` ·
   `currentState : Stream<AuthState>` · `changeOrganization()`.
4. `auth_cubit.dart` + `login_screen.dart` (زر Google) + حذف Setup.
5. `auth_gate.dart` + `_redirect` الجديد + شاشتي `/create-organization` و`/waiting-activation`
   (نصّان فقط في P2؛ التفعيل في P3).
6. **حذف** §12.1 + تحديث `cubit_smoke_test` و`widget_test` للـ API الجديد.
**Acceptance:** زر Google يفتح المتصفح ويعود بـ UID · توكن محفوظ · إعادة تشغيل دون إنترنت
تُدخل التطبيق (جلسة من الكاش) · `flutter analyze/test` أخضران.

### P3 — المؤسسة والأعضاء
1. `organization.dart` + `organization_repository.dart` (+ remote DS).
2. `create_organization_screen.dart` كامل (§8.5 خطوة 2-5) + `orgId` حتمي (§8.5 حاشية).
3. `member.dart` + `member_repository.dart` + remote DS (`invites`, `members`, `users`).
4. `members_screen.dart`: قائمة + Add(email, role) + Activate + Change role + Disable
   + "نسخ رابط/تعليمات الدخول" (نص يوضّح أن الموظف يسجّل بنفس بريده).
5. `permissions.dart` + إعادة ربط getters (§7.3) + `test/security/permissions_parity_test.dart`.
6. `MigrationPanel`: استبدال "المستخدمون" بـ MembersScreen؛ إخفاء تبويب "الأمان" (كان Dev-only).
**Acceptance:** اختبارات §42 (1،2،3،4) تنجح يدوياً: أول حساب ⇒ مؤسسة+admin؛ إضافة موظف؛
الموظف يدخل ⇒ "waiting for activation"؛ التفعيل ⇒ يدخل؛ بريد غير مصرّح ⇒ "Access Denied".

### P4 — قواعد الأمان (قبل أي بيانات حقيقية) — **بوابة صارمة**
1. كتابة `firestore.rules` (§10) و`firestore.indexes.json` و`firebase.json` و`.firebaserc`.
2. `test/security/firestore_rules_test.dart` على **Emulator**:
   `firebase emulators:exec --only firestore --project demo-materiallab "flutter test test/security/firestore_rules_test.dart"`.
   يغطي: (a) مستخدم بلا profile لا يقرأ شيئاً · (b) مستخدم من مؤسسة أخرى لا يقرأ/يكتب (خطتك §42-10) ·
   (c) viewer لا ينشئ/يعدّل (خطتك §42-5) · (d) invited لا يكتب · (e) `version` غير متسلسل مرفوض ·
   (f) `updatedBy != auth.uid` مرفوض · (g) delete مرفوض · (h) user يعدّل دوره ⇒ مرفوض ·
   (i) لا `organizationId` مزيّف (اختبار path juggling).
3. `test/security/permissions_parity_test.dart` أخضر.
4. نشر القواعد على الإنتاج **بعد** نجاح (2) مباشرة، وتسجيل التاريخ في commit.
**Acceptance:** كل سيناريوهات (a)-(i) تُرفض/تُقبل كما هو محدد · القواعد منشورة ·
`firebase deploy --only firestore:rules` نظيف بلا تحذير.

### P5 — طبقة Repository (نقطة الفصل)
1. **Facade بلا مساس:** `abstract class InspectionRepository`؛ التنفيذ
   `OfflineFirstInspectionRepository` يغلّف `InspectionRepo` الحالي كـ `LocalInspectionDataSource`
   **دون تغيير سطر واحد** في `inspection_repo.dart` (بما فيه `:210`, `:254`, `:342`, `:391`, `:481`, `:510`).
2. نفس الشيء لـ `LabResult` (`LabRepo` كـ local DS جزئياً: `runSampleTest` + `saveWorksheet`).
3. `SampleRepository`, `LabResultRepository`, `QualityCheckRepository`, `MemberRepository`,
   `OrganizationRepository`, `AuditRepository`, `DeviceRepository` (abstract) + implementations.
4. Facade بالاسم القديم: `class InspectionRepo implements InspectionRepository`
   مسجَّل في GetIt ⇒ **صفر تعديل في 30 Cubit و8 Widgets** (§3).
5. `test/architecture/repository_boundary_test.dart`:presentation لا يستورد `data/`.
**Acceptance:** `flutter analyze/test` أخضران **دون تعديل أي cubit أو widget** ·
`grep -r "DatabaseHelper" lib/features/*/presentation` = لا نتائج جديدة.

### P6 — طابور المزامنة + المحرك
1. `entity_registry.dart` (§9.2) + handlers.
2. `sync_queue.dart`: `enqueue()` (يُستدعى داخل transaction)، `claim(n)`، `markDone`،
   `markRetry(err)`، `markConflict(...)`، `purgeSolved()` (إزالة صف قديم لنفس الكيان).
3. `sync_metadata.dart` + `audit_logger.dart` (§9.7).
4. `push_worker.dart` + `pull_worker.dart` + `sync_engine.dart` (مؤقت 60s + events + `dispose`).
5. `test/sync/{sync_queue_test,push_worker_test,pull_worker_test,conflict_test}.dart`
   (على SQLite حقيقي + fake remote).
**Acceptance:** كتابة offline ⇒ صف `pending` ⇒ `dispose`/إعادة تشغيل ⇒ الصف باقٍ ⇒
Online ⇒ الدفع ينجح ⇒ `remote_version` محدَّث + `meta` نبض.

### P7 — Offline-first على مسارات الكتابة
1. تركيب `enqueue` في `InspectionRepo.create/update/updateStatus/delete(tombstone)`،
   `LabRepo.runSampleTest/saveWorksheet/...`، إعدادات المختبر.
2. الحواجز المحلية §9.4 (session/permission/readOnly/online-only) في كل عملية.
3. Audit outbox في نفس الـ transaction.
4. شاشة `SyncScreen`: الطابور، التعارضات (مع keep_local/keep_remote)، آخر مزامنة،
   زر "مزامنة الآن"، إعادة محاولة، تنزيل السجل.
5. اختبار **§42-6/7**: Internet OFF ⇒ إنشاء فحص يعمل ويظهر فوراً ⇒ Internet ON ⇒ مزامنة.
**Acceptance:** اختبارات §42-6 و§42-7 تنجح · لا كتابة واحدة تخرج من الـ transaction بلا enqueue
(تأكيد بـ `test/sync/atomicity_test.dart`).

### P8 — التنزيل + جهاز Dashboard
1. `pull_worker` مفعّل لكل الأجهزة + UPSERT داخل transaction.
2. `app_shell.dart`: شارة `● Online / ● Offline · Pending N · Last Sync HH:mm:ss` (خطتك §25).
3. `device.readOnly = (role == 'viewer')` ⇒ إخفاء كل أزرار الكتابة + `readOnly` في
   `devices` + `can(orgId,'samples.create')` يفشل على الخادم ⇒ **طبقتان**.
4. اختبار **§42-8/§42-9**: جهاز 2 يستقبل تغيير جهاز 1 · وجهاز 2 offline يعرض آخر بيانات.
**Acceptance:** §42-8 و§42-9 تنجحان · Dashboard لا يعرض زر كتابة واحداً (يُثبت باختبار Widget).

### P9 — الأجهزة + سجل التدقيق
1. `device_registry` + `devices/{deviceId}` remote + "تسجيل خروج من هذا الجهاز" (مشغّل فقط).
2. `auditLogs` كامل + شاشة عرض (لـ `audit.read` فقط) + تنقية بـ `entityType/action/date`.
3. تنظيف السجل المحلي (§9.7).
**Acceptance:** كل عملية مهمة لها صف audit بثلاثيات (من/ماذا/متى/أي جهاز) ·
سجل **غير قابل للتعديل** محلياً وبعيداً.

### P10 — مصفوفة الاختبارات §42 (كلها)
تشغيل وتوثيق النتيجة المتوقعة لكل حالة في `test/manual/v1_acceptance_checklist.md`
(يُنشأ في هذه المرحلة) — مع لقطات/ timestamps.

### P11 — النسخ الاحتياطي والاستعادة مع المزامنة
1. المسارات per-org + التحقق `backupRequiredTables` (+`sync_metadata`).
2. **استعادة ⇒ ثمvable**: بعد الاستعادة يُشغَّل `reconcileAfterRestore()`:
   لكل صف مُزامن: قارن `remote_version` بالبعيد؛ الأحدث محلياً ⇒ enqueue؛ المسحوب من جهاز
   آخر ⇒ يُحذف محلياً؟ **لا**: يُعاد enqueue conflict ثم يُعرض للمستخدم (لا فقدان صامت).
3. تغييرات المخطط (نسخة P1) ⇒ نسخة تلقائية قبل كل تطبيق.
**Acceptance:** استعادة نسخة قديمة لا تُنتج بيانات كاذبة ولا تفقد عيّنة · `integrity_check=ok`.

### P12 — البناء والإطلاق
1. `flutter build windows --release` (VS 2022 17.12.1 ✓) + اختبار على جهاز نظيف.
2. `tool/firebase/README.md`: أوامر البناء بمفاتيح `--dart-define` + نشر القواعد.
3. تسليم الـ exe إلى صفحة الهبوط (Cloudflare R2) + تحديث نسخة.
4. **الإصدار 1 = Device-writer واحد جهاز قراءة فقط (viewer)** فقط؛ So: جهاز كتابة واحد فقط؛ تفعيل كاتبَين في إصدار لاحق بعد اختبار
   التعارض على Staging.

---

## 15) استراتيجية الاختبار

| النوع | الملفات | الغرض |
|---|---|---|
| Unit | `test/sync/*.dart` (5) | الطابور، الدفع، السحب، التعارض، الذرّية |
| Unit | `test/security/permissions_parity_test.dart` | تطابق Dart ↔ Rules |
| Rules (emulator) | `test/security/firestore_rules_test.dart` | العزل، الترقية، الحذف، cross-org |
| Architecture | `test/architecture/*.dart` (2) | عزل Firebase، حدود الطبقات |
| Auth | `test/auth/auth_flow_test.dart` | الحالات، الجلسة المخزّنة، offline |
| Regress | `test/rules/*` + `test/backup/*` + `test/lab/*` + `test/reports/*` (الموجود) | **يجب ألّا تنكسر** |
| Widget | `test/widget_test.dart` + شاشة واحدة جديدة | login/members/sync |
| Manual | `test/manual/v1_acceptance_checklist.md` | اختبارات خطتك §42 العشرة |

**أوامر التحقق الثابتة (تُكتب في AGENTS.md):**
```powershell
flutter analyze
flutter test
firebase emulators:exec --only firestore --project demo-materiallab "flutter test test/security"
```

---

## 16) المخاطر والتخفيف

| # | الخطر | الاحتمال | التخفيف (مُطبَّق في هذه الخطة) |
|---|---|---|---|
| R1 | **Firebase على Windows beta** | متوسط | D5: كل Firebase معزول في `remote/` · اختبار تكامل أسبوعي · مسار Django مفتوح · **لا** ميزات حرجة تعتمد على Firestore Cache |
| R2 | `runTransaction` يسقط التطبيق | مؤكد | ممنوع كلياً؛ `version` + Rules + `sync_conflicts` |
| R3 | Firestore تكلفة غير مقبولة | متوسط | D8 (لا استعلامات ترشيح) + batch 400 + سقف 1500/سحب + Budget alert (§4.1-5) |
| R4 | خطأ في Rules ⇒ تسريب بين المؤسسات | منخفض/شديد الأثر | P4 بوابة صارمة + emulator tests + catch-all `allow: if false` + المراجعة اليدوية للـ rules في PR |
| R5 | ازدواج المرحلة (حسابان لنفس الـ UID) | متوسط | `orgId` حتمي من UID (§8.5) ⇒ إعادة المحاولة لا تنشئ مؤسسة ثانية |
| R6 | بيانات `%APPDATA%` داخل OneDrive | منخفض | `%APPDATA%` محلي؛ تحقق عند أول تشغيل: إن كان المسار على OneDrive ⇒ تحذير في SyncScreen + اقتراح نقل |
| R7 | إعادة تشغيل بلا إنترنت تُخرج المستخدم | مؤكد (بلا حل) | §8.4 SessionStore |
| R8 | `report_html` يتجاوز 1 MiB | منخفض | فحص 900 KB + رفض صريح + قابلية إعادة التوليد |
| R9 | استعادة نسخة قديمة تُفسد المزامنة | متوسط | P11: `reconcileAfterRestore()` + لا حذف صامت |
| R10 | Visual Studio 17.12 / C++ toolchain | مؤكد (مُتحقَّق ✓) | ~~VS 2022 17.12.1 مثبّت — متوافق~~ **مُصحَّح 2026-09-27:** 17.12.1 (MSVC 14.42) **غير** متوافق — `firebase_core 4.15.0` (C++ SDK 13.12.0) يفشل في الربط بـ6 رموز `__std_*_1`/`_Avx2WmemEnabled`.VS 2022 **17.14** (MSVC `14.44.35207`) يبني `material_lab.exe` بنجاح. التفاصيل في `tool/firebase/README.md` §7 |
| R11 | بطء السحب على شبكة ضعيفة | متوسط | pagination 300 + مؤشر مركّب + السحب عند الطلب لا دورياً عدوائياً |

---

## 17) Definition of Done — V1

```
[ ] Google Login (Windows، عبر Firebase)
[ ] Create Organization (أول مستخدم = admin)
[ ] Admin يضيف موظفين بريداً + activating
[ ] الموظف المصرّح يدخل / غير المصرّح = Access Denied
[ ] Role + Permission (خريطة واحدة Dart↔Rules باختبار تطابق)
[ ] Organization Isolation (مُثبت على المحاكي: شركة A لا ترى شركة B)
[ ] SQLite per-org (مجلد مستقل + نسخة احتياطية مستقلة)
[ ] Repository Layer (UI لا يعرف مصدر البيانات)
[ ] Firestore + Rules منشورة على الإنتاج
[ ] Sync Queue + Sync Engine (دفع/سحب/تعارض/إعادة محاولة)
[ ] Offline Create + Offline Update (ويُفتح التطبيق بلا إنترنت)
[ ] Automatic Sync + شارة Last Sync / Pending
[ ] جهاز Dashboard يعرض بيانات الجهاز الأول
[ ] Read-only Viewer (طبقتان: UI + Rules)
[ ] Audit Log (من/ماذا/على ماذا/متى/أي جهاز) غير قابل للتعديل
[ ] اختبار §42 العشرة كلها موثّقة
[ ] Multi-device + Multi-organization اختباران ناجحان
[ ] Backup/Restore + reconcile
[ ] flutter analyze = 0 errors && flutter test أخضر
```

---

## 18) المؤجَّل (ليس V1)
- Cloud Functions (ربط تلقائي بدل الـ invite) — عند الحاجة (>100 مؤسسة مثلاً).
- تطبيق Web/Mobile.
- `lab_inventory` / `lab_consumption_log` / `lab_stock_adjustments` / `lab_worksheet` للمزامنة.
- تعديل `role → permissions` من الواجهة.
- App Check / rate-limiting للـ audit logs.
- الانتقال إلى Django (المستند 45 من خطتك) عند بلوغ عتبات المراقبة.

---

## 19) تأكد قبل البدء (Checklist المبتدئ)
- [ ] نسخ `GOOGLE_WEB_CLIENT_ID` من Console (P0-3)
- [ ] إنشاء `Desktop app` OAuth client + `http://127.0.0.1` redirect URI ونسخ `GOOGLE_DESKTOP_CLIENT_ID` (P0-4) — **إلزامي لتسجيل دخول Windows**
- [ ] إنشاء Firestore database (P0-1)
- [ ] Budget alert (P0-5)
- [ ] نسخة احتياطية من أي DB حالية (V1 غير منشور ⇒ لا يوجد، لكن تحقّق)
- [ ] إنشاء فرع `feature/v2-org-firebase-sync`
- [ ] `git status` نظيف
