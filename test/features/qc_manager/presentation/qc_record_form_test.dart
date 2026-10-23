import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/features/qc_manager/domain/qc_custom_table.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_table_rows_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/custom_tables/qc_table_records_screen.dart';

class _RowsRepoMock extends Mock implements QcCustomTablesRepository {}

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
    required: true,
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

QcCustomTableRow _blankRow() =>
    const QcCustomTableRow(recordedAt: _now, createdAt: _now, updatedAt: _now);

/// The provider deliberately sits INSIDE the home route — i.e. below the
/// Navigator, exactly like the real screen. The record form opens as a dialog
/// (desktop) or a pushed route (phone), so it cannot reach this provider from
/// its own context; the form must receive the cubit explicitly.
Widget _host(QcTableRowsCubit cubit) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => MaterialApp(
    home: Scaffold(
      body: BlocProvider<QcTableRowsCubit>.value(
        value: cubit,
        child: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showRecordForm(context, cubit.state),
              child: const Text('open form'),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() => registerFallbackValue(_blankRow()));

  setUp(() => AppText.useLanguage('en'));

  late _RowsRepoMock repo;
  late QcTableRowsCubit cubit;

  setUp(() async {
    repo = _RowsRepoMock();
    when(
      () => repo.getTableBundle(1),
    ).thenAnswer((_) async => (table: _table, fields: _fields));
    when(
      () => repo.listRows(
        1,
        limit: any(named: 'limit'),
        afterRowId: any(named: 'afterRowId'),
      ),
    ).thenAnswer((_) async => <QcCustomTableRow>[]);
    when(() => repo.addRow(any())).thenAnswer((_) async => 1);
    cubit = QcTableRowsCubit(repo: repo, tableId: 1);
    await cubit.load();
  });

  tearDown(() => cubit.close());

  for (final factor in [AppFormFactor.desktop, AppFormFactor.mobile]) {
    testWidgets(
      'records a new sample on ${factor.name} without a provider lookup',
      (tester) async {
        FormFactor.debugSet(factor);
        addTearDown(() => FormFactor.debugSet(AppFormFactor.desktop));
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = factor.isMobile
            ? const Size(420, 900)
            : const Size(1280, 800);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_host(cubit));
        await tester.pumpAndSettle();

        await tester.tap(find.text('open form'));
        await tester.pumpAndSettle();

        // The overlay rendered its fields (this used to throw
        // "Provider<QcTableRowsCubit> not found" on save).
        expect(find.text('Sample'), findsOneWidget);
        expect(find.byType(TextFormField), findsWidgets);

        await tester.enterText(find.byType(TextFormField).first, 'S1');
        await tester.pump();

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        final row =
            verify(() => repo.addRow(captureAny())).captured.single
                as QcCustomTableRow;
        expect(row.values['f-sample'], 'S1');
        expect(row.tableRemoteId, 'tbl-1');
        expect(row.tableId, 1);
      },
    );
  }
}
