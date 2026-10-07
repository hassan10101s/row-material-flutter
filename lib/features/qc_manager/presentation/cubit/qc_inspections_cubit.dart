import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_inspection.dart';
import '../../domain/qc_repositories.dart';
import '../../domain/qc_template.dart';

/// How many sheets one page asks for. Paged rather than "load everything"
/// because a plant accumulates inspections far faster than it reads them, and
/// `qc_inspections` is ordered by `inspection_date DESC, inspection_id DESC`
/// with the date index, so a page is a bounded index scan.
const qcInspectionsPageSize = 50;

/// The filter scope behind the inspections register.
///
/// Kept as one value object (rather than loose fields on the state) so the
/// dashboard link and the filter sheet describe a query identically.
class QcInspectionFilters extends Equatable {
  const QcInspectionFilters({
    this.statuses = const {},
    this.refType = '',
    this.lotNo = '',
    this.dept = '',
  });

  /// The repository takes one `status`, so a multi-select costs one query per
  /// status - see [QcInspectionsCubit._query]. Two or three statuses is the
  /// usual ask, which is far cheaper than widening the contract.
  final Set<String> statuses;
  final String refType;
  final String lotNo;
  final String dept;

  bool get isEmpty =>
      statuses.isEmpty && refType.isEmpty && lotNo.isEmpty && dept.isEmpty;

  int get activeCount =>
      (statuses.isEmpty ? 0 : 1) +
      (refType.isEmpty ? 0 : 1) +
      (lotNo.isEmpty ? 0 : 1) +
      (dept.isEmpty ? 0 : 1);

  QcInspectionFilters copyWith({
    Set<String>? statuses,
    String? refType,
    String? lotNo,
    String? dept,
  }) => QcInspectionFilters(
    statuses: statuses ?? this.statuses,
    refType: refType ?? this.refType,
    lotNo: lotNo ?? this.lotNo,
    dept: dept ?? this.dept,
  );

  @override
  List<Object?> get props => [
    // Sorted so two filters holding the same statuses compare equal.
    (statuses.toList()..sort()),
    refType,
    lotNo,
    dept,
  ];
}

/// Counters for the register's summary strip.
///
/// Derived from the rows already loaded rather than from extra aggregate
/// queries, the same trade the goals register makes: a counter that disagreed
/// with the rows underneath it would be worse than no counter.
class QcInspectionSummary extends Equatable {
  const QcInspectionSummary({
    this.total = 0,
    this.inProgress = 0,
    this.awaitingReview = 0,
    this.withNc = 0,
  });

  final int total;
  final int inProgress;

  /// Submitted but not yet approved or rejected: the queue a reviewer works.
  final int awaitingReview;
  final int withNc;

  factory QcInspectionSummary.from(List<QcInspection> rows) =>
      QcInspectionSummary(
        total: rows.length,
        inProgress: rows
            .where((i) => i.status == QcInspectionStatus.inProgress)
            .length,
        awaitingReview: rows.where((i) => i.isSubmitted).length,
        withNc: rows.where((i) => i.hasOpenNc).length,
      );

  @override
  List<Object?> get props => [total, inProgress, awaitingReview, withNc];
}

@immutable
class QcInspectionsState extends Equatable {
  const QcInspectionsState({
    this.inspections = const [],
    this.filters = const QcInspectionFilters(),
    this.summary = const QcInspectionSummary(),
    this.startTemplates = const [],
    this.loading = false,
    this.loadingMore = false,
    this.saving = false,
    this.error,
    this.saved = false,
    this.hasMore = false,
    this.startedId,
  });

  final List<QcInspection> inspections;
  final QcInspectionFilters filters;
  final QcInspectionSummary summary;

  /// Issued checklists the "start an inspection" form may choose from.
  ///
  /// Only published, non-archived templates: an inspection is a signed record
  /// of what was checked, so it has to point at a checklist that was actually
  /// in force.
  final List<QcTemplate> startTemplates;
  final bool loading;
  final bool loadingMore;
  final bool saving;
  final String? error;

  /// Set once by a successful create/delete so the caller can pop itself.
  final bool saved;

  /// True while a full page came back, so there is probably another one.
  final bool hasMore;

  /// The id of a sheet that was just created, so the register can route into
  /// it instead of making the inspector hunt for the row they just made.
  final int? startedId;

  QcInspectionsState copyWith({
    List<QcInspection>? inspections,
    QcInspectionFilters? filters,
    QcInspectionSummary? summary,
    List<QcTemplate>? startTemplates,
    bool? loading,
    bool? loadingMore,
    bool? saving,
    Object? error = _unset,
    bool? saved,
    bool? hasMore,
    Object? startedId = _unset,
  }) => QcInspectionsState(
    inspections: inspections ?? this.inspections,
    filters: filters ?? this.filters,
    summary: summary ?? this.summary,
    startTemplates: startTemplates ?? this.startTemplates,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
    saved: saved ?? this.saved,
    hasMore: hasMore ?? this.hasMore,
    startedId: identical(startedId, _unset)
        ? this.startedId
        : startedId as int?,
  );

  @override
  List<Object?> get props => [
    inspections,
    filters,
    summary,
    startTemplates,
    loading,
    loadingMore,
    saving,
    error,
    saved,
    hasMore,
    startedId,
  ];
}

const _unset = Object();

/// Drives the inspections register: filtering, paging, and starting a sheet.
///
/// Read paths here are for everyone holding `qcRead`; the write path
/// ([startInspection]) goes through the repository facade, which refuses
/// without `qcWrite`, so this screen never has to ask the session twice.
class QcInspectionsCubit extends AppCubit<QcInspectionsState> {
  QcInspectionsCubit({
    required this.repo,
    this.templates,
    QcInspectionFilters? initialFilters,
  }) : super(
         QcInspectionsState(
           filters: initialFilters ?? const QcInspectionFilters(),
           loading: true,
         ),
       );

  final QcInspectionRepository repo;

  /// Optional: the register works without it (the tests and the read-only
  /// routes do), and only [loadStartOptions] needs it.
  final QcTemplateRepository? templates;

  /// Bumped on every filter change. A load whose token is stale is dropped
  /// rather than allowed to overwrite the newer scope's rows.
  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    // `saved` is deliberately left alone: a successful create emits it and then
    // reloads, and clearing it here would eat the signal the screen listens for.
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await _query(state.filters);
      if (token != _token) return;
      safeEmit(
        state.copyWith(
          inspections: rows,
          summary: QcInspectionSummary.from(rows),
          loading: false,
          hasMore: rows.length >= qcInspectionsPageSize,
        ),
      );
    } on AppError catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  /// Appends the next page. No-op unless the last load filled a page, so a
  /// screen that reached the end stops asking.
  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    safeEmit(state.copyWith(loadingMore: true, error: null));
    try {
      final more = await _query(
        state.filters,
        offset: state.inspections.length,
        limit: qcInspectionsPageSize,
      );
      final merged = [...state.inspections, ...more];
      safeEmit(
        state.copyWith(
          inspections: merged,
          summary: QcInspectionSummary.from(merged),
          loadingMore: false,
          hasMore: more.length >= qcInspectionsPageSize,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loadingMore: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loadingMore: false, error: '$e'));
    }
  }

  Future<void> refresh() => load();

  /// Loads the issued checklists the start form offers.
  ///
  /// Separate from [load] because it is a different concern (what *may* be
  /// started) and a register with no templates still has rows to show. A
  /// template repository that is absent - or a query that fails - leaves the
  /// list empty and the form says so, rather than blocking the register.
  Future<void> loadStartOptions() async {
    final source = templates;
    if (source == null) return;
    try {
      final rows = await source.listTemplates(publishedOnly: true);
      // Simplified plan §3: start-inspection offers only one-shot quality
      // checklists; periodic task lists live independently (dashboard card).
      final usable =
          rows
              .where(
                (t) =>
                    t.isPublished &&
                    !t.isArchived &&
                    !t.isDeleted &&
                    t.isOneShot,
              )
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      safeEmit(state.copyWith(startTemplates: usable));
    } catch (_) {
      safeEmit(state.copyWith(startTemplates: const []));
    }
  }

  Future<void> applyFilters(QcInspectionFilters filters) async {
    safeEmit(state.copyWith(filters: filters, inspections: const []));
    await load();
  }

  /// Toggles one status in the multi-select and reloads.
  Future<void> toggleStatus(String status) async {
    final next = {...state.filters.statuses};
    if (!next.remove(status)) next.add(status);
    await applyFilters(state.filters.copyWith(statuses: next));
  }

  Future<void> clearFilters() => applyFilters(const QcInspectionFilters());

  /// Creates the sheet and reloads so the new row is in scope.
  ///
  /// The id is emitted *before* the reload, because the reload is awaited and
  /// the screen pushes into the sheet the moment this returns.
  Future<void> startInspection(QcInspection inspection) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      final id = await repo.createInspection(inspection);
      safeEmit(state.copyWith(saving: false, saved: true, startedId: id));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> deleteInspection(int inspectionId) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.deleteInspection(inspectionId);
      safeEmit(state.copyWith(saving: false, saved: true));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearSaved() => safeEmit(state.copyWith(saved: false));

  void clearStarted() => safeEmit(state.copyWith(startedId: null));

  /// Runs the filter scope.
  ///
  /// The one honest compromise is the multi-status filter: the repository takes
  /// a single `status`, so a multi-select costs one query per status and is
  /// merged and re-sorted here.
  Future<List<QcInspection>> _query(
    QcInspectionFilters filters, {
    int offset = 0,
    int limit = qcInspectionsPageSize,
  }) async {
    Future<List<QcInspection>> call(String status) => repo.listInspections(
      status: status,
      refType: filters.refType,
      lotNo: filters.lotNo,
      dept: filters.dept,
      limit: limit,
      offset: offset,
    );

    if (filters.statuses.isEmpty) return call('');
    final statuses = filters.statuses.toList()..sort();
    final batches = await Future.wait(statuses.map(call));
    final merged = <int, QcInspection>{};
    for (final batch in batches) {
      for (final row in batch) {
        merged[row.inspectionId ?? 0] = row;
      }
    }
    final rows = merged.values.toList()
      ..sort((a, b) {
        final byDate = b.inspectionDate.compareTo(a.inspectionDate);
        // Same date: newest id first, matching the repository's own order so a
        // merged page does not reshuffle within a day.
        return byDate != 0
            ? byDate
            : (b.inspectionId ?? 0).compareTo(a.inspectionId ?? 0);
      });
    return rows;
  }
}
