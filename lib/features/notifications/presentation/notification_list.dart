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
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 4.h),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          controller.unread > 0
                              ? AppText.t(
                                  'الإشعارات (${controller.unread})',
                                  'Notifications (${controller.unread})',
                                )
                              : AppText.t('الإشعارات', 'Notifications'),
                          style: TextStyle(
                            fontSize: 16.spMax,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textStrong,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: items.isEmpty
                            ? null
                            : () async {
                                await controller.markAllRead();
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              },
                        child: Text(
                          AppText.t(
                            'مسح الكل',
                            'Clear all',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: items.isEmpty
                      ? Padding(
                          padding: EdgeInsets.all(24.w),
                          child: Text(
                            AppText.t(
                              'لا جديد حتى الآن',
                              'No new items yet',
                            ),
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 14.spMax,
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: items.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1),
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
                              avatarBg = AppColors.primary
                                  .withValues(alpha: AppOpacity.subtle);
                              avatarFg = AppColors.primary;
                            }
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: avatarBg,
                                child: Icon(
                                  icon,
                                  color: avatarFg,
                                ),
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
                              onTap: () =>
                                  Navigator.of(context).pop(item),
                            );
                          },
                        ),
                ),
                // ── Always-on battery hint (Android only) ───────────────────
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
          ),
        );
      },
    );
  }
}

/// Bottom hint inside the notifications sheet:
/// "To always receive notifications, enable [No battery optimization]
///  for Material Lab" + a button that requests it.
class _BatteryExemptionFooter extends StatefulWidget {
  const _BatteryExemptionFooter();

  @override
  State<_BatteryExemptionFooter> createState() =>
      _BatteryExemptionFooterState();
}

class _BatteryExemptionFooterState extends State<_BatteryExemptionFooter> {
  bool _exempt = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (mounted) {
        setState(() {
          _exempt = status.isGranted;
          _checking = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _request() async {
    try {
      final status =
          await Permission.ignoreBatteryOptimizations.request();
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
                    'لتلقي الإشعارات دائماً فعّل «عدم تحسين البطارية» لتطبيق متريال لاب',
                    'To always receive notifications, enable “No battery optimization” for Material Lab',
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
                    'الإعدادات > البطارية > متريال لاب > بدون قيود، حتى تصل الإشعارات والتطبيق مغلق.',
                    'Settings > Battery > Material Lab > Unrestricted, so alerts arrive even when the app is closed.',
                  ),
                  style: TextStyle(
                    fontSize: 11.5.spMax,
                    color: AppColors.textMuted,
                    height: 1.5,
                  ),
                ),
                SizedBox(height: 8.h),
                _checking
                    ? const SizedBox.shrink()
                    : _exempt
                        ? Row(
                            children: [
                              const Icon(
                                Icons.check_circle_outline,
                                size: 16,
                                color: Colors.green,
                              ),
                              SizedBox(width: 6.w),
                              Text(
                                AppText.t(
                                  'مفعّل — الإشعارات ستصل دائماً',
                                  'Enabled — notifications will always arrive',
                                ),
                                style: TextStyle(
                                  fontSize: 12.spMax,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.green.shade700,
                                ),
                              ),
                            ],
                          )
                        : FilledButton.tonalIcon(
                            onPressed: _request,
                            icon: const Icon(
                              Icons.battery_saver_outlined,
                              size: 18,
                            ),
                            label: Text(
                              AppText.t(
                                'تفعيل عدم تحسين البطارية',
                                'Allow background activity',
                              ),
                            ),
                          ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
