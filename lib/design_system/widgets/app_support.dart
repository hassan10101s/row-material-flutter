import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_strings.dart';
import '../feedback/app_feedback.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_button.dart';
import 'app_window.dart';

/// Company contact channels (single source of truth — the login screen and
/// the shell topbar both open the same sheet from here).
class AppSupport {
  static const site = 'https://materiallab.app/';
  static const whatsapp = 'https://wa.me/201213473838';
  static const phone = 'tel:+201213473838';

  static const companyName = 'Kvector Co.';

  static Future<void> openLink(BuildContext context, String value) async {
    final ok = await launchUrl(
      Uri.parse(value),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      AppFeedback.error(
        context,
        AppText.t('تعذر فتح الرابط.', 'Could not open the link.'),
      );
    }
  }
}

/// The single elegant support entry: a headset button that opens the contact
/// sheet (dialog on desktop, bottom sheet on phones).
class AppSupportButton extends StatelessWidget {
  const AppSupportButton({super.key, this.expanded = true, this.small = false});

  final bool expanded;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: AppText.t('الدعم والتواصل', 'Support & contact'),
      icon: const Icon(Icons.support_agent_outlined),
      style: AppButtonStyle.secondary,
      expanded: expanded,
      small: small,
      onPressed: () => openSupportSheet(context),
    );
  }
}

/// Company card + WhatsApp / call / website actions.
Future<void> openSupportSheet(BuildContext context) {
  return showAppOverlay<void>(
    context,
    title: AppText.t('الدعم والتواصل', 'Support & contact'),
    icon: Icons.support_agent_outlined,
    builder: (sheetContext, close) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [
                    AppColors.primary,
                    AppColors.primary.withValues(alpha: 0.65),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.support_agent_outlined,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    AppSupport.companyName,
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    AppText.t(
                      'شركة تطوير برمجيات وحلول تقنية مؤسسية',
                      'Software Development & Enterprise Solutions Company',
                    ),
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          label: AppText.t('واتساب', 'WhatsApp'),
          icon: const Icon(Icons.chat_outlined, size: 18),
          expanded: true,
          onPressed: () =>
              AppSupport.openLink(sheetContext, AppSupport.whatsapp),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          label: AppText.t('اتصال', 'Call'),
          icon: const Icon(Icons.phone_outlined, size: 18),
          style: AppButtonStyle.secondary,
          expanded: true,
          onPressed: () => AppSupport.openLink(sheetContext, AppSupport.phone),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          label: AppText.t('الموقع', 'Website'),
          icon: const Icon(Icons.language, size: 18),
          style: AppButtonStyle.ghost,
          expanded: true,
          onPressed: () => AppSupport.openLink(sheetContext, AppSupport.site),
        ),
      ],
    ),
  );
}
