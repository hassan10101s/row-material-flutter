import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../app/auth_gate.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/sync/conflict_resolver.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../di/service_locator.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/tokens/app_breakpoints.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../core/constants/app_strings.dart';

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
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('المزامنة', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (gate.session.offline)
                  const Text('جلسة محلية (بدون توكن حي)'),
                AppButton(
                  label: 'مزامنة الآن',
                  small: true,
                  loading: _busy,
                  icon: const Icon(Icons.sync, size: 18),
                  onPressed: _busy || !gate.online ? null : _syncNow,
                ),
                if ((status?.blocked ?? 0) > 0)
                  AppButton(
                    label: 'إعادة المحاولة',
                    small: true,
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _busy || !gate.online ? null : _retryAll,
                  ),
                AppButton(
                  label: 'تنزيل السجل',
                  small: true,
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  onPressed: _busy || !gate.online ? null : _downloadHistory,
                ),
              ],
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
                  label: 'الحالة',
                  value: status?.badge ?? '—',
                  color: _badgeColor(status),
                  width: tileWidth,
                ),
                _Tile(
                  label: 'في الانتظار',
                  value: '${status?.pending ?? 0}',
                  width: tileWidth,
                ),
                _Tile(
                  label: 'محجوب',
                  value: '${status?.blocked ?? 0}',
                  color: (status?.blocked ?? 0) > 0 ? AppColors.danger : null,
                  width: tileWidth,
                ),
                _Tile(
                  label: 'تعارضات',
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
          'آخر رفع: ${_time(status?.lastPushAt)}\n'
          'آخر تنزيل: ${_time(status?.lastPullAt)}',
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
            'Firebase غير مهيأ — التطبيق يعمل محلياً فقط.',
            style: TextStyle(color: AppColors.warning, fontSize: 12.spMax),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text(
          'الطابور',
          style: TextStyle(fontSize: 15.spMax, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_queueRows.isEmpty)
          const Text('لا توجد عناصر في الطابور.')
        else
          Card(
            child: Column(
              children: [
                for (final row in _queueRows)
                  _QueueRow(
                    row: row,
                    onRetry: _busy || !gate.online
                        ? null
                        : () => _retryOne(row),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'التعارضات',
          style: TextStyle(fontSize: 15.spMax, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_rows.isEmpty)
          const Text('لا توجد تعارضات — كل البيانات متزامنة.')
        else
          Card(
            child: Column(
              children: [
                for (final row in _rows)
                  _ConflictRow(
                    row: row,
                    onKeepLocal: () => _keepLocal(row),
                    onKeepRemote: () => _keepRemote(row),
                  ),
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
      child: Card(
        margin: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
        child: Padding(
          padding: const EdgeInsets.all(12),
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
              const SizedBox(height: 4),
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
      ),
    );
  }
}

/// One `sync_queue` row: what it is, how many attempts it took and - when it is
/// blocked - a per-row retry that clears the backoff.
class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.row, this.onRetry});

  final Map<String, Object?> row;
  final VoidCallback? onRetry;

  static const Map<String, String> _statusAr = {
    'pending': 'في الانتظار',
    'in_flight': 'جارٍ الإرسال',
    'failed': 'فشل',
    'conflict': 'تعارض',
    'blocked': 'محجوب',
  };

  @override
  Widget build(BuildContext context) {
    final status = '${row['status'] ?? ''}';
    final retryCount = (row['retry_count'] as num?)?.toInt() ?? 0;
    final error = row['last_error'];
    return ListTile(
      dense: true,
      title: Text('${row['entity_type']} · ${row['entity_id']}'),
      subtitle: Text(
        [
          _statusAr[status] ?? status,
          '${row['operation']}',
          if (retryCount > 0) 'محاولات: $retryCount',
          if (error != null && '$error'.isNotEmpty) '$error',
        ].join(' · '),
      ),
      trailing: status == 'failed' || status == 'conflict'
          ? TextButton(onPressed: onRetry, child: const Text('إعادة'))
          : null,
    );
  }
}

class _ConflictRow extends StatelessWidget {
  const _ConflictRow({
    required this.row,
    required this.onKeepLocal,
    required this.onKeepRemote,
  });

  final Map<String, Object?> row;
  final VoidCallback onKeepLocal;
  final VoidCallback onKeepRemote;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text('${row['entity_type']} · ${row['entity_id']}'),
      subtitle: Text('${row['direction']} · ${row['detected_at']}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: onKeepLocal, child: const Text('إبقاء المحلي')),
          TextButton(
            onPressed: onKeepRemote,
            child: const Text('إبقاء الخادم'),
          ),
        ],
      ),
    );
  }
}
