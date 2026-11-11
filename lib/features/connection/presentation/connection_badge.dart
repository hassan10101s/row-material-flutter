import 'package:flutter/material.dart';
import '../../../design_system/widgets/app_tooltip.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_colors.dart';
import 'connection_status_controller.dart';

/// Displays connectivity and last cache refresh; the shell opens local drafts.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({
    super.key,
    required this.status,
    this.onTap,
    this.compact = false,
    this.canReviewQuarantine = false,
  });

  final ConnectionStatus status;
  final VoidCallback? onTap;
  final bool compact;

  /// True only for the organization manager and the quality manager: the
  /// quarantine detail (malformed server records skipped instead of aborting
  /// the archive) is management information, not general chatter.
  final bool canReviewQuarantine;

  static const Key badgeKey = Key('sync-badge');
  static const Key pendingKey = Key('sync-badge-pending');
  static const Key blockedKey = Key('sync-badge-blocked');

  Color get _color {
    if (!status.online) return AppColors.warning;
    if (status.hasError) return AppColors.danger;
    if (_quarantineVisible) return AppColors.warning;
    if (status.pullIncomplete) return AppColors.info;
    return AppColors.success;
  }

  bool get _quarantineVisible =>
      canReviewQuarantine && status.quarantined.isNotEmpty;

  IconData get _icon {
    if (!status.online) return Icons.cloud_off_outlined;
    if (status.hasError) return Icons.sync_problem_outlined;
    if (_quarantineVisible) return Icons.report_problem_outlined;
    if (status.pullIncomplete) return Icons.cloud_sync_outlined;
    return Icons.cloud_done_outlined;
  }

  /// Everything the badge knows, as one line - the tooltip and the test both
  /// read it, so the user and the assertions can never drift apart.
  String get tooltipMessage {
    final connection = status.online
        ? AppText.t('متصل', 'Online')
        : AppText.t('غير متصل', 'Offline');
    final last = status.lastSync == null
        ? AppText.t('لم يُحدّث بعد', 'Not updated yet')
        : _stamp(status.lastSync!);
    final detail = status.hasError
        ? AppText.t('تعذر تحديث البيانات', 'Could not refresh data')
        : status.pullIncomplete
        ? AppText.t('جارٍ تجهيز البيانات', 'Preparing data')
        : status.online
        ? AppText.t('آخر تحديث', 'Last refresh')
        : AppText.t('عرض البيانات المحفوظة', 'Showing cached data');
    var message =
        '$connection • $detail: $last\n${AppText.t('اضغط لعرض المسودات', 'Open drafts')}';
    if (_quarantineVisible) {
      // Management-only: the exact skipped records and how to clear them.
      final records = status.quarantined
          .take(5)
          .map((r) => '\n• $r')
          .join();
      message += '\n${AppText.t(
        'سجلّات تالفّة على السيرفر تم تجاهلها ولا توقف العمل؛ يحذفها مدير المؤسسة أو مدير الجودة من Firebase:',
        'Malformed server records were skipped (the app keeps working); the organization/quality manager deletes them from Firebase:',
      )}$records';
    }
    return message;
  }

  static String _stamp(DateTime at) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${p(at.month)}-${p(at.day)} ${p(at.hour)}:${p(at.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return AppTooltip(
      key: badgeKey,
      message: tooltipMessage,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [Icon(_icon, size: 18.r, color: color)],
          ),
        ),
      ),
    );
  }
}
