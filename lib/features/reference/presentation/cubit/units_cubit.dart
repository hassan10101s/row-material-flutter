import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/widgets/app_infinite_list.dart';
import '../../domain/reference_repository.dart';
import 'units_state.dart';

/// Loads the lab units catalog for the Units settings tab, plus per-symbol
/// usage counts so the table shows which units the program inherits.
///
/// Mobile infinite-scroll model: DB-side search + `LIMIT/OFFSET`.
class UnitsCubit extends AppCubit<UnitsState> {
  UnitsCubit({required this.repo, this.pageSize = kMobilePageSize})
    : super(const UnitsState());

  final ReferenceRepository repo;
  final int pageSize;

  int _token = 0;

  /// Usage counts scan every unit-holding table (13 GROUP BYs): units
  /// change rarely, so the map is cached per cubit lifetime and only
  /// recomputed after a local upsert/delete.
  Map<String, int>? _usageCache;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(
      state.copyWith(loading: true, clearError: true, clearErrorMore: true),
    );
    try {
      final settled = await Future.wait([
        repo.listUnitsPaged(
          query: state.query,
          limit: pageSize,
          offset: 0,
        ),
        repo.countUnits(query: state.query),
      ]);
      var usage = _usageCache ?? const <String, int>{};
      if (_usageCache == null) {
        try {
          usage = await repo.unitUsageCounts();
          _usageCache = usage;
        } catch (_) {}
      }
      if (token != _token) return;
      final rows = settled[0] as List<Map<String, dynamic>>;
      final total = settled[1] as int;
      safeEmit(
        state.copyWith(
          loading: false,
          rows: rows,
          usage: usage,
          total: total,
          hasMore: rows.length >= pageSize,
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

  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    safeEmit(state.copyWith(loadingMore: true, clearErrorMore: true));
    try {
      final more = await repo.listUnitsPaged(
        query: state.query,
        limit: pageSize,
        offset: state.rows.length,
      );
      safeEmit(
        state.copyWith(
          loadingMore: false,
          rows: [...state.rows, ...more],
          hasMore: more.length >= pageSize,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loadingMore: false, errorMore: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loadingMore: false, errorMore: '$e'));
    }
  }

  Future<void> refresh() => load();

  Future<void> setQuery(String query) async {
    if (query == state.query) return;
    safeEmit(state.copyWith(query: query, rows: const []));
    await load();
  }

  Future<void> upsert(
    String symbol, {
    String name = '',
    String dimension = '',
  }) async {
    await repo.upsertUnit(symbol, name: name, dimension: dimension);
    _usageCache = null;
  }

  /// Refuses to delete a unit the program still references, naming how many
  /// rows inherit it. Deleting it would orphan those pickers.
  Future<void> delete(String symbol) async {
    final trimmed = symbol.trim();
    // Deletes are rare: always re-scan so a unit adopted elsewhere since
    // the cached load can never slip through the guard.
    Map<String, int> usage = state.usage;
    try {
      usage = await repo.unitUsageCounts();
      _usageCache = usage;
    } catch (_) {}
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
    _usageCache = null;
  }
}
