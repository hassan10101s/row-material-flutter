import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/auth_gate.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/locale/locale_service.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/platform/file_delivery.dart';
import '../../../core/platform/folder_picker.dart';
import '../../../core/sync/sync_metadata.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/theme/theme_service.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/widgets/app_adaptive.dart';
import '../../auth/domain/user.dart';
import '../../settings/domain/export_root_service.dart';
import '../../sync/presentation/sync_status_controller.dart';
import 'desktop/app_shell.dart';
import 'mobile/app_shell.dart';
import 'shell_nav.dart';

/// Application shell: sidebar or bottom bar, topbar, and the routed page.
///
/// This file holds **no UI**, only the dispatch and the two things both
/// experiences need and neither should own: the destination list and the sync
/// badge's controller. The desktop experience is the pre-split screen; the
/// phone experience is the same destinations in a drawer plus a bottom bar.
///
/// ## Every dependency arrives as a parameter
///
/// The pre-split shell reached for `getIt` in nine places - the sync controller,
/// the nav list, both sign-outs, the export folder, the chrome listenables and
/// two reads of the current user. That made the whole shell untestable: there
/// was no way to build it in a widget test, so there was no way to assert that
/// the two chrome variants reach the same destinations. The router is now the
/// only place that resolves anything, and it passes the graph down.
///
/// ## The sync controller lives here, not in a variant
///
/// It owns a 20s timer and a connectivity subscription. If each variant owned
/// one there would be two timers when one is built and one when the other is,
/// and the badge would depend on which chrome happened to be mounted. The host
/// starts it once and both variants read it.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.child,
    required this.gate,
    required this.locale,
    required this.theme,
    required this.syncQueue,
    required this.syncMetadata,
    required this.connectivity,
    required this.exportRoot,
    required this.fileDelivery,
    required this.folderPicker,
  });

  final Widget child;
  final AuthGate gate;
  final LocaleService locale;
  final ThemeService theme;
  final SyncQueue syncQueue;
  final SyncMetadata syncMetadata;
  final ConnectivityService connectivity;
  final ExportRootService exportRoot;
  final FileDelivery fileDelivery;
  final FolderPicker folderPicker;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final SyncStatusController _syncStatus = SyncStatusController(
    queue: widget.syncQueue,
    metadata: widget.syncMetadata,
    isOnline: () => widget.connectivity.isOnline,
    connectivityChanges: widget.connectivity.onStatusChange,
  )..start();

  @override
  void dispose() {
    _syncStatus.dispose();
    super.dispose();
  }

  /// The destinations this member can reach, with the permission flags resolved
  /// from the injected session rather than the locator.
  List<ShellNavEntry> _entries(User user) => shellNavEntries(
    canSeeSettings: user.canSeeSettings,
    canAudit: widget.gate.session.permissions.contains(Permission.auditRead),
    canReadQc: widget.gate.session.permissions.contains(Permission.qcRead),
  );

  Future<void> _logout() async {
    try {
      await widget.gate.auth.signOut();
    } on AppError {
      // best effort
    } on Object {
      // best effort: the local session is cleared even if the network fails
    }
    widget.gate.updated();
    if (mounted) context.go('/login');
  }

  /// Signs out of this device only: the member stays active and their other
  /// devices keep working.
  Future<void> _logoutThisDevice() async {
    try {
      await widget.gate.auth.signOutThisDevice();
    } on AppError {
      // best effort
    } on Object {
      // best effort: the local session is cleared even if the network fails
    }
    widget.gate.updated();
    if (mounted) context.go('/login');
  }

  Future<void> _openPdfFolder() async {
    final delivery = widget.fileDelivery;
    if (!delivery.canReveal) return;
    final picker = widget.folderPicker;
    final exportRoot = widget.exportRoot;
    try {
      var path = await exportRoot.configuredPath();
      if (path == null) {
        if (!picker.supported) return;
        final picked = await picker.pick(
          dialogTitle: AppText.t(
            'اختر مجلد حفظ التصدير',
            'Choose the exports folder',
          ),
        );
        if (picked == null || !mounted) return;
        await exportRoot.setPath(picked);
        path = picked;
      }
      final opened = await delivery.reveal(path);
      if (!opened && mounted) {
        AppFeedback.error(
          context,
          AppText.t('تعذر فتح مجلد PDF', 'Could not open the PDF folder'),
        );
      }
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (_) {
      if (mounted) {
        AppFeedback.error(
          context,
          AppText.t('تعذر فتح مجلد PDF', 'Could not open the PDF folder'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.locale, widget.theme]),
    builder: (context, _) {
      final user = widget.gate.currentUser;
      if (user == null) return const SizedBox.shrink();

      void navigate(String path) => context.go(path);

      return appAdaptiveVariant(
        context,
        desktop: (_) => DesktopAppShell(
          user: user,
          entries: _entries(user),
          locale: widget.locale,
          theme: widget.theme,
          syncStatus: _syncStatus,
          onNavigate: navigate,
          onLogout: _logout,
          onLogoutThisDevice: _logoutThisDevice,
          onOpenPdfFolder: _openPdfFolder,
          canOpenPdfFolder: widget.fileDelivery.canReveal,
          child: widget.child,
        ),
        mobile: (_) => MobileAppShell(
          user: user,
          entries: _entries(user),
          locale: widget.locale,
          theme: widget.theme,
          syncStatus: _syncStatus,
          onNavigate: navigate,
          onLogout: _logout,
          onLogoutThisDevice: _logoutThisDevice,
          onOpenPdfFolder: _openPdfFolder,
          canOpenPdfFolder: widget.fileDelivery.canReveal,
          child: widget.child,
        ),
      );
    },
  );
}
