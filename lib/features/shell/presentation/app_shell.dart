import '../../../core/sync/sync_data_changes.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/auth_gate.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/network/transient_network_error.dart';
import '../../../core/locale/locale_service.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/platform/file_delivery.dart';
import '../../../core/platform/folder_picker.dart';
import '../../../core/sync/sync_metadata.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/commands/command_outbox.dart';
import '../../../core/commands/central_sync_driver.dart';
import '../../../core/commands/offline_write_prompt.dart';
import '../../../core/commands/direct_write_service.dart';
import '../../../design_system/widgets/app_dialogs.dart';
import '../../../core/auth/access_monitor.dart';
import '../../../core/theme/theme_service.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/widgets/app_adaptive.dart';
import '../../auth/domain/user.dart';
import '../../../di/service_locator.dart';
import '../../notifications/domain/notifications_port.dart';
import '../../settings/domain/export_root_service.dart';
import '../../connection/presentation/connection_status_controller.dart';
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
/// It owns a local status timer and a connectivity subscription. If each variant owned
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
    this.commandOutbox,
    this.centralSync,
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
  final CommandOutbox? commandOutbox;
  final CentralSyncDriver? centralSync;
  final ConnectivityService connectivity;
  final ExportRootService exportRoot;
  final FileDelivery fileDelivery;
  final FolderPicker folderPicker;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  DirectWriteService? _operationMonitor;
  StreamSubscription<bool>? _archiveConnectivity;
  late final ConnectionStatusController _syncStatus =
      ConnectionStatusController(
        metadata: widget.syncMetadata,
        onRefreshData: _refreshApprovedData,
        centralReady: widget.centralSync == null
            ? null
            : () async => await widget.centralSync!.currentSequence() != null,
        isOnline: () => widget.connectivity.isOnline,
        connectivityChanges: widget.connectivity.onStatusChange,
      )..start();

  @override
  void initState() {
    super.initState();
    if (getIt.isRegistered<OfflineWritePrompt>()) {
      getIt<OfflineWritePrompt>().askSaveDraft = _chooseOfflineDraft;
      getIt<OfflineWritePrompt>().showNotice = _showWriteNotice;
    }
    WidgetsBinding.instance.addObserver(this);
    widget.centralSync?.mayPoll = _mayPoll;
    _archiveConnectivity = widget.connectivity.onStatusChange.listen((online) {
      SyncDataChanges.notifyStatus();
      if (online) {
        unawaited(widget.centralSync?.refreshForeground(immediate: true));
        if (getIt.isRegistered<DirectWriteService>()) {
          unawaited(getIt<DirectWriteService>().recover());
        }
      }
    });
    widget.centralSync?.start();
    // Killed-app OS notification tap: the payload was stashed by
    // NotificationService.initOs before the router existed. Consume it once
    // (the field is cleared as part of routing, so re-runs are no-ops).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (getIt.isRegistered<DirectWriteService>()) {
        _operationMonitor = getIt<DirectWriteService>();
        _operationMonitor!.onOutcome = _reportOperationOutcome;
        _operationMonitor!.mayMonitor = _isForeground;
        _operationMonitor!.startOutcomeMonitor();
      }
      try {
        final service = getIt<NotificationsPort>();
        final payload = service.pendingPayload;
        if (payload == null || payload.isEmpty) return;
        service.pendingPayload = null;
        _openPayload(payload);
      } on Object {
        // Best effort: stay on the current page (unregistered in tests).
      }
    });
    // Later taps (app foregrounded, pushes arriving mid-session): the payload
    // listener keeps working. The previous one-shot latch meant every OS
    // notification tap beyond the first silently opened nothing.
    try {
      getIt<NotificationsPort>().addPayloadListener(_openPayload);
    } on Object {
      // NotificationService is not registered (tests, harnesses): skip.
    }
  }

  bool _mayPoll() => widget.connectivity.isOnline && _isForeground();

  bool _isForeground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached;
  }

  void _openPayload(String payload) {
    unawaited(() async {
      try {
        final target = await getIt<NotificationsPort>().resolvePayload(payload);
        if (target != null && mounted) context.go(target);
      } on Object {
        // A stale/offline notification must not break navigation.
      }
    }());
  }

  @override
  void dispose() {
    final monitor = _operationMonitor;
    if (monitor != null && monitor.onOutcome == _reportOperationOutcome) {
      monitor.stopOutcomeMonitor();
      monitor.mayMonitor = null;
    }
    if (getIt.isRegistered<OfflineWritePrompt>() &&
        getIt<OfflineWritePrompt>().askSaveDraft == _chooseOfflineDraft) {
      getIt<OfflineWritePrompt>().askSaveDraft = null;
      getIt<OfflineWritePrompt>().showNotice = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _archiveConnectivity?.cancel();
    final sync = widget.centralSync;
    if (sync != null && sync.mayPoll == _mayPoll) {
      sync.mayPoll = null;
      sync.stop();
      sync.cancelActive();
    }
    // The services are process-lifetime singletons: a listener left attached
    // to a disposed shell would route through context.go on a defunct node.
    try {
      getIt<NotificationsPort>().removePayloadListener(_openPayload);
    } on Object {
      // getIt may be torn down in tests before the shell disposes.
    }
    _syncStatus.dispose();
    super.dispose();
  }

  Future<void> _refreshApprovedData() async {
    if (!widget.connectivity.isOnline) {
      await widget.connectivity.refresh();
      if (!mounted) return;
    }
    if (!widget.connectivity.isOnline) {
      if (mounted) {
        AppFeedback.info(
          context,
          AppText.t(
            'لا يوجد اتصال. يتم عرض آخر بيانات محفوظة.',
            'No connection. Showing the last cached data.',
          ),
        );
      }
      return;
    }
    try {
      // Manual refresh may resume reads paused by quota exhaustion. Automatic
      // foreground/reconnect triggers deliberately cannot clear that pause.
      await widget.centralSync?.syncNow();
    } catch (error) {
      if (mounted) {
        if (isTransientNetworkFailure(error)) {
          AppFeedback.info(context, AppError.friendly(error));
        } else {
          AppFeedback.errorFrom(context, error);
        }
      }
    }
  }

  void _showWriteNotice(String message) {
    if (mounted) AppFeedback.info(context, message);
  }

  Future<bool> _reportOperationOutcome(
    CommandOutboxEntry entry,
    bool approved,
  ) async {
    if (!mounted ||
        widget.gate.session.uid != entry.uid ||
        widget.gate.session.organizationId != entry.organizationId) {
      return false;
    }
    final writes = entry.payload['writes'] as List? ?? const [];
    final operations = {
      for (final write in writes.whereType<Map>()) write['operation'],
    };
    final action = !approved
        ? AppText.t('لم تتم العملية', 'Operation failed')
        : operations.length != 1
        ? AppText.t('تم تنفيذ العملية', 'Operation completed')
        : switch (operations.single) {
            'create' => AppText.t('تم الحفظ', 'Saved'),
            'tombstone' => AppText.t('تم الحذف', 'Deleted'),
            _ => AppText.t('تم التعديل', 'Updated'),
          };
    final first = writes.whereType<Map>().firstOrNull;
    final data = first?['payload'];
    final label = data is Map
        ? '${data['name'] ?? data['entryCode'] ?? data['materialName'] ?? ''}'
              .trim()
        : '';
    final ref = entry.operationId.length > 8
        ? entry.operationId.substring(0, 8)
        : entry.operationId;
    final message =
        '$action${label.isEmpty ? '' : ': $label'} [$ref]${approved ? '' : '\n${entry.lastError ?? AppText.t('راجع تفاصيل العملية في المسودات.', 'Review the operation details in Drafts.')}'}';
    AppFeedback.show(
      context,
      message,
      type: approved ? AppFeedbackType.success : AppFeedbackType.error,
      durationSeconds: 7,
    );
    return true;
  }

  Future<bool> _chooseOfflineDraft() async {
    if (!mounted) return false;
    return showAppConfirm(
      context,
      title: AppText.t('لا يوجد اتصال بالإنترنت', 'No internet connection'),
      message: AppText.t(
        'هذه العملية تحتاج اتصالًا. يمكنك حفظها كمسودة على هذا الجهاز ومراجعتها وإرسالها بنفسك لاحقًا.',
        'This action needs an internet connection. Save a draft on this device to review and submit yourself later.',
      ),
      confirmLabel: AppText.t('حفظ كمسودة', 'Save draft'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
      icon: Icons.cloud_off_outlined,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_operationMonitor != null) {
        unawaited(_operationMonitor!.checkOutcomes());
      }
      if (getIt.isRegistered<AuthGate>()) getIt<AuthGate>().updated();
      if (getIt.isRegistered<AccessMonitor>()) getIt<AccessMonitor>().start();
      widget.centralSync?.start();
      unawaited(widget.centralSync?.refreshForeground(immediate: true));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      widget.centralSync?.stop();
      widget.centralSync?.cancelActive();
      if (getIt.isRegistered<AccessMonitor>()) getIt<AccessMonitor>().stop();
    }
  }

  /// The destinations this member can reach, with the permission flags resolved
  /// from the injected session rather than the locator.
  List<ShellNavEntry> _entries(User user) => shellNavEntries(
    canSeeSettings: user.canSeeSettings,
    canReadReference: user.permissions.contains(Permission.samplesRead),
    canReadMembers: user.permissions.contains(Permission.usersRead),
    canReadAudit: user.permissions.contains(Permission.auditRead),
    canReadQc: widget.gate.session.permissions.contains(Permission.qcRead),
    canReadFormulations: widget.gate.session.permissions.contains(
      Permission.formulationsRead,
    ),
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
    if (!delivery.canRevealFolder) return;
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
      if (mounted) AppFeedback.errorFrom(context, e);
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
          canOpenPdfFolder: widget.fileDelivery.canRevealFolder,
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
          canOpenPdfFolder: widget.fileDelivery.canRevealFolder,
          child: widget.child,
        ),
      );
    },
  );
}
