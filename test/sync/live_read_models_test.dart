import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/sync/sync_data_changes.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/reference_cubit.dart';

class _Reference extends Mock implements ReferenceRepository {}

void main() {
  test(
    'an open register refreshes after a remote commit and unsubscribes on close',
    () async {
      final repo = _Reference();
      var rows = <Map<String, dynamic>>[];
      when(
        () => repo.listMaterialsPaged(
          query: any(named: 'query'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => rows);
      when(
        () => repo.countMaterials(query: any(named: 'query')),
      ).thenAnswer((_) async => rows.length);
      final cubit = ReferenceCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.materials, isEmpty);
      rows = [
        {'id': 5, 'material_name': 'Remote material', 'material_code': 'REM'},
      ];
      final updated = cubit.stream.firstWhere(
        (state) => !state.loading && state.materials.isNotEmpty,
      );
      SyncDataChanges.notify();
      await updated;
      expect(cubit.state.materials.single['material_name'], 'Remote material');
      await cubit.close();
      clearInteractions(repo);
      SyncDataChanges.notify();
      await Future<void>.delayed(Duration.zero);
      verifyNever(() => repo.countMaterials(query: any(named: 'query')));
    },
  );
}
