import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_sop.dart';
import '../../domain/qc_repositories.dart';

/// How the SOP register is narrowed.
class QcSopFilters extends Equatable {
  const QcSopFilters({
    this.statuses = const {},
    this.dept = '',
    this.category = '',
    this.text = '',
    this.includeArchived = false,
  });

  final Set<String> statuses;
  final String dept;
  final String category;

  /// Free-text over code and title. The repository has no such column, so it is
  /// applied in memory after the query - fine for a register this size, and
  /// honest about it rather than pretending the database filtered it.
  final String text;

  /// Archived and obsolete SOPs stay out of the way unless asked for.
  final bool includeArchived;

  bool get isEmpty =>
      statuses.isEmpty &&
      dept.isEmpty &&
      category.isEmpty &&
      text.isEmpty &&
      !includeArchived;

  QcSopFilters copyWith({
    Set<String>? statuses,
    String? dept,
    String? category,
    String? text,
    bool? includeArchived,
  }) => QcSopFilters(
    statuses: statuses ?? this.statuses,
    dept: dept ?? this.dept,
    category: category ?? this.category,
    text: text ?? this.text,
    includeArchived: includeArchived ?? this.includeArchived,
  );

  @override
  List<Object?> get props => [
    (statuses.toList()..sort()),
    dept,
    category,
    text,
    includeArchived,
  ];
}

/// Counters for the register's summary strip.
class QcSopSummary extends Equatable {
  const QcSopSummary({
    this.total = 0,
    this.draft = 0,
    this.awaitingApproval = 0,
    this.published = 0,
    this.expiringSoon = 0,
  });

  final int total;
  final int draft;
  final int awaitingApproval;
  final int published;

  /// Published SOPs inside 30 days of their expiry - the ones a maintenance
  /// manager needs to see before they lapse.
  final int expiringSoon;

  factory QcSopSummary.from(List<QcSop> sops) {
    final soon = DateTime.now().add(const Duration(days: 30));
    return QcSopSummary(
      total: sops.length,
      draft: sops.where((s) => s.status == SopStatus.draft).length,
      awaitingApproval: sops.where((s) => s.status == SopStatus.pending).length,
      published: sops.where((s) => s.isPublished).length,
      expiringSoon: sops
          .where((s) => s.isPublished && s.expiryDate.isNotEmpty)
          .where(
            (s) => DateTime.tryParse(s.expiryDate)?.isBefore(soon) ?? false,
          )
          .length,
    );
  }

  @override
  List<Object?> get props => [
    total,
    draft,
    awaitingApproval,
    published,
    expiringSoon,
  ];
}

@immutable
class QcSopsState extends Equatable {
  const QcSopsState({
    this.sops = const [],
    this.filters = const QcSopFilters(),
    this.summary = const QcSopSummary(),
    this.loading = false,
    this.saving = false,
    this.error,
  });

  final List<QcSop> sops;
  final QcSopFilters filters;
  final QcSopSummary summary;
  final bool loading;
  final bool saving;
  final String? error;

  QcSopsState copyWith({
    List<QcSop>? sops,
    QcSopFilters? filters,
    QcSopSummary? summary,
    bool? loading,
    bool? saving,
    Object? error = _unset,
  }) => QcSopsState(
    sops: sops ?? this.sops,
    filters: filters ?? this.filters,
    summary: summary ?? this.summary,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
  );

  @override
  List<Object?> get props => [sops, filters, summary, loading, saving, error];
}

const _unset = Object();

/// The SOP register.
///
/// Writes go through the guarded facade, which is where the lifecycle rules
/// actually live: this cubit never decides that a draft may be published, it
/// asks the repository and reports what came back. The one rule it does own is
/// showing the reader which transitions are even offered, from
/// [SopStatus.transitions] - a single source of truth for the buttons.
class QcSopsCubit extends AppCubit<QcSopsState> {
  QcSopsCubit({required this.repo, QcSopFilters? initialFilters})
    : super(
        QcSopsState(
          filters: initialFilters ?? const QcSopFilters(),
          loading: true,
        ),
      );

  final QcSopRepository repo;
  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final sops = await _query(state.filters);
      if (token != _token) return;
      safeEmit(
        state.copyWith(
          sops: sops,
          summary: QcSopSummary.from(sops),
          loading: false,
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

  Future<void> refresh() => load();

  Future<void> applyFilters(QcSopFilters filters) async {
    safeEmit(state.copyWith(filters: filters, sops: const []));
    await load();
  }

  Future<void> toggleStatus(String status) async {
    final next = {...state.filters.statuses};
    if (!next.remove(status)) next.add(status);
    await applyFilters(state.filters.copyWith(statuses: next));
  }

  Future<void> clearFilters() => applyFilters(const QcSopFilters());

  void clearError() => safeEmit(state.copyWith(error: null));

  Future<void> createSop(QcSop sop) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.createSop(sop);
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Sends a SOP along its lifecycle.
  ///
  /// The move is checked against [SopStatus.transitions] here *and* by the
  /// repository guard. That is not belt-and-braces duplication: the guard is the
  /// authority, but a caller that gets a refusal from it has already paid for a
  /// round trip and a write attempt, while the reader gets no explanation of
  /// which rule stopped them.
  Future<QcSop?> advance(
    QcSop sop,
    String toStatus, {
    String reason = '',
  }) async {
    final id = sop.sopId;
    if (id == null) return null;
    if (!SopStatus.canTransition(sop.status, toStatus)) {
      safeEmit(
        state.copyWith(
          error: AppText.t(
            'لا يمكن نقل الإجراء من ${sop.status} إلى $toStatus',
            'Cannot move an SOP from ${sop.status} to $toStatus',
          ),
        ),
      );
      return null;
    }
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      final next = sop.copyWith(
        status: toStatus,
        rejectionReason: toStatus == SopStatus.draft
            ? reason
            : sop.rejectionReason,
        reviewedAt:
            toStatus == SopStatus.approved || toStatus == SopStatus.draft
            ? nowIso()
            : sop.reviewedAt,
        publishedAt: toStatus == SopStatus.published
            ? nowIso()
            : sop.publishedAt,
        updatedAt: nowIso(),
      );
      await repo.updateSop(next);
      safeEmit(state.copyWith(saving: false));
      await load();
      return next;
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
    return null;
  }

  Future<void> deleteSop(int sopId) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.deleteSop(sopId);
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Publishes the SOP's current body as the next revision and supersedes the
  /// previous one, which is the only way a published SOP ever changes.
  Future<void> publishRevision(
    QcSop sop, {
    required String changeSummary,
    String effectiveFrom = '',
  }) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.publishSopRevision(
        sop.sopId ?? 0,
        changeSummary: changeSummary,
        effectiveFrom: effectiveFrom,
      );
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<List<QcSop>> _query(QcSopFilters filters) async {
    final includeArchived =
        filters.includeArchived ||
        (filters.statuses.any((s) => s == SopStatus.archived));
    var rows = await repo.listSops(
      dept: filters.dept,
      includeArchived: includeArchived,
    );

    // The repository takes no status, so a multi-select fans out here and the
    // results are merged; an empty selection means "every status".
    if (filters.statuses.isNotEmpty) {
      rows = rows.where((s) => filters.statuses.contains(s.status)).toList();
    } else if (!filters.includeArchived) {
      rows = rows.where((s) => s.status != SopStatus.archived).toList();
    }
    if (filters.category.isNotEmpty) {
      rows = rows.where((s) => s.category == filters.category).toList();
    }
    final needle = filters.text.trim().toLowerCase();
    if (needle.isNotEmpty) {
      rows = rows
          .where(
            (s) =>
                s.code.toLowerCase().contains(needle) ||
                s.title.toLowerCase().contains(needle),
          )
          .toList();
    }
    return rows;
  }
}
