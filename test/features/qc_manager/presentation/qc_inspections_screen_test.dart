import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_inspections_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/inspections/qc_inspections_screen.dart';

class _InspectionsMock extends Mock implements QcInspectionRepository {}

/// The register hides "new inspection" behind a session permission check, so a
/// test has to answer it rather than assume the default.
class _GateMock extends Mock implements AuthGate {}

const _now = '2026-02-01 08:00:00';

QcInspection _row({
  int? id = 1,
  String status = QcInspectionStatus.inProgress,
  String result = QcOverallResult.pending,
  String lotNo = 'LOT-77',
  String inspector = 'Hana',
  double? score,
  int ncCount = 0,
  bool hasNc = false,
}) => QcInspection(
  inspectionId: id,
  templateId: 4,
  templateVersion: 2,
  refType: QcRefType.lot,
  lotNo: lotNo,
  status: status,
  resultOverall: result,
  scorePct: score,
  hasNc: hasNc,
  ncCount: ncCount,
  inspectorId: 'u1',
  inspectorName: inspector,
  inspectionDate: '2026-02-01',
  createdAt: _now,
  updatedAt: _now,
);

/// Stubs the register read so the fake honours the arguments it was called with,
/// the way SQL would.
void _stubRows(_InspectionsMock repo, List<QcInspection> rows) {
  when(
    () => repo.listInspections(
      templateId: any(named: 'templateId'),
      status: any(named: 'status'),
      refType: any(named: 'refType'),
      refId: any(named: 'refId'),
      lotNo: any(named: 'lotNo'),
      dept: any(named: 'dept'),
      limit: any(named: 'limit'),
      offset: any(named: 'offset'),
    ),
  ).thenAnswer((invocation) async {
    final status = invocation.namedArguments[#status] as String;
    final lotNo = invocation.namedArguments[#lotNo] as String;
    var out = rows;
    if (status.isNotEmpty) {
      out = out.where((r) => r.status == status).toList();
    }
    if (lotNo.isNotEmpty) {
      out = out.where((r) => r.lotNo == lotNo).toList();
    }
    return out;
  });
  when(
    () => repo.countInspections(
      status: any(named: 'status'),
      refType: any(named: 'refType'),
      refId: any(named: 'refId'),
    ),
  ).thenAnswer((_) async => rows.length);
}

Widget _host(Widget child, QcInspectionsCubit cubit) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => BlocProvider.value(
    value: cubit,
    child: MaterialApp(home: child),
  ),
);

void main() {
  setUp(() => AppText.arabic = false);
  tearDownAll(() => AppText.arabic = true);
  setUpAll(() {
    registerFallbackValue(_row());
    registerFallbackValue(Permission.qcWrite);
  });

  late _GateMock gate;

  /// Registers a session and answers the one permission the register asks.
  void registerGate({bool canWrite = true}) {
    gate = _GateMock();
    when(() => gate.canWrite(any())).thenReturn(canWrite);
    getIt.registerSingleton<AuthGate>(gate);
    addTearDown(() => getIt.unregister<AuthGate>());
  }

  group('QcInspectionsScreen', () {
    late _InspectionsMock repo;
    late QcInspectionsCubit cubit;

    setUp(() {
      repo = _InspectionsMock();
      cubit = QcInspectionsCubit(repo: repo);
      registerGate();
    });

    tearDown(() => cubit.close());

    testWidgets('an empty register explains itself', (tester) async {
      _stubRows(repo, []);
      await cubit.load();
      await tester.pumpWidget(_host(const QcInspectionsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('No inspections yet'), findsOneWidget);
    });

    testWidgets('a filtered register says so rather than "none yet"', (
      tester,
    ) async {
      _stubRows(repo, []);
      await cubit.applyFilters(const QcInspectionFilters(statuses: {'draft'}));
      await tester.pumpWidget(_host(const QcInspectionsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('No inspections match these filters'), findsOneWidget);
    });

    testWidgets('each row shows its reference, status and result in words', (
      tester,
    ) async {
      _stubRows(repo, [
        _row(),
        _row(
          id: 2,
          status: QcInspectionStatus.submitted,
          result: QcOverallResult.conditional,
          lotNo: 'LOT-78',
        ),
      ]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcInspectionsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.textContaining('LOT-77'), findsOneWidget);
      expect(find.textContaining('LOT-78'), findsOneWidget);
      // The pill label is the translated word, not the stored constant.
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('Submitted'), findsOneWidget);
      expect(find.text('Conditional'), findsOneWidget);
    });

    testWidgets('the summary strip counts the rows in scope', (tester) async {
      _stubRows(repo, [
        _row(),
        _row(id: 2, status: QcInspectionStatus.submitted),
        _row(id: 3, status: QcInspectionStatus.reviewed),
      ]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcInspectionsScreen(), cubit));
      await tester.pumpAndSettle();

      // 3 total, 1 in progress, 2 with an open NC is not what this data says.
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('a soft-deleted or unreadable sheet reports a failure', (
      tester,
    ) async {
      when(
        () => repo.listInspections(
          templateId: any(named: 'templateId'),
          status: any(named: 'status'),
          refType: any(named: 'refType'),
          refId: any(named: 'refId'),
          lotNo: any(named: 'lotNo'),
          dept: any(named: 'dept'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenThrow(StateError('database is locked'));
      final cubit = QcInspectionsCubit(repo: repo);
      addTearDown(cubit.close);
      await tester.pumpWidget(_host(const QcInspectionsScreen(), cubit));
      // The failure has to arrive *after* the screen is listening, which is what
      // a real one does on first load or a pull-to-refresh.
      await cubit.load();
      await tester.pumpAndSettle();

      // A read failure shown as "no inspections" would read as success.
      expect(find.textContaining('database is locked'), findsOneWidget);
      expect(find.text('No inspections yet'), findsNothing);
    });

    testWidgets('the filter sheet applies a status and reloads', (
      tester,
    ) async {
      _stubRows(repo, [_row()]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcInspectionsScreen(), cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'Submitted'));
      await tester.pumpAndSettle();

      // The sheet edits a draft; nothing is applied until Apply.
      expect(cubit.state.filters.statuses, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(cubit.state.filters.statuses, {QcInspectionStatus.submitted});
      expect(find.textContaining('LOT-77'), findsNothing);
      expect(find.text('No inspections match these filters'), findsOneWidget);
    });
  });
}
