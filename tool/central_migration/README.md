# الترحيل والاستلام — Firestore مباشر، البروتوكول 3

التشغيل يستخدم Firebase Auth وFirestore فقط. المجلد `server/` أدوات عقد واختبارات محلية، وليس خدمة منشورة أو مسارًا لتجاوز قواعد Firestore. إعداد Firebase لا يحتوي نشر Functions، ولا يعتمد التطبيق على مرسل Push.

**هذه الأدوات لا تعني جاهزية الإصدار للإنتاج.** لا تفعّل البوابة الحقيقية دون أدلة الاستلام المطابقة لبصمة المصدر. الاختبارات المستهدفة لا تغطي وحدها أقصى حجم لكل عملية في جميع الشاشات.

## العقد الحالي

- أجهزة متعددة مسجلة ومصرح لها؛ لا قيد `writerDeviceId`.
- `schemaVersion: 3` و`writePolicy: multi_authorized` و`mode: firestore_direct_v2`.
- لا رفع للطابور القديم أو للبذور عند فتح الجلسة. المسودة المنفصلة تحتاج اختيار الإرسال.
- الطلب المرسل يحتفظ بمعرفه ومحتواه عند فقد الرد؛ يُستعاد الإيصال قبل تكرار الأثر.
- قارئ أمامي كل 30 ثانية، وحد قراءة ثابت `readTime` وتثبيت ذري للكاش والمؤشر.
- الحد العام 4 آثار أعمال للطلب. توسعة 29 أكتوبر تتيح 10 آثار لتعريفات جداول الجودة وأعمدتها فقط (9 أعمدة كحد أقصى)، مع مرجع أثر متحقق منه داخل كل سجل. لا يثبت العدد قبول كل التركيبات ضمن ميزانية القواعد. لا تُقسّم عملية أعمال ذرية لتجاوز الحد.
- التراجع التشغيلي يفرض الصيانة، ولا يفتح الرفع القديم.

## الاختبارات المحلية

من جذر المستودع، مع Node dependencies في `tool/central_migration/server`:

```powershell
firebase emulators:exec --only firestore,auth --project demo-materiallab "flutter test test/security"
firebase emulators:exec --only firestore --project demo-materiallab "node --test tool/central_migration/test/*.test.js tool/central_migration/server/test/*.test.js"
firebase emulators:exec --only firestore --project demo-materiallab "node tool/central_migration/proof.js"
node tool/central_migration/generate_rules.js --check
```

`proof.js` يثبت الترحيل والاستعادة والإحباط في الصيانة على بيانات مصطنعة فقط. اختبار النقل والقواعد الفعلي موجود في `test/security/firestore_direct_sync_test.dart` ويستخدم مستخدم Firebase عاديًا؛ Admin لتجهيز البيانات فقط.

## الأدوات

- `audit.js`: يميّز الروابط القديمة ويحسب ملاحظات التفرّد دون اختيار سجل أصح تلقائيًا.
- `raw_material_plan.js`: تصنيف للقراءة فقط، لا يختار UUID ولا يحذف سجلات يتيمة.
- `repair.js`: يقترح تغييرات مثبتة مع بصمة الحالة السابقة. التطبيق يحتاج قرارًا مراجعًا بسبب واضح ومراجع معلوم، ثم شرط نسخة السيرفر.
- `backup.js`: تصدير typed format 2 للمؤسسة وشجرتها، بما فيها مجموعات تحت وثائق أب مفقودة، وملفات المستخدمين الجذرية وشجرتها، مع SHA-256 وعدّادات.
- `restore.js`: تدقيق افتراضي؛ التطبيق يحتاج `--apply` ووضع الصيانة. يرفض المحتوى المختلف أو الوثائق الإضافية حتى تُراجع، ويثبت مقارنة المحتوى بعد الاستعادة.
- `release_gate.js`: يربط الأدلة ببصمة المصدر وبصمات ملفات التقارير، ويرفض أي بوابة غير ناجحة أو عملية غير مغطاة.

## الانتقال الحقيقي، بعد استكمال جميع موانع الإصدار

النشر يبدأ في staging. لا توجد في الإعداد الحالي هوية staging موثقة. استبدل القيم بين الأقواس بالقيم المراجعة؛ لا تستخدم مشروع الإنتاج كبيئة اختبار.

```powershell
# 1. فرض الصيانة من القواعد، ثم تصدير ثابت في مجلد جديد.
node tool/central_migration/migrate.js --project <project> --org <org> --stage freeze
node tool/central_migration/backup.js --project <project> --org <org> --out <new-backup-directory>
node tool/central_migration/audit.js --project <project> --org <org> --json <audit-report>

# 2. الإصلاحات المراجعة فقط، ثم التدقيق مجددًا. لا حذف آلي لاجتياز التدقيق.
# 3. المراحل التالية ترفض التنفيذ خارج الصيانة.
node tool/central_migration/migrate.js --project <project> --org <org> --stage audit
node tool/central_migration/migrate.js --project <project> --org <org> --stage counters
node tool/central_migration/migrate.js --project <project> --org <org> --stage parentRefs
node tool/central_migration/migrate.js --project <project> --org <org> --stage reservations

# 4. مراجعة قواعد staging واختبارها، ثم تفعيل البوابة بالأدلة المطابقة فقط.
node tool/central_migration/release_gate.js --evidence <acceptance-json>
node tool/central_migration/migrate.js --project <project> --org <org> --stage gate --migration-id <id> --evidence <acceptance-json>

# التراجع يمنع الكتابة، ولا يعيد المسار القديم.
node tool/central_migration/migrate.js --project <project> --org <org> --abort --abort-reason <reason>

# فحص الاستعادة أولًا؛ لا استعادة نسخة قديمة فوق كتابات جديدة.
node tool/central_migration/restore.js --project <project> --from <backup-directory>
```

بعد أي كتابة جديدة: احتفظ بها في تصدير مستقل، وجرّب تسويتها واستعادتها على المحاكي ثم staging. لا توجد راية force لتجاوز تعارض المحتوى.

النسخ المحلية تحت `backup/` أو `build/` قد تحتوي بيانات حساسة؛ لا تُضمّنها في Git أو حزمة تسليم عامة.

قرار نطاق الإصدار الأول: الأكبر من الحد الخاص بعائلة العملية يُحفظ مسودة غير مرسلة ويُعطّل إرساله بوضوح؛ الحد العام 4، وتعريفات الجداول وأعمدتها 10. لا يفرض استلام الإصدار تشغيل العمليات الكبيرة المعطلة؛ يفرض إثبات المنع وعدم الحفظ الجزئي واختبار كل عملية مفعّلة. راجع [العقد الحالي](../../SYNC_CURRENT_CONTRACT.md).
