import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/chemical_consumption_report.dart';
import '../../domain/lab_local_repository.dart';

class ChemicalConsumptionState {
  const ChemicalConsumptionState({
    required this.period,
    this.inventoryId,
    this.report,
    this.loading = true,
    this.error,
  });
  final ConsumptionPeriod period;
  final int? inventoryId;
  final ChemicalConsumptionReport? report;
  final bool loading;
  final String? error;
}

class ChemicalConsumptionCubit extends AppCubit<ChemicalConsumptionState> {
  ChemicalConsumptionCubit({required this.repo, DateTime? today})
    : super(
        ChemicalConsumptionState(
          period: ConsumptionPeriod.lastThreeMonths(today ?? DateTime.now()),
        ),
      ) {
    refreshOnSync(refresh);
  }
  final LabLocalRepository repo;
  int _generation = 0;

  Future<void> refresh() => _load(state.period, state.inventoryId);
  Future<void> selectChemical(int? id) => _load(state.period, id);
  Future<void> selectPeriod(ConsumptionPeriod period) =>
      _load(period, state.inventoryId);

  Future<void> _load(ConsumptionPeriod period, int? inventoryId) async {
    final generation = ++_generation;
    safeEmit(
      ChemicalConsumptionState(
        period: period,
        inventoryId: inventoryId,
        report: state.report,
      ),
    );
    try {
      final report = await repo.chemicalConsumptionReport(
        period: period,
        inventoryId: inventoryId,
      );
      if (generation != _generation || isClosed) return;
      safeEmit(
        ChemicalConsumptionState(
          period: period,
          inventoryId: inventoryId,
          report: report,
          loading: false,
        ),
      );
    } catch (error) {
      if (generation != _generation || isClosed) return;
      safeEmit(
        ChemicalConsumptionState(
          period: period,
          inventoryId: inventoryId,
          loading: false,
          error: AppError.friendly(error),
        ),
      );
    }
  }
}
