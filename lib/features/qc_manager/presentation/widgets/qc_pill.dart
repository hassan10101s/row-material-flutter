import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../domain/qc_enums.dart';

/// Small status pills for the QC screens.
///
/// A template has no `status` column - it has `is_published`/`is_archived` -
/// so [publication] renders that pair into a word rather than leaving every
/// caller to spell the mapping out again.
class QcPill extends StatelessWidget {
  const QcPill(this.label, this.color, {super.key});

  final String label;
  final Color color;

  static String typeLabel(String type) => switch (type) {
    QcTemplateType.incoming => AppText.t('وارد', 'Incoming'),
    QcTemplateType.inProcess => AppText.t('أثناء التصنيع', 'In process'),
    QcTemplateType.finalCheck => AppText.t('فحص نهائي', 'Final check'),
    QcTemplateType.packing => AppText.t('تغليف', 'Packing'),
    QcTemplateType.process => AppText.t('عملية', 'Process'),
    QcTemplateType.rawMaterial => AppText.t('خام', 'Raw material'),
    QcTemplateType.finishedGoods => AppText.t('تامة الصنع', 'Finished goods'),
    QcTemplateType.calibration => AppText.t('معايرة', 'Calibration'),
    _ => AppText.t('أخرى', 'Other'),
  };

  static String publicationLabel({
    required bool published,
    bool archived = false,
  }) {
    if (archived) return AppText.t('مؤرشف', 'Archived');
    return published
        ? AppText.t('منشور', 'Published')
        : AppText.t('مسودة', 'Draft');
  }

  static Color publicationColor({
    required bool published,
    bool archived = false,
  }) {
    if (archived) return AppColors.textMuted;
    return published ? AppColors.success : AppColors.textMuted;
  }

  /// Whether a checklist is issued, so the wording lives in one place.
  ///
  /// Named booleans rather than the model: this widget also dresses findings and
  /// inspections, and it should not have to import a model it does not describe.
  static Widget publication({required bool published, bool archived = false}) =>
      QcPill(
        publicationLabel(published: published, archived: archived),
        publicationColor(published: published, archived: archived),
      );

  static Widget type(String type) =>
      QcPill(typeLabel(type), AppColors.textMuted);

  static Widget version(String label) => QcPill(label, AppColors.info);

  /// Findings and inspections share the NC lifecycle, so they share its labels.
  static String openStateLabel(String state) => switch (state) {
    NcStatus.open => AppText.t('مفتوح', 'Open'),
    NcStatus.closed => AppText.t('مغلق', 'Closed'),
    NcStatus.verified => AppText.t('تم التحقق', 'Verified'),
    _ => state,
  };

  static Color openStateColor(String state) => switch (state) {
    NcStatus.open => AppColors.warning,
    NcStatus.closed => AppColors.success,
    NcStatus.verified => AppColors.info,
    _ => AppColors.textMuted,
  };

  static Widget openState(String state) =>
      QcPill(openStateLabel(state), openStateColor(state));

  // ── Inspections ────────────────────────────────────────────────────────

  /// Workflow state of an inspection sheet.
  ///
  /// `Rejected` is danger-coloured even though it is a finished state: a sheet
  /// that came back from review is the one a reader most needs to spot, and
  /// painting it neutral would hide it.
  static String inspectionStatusLabel(String status) => switch (status) {
    QcInspectionStatus.inProgress => AppText.t('جارية', 'In progress'),
    QcInspectionStatus.submitted => AppText.t('مُرسلة', 'Submitted'),
    QcInspectionStatus.reviewed => AppText.t('تمت مراجعتها', 'Reviewed'),
    QcInspectionStatus.approved => AppText.t('معتمدة', 'Approved'),
    QcInspectionStatus.rejected => AppText.t('مرفوضة', 'Rejected'),
    QcInspectionStatus.closed => AppText.t('مغلقة', 'Closed'),
    _ => status,
  };

  static Color inspectionStatusColor(String status) => switch (status) {
    QcInspectionStatus.inProgress => AppColors.info,
    QcInspectionStatus.submitted => AppColors.warning,
    QcInspectionStatus.reviewed => AppColors.warning,
    QcInspectionStatus.approved => AppColors.success,
    QcInspectionStatus.rejected => AppColors.danger,
    QcInspectionStatus.closed => AppColors.textMuted,
    _ => AppColors.textMuted,
  };

  static Widget inspectionStatus(String status) =>
      QcPill(inspectionStatusLabel(status), inspectionStatusColor(status));

  /// Rolled-up verdict of the whole sheet.
  static String inspectionResultLabel(String result) => switch (result) {
    QcOverallResult.pass => AppText.t('مطابق', 'Pass'),
    QcOverallResult.conditional => AppText.t('مطابق بشروط', 'Conditional'),
    QcOverallResult.fail => AppText.t('غير مطابق', 'Fail'),
    _ => AppText.t('لم يُقيَّم', 'Pending'),
  };

  static Color inspectionResultColor(String result) => switch (result) {
    QcOverallResult.pass => AppColors.success,
    QcOverallResult.conditional => AppColors.warning,
    QcOverallResult.fail => AppColors.danger,
    _ => AppColors.textMuted,
  };

  static Widget inspectionResult(String result) =>
      QcPill(inspectionResultLabel(result), inspectionResultColor(result));

  /// What an inspection was raised against.
  static String refTypeLabel(String type) => switch (type) {
    QcRefType.job => AppText.t('أمر تشغيل', 'Job'),
    QcRefType.batch => AppText.t('دفعة', 'Batch'),
    QcRefType.lot => AppText.t('لوط', 'Lot'),
    QcRefType.po => AppText.t('أمر شراء', 'PO'),
    QcRefType.grn => AppText.t('إذن استلام', 'GRN'),
    QcRefType.material => AppText.t('مادة', 'Material'),
    QcRefType.wip => AppText.t('تحت التشغيل', 'WIP'),
    QcRefType.finishedGoods => AppText.t('تامة الصنع', 'Finished goods'),
    QcRefType.order => AppText.t('طلب', 'Order'),
    _ => AppText.t('أخرى', 'Other'),
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12.spMax,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
