import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/reference_repository.dart';
import 'units_state.dart';

/// Loads the lab units catalog for the Units settings tab, plus per-symbol
/// usage counts so the table shows which units the program inherits.
class UnitsCubit extends AppCubit<UnitsState> {
  UnitsCubit({required this.repo}) : super(const UnitsState());

  final ReferenceRepository repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.listUnits();
      var usage = const <String, int>{};
      try {
        usage = await repo.unitUsageCounts();
      } catch (_) {}
      safeEmit(state.copyWith(loading: false, rows: rows, usage: usage));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<void> upsert(
    String symbol, {
    String name = '',
    String dimension = '',
  }) => repo.upsertUnit(symbol, name: name, dimension: dimension);

  /// Refuses to delete a unit the program still references, naming how many
  /// rows inherit it. Deleting it would orphan those pickers.
  Future<void> delete(String symbol) async {
    final trimmed = symbol.trim();
    Map<String, int> usage = state.usage;
    if (!usage.containsKey(trimmed)) {
      try {
        usage = await repo.unitUsageCounts();
      } catch (_) {}
    }
    final n = usage[trimmed] ?? 0;
    if (n > 0) {
      throw ValidationError(
        AppText.t(
          'الوحدة "$trimmed" مستخدمة في $n موضع — لا يمكن حذفها',
          'Unit "$trimmed" is used in $n place(s) and cannot be deleted',
        ),
      );
    }
    await repo.deleteUnit(trimmed);
  }
}
