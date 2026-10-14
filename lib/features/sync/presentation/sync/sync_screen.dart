import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/sync/conflict_resolver.dart';
import '../../../../core/sync/backfill_service.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/sync/sync_metadata.dart';
import '../../../../core/sync/sync_queue.dart';
import '../../../../di/service_locator.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/widgets/app_button.dart';
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
  final _conflicts = getIt<ConflictResolver>();

  StreamSubscription<SyncStatusSnapshot>? _subscription;
  SyncStatusSnapshot? _status;
  List<Map<String, Object?>> _rows = const [];
  List<Map<String, Object?>> _queueRows = const [];
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
    final snapshot = await _engine.syncNow(reason: 'screen');
    final rows = await _queue.listConflicts(limit: 200);
    final queueRows = await _queue.listQueue(limit: 200);
    if (mounted) {
      setState(() {
        _status = snapshot;
        _rows = rows;
        _queueRows = queueRows;
      });
    }
  }

  Future<void> _syncNow() =>
      _guarded(() async {
        await _engine.syncNow(reason: 'manual');
        await _refresh();
      });

  /// "تنزيل السجل": a pull-only cycle, for a device that just wants the
  /// server's history without pushing anything.
  Future<void> _downloadHistory() =>
      _guarded(() async {
        await _engine.syncNow(reason: 'history', pullOnly: true);
        await _refresh();
      });

  /// "إعادة السحب الكامل": forget pull cursors and re-walk every collection
  /// from the beginning. For devices whose cursor was poisoned by old code
  /// that advanced past documents it failed to apply: those rows are behind
  /// the cursor, so no normal pull (and no reinstall — APK reinstall keeps
  /// app data) will ever fetch them. Applied rows re-skip cheaply and queued
  /// local edits are untouched, unlike wiping app data.
  Future<void> _fullRepull() => _guarded(() async {
        await getIt<SyncMetadata>().clearCursors();
        await _engine.syncNow(reason: 'full-repull', pullOnly: true);
        await _refresh();
        if (mounted) {
          AppFeedback.success(
            context,
            AppText.t(
              'تمت إعادة السحب الكامل',
              'Full re-pull done',
            ),
          );
        }
      });

  /// "رفع المتأخر": re-queue every local inspection row that never reached
  /// the server (imports / restores / lost queue rows), then push in batches.
  /// Temporary recovery tool for the current history backlog.
  Future<void> _backfill() => _guarded(() async {
        final report =
            await getIt<BackfillService>().enqueueUnsyncedSamples();
        await _engine.syncNow(reason: 'backfill');
        await _refresh();
        if (mounted) {
          AppFeedback.success(
            context,
            AppText.t(
              'تم تجهيز ${report.total} سجل للرفع (${report.tombstones} حذف)',
              'Queued ${report.total} record(s) for upload (${report.tombstones} deletes)',
            ),
          );
        }
      });

  /// "إعادة المحاولة": clear the backoff of every blocked row, then sync again.
  Future<void> _retryAll() =>
      _guarded(() async {
        await _queue.retryBlocked();
        await _engine.syncNow(reason: 'retry');
        await _refresh();
      });

  Future<void> _retryOne(Map<String, Object?> row) =>
      _guarded(() async {
        await _queue.retryRow((row['id'] as num).toInt());
        await _engine.syncNow(reason: 'retry-one');
        await _refresh();
      });

  /// "تجاهل الكل": dismiss every unresolved conflict without picking a side.
  /// Purely local (no sync cycle), so it also works offline — the stale rows
  /// just stop blocking the badge until fresh writes re-queue themselves.
  Future<void> _dismissAll() =>
      _guarded(() async {
        await _queue.dismissAllConflicts();
        await _refresh();
      });

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    final status = _status;
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
              ? AppText.t('جلسة محلية (بدون توكن حي)',
                  'Local session (no live token)')
              : AppText.t('الحالة والطابور والتعارضات',
                  'Status, queue and conflicts'),
          icon: Icons.sync_outlined,
          actions: [
            AppButton(
              label: AppText.t('مزامنة الآن', 'Sync now'),
              small: true,
              loading: _busy,
              icon: const Icon(Icons.sync, size: 18),
              onPressed: _busy || !gate.online ? null : _syncNow,
            ),
            if ((status?.blocked ?? 0) > 0)
              AppButton(
                label: AppText.t('إعادة المحاولة', 'Retry'),
                small: true,
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _busy || !gate.online ? null : _retryAll,
              ),
            if ((status?.conflicts ?? 0) > 0)
              AppButton(
                label: AppText.t('تجاهل الكل', 'Dismiss all'),
                small: true,
                icon: const Icon(Icons.clear_all, size: 18),
                onPressed: _busy ? null : _dismissAll,
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
            AppButton(
              label: AppText.t('رفع المتأخر', 'Upload backlog'),
              small: true,
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              onPressed: _busy || !gate.online ? null : _backfill,
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
            final tileWidth =
                stacked ? width : (width - AppSpacing.sm * 3) / 4;
            return Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _Tile(
                  label: AppText.t('الحالة', 'Status'),
                  value: status?.badge ?? '—',
                  color: _badgeColor(status),
                  width: tileWidth,
                ),
                _Tile(
                  label: AppText.t('في الانتظار', 'Pending'),
                  value: '${status?.pending ?? 0}',
                  width: tileWidth,
                ),
                _Tile(
                  label: AppText.t('محجوب', 'Blocked'),
                  value: '${status?.blocked ?? 0}',
                  color: (status?.blocked ?? 0) > 0 ? AppColors.danger : null,
                  width: tileWidth,
                ),
                _Tile(
                  label: AppText.t('تعارضات', 'Conflicts'),
                  value: '${status?.conflicts ?? 0}',
                  color: (status?.conflicts ?? 0) > 0 ? AppColors.warning : null,
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
            '${status!.lastError}',
            style: TextStyle(color: AppColors.danger, fontSize: 12.spMax),
          ),
        ],
        if (status?.degraded == true) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            AppText.t(
              'Firebase غير مهيأ — التطبيق يعمل محلياً فقط.',
              'Firebase is not configured — the app works locally only.',
            ),
            style: TextStyle(color: AppColors.warning, fontSize: 12.spMax),
          ),
        ],
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
          Text(AppText.t(
              'لا توجد تعارضات — كل البيانات متزامنة.', 'No conflicts — all data is synced.'))
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
                        AppButton(
                          label: AppText.t('إبقاء المحلي', 'Keep local'),
                          small: true,
                          style: AppButtonStyle.ghost,
                          onPressed: () => _keepLocal(row),
                        ),
                        AppButton(
                          label: AppText.t('إبقاء الخادم', 'Keep server'),
                          small: true,
                          style: AppButtonStyle.ghost,
                          onPressed: () => _keepRemote(row),
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
      AppText.t('حل التعارض يحتاج جلسة صالحة واتصال بالإنترنت',
          'Resolving a conflict needs a valid session and an internet connection'),
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
      await _refresh();
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
      await _refresh();
    });
  }

  static String _time(DateTime? value) => value == null
      ? '—'
      : '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  static Color? _badgeColor(SyncStatusSnapshot? status) {
    if (status == null) return null;
    if (!status.online) return AppColors.textMuted;
    if (status.syncing) return AppColors.primary;
    if (status.blocked > 0) return AppColors.danger;
    return AppColors.success;
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
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.spMax,
              ),
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
      if (error != null && '$error'.isNotEmpty) '$error',
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
