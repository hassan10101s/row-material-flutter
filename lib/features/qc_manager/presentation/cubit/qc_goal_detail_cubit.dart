import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/state/app_cubit.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../core/utils/app_format.dart';
import '../../domain/qc_audit.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_goal.dart';
import '../../domain/qc_repositories.dart';

/// Which tab of the goal detail screen is showing.
enum QcGoalTab { overview, assignments, actions, kpis, links, history }

@immutable
class QcGoalDetailState extends Equatable {
  const QcGoalDetailState({
    this.goalId = 0,
    this.bundle,
    this.history = const [],
    this.tab = QcGoalTab.overview,
    this.loading = false,
    this.saving = false,
    this.error,
    this.historyError,
    this.notice,
  });

  final int goalId;

  /// The goal plus its assignments, actions, KPIs and links.
  ///
  /// Null until the first load resolves, and stays null if the goal has been
  /// soft-deleted out from under the open screen.
  final QcGoalBundle? bundle;

  /// The goal's slice of `qc_audits`, for the History tab.
  final List<QcAudit> history;
  final QcGoalTab tab;
  final bool loading;
  final bool saving;
  final String? error;
  final String? historyError;

  /// One-shot confirmation ("Marked done by Hassan") for the snackbar.
  final String? notice;

  QcGoal? get goal => bundle?.goal;

  List<QcGoalAssignment> get assignments => bundle?.assignments ?? const [];

  List<QcGoalAction> get actions => bundle?.actions ?? const [];

  List<QcGoalKpi> get kpis => bundle?.kpis ?? const [];

  List<QcGoalLink> get links => bundle?.links ?? const [];

  QcGoalDetailState copyWith({
    int? goalId,
    Object? bundle = _unset,
    List<QcAudit>? history,
    QcGoalTab? tab,
    bool? loading,
    bool? saving,
    Object? error = _unset,
    Object? historyError = _unset,
    Object? notice = _unset,
  }) => QcGoalDetailState(
    goalId: goalId ?? this.goalId,
    bundle: identical(bundle, _unset) ? this.bundle : bundle as QcGoalBundle?,
    history: history ?? this.history,
    tab: tab ?? this.tab,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
    historyError: identical(historyError, _unset)
        ? this.historyError
        : historyError as String?,
    notice: identical(notice, _unset) ? this.notice : notice as String?,
  );

  @override
  List<Object?> get props => [
    goalId,
    bundle,
    history,
    tab,
    loading,
    saving,
    error,
    historyError,
    notice,
  ];
}

const _unset = Object();

/// Drives one goal: its people, steps, measurements, links, and audit trail.
///
/// Every mutation goes through the repository and is followed by a reload, so
/// what the tabs show is always what was persisted rather than an optimistic
/// guess that a permission check or a trigger could still refuse.
class QcGoalDetailCubit extends AppCubit<QcGoalDetailState> {
  QcGoalDetailCubit({
    required this.repo,
    required this.audit,
    required int goalId,
  }) : super(QcGoalDetailState(goalId: goalId, loading: true));

  final QcGoalRepository repo;
  final QcAuditRepository audit;

  /// Guards against a load that resolves after a later one.
  int _token = 0;

  Future<void> load({int? goalId}) async {
    final targetGoalId = goalId ?? state.goalId;
    final token = ++_token;
    safeEmit(
      state.copyWith(
        goalId: targetGoalId,
        loading: true,
        error: null,
        historyError: null,
      ),
    );
    try {
      final bundle = await repo.getGoalBundle(targetGoalId);
      if (token != _token) return;
      // The trail is a second query; a goal with no history is normal, and an
      // unreadable trail must not blank the goal itself.
      List<QcAudit> history = const [];
      String? historyError;
      try {
        history = await audit.list(
          entityType: QcAuditEntity.goal,
          entityId: '$targetGoalId',
          limit: 200,
        );
      } catch (e) {
        historyError = '$e';
        history = const [];
      }
      if (token != _token) return;
      if (bundle == null) {
        safeEmit(
          state.copyWith(
            loading: false,
            bundle: null,
            error: AppText.t('الهدف غير موجود', 'This goal no longer exists'),
          ),
        );
        return;
      }
      safeEmit(
        state.copyWith(
          loading: false,
          bundle: bundle,
          history: history,
          historyError: historyError,
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

  Future<void> reloadHistory() async {
    final goal = state.goal;
    if (goal == null) return;
    safeEmit(state.copyWith(historyError: null));
    try {
      final history = await audit.list(
        entityType: QcAuditEntity.goal,
        entityId: '${goal.goalId}',
        limit: 200,
      );
      safeEmit(state.copyWith(history: history, historyError: null));
    } catch (e) {
      safeEmit(state.copyWith(historyError: '$e'));
    }
  }

  void selectTab(QcGoalTab tab) => safeEmit(state.copyWith(tab: tab));

  /// Closes the goal, recording who finished it and when.
  ///
  /// The finisher is stamped here rather than asked of the caller: a
  /// completion dialog that lets you type someone else's name is how a goal
  /// ends up closed with no accountable person.
  Future<void> completeGoal({
    required String completedBy,
    required String completedByName,
    String notes = '',
    List<String> evidence = const [],
  }) async {
    final goal = state.goal;
    if (goal == null) return;
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      final candidate = goal.copyWith(
        status: QcGoalStatus.completed,
        completedBy: completedBy,
        completedByName: completedByName,
        completedAt: nowIso(),
        completionNotes: notes,
        completionEvidenceJson: jsonDumps(evidence),
      );
      final blocker = candidate.completionBlocker;
      if (blocker.isNotEmpty) {
        safeEmit(state.copyWith(saving: false, error: blocker));
        return;
      }
      await repo.saveGoal(candidate);
      safeEmit(
        state.copyWith(
          saving: false,
          notice: AppText.t(
            'تم الإكمال بواسطة $completedByName',
            'Completed by $completedByName',
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

  Future<void> setStatus(String status) async {
    final goal = state.goal;
    if (goal == null) return;
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.saveGoal(goal.copyWith(status: status));
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> assign({
    required String assigneeId,
    required String assigneeName,
    String role = QcGoalRole.member,
    String dueDate = '',
    required String assignedBy,
    required String assignedByName,
  }) async {
    final now = nowIso();
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.assignGoal(
        QcGoalAssignment(
          goalId: state.goalId,
          assigneeId: assigneeId,
          assigneeName: assigneeName,
          role: role,
          assignedAt: now,
          assignedBy: assignedBy,
          assignedByName: assignedByName,
          dueDate: dueDate,
          createdAt: now,
          updatedAt: now,
        ),
      );
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Marks one person's share done. Same finisher rule as the goal.
  Future<void> completeAssignment(
    int assignId,
    String who,
    String whoName,
  ) async {
    final target = state.assignments
        .where((a) => a.assignId == assignId)
        .firstOrNull;
    if (target == null) return;
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.updateAssignment(
        target.copyWith(
          status: QcGoalAssignmentStatus.completed,
          completedBy: who,
          completedByName: whoName,
          completedAt: nowIso(),
        ),
      );
      safeEmit(
        state.copyWith(
          saving: false,
          notice: AppText.t('تم إنجاز $whoName', 'Marked done for $whoName'),
        ),
      );
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> removeAssignment(int assignId) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.removeAssignment(assignId);
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> addAction({
    required String actionText,
    String status = QcGoalActionStatus.todo,
    String priority = QcPriority.medium,
    String dueDate = '',
    int? assignId,
  }) async {
    final now = nowIso();
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.addAction(
        QcGoalAction(
          goalId: state.goalId,
          assignId: assignId,
          actionText: actionText,
          status: status,
          priority: priority,
          dueDate: dueDate,
          createdAt: now,
          updatedAt: now,
        ),
      );
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  /// Closes an action, stamping the finisher.
  Future<void> completeAction(int actionId, String who, String whoName) async {
    final target = state.actions
        .where((a) => a.actionId == actionId)
        .firstOrNull;
    if (target == null) return;
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.saveAction(
        target.copyWith(
          status: QcGoalActionStatus.done,
          doneBy: who,
          doneByName: whoName,
          doneAt: nowIso(),
        ),
      );
      safeEmit(
        state.copyWith(
          saving: false,
          notice: AppText.t('تم الإنجاز', 'Step marked done'),
        ),
      );
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> saveKpi({
    required String name,
    required double target,
    double? actual,
    String unit = '',
    String measureDate = '',
    String measuredBy = '',
    String measuredByName = '',
    String notes = '',
    bool higherIsBetter = true,
  }) async {
    final now = nowIso();
    final existing = state.kpis.where((k) => k.name == name).firstOrNull;
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      final kpi = QcGoalKpi(
        kpiId: existing?.kpiId,
        goalId: state.goalId,
        name: name,
        target: target,
        actual: actual,
        unit: unit,
        measureDate: measureDate,
        measuredBy: measuredBy,
        measuredByName: measuredByName,
        notes: notes,
        higherIsBetter: higherIsBetter,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );
      if (existing == null) {
        await repo.addKpi(kpi);
      } else {
        await repo.saveKpi(kpi);
      }
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> deleteKpi(int kpiId) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.deleteKpi(kpiId);
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> link({
    required String linkType,
    required String refId,
    String notes = '',
  }) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.addLink(
        QcGoalLink(
          goalId: state.goalId,
          linkType: linkType,
          refId: refId,
          notes: notes,
          createdAt: nowIso(),
        ),
      );
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> unlink(int linkId) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.deleteLink(linkId);
      safeEmit(state.copyWith(saving: false));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearNotice() => safeEmit(state.copyWith(notice: null));
}
