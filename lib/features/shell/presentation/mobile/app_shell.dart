import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/locale/locale_service.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_motion.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../auth/domain/user.dart';
import '../../../sync/presentation/sync_status_controller.dart';
import '../shell_chrome.dart';
import '../shell_nav.dart';
import '../chrome_reveal.dart';

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

  /// Scroll-driven chrome visibility: scrolling down folds the top bar and
  /// the bottom bar off their screen edges and hands the whole panel back to
  /// the page; scrolling up, or a drag past the top edge, brings them back.
  ///
  /// While the drawer is open the chrome is forced visible so it slides back
  /// rather than animating under the drawer scrim, and while the keyboard is
  /// up the bottom bar stays folded so typing keeps the maximum body area.
  final ChromeVisibilityController _chrome = ChromeVisibilityController();

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
    // A fresh page starts its scroll at the top, so it opens with the chrome.
    _chrome.reveal();
    widget.onNavigate(path);
  }

  /// Drawer destinations acknowledge the tap with a selection tick — the
  /// bottom bar does the same in [_selectSlot]. The desktop sidebar share of
  /// [ShellNavItem] stays feedback-free.
  void _selectFromDrawer(String path) {
    HapticFeedback.selectionClick();
    _navigate(path);
  }

  @override
  void dispose() {
    _chrome.dispose();
    super.dispose();
  }

  void _selectSlot(int index) {
    HapticFeedback.selectionClick();
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
    // Captured from the page's context: the sheet route has no GoRouterState.
    String? currentPath;
    try {
      currentPath = GoRouterState.of(context).uri.path;
    } catch (_) {
      currentPath = null;
    }

    final chosen = await showAppOverlay<String>(
      context,
      title: AppText.t('انتقل إلى', 'Jump to'),
      builder: (sheetContext, close) => ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          for (final path in paths)
            Builder(
              builder: (context) {
                final selected = currentPath == path;
                return ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  tileColor: selected
                      ? AppColors.primary.withValues(alpha: 0.1)
                      : null,
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(
                        alpha: selected ? 0.16 : 0.07,
                      ),
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                    ),
                    child: Icon(
                      icons[path],
                      size: 19,
                      color: selected ? AppColors.primary : AppColors.textMuted,
                    ),
                  ),
                  title: Text(
                    labels[path] ?? path,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  trailing: selected
                      ? Icon(
                          Icons.check_circle,
                          color: AppColors.primary,
                          size: 20,
                        )
                      : null,
                  onTap: () => close(path),
                );
              },
            ),
        ],
      ),
    );
    if (chosen != null && mounted) {
      HapticFeedback.selectionClick();
      _navigate(chosen);
    }
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

    // With the keyboard up the body is already squeezed from below; folding
    // the nav bar out of the way keeps as much of the form as possible in
    // view. The top bar folds with it - typing fields deserve the whole top.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final revealDuration = AppMotion.of(context, AppMotion.normal);

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
          _chrome.forced = opened;
        },
        drawer: _ShellDrawer(
          user: widget.user,
          entries: widget.entries,
          currentPath: currentPath,
          onSelect: _selectFromDrawer,
          onLogout: widget.onLogout,
          onLogoutThisDevice: widget.onLogoutThisDevice,
          onOpenPdfFolder: widget.onOpenPdfFolder,
          canOpenPdfFolder: widget.canOpenPdfFolder,
        ),
        body: Column(
          children: [
            // The SafeArea stays *outside* the reveal: the status-bar band
            // keeps its inset whether the bar below it is folded or not, so
            // hidden chrome never pushes page content under the status icons.
            SafeArea(
              top: true,
              bottom: false,
              left: false,
              right: false,
              child: ListenableBuilder(
                listenable: _chrome,
                builder: (context, _) => ChromeReveal(
                  visible: _chrome.visible && !keyboardOpen,
                  edge: ChromeRevealEdge.top,
                  duration: revealDuration,
                  child: ShellTopBar(
                    user: widget.user,
                    locale: widget.locale,
                    theme: widget.theme,
                    syncStatus: widget.syncStatus,
                    title: _currentDestinationLabel(currentPath),
                    onOpenSync: () => widget.onNavigate('/settings?tab=sync'),
                    onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                    // The identity card states the role, so the chip would only
                    // duplicate it and cost bar width the phone does not have.
                    showRoleChip: false,
                    compact: true,
                  ),
                ),
              ),
            ),
            // One listener observes every scrollable in the page (vertical
            // notifications bubble up through this bottleneck) and drives the
            // chrome - no screen has to cooperate, and horizontal scrollers
            // inside cards are filtered out by the controller.
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _chrome.handleScrollNotification,
                child: widget.child,
              ),
            ),
          ],
        ),
        // Floating rounded bar: same slots, labels and gestures as before
        // (the split tests pin them), dressed as a surface card with a soft
        // shadow instead of a full-bleed strip. The More slot carries a
        // sync-attention dot while anything is pending/blocked, so unsynced
        // work is visible without opening the drawer.
        //
        // The bottom SafeArea stays *outside* the reveal so the gesture-bar
        // band keeps its inset whether the bar is folded or not; the outer
        // margins ride inside the reveal instead of the SafeArea `minimum`,
        // so folding the bar disappears the whole card - gutter and all -
        // and the page body grows by its full height.
        //
        // The compact single-line label style keeps long Arabic labels from
        // wrapping onto a clipped second line in the narrow slots.
        //
        // The NavigationBar stays built while folded: only its box collapses,
        // so state, keys and sibling finders survive the hidden state.
        bottomNavigationBar: ListenableBuilder(
          listenable: Listenable.merge([widget.syncStatus, _chrome]),
          builder: (context, _) {
            final attention =
                widget.syncStatus.status.pending +
                widget.syncStatus.status.blocked;
            return SafeArea(
              top: false,
              left: false,
              right: false,
              child: ChromeReveal(
                visible: _chrome.visible && !keyboardOpen,
                edge: ChromeRevealEdge.bottom,
                duration: revealDuration,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    0,
                    AppSpacing.md,
                    AppSpacing.sm,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.10),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          border: Border.all(color: AppColors.borderMuted),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: NavigationBarTheme(
                          data: NavigationBarThemeData(
                            labelTextStyle: WidgetStatePropertyAll(
                              TextStyle(
                                fontSize: 11.spMax,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          child: NavigationBar(
                            height: 70,
                            elevation: 0,
                            backgroundColor: Colors.transparent,
                            indicatorColor: AppColors.primary.withValues(
                              alpha: 0.14,
                            ),
                            labelBehavior:
                                NavigationDestinationLabelBehavior.alwaysShow,
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
                                      ? (attention > 0
                                            ? Badge(
                                                smallSize: 9,
                                                backgroundColor:
                                                    AppColors.danger,
                                                child: Icon(slot.icon),
                                              )
                                            : Icon(slot.icon))
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
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String? _currentDestinationLabel(String path) {
    for (final entry in widget.entries) {
      if (entry.path == path) return entry.label;
    }
    return null;
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
                    onOpenSettings: () => onSelect('/settings'),
                  ),
                  const Divider(height: 1),
                  // Small section label so the destination list does not
                  // read as an undivided extension of the identity card.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 10, 22, 2),
                    child: Text(
                      AppText.t('الوجهات', 'Destinations'),
                      style: TextStyle(
                        fontSize: 11.spMax,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textMuted,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  for (final e in entries)
                    ShellNavItem(
                      label: e.label,
                      icon: e.icon,
                      active:
                          entries.indexOf(e) ==
                          shellSectionIndex(entries, currentPath),
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
                padding: const EdgeInsets.all(AppSpacing.md),
                child: AppButton(
                  label: AppStrings.openPdfFolder,
                  icon: Icon(Icons.folder_open, size: 18.r),
                  onPressed: onOpenPdfFolder,
                  style: AppButtonStyle.secondary,
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
