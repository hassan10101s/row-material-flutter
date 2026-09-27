import 'package:flutter/foundation.dart';

import '../auth/app_session.dart';
import '../auth/permissions.dart';
import 'audit_logger.dart';
import 'device_registry.dart';
import 'sync_metadata.dart';

/// One page of the audit screen, plus what the screen needs to render it.
@immutable
class AuditPage {
  const AuditPage({
    required this.entries,
    required this.total,
    required this.offset,
    required this.hasMore,
    this.entityTypes = const [],
    this.actions = const [],
  });

  final List<Map<String, Object?>> entries;

  /// Rows matching the current filters (not just this page).
  final int total;
  final int offset;
  final bool hasMore;

  /// Distinct values present locally, for the filter dropdowns.
  final List<String> entityTypes;
  final List<String> actions;

  static const AuditPage empty = AuditPage(entries: [], total: 0, offset: 0, hasMore: false);
}

/// The read side of the audit trail, as the UI needs it.
///
/// The screen depends on this contract only, so it can be rendered against a
/// stub instead of a live database.
abstract class AuditTrailReader {
  /// `audit.read` (plan §7.2). A device without it must not see the trail: the
  /// rows are synced down from `auditLogs`.
  bool get canRead;

  Future<AuditPage> page({
    String? entityType,
    String? action,
    DateTime? from,
    DateTime? to,
    int limit = 200,
    int offset = 0,
  });
}

/// The read side of the audit trail and its retention policy (plan §14-P9.2 /
/// §14-P9.3).
///
/// * `audit.read` decides whether the trail may be shown at all - the
///   permission is checked locally as well, because the data is local;
/// * retention (90 days / 20 000 rows, plan §9.7) runs from the sync cycle, at
///   most once a day, never before the first successful push - pruning unsynced
///   rows would delete the record of a write that never reached the server.
class AuditTrail implements AuditTrailReader {
  AuditTrail({
    required this.audit,
    required this.metadata,
    required this.devices,
    this.retention = const Duration(days: 90),
    this.maxRows = 20000,
    this.interval = const Duration(hours: 24),
  });

  final AuditLogger audit;
  final SyncMetadata metadata;
  final DeviceRegistry devices;

  final Duration retention;
  final int maxRows;

  /// Housekeeping is cheap but not free: once a day is plenty.
  final Duration interval;

  static const String lastPrunedAtKey = 'audit_last_pruned_at';

  AppSession get _session => devices.source.session;

  @override
  bool get canRead => _session.can(Permission.auditRead);

  @override
  Future<AuditPage> page({
    String? entityType,
    String? action,
    DateTime? from,
    DateTime? to,
    int limit = 200,
    int offset = 0,
  }) async {
    if (!canRead) return AuditPage.empty;
    final entries = await audit.query(
      entityType: entityType,
      action: action,
      from: from,
      to: to,
      limit: limit,
      offset: offset,
    );
    final total = await audit.count(
      entityType: entityType,
      action: action,
      from: from,
      to: to,
    );
    final facets = await audit.facets();
    return AuditPage(
      entries: entries,
      total: total,
      offset: offset,
      hasMore: offset + entries.length < total,
      entityTypes: facets.entityTypes,
      actions: facets.actions,
    );
  }

  /// Retention pass. Returns true when rows were actually pruned.
  ///
  /// [force] runs it regardless of [interval] (the "clean up now" action of the
  /// screen, and the tests).
  Future<bool> runRetention({bool force = false}) async {
    if (!force) {
      final last = DateTime.tryParse(await metadata.get(lastPrunedAtKey));
      if (last != null && DateTime.now().difference(last) < interval) return false;
    }
    await audit.prune(maxRows: maxRows, retention: retention);
    await metadata.set(lastPrunedAtKey, DateTime.now().toIso8601String());
    return true;
  }
}
