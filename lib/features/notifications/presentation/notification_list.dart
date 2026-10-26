import '../../../design_system/widgets/app_window.dart';
import '../../../design_system/widgets/app_button.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_opacity.dart';
import '../domain/notification_item.dart';
import 'notification_controller.dart';

/// Bottom-sheet list of recent new-item notifications (mobile only).
/// Returns the tapped item so the caller can deep-link.
class NotificationList extends StatelessWidget {
  const NotificationList({super.key, required this.controller});

  final NotificationController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.items;
        return AppDialog(
          title: controller.unread > 0
              ? AppText.t(
                  'الإشعارات (${controller.unread})',
                  'Notifications (${controller.unread})',
                )
              : AppText.t('الإشعارات', 'Notifications'),
          icon: Icons.notifications_outlined,
          height: 500,
          actions: [
            AppButton(
              label: AppText.t('مسح الكل', 'Clear all'),
              style: AppButtonStyle.ghost,
              onPressed: items.isEmpty
                  ? null
                  : () async {
                      await controller.markAllRead();
                      if (context.mounted) Navigator.of(context).pop();
                    },
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              items.isEmpty
                  ? Padding(
                      padding: EdgeInsets.all(24.w),
                      child: Text(
                        AppText.t('لا جديد حتى الآن', 'No new items yet'),
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 14.spMax,
                        ),
                      ),
                    )
                  : ListView.separated(
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final item = items[i];
                        // Icon by kind: truck for raw material, factory for
                        // product batch, microscope-ish (biotech) for lab.
                        final IconData icon;
                        if (item.type == NotificationType.sync) {
                          icon = Icons.sync_problem_outlined;
                        } else if (item.type == NotificationType.labResult) {
                          icon = Icons.biotech_outlined;
                        } else if (item.isProductInspection) {
                          icon = Icons.factory_outlined;
                        } else {
                          icon = Icons.local_shipping_outlined;
                        }
                        // Color by verdict: danger tint when rejected /
                        // non-conforming, info tint when accepted/
                        // matching, neutral primary tint when pending.
                        final Color avatarBg;
                        final Color avatarFg;
                        if (item.isRejected) {
                          avatarBg = AppColors.danger.withValues(
                            alpha: AppOpacity.subtle,
                          );
                          avatarFg = AppColors.danger;
                        } else if (item.isAccepted) {
                          avatarBg = AppColors.info.withValues(
                            alpha: AppOpacity.subtle,
                          );
                          avatarFg = AppColors.info;
                        } else {
                          avatarBg = AppColors.primary.withValues(
                            alpha: AppOpacity.subtle,
                          );
                          avatarFg = AppColors.primary;
                        }
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: avatarBg,
                            child: Icon(icon, color: avatarFg),
                          ),
                          title: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: item.read
                                  ? FontWeight.w500
                                  : FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            item.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: item.read
                              ? null
                              : Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: avatarFg,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                          onTap: () => Navigator.of(context).pop(item),
                        );
                      },
                    ),
              // ── Background delivery preferences (Android only) ──────────
              // FCM arrives when killed only if the OEM does not force-stop
              // the app: user must set battery to Unrestricted for
              // Material Lab. Shown at the bottom of the sheet, never
              // blocking the list itself.
              if (Platform.isAndroid) ...[
                const Divider(height: 1),
                const _BatteryExemptionFooter(),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Bottom hint inside the notifications sheet:
/// Permissions and battery settings that can affect background delivery.
///  for Material Lab" + a button that requests it.
class _BatteryExemptionFooter extends StatefulWidget {
  const _BatteryExemptionFooter();

  @override
  State<_BatteryExemptionFooter> createState() =>
      _BatteryExemptionFooterState();
}

class _BatteryExemptionFooterState extends State<_BatteryExemptionFooter>
    with WidgetsBindingObserver {
  bool _exempt = false;
  bool _checking = true;
  bool _notificationsAllowed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      final notifications = await Permission.notification.status;
      if (mounted) {
        setState(() {
          _exempt = status.isGranted;
          _notificationsAllowed = notifications.isGranted;
          _checking = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _requestNotifications() async {
    try {
      final permission = await Permission.notification.request();
      if (permission.isPermanentlyDenied) await openAppSettings();
    } on Object {
      await openAppSettings();
    } finally {
      await _refresh();
    }
  }

  Future<void> _request() async {
    try {
      final status = await Permission.ignoreBatteryOptimizations.request();
      if (!status.isGranted) {
        // User dismissed or OEM has no exemption screen: fall back to the
        // app-settings page where battery can be set to Unrestricted.
        await openAppSettings();
      }
    } on Object {
      try {
        await openAppSettings();
      } on Object {
        // Best effort.
      }
    } finally {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(16.w, 10.h, 16.w, 14.h),
      color: AppColors.primary.withValues(alpha: 0.06),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 2.h),
            child: Icon(
              _exempt
                  ? Icons.battery_charging_full_outlined
                  : Icons.battery_alert_outlined,
              size: 20,
              color: AppColors.primary,
            ),
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  AppText.t(
                    'استقبال الإشعارات في الخلفية',
                    'Receiving notifications in the background',
                  ),
                  style: TextStyle(
                    fontSize: 12.5.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                    height: 1.5,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  AppText.t(
                    'اسمح بإشعارات النظام، واختر «بدون قيود» إذا كان جهازك يقيّد عمل التطبيق في الخلفية.',
                    'Allow system notifications. Choose Unrestricted battery use if your device limits background activity.',
                  ),
                  style: TextStyle(
                    fontSize: 11.5.spMax,
                    color: AppColors.textMuted,
                    height: 1.5,
                  ),
                ),
                SizedBox(height: 8.h),
                if (!_checking && !_notificationsAllowed) ...[
                  AppButton(
                    label: AppText.t(
                      'السماح بالإشعارات',
                      'Allow notifications',
                    ),
                    icon: const Icon(Icons.notifications_active_outlined),
                    onPressed: _requestNotifications,
                  ),
                  const SizedBox(height: 8),
                ],
                _checking
                    ? const SizedBox.shrink()
                    : _exempt
                    ? Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 16,
                            color: AppColors.success,
                          ),
                          SizedBox(width: 6.w),
                          Expanded(
                            child: Text(
                              AppText.t(
                                'مفعّل — السماح بالعمل في الخلفية',
                                'Enabled — background activity allowed',
                              ),
                              style: TextStyle(
                                fontSize: 12.spMax,
                                fontWeight: FontWeight.w700,
                                color: AppColors.success,
                              ),
                            ),
                          ),
                        ],
                      )
                    : AppButton(
                        onPressed: _request,
                        label: AppText.t(
                          'تفعيل عدم تحسين البطارية',
                          'Allow background activity',
                        ),
                        icon: const Icon(
                          Icons.battery_saver_outlined,
                          size: 18,
                        ),
                        style: AppButtonStyle.secondary,
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
