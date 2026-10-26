import 'package:equatable/equatable.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/routine_repository.dart';

class RoutineSheetState extends Equatable {
  const RoutineSheetState({
    this.loading = true,
    this.sheet,
    this.toggling = const {},
    this.logging = const {},
    this.error,
    this.notice,
  });

  final bool loading;
  final RoutineSheet? sheet;

  /// Item ids currently being written (checkbox disabled meanwhile).
  final Set<int> toggling;

  /// Item ids whose done-button press is in flight.
  final Set<int> logging;
  final String? error;
  final String? notice;

  RoutineSheetState copyWith({
    bool? loading,
    RoutineSheet? sheet,
    Set<int>? toggling,
    Set<int>? logging,
    Object? error = _unset,
    Object? notice = _unset,
  }) => RoutineSheetState(
    loading: loading ?? this.loading,
    sheet: sheet ?? this.sheet,
    toggling: toggling ?? this.toggling,
    logging: logging ?? this.logging,
    error: identical(error, _unset) ? this.error : error as String?,
    notice: identical(notice, _unset) ? this.notice : notice as String?,
  );

  @override
  List<Object?> get props => [loading, sheet, toggling, logging, error, notice];
}

const Object _unset = Object();

/// One routine sheet: tap a box to check (stamps who/when), tap again to
/// uncheck while the period is current. Past sheets are read-only.
class RoutineSheetCubit extends AppCubit<RoutineSheetState> {
  RoutineSheetCubit({required this.repo, required this.inspectionId})
    : super(const RoutineSheetState()) {
    refreshOnSync(load);
  }

  final RoutineListsRepository repo;
  final int inspectionId;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null, notice: null));
    try {
      final sheet = await repo.loadSheet(inspectionId);
      safeEmit(state.copyWith(loading: false, sheet: sheet));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  Future<void> refresh() => load();

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearNotice() => safeEmit(state.copyWith(notice: null));

  Future<void> toggle(int itemId, {String note = ''}) async {
    if (state.toggling.contains(itemId)) return;
    safeEmit(
      state.copyWith(toggling: {...state.toggling, itemId}, error: null),
    );
    try {
      final sheet = await repo.toggleCheck(
        inspectionId: inspectionId,
        itemId: itemId,
        note: note,
      );
      safeEmit(
        state.copyWith(
          sheet: sheet,
          toggling: state.toggling.where((id) => id != itemId).toSet(),
        ),
      );
    } on AppError catch (e) {
      safeEmit(
        state.copyWith(
          toggling: state.toggling.where((id) => id != itemId).toSet(),
          error: e.message,
        ),
      );
    } catch (e) {
      safeEmit(
        state.copyWith(
          toggling: state.toggling.where((id) => id != itemId).toSet(),
          error: AppError.friendly(e),
        ),
      );
    }
  }

  /// The per-task done button: appends one log entry (time + user) and
  /// marks the row done for the period. Unlike [toggle], it never unmarks.
  Future<void> recordDone(int itemId, {String note = ''}) async {
    if (state.logging.contains(itemId)) return;
    safeEmit(state.copyWith(logging: {...state.logging, itemId}, error: null));
    try {
      final sheet = await repo.recordDone(
        inspectionId: inspectionId,
        itemId: itemId,
        note: note,
      );
      safeEmit(
        state.copyWith(
          sheet: sheet,
          logging: state.logging.where((id) => id != itemId).toSet(),
          notice: AppText.t(
            'تم تسجيل الإنجاز (الساعة + الاسم)',
            'Completion logged (time + name)',
          ),
        ),
      );
    } on AppError catch (e) {
      safeEmit(
        state.copyWith(
          logging: state.logging.where((id) => id != itemId).toSet(),
          error: e.message,
        ),
      );
    } catch (e) {
      safeEmit(
        state.copyWith(
          logging: state.logging.where((id) => id != itemId).toSet(),
          error: AppError.friendly(e),
        ),
      );
    }
  }
}
