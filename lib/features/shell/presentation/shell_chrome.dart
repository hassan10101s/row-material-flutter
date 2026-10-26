/// The chrome both experiences share, so the split cannot drift it apart.
///
/// These three widgets are a **move**, not a rewrite. `_TopBar` became
/// [ShellTopBar], `_FloatingRound` became [ShellFloatingRound] and the sidebar's
/// brand-and-avatar card became [ShellIdentityCard] - same paddings, same
/// `56.h` / `18.r` / `12.r` call sites, same colours. Two things changed:
///
///  * the services arrive as parameters instead of `getIt` lookups, so this
///    file is constructible in a test with no locator registered;
///  * the read-only role chip is optional, because at 400dp the identity card
///    already states the role and a chip beside three toggles does not fit.
///
/// One implementation rather than two: the phone is not a re-authoring of the
/// bar, it is the same bar with the menu button switched on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/locale/locale_service.dart';
import '../../../core/theme/theme_service.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_motion.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_window.dart';
import '../../../design_system/widgets/app_support.dart';
import '../../../design_system/widgets/app_user_avatar.dart';
import '../../auth/domain/user.dart';
import '../../notifications/presentation/notification_bell.dart';
import '../../sync/presentation/sync_badge.dart';
import '../../sync/presentation/sync_status_controller.dart';

/// The bar across the top of both experiences: menu button, language toggle,
/// theme toggle, optional read-only chip, and the sync badge.
///
/// Only the bar listens. It is the one widget that renders the counters, the
/// language label and the theme icon, and the 20s refresh it is driven by must
/// not rebuild the routed page underneath it.
class ShellTopBar extends StatelessWidget {
  const ShellTopBar({
    super.key,
    required this.user,
    required this.locale,
    required this.theme,
    required this.syncStatus,
    required this.onOpenSync,
    this.title,
    this.onMenu,
    this.showRoleChip = true,
    this.compact = false,
  });

  final User user;
  final LocaleService locale;
  final ThemeService theme;
  final SyncStatusController syncStatus;
  final VoidCallback onOpenSync;
  final String? title;

  /// Null on desktop, where the sidebar is always visible and there is nothing
  /// for a menu button to open.
  final VoidCallback? onMenu;

  final bool showRoleChip;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([syncStatus, locale, theme]),
      builder: (context, _) => _bar(context),
    );
  }

  Widget _bar(BuildContext context) {
    if (compact) {
      return SizedBox(
        height: 56,
        child: Row(
          children: [
            IconButton(
              tooltip: AppText.t('القائمة', 'Menu'),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onMenu,
              icon: const Icon(Icons.menu),
            ),
            Expanded(
              child: Text(
                title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: SyncBadge(
                status: syncStatus.status,
                onTap: onOpenSync,
                compact: true,
              ),
            ),
            const SizedBox(width: 48, height: 48, child: NotificationBell()),
            PopupMenuButton<String>(
              tooltip: AppText.t('المزيد', 'More'),
              onSelected: (value) {
                switch (value) {
                  case 'language':
                    locale.toggle();
                  case 'theme':
                    theme.toggle();
                  case 'support':
                    openSupportSheet(context);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'language',
                  child: Text(AppStrings.toggleLanguage),
                ),
                PopupMenuItem(
                  value: 'theme',
                  child: Text(AppStrings.toggleTheme),
                ),
                PopupMenuItem(
                  value: 'support',
                  child: Text(AppText.t('الدعم والتواصل', 'Support & contact')),
                ),
              ],
            ),
          ],
        ),
      );
    }
    // Transparent chrome: no solid strip, no divider — the page background
    // shows through and the round buttons (language, theme, support) plus
    // the bell and sync badge read as floating pills.
    return Material(
      color: Colors.transparent,
      elevation: 0,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(color: Colors.transparent),
        child: Row(
          children: [
            if (onMenu != null) ...[
              IconButton(
                tooltip: AppText.t('القائمة', 'Menu'),
                onPressed: onMenu,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.primary.withValues(alpha: 0.08),
                  foregroundColor: AppColors.primary,
                ),
                icon: const Icon(Icons.menu),
              ),
              const SizedBox(width: 8),
            ],
            if (title != null && title!.trim().isNotEmpty)
              Expanded(
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4),
                  child: Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16.spMax,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textStrong,
                    ),
                  ),
                ),
              )
            else
              const Spacer(),
            ShellFloatingRound(
              tooltip: AppStrings.toggleLanguage,
              onPressed: () => locale.toggle(),
              child: Text(
                locale.isArabic ? 'EN' : 'ع',
                style: TextStyle(
                  fontSize: 14.spMax,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ShellFloatingRound(
              tooltip: AppStrings.toggleTheme,
              onPressed: () => theme.toggle(),
              child: Icon(
                theme.mode == ThemeMode.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                size: 20.r,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 8),
            // Company support, same round style: opens the contact sheet
            // (dialog on desktop, bottom sheet on phones).
            ShellFloatingRound(
              tooltip: AppText.t('الدعم والتواصل', 'Support & contact'),
              onPressed: () => openSupportSheet(context),
              child: Icon(
                Icons.support_agent_outlined,
                size: 20.r,
                color: AppColors.primary,
              ),
            ),
            if (showRoleChip && user.isReadOnly) ...[
              const SizedBox(width: 12),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  user.roleLabel,
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.warning,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 10),
            // Mobile-only new-item bell (inspections + lab results).
            const NotificationBell(),
            const SizedBox(width: 6),
            // The badge is the visible proof of the offline-first state:
            // connection, work waiting, last exchange.
            SyncBadge(status: syncStatus.status, onTap: onOpenSync),
          ],
        ),
      ),
    );
  }
}

/// Circular floating toggle button used in the topbar (language + theme).
class ShellFloatingRound extends StatelessWidget {
  const ShellFloatingRound({
    super.key,
    required this.tooltip,
    required this.child,
    required this.onPressed,
  });

  final String tooltip;
  final Widget child;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surfaceSoft,
        borderRadius: BorderRadius.circular(12.r),
        elevation: 0,
        child: InkWell(
          borderRadius: BorderRadius.circular(12.r),
          onTap: onPressed,
          child: Container(
            width: 40.r,
            height: 40.r,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: AppColors.borderMuted),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// One destination in a destination list.
///
/// Shared by the desktop sidebar and the phone drawer, so "which destination is
/// active" and "what a destination looks like" cannot drift apart between the
/// two experiences.
class ShellNavItem extends StatelessWidget {
  const ShellNavItem({
    super.key,
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12.r)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Material(
            color: active
                ? AppColors.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: AppMotion.of(context, AppMotion.fast),
                      curve: Curves.easeOutCubic,
                      width: 34.r,
                      height: 34.r,
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.primary.withValues(alpha: 0.16)
                            : AppColors.surfaceSoft,
                        borderRadius: BorderRadius.circular(10.r),
                        border: Border.all(
                          color: active
                              ? AppColors.primary.withValues(alpha: 0.25)
                              : AppColors.borderMuted,
                        ),
                      ),
                      child: Icon(
                        icon,
                        size: 18.r,
                        color: active ? AppColors.primary : AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.spMax,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: active
                              ? AppColors.primary
                              : AppColors.textStrong,
                        ),
                      ),
                    ),
                    if (active)
                      Icon(
                        isRtl
                            ? Icons.keyboard_arrow_left
                            : Icons.keyboard_arrow_right,
                        size: 18.r,
                        color: AppColors.primary,
                      ),
                  ],
                ),
              ),
            ),
          ),
          // The active-edge pill is always in the stack and cross-fades with
          // the active state, so moving between destinations animates the
          // indicator instead of popping it (drawer and desktop sidebar both).
          PositionedDirectional(
            start: 0,
            top: 8,
            bottom: 8,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: AppMotion.of(context, AppMotion.fast),
                curve: Curves.easeOutCubic,
                opacity: active ? 1 : 0,
                child: Container(
                  width: 3.5,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Brand, avatar, name and the two sign-out affordances.
///
/// Both the desktop sidebar and the phone drawer open with this, so the member
/// is identified the same way whichever chrome they are looking at - and so the
/// read-only role the topbar chip states on desktop is stated here too.
class ShellIdentityCard extends StatelessWidget {
  const ShellIdentityCard({
    super.key,
    required this.user,
    required this.onLogout,
    required this.onLogoutThisDevice,
    required this.onOpenSettings,
  });

  final User user;

  /// "Sign out of this device only": the member stays active and their other
  /// devices keep working.
  final VoidCallback onLogout;
  final VoidCallback onLogoutThisDevice;

  /// Opens the Settings screen (its account section holds name + password).
  final VoidCallback onOpenSettings;

  /// Tapping the member row opens a small account sheet: the two sign-outs live
  /// in there now (they used to be two icon buttons crowding the row), and the
  /// gear button beside the name jumps straight to Settings.
  Future<void> _openAccountSheet(BuildContext context) {
    final label = user.label.isNotEmpty ? user.label : user.email;
    return showAppOverlay<void>(
      context,
      title: AppText.t('الحساب', 'Account'),
      icon: Icons.person_outline,
      builder: (sheetContext, close) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                AppUserAvatar(name: label, photoUrl: user.photoUrl, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15.spMax,
                        ),
                      ),
                      Text(
                        '${user.username} — ${user.roleLabel}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12.spMax,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(AppText.t('الإعدادات', 'Settings')),
            onTap: () {
              Navigator.of(sheetContext).pop();
              onOpenSettings();
            },
          ),
          ListTile(
            leading: const Icon(Icons.phone_iphone),
            title: Text(
              AppText.t(
                'تسجيل الخروج من هذا الجهاز فقط',
                'Sign out of this device only',
              ),
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              onLogoutThisDevice();
            },
          ),
          ListTile(
            leading: Icon(Icons.logout, color: AppColors.danger),
            title: Text(
              AppText.t('تسجيل الخروج', 'Logout'),
              style: TextStyle(color: AppColors.danger),
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              onLogout();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = user.label.isNotEmpty ? user.label : user.fullName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46.r,
                height: 46.r,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      AppColors.primary,
                      AppColors.primary.withValues(alpha: 0.65),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14.r),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(Icons.science, size: 24.r, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppStrings.appTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.spMax,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                    Text(
                      AppStrings.tagline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11.spMax,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceSoft,
              borderRadius: BorderRadius.circular(14.r),
              border: Border.all(color: AppColors.borderMuted),
            ),
            padding: EdgeInsetsDirectional.only(
              start: 10.w,
              end: 4.w,
              top: 8.h,
              bottom: 8.h,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 168;
                // The whole row opens the account sheet (name, Settings and the
                // two sign-outs); the gear is a shortcut straight to Settings.
                // The rail can be collapsed to roughly 90px - in that state the
                // avatar alone is the affordance, so the name and buttons drop.
                return InkWell(
                  onTap: () => _openAccountSheet(context),
                  borderRadius: BorderRadius.circular(14.r),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 2,
                      end: 2,
                      top: 2,
                      bottom: 2,
                    ),
                    child: narrow
                        ? Align(
                            alignment: AlignmentDirectional.center,
                            child: AppUserAvatar(
                              name: label,
                              photoUrl: user.photoUrl,
                              radius: 18.r,
                            ),
                          )
                        : Row(
                            children: [
                              AppUserAvatar(
                                name: label,
                                photoUrl: user.photoUrl,
                                radius: 18.r,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      label,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13.spMax,
                                      ),
                                    ),
                                    Text(
                                      '${user.username} — ${user.roleLabel}',
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 11.spMax,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: AppText.t('الإعدادات', 'Settings'),
                                visualDensity: VisualDensity.compact,
                                onPressed: onOpenSettings,
                                icon: Icon(Icons.settings_outlined, size: 18.r),
                              ),
                              Icon(
                                Icons.keyboard_arrow_down,
                                size: 18.r,
                                color: AppColors.textMuted,
                              ),
                            ],
                          ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
