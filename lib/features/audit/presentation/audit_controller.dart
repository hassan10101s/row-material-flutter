import 'package:flutter/foundation.dart';

import '../../../core/sync/audit_trail.dart';
/// Read-only state of the audit screen (plan §14-P9.2).
class AuditFilter {
  const AuditFilter({this.entityType, this.action, this.from, this.to});

  final String? entityType;
  final String? action;
  final DateTime? from;
  final DateTime? to;

  bool get isEmpty => entityType == null && action == null && from == null && to == null;

  AuditFilter copyWith({
    String? entityType,
    String? action,
    DateTime? from,
    DateTime? to,
    bool clearEntityType = false,
    bool clearAction = false,
    bool clearFrom = false,
    bool clearTo = false,
  }) =>
      AuditFilter(
        entityType: clearEntityType ? null : (entityType ?? this.entityType),
        action: clearAction ? null : (action ?? this.action),
        from: clearFrom ? null : (from ?? this.from),
        to: clearTo ? null : (to ?? this.to),
      );

  @override
  bool operator ==(Object other) =>
      other is AuditFilter &&
      other.entityType == entityType &&
      other.action == action &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(entityType, action, from, to);
}

/// Paged, filtered reader of the local audit trail.
///
/// The trail is local data (it is pulled from `auditLogs`), so the screen asks
/// the same `AuditTrail` the sync cycle prunes through: one code path for the
/// permission, the filters and the retention.
class AuditController extends ChangeNotifier {
  AuditController(this.trail, {this.pageSize = 50});

  final AuditTrailReader trail;
  final int pageSize;

  AuditFilter _filter = const AuditFilter();
  AuditPage _page = AuditPage.empty;
  int _offset = 0;
  bool _loading = false;
  String? _error;

  AuditFilter get filter => _filter;
  AuditPage get page => _page;
  int get offset => _offset;
  bool get loading => _loading;
  String? get error => _error;

  /// `audit.read` — a device without it must not see the trail at all.
  bool get canRead => trail.canRead;

  bool get hasPrevious => _offset > 0;
  bool get hasNext => _page.hasMore;

  /// 1-based page number, for the "page 2 of 7" line.
  int get pageNumber => (_offset ~/ pageSize) + 1;
  int get pageCount => _page.total == 0 ? 1 : (_page.total / pageSize).ceil();

  Future<void> load() async {
    if (!canRead) {
      _page = AuditPage.empty;
      _loading = false;
      notifyListeners();
      return;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _page = await trail.page(
        entityType: _filter.entityType,
        action: _filter.action,
        from: _filter.from,
        to: _filter.to,
        limit: pageSize,
        offset: _offset,
      );
    } on Object catch (e) {
      _error = '$e';
      _page = AuditPage.empty;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Any filter change goes back to the first page - staying on page 4 of a
  /// list that now has one page would show an empty screen.
  Future<void> applyFilter(AuditFilter filter) async {
    _filter = filter;
    _offset = 0;
    await load();
  }

  Future<void> clearFilters() => applyFilter(const AuditFilter());

  Future<void> nextPage() async {
    if (!hasNext) return;
    _offset += pageSize;
    await load();
  }

  Future<void> previousPage() async {
    if (!hasPrevious) return;
    _offset = (_offset - pageSize).clamp(0, 1 << 31);
    await load();
  }
}
