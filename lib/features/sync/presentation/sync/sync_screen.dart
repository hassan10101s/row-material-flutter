import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/commands/command_outbox.dart';
import '../../../../core/commands/command_worker.dart';
import '../../../../core/commands/central_sync_driver.dart';
import '../../../../core/sync/conflict_resolver.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/sync/sync_metadata.dart';
import '../../../../core/sync/sync_queue.dart';
import '../../../../di/service_locator.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_page_header.dart';
import '../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../design_system/export/table_html_export.dart';
import '../../../../core/constants/app_strings.dart';

/// SyncScreen (plan P13.4/P25): status, pending/blocked counters, manual
/// "sync now", and the conflict list with keep-local / keep-remote actions.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, this.embedded = false});

  /// Renders without its own page padding, for hosting inside the Settings tabs.
  final bool embedded;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _engine = getIt<SyncEngine>();
  final _queue = getIt<SyncQueue>();
  final _commands = getIt<CommandOutbox>();
  final _conflicts = getIt<ConflictResolver>();

  StreamSubscription<SyncStatusSnapshot>? _subscription;
  SyncStatusSnapshot? _status;
  List<Map<String, Object?>> _rows = const [];
  List<Map<String, Object?>> _queueRows = const [];
  List<CommandOutboxEntry> _commandRows = const [];
  CommandOutboxCounts? _commandCounts;
  int? _centralSequence;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _subscription = _engine.status.listen((snapshot) {
      if (mounted) setState(() => _status = snapshot);
    });
    // Deferred by one frame: `_guarded` flips `_busy` with `setState`, which is
    // illegal while the tree is still building. The load is also not urgent
    // enough to sit ahead of the first paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_guarded(_refresh));
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// Runs [action] behind the busy flag and reports a failure to the user.
  ///
  /// These handlers used to be bare `try { ... } finally { ... }`. A thrown
  /// error escaped as an *unhandled* async exception: the spinner stopped, no
  /// banner appeared, and keep-local/keep-remote looked like a silent no-op. A
  /// sync screen that cannot report a failed sync is worse than no sync screen,
  /// because the user concludes the row is fine.
  Future<void> _guarded(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) AppFeedback.errorFrom(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (centralCommandPilotEnabled) {
      await getIt<CentralSyncDriver>().syncNow();
      await _refreshData();
      return;
    }
    final snapshot = await _engine.syncNow(reason: 'screen');
    if (mounted) setState(() => _status = snapshot);
    await _refreshData();
  }

  /// Re-reads the conflict/queue lists. Deliberately does **not** run a sync
  /// cycle: every `_retryAll`-style action has already run its own [syncNow],
  /// and the old shape called [syncNow] a second time through here — two full
  /// walks (2× the pull plus 2× the audit maintenance) per button tap.
  Future<void> _refreshData() async {
    final results = await Future.wait<Object?>([
      _queue.listConflicts(limit: 200),
      _queue.listQueue(limit: 200),
      _commands.list(limit: 200),
      _commands.counts(),
      if (centralCommandPilotEnabled)
        getIt<CentralSyncDriver>().currentSequence(),
    ]);
    final rows = results[0] as List<Map<String, Object?>>;
    final queueRows = results[1] as List<Map<String, Object?>>;
    final commandRows = results[2] as List<CommandOutboxEntry>;
    final commandCounts = results[3] as CommandOutboxCounts;
    final centralSequence = centralCommandPilotEnabled
        ? results[4] as int?
        : null;
    if (mounted) {
      setState(() {
        _rows = rows;
        _queueRows = queueRows;
        _commandRows = commandRows;
        _commandCounts = commandCounts;
        _centralSequence = centralSequence;
      });
    }
  }

  Future<void> _syncNow() => _guarded(() async {
    if (centralCommandPilotEnabled) {
      await getIt<CentralSyncDriver>().syncNow();
      await _refreshData();
      return;
    }
    await _engine.syncNow(reason: 'manual');
    await _refreshData();
  });

  /// "تنزيل السجل": a pull-only cycle, for a device that just wants the
  /// server's history without pushing anything.
  Future<void> _downloadHistory() => _guarded(() async {
    if (centralCommandPilotEnabled) {
      await getIt<CentralSyncDriver>().syncNow();
      await _refreshData();
      return;
    }
    await _engine.syncNow(reason: 'history', pullOnly: true);
    await _refreshData();
  });

  /// "إعادة السحب الكامل": forget pull cursors and re-walk every collection
  /// from the beginning. For devices whose cursor was poisoned by old code
  /// that advanced past documents it failed to apply: those rows are behind
  /// the cursor, so no normal pull (and no reinstall — APK reinstall keeps
  /// app data) will ever fetch them. Applied rows re-skip cheaply and queued
  /// local edits are untouched, unlike wiping app data.
  Future<void> _fullRepull() => _guarded(() async {
    if (centralCommandPilotEnabled) {
      await getIt<CentralSyncDriver>().syncNow(forceSnapshot: true);
      await _refreshData();
      return;
    }
    await getIt<SyncMetadata>().clearCursors();
    await _engine.syncNow(reason: 'full-repull', pullOnly: true);
    await _refreshData();
    if (mounted) {
      AppFeedback.success(
        context,
        AppText.t('تمت إعادة السحب الكامل', 'Full re-pull done'),
      );
    }
  });

  /// "إعادة المحاولة": clear the backoff of every blocked row, then sync again.
  Future<void> _retryAll() => _guarded(() async {
    await _queue.retryBlocked();
    await _engine.syncNow(reason: 'retry');
    await _refreshData();
  });

  Future<void> _retryOne(Map<String, Object?> row) => _guarded(() async {
    await _queue.retryRow((row['id'] as num).toInt());
    await _engine.syncNow(reason: 'retry-one');
    await _refreshData();
  });

  Future<void> _dismissAll() => _guarded(() async {
    final gate = getIt<AuthGate>();
    if (!gate.online ||
        !gate.session.canDo(Permission.orgUpdate, online: gate.online)) {
      return;
    }
    final organizationId = gate.organizationId;
    final actor = _SessionView(gate.session.uid, gate.session.deviceId);
    final ids = _rows.map((row) => (row['id'] as num).toInt()).toList();
    if (ids.isEmpty) return;
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('تنظيف التعارضات', 'Clean up conflicts'),
      message: AppText.t(
        'استبدال التعديلات المحلية المتعارضة الظاهرة (${ids.length}) بأحدث نسخة من السيرفر؟ سيُحفظ سجل التعارض، وتبقى الحالات التي يتعذر التحقق منها للمراجعة. لا تُحذف بيانات السيرفر.',
        'Replace the ${ids.length} displayed conflicting local changes with current server copies? Conflict history is retained. Unverifiable cases remain for review. Server data is not deleted.',
      ),
      confirmLabel: AppText.t('اعتماد نسخة السيرفر', 'Use server copies'),
      danger: true,
    );
    if (!confirmed || !mounted) return;
    final failures = await _conflicts.cleanUpFromServer(
      ids,
      organizationId: organizationId,
      session: actor,
    );
    await _refreshData();
    if (!mounted) return;
    final message = AppText.t(
      'تمت معالجة ${ids.length - failures.length} تعارض؛ متبقٍ للمراجعة ${failures.length}.',
      'Processed ${ids.length - failures.length} conflicts; ${failures.length} remain for review.',
    );
    if (failures.isEmpty) {
      AppFeedback.success(context, message);
    } else {
      AppFeedback.error(context, message);
    }
  });

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    final status = _status;
    final pendingCount = centralCommandPilotEnabled
        ? ((_commandCounts?.pending ?? 0) +
              (_commandCounts?.awaitingProjection ?? 0))
        : (status?.pending ?? 0);
    final blockedCount = centralCommandPilotEnabled
        ? ((_commandCounts?.rejected ?? 0) +
              (_commandCounts?.needsReview ?? 0) +
              (_commandCounts?.requiresAuth ?? 0))
        : (status?.blocked ?? 0);
    final conflictCount = centralCommandPilotEnabled
        ? (_commandCounts?.needsReview ?? 0)
        : (status?.conflicts ?? 0);
    final centralReady = _centralSequence != null;
    return ListView(
      padding: widget.embedded
          ? EdgeInsets.zero
          : const EdgeInsets.all(AppSpacing.page),
      children: [
        // Title on its own line, actions in a `Wrap` underneath. As one `Row` with a
        // `Spacer` this header's minimum intrinsic width - an Arabic title plus
        // up to three Arabic-labelled buttons - exceeds a 360dp phone, so the
        // buttons were pushed off-screen behind a RenderFlex overflow. A `Wrap`
        // reflows them onto a second line at any width, and `end` alignment
        // keeps them right-aligned on desktop where they still fit on one line.
        AppPageHeader(
          title: AppText.t('المزامنة', 'Sync'),
          subtitle: gate.session.offline
              ? AppText.t(
                  'جلسة محلية (بدون توكن حي)',
                  'Local session (no live token)',
                )
              : AppText.t(
                  'الحالة والطابور والتعارضات',
                  'Status, queue and conflicts',
                ),
          icon: Icons.sync_outlined,
          actions: [
            AppButton(
              label: AppText.t('مزامنة الآن', 'Sync now'),
              small: true,
              loading: _busy,
              icon: const Icon(Icons.sync, size: 18),
              onPressed: _busy || !gate.online ? null : _syncNow,
            ),
            if (!centralCommandPilotEnabled && (status?.blocked ?? 0) > 0)
              AppButton(
                label: AppText.t('إعادة المحاولة', 'Retry'),
                small: true,
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _busy || !gate.online ? null : _retryAll,
              ),
            if (!centralCommandPilotEnabled &&
                _rows.isNotEmpty &&
                gate.session.canDo(Permission.orgUpdate, online: gate.online))
              AppButton(
                label: AppText.t('تنظيف التعارضات', 'Clean up conflicts'),
                small: true,
                icon: const Icon(Icons.clear_all, size: 18),
                onPressed: _busy || !gate.online ? null : _dismissAll,
              ),
            AppButton(
              label: AppText.t('تنزيل السجل', 'Download log'),
              small: true,
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              onPressed: _busy || !gate.online ? null : _downloadHistory,
            ),
            AppButton(
              label: AppText.t('سحب كامل', 'Full re-pull'),
              small: true,
              icon: const Icon(Icons.refresh_outlined, size: 18),
              onPressed: _busy || !gate.online ? null : _fullRepull,
            ),
            if (centralCommandPilotEnabled)
              AppButton(
                label: AppText.t('تنظيف الطلبات المحسومة', 'Clean settled'),
                small: true,
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                onPressed: _busy ? null : _archiveSettled,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // Four equal-width `Expanded` tiles leave each one ~90dp on a 360dp phone, which
        // the Arabic labels wrap into rather than fit. Below
        // [AppBreakpoints.medium] the tiles take the full width and stack;
        // above it they keep the original four-across row.
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final stacked = width < AppBreakpoints.medium;
            final tileWidth = stacked ? width : (width - AppSpacing.sm * 3) / 4;
            return Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _Tile(
                  label: AppText.t('الحالة', 'Status'),
                  value: centralCommandPilotEnabled
                      ? (centralReady
                            ? AppText.t(
                                'جاهز · $_centralSequence',
                                'Ready · $_centralSequence',
                              )
                            : AppText.t(
                                'جارٍ تحميل الأرشيف',
                                'Loading archive',
                              ))
                      : status?.badge ?? '—',
                  color: centralCommandPilotEnabled
                      ? (centralReady ? AppColors.success : AppColors.warning)
                      : _badgeColor(status),
                  width: tileWidth,
                ),
                _Tile(
                  label: AppText.t('في الانتظار', 'Pending'),
                  value: '$pendingCount',
                  width: tileWidth,
                ),
                _Tile(
                  label: AppText.t('محجوب', 'Blocked'),
                  value: '$blockedCount',
                  color: blockedCount > 0 ? AppColors.danger : null,
                  width: tileWidth,
                ),
                _Tile(
                  label: AppText.t('تعارضات', 'Conflicts'),
                  value: '$conflictCount',
                  color: conflictCount > 0 ? AppColors.warning : null,
                  width: tileWidth,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '${AppText.t('آخر رفع', 'Last upload')}: ${_time(status?.lastPushAt)}\n'
          '${AppText.t('آخر تنزيل', 'Last download')}: ${_time(status?.lastPullAt)}',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
        if (status?.lastError != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            AppText.t(
              'تعذر إكمال آخر عملية مزامنة. حاول مرة أخرى لاحقًا.',
              'The last sync did not complete. Please try again later.',
            ),
            style: TextStyle(color: AppColors.danger, fontSize: 12.spMax),
          ),
        ],
        if (status?.degraded == true) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            AppText.t(
              'المزامنة غير مهيأة — التطبيق يعمل محلياً فقط.',
              'Sync is not configured — the app works locally only.',
            ),
            style: TextStyle(color: AppColors.warning, fontSize: 12.spMax),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text(
          AppText.t('طلبات الاعتماد المركزي', 'Central approval requests'),
          style: TextStyle(fontSize: 15.spMax, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_commandRows.isEmpty)
          Text(AppText.t('لا توجد طلبات مركزية.', 'No central requests.'))
        else
          SizedBox(
            height: 280.h,
            child: AppPaginatedTable(
              minTableWidth: 920,
              columnFlex: const [1.2, 1.2, 0.8, 0.8, 1.5, 1.1],
              headers: [
                AppText.t('العملية', 'Operation'),
                AppText.t('المعرّف', 'Operation ID'),
                AppText.t('الحالة', 'State'),
                AppText.t('المحاولات', 'Attempts'),
                AppText.t('التفاصيل', 'Details'),
                AppText.t('الإجراءات', 'Actions'),
              ],
              rows: [
                for (final command in _commandRows)
                  [
                    Text(
                      command.commandType,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      command.operationId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(command.state.value),
                    Text('${command.attempts}'),
                    Text(
                      command.lastError ??
                          command.lastErrorCode ??
                          AppText.t('—', '—'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    _commandAction(command),
                  ],
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Text(
              AppText.t('الطابور', 'Queue'),
              style: TextStyle(fontSize: 15.spMax, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            IconButton(
              tooltip: AppText.t('تصدير جدول', 'Export table'),
              visualDensity: VisualDensity.compact,
              onPressed: _queueRows.isEmpty
                  ? null
                  : () => TableHtmlExport.export(
                      context,
                      filePrefix: 'sync_queue',
                      title: AppText.t('طابور المزامنة', 'Sync queue'),
                      headers: _QueueRow.exportHeaders(),
                      rows: _QueueRow.exportRows(_queueRows),
                    ),
              icon: const Icon(Icons.table_view_outlined),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_queueRows.isEmpty)
          Text(AppText.t('لا توجد عناصر في الطابور.', 'Queue is empty.'))
        else
          SizedBox(
            height: 320.h,
            child: AppPaginatedTable(
              minTableWidth: 720,
              columnFlex: const [1.4, 0.8, 0.8, 1.2, 0.8],
              headers: [
                ..._QueueRow.exportHeaders(),
                AppText.t('الإجراءات', 'Actions'),
              ],
              rows: [
                for (final row in _queueRows)
                  [
                    Text(
                      '${row['entity_type']} · ${row['entity_id']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${row['operation']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _QueueRow.statusLabel('${row['status'] ?? ''}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _QueueRow.infoText(row),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    () {
                      final status = '${row['status'] ?? ''}';
                      if (status == 'failed' || status == 'conflict') {
                        return AppButton(
                          label: AppText.t('إعادة', 'Retry'),
                          small: true,
                          style: AppButtonStyle.ghost,
                          onPressed: _busy || !gate.online
                              ? null
                              : () => _retryOne(row),
                        );
                      }
                      return const SizedBox.shrink();
                    }(),
                  ],
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Text(
              AppText.t('التعارضات', 'Conflicts'),
              style: TextStyle(fontSize: 15.spMax, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            IconButton(
              tooltip: AppText.t('تصدير جدول', 'Export table'),
              visualDensity: VisualDensity.compact,
              onPressed: _rows.isEmpty
                  ? null
                  : () => TableHtmlExport.export(
                      context,
                      filePrefix: 'sync_conflicts',
                      title: AppText.t('تعارضات المزامنة', 'Sync conflicts'),
                      headers: _ConflictRow.exportHeaders(),
                      rows: _ConflictRow.exportRows(_rows),
                    ),
              icon: const Icon(Icons.table_view_outlined),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_rows.isEmpty)
          Text(
            AppText.t(
              'لا توجد تعارضات بانتظار المراجعة.',
              'No conflicts awaiting review.',
            ),
          )
        else
          SizedBox(
            height: 320.h,
            child: AppPaginatedTable(
              minTableWidth: 720,
              columnFlex: const [1.4, 0.9, 1.1, 1.6],
              headers: [
                ..._ConflictRow.exportHeaders(),
                AppText.t('الإجراءات', 'Actions'),
              ],
              rows: [
                for (final row in _rows)
                  [
                    Text(
                      '${row['entity_type']} · ${row['entity_id']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${row['direction']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${row['detected_at']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Tooltip(
                          message: AppText.t('إبقاء المحلي', 'Keep local'),
                          child: AppButton(
                            icon: Icon(
                              Icons.edit_note,
                              semanticLabel: AppText.t(
                                'إبقاء المحلي',
                                'Keep local',
                              ),
                            ),
                            small: true,
                            style: AppButtonStyle.ghost,
                            onPressed: _busy || !_canResolve
                                ? null
                                : () => _keepLocal(row),
                          ),
                        ),
                        Tooltip(
                          message: AppText.t('إبقاء الخادم', 'Keep server'),
                          child: AppButton(
                            icon: Icon(
                              Icons.cloud_download_outlined,
                              semanticLabel: AppText.t(
                                'إبقاء الخادم',
                                'Keep server',
                              ),
                            ),
                            small: true,
                            style: AppButtonStyle.ghost,
                            onPressed: _busy || !_canResolve
                                ? null
                                : () => _keepRemote(row),
                          ),
                        ),
                      ],
                    ),
                  ],
              ],
            ),
          ),
      ],
    );
  }

  bool get _canResolve {
    final gate = getIt<AuthGate>();
    return gate.session.canDo(Permission.samplesUpdate, online: gate.online);
  }

  void _refuseOffline() {
    AppFeedback.error(
      context,
      AppText.t(
        'حل التعارض يحتاج جلسة صالحة واتصال بالإنترنت',
        'Resolving a conflict needs a valid session and an internet connection',
      ),
    );
  }

  Future<void> _keepLocal(Map<String, Object?> row) async {
    if (!_canResolve) return _refuseOffline();
    final gate = getIt<AuthGate>();
    await _guarded(() async {
      await _conflicts.keepLocal(
        (row['id'] as num).toInt(),
        organizationId: gate.organizationId,
        session: _SessionView(gate.session.uid, gate.session.deviceId),
      );
      await _refreshData();
    });
  }

  Future<void> _keepRemote(Map<String, Object?> row) async {
    if (!_canResolve) return _refuseOffline();
    final gate = getIt<AuthGate>();
    await _guarded(() async {
      await _conflicts.keepRemote(
        (row['id'] as num).toInt(),
        organizationId: gate.organizationId,
        session: _SessionView(gate.session.uid, gate.session.deviceId),
      );
      await _refreshData();
    });
  }

  static String _time(DateTime? value) => value == null
      ? '—'
      : '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  static Color? _badgeColor(SyncStatusSnapshot? status) {
    if (status == null) return null;
    if (!status.online) return AppColors.textMuted;
    if (status.syncing) return AppColors.primary;
    if (status.blocked > 0 ||
        status.failed > 0 ||
        (status.lastError?.isNotEmpty ?? false)) {
      return AppColors.danger;
    }
    if (status.pullIncomplete || !status.fullySynced) {
      return AppColors.textMuted;
    }
    return AppColors.success;
  }

  /// Per-row correction actions in the central requests table (production
  /// acceptance 3): requeue after sign-in, archive-and-release after a final
  /// rejection, and the conflict review for needs_review. Approved rows are
  /// resolved by definition; cleanup handles them in bulk.
  Widget _commandAction(CommandOutboxEntry command) {
    final gate = getIt<AuthGate>();
    switch (command.state) {
      case OutboxState.authRequired:
        return AppButton(
          label: AppText.t('إعادة الإرسال', 'Requeue'),
          small: true,
          style: AppButtonStyle.ghost,
          onPressed: _busy || !gate.online ? null : () => _retryAuthRequired(),
        );
      case OutboxState.rejected:
        return AppButton(
          label: AppText.t('أرشفة ورفع القفل', 'Archive'),
          small: true,
          style: AppButtonStyle.ghost,
          onPressed: _busy ? null : () => _archiveRejected(command),
        );
      case OutboxState.needsReview:
        return AppButton(
          label: AppText.t('عرض التعارض', 'Review'),
          small: true,
          style: AppButtonStyle.ghost,
          onPressed: _busy ? null : () => _showConflictReview(command),
        );
      case OutboxState.pending:
      case OutboxState.inFlight:
      case OutboxState.approved:
      case OutboxState.archived:
        return const SizedBox.shrink();
    }
  }

  /// Reads the approved after-image of one entity for the conflict dialog.
  Future<(int, String)?> _approvedCopyInfo(String entityType, String entityId) async {
    if (entityType.isEmpty || entityId.isEmpty) return null;
    final rows = await (await _commands.dbHelper.database).query(
      'central_approved_records',
      columns: ['version', 'payload'],
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [entityType, entityId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final version = (rows.single['version'] as num).toInt();
    String payloadText;
    try {
      final payload = jsonDecode('${rows.single['payload']}');
      payloadText = const JsonEncoder.withIndent('  ').convert(payload);
      if (payloadText.length > 1500) payloadText = '${payloadText.substring(0, 1500)}…';
    } on Object {
      payloadText = '—';
    }
    return (version, payloadText);
  }

  /// Central cleanup (production acceptance 3): archive resolved rows only.
  Future<void> _archiveSettled() => _guarded(() async {
    final count = await _commands.archiveSettled();
    await _refreshData();
    if (!mounted) return;
    AppFeedback.success(
      context,
      AppText.t(
        'أُرشفت $count طلبات محسومة؛ لم تمس الإيصالات ولا الطلبات المعلقة.',
        'Archived $count resolved requests; receipts and pending rows untouched.',
      ),
    );
  });

  /// Requeue auth_required requests after a fresh sign-in — same account,
  /// organization and device, same operationId + hash (outbox scope).
  Future<void> _retryAuthRequired() => _guarded(() async {
    final requeued = await _commands.retryRejected(onlyPendingable: true);
    await getIt<CommandWorker>().runOnce();
    await _refreshData();
    if (mounted && requeued > 0) {
      AppFeedback.success(
        context,
        AppText.t(
          'أعيدت $requeued طلبات إلى الانتظار بنفس المعرف.',
          '$requeued request(s) requeued under their original ids.',
        ),
      );
    }
  });

  /// Final rejection: archive the request and release its record locks so a
  /// corrected request can be authored (production acceptance 3).
  Future<void> _archiveRejected(CommandOutboxEntry command) => _guarded(() async {
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('أرشفة الطلب المرفوض', 'Archive the rejected request'),
      message: AppText.t(
        'سيُأرشف الطلب مع سبب الرفض ويرفع قفل السجل، فتستطيع إنشاء طلب مصحح جديد بالنسخة الحالية. الإيصال يبقى محفوظًا.',
        'The request is archived with its rejection reason and the record locks are released, so a corrected request can be authored at the current version. The receipt is kept.',
      ),
      confirmLabel: AppText.t('أرشفة ورفع القفل', 'Archive and release'),
      danger: true,
    );
    if (!confirmed || !mounted) return;
    final released = await _commands.releaseLockAndArchive(
      command.operationId,
      reason: AppText.t(
        'أُرشف بقرار المستخدم بعد الرفض النهائي',
        'Archived by user decision after a final rejection',
      ),
    );
    await _refreshData();
    if (!mounted) return;
    if (released) {
      AppFeedback.success(
        context,
        AppText.t('رُفع قفل السجل؛ أنشئ طلبًا جديدًا بعد اكتمال المزامنة.', 'Lock released; author a new request once sync completes.'),
      );
    } else {
      AppFeedback.error(
        context,
        AppText.t('لا يمكن أرشفة طلب مصيره غير محسوم بعد.', 'A request whose fate is not settled cannot be archived yet.'),
      );
    }
  });

  /// Version conflict (needs_review): show the approved copy against the
  /// parked request, then let the user discard their request (archive +
  /// release the lock) and re-author from the current version. Never merges
  /// silently (production acceptance 3).
  Future<void> _showConflictReview(CommandOutboxEntry command) async {
    final writes = command.payload['writes'];
    final approvedInfo = writes is List && writes.isNotEmpty && writes.first is Map
        ? await _approvedCopyInfo(
            '${(writes.first as Map)['entityType']}',
            '${(writes.first as Map)['entityId']}',
          )
        : null;
    if (!mounted) return;
    final discard = await showAppConfirm(
      context,
      title: AppText.t('تعارض إصدار السجل', 'Record version conflict'),
      message: [
        AppText.t(
          'طلبي: الإصدار المتوقع ${command.expectedVersion}.',
          'My request: expected version ${command.expectedVersion}.',
        ),
        if (approvedInfo != null)
          AppText.t(
            'النسخة المعتمدة على السيرفر: الإصدار ${approvedInfo.$1}.',
            'Approved server copy: version ${approvedInfo.$1}.',
          ),
        if (approvedInfo != null) approvedInfo.$2,
        AppText.t(
          'السبب: ${command.lastError ?? command.lastErrorCode ?? '—'}',
          'Reason: ${command.lastError ?? command.lastErrorCode ?? '—'}',
        ),
        AppText.t(
          'لتعديل الطلب: تجاهل هذا الطلب (يُأرشف ويُرفع القفل)، وبعد اكتمال المزامنة أنشئ طلبًا جديدًا بالإصدار الحالي من الشاشة نفسها.',
          'To proceed: discard this request (archived, locks released), then author a new request at the current version once sync completes.',
        ),
      ].join('\n'),
      confirmLabel: AppText.t('تجاهل طلبي وأرشفة', 'Discard my request'),
      cancelLabel: AppText.t('إبقاء الطلب للمراجعة', 'Keep for review'),
      danger: true,
    );
    if (!discard || !mounted) return;
    await _guarded(() async {
      final released = await _commands.releaseLockAndArchive(
        command.operationId,
        reason: AppText.t(
          'تجاهل المستخدم طلبه بعد تعارض الإصدار',
          'User discarded the request after a version conflict',
        ),
      );
      await _refreshData();
      if (!mounted) return;
      AppFeedback.success(
        context,
        released
            ? AppText.t('رُفع القفل؛ أنشئ طلبًا جديدًا بالإصدار الحالي.', 'Lock released; author a new request at the current version.')
            : AppText.t('الطلب لم يعد في حالة قرار.', 'The request is no longer awaiting a decision.'),
      );
    });
  }
}

/// The two fields the resolver needs to stamp the replayed document.
class _SessionView implements AppSessionLike {
  const _SessionView(this.uid, this.deviceId);

  @override
  final String uid;

  @override
  final String deviceId;
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.value,
    this.color,
    required this.width,
  });

  final String label;
  final String value;
  final Color? color;

  /// Width assigned by the caller's [LayoutBuilder]. Explicit rather than
  /// `Expanded`, so the tiles can live in a [Wrap] and take the full width on a
  /// phone instead of being squeezed into ~90dp columns.
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AppCard(
        margin: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              value,
              style: TextStyle(
                fontSize: 18.spMax,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared labels + export mapping for one `sync_queue` row: what it is, how
/// many attempts it took and the last error. Used by the queue table and its
/// HTML export alike.
class _QueueRow {
  _QueueRow._();

  static String statusLabel(String status) {
    return switch (status) {
      'pending' => AppText.t('في الانتظار', 'Pending'),
      'in_flight' => AppText.t('جارٍ الإرسال', 'Sending'),
      'failed' => AppText.t('فشل', 'Failed'),
      'conflict' => AppText.t('تعارض', 'Conflict'),
      'blocked' => AppText.t('محجوب', 'Blocked'),
      _ => AppText.t('غير معروف', 'Unknown'),
    };
  }

  static String infoText(Map<String, Object?> row) {
    final retryCount = (row['retry_count'] as num?)?.toInt() ?? 0;
    final error = row['last_error'];
    return [
      if (retryCount > 0)
        AppText.t('محاولات: $retryCount', 'Attempts: $retryCount'),
      if (error != null && '$error'.trim().isNotEmpty)
        AppText.t('تعذرت آخر محاولة', 'Last attempt failed'),
    ].join(' · ');
  }

  static List<String> exportHeaders() => [
    AppText.t('الكيان', 'Entity'),
    AppText.t('العملية', 'Operation'),
    AppText.t('الحالة', 'Status'),
    AppText.t('معلومات', 'Info'),
  ];

  static List<List<String>> exportRows(List<Map<String, Object?>> rows) => [
    for (final row in rows)
      [
        '${row['entity_type']} · ${row['entity_id']}',
        '${row['operation']}',
        statusLabel('${row['status'] ?? ''}'),
        infoText(row),
      ],
  ];
}

class _ConflictRow {
  _ConflictRow._();

  static List<String> exportHeaders() => [
    AppText.t('الكيان', 'Entity'),
    AppText.t('الاتجاه', 'Direction'),
    AppText.t('الرصد', 'Detected'),
  ];

  static List<List<String>> exportRows(List<Map<String, Object?>> rows) => [
    for (final row in rows)
      [
        '${row['entity_type']} · ${row['entity_id']}',
        '${row['direction']}',
        '${row['detected_at']}',
      ],
  ];
}
