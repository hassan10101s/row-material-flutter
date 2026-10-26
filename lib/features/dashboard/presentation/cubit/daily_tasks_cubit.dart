import 'package:equatable/equatable.dart';

import '../../../../core/state/app_cubit.dart';
import '../../../../di/service_locator.dart';
import '../../../qc_manager/domain/qc_repositories.dart';

/// Daily-tasks summary state for the dashboard card: how many published
/// periodic QC lists exist today and how many were inspected (any result).
class DailyTasksState extends Equatable {
  const DailyTasksState({this.total = 0, this.done = 0, this.loading = false});

  final int total;
  final int done;
  final bool loading;

  bool get hasTasks => total > 0;

  DailyTasksState copyWith({int? total, int? done, bool? loading}) =>
      DailyTasksState(
        total: total ?? this.total,
        done: done ?? this.done,
        loading: loading ?? this.loading,
      );

  @override
  List<Object?> get props => [total, done, loading];
}

/// Loads the daily-tasks counts once per mount; presentation no longer
/// reaches into repositories from a widget's initState (Phase 0 cleanup).
class DailyTasksCubit extends AppCubit<DailyTasksState> {
  DailyTasksCubit() : super(const DailyTasksState(loading: true));

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true));
    try {
      final templates = await getIt<QcTemplateRepository>().listTemplates(
        publishedOnly: true,
      );
      final ids = <int>{};
      for (final t in templates) {
        final id = t.templateId;
        if (id != null &&
            t.isPublished &&
            !t.isArchived &&
            !t.isDeleted &&
            t.isPeriodic) {
          ids.add(id);
        }
      }
      var total = 0;
      var done = 0;
      if (ids.isNotEmpty) {
        final now = DateTime.now();
        String p(int v) => v.toString().padLeft(2, '0');
        final today = '${now.year}-${p(now.month)}-${p(now.day)}';
        final inspected = await getIt<QcInspectionRepository>()
            .templateIdsInspectedOn(today);
        total = ids.length;
        done = inspected.intersection(ids).length;
      }
      safeEmit(state.copyWith(total: total, done: done, loading: false));
    } catch (_) {
      safeEmit(const DailyTasksState(total: 0, done: 0, loading: false));
    }
  }
}
