import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_detail_cubit.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/run_test_cubit.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';

class _InspectionRepositoryMock extends Mock implements InspectionRepository {}

class _LabLocalRepositoryMock extends Mock implements LabLocalRepository {}

class _LabConfigurationRepositoryMock extends Mock
    implements LabConfigurationRepository {}

class _LabResultRepositoryMock extends Mock implements LabResultRepository {}

class _ReportRepositoryMock extends Mock implements ReportRepository {}

void main() {
  group('RunTestCubit inspection trace', () {
    late _LabConfigurationRepositoryMock configuration;
    late _LabLocalRepositoryMock local;
    late _LabResultRepositoryMock results;
    late RunTestCubit cubit;

    setUp(() {
      configuration = _LabConfigurationRepositoryMock();
      local = _LabLocalRepositoryMock();
      results = _LabResultRepositoryMock();
      when(() => configuration.listAnalyses()).thenAnswer(
        (_) async => [
          {'id': 8, 'name': 'Moisture', 'unit': '%'},
        ],
      );
      when(() => configuration.listProducts()).thenAnswer((_) async => []);
      when(() => local.listInspectionMaterials()).thenAnswer(
        (_) async => [
          {'id': 4, 'material_name': 'Raw sugar', 'material_code': 'RS-04'},
        ],
      );
      cubit = RunTestCubit(
        config: configuration,
        results: results,
        local: local,
      );
      addTearDown(cubit.close);
    });

    test(
      'new test starts with an empty analysis selection and can clear it',
      () async {
        await cubit.load();
        expect(cubit.state.analysisId, isNull);
        cubit.selectAnalysis(8);
        expect(cubit.state.analysisId, 8);
        cubit.clearAnalysis();
        expect(cubit.state.analysisId, isNull);
      },
    );

    test('changing source clears the previous inspection and sample', () async {
      when(() => local.listInspectionRecords(4)).thenAnswer(
        (_) async => [
          {
            'id': 22,
            'entry_code': 'RAW-22',
            'sample_names': ['Raw sample'],
          },
        ],
      );
      await cubit.load();
      await cubit.selectRawMaterial(4);
      cubit.selectInspection(22);

      cubit.setSourceType('product');

      expect(cubit.state.selectedInspection, isEmpty);
      expect(cubit.state.selectedSampleName, isEmpty);
      expect(cubit.state.inspections, isEmpty);
      expect(cubit.state.rawMaterialId, isNull);
      expect(cubit.state.sourceName, isEmpty);
    });

    test(
      'raw lookup replaces product identity and clears an old sample',
      () async {
        when(() => local.resolveInspection('PRODUCT')).thenAnswer(
          (_) async => {
            'id': 10,
            'inspection_kind': 'product',
            'product_id': 3,
            'material_name': 'Feed',
            'entry_code': 'PRODUCT',
            'sample_names': ['Product sample'],
          },
        );
        when(() => local.resolveInspection('RAW')).thenAnswer(
          (_) async => {
            'id': 22,
            'material_id': 4,
            'material_name': 'Raw sugar',
            'entry_code': 'RAW',
            'sample_names': <String>[],
          },
        );
        await cubit.load();
        await cubit.lookupEntry('PRODUCT');
        await cubit.lookupEntry('RAW');

        expect(cubit.state.sourceType, 'raw_material');
        expect(cubit.state.rawMaterialId, 4);
        expect(cubit.state.productId, isNull);
        expect(cubit.state.selectedSampleName, isEmpty);
        expect(cubit.state.selectedInspection['entry_code'], 'RAW');
      },
    );

    test('late records cannot repopulate a different source', () async {
      final pending = Completer<List<Map<String, dynamic>>>();
      when(
        () => local.listInspectionRecords(4),
      ).thenAnswer((_) => pending.future);
      await cubit.load();
      final loading = cubit.selectRawMaterial(4);
      cubit.setSourceType('product');
      pending.complete([
        {'id': 22, 'entry_code': 'RAW'},
      ]);
      await loading;

      expect(cubit.state.sourceType, 'product');
      expect(cubit.state.inspections, isEmpty);
      expect(cubit.state.loadingInspections, isFalse);
    });

    test(
      'late failed request cannot replace a newer successful selection',
      () async {
        final pending = Completer<List<Map<String, dynamic>>>();
        when(
          () => local.listInspectionRecords(4),
        ).thenAnswer((_) => pending.future);
        when(() => local.listInspectionRecords(5)).thenAnswer(
          (_) async => [
            {'id': 50, 'entry_code': 'NEW'},
          ],
        );
        await cubit.load();
        final oldLoading = cubit.selectRawMaterial(4);
        await cubit.selectRawMaterial(5);
        pending.completeError(StateError('old request failed'));
        await oldLoading;

        expect(cubit.state.error, isNull);
        expect(cubit.state.inspections.single['entry_code'], 'NEW');
        expect(cubit.state.loadingInspections, isFalse);
      },
    );

    test('a successful retry clears the previous load error', () async {
      when(
        () => local.listInspectionRecords(4),
      ).thenThrow(StateError('offline'));
      await cubit.load();
      await cubit.selectRawMaterial(4);
      expect(cubit.state.error, isNotNull);
      when(() => local.listInspectionRecords(4)).thenAnswer((_) async => []);

      await cubit.selectRawMaterial(4);

      expect(cubit.state.error, isNull);
      expect(cubit.state.loadingInspections, isFalse);
    });

    test('clear selection invalidates an in-flight record load', () async {
      final pending = Completer<List<Map<String, dynamic>>>();
      when(
        () => local.listInspectionRecords(4),
      ).thenAnswer((_) => pending.future);
      await cubit.load();
      final loading = cubit.selectRawMaterial(4);
      cubit.clearRawMaterial();
      pending.complete([
        {'id': 22},
      ]);
      await loading;

      expect(cubit.state.rawMaterialId, isNull);
      expect(cubit.state.inspections, isEmpty);
      expect(cubit.state.loadingInspections, isFalse);
    });

    test('latest lookup wins when older lookup finishes last', () async {
      final pending = Completer<Map<String, dynamic>?>();
      when(
        () => local.resolveInspection('OLD'),
      ).thenAnswer((_) => pending.future);
      when(() => local.resolveInspection('NEW')).thenAnswer(
        (_) async => {'id': 22, 'material_id': 4, 'entry_code': 'NEW'},
      );
      await cubit.load();
      final oldLookup = cubit.lookupEntry('OLD');
      expect(await cubit.lookupEntry('NEW'), isTrue);
      pending.complete({'id': 10, 'material_id': 5, 'entry_code': 'OLD'});

      expect(await oldLookup, isFalse);
      expect(cubit.state.selectedInspection['entry_code'], 'NEW');
      expect(cubit.state.rawMaterialId, 4);
    });

    test(
      'an unknown entry does not cancel the material records still loading',
      () async {
        final pending = Completer<List<Map<String, dynamic>>>();
        when(
          () => local.listInspectionRecords(4),
        ).thenAnswer((_) => pending.future);
        when(
          () => local.resolveInspection('UNKNOWN'),
        ).thenAnswer((_) async => null);
        await cubit.load();
        final loading = cubit.selectRawMaterial(4);
        expect(await cubit.lookupEntry('UNKNOWN'), isFalse);
        pending.complete([
          {'id': 22, 'entry_code': 'CURRENT'},
        ]);
        await loading;
        expect(cubit.state.loadingInspections, isFalse);
        expect(cubit.state.inspections.single['entry_code'], 'CURRENT');
      },
    );

    test(
      'a newer manual inspection selection wins over a pending lookup',
      () async {
        final pending = Completer<Map<String, dynamic>?>();
        when(() => local.listInspectionRecords(4)).thenAnswer(
          (_) async => [
            {
              'id': 22,
              'entry_code': 'MANUAL',
              'sample_names': ['S1'],
            },
          ],
        );
        when(
          () => local.resolveInspection('QR'),
        ).thenAnswer((_) => pending.future);
        await cubit.load();
        await cubit.selectRawMaterial(4);
        final lookup = cubit.lookupEntry('QR');
        cubit.selectInspection(22);
        pending.complete({'id': 23, 'entry_code': 'QR', 'material_id': 4});
        expect(await lookup, isFalse);
        expect(cubit.state.selectedInspection['entry_code'], 'MANUAL');
      },
    );

    test(
      'runs against the selected inspection and its selected sample',
      () async {
        when(() => local.listInspectionRecords(4)).thenAnswer(
          (_) async => [
            {
              'id': 22,
              'entry_code': 'INSP-22',
              'material_name': 'Raw sugar',
              'inspection_date': '2026-10-21',
              'supplier': 'Supplier A',
              'truck_number': 'TR-42',
              'sample_names': ['Truck 1', 'Truck 2'],
            },
          ],
        );
        when(
          () => results.runSampleTest(
            analysisId: 8,
            sourceType: 'raw_material',
            sourceRefId: 4,
            sourceName: 'Raw sugar',
            sampleName: 'Truck 2',
            resultText: '0.5',
            dynamicValues: const {},
            user: null,
            entryCode: 'INSP-22',
            manualResult: false,
          ),
        ).thenAnswer(
          (_) async => {
            'test': {'id': 1},
          },
        );

        await cubit.load();
        await cubit.selectRawMaterial(4);
        cubit.selectInspection(22);
        cubit.selectInspectionSample('Truck 2');
        cubit.selectAnalysis(8);
        final result = await cubit.run(
          sampleName: '',
          resultText: '0.5',
          dynamicValues: const {},
        );

        expect(result['test'], {'id': 1});
        verify(
          () => results.runSampleTest(
            analysisId: 8,
            sourceType: 'raw_material',
            sourceRefId: 4,
            sourceName: 'Raw sugar',
            sampleName: 'Truck 2',
            resultText: '0.5',
            dynamicValues: const {},
            user: null,
            entryCode: 'INSP-22',
            manualResult: false,
          ),
        ).called(1);
        await cubit.close();
      },
    );
  });

  test(
    'inspection detail loads lab analyses by the exact record number',
    () async {
      final inspections = _InspectionRepositoryMock();
      final labResults = _LabResultRepositoryMock();
      when(() => inspections.getById(22)).thenAnswer(
        (_) async => {
          'id': 22,
          'entry_code': 'INSP-22',
          'status_history': const [],
        },
      );
      when(() => labResults.listSampleTestsForEntryCode('INSP-22')).thenAnswer(
        (_) async => [
          {
            'analysis_name': 'Moisture',
            'sample_name': 'Truck 2',
            'result_text': '0.5',
            'analysis_unit': '%',
          },
        ],
      );
      final cubit = InspectionDetailCubit(
        inspectionId: 22,
        repo: inspections,
        reports: _ReportRepositoryMock(),
        labResults: labResults,
      );

      await cubit.load();

      expect(cubit.state.chemicalAnalyses, hasLength(1));
      expect(cubit.state.chemicalAnalyses.single['analysis_name'], 'Moisture');
      verify(() => labResults.listSampleTestsForEntryCode('INSP-22')).called(1);
      await cubit.close();
    },
  );

  for (final code in ['INSP-22', ' INSP-22', 'INSP-22 ']) {
    test('detail keeps the stored receipt identity verbatim: $code', () async {
      final inspections = _InspectionRepositoryMock();
      final lab = _LabResultRepositoryMock();
      when(() => inspections.getById(22)).thenAnswer(
        (_) async => {'id': 22, 'entry_code': code, 'status_history': const []},
      );
      when(
        () => lab.listSampleTestsForEntryCode(any()),
      ).thenAnswer((_) async => []);
      final cubit = InspectionDetailCubit(
        inspectionId: 22,
        repo: inspections,
        reports: _ReportRepositoryMock(),
        labResults: lab,
      );
      await cubit.load();
      verify(() => lab.listSampleTestsForEntryCode(code)).called(1);
      expect(cubit.state.error, isNull);
      await cubit.close();
    });
  }
}
