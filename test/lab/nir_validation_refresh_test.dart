import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/lab/domain/nir_validation_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/nir_validation_cubit.dart';

class _Repo implements NirValidationRepository {
  @override
  Future<void> setPointIncluded(NirValidationPoint point, bool included) =>
      throw UnimplementedError();
  final pending = <Completer<NirValidationReport>>[];
  @override
  Future<NirValidationReport> compute({String? startDate}) {
    expect(
      startDate,
      isNull,
      reason: 'the read snapshot resolves its own horizon',
    );
    return pending.removeAt(0).future;
  }

  @override
  Future<List<NirValidationSettings>> listResetHistory({
    int limit = 50,
  }) async => [];
  @override
  Future<NirValidationSettings?> getSettings() =>
      throw StateError('must use the report snapshot');
  @override
  Future<NirValidationSettings> resetValidation(
    String date, {
    String note = '',
    NirScope? scope,
    int? entityId,
    String entityName = '',
    String parameter = '',
    NirAppliedCorrection? appliedCorrection,
  }) => throw UnimplementedError();
}

void main() {
  test(
    'an older NIR refresh cannot replace a newer result or show its stale error',
    () async {
      final repo = _Repo();
      final first = Completer<NirValidationReport>();
      final second = Completer<NirValidationReport>();
      repo.pending.addAll([first, second]);
      final cubit = NirValidationCubit(repo: repo);
      addTearDown(cubit.close);
      final oldLoad = cubit.load();
      final newLoad = cubit.load();
      second.complete(
        const NirValidationReport(
          settings: NirValidationSettings(id: 2, startDate: '2026-11-07'),
          stats: [],
        ),
      );
      await newLoad;
      first.completeError(StateError('late failure from obsolete request'));
      await oldLoad;
      expect(cubit.state.settings!.id, 2);
      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, isNull);
      final third = Completer<NirValidationReport>();
      repo.pending.add(third);
      final cleared = cubit.load();
      third.complete(const NirValidationReport(settings: null, stats: []));
      await cleared;
      expect(
        cubit.state.settings,
        isNull,
        reason: 'an absent horizon must not retain an earlier setting',
      );
    },
  );
}
