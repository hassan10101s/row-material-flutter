import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/locale/locale_service.dart';
import '../../../core/theme/theme_service.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../di/service_locator.dart';
import '../../auth/domain/user.dart';

/// Application shell: RTL sidebar + topbar + content panel.
/// Mirrors web/src/50_shell.js (AppShell).
class AppShell extends StatefulWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _NavEntry {
  final String path;
  final String label;
  final IconData icon;
  const _NavEntry(this.path, this.label, this.icon);
}

class _AppShellState extends State<AppShell> {
  bool _navOpen = false;

  List<_NavEntry> _navEntries(User user) {
    final entries = <_NavEntry>[
      _NavEntry('/dashboard', AppStrings.dashboard, Icons.dashboard_outlined),
      _NavEntry('/inspections', AppStrings.inspections, Icons.history),
      _NavEntry('/reports', AppStrings.reports, Icons.description_outlined),
      _NavEntry('/lab', AppStrings.lab, Icons.biotech_outlined),
    ];
    if (user.canSeeSettings) {
      entries.add(_NavEntry('/reference', AppStrings.reference, Icons.book_outlined));
      entries.add(_NavEntry('/settings', AppStrings.settings, Icons.settings_outlined));
    }
    return entries;
  }

  Future<void> _logout() async {
    try {
      getIt<AuthGate>().auth.logout();
    } on AppError {
      // best effort
    }
    getIt<AuthGate>().updated();
    if (mounted) context.go('/login');
  }

  Future<void> _openPdfFolder() async {
    // TODO: wire exportScience PDF folder later with ReportService.
    AppFeedback.info(
      context,
      AppText.t('فتح مجلد PDF قريباً', 'Opening PDF folder soon'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: getIt<LocaleService>(),
      builder: (context, _) => _build(context, user),
    );
  }

  Widget _build(BuildContext context, User user) {
    final entries = _navEntries(user);
    final currentPath = GoRouterState.of(context).uri.path;

    final drawer = _Sidebar(
      user: user,
      entries: entries,
      currentPath: currentPath,
      onSelect: (path) {
        setState(() => _navOpen = false);
        context.go(path);
      },
      onLogout: _logout,
      onOpenPdfFolder: _openPdfFolder,
    );

    final Widget body;
    // Desktop / Large screen: sidebar on the right (first child in RTL Row).
    if (MediaQuery.sizeOf(context).width >= 720) {
      body = Scaffold(
        backgroundColor: AppColors.background,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 280.w,
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  left: BorderSide(color: AppColors.borderMuted),
                ),
              ),
              child: drawer,
            ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(onMenu: () {}, user: user, showMenuButton: false),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ],
        ),
      );
    } else {
      // Narrow screen: overlay drawer opened from topbar menu button.
      body = Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            Column(
              children: [
                _TopBar(
                    onMenu: () => setState(() => _navOpen = true),
                    user: user,
                    showMenuButton: true),
                Expanded(child: widget.child),
              ],
            ),
            if (_navOpen)
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => setState(() => _navOpen = false),
                        child: ColoredBox(
                          color: AppColors.surfaceDeep.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    SizedBox(width: 280.w, child: Material(child: drawer)),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    return CallbackShortcuts(
      bindings: _shortcuts(entries),
      child: body,
    );
  }

  Map<ShortcutActivator, VoidCallback> _shortcuts(List<_NavEntry> entries) {
    const digits = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final bindings = <ShortcutActivator, VoidCallback>{};
    for (var i = 0; i < entries.length && i + 1 < digits.length; i++) {
      final path = entries[i].path;
      bindings[SingleActivator(digits[i + 1], control: true)] = () {
        if (mounted) context.go(path);
      };
    }
    bindings[const SingleActivator(LogicalKeyboardKey.escape)] = () {
      if (_navOpen) setState(() => _navOpen = false);
    };
    return bindings;
  }
}

class _TopBar extends StatelessWidget {
  final VoidCallback onMenu;
  final User user;
  final bool showMenuButton;
  const _TopBar({
    required this.onMenu,
    required this.user,
    this.showMenuButton = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 0.5,
      child: Container(
        height: 56.h,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (showMenuButton) ...[
              IconButton(
                tooltip: AppText.t('القائمة', 'Menu'),
                onPressed: onMenu,
                icon: const Icon(Icons.menu),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                '${AppStrings.appTitle} — ${user.fullName}',
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: AppStrings.toggleTheme,
              onPressed: () => getIt<ThemeService>().toggle(),
              icon: Icon(
                getIt<ThemeService>().mode == ThemeMode.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
              ),
            ),
            if (user.isDeveloper)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Developer',
                    style: TextStyle(fontSize: 12.spMax, color: AppColors.warning)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final User user;
  final List<_NavEntry> entries;
  final String currentPath;
  final ValueChanged<String> onSelect;
  final VoidCallback onLogout;
  final VoidCallback onOpenPdfFolder;

  const _Sidebar({
    required this.user,
    required this.entries,
    required this.currentPath,
    required this.onSelect,
    required this.onLogout,
    required this.onOpenPdfFolder,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Brand card.
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(Icons.science, size: 44.r, color: AppColors.primary),
                      const SizedBox(height: 8),
                      Text(AppStrings.appTitle,
                          style: Theme.of(context).textTheme.titleLarge),
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
                                  Text(user.fullName,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600, fontSize: 14.spMax)),
                                  Text(
                                    '${user.username} — ${user.role}',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: AppColors.textMuted, fontSize: 11.spMax),
                                  ),
                                ],
                              ),
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
                ),
                const Divider(height: 1),
                // Nav list.
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final e in entries)
                        _NavItem(
                          label: e.label,
                          icon: e.icon,
                          active: e.path == currentPath,
                          onTap: () => onSelect(e.path),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: OutlinedButton.icon(
            onPressed: onOpenPdfFolder,
            icon: Icon(Icons.folder_open, size: 18.r),
            label: Text(AppStrings.openPdfFolder),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              backgroundColor: AppColors.surface,
              side: BorderSide(color: AppColors.border),
            ),
          ),
        ),
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: active ? AppColors.primary.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(10.r),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 18.r, color: active ? AppColors.primary : AppColors.textMuted),
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