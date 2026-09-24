import 'app_strings.dart';

/// Central bilingual error catalog.
///
/// Every user-facing error message lives here once, in both Arabic and
/// English. Repositories / domain rules / factories only reference a catalog
/// getter and never embed a raw literal, so the shown text always matches the
/// active UI language (through `AppText.t`).
class AppErrors {
  AppErrors._();

  // ── Generic field validators (app_format.dart) ───────────────────────────

  static String fieldRequired(String label) =>
      AppText.t('يجب إدخال "$label".', '"$label" is required.');
  static String fieldMaxLength(String label, Object max) => AppText.t(
      'يجب ألا يتجاوز "$label" $max حرفاً.',
      '"$label" must be at most $max characters.');
  static String fieldNumbersOnly(String label) =>
      AppText.t('يجب أن يحتوي "$label" على أرقام فقط.',
          '"$label" must contain numbers only.');
  static String fieldValueRequired(String label) =>
      AppText.t('قيمة "$label" مطلوبة.', '"$label": value is required.');
  static String fieldExceedsMaxLength(String label) =>
      AppText.t('"$label" يتجاوز الحد الأقصى.', '"$label" exceeds max length.');
  static String fieldNonNegative(String label) => AppText.t(
      'يجب أن يكون "$label" رقماً غير سالب.',
      '"$label" must be a non-negative number.');
  static String fieldSampleValues(Object key, Object sampleCount) => AppText.t(
      'نتيجة "$key" يجب أن توفر قيمة لكل من $sampleCount عينة (عينات).',
      '"$key" result must provide a value for each of the $sampleCount sample(s).');
  static String fieldOneValuePerSample(Object key, Object sampleCount) =>
      AppText.t('نتيجة "$key" يجب أن توفر قيمة واحدة لكل عينة ($sampleCount).',
          '"$key" result must provide one value per sample ($sampleCount).');

  // ── Raw materials / inventory (lab) ──────────────────────────────────────

  static String get materialNameRequired =>
      AppText.t('اسم المادة مطلوب.', 'Material name is required.');
  static String get materialTypeInvalid =>
      AppText.t('نوع المادة يجب أن يكون liquid أو powder.',
          'Material type must be liquid or powder.');
  static String get unitNotSupported =>
      AppText.t('الوحدة غير مدعومة.', 'Unit is not supported.');
  static String get materialExists =>
      AppText.t('يوجد مادة بنفس الاسم بالفعل.', 'A material with this name already exists.');
  static String get inventoryItemNotFound =>
      AppText.t('مادة المخزون غير موجودة.', 'Inventory item was not found.');
  static String get failedCreateInventory =>
      AppText.t('فشل إنشاء المادة في المخزون.', 'Failed to create inventory item.');
  static String get worksheetRowNotFound =>
      AppText.t('صف ورقة العمل غير موجود.', 'Worksheet row not found.');
  static String get insufficientStock => AppText.t(
      'لا يوجد رصيد كيمياء كافي لإكمال الاختبار.',
      'Not enough chemistry balance to complete the test.');
  static String insufficientStockItem(Object name, Object requested,
          Object available, Object unit) =>
      AppText.t(
          '«$name» — المطلوب $requested $unit، المتاح $available $unit',
          '«$name» — required $requested $unit, available $available $unit');

  // ── Products (lab) ───────────────────────────────────────────────────────

  static String get productNameRequired =>
      AppText.t('اسم المنتج مطلوب.', 'Product name is required.');
  static String get productExists =>
      AppText.t('يوجد منتج بنفس الاسم بالفعل.', 'A product with this name already exists.');
  static String get productNotFound =>
      AppText.t('المنتج غير موجود.', 'Product was not found.');

  // ── Analyses (lab) ───────────────────────────────────────────────────────

  static String get analysisIdRangeRequired =>
      AppText.t('معرف التحليل مطلوب داخل النطاقات.',
          'Analysis id is required inside ranges.');
  static String get analysisNameRequired =>
      AppText.t('اسم التحليل مطلوب.', 'Analysis name is required.');
  static String get analysisExists =>
      AppText.t('يوجد تحليل بنفس الاسم بالفعل.',
          'An analysis with the same name already exists.');
  static String get analysisNotFound =>
      AppText.t('التحليل غير موجود.', 'Analysis was not found.');
  static String get testNotFound =>
      AppText.t('الاختبار غير موجود.', 'Test was not found.');
  static String get sourceTypeInvalid => AppText.t(
      'نوع المصدر يجب أن يكون raw_material أو product.',
      'Source type must be raw_material or product.');
  static String entryCodeNotFound(Object code) => AppText.t(
      'كود الدخول غير موجود في سجل الدخول: $code',
      'Entry code was not found in the inspection log: $code');
  static String get sampleAndSourceRequired => AppText.t(
      'اسم العينة واسم المصدر مطلوبان.',
      'Sample name and source are required.');
  static String get rowAlreadyCancelled =>
      AppText.t('تم إلغاء هذا الصف بالفعل.', 'This row has already been cancelled.');
  static String get cancelReasonRequired => AppText.t(
      'سبب الإلغاء مطلوب للحفاظ على سجل التدقيق.',
      'Cancellation reason is required to keep the audit log.');

  // ── Constants (lab) ──────────────────────────────────────────────────────

  static String get constantNameRequired =>
      AppText.t('اسم الثابت مطلوب.', 'Constant name is required.');
  static String get constantSymbolInvalid => AppText.t(
      'رمز الثابت يجب أن يبدأ بحرف (A-Z, a-z أو _).',
      'Constant symbol must start with a letter (A-Z, a-z or _).');
  static String get constantPrecisionRange =>
      AppText.t('الدقة يجب أن تكون بين 0 و 12.',
          'Precision must be between 0 and 12.');
  static String get constantDerivedExprRequired =>
      AppText.t('الثابت المشتق يتطلب تعبيراً.',
          'Derived constant requires an expression.');
  static String constantExprInvalid(Object msg) => AppText.t(
      'تعبير الثابت غير صالح: $msg', 'Invalid constant expression: $msg');
  static String get constantValueNumeric =>
      AppText.t('قيمة الثابت يجب أن تكون رقماً.',
          'Constant value must be numeric.');
  static String get constantExists =>
      AppText.t('يوجد ثابت بنفس الاسم بالفعل.',
          'A constant with this name already exists.');
  static String get constantNotFound =>
      AppText.t('الثابت غير موجود.', 'Global constant was not found.');

  // ── Lab reports (shared) ─────────────────────────────────────────────────

  static String get reportTypeInvalid => AppText.t(
      'يجب أن يكون نوع التقرير اليومي أو الشهري أو السنوي.',
      'Report type must be daily, monthly or yearly.');
  static String get dailyReportDateRequired =>
      AppText.t('التاريخ مطلوب للتقرير اليومي.',
          'Date is required for the daily report.');
  static String get monthlyReportDateRequired =>
      AppText.t('الشهر والسنة مطلوبان للتقرير الشهري.',
          'Month and year are required for the monthly report.');
  static String get yearlyReportDateRequired =>
      AppText.t('السنة مطلوبة للتقرير السنوي.',
          'Year is required for the yearly report.');
  static String get reportDateRequired =>
      AppText.t('التاريخ مطلوب', 'Date is required.');
  static String get reportDateInvalid => AppText.t(
      'صيغة التاريخ غير صحيحة. استخدم الشكل YYYY-MM-DD.',
      'Invalid date format. Use YYYY-MM-DD.');
  static String get reportsListRequired =>
      AppText.t('قائمة الفحوصات مطلوبة', 'Inspection list is required.');
  static String get selectAtLeastOne =>
      AppText.t('حدد سجلات واحدة على الأقل.', 'Select at least one record.');
  static String get maxLabels100 =>
      AppText.t('الحد الأقصى 100 ملصق في المرة الواحدة.',
          'Maximum 100 labels at a time.');

  // ── Inspections ──────────────────────────────────────────────────────────

  static String get max3Samples =>
      AppText.t('الحد الأقصى 3 عينات.', 'A maximum of 3 samples are allowed.');
  static String get materialSelectionRequired =>
      AppText.t('اختيار المادة مطلوب.', 'Material selection is required.');
  static String get materialArchived => AppText.t(
      'المادة المختارة غير نشطة (مؤرشفة) ولا يمكن استخدامها في فحص جديد.',
      'Selected material is inactive (archived) and cannot be used in a new inspection.');
  static String get sampleTakerMin3 => AppText.t(
      'يجب أن يتكون اسم آخذ العينات من 3 أحرف على الأقل.',
      'Sample taker name must be at least 3 characters.');
  static String get supplierMin3 =>
      AppText.t('يجب أن يتكون اسم المورد من 3 أحرف على الأقل.',
          'Supplier name must be at least 3 characters.');
  static String get inspectionMaxSamples =>
      AppText.t('يُسمح بثلاث عينات كحد أقصى.',
          'A maximum of 3 samples are allowed.');
  static String get entryCodeAlreadyExists => AppText.t(
      'كود الدخول المُنشأ موجود بالفعل. حاول مرة أخرى.',
      'Generated entry code already exists. Please retry.');
  static String get inspectionNotFound =>
      AppText.t('الفحص غير موجود.', 'Inspection not found.');
  static String get noDecisionChange =>
      AppText.t('لا يوجد تغيير في القرار.', 'No decision change detected.');
  static String get decisionStatusRequired =>
      AppText.t('حالة القرار مطلوبة.', 'Decision status is required.');
  static String get decisionReasonRequired => AppText.t(
      'سبب القرار مطلوب (يجب إدخال البيانات).',
      'Decision reason is required (must enter data).');
  static String get rejectedQtyRequired => AppText.t(
      'الكمية المرفوضة مطلوبة للرفض الجزئي (يجب إدخال الكمية).',
      'Rejected quantity is required for partial rejection (must enter the quantity).');
  static String get rejectedQtyExceeds =>
      AppText.t('الكمية المرفوضة لا يمكن أن تتجاوز كمية الشحنة.',
          'Rejected quantity cannot exceed the lot quantity.');
  static String get followUpNoteRequired => AppText.t(
      'ملاحظة المتابعة مطلوبة في القبول المبدئي.',
      'Follow-up note is required for conditional approval.');
  static String maxDecisionUpdates(Object max) => AppText.t(
      'تم الوصول إلى الحد الأقصى من تحديثات قرار الجودة ($max مرات).',
      'Reached maximum quality decision updates ($max times).');

  // ── Auth / users ─────────────────────────────────────────────────────────

  static String get setupAlreadyCompleted =>
      AppText.t('تم إعداد النظام بالفعل.', 'Setup has already been completed.');
  static String get usernameRequired =>
      AppText.t('اسم المستخدم مطلوب.', 'Username is required.');
  static String get usernameExists =>
      AppText.t('اسم المستخدم موجود مسبقاً.', 'Username already exists.');
  static String get invalidCredentials => AppText.t(
      'اسم المستخدم أو كلمة المرور غير صحيحة.',
      'Invalid username or password.');
  static String get accountDisabled =>
      AppText.t('الحساب معطل.', 'Account is disabled.');
  static String get licenseSystemExpired => AppText.t(
      'انتهت صلاحية استخدام النظام. يرجى الاتصال بالمطور.',
      'Application usage has expired. Please contact the developer.');
  static String get licenseAppExpired => AppText.t(
      'انتهت صلاحية رخصة التطبيق.', 'Application license has expired.');
  static String get userNotFound =>
      AppText.t('المستخدم غير موجود.', 'User not found.');
  static String get cannotModifyDeveloper =>
      AppText.t('لا يمكن تعديل حساب المطور.', 'Cannot modify the Developer account.');
  static String get cannotDeleteDeveloper =>
      AppText.t('لا يمكن حذف حساب المطور.', 'Cannot delete the Developer account.');
  static String get cannotDeleteSelf => AppText.t(
      'لا يمكن حذف حسابك الخاص.', 'You cannot delete your own account.');
  static String deleteGuardHasRecords(Object name) => AppText.t(
      'لا يمكن حذف "$name" لأنه لديه سجلات فحوصات قائمة.',
      'Cannot delete "$name" because they have active inspection records.');
  static String deleteGuardDecisionLogs(Object name) => AppText.t(
      'لا يمكن حذف "$name" لأنه لديه سجل قرارات في سجل التدقيق.',
      'Cannot delete "$name" because they have a decision log in the audit trail.');
  static String get userIdHasInspectionRecords => AppText.t(
      'لا يمكن حذف المستخدم: لديه سجلات فحوصات قائمة. أعد تعيين الفحوصات أو احذفها أولاً.',
      'Cannot delete user: they have existing inspection records. '
      'Reassign or delete inspections first.');
  static String get userIdHasStatusHistoryRecords => AppText.t(
      'لا يمكن حذف المستخدم: لديه سجلات في سجل القرارات.',
      'Cannot delete user: they have existing status history records.');

  // ── Reference (materials / parameters / units) ───────────────────────────

  static String get materialNotFound =>
      AppText.t('المادة غير موجودة.', 'Material not found.');
  static String get referenceMaterialNameRequired =>
      AppText.t('اسم المادة مطلوب.', 'Material name is required.');
  static String get referenceMaterialCodeRequired =>
      AppText.t('كود المادة مطلوب.', 'Material code is required.');
  static String referenceMaterialExists(Object name) => AppText.t(
      'المادة "$name" موجودة بالفعل.', 'Material "$name" already exists.');
  static String get parameterNameRequired =>
      AppText.t('اسم البارامتر مطلوب.', 'Parameter name is required.');
  static String get parameterTypeInvalid => AppText.t(
      'نوع البارامتر يجب أن يكون chemical أو physical.',
      'parameter_type must be chemical or physical.');
  static String get unitSymbolRequired =>
      AppText.t('رمز الوحدة مطلوب.', 'Unit symbol is required.');

  // ── Backup / migration ───────────────────────────────────────────────────

  static String get backupIntegrityFail => AppText.t(
      'ملف النسخة الاحتياطية تالف (فشل فحص السلامة integrity check).',
      'Backup file is corrupt (integrity check failed).');
  static String backupMissingTables(Object missing) => AppText.t(
      'ملف النسخة الاحتياطية غير صالح: الجداول المطلوبة ناقصة: $missing',
      'Invalid backup file: required tables are missing: $missing');
  static String backupSchemaTooOld(Object table, Object missingCols) =>
      AppText.t(
          'ملف النسخة الاحتياطية قديم جداً أو غير متوافق مع هذا الإصدار: '
          'جدول "$table" ينقصه الأعمدة: $missingCols',
          'Backup file is too old or incompatible with this version: '
          'table "$table" is missing columns: $missingCols');
  static String backupUnreadable(Object err) => AppText.t(
      'ملف النسخة الاحتياطية تالف أو غير قابل للقراءة: $err',
      'Backup file is corrupt or unreadable: $err');
  static String backupUpgradeFailed(Object err) => AppText.t(
      'تعذر ترقية النسخة الاحتياطية إلى بنية النسخة الحالية من البرنامج: $err',
      'Could not upgrade the backup to the current app schema: $err');
  static String get backupIntegrityAfterUpgrade => AppText.t(
      'فشل التحقق من سلامة النسخة الاحتياطية بعد الترقية التلقائية.',
      'Backup integrity verification failed after automatic upgrade.');
  static String backupRestoreFailed(Object err) => AppText.t(
      'فشل استرداد قاعدة البيانات: $err', 'Failed to restore database: $err');
  static String get invalidMaterialsDb => AppText.t(
      'قاعدة بيانات المواد غير صالحة: جدول reference_materials ناقص.',
      'Invalid materials database: missing reference_materials table.');
  static String get invalidParamsDb => AppText.t(
      'قاعدة بيانات المواد غير صالحة: جدول parameters ناقص.',
      'Invalid materials database: missing parameters table.');
  static String incompatibleMaterialsTable(Object missing) => AppText.t(
      'جدول المواد غير متوافق (ناقص: $missing).',
      'Incompatible materials table (missing: $missing).');
  static String incompatibleParamsTable(Object missing) => AppText.t(
      'جدول البارامترات غير متوافق (ناقص: $missing).',
      'Incompatible parameters table (missing: $missing).');
  static String get backupPathMustDiffer => AppText.t(
      'يجب أن يختلف مسار النسخة الاحتياطية عن مسار قاعدة البيانات النشطة.',
      'Backup path must be different from the active database path.');
  static String get backupVerifiedFail => AppText.t(
      'تم إنشاء النسخة الاحتياطية لكن فشل التحقق من سلامتها.',
      'Backup was created but integrity verification failed.');
  static String get restoreActiveDbSelected => AppText.t(
      'الملف المختار هو قاعدة البيانات النشطة نفسها.',
      'Selected file is already the active database.');
  static String usersTableMissingColumns(Object missing) => AppText.t(
      'جدول المستخدمين في قاعدة البيانات المصدر ينقصه أعمدة: $missing',
      'Source database users table is missing columns: $missing');
  static String get restoreSuccess => AppText.t(
      'تم استرداد قاعدة البيانات بنجاح.',
      'Database was restored successfully.');

  // ── QR / logo / worksheet seeding ────────────────────────────────────────

  static String get qrPayloadEmpty =>
      AppText.t('محتوى الباركود فارغ.', 'QR payload is empty.');
  static String get qrCapacityExceeded => AppText.t(
      'البيانات تتجاوز سعة الباركود (الإصدار > 40).',
      'Data exceeds QR code capacity (version > 40)');
  static String get qrTruncatedWarning => AppText.t(
      'تحذير: تم اختزال محتوى الباركود لتناسب الحد الأقصى.',
      'Warning: barcode content was truncated to fit the limit.');

  // ── Reports / labels (report_service.dart, qr_render.dart) ───────────────

  static String get batchLabelsSelectAtLeastOne =>
      AppText.t('حدد سجلات واحدة على الأقل.',
          'Select at least one record.');
  static String get batchLabelsMax100 =>
      AppText.t('الحد الأقصى 100 ملصق في المرة الواحدة.',
          'Maximum of 100 labels at a time.');
  static String get dailyDateRequired =>
      AppText.t('التاريخ مطلوب', 'Date is required');
  static String get dateFormatInvalid => AppText.t(
      'صيغة التاريخ غير صحيحة. استخدم الشكل YYYY-MM-DD.',
      'Invalid date format. Use YYYY-MM-DD.');
  static String get inspectionsListRequired =>
      AppText.t('قائمة الفحوصات مطلوبة', 'Inspections list is required');
  static String get logoNotFound =>
      AppText.t('شعار التقرير غير موجود.', 'Report logo not found.');
  static String get logoEmpty =>
      AppText.t('ملف شعار التقرير فارغ.', 'Report logo file is empty.');
  static String get logoFormat => AppText.t(
      'صيغة غير مدعومة. استخدم PNG أو JPEG.',
      'Unsupported image format. Use PNG or JPEG.');
  static String seedNoWorksheet(Object label) =>
      AppText.t('لا توجد ورقة عمل في $label.',
          'No worksheet found in $label.');
  static String seedMissingColumns(Object missing) => AppText.t(
      'ملف Reference.xlsx ينقصه الأعمدة المطلوبة: $missing',
      'Reference.xlsx is missing required columns: $missing');

  // ── Formula engine ───────────────────────────────────────────────────────

  static String formulaUnitDimMismatch(Object symbol, Object unit,
          Object targetDim) =>
      AppText.t(
          'وحدة الثابت "$symbol" ("$unit") لا تطابق البعد المطلوب "$targetDim".',
          "Constant '$symbol' unit '$unit' does not match expected dimension '$targetDim'.");
  static String get formulaCircularDependency => AppText.t(
      'تبعية دائرية في الثوابت المشتقة.',
      'Circular dependency in derived constants.');
  static String formulaDerivedNoExpression(Object symbol) => AppText.t(
      'الثابت المشتق "$symbol" لا يحتوي على تعبير.',
      "Derived constant '$symbol' has no expression.");
  static String formulaEvalError(Object symbol, Object msg) => AppText.t(
      'خطأ في تقييم الثابت المشتق "$symbol": $msg',
      "Error evaluating derived constant '$symbol': $msg");
  static String formulaMissingConstantValue(Object symbol) => AppText.t(
      'قيمة مفقودة للثابت "$symbol".',
      "Missing value for constant '$symbol'.");
  static String formulaBelowMin(Object symbol, Object value, Object lo) =>
      AppText.t('الثابت "$symbol" ($value) أقل من الحد الأدنى ($lo).',
          "Constant '$symbol' ($value) is below minimum ($lo).");
  static String formulaAboveMax(Object symbol, Object value, Object hi) =>
      AppText.t('الثابت "$symbol" ($value) أعلى من الحد الأقصى ($hi).',
          "Constant '$symbol' ($value) is above maximum ($hi).");
  static String formulaResolveFailed(Object list) => AppText.t(
      'تعذر حل الثوابت، تحقق من التعبيرات الناقصة أو الدائرية: $list',
      'Could not resolve constant(s), check missing/cyclic expressions: $list');
  static String formulaMissingValues(Object list) =>
      AppText.t('قيم مفقودة لـ: $list', 'Missing values for: $list');
  static String get formulaResultNotNumeric =>
      AppText.t('نتيجة المعادلة ليست رقمية.', 'Formula result is not numeric.');
  static String get formulaEmpty =>
      AppText.t('المعادلة فارغة.', 'Formula is empty.');
  static String get formulaInvalidSyntax =>
      AppText.t('صيغة المعادلة غير صحيحة.', 'Invalid formula syntax.');
  static String get formulaInvalidNumber =>
      AppText.t('رقم غير صحيح داخل المعادلة.', 'Invalid number in formula.');
  static String formulaInvalidName(Object name) =>
      AppText.t('اسم غير صحيح داخل المعادلة: $name',
          'Invalid name in formula: $name');
  static String formulaMissingFieldValue(Object name) =>
      AppText.t('قيمة مفقودة للحقل: $name', 'Missing value for field: $name');
  static String get formulaDivisionByZero =>
      AppText.t('القسمة على صفر داخل المعادلة.',
          'Division by zero in formula.');
  static String formulaInvalidPower(Object left, Object right) => AppText.t(
      'تعبير أس صحيح غير صالح ($left ** $right).',
      'Invalid power expression ($left ** $right).');
  static String get formulaUnsupportedOperator =>
      AppText.t('معامل غير مدعوم داخل المعادلة.',
          'Unsupported operator in formula.');
  static String formulaInvalidArguments(Object name) => AppText.t(
      'وسائط غير صحيحة للدالة $name.',
      'Invalid arguments for function $name.');
  static String formulaUnsupportedFunction(Object name) =>
      AppText.t('دالة غير مدعومة: $name', 'Unsupported function: $name');
  static String formulaMissingVariables(Object list) => AppText.t(
      'دلائل المعادلة ناقصة: $list',
      'Formula variables are missing: $list');
  static String formulaError(Object message) =>
      AppText.t('خطأ في المعادلة: $message', 'Formula error: $message');
}