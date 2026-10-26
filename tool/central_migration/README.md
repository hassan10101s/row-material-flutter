# أداة الانتقال إلى بروتوكول المزامنة المركزية (الجاهزية للإنتاج — البند 5)

ترحيل مؤسسة واحدة من كتابة المسار القديم (push) إلى بروتوكول الأوامر المركزي
(`schemaVersion 2`, `domainManifestVersion 1`) — على دفعات آمنة وقابلة لإعادة
التشغيل (idempotent). كل مرحلة تُسجَّل في
`organizations/{org}/migrationState/current` وتصبح no-op بعد إتمامها.

> **قاعدة ذهبية:** لا تُشغَّل على مشروع حقيقي قبل إثباتها على المحاكي
> (`demo-materiallab`) وقراءة تقرير التدقيق بالكامل.

## الملفات

| ملف | الوظيفة |
|---|---|
| `shared.js` | تهيئة admin + قراءة المانيفست وقواعد الفهرسة الفريدة من **نفس** كود الخادم (`domain_manifest.json`, `domain_admission.js`) — لا انحراف ممكن بين التدقيق والإنفاذ |
| `audit.js` | تدقيق للقراءة فقط: blockers لكل كيان (organizationId، version، createdBy/createdAt/updatedAt، روابط الآباء المطلوبة `*_remote_id`، قيم فريدة مكررة) |
| `backup.js` | نسخة JSONL لكل مجموعات المؤسسة + `restore-report.json` (شبكة الأمان قبل أي كتابة) |
| `migrate.js` | التنفيذ: `audit → counters → parentRefs → reservations → gate` و`--abort` |
| `proof.js` | إثبات آلي على المحاكي: بذرة قديمة → تدقيق → نسخ → ترحيل → إعادة تشغيل (idempotency) → بروتوكول المزامنة الحقيقي يخدم المؤسسة → إحباط |

## ما تفعله كل مرحلة

1. **audit** — يعيد تشغيل حكم التدقيق؛ أي blocker يوقف الترحيل فورًا.
2. **counters** — ينشئ `counters/changeSequence` (أقصى `seq` في changeEvents، وإلا 0)
   و`counters/sampleNumber` (أقصى `sampleNo` في samples). البروتوكول يفشل بدون
   العدّادات (PROTOCOL_NOT_READY).
3. **parentRefs** — يملأ `parentRefs` في مستندات الأعمال القديمة من أعمدة
   `*_remote_id` (المستندات القديمة لا تحملها، والعميل لا يستطيع تجميع اللقطة
   بدونها). لا يرفع `version` — لا تغيير في المحتوى، فقط إضافة خريطة الآباء.
4. **reservations** — يبني `uniqueReservations` لكل مستند **حي** بنفس مطالب
   `uniqueClaims` التي سينفذها الاستقبال بعد القطع (tombstones مستثناة).
5. **gate** — يضبط `commandProtocol`:
   `{enabled: true, schemaVersion: 2, domainManifestVersion: 1, migrationId,
   writerDeviceId, globalReferencesReady: true, uniqueAdmissionComplete: true}`.
   من هذه اللحظة: قواعد Firestore ترفض الكتابة القديمة
   (`legacyDomainWritesAllowed`) والقراءة المركزية تصبح مسموحة.

`--abort` يعيد `enabled: false` (يفتح المسار القديم مجددًا) ويسجل الإحباط —
كل ما بناه الترحيل يبقى مكانه لإعادة تشغيل لاحقة.

## التشغيل على المحاكي (الإثبات)

من جذر المستودع:

```bash
firebase emulators:exec --only firestore --project demo-materiallab "node tool/central_migration/proof.js"
```

الإثبات يغطي: تدقيق نظيف، نسخة احتياطية، عدّادات، parentRefs، حجوزات فريدة،
البوابة، إعادة تشغيل بلا تغيير، خدمة `beginSnapshot/snapshotPage/events`
الحقيقية للمؤسسة المُرحّلة، ثم الإحباط.

## التشغيل على مؤسسة حقيقية (عند الجاهزية)

```bash
# 0) نفّذ أوامر الموظفين/الجهاز على جهاز الكاتب المعتمد فقط، ثم أوقف كل الأجهزة عن الكتابة.
# 1) نسخة احتياطية أولًا:
node tool/central_migration/backup.js --project <prod> --org <orgId> --out backup/<orgId>

# 2) تدقيق للقراءة فقط — يجب أن ينتهي برمز 0:
node tool/central_migration/audit.js --project <prod> --org <orgId> --json backup/<orgId>/audit.json

# 3) الترحيل بلا البوابة (عدّادات + parentRefs + حجوزات) — آمن قبل القطع:
node tool/central_migration/migrate.js --project <prod> --org <orgId> --stage counters
node tool/central_migration/migrate.js --project <prod> --org <orgId> --stage parentRefs
node tool/central_migration/migrate.js --project <prod> --org <orgId> --stage reservations

# 4) القطع الفعلي — يحتاج هوية جهاز الكاتب:
node tool/central_migration/migrate.js --project <prod> --org <orgId> \
  --writer-device <deviceId> --migration-id <migrationId>

# التراجع (يفتح المسار القديم مجددًا):
node tool/central_migration/migrate.js --project <prod> --org <orgId> --abort --abort-reason "..."
```

## إجراء القطع (checklist)

1. إعلان صيانة قصيرة؛ إيقاف مزامنة الأجهزة (كاتب واحد فقط على الأجهزة).
2. نسخة احتياطية + تدقيق نظيف (رمز 0) + أرشفة تقرير التدقيق.
3. مراحل `counters/parentRefs/reservations` (يمكن أن تسبق القطع بأيام —
   لا تلمس المحتوى ولا الإصدارات).
4. تشغيل `gate` مع `writerDeviceId` = جهاز الكاتب المعتمد.
5. أول جهاز يفتح التطبيق يبني الأرشيف (staging bootstrap) من الخادم المركزي —
   راقب شاشة المزامنة حتى `catching_up`.
6. إرسال أمر تجريبي (تعديل طفيف) والتحقق من `changeEvents` و`auditLogs`
   ووصول الإشعارات للأجهزة الأخرى.
7. توثيق `migrationId` في سجل التشغيل.

## سياسة الأجهزة القديمة

- أي جهاز أقدم من إصدار البروتوكول (لا يفهم `commandProtocol`) يُسحب من
  `devices` (`status != 'active'`) قبل القطع؛ قواعد Firestore ترفض كتاباته
  القديمة تلقائيًا (`legacyDomainWritesAllowed`)، لكن عدم الثقة فيه مسؤولية
  تشغيلية.
- إعادة تفعيل جهاز قديم بعد القطع غير مدعومة — يجب ترقيته أولًا.
