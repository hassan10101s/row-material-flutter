import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/features/lab/core/test_history_logic.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/test_history_cubit.dart';
import 'package:material_lab/features/lab/presentation/test_history/test_history_scope.dart';
import 'package:material_lab/features/lab/presentation/test_history/widgets/test_history_parts.dart';

class _MockResults extends Mock implements LabResultRepository {}

class _MockLocal extends Mock implements LabLocalRepository {}

class _MockConfig extends Mock implements LabConfigurationRepository {}

Map<String, dynamic> _row(int id, String analysis) {
  // Inside the default last-24h window so the scope keeps the rows.
  final at = DateTime.now().subtract(Duration(hours: id)).toString();
  return {
    'id': id,
    'tested_at': at,
    'analysis_name': analysis,
    'sample_name': 'S$id',
    'source_name': 'Wheat',
    'source_type': 'raw_material',
    'entry_code': 'EC-$id',
    'result_text': '12.$id',
    'range_unit': '%',
    'min': 10,
    'max': 14,
    'range_state': 'in',
    'tested_by_name': 'Hana',
  };
}

/// Regression test for the grave report: pressing select-all (or long-press,
/// or tapping while selecting) must NEVER open the detail/edit screen.
/// Selection only toggles checkboxes; editors open solely from a plain tap
/// while select mode is off.
void main() {
  late _MockResults results;
  late _MockLocal local;
  late _MockConfig config;
  late List<Map<String, dynamic>> rows;
  late List<Map<String, dynamic>> opened;

  setUp(() {
    results = _MockResults();
    local = _MockLocal();
    config = _MockConfig();
    rows = [_row(1, 'Protein A'), _row(2, 'Protein B'), _row(3, 'Fat')];
    opened = [];
    when(() => results.listSampleTests()).thenAnswer((_) async => rows);
    when(() => local.listConsumptionLog()).thenAnswer((_) async => []);
    when(() => config.listAnalyses()).thenAnswer((_) async => []);
  });

  Future<void> pumpTable(
    WidgetTester tester, {
    ValueChanged<Map<String, dynamic>>? onOpenReport,
  }) async {
    final cubit = TestHistoryCubit(
      results: results,
      local: local,
      config: config,
    );
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 800),
        builder: (context, _) => MaterialApp(
          home: Scaffold(
            body: BlocProvider<TestHistoryCubit>(
              create: (_) => cubit,
            child: TestHistoryScope(
              builder: (context, scope, d) => Column(
                children: [
                  if (scope.selecting)
                    TestHistorySelectionBar(
                      rows: scope.selectedRows(d.sorted),
                      onClear: scope.clearSelection,
                    ),
                  // The rebuilt table fills the space it is given (the shared
                  // AppPaginatedTable resolves its own height), so it needs a
                  // bounded parent here exactly like the desktop tab gives it.
                  Expanded(
                    child: TestHistoryTable(
                      slice: d.paged.slice,
                      start: d.paged.start,
                      isEmpty: false,
                      selecting: scope.selecting,
                      selectedIds: scope.selectedIds,
                      onToggleSelect: (r) =>
                          scope.toggleSelected(thRowKey(r)),
                      onLongPressRow: (r) =>
                          scope.toggleSelected(thRowKey(r)),
                      onToggleSelectAll: () => scope.toggleSelectAll(
                        [for (final r in d.paged.slice) thRowKey(r)],
                      ),
                      allOnPageSelected: d.paged.slice.isNotEmpty &&
                          d.paged.slice.every(
                            (r) => scope.selectedIds.contains(thRowKey(r)),
                          ),
                      onOpen: opened.add,
                      onOpenReport: onOpenReport,
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Checkbox checkboxAt(WidgetTester tester, int index) =>
      tester.widget<Checkbox>(find.byType(Checkbox).at(index));

  testWidgets('select-all selects everything and opens nothing', (
    tester,
  ) async {
    await pumpTable(tester);
    expect(find.byType(Checkbox), findsNothing);

    // Long-press enters select mode and picks that row.
    await tester.longPress(find.text('Protein A'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(4));
    expect(opened, isEmpty);

    // Select-all checks every row — and still opens nothing.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      expect(checkboxAt(tester, i).value, isTrue);
    }
    expect(opened, isEmpty);

    // Tapping a row while selecting toggles it off — no editor.
    await tester.tap(find.text('Protein B'));
    await tester.pumpAndSettle();
    expect(checkboxAt(tester, 2).value, isFalse);
    expect(opened, isEmpty);

    // Leaving select mode restores the single-tap-opens behavior.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(find.text('Protein B'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(opened.single['id'], 2);
  });

  testWidgets('tapping the merged source+code cell opens the linked report',
      (tester) async {
    final reported = <Map<String, dynamic>>[];
    await pumpTable(tester, onOpenReport: reported.add);

    // The entry code now lives inside the Source cell; tapping it opens the
    // linked inspection (المحضر), never the lab-test editor.
    await tester.tap(find.text('EC-1'));
    await tester.pumpAndSettle();
    expect(reported, hasLength(1));
    expect(reported.single['id'], 1);
    expect(opened, isEmpty);
  });

  testWidgets('cards: long-press selects, tap toggles, never opens', (
    tester,
  ) async {
    final toggled = <Map<String, dynamic>>[];
    var selecting = false;
    final selected = <String>{};

    Future<void> pumpCards() => tester.pumpWidget(
          ScreenUtilInit(
            designSize: const Size(400, 800),
            builder: (context, _) => MaterialApp(
              home: Scaffold(
                body: TestHistoryCards(
                  slice: rows,
                  start: 0,
                  selecting: selecting,
                  selectedIds: selected,
                  onToggleSelect: toggled.add,
                  onLongPressRow: (r) {
                    selecting = true;
                    selected.add(thRowKey(r));
                  },
                  onOpen: opened.add,
                ),
              ),
            ),
          ),
        );

    await pumpCards();
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Protein A'));
    await tester.pumpAndSettle();
    expect(selected, {'id:1'});
    expect(opened, isEmpty);

    await pumpCards();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Protein A'));
    await tester.pumpAndSettle();
    expect(toggled, hasLength(1));
    expect(opened, isEmpty);
  });
}
