import '../../../../core/security/secure_field_access.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../core/commands/central_authoring_gateway.dart';
import '../../domain/nir_validation_repository.dart';
import 'nir_validation_state.dart';

/// Loads the NIR فلديشن report and performs the reset (new horizon).
class NirValidationCubit extends AppCubit<NirValidationState> {
  NirValidationCubit({required this.repo, this.secureAccess}) : super(const NirValidationState()) {
    refreshOnSync(load);
    secureAccess?.addListener(_privacyChanged);
  }

  final SecureFieldAccess? secureAccess;
  void _privacyChanged() {
    _loadGeneration++;
    safeEmit(state.copyWith(stats: const [], resetHistory: const []));
    load();
  }
  @override
  Future<void> close() {
    secureAccess?.removeListener(_privacyChanged);
    return super.close();
  }
  final NirValidationRepository repo;
  int _loadGeneration = 0;

  Future<bool> setPointIncluded(NirValidationPoint point, bool included) async {
    if (state.saving || state.pendingApproval) return false;
    safeEmit(state.copyWith(saving: true, clearError: true));
    try {
      await repo.setPointIncluded(point, included);
      await load();
      safeEmit(state.copyWith(saving: false));
      return state.error == null;
    } on CentralDraftPending {
      safeEmit(state.copyWith(saving: false, pendingApproval: true));
      return false;
    } catch (error) {
      safeEmit(state.copyWith(saving: false, error: AppError.friendly(error)));
      return false;
    }
  }

  Future<void> load() async {
    final generation = ++_loadGeneration;
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      // The repository resolves the horizon and measurements in one read
      // snapshot. Do not fetch an earlier horizon and force it onto new data.
      final report = await repo.compute();
      final history = await repo.listResetHistory();
      if (generation != _loadGeneration || isClosed) return;
      safeEmit(
        state.copyWith(
          loading: false,
          settings: report.settings,
          clearSettings: report.settings == null,
          resetHistory: history,
          stats: report.stats,
        ),
      );
    } on AppError catch (e) {
      if (generation != _loadGeneration || isClosed) return;
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    } catch (e) {
      if (generation != _loadGeneration || isClosed) return;
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
    NirAppliedCorrection? appliedCorrection,
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
        appliedCorrection: appliedCorrection,
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
      safeEmit(state.copyWith(saving: false, error: AppError.friendly(e)));
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
