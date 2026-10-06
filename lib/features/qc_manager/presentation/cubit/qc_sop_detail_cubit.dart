import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_sop.dart';
import '../../domain/qc_repositories.dart';
import 'qc_sops_cubit.dart';

@immutable
class QcSopDetailState extends Equatable {
  const QcSopDetailState({
    this.sopId = 0,
    this.sop,
    this.revisions = const [],
    this.reads = const [],
    this.loading = false,
    this.saving = false,
    this.error,
    this.notice,
  });

  final int sopId;
  final QcSop? sop;

  /// Newest first, as the repository returns them.
  final List<QcSopRevision> revisions;

  /// Acknowledgements recorded against the current revision.
  final List<QcSopRead> reads;
  final bool loading;
  final bool saving;
  final String? error;
  final String? notice;

  QcSopRevision? get latestRevision =>
      revisions.isEmpty ? null : revisions.first;

  /// The transitions the reader is allowed to start, from the domain's own
  /// table. Offering anything else would be offering a request the guard will
  /// refuse.
  List<String> get nextStatuses =>
      SopStatus.transitions[sop?.status ?? ''] ?? const [];

  /// Whether this user still owes an acknowledgement on the current revision.
  ///
  /// A read is recorded per revision, so re-acknowledging revision 3 says
  /// nothing about revision 4 - which is the whole reason reads carry `rev_no`.
  bool owesAck(String userId) {
    final revNo = latestRevision?.revNo ?? sop?.revNo ?? 0;
    return !reads.any((r) => r.userId == userId && r.revNo == revNo);
  }

  QcSopDetailState copyWith({
    int? sopId,
    Object? sop = _unset,
    List<QcSopRevision>? revisions,
    List<QcSopRead>? reads,
    bool? loading,
    bool? saving,
    Object? error = _unset,
    Object? notice = _unset,
  }) => QcSopDetailState(
    sopId: sopId ?? this.sopId,
    sop: identical(sop, _unset) ? this.sop : sop as QcSop?,
    revisions: revisions ?? this.revisions,
    reads: reads ?? this.reads,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
    notice: identical(notice, _unset) ? this.notice : notice as String?,
  );

  @override
  List<Object?> get props => [
    sopId,
    sop,
    revisions,
    reads,
    loading,
    saving,
    error,
    notice,
  ];
}

const _unset = Object();

/// One SOP: its body, its revision history, and who has acknowledged it.
///
/// A published SOP is never edited in place. `publishSopRevision` is the only
/// way its text changes, which is why [publishRevision] here asks for a change
/// summary before it will call anything.
class QcSopDetailCubit extends AppCubit<QcSopDetailState> {
  QcSopDetailCubit({required this.repo, required this.sops, required int sopId})
    : super(QcSopDetailState(sopId: sopId, loading: true));

  final QcSopRepository repo;

  /// The register's cubit, reused so a publish here shows up in the list behind
  /// it instead of needing the screen to remember to refresh.
  final QcSopsCubit sops;

  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final sop = await repo.getSop(state.sopId);
      if (token != _token) return;
      if (sop == null) {
        safeEmit(
          state.copyWith(
            loading: false,
            sop: null,
            error: AppText.t(
              'هذا الإجراء غير موجود',
              'This SOP no longer exists',
            ),
          ),
        );
        return;
      }
      final revisions = await repo.listSopRevisions(state.sopId);
      final reads = await _readsForCurrentRevision(sop);
      if (token != _token) return;
      safeEmit(
        state.copyWith(
          loading: false,
          sop: sop,
          revisions: revisions,
          reads: reads,
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

  /// Acknowledgements for the whole SOP, from the read side of the contract.
  ///
  /// Swallowed if it fails: a compliance screen that cannot list its readers
  /// should still show the procedure, and the next load will try again.
  Future<List<QcSopRead>> _readsForCurrentRevision(QcSop sop) async {
    try {
      final entries = await repo.listSopReads(sop.sopId ?? 0);
      return entries;
    } catch (_) {
      return const [];
    }
  }

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearNotice() => safeEmit(state.copyWith(notice: null));

  /// Moves the SOP along its lifecycle.
  Future<void> advance(String toStatus, {String reason = ''}) async {
    final sop = state.sop;
    if (sop == null) return;
    if (!SopStatus.canTransition(sop.status, toStatus)) {
      safeEmit(
        state.copyWith(
          error: AppText.t(
            'لا يمكن نقل الإجراء من ${sop.status} إلى $toStatus',
            'Cannot move an SOP from ${sop.status} to $toStatus',
          ),
        ),
      );
      return;
    }
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.updateSop(
        sop.copyWith(
          status: toStatus,
          rejectionReason: toStatus == SopStatus.draft
              ? reason
              : sop.rejectionReason,
          reviewedAt:
              (toStatus == SopStatus.approved || toStatus == SopStatus.draft)
              ? nowIso()
              : sop.reviewedAt,
          publishedAt: toStatus == SopStatus.published
              ? nowIso()
              : sop.publishedAt,
          updatedAt: nowIso(),
        ),
      );
      safeEmit(state.copyWith(saving: false));
      await load();
      await sops.refresh();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> save(QcSop sop) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.updateSop(sop.copyWith(updatedAt: nowIso()));
      safeEmit(state.copyWith(saving: false));
      await load();
      await sops.refresh();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Cuts the next revision. The summary is mandatory: an unexplained revision
  /// cannot be audited later.
  Future<void> publishRevision({
    required String changeSummary,
    String effectiveFrom = '',
  }) async {
    final sop = state.sop;
    if (sop == null) return;
    if (changeSummary.trim().isEmpty) {
      safeEmit(
        state.copyWith(
          error: AppText.t('سبب التغيير مطلوب', 'A change summary is required'),
        ),
      );
      return;
    }
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.publishSopRevision(
        sop.sopId ?? 0,
        changeSummary: changeSummary.trim(),
        effectiveFrom: effectiveFrom,
      );
      safeEmit(
        state.copyWith(
          saving: false,
          notice: AppText.t(
            'تم نشر مراجعة جديدة',
            'A new revision was published',
          ),
        ),
      );
      await load();
      await sops.refresh();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Records that this reader has read the current revision.
  ///
  /// The revision number is read off the latest revision rather than typed in,
  /// so an acknowledgement cannot be filed against the wrong one.
  Future<void> acknowledge({
    required String userId,
    String userName = '',
    String ackMethod = SopAckMethod.manual,
    String signatureBase64 = '',
  }) async {
    final sop = state.sop;
    if (sop == null) return;
    if (userId.trim().isEmpty) {
      safeEmit(
        state.copyWith(
          error: AppText.t('المستخدم مطلوب', 'A user is required'),
        ),
      );
      return;
    }
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.recordSopRead(
        QcSopRead(
          sopId: sop.sopId ?? 0,
          revNo: state.latestRevision?.revNo ?? sop.revNo,
          userId: userId.trim(),
          userName: userName.trim(),
          readAt: nowIso(),
          ackMethod: ackMethod,
          signatureBase64: signatureBase64,
        ),
      );
      safeEmit(
        state.copyWith(
          saving: false,
          notice: AppText.t(
            'تم تسجيل القراءة',
            'Read acknowledgement recorded',
          ),
        ),
      );
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }
}
