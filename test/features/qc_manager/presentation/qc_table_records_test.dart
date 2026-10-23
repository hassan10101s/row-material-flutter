import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/qc_manager/domain/qc_custom_table.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_table_rows_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/custom_tables/qc_table_records_screen.dart';

class _RepoMock extends Mock implements QcCustomTablesRepository {}

const _now = '2026-02-01 08:00:00';

QcCustomTable get _table => const QcCustomTable(
  tableId: 1,
  remoteId: 'tbl-1',
  title: 'Weights',
  description: 'Daily sample weights',
  createdAt: _now,
  updatedAt: _now,
);

List<QcCustomTableField> get _fields => const [
  QcCustomTableField(
    fieldId: 1,
    tableId: 1,
    remoteId: 'f-sample',
    label: 'Sample',
    colType: QcCustomColType.text,
    sortOrder: 0,
    createdAt: _now,
    updatedAt: _now,
  ),
  QcCustomTableField(
    fieldId: 2,
    tableId: 1,
    remoteId: 'f-weight',
    label: 'Weight',
    colType: QcCustomColType.number,
    sortOrder: 1,
    createdAt: _now,
    updatedAt: _now,
  ),
];

QcCustomTableRow _row(int id, String sample) => QcCustomTableRow(
  rowId: id,
  tableId: 1,
  tableRemoteId: 'tbl-1',
  remoteId: 'r$id',
  valuesJson: '{"f-sample":"$sample","f-weight":$id}',
  note: 'note $id',
  recordedAt: _now,
  recordedByName: 'Ali',
  createdAt: _now,
  updatedAt: _now,
);

/// The register opens through [QcTableRecordsScreen.open], which pulls its
/// cubit from get_it — the test installs a scoped factory and resets DI
/// afterwards (each test file runs in its own isolate).
Widget _host() => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => QcTableRecordsScreen.open(context, 1),
            child: const Text('open register'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() => AppText.useLanguage('en'));

  late _RepoMock repo;

  setUp(() {
    repo = _RepoMock();
    when(
      () => repo.getTableBundle(1),
    ).thenAnswer((_) async => (table: _table, fields: _fields));
    when(
      () => repo.listRows(
        1,
        limit: any(named: 'limit'),
        afterRowId: any(named: 'afterRowId'),
      ),
    ).thenAnswer((_) async => [_row(102, 'S2'), _row(101, 'S1')]);
    getIt.registerFactoryParam<QcTableRowsCubit, int, void>(
      (tableId, _) => QcTableRowsCubit(repo: repo, tableId: tableId),
    );
    addTearDown(getIt.reset);
  });

  group('desktop', () {
    setUp(() {
      FormFactor.debugSet(AppFormFactor.desktop);
      addTearDown(() => FormFactor.debugSet(AppFormFactor.desktop));
    });

    testWidgets('opens the register as a design-system window, not a route', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      await tester.tap(find.text('open register'));
      await tester.pumpAndSettle();

      expect(find.byType(AppWindow), findsOneWidget);
      // The window title follows the loaded definition.
      expect(find.text('Weights'), findsOneWidget);
      // One data-table column per definition field (+ meta columns).
      expect(find.text('Recorded'), findsOneWidget);
      expect(find.text('Sample'), findsOneWidget);
      expect(find.text('Weight'), findsOneWidget);
      expect(find.text('Note'), findsOneWidget);
      expect(find.text('S1'), findsOneWidget);

      // Closing is the window's ✕ — the builder route is gone.
      final darkBarrier = find.descendant(
        of: find.byType(AppWindow),
        matching: find.byIcon(Icons.close),
      );
      expect(darkBarrier, findsOneWidget);
    });

    testWidgets('rows are selectable and the selection drives export', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      await tester.tap(find.text('open register'));
      await tester.pumpAndSettle();

      expect(find.text('Export table'), findsOneWidget);

      // The checkbox column is hidden until the header reveal button.
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await tester.pump();

      // Header + two rows.
      final boxes = find.byType(Checkbox);
      expect(boxes, findsNWidgets(3));
      await tester.tap(boxes.first);
      await tester.pump();

      expect(find.text('Export (2)'), findsOneWidget);
      expect(find.text('Export table'), findsNothing);
    });
  });

  group('mobile', () {
    setUp(() {
      FormFactor.debugSet(AppFormFactor.mobile);
      addTearDown(() => FormFactor.debugSet(AppFormFactor.desktop));
    });

    testWidgets('keeps the pushed route and long-press selection', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      await tester.tap(find.text('open register'));
      await tester.pumpAndSettle();

      expect(find.byType(AppWindow), findsNothing);
      expect(find.text('Sample: S1'), findsOneWidget);
      expect(find.text('Export table'), findsOneWidget);

      await tester.longPress(find.text('Sample: S1'));
      await tester.pump();

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('Export (1)'), findsOneWidget);
    });
  });
}
