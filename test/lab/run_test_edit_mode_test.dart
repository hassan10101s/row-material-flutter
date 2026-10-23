import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/design_system/widgets/app_entity_autocomplete.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/run_test_cubit.dart';
import 'package:material_lab/features/lab/presentation/run_test/run_test_tab.dart';

class _MockConfig extends Mock implements LabConfigurationRepository {}

class _MockLocal extends Mock implements LabLocalRepository {}

class _MockResults extends Mock implements LabResultRepository {}

/// Regression test for the request: editing a test from the history must use
/// the *same* field widgets as the add form — list fields become dropdowns,
/// fixed-value fields become read-only, and the analysis/source stay fixed
/// (only the sample remains editable).
void main() {
  testWidgets('edit mode reuses the add fields with fixed analysis/source', (
    tester,
  ) async {
    AppText.arabic = true;
    final config = _MockConfig();
    final local = _MockLocal();
    final results = _MockResults();
    when(() => config.listAnalyses()).thenAnswer(
      (_) async => [
        {
          'id': 5,
          'name': 'pH',
          'unit': 'pH',
          'dynamic_fields': ['Brix', 'Color', 'Moisture'],
          'field_chemical_links': [
            {'dynamic_field': 'Brix', 'kind': 'value', 'fixed_value': 5},
            {
              'dynamic_field': 'Color',
              'kind': 'list',
              'list_values': ['Red', 'Green'],
            },
            {'dynamic_field': 'Moisture', 'kind': 'link'},
          ],
        },
      ],
    );
    when(() => config.listProducts()).thenAnswer((_) async => []);
    when(() => local.listInspectionMaterials()).thenAnswer((_) async => []);
    when(() => local.listInspectionRecords(4)).thenAnswer(
      (_) async => [
        {
          'id': 22,
          'entry_code': 'EC-22',
          'material_id': 4,
          'material_name': 'Raw sugar',
          'sample_names': ['S1', 'S2'],
        },
      ],
    );

    final editRow = <String, dynamic>{
      'id': 1,
      'analysis_id': 5,
      'source_type': 'raw_material',
      'source_ref_id': 4,
      'source_name': 'Raw sugar',
      'sample_name': 'S2',
      'result_text': '6.5',
      'entry_code': 'EC-22',
      'dynamic_values': {'Color': 'Green', 'Moisture': '12'},
    };
    final cubit = RunTestCubit(
      config: config,
      results: results,
      local: local,
      editRow: editRow,
    );
    await cubit.load();

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 800),
        builder: (context, _) => MaterialApp(
          home: Scaffold(
            body: BlocProvider.value(
              value: cubit,
              child: SingleChildScrollView(
                child: RunTestTab(onTestRun: () {}, editRow: editRow),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Analysis/material/record pickers are gone — only the sample picker
    // stays (analysis and source are history while editing).
    expect(find.byType(AppEntityAutocomplete), findsOneWidget);
    // The list field is a dropdown; the fixed-value field has no input.
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    // The source is shown fixed (not an editable picker).
    expect(find.textContaining('Raw sugar'), findsWidgets);
    // Stored list selection and fixed value both render.
    expect(find.text('Green'), findsWidgets);
    // Fixed values are shown to at most 3 decimals, trailing zeros trimmed.
    expect(find.text('5'), findsWidgets);
    // The sample stays editable and shows the stored value.
    expect(find.text('S2'), findsWidgets);

    await cubit.close();
  });
}
