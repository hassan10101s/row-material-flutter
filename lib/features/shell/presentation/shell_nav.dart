import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_strings.dart';
import '../../../router/app_router.dart';

/// One destination in the shell's navigation.
///
/// Described once, for both experiences. The split is in the chrome *around*
/// this list - sidebar versus bottom bar plus drawer - never in the list itself,
/// which is what makes "the phone can reach everything the desktop offers" an
/// assertion rather than a hope.
class ShellNavEntry {
  const ShellNavEntry(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;
}

/// How many destinations go straight onto the phone's bottom bar.
///
/// The entries [shellNavEntries] returns start with three unconditional ones -
/// dashboard, inspections (including material reports), and lab - followed by
/// permission-gated destinations.
const int shellBottomBarSlots = 4;

/// The destinations this member can reach, in navigation order.
///
/// The permission flags are parameters rather than `getIt` lookups so this can
/// be asserted with no service locator at all. [canAudit] is passed separately
/// from the settings flag because the audit destination is gated on the
/// **session** permissions, which are a narrower set than the role's own once a
/// device has been switched read-only.
List<ShellNavEntry> shellNavEntries({
  required bool canSeeSettings,
  required bool canAudit,
  bool canReadQc = false,
}) {
  // Sync and Members are no longer top-level destinations: both live in
  // Settings now (`/settings?tab=sync`, `/settings?tab=members`).
  final entries = <ShellNavEntry>[
    ShellNavEntry('/dashboard', AppStrings.dashboard, Icons.dashboard_outlined),
    ShellNavEntry(
      AppRoutes.inspections,
      AppText.t('فحص الخامات', 'Material inspections'),
      Icons.history,
    ),
    ShellNavEntry('/lab', AppStrings.lab, Icons.biotech_outlined),
  ];
  // QC management is one entry point for all QC Manager destinations.
  if (canReadQc) {
    entries.add(
      ShellNavEntry(
        AppRoutes.qcManagement,
        AppText.t('إدارة الجودة', 'Quality management'),
        Icons.checklist_rtl_outlined,
      ),
    );
  }
  if (canSeeSettings) {
    entries.add(
      ShellNavEntry('/reference', AppStrings.reference, Icons.book_outlined),
    );
    entries.add(
      ShellNavEntry('/settings', AppStrings.settings, Icons.settings_outlined),
    );
  }
  if (canAudit) {
    entries.add(
      ShellNavEntry(
        '/audit',
        AppText.t('سجل التدقيق', 'Audit trail'),
        Icons.history_toggle_off,
      ),
    );
  }
  return entries;
}

/// The index of the destination that owns [currentPath], or -1.
///
/// An exact match wins. Failing that, the longest destination path that
/// [currentPath] starts with, so a detail route like `/inspections/42` keeps
/// its section lit instead of lighting nothing. -1 means the path belongs to no
/// destination, which inside the shell does not occur: every routed page sits
/// under one of the paths above.
int shellSectionIndex(List<ShellNavEntry> entries, String currentPath) {
  if (currentPath == AppRoutes.reports) {
    currentPath = AppRoutes.inspections;
  }
  if (currentPath.startsWith('/qc-') &&
      entries.any((entry) => entry.path == AppRoutes.qcManagement)) {
    return entries.indexWhere(
      (entry) => entry.path == AppRoutes.qcManagement,
    );
  }
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].path == currentPath) return i;
  }
  var best = -1;
  var bestLength = 0;
  for (var i = 0; i < entries.length; i++) {
    final path = entries[i].path;
    if (path.length > bestLength && currentPath.startsWith('$path/')) {
      best = i;
      bestLength = path.length;
    }
  }
  return best;
}

/// The destinations that go on the phone's bottom bar, in order.
List<ShellNavEntry> shellBottomBarEntries(List<ShellNavEntry> entries) =>
    entries.take(shellBottomBarSlots).toList();

/// How many destinations `Ctrl+1`..`Ctrl+9` can address.
///
/// Nine, because there is no tenth digit row key to hang a tenth shortcut on.
const int shellShortcutCount = 9;

/// The paths `Ctrl+1`..`Ctrl+9` jump to, in shortcut order.
///
/// Returned as a plain list so the shortcuts the desktop wires up and the
/// destinations the phone can reach can be asserted against each other: a
/// destination the desktop can jump to by keyboard must be somewhere the phone
/// can navigate to too, or the shortcut set is a capability only one experience
/// has. The phone reaches the same list by long-pressing a bottom-bar slot.
List<String> shellShortcutPaths(List<ShellNavEntry> entries) =>
    entries.take(shellShortcutCount).map((entry) => entry.path).toList();

/// `Ctrl+1`..`Ctrl+9` over [shellShortcutPaths].
///
/// [onNavigate] is injected rather than a `BuildContext` so the map can be
/// built and asserted without a widget tree. The digit keys are addressed by
/// scan code instead of a ten-line literal list: `digit0` is 0x30, so the `n`th
/// digit is 0x30 + n.
Map<ShortcutActivator, VoidCallback> shellShortcutBindings(
  List<ShellNavEntry> entries,
  void Function(String path) onNavigate,
) {
  const digit0 = 0x30;
  final paths = shellShortcutPaths(entries);
  return <ShortcutActivator, VoidCallback>{
    for (var i = 0; i < paths.length; i++)
      SingleActivator(LogicalKeyboardKey(digit0 + i + 1), control: true): () =>
          onNavigate(paths[i]),
  };
}
