import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/locale/locale_service.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../auth/domain/user.dart';
import '../../../sync/presentation/sync_status_controller.dart';
import '../shell_chrome.dart';
import '../shell_nav.dart';

/// Desktop shell: a persistent sidebar, a topbar and the routed page.
///
/// ## This is a move, reviewed as a move
///
/// Everything below the `Scaffold` is the pre-split `_AppShellState._build`
/// desktop branch with nothing changed: the `280.w` sidebar, the
/// `Border(left: BorderSide(...))` on its trailing edge, the `56.h` topbar and
/// the `CallbackShortcuts` wrapper. The one thing that is gone is the
/// `MediaQuery.sizeOf(context).width >= AppBreakpoints.medium` branch that used
/// to pick between this layout and a phone drawer inside the same file - that
/// branch was the half-measure this split replaces, because which chrome to
/// build is a platform decision (see `FormFactor`).
///
/// One behaviour is intentionally narrower than the old code: `onNavigate` goes
/// straight to the router, where the old drawer callback also closed the drawer
/// first. There is no drawer on this experience to close.
class DesktopAppShell extends StatelessWidget {
  const DesktopAppShell({
    super.key,
    required this.child,
    required this.user,
    required this.entries,
    required this.locale,
    required this.theme,
    required this.syncStatus,
    required this.onNavigate,
    required this.onLogout,
    required this.onLogoutThisDevice,
    required this.onOpenPdfFolder,
    required this.canOpenPdfFolder,
  });

  final Widget child;
  final User user;
  final List<ShellNavEntry> entries;
  final LocaleService locale;
  final ThemeService theme;
  final SyncStatusController syncStatus;
  final void Function(String path) onNavigate;
  final VoidCallback onLogout;
  final VoidCallback onLogoutThisDevice;
  final VoidCallback onOpenPdfFolder;

  /// Whether the exports folder can be shown in a file manager on this platform.
  final bool canOpenPdfFolder;

  @override
  Widget build(BuildContext context) {
    final currentPath = GoRouterState.of(context).uri.path;

    return CallbackShortcuts(
      bindings: shellShortcutBindings(entries, onNavigate),
      child: Scaffold(
        backgroundColor: AppColors.background,
        // Sidebar on the right (first child in an RTL Row).
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 264.w,
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: BorderDirectional(
                  end: BorderSide(color: AppColors.borderMuted),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 16,
                    offset: const Offset(2, 0),
                  ),
                ],
              ),
              child: _Sidebar(
                user: user,
                entries: entries,
                currentPath: currentPath,
                onSelect: onNavigate,
                onLogout: onLogout,
                onLogoutThisDevice: onLogoutThisDevice,
                onOpenPdfFolder: onOpenPdfFolder,
                canOpenPdfFolder: canOpenPdfFolder,
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  ShellTopBar(
                    user: user,
                    locale: locale,
                    theme: theme,
                    syncStatus: syncStatus,
                    onOpenSync: () => onNavigate('/settings?tab=sync'),
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.user,
    required this.entries,
    required this.currentPath,
    required this.onSelect,
    required this.onLogout,
    required this.onLogoutThisDevice,
    required this.onOpenPdfFolder,
    required this.canOpenPdfFolder,
  });

  final User user;
  final List<ShellNavEntry> entries;
  final String currentPath;
  final ValueChanged<String> onSelect;
  final VoidCallback onLogout;
  final VoidCallback onLogoutThisDevice;
  final VoidCallback onOpenPdfFolder;
  final bool canOpenPdfFolder;

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
                ShellIdentityCard(
                  user: user,
                  onLogout: onLogout,
                  onLogoutThisDevice: onLogoutThisDevice,
                ),
                const Divider(height: 1),
                // Nav list.
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final e in entries)
                        ShellNavItem(
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
        // On a phone the export folder is inside the app sandbox and no file
        // manager can reach it, so the button would only ever fail. Reports are
        // shared from the sheet that appears when one is created.
        if (canOpenPdfFolder) const Divider(height: 1),
        if (canOpenPdfFolder)
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
