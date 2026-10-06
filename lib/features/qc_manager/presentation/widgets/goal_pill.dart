import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../domain/qc_enums.dart';

/// Goal status, priority and overdue pills.
///
/// A separate widget from `NcrPill` because the two vocabularies collide
/// (`Active`, `Blocked`, `Done`) without meaning the same thing: a pill that
/// reused the finding mapping would paint a `Cancelled` goal red-as-rejected
/// and a `Draft` goal grey-as-unrated.
class GoalPill extends StatelessWidget {
  const GoalPill(this.label, this.color, {super.key});

  final String label;
  final Color color;

  /// Localised name for a stored status code.
  ///
  /// Falls back to the raw code so an unexpected value is visible rather than
  /// silently rendered as "Draft".
  static String statusLabel(String status) => switch (status) {
    QcGoalStatus.draft => AppText.t('مسودة', 'Draft'),
    QcGoalStatus.active => AppText.t('نشط', 'Active'),
    QcGoalStatus.onHold => AppText.t('موقوف', 'On hold'),
    QcGoalStatus.completed => AppText.t('مكتمل', 'Completed'),
    QcGoalStatus.cancelled => AppText.t('ملغى', 'Cancelled'),
    QcGoalStatus.archived => AppText.t('مؤرشف', 'Archived'),
    _ => status.isEmpty ? AppText.t('غير معروف', 'Unknown') : status,
  };

  static Color statusColor(String status) => switch (status) {
    QcGoalStatus.draft => AppColors.textMuted,
    QcGoalStatus.active => AppColors.info,
    QcGoalStatus.onHold => AppColors.warning,
    QcGoalStatus.completed => AppColors.success,
    QcGoalStatus.cancelled => AppColors.textMuted,
    QcGoalStatus.archived => AppColors.textMuted,
    _ => AppColors.textMuted,
  };

  static Widget status(String status) =>
      GoalPill(statusLabel(status), statusColor(status));

  static String priorityLabel(String priority) => switch (priority) {
    QcPriority.low => AppText.t('منخفض', 'Low'),
    QcPriority.medium => AppText.t('متوسط', 'Medium'),
    QcPriority.high => AppText.t('عال', 'High'),
    QcPriority.critical => AppText.t('حرج', 'Critical'),
    _ => priority,
  };

  static Color priorityColor(String priority) => switch (priority) {
    QcPriority.critical => AppColors.danger,
    QcPriority.high => AppColors.warning,
    QcPriority.medium => AppColors.info,
    _ => AppColors.textMuted,
  };

  static Widget priority(String priority) =>
      GoalPill(priorityLabel(priority), priorityColor(priority));

  /// The single "this is late" marker. Deliberately its own pill rather than a
  /// coloured due date, because a due date in red and a status pill in red
  /// together read as two problems when there is one.
  static Widget overdue() =>
      GoalPill(AppText.t('متأخر', 'Overdue'), AppColors.danger);

  /// Assignment state, which is a per-person share of the goal rather than a
  /// state of the goal itself.
  static Widget assignmentStatus(String status) => switch (status) {
    QcGoalAssignmentStatus.pending => GoalPill(
      AppText.t('بالانتظار', 'Pending'),
      AppColors.textMuted,
    ),
    QcGoalAssignmentStatus.inProgress => GoalPill(
      AppText.t('قيد التنفيذ', 'In progress'),
      AppColors.warning,
    ),
    QcGoalAssignmentStatus.completed => GoalPill(
      AppText.t('مكتمل', 'Completed'),
      AppColors.success,
    ),
    QcGoalAssignmentStatus.rejected => GoalPill(
      AppText.t('مرفوض', 'Rejected'),
      AppColors.danger,
    ),
    QcGoalAssignmentStatus.cancelled => GoalPill(
      AppText.t('ملغى', 'Cancelled'),
      AppColors.textMuted,
    ),
    _ => GoalPill(status.isEmpty ? '-' : status, AppColors.textMuted),
  };

  /// Step state inside a goal.
  static Widget actionStatus(String status) => switch (status) {
    QcGoalActionStatus.todo => GoalPill(
      AppText.t('مبدئي', 'To do'),
      AppColors.textMuted,
    ),
    QcGoalActionStatus.inProgress => GoalPill(
      AppText.t('قيد التنفيذ', 'In progress'),
      AppColors.warning,
    ),
    QcGoalActionStatus.done => GoalPill(
      AppText.t('منجز', 'Done'),
      AppColors.success,
    ),
    QcGoalActionStatus.blocked => GoalPill(
      AppText.t('متعثر', 'Blocked'),
      AppColors.danger,
    ),
    QcGoalActionStatus.cancelled => GoalPill(
      AppText.t('ملغى', 'Cancelled'),
      AppColors.textMuted,
    ),
    _ => GoalPill(status.isEmpty ? '-' : status, AppColors.textMuted),
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
