import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../domain/qc_enums.dart';

/// SOP status and criticality pills.
///
/// The status codes come straight from [SopStatus] rather than being spelled
/// out here: a second copy of the vocabulary is a second thing to forget to
/// update, and the switch below would silently start falling through to
/// "Unknown" the day someone added a state.
///
/// `Approved` is success-coloured and `Obsolete`/`Archived` are muted rather
/// than danger-coloured: a retired procedure is the correct end state, not a
/// problem, and painting it red would bury the drafts actually awaiting work.
class SopPill extends StatelessWidget {
  const SopPill(this.label, this.color, {super.key});

  final String label;
  final Color color;

  static String statusLabel(String status) => switch (status) {
    SopStatus.draft => AppText.t('مسودة', 'Draft'),
    SopStatus.pending => AppText.t('بانتظار الموافقة', 'Awaiting approval'),
    SopStatus.approved => AppText.t('معتمد', 'Approved'),
    SopStatus.published => AppText.t('منشور', 'Published'),
    SopStatus.obsolete => AppText.t('ملغى', 'Obsolete'),
    SopStatus.archived => AppText.t('مؤرشف', 'Archived'),
    _ => status.isEmpty ? AppText.t('غير معروف', 'Unknown') : status,
  };

  static Color statusColor(String status) => switch (status) {
    SopStatus.draft => AppColors.textMuted,
    SopStatus.pending => AppColors.warning,
    SopStatus.approved => AppColors.success,
    SopStatus.published => AppColors.info,
    SopStatus.obsolete => AppColors.textMuted,
    SopStatus.archived => AppColors.textMuted,
    _ => AppColors.textMuted,
  };

  static Widget status(String status) =>
      SopPill(statusLabel(status), statusColor(status));

  static String criticalityLabel(String v) => switch (v) {
    'Critical' => AppText.t('حرج', 'Critical'),
    'High' => AppText.t('عال', 'High'),
    'Medium' => AppText.t('متوسط', 'Medium'),
    'Low' => AppText.t('منخفض', 'Low'),
    _ => v.isEmpty ? '-' : v,
  };

  static Widget criticality(String v) =>
      SopPill(criticalityLabel(v), switch (v) {
        'Critical' => AppColors.danger,
        'High' => AppColors.warning,
        _ => AppColors.textMuted,
      });

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
