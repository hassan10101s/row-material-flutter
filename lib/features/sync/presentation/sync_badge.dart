import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_colors.dart';
import 'sync_status_controller.dart';

/// The topbar sync badge (plan §14-P8.1): the state of the connection, how many
/// changes are still waiting to be pushed and when the server was last reached.
///
/// It reports, it does not act: tapping it opens the sync screen, which is
/// where the real controls live.
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, required this.status, this.onTap});

  final SyncBadgeStatus status;
  final VoidCallback? onTap;

  static const Key badgeKey = Key('sync-badge');
  static const Key pendingKey = Key('sync-badge-pending');
  static const Key blockedKey = Key('sync-badge-blocked');

  Color get _color {
    if (!status.online) return AppColors.warning;
    if (status.blocked > 0) return AppColors.danger;
    if (status.pending > 0) return AppColors.info;
    return AppColors.success;
  }

  IconData get _icon {
    if (!status.online) return Icons.cloud_off_outlined;
    if (status.blocked > 0) return Icons.cloud_queue_outlined;
    if (status.pending > 0) return Icons.cloud_sync_outlined;
    return Icons.cloud_done_outlined;
  }

  /// Everything the badge knows, as one line - the tooltip and the test both
  /// read it, so the user and the assertions can never drift apart.
  String get tooltipMessage {
    final connection = status.online
        ? AppText.t('متصل', 'Online')
        : AppText.t('غير متصل', 'Offline');
    final pending = AppText.t('في الانتظار', 'pending');
    final blocked = AppText.t('متوقف', 'blocked');
    final last = status.lastSync == null
        ? AppText.t('لم تتم بعد', 'never')
        : _stamp(status.lastSync!);
    return '$connection • $pending: ${status.pending} • $blocked: ${status.blocked} • '
        '${AppText.t('آخر مزامنة', 'last sync')}: $last';
  }

  static String _stamp(DateTime at) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${p(at.month)}-${p(at.day)} ${p(at.hour)}:${p(at.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Tooltip(
      key: badgeKey,
      message: tooltipMessage,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, size: 18.r, color: color),
              if (status.pending > 0) ...[
                const SizedBox(width: 4),
                _CountBubble(
                  bubbleKey: pendingKey,
                  count: status.pending,
                  color: AppColors.info,
                ),
              ],
              if (status.blocked > 0) ...[
                const SizedBox(width: 4),
                _CountBubble(
                  bubbleKey: blockedKey,
                  count: status.blocked,
                  color: AppColors.danger,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CountBubble extends StatelessWidget {
  const _CountBubble({required this.bubbleKey, required this.count, required this.color});

  final Key bubbleKey;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: bubbleKey,
      padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 1.h),
      constraints: BoxConstraints(minWidth: 18.w),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11.spMax,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Small label used by the sync screen header as well.
class SyncStateLabel extends StatelessWidget {
  const SyncStateLabel({super.key, required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.success : AppColors.warning;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(online ? Icons.wifi : Icons.wifi_off, size: 14.r, color: color),
        const SizedBox(width: 4),
        Text(
          online ? AppText.t('متصل', 'Online') : AppText.t('غير متصل', 'Offline'),
          style: TextStyle(fontSize: 12.spMax, color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
