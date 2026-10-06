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

/// Phone shell: a topbar, the routed page, a bottom bar and a drawer.
///
/// ## What the phone gains over the old overlay drawer
///
/// The pre-split narrow branch was a `Stack` with a scrim and a `280.w` panel
/// slid in from the topbar's menu button - and on Android, system back popped
/// the **route** instead of closing it, leaving the app with the drawer still
/// open. Three things fix that here:
///
///  * a real [NavigationBar], so the four unconditional destinations are one tap
///    away instead of two taps through a drawer;
///  * a [PopScope] that consumes the back gesture while the drawer is open, so
///    back closes the drawer first and only then leaves the page;
///  * long-press on any bottom-bar slot for the same destination list
///    `Ctrl+1..9` addresses on desktop, so no destination is reachable on one
///    experience and not the other.
///
/// Nothing here re-implements a destination: the list comes from
/// [shellNavEntries] through the dispatcher - the same list the sidebar renders.
class MobileAppShell extends StatefulWidget {
  const MobileAppShell({
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
  final bool canOpenPdfFolder;

  @override
  State<MobileAppShell> createState() => _MobileAppShellState();
}

class _MobileAppShellState extends State<MobileAppShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _drawerOpen = false;

  /// The bottom bar's slots: the unconditional destinations, then "More".
  ///
  /// The count is fixed at [shellBottomBarSlots] + 1 rather than "whatever this
  /// role may see", so the bar does not reshuffle itself as permissions change
  /// and a member who learned four positions does not lose them. Everything past
  /// the fourth is reached through the drawer.
  List<_BarSlot> get _slots => <_BarSlot>[
    for (final entry in shellBottomBarEntries(widget.entries))
      _BarSlot.destination(entry),
    _BarSlot.more(),
  ];

  /// Navigating from the drawer closes it first, in the order the desktop's
  /// `onSelect` used to: dismiss the chrome, then move.
  void _navigate(String path) {
    if (_drawerOpen) _scaffoldKey.currentState?.closeDrawer();
    widget.onNavigate(path);
  }

  void _selectSlot(int index) {
    final slot = _slots[index];
    if (slot.isMore) {
      _scaffoldKey.currentState?.openDrawer();
      return;
    }
    _navigate(slot.entry!.path);
  }

  /// The keyboard-equivalent jump list, reachable by long press.
  ///
  /// It is the phone's answer to `Ctrl+1..9`: the same [shellShortcutPaths]
  /// order, so a destination the desktop addresses with one keystroke is one
  /// long press away here.
  Future<void> _showJumpList() async {
    final paths = shellShortcutPaths(widget.entries);
    if (paths.isEmpty) return;
    final labels = {for (final e in widget.entries) e.path: e.label};
    final icons = {for (final e in widget.entries) e.path: e.icon};

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                AppText.t('انتقل إلى', 'Jump to'),
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final path in paths)
              ListTile(
                leading: Icon(icons[path]),
                title: Text(labels[path] ?? path),
                onTap: () => Navigator.of(sheetContext).pop(path),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) _navigate(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final currentPath = GoRouterState.of(context).uri.path;
    final section = shellSectionIndex(widget.entries, currentPath);
    final slots = _slots;

    // A destination that lives behind "More" - or a path no destination owns -
    // lights the More slot rather than lighting nothing, so the bar always says
    // where the user is.
    final selected = section >= 0 && section < shellBottomBarSlots
        ? section
        : slots.length - 1;

    return PopScope(
      // While the drawer is up, back closes it instead of leaving the page.
      //
      // `ScaffoldState.openDrawer` already registers a `LocalHistoryEntry`, so
      // a bare `Navigator.pop` would close the drawer too - but only because the
      // pop is allowed to reach the navigator. `canPop: false` stops it, and a
      // blocked pop never removes that local history entry, so the drawer has
      // to be closed explicitly here.
      key: const Key('shell-back-guard'),
      canPop: !_drawerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_drawerOpen) return;
        _scaffoldKey.currentState?.closeDrawer();
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppColors.background,
        onDrawerChanged: (opened) {
          if (opened == _drawerOpen) return;
          setState(() => _drawerOpen = opened);
        },
        drawer: _ShellDrawer(
          user: widget.user,
          entries: widget.entries,
          currentPath: currentPath,
          onSelect: _navigate,
          onLogout: widget.onLogout,
          onLogoutThisDevice: widget.onLogoutThisDevice,
          onOpenPdfFolder: widget.onOpenPdfFolder,
          canOpenPdfFolder: widget.canOpenPdfFolder,
        ),
        body: Column(
          children: [
            ShellTopBar(
              user: widget.user,
              locale: widget.locale,
              theme: widget.theme,
              syncStatus: widget.syncStatus,
              onOpenSync: () => widget.onNavigate('/settings?tab=sync'),
              onMenu: () => _scaffoldKey.currentState?.openDrawer(),
              // The identity card states the role, so the chip would only
              // duplicate it and cost bar width the phone does not have.
              showRoleChip: false,
            ),
            Expanded(child: widget.child),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selected,
          onDestinationSelected: _selectSlot,
          destinations: [
            for (final slot in slots)
              NavigationDestination(
                // `NavigationDestination` has no `onLongPress`, so the long
                // press is a gesture recognizer on the icon - the deepest
                // recognizer on the pointer's hit path, and therefore the one
                // that wins the arena over the destination's own `InkResponse`
                // tap and the bar's tooltip. Verified: a long press fires the
                // handler and does *not* also select the destination.
                icon: slot.isMore
                    ? Icon(slot.icon)
                    : GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onLongPress: () => _showJumpList(),
                        child: Icon(slot.icon),
                      ),
                label: slot.label,
              ),
          ],
        ),
      ),
    );
  }
}

class _ShellDrawer extends StatelessWidget {
  const _ShellDrawer({
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
    return Drawer(
      backgroundColor: AppColors.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ShellIdentityCard(
                    user: user,
                    onLogout: onLogout,
                    onLogoutThisDevice: onLogoutThisDevice,
                  ),
                  const Divider(height: 1),
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
            // Hidden rather than disabled when the sandbox folder cannot be
            // revealed: on a phone no file manager can reach it, so the tap would
            // only ever fail. Reports are shared from the sheet that appears
            // when one is created.
            if (canOpenPdfFolder) ...[
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
          ],
        ),
      ),
    );
  }
}

/// One bottom-bar slot: either a destination or the trailing "More" affordance.
///
/// Neither constructor is `const`: both read a field off a [ShellNavEntry], and
/// [AppStrings.more] is a getter over the active language.
class _BarSlot {
  _BarSlot.destination(ShellNavEntry entry)
    : isMore = false,
      entry = entry,
      label = entry.label,
      icon = entry.icon;

  _BarSlot.more()
    : isMore = true,
      entry = null,
      label = AppStrings.more,
      icon = Icons.more_horiz;

  final bool isMore;
  final ShellNavEntry? entry;
  final String label;
  final IconData icon;
}
