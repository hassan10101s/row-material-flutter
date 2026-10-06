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
    });

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
}
