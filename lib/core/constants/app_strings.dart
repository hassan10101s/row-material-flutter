/// Small localization helper. The app UI shows one active language; screens
/// call `t(ar, en)` where the active language decides which string to show.
class AppText {
  static bool arabic = true;

  static void useLanguage(String code) => arabic = code != 'en';

  static String t(String ar, String en) => arabic ? ar : en;
}

/// Central bilingual strings.
class AppStrings {
  static String get appTitle => AppText.t('مختبر المواد الخام', 'Raw Material Lab');
  static String get tagline => AppText.t(
      'نظام فحص ومراقبة جودة المواد الخام', 'Raw Material Inspection & QC System');

  static String get dashboard => AppText.t('لوحة التحكم', 'Dashboard');
  static String get inspections => AppText.t('سجل الفحوصات', 'Inspections');
  static String get newInspection => AppText.t('فحص جديد', 'New Inspection');
  static String get materials => AppText.t('المواد الخام', 'Materials');
  static String get lab => AppText.t('المختبر', 'Lab');
  static String get reports => AppText.t('التقارير', 'Reports');
  static String get settings => AppText.t('الإعدادات', 'Settings');
  static String get reference => AppText.t('المرجعية', 'Reference');
  static String get login => AppText.t('تسجيل الدخول', 'Login');
  static String get logout => AppText.t('تسجيل الخروج', 'Logout');
  static String get welcome => AppText.t('أهلاً بك', 'Welcome');

  static String get approved => AppText.t('قبول نهائي', 'Approved');
  static String get conditional => AppText.t('قبول مشروط', 'Conditional');
  static String get partialRejection => AppText.t('رفض جزئي', 'Partial Rejection');
  static String get fullRejection => AppText.t('رفض كامل', 'Full Rejection');
  static String get pending => AppText.t('قيد الانتظار', 'Pending');

  static String get save => AppText.t('حفظ', 'Save');
  static String get cancel => AppText.t('إلغاء', 'Cancel');
  static String get delete => AppText.t('حذف', 'Delete');
  static String get edit => AppText.t('تعديل', 'Edit');
  static String get search => AppText.t('بحث', 'Search');
  static String get exportPdf => AppText.t('تصدير PDF', 'Export PDF');
  static String get print => AppText.t('طباعة', 'Print');
  static String get shareWhatsapp => AppText.t('مشاركة واتساب', 'Share WhatsApp');
  static String get openPdfFolder => AppText.t('فتح مجلد PDF', 'Open PDF Folder');
  static String get preview => AppText.t('معاينة', 'Preview');
  static String get toggleTheme => AppText.t('تبديل المظهر', 'Toggle theme');

  static String get inventory => AppText.t('المخزون', 'Inventory');
  static String get analyses => AppText.t('التحليلات', 'Analyses');
  static String get products => AppText.t('المنتجات', 'Products');
  static String get constants => AppText.t('الثوابت', 'Constants');
  static String get runTest => AppText.t('تشغيل اختبار', 'Run Test');
  static String get testHistory => AppText.t('سجل الفحوصات', 'Test History');
  static String get worksheet => AppText.t('ورقة العمل', 'Worksheet');
  static String get labReports => AppText.t('تقارير المختبر', 'Lab Reports');
  static String get activityLog => AppText.t('سجل النشاط', 'Activity Log');

  static String get backup => AppText.t('نسخ احتياطي', 'Backup');
  static String get restore => AppText.t('استعادة', 'Restore');
  static String get users => AppText.t('المستخدمون', 'Users');

  static String get decisionReason => AppText.t('سبب القرار', 'Decision Reason');
  static String get followUpNote => AppText.t('ملاحظة المتابعة', 'Follow-up Note');
  static String get rejectedQuantity => AppText.t('الكمية المرفوضة', 'Rejected Qty');
}