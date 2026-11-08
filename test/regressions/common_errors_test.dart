// Regression coverage for the defects reproduced by the November 7 audit.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/design_system/widgets/app_field.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_form_cubit.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/units_cubit.dart';
import 'package:material_lab/features/lab/core/formula_engine.dart';

class _Reference extends Mock implements ReferenceRepository {}

class _Inspections extends Mock implements InspectionRepository {}

void main() {
  test(
    'a slow first selection cannot overwrite the latest product and reference',
    () async {
      final reference = _Reference();
      final first = Completer<Map<String, dynamic>>();
      when(
        () =>
            reference.getProductForInspection(1, inspectionDate: '2026-11-07'),
      ).thenAnswer((_) => first.future);
      when(
        () =>
            reference.getProductForInspection(2, inspectionDate: '2026-11-07'),
      ).thenAnswer(
        (_) async => {
          'product_code': 'B',
          'physical_reference': {'B': 'Max 20'},
        },
      );
      final cubit = InspectionFormCubit(
        repo: _Inspections(),
        reference: reference,
      );
      addTearDown(cubit.close);
      final older = cubit.selectProduct(1, date: '2026-11-07');
      await cubit.selectProduct(2, date: '2026-11-07');
      expect(cubit.state.materialId, 2);
      first.complete({
        'product_code': 'A',
        'physical_reference': {'A': 'Max 10'},
      });
      await older;
      expect(cubit.state.materialId, 2);
      expect(cubit.state.physicalReference, contains('B'));
    },
  );

  test('old pagination never appends rows to a new search', () async {
    final reference = _Reference();
    final more = Completer<List<Map<String, dynamic>>>();
    when(
      () => reference.listUnitsPaged(query: '', limit: 1, offset: 0),
    ).thenAnswer(
      (_) async => [
        {'symbol': 'old-1'},
      ],
    );
    when(() => reference.countUnits(query: '')).thenAnswer((_) async => 2);
    when(() => reference.unitUsageCounts()).thenAnswer((_) async => {});
    when(
      () => reference.listUnitsPaged(query: '', limit: 1, offset: 1),
    ).thenAnswer((_) => more.future);
    when(
      () => reference.listUnitsPaged(query: 'new', limit: 1, offset: 0),
    ).thenAnswer(
      (_) async => [
        {'symbol': 'new-1'},
      ],
    );
    when(() => reference.countUnits(query: 'new')).thenAnswer((_) async => 1);
    final cubit = UnitsCubit(repo: reference, pageSize: 1);
    addTearDown(cubit.close);
    await cubit.load();
    final older = cubit.loadMore();
    await cubit.setQuery('new');
    more.complete([
      {'symbol': 'old-2'},
    ]);
    await older;
    expect(cubit.state.query, 'new');
    expect(cubit.state.rows.map((r) => r['symbol']), ['new-1']);
    expect(cubit.state.loadingMore, isFalse);
  });

  test('a successful form selection clears the previous error', () async {
    final reference = _Reference();
    when(
      () => reference.getProductForInspection(1, inspectionDate: '2026-11-07'),
    ).thenAnswer((_) async => throw StateError('temporary failure'));
    when(
      () => reference.getProductForInspection(2, inspectionDate: '2026-11-07'),
    ).thenAnswer((_) async => {'product_code': 'B'});
    final cubit = InspectionFormCubit(
      repo: _Inspections(),
      reference: reference,
    );
    addTearDown(cubit.close);
    await cubit.selectProduct(1, date: '2026-11-07');
    expect(cubit.state.error, isNotNull);
    await cubit.selectProduct(2, date: '2026-11-07');
    expect(cubit.state.materialId, 2);
    expect(cubit.state.error, isNull);
  });

  test('numeric validation and formula constants reject nonfinite values', () {
    final overflow = List.filled(400, '9').join();
    expect(double.parse(overflow).isInfinite, isTrue);
    expect(Validators.numeric(overflow), isNotNull);
    expect(
      () => resolveConstants({
        'X': {'value': 'NaN', 'min_value': 0, 'max_value': 10},
      }),
      throwsA(isA<ValidationError>()),
    );
    expect(
      () => evaluateFormula('X + 1', constants: {'X': 'Infinity'}),
      throwsA(isA<ValidationError>()),
    );
  });

  test(
    'simultaneous first secret loads all return the persisted key',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'materiallab_audit_secret_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final secret = LocalSecret(dir.path);
      final keys = await Future.wait(List.generate(8, (_) => secret.load()));
      final unique = keys.map((k) => k.join(',')).toSet();
      expect(unique.length, 1);
      final diskKey = await LocalSecret(dir.path).load();
      expect(keys.every((k) => k.join(',') == diskKey.join(',')), isTrue);
    },
  );
}
