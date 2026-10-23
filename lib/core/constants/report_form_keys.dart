/// Setting keys for the per-form QA form numbers (`رقم فورم الجودة`).
///
/// Historically a single global key `qa_form_no` printed on every form,
/// label and report. Each printed document now owns its own key so reports
/// can carry independent form numbers; the global key remains as a fallback
/// for setups that still set it.
class ReportFormKeys {
  ReportFormKeys._();

  /// Legacy global key — read as a fallback for every form.
  static const String global = 'qa_form_no';

  // ── Inspections ──────────────────────────────────────────────────
  /// Single-inspection PDF report.
  static const String inspectionReport = 'inspection_report_form_no';

  /// Sample / inspection label (10×5cm) and batch labels.
  static const String inspectionLabel = 'inspection_label_form_no';

  /// Lab equipment sticker.
  static const String equipmentLabel = 'equipment_label_form_no';

  // ── Period reports ───────────────────────────────────────────────
  static const String dailyReport = 'daily_report_form_no';
  static const String monthlyReport = 'monthly_report_form_no';
  static const String yearlyReport = 'yearly_report_form_no';
  static const String followUpReport = 'followup_report_form_no';

  // ── Lab (work) reports ───────────────────────────────────────────
  static const String labDailyReport = 'lab_daily_report_form_no';
  static const String labMonthlyReport = 'lab_monthly_report_form_no';
  static const String labYearlyReport = 'lab_yearly_report_form_no';

  /// Non-conformance (NCR) report.
  static const String ncrReport = 'ncr_report_form_no';

  /// Every key, used to seed the settings table defaults.
  static const List<String> all = <String>[
    global,
    inspectionReport,
    inspectionLabel,
    equipmentLabel,
    dailyReport,
    monthlyReport,
    yearlyReport,
    followUpReport,
    labDailyReport,
    labMonthlyReport,
    labYearlyReport,
    ncrReport,
  ];
}
