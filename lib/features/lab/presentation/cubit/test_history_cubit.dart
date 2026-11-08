import '../../../../core/security/secure_field_access.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/lab_local_repository.dart';
import '../../domain/lab_result_repository.dart';
import 'test_history_state.dart';

/// Loads the sample-tests history for the Tests tab. Reloaded by the tab when
/// the LabCubit history tick changes (i.e. after a test finishes).
///
/// The history pairs a replicated result with a device-local consumption log,
/// so it needs the result and local contracts; the analyses are only read to
/// label the rows.
class TestHistoryCubit extends AppCubit<TestHistoryState> {
  TestHistoryCubit({
    required this.results,
    required this.local,
    required this.config,
    this.secureAccess,
  }) : super(const TestHistoryState()) {
    refreshOnSync(load);
    secureAccess?.addListener(_privacyChanged);
  }

  final SecureFieldAccess? secureAccess;
  void _privacyChanged() {
    safeEmit(
      state.copyWith(
        rows: [
          for (final row in state.rows)
            if (row['secure_result'] != 1) SecureFieldAccess.publicRecord(row),
        ],
      ),
    );
    load();
  }

  @override
  Future<void> close() {
    secureAccess?.removeListener(_privacyChanged);
    return super.close();
  }

  final LabResultRepository results;
  final LabLocalRepository local;
  final LabConfigurationRepository config;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final loaded = await Future.wait<Object>([
        results.listSampleTests(),
        local.listConsumptionLog(),
        config.listAnalyses(),
      ]);
      final rows = <Map<String, dynamic>>[];
      for (final row in loaded[0] as List<Map<String, dynamic>>) {
        if (row['secure_result'] == 1 && secureAccess?.enabled != true) {
          continue;
        }
        rows.add(
          secureAccess == null
              ? row
              : await secureAccess!.reveal('labResult', row),
        );
      }
      safeEmit(
        state.copyWith(
          loading: false,
          rows: secureAccess?.enabled == true
              ? rows
              : [
                  for (final r in rows)
                    if (r['secure_result'] != 1)
                      SecureFieldAccess.publicRecord(r),
                ],
          log: loaded[1] as List<Map<String, dynamic>>,
          analyses: loaded[2] as List<Map<String, dynamic>>,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }
}
