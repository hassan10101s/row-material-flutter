import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../core/commands/central_authoring_gateway.dart';
import '../../domain/nir_validation_repository.dart';
import 'nir_validation_state.dart';

/// Loads the NIR فلديشن report and performs the reset (new horizon).
class NirValidationCubit extends AppCubit<NirValidationState> {
  NirValidationCubit({required this.repo}) : super(const NirValidationState()) {
    refreshOnSync(load);
  }

  final NirValidationRepository repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      final settings = await repo.getSettings();
      final history = await repo.listResetHistory();
      final report = await compute(settings?.startDate);
      safeEmit(
        state.copyWith(
          loading: false,
          settings: settings,
          resetHistory: history,
          stats: report.stats,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  Future<NirValidationReport> compute(String? startDate) =>
      repo.compute(startDate: startDate);

  /// Records a new horizon. Pass [scope] + [entityId]/[entityName] +
  /// [parameter] to reset a single item inside one خامة/منتج; leave them out
  /// for a whole-calibration reset.
  Future<bool> reset(
    String startDate,
    String note, {
    NirScope? scope,
    int? entityId,
    String entityName = '',
    String parameter = '',
  }) async {
    safeEmit(
      state.copyWith(saving: true, clearError: true, pendingApproval: false),
    );
    try {
      await repo.resetValidation(
        startDate,
        note: note,
        scope: scope,
        entityId: entityId,
        entityName: entityName,
        parameter: parameter,
      );
      await load();
      safeEmit(state.copyWith(saving: false));
      return true;
    } on CentralDraftPending {
      safeEmit(
        state.copyWith(saving: false, clearError: true, pendingApproval: true),
      );
      return true;
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
      return false;
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: AppError.friendly(e)));
      return false;
    }
  }

  void setScope(NirScope? scope) =>
      safeEmit(state.copyWith(scopeFilter: scope, clearScope: scope == null));

  void setQuery(String query) {
    safeEmit(state.copyWith(query: query));
  }
}
