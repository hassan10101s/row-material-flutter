import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
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
      const _NavEntry('/dashboard', 'لوحة التحكم | Dashboard', Icons.dashboard_outlined),
      const _NavEntry('/history', 'سجل الفحوصات | History', Icons.history),
      const _NavEntry('/reports', 'التقارير | Reports', Icons.description_outlined),
      const _NavEntry('/lab', 'المختبر | Lab', Icons.biotech_outlined),
    ];
    if (user.canCreateInspection) {
      entries.add(
          const _NavEntry('/inspections', 'فحص جديد | New Inspection', Icons.add_task));
    }
    if (user.canSeeSettings) {
      entries.add(const _NavEntry('/reference', 'المرجعية | Reference', Icons.book_outlined));
      entries.add(const _NavEntry('/settings', 'الإعدادات | Settings', Icons.settings_outlined));
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('فتح مجلد PDF قريباً | Opening PDF folder soon')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = getIt<AuthGate>().currentUser;
    if (user == null) return const SizedBox.shrink();
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

    // Desktop: sidebar on the right (row-reverse for RTL).
    if (MediaQuery.sizeOf(context).width >= 1024) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                children: [
                  _TopBar(onMenu: () {}, user: user),
                  Expanded(child: widget.child),
                ],
              ),
            ),
            Container(
              width: 300,
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  left: BorderSide(color: AppColors.borderMuted),
                ),
              ),
              child: drawer,
            ),
          ],
        ),
      );
    }

    // Narrow: overlay drawer opened from the top bar.
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          Column(
            children: [
              _TopBar(onMenu: () => setState(() => _navOpen = true), user: user),
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
                      child: ColoredBox(color: Colors.black45),
                    ),
                  ),
                  SizedBox(width: 300, child: Material(child: drawer)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final VoidCallback onMenu;
  final User user;
  const _TopBar({required this.onMenu, required this.user});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 0.5,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Menu',
              onPressed: onMenu,
              icon: const Icon(Icons.menu),
            ),
            const SizedBox(width: 8),
            Text(
              '${AppStrings.appTitle} — ${user.fullName}',
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            if (user.isDeveloper)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Developer',
                    style: TextStyle(fontSize: 12, color: AppColors.warning)),
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
        // Brand card.
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(Icons.science, size: 44, color: AppColors.primary),
              const SizedBox(height: 8),
              Text('Material Lab',
                  style: Theme.of(context).textTheme.titleLarge),
              Text(
                AppStrings.tagline,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: AppSpacing.md),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: AppColors.primary,
                      child: Text(
                        user.fullName.isEmpty
                            ? '?'
                            : user.fullName.substring(0, 1).toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user.fullName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                          Text(
                            '${user.username} — ${user.role}',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppColors.textMuted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'تسجيل الخروج | Logout',
                      onPressed: onLogout,
                      icon: const Icon(Icons.logout, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Nav list.
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
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
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: OutlinedButton.icon(
            onPressed: onOpenPdfFolder,
            icon: const Icon(Icons.folder_open, size: 18),
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
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 18, color: active ? AppColors.primary : AppColors.textMuted),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? AppColors.primary : AppColors.textStrong,
              ),
            ),
          ],
        ),
      ),
    );
  }
}