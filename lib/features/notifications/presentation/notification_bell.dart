import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/responsive/form_factor.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/widgets/app_window.dart';
import '../../../di/service_locator.dart';
import '../../shell/presentation/shell_chrome.dart';
import '../domain/notification_item.dart';
import 'notification_controller.dart';
import 'notification_list.dart';

/// Mobile-only bell shown in [ShellTopBar] next to the sync badge.
/// Returns an empty widget on desktop (mobile-only feature).
/// Resolves [NotificationController] from getIt when not passed, so the
/// shell chrome needs no constructor changes; returns empty when unregistered
/// (tests, desktop, signed-out).
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key, this.controller});

  final NotificationController? controller;

  NotificationController? _resolve() {
    if (controller != null) return controller;
    try {
      return getIt<NotificationController>();
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!FormFactor.current.isMobile) return const SizedBox.shrink();
    final resolved = _resolve();
    if (resolved == null) return const SizedBox.shrink();
    final ctl = resolved;
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final count = ctl.unread;
        return ShellFloatingRound(
          tooltip: count > 0
              ? AppText.t('الإشعارات ($count)', 'Notifications ($count)')
              : AppText.t('الإشعارات', 'Notifications'),
          onPressed: () => _open(context),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                count > 0
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_none_outlined,
                size: 20.r,
                color: AppColors.primary,
              ),
              if (count > 0)
                Positioned(
                  right: -6,
                  top: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.danger,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10.spMax,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _open(BuildContext context) async {
    final ctl = _resolve();
    if (ctl == null) return;
    await ctl.load();
    if (!context.mounted) return;
    final selected = await showAppDialog<NotificationItem>(
      context,
      builder: (_) => NotificationList(controller: ctl),
    );
    if (selected == null || !context.mounted) return;
    await ctl.markRead(selected);
    if (!context.mounted) return;
    if (selected.type == NotificationType.inspection) {
      context.go('/inspections?highlight=${selected.refId}');
    } else if (selected.type == NotificationType.sync) {
      context.go('/sync');
    } else {
      context.go('/lab?tab=0&highlight=${selected.refId}');
    }
  }
}
