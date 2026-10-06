import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';

/// Severity and status pills for the NCR report.
///
/// This exists instead of reusing `AppStatusBadge` on purpose. That widget maps
/// its input through a fixed approval vocabulary - anything it does not
/// recognise collapses to "Pending" - so handing it `Critical`, `Verified` or
/// `InProgress` rendered every non-conforming row as "Pending". A report whose
/// whole job is distinguishing a critical open finding from a closed minor one
/// cannot share a badge that erases the difference.
class NcrPill extends StatelessWidget {
  const NcrPill(this.label, this.color, {super.key});

  final String label;
  final Color color;

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

/// AppColors.neutral needs a [BuildContext]; these factories are top-level, so
/// they name the same token (	extMuted) directly.
///
/// Severity of a finding. Critical is the only one that gets the danger colour,
/// so a wall of rows still reads at a glance.
NcrPill ncrSeverityPill(String severity) => switch (severity) {
  'Critical' => NcrPill(AppText.t('حرجة', 'Critical'), AppColors.danger),
  'Major' => NcrPill(AppText.t('كبرى', 'Major'), AppColors.warning),
  'Minor' => NcrPill(AppText.t('بسيطة', 'Minor'), AppColors.info),
  _ => NcrPill(
    severity.isEmpty ? AppText.t('غير محدد', 'Unrated') : severity,
    AppColors.textMuted,
  ),
};

/// Lifecycle state of a finding.
///
/// `Verified` is deliberately success-coloured rather than neutral: the plan
/// counts it as still open, so a reader must be able to see at a glance that it
/// is finished and waiting on someone, not finished.
NcrPill ncrStatePill(String status) => switch (status) {
  'Open' => NcrPill(AppText.t('مفتوحة', 'Open'), AppColors.info),
  'Assigned' => NcrPill(AppText.t('مسندة', 'Assigned'), AppColors.warning),
  'InProgress' => NcrPill(
    AppText.t('قيد المعالجة', 'In progress'),
    AppColors.warning,
  ),
  'Verified' => NcrPill(AppText.t('تم التحقق', 'Verified'), AppColors.success),
  'Closed' => NcrPill(AppText.t('مغلقة', 'Closed'), AppColors.success),
  'Rejected' => NcrPill(AppText.t('مرفوضة', 'Rejected'), AppColors.danger),
  _ => NcrPill(
    status.isEmpty ? AppText.t('غير محدد', 'Unknown') : status,
    AppColors.textMuted,
  ),
};

/// CAPA state, which has its own vocabulary and its own failure modes.
NcrPill ncrCapaPill(String status) => switch (status) {
  'Open' => NcrPill(AppText.t('مفتوح', 'Open'), AppColors.info),
  'InProgress' => NcrPill(
    AppText.t('قيد التنفيذ', 'In progress'),
    AppColors.warning,
  ),
  'VerifiedEffective' => NcrPill(
    AppText.t('فعّال', 'Effective'),
    AppColors.success,
  ),
  'VerifiedIneffective' => NcrPill(
    AppText.t('غير فعّال', 'Ineffective'),
    AppColors.danger,
  ),
  'Closed' => NcrPill(AppText.t('مغلق', 'Closed'), AppColors.textMuted),
  'Rejected' => NcrPill(AppText.t('مرفوض', 'Rejected'), AppColors.danger),
  _ => NcrPill(
    status.isEmpty ? AppText.t('غير محدد', 'Unknown') : status,
    AppColors.textMuted,
  ),
};
