import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/qc_custom_table.dart';
import '../../domain/qc_repositories.dart';

/// Drives the settings gear: the list of user-authored tables, plus the
/// create / edit / delete flows that the hub's dynamic chips are built from.
///
/// Deliberately not a singleton-per-screen family: the
/// defs this holds feed BOTH the chip row in the hub and the settings screen
/// itself, so the hub can rebuild its chips the moment a table is created
/// without re-querying [QcCustomTablesRepository].
@immutable
class QcCustomTablesState extends Equatable {
  const QcCustomTablesState({
    this.tables = const [],
    this.loading = false,
    this.saving = false,
    this.error,
    this.saved = false,
  });

  final List<QcCustomTable> tables;
  final bool loading;
  final bool saving;
  final String? error;

  /// Set once by a successful create/edit/delete so the editor form can pop.
  final bool saved;

  QcCustomTablesState copyWith({
    List<QcCustomTable>? tables,
    bool? loading,
    bool? saving,
    Object? error = _unset,
    bool? saved,
  }) => QcCustomTablesState(
    tables: tables ?? this.tables,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
    saved: saved ?? this.saved,
  );

  @override
  List<Object?> get props => [tables, loading, saving, error, saved];
}

const _unset = Object();

class QcCustomTablesCubit extends AppCubit<QcCustomTablesState> {
  QcCustomTablesCubit({required this.repo})
    : super(const QcCustomTablesState(loading: true)) {
    refreshOnSync(load);
  }

  final QcCustomTablesRepository repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final tables = await repo.listTables();
      // `saved` is left alone: the settings screen pops on it, then the hub
      // reloads - clearing it here would eat that signal.
      safeEmit(state.copyWith(tables: tables, loading: false));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  Future<void> refresh() => load();

  Future<void> createTable(
    QcCustomTable table,
    List<QcCustomTableField> fields,
  ) => _write(() => repo.createTable(table, fields));

  Future<void> saveTable(
    QcCustomTable table,
    List<QcCustomTableField> fields,
  ) => _write(() => repo.saveTable(table, fields));

  Future<void> deleteTable(int tableId) =>
      _write(() => repo.deleteTable(tableId));

  Future<void> _write(Future<void> Function() action) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await action();
      safeEmit(state.copyWith(saving: false, saved: true));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: AppError.friendly(e)));
    }
  }

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearSaved() => safeEmit(state.copyWith(saved: false));
}
