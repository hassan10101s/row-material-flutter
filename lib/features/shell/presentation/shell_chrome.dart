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

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/locale/locale_service.dart';
import '../../../core/theme/theme_service.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../auth/domain/user.dart';
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
    this.onMenu,
    this.showRoleChip = true,
  });

  final User user;
  final LocaleService locale;
  final ThemeService theme;
  final SyncStatusController syncStatus;
  final VoidCallback onOpenSync;

  /// Null on desktop, where the sidebar is always visible and there is nothing
  /// for a menu button to open.
  final VoidCallback? onMenu;

  final bool showRoleChip;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([syncStatus, locale, theme]),
      builder: (context, _) => _bar(context),
    );
  }

  Widget _bar(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 0.5,
      child: Container(
        height: 56.h,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (onMenu != null) ...[
              IconButton(
                tooltip: AppText.t('القائمة', 'Menu'),
                onPressed: onMenu,
                icon: const Icon(Icons.menu),
              ),
              const SizedBox(width: 8),
            ],
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
            if (showRoleChip && user.isReadOnly) ...[
              const SizedBox(width: 12),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  AppRoles.label(user.role),
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.warning,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 10),
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
        shape: const CircleBorder(),
        elevation: 2,
        shadowColor: Colors.black26,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(padding: const EdgeInsets.all(9), child: child),
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
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: active
              ? AppColors.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10.r),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18.r,
              color: active ? AppColors.primary : AppColors.textMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.spMax,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? AppColors.primary : AppColors.textStrong,
                ),
              ),
            ),
          ],
        ),
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
  });

  final User user;

  /// "Sign out of this device only": the member stays active and their other
  /// devices keep working.
  final VoidCallback onLogout;
  final VoidCallback onLogoutThisDevice;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Icon(Icons.science, size: 44.r, color: AppColors.primary),
          const SizedBox(height: 8),
          Text(
            AppStrings.appTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            AppStrings.tagline,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceSoft,
              borderRadius: BorderRadius.circular(12.r),
            ),
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18.r,
                  backgroundColor: AppColors.primary,
                  child: Text(
                    user.fullName.isEmpty
                        ? '?'
                        : user.fullName.substring(0, 1).toUpperCase(),
                    style: TextStyle(color: Colors.white, fontSize: 16.spMax),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.fullName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14.spMax,
                        ),
                      ),
                      Text(
                        '${user.username} — ${user.role}',
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
                  tooltip: AppText.t(
                    'تسجيل الخروج من هذا الجهاز فقط',
                    'Sign out of this device only',
                  ),
                  onPressed: onLogoutThisDevice,
                  icon: Icon(Icons.phone_iphone, size: 18.r),
                ),
                IconButton(
                  tooltip: AppText.t('تسجيل الخروج', 'Logout'),
                  onPressed: onLogout,
                  icon: Icon(Icons.logout, size: 18.r),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
