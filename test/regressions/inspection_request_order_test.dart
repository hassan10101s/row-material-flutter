import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_form_cubit.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspections_cubit.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';

class _References extends Mock implements ReferenceRepository {}

class _Inspections extends Mock implements InspectionRepository {}

class _Reports extends Mock implements ReportRepository {}

void main() {
  for (final product in [false, true]) {
    group(product ? 'product selection' : 'material selection', () {
      late _References references;
      late _Inspections inspections;
      late InspectionFormCubit cubit;
      late Completer<Map<String, dynamic>> pending;
      Future<void> select() => product
          ? cubit.selectProduct(1, date: '2026-11-08')
          : cubit.selectMaterial(1, date: '2026-11-08');
      Map<String, dynamic> result() => {
        product ? 'product_code' : 'material_code': 'M1',
        'next_entry_code': 'M1-20261108-1',
        'physical_reference': {'Moisture': 'Max 10'},
      };
      setUp(() {
        references = _References();
        inspections = _Inspections();
        pending = Completer();
        when(
          () => references.getMaterial(1, inspectionDate: '2026-11-08'),
        ).thenAnswer((_) => pending.future);
        when(
          () => references.getProductForInspection(
            1,
            inspectionDate: '2026-11-08',
          ),
        ).thenAnswer((_) => pending.future);
        when(
          () => inspections.listSampleTakerHistory(),
        ).thenAnswer((_) async => []);
        when(
          () => inspections.listSupplierHistory(
            materialId: any(named: 'materialId'),
          ),
        ).thenAnswer((_) async => []);
        cubit = InspectionFormCubit(repo: inspections, reference: references);
        addTearDown(cubit.close);
      });

      test('clearing a pending selection prevents it from returning', () async {
        final loading = select();
        expect(cubit.state.selectingReference, isTrue);
        cubit.clearMaterial();
        pending.complete(result());
        await loading;
        expect(cubit.state.materialId, isNull);
        expect(cubit.state.physicalReference, isEmpty);
        expect(cubit.state.selectingReference, isFalse);
      });

      test(
        'entering edit mode keeps the approved identity and snapshot',
        () async {
          final loading = select();
          await cubit.loadForEdit({
            'id': 99,
            'material_id': 7,
            'material_code': 'ARCHIVE',
            'entry_code': 'APPROVED-ENTRY',
            'physical_reference': {'Archived': 'Max 5'},
          });
          pending.complete(result());
          await loading;
          expect(cubit.state.materialId, 7);
          expect(cubit.state.entryCode, 'APPROVED-ENTRY');
          expect(cubit.state.physicalReference, {'Archived': 'Max 5'});
        },
      );

      test(
        'an obsolete failure cannot restore an error after clearing',
        () async {
          final loading = select();
          cubit.clearMaterial();
          pending.completeError(StateError('obsolete query'));
          await loading;
          expect(cubit.state.error, isNull);
          expect(cubit.state.selectingReference, isFalse);
        },
      );

      test(
        'saving waits for the selected reference instead of using an old identity',
        () async {
          final loading = select();
          expect(
            await cubit.save(
              {},
              const UserContext(id: 1, fullName: 'Operator', role: 'admin'),
            ),
            isFalse,
          );
          verifyNever(
            () => inspections.create(
              {},
              const UserContext(id: 1, fullName: 'Operator', role: 'admin'),
            ),
          );
          pending.complete(result());
          await loading;
          expect(cubit.state.selectingReference, isFalse);
          expect(cubit.state.materialId, 1);
        },
      );

      test(
        'a date change during selection generates the entry code for the latest date',
        () async {
          when(
            () => references.generateEntryCode('M1', '2026-11-09'),
          ).thenAnswer((_) async => 'M1-20261109-1');
          final loading = select();
          await cubit.regenerateEntryCode('2026-11-09');
          pending.complete(result());
          await loading;
          expect(cubit.state.entryCode, 'M1-20261109-1');
        },
      );
    });
  }

  test('an older catalog cannot overwrite a product catalog', () async {
    final references = _References();
    final inspections = _Inspections();
    final raw = Completer<List<Map<String, dynamic>>>();
    when(() => references.listMaterials()).thenAnswer((_) => raw.future);
    when(() => references.listProductsForInspection()).thenAnswer(
      (_) async => [
        {'id': 2, 'name': 'Product B', 'product_code': 'B'},
      ],
    );
    when(
      () => inspections.listSampleTakerHistory(),
    ).thenAnswer((_) async => []);
    final cubit = InspectionFormCubit(repo: inspections, reference: references);
    addTearDown(cubit.close);
    final older = cubit.loadMaterials();
    await cubit.loadProducts();
    raw.complete([
      {'id': 1, 'material_name': 'Raw A'},
    ]);
    await older;
    expect(cubit.state.materials.single['material_name'], 'Product B');
  });

  test(
    'old raw suppliers cannot surface for a product with the same local id',
    () async {
      final references = _References();
      final inspections = _Inspections();
      final suppliers = Completer<List<Map<String, dynamic>>>();
      when(
        () => references.getMaterial(1, inspectionDate: '2026-11-08'),
      ).thenAnswer((_) async => {'material_code': 'RAW'});
      when(() => references.listProductsForInspection()).thenAnswer(
        (_) async => [
          {'id': 1, 'name': 'Product', 'product_code': 'P'},
        ],
      );
      when(
        () =>
            references.getProductForInspection(1, inspectionDate: '2026-11-08'),
      ).thenAnswer((_) async => {'product_code': 'P'});
      when(
        () => inspections.listSampleTakerHistory(),
      ).thenAnswer((_) async => []);
      when(
        () => inspections.listSupplierHistory(materialId: 1),
      ).thenAnswer((_) => suppliers.future);
      final cubit = InspectionFormCubit(
        repo: inspections,
        reference: references,
      );
      addTearDown(cubit.close);
      final raw = cubit.selectMaterial(1, date: '2026-11-08');
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.materialId, 1);
      expect(cubit.state.refRevision, 1);
      await cubit.loadProducts();
      await cubit.selectProduct(1, date: '2026-11-08');
      expect(cubit.state.refRevision, 2);
      suppliers.complete([
        {'name': 'Raw supplier'},
      ]);
      await raw;
      expect(cubit.state.materialCode, 'P');
      expect(cubit.state.supplierOptions, isEmpty);
    },
  );

  for (final fail in [false, true]) {
    test(
      'an obsolete ledger ${fail ? 'failure' : 'page'} cannot replace a new search',
      () async {
        final repo = _Inspections();
        final pending = Completer<List<Map<String, dynamic>>>();
        when(
          () => repo.list(
            query: any(named: 'query'),
            status: '',
            reason: '',
            limit: 200,
            offset: 0,
            orderBy: 'inspection_date DESC, id DESC',
            kind: 'raw',
            dateFrom: '',
            dateTo: '',
            supplier: '',
            materialId: null,
            productId: null,
          ),
        ).thenAnswer((call) {
          return call.namedArguments[#query] == 'new'
              ? Future.value([
                  {'id': 2},
                ])
              : pending.future;
        });
        when(
          () => repo.count(
            query: any(named: 'query'),
            status: '',
            reason: '',
            kind: 'raw',
            dateFrom: '',
            dateTo: '',
            supplier: '',
            materialId: null,
            productId: null,
          ),
        ).thenAnswer(
          (call) async => call.namedArguments[#query] == 'new' ? 1 : 20,
        );
        final cubit = InspectionsCubit(repo: repo, reports: _Reports());
        addTearDown(cubit.close);
        final older = cubit.load();
        await cubit.setQuery('new');
        if (fail) {
          pending.completeError(StateError('obsolete'));
        } else {
          pending.complete([
            {'id': 1},
          ]);
        }
        await older;
        expect(cubit.state.query, 'new');
        expect(cubit.state.rows, [
          {'id': 2},
        ]);
        expect(cubit.state.total, 1);
        expect(cubit.state.error, isNull);
      },
    );
  }
}
