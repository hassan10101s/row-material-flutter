import 'package:flutter/material.dart';
import './app_tooltip.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
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

  static const companyName = 'Kvector Co. LLC';

  /// Deliberately shown in English on both language sides: the corporate
  /// identity (name, line of business, seat) reads as a formal letterhead.
  static const companyLine = 'Software Development & AI for Industry';
  static const companySeat = 'Mohandiseen, Cairo, Egypt';

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
                  // Formal letterhead in both languages: English identity,
                  // then the seat line underneath.
                  const Text(
                    AppSupport.companyName,
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    AppSupport.companyLine,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  Text(
                    AppSupport.companySeat,
                    style: TextStyle(
                      color: AppColors.textMuted.withValues(alpha: 0.8),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        // Compact circular channels row (website / call / WhatsApp) instead
        // of stacked full-width buttons — same links, less space.
        const AppSupportChannels(),
      ],
    ),
  );
}

/// One circular contact button with a small bilingual label underneath.
/// Shared by the support sheet and the trial-expired screen.
class AppSupportCircle extends StatelessWidget {
  const AppSupportCircle({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.icon,
    this.glyph,
    this.background,
    this.foreground,
    this.border,
  }) : assert(icon != null || glyph != null);

  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final IconData? icon;

  /// Pre-sized widget used instead of [icon] (e.g. the authentic WhatsApp
  /// SVG logo).
  final Widget? glyph;
  final Color? background;
  final Color? foreground;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return AppTooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(40.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: tooltip,
              child: Container(
                width: 52.r,
                height: 52.r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: background ?? AppColors.surface,
                  border: border == null
                      ? null
                      : Border.all(color: border!, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: glyph ??
                      Icon(
                        icon,
                        color: foreground ?? AppColors.primary,
                        size: 22.r,
                      ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11.5.spMax,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The company contact channels as tight circular icons side by side:
/// website, call and WhatsApp (authentic logo). RTL flips the row.
class AppSupportChannels extends StatelessWidget {
  const AppSupportChannels({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        AppSupportCircle(
          label: AppText.t('الموقع', 'Website'),
          icon: Icons.language,
          border: AppColors.border,
          tooltip: AppText.t('فتح الموقع', 'Open the website'),
          onTap: () => AppSupport.openLink(context, AppSupport.site),
        ),
        AppSupportCircle(
          label: AppText.t('اتصال', 'Call'),
          icon: Icons.phone_outlined,
          background: AppColors.primary,
          foreground: Colors.white,
          tooltip: AppText.t('اتصال بالدعم', 'Call support'),
          onTap: () => AppSupport.openLink(context, AppSupport.phone),
        ),
        AppSupportCircle(
          label: AppText.t('واتساب', 'WhatsApp'),
          background: AppColors.whatsapp,
          foreground: Colors.white,
          tooltip: AppText.t('تواصل واتساب', 'Chat on WhatsApp'),
          glyph: SizedBox(
            width: 22.r,
            height: 22.r,
            child: SvgPicture.asset('assets/images/whatsapp.svg'),
          ),
          onTap: () => AppSupport.openLink(context, AppSupport.whatsapp),
        ),
      ],
    );
  }
}
