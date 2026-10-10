import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/qc_manager/data/qc_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_inspection_sheet_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_inspections_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/inspections/qc_inspections_screen.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;
  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

class _GateMock extends Mock implements AuthGate {}

/// Thin read-path adapters: the concrete local repos do not implement the
/// domain interfaces (the offline-first facades do), and this repro only
/// needs the reads, so delegate those and fail loudly on anything else.
class _Inspections implements QcInspectionRepository {
  _Inspections(this.local);
  final QcInspectionRepo local;

  @override
  Future<List<QcInspection>> listInspections({
    int? templateId,
    String status = '',
    String refType = '',
    String refId = '',
    String lotNo = '',
    String dept = '',
    int limit = 100,
    int offset = 0,
  }) => local.listInspections(
    templateId: templateId,
    status: status,
    refType: refType,
    refId: refId,
    lotNo: lotNo,
    dept: dept,
    limit: limit,
    offset: offset,
  );

  @override
  Future<QcInspection?> getInspection(int inspectionId) =>
      local.getInspection(inspectionId);

  @override
  Future<List<QcResponse>> listResponses(int inspectionId) =>
      local.listResponses(inspectionId);

  @override
  Future<List<QcFindingNc>> listFindings(int inspectionId) =>
      local.listFindings(inspectionId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Templates implements QcTemplateRepository {
  _Templates(this.local);
  final QcTemplateRepo local;

  @override
  Future<({QcTemplate template, List<QcSection> sections, List<QcItem> items})?>
  getTemplateTree(int templateId) => local.getTemplateTree(templateId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _NcCapa implements QcNcCapaRepository {
  _NcCapa(this.local);
  final QcNcCapaRepo local;

  @override
  Future<List<QcFindingNc>> listFindings({
    String status = '',
    String severity = '',
    String assignedTo = '',
    String inspectionId = '',
    bool overdueOnly = false,
    int limit = 200,
    int offset = 0,
  }) => local.listFindings(
    status: status,
    severity: severity,
    assignedTo: assignedTo,
    inspectionId: inspectionId,
    overdueOnly: overdueOnly,
    limit: limit,
    offset: offset,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Regression: drives the Quality entry (register + sheet) with a REAL
/// database instead of mocks, to surface crashes that only real rows
/// trigger. Covers the sheet-open `RenderFlex` unbounded-width crash and the
/// lazy-controller dispose crash (see `qc_sheet_mock_data_test.dart`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();
  setUpAll(() => registerFallbackValue(Permission.qcWrite));

  late Directory tmp;
  late DatabaseHelper helper;
  late QcInspectionRepo inspectionsLocal;
  late QcTemplateRepo templatesLocal;
  late QcNcCapaRepo ncCapaLocal;
  late _Inspections inspections;
  late _Templates templates;
  late _NcCapa ncCapa;

  setUp(() async {
    AppText.arabic = false;
    tmp = await Directory.systemTemp.createTemp('matlab_qc_repro');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    await helper.database;
    templatesLocal = QcTemplateRepo(helper);
    inspectionsLocal = QcInspectionRepo(helper);
    ncCapaLocal = QcNcCapaRepo(helper);
    inspections = _Inspections(inspectionsLocal);
    templates = _Templates(templatesLocal);
    ncCapa = _NcCapa(ncCapaLocal);

    const now = '2026-05-01 08:00:00';
    final templateId = await templatesLocal.createTemplate(
      QcTemplate(
        name: 'Incoming Steel',
        type: QcTemplateType.incoming,
        isPublished: true,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final db = await helper.database;
    final sectionId = await db.insert('qc_sections', {
      'template_id': templateId,
      'title': 'Visual',
      'order_index': 0,
    });
    await db.insert('qc_items', {
      'section_id': sectionId,
      'template_id': templateId,
      'label': 'No rust',
      'item_type': 'passfail',
      'order_index': 0,
    });
    await db.insert('qc_items', {
      'section_id': sectionId,
      'template_id': templateId,
      'label': 'Thickness',
      'item_type': 'number',
      'min_value': 1.0,
      'max_value': 5.0,
      'unit': 'mm',
      'order_index': 1,
    });
    await inspectionsLocal.createInspection(
      QcInspection(
        templateId: templateId,
        refType: QcRefType.lot,
        lotNo: 'LOT-9',
        inspectionDate: '2026-05-01',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final gate = _GateMock();
    when(() => gate.canWrite(any())).thenReturn(true);
    getIt.registerSingleton<AuthGate>(gate);
    getIt.registerFactoryParam<QcInspectionSheetCubit, int, void>(
      (id, _) => QcInspectionSheetCubit(
        repo: inspections,
        templates: templates,
        ncCapa: ncCapa,
        inspectionId: id,
      ),
    );
  });

  tearDown(() async {
    if (getIt.isRegistered<AuthGate>()) getIt.unregister<AuthGate>();
    if (getIt.isRegistered<QcInspectionSheetCubit>()) {
      getIt.unregister<QcInspectionSheetCubit>();
    }
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
    AppText.arabic = true;
  });

  Widget host(Widget child, QcInspectionsCubit cubit) => ScreenUtilInit(
    designSize: const Size(1280, 720),
    builder: (context, _) => BlocProvider.value(
      value: cubit,
      child: MaterialApp(home: child),
    ),
  );

  /// Real-database I/O on desktop is slow (seconds for the first queries),
  /// and the loading spinner animates forever, so `pumpAndSettle` can never
  /// settle while it is up. Fake-clock pumps alone do not let real I/O
  /// finish, and a bare `Future.delayed` in a widget test runs on the fake
  /// clock (it never elapses) — so wait in real time via `runAsync`, then
  /// pump a frame, until the expected content appears.
  ///
  /// Evaluation itself can throw while the tree is mid-rebuild, so treat a
  /// throwing evaluation as "not there yet".
  Future<void> settleOn(Finder finder, WidgetTester tester) async {
    for (var i = 0; i < 100; i++) {
      var found = false;
      try {
        found = finder.evaluate().isNotEmpty;
      } catch (_) {
        found = false;
      }
      if (found) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
    }
  }

  test('diagnostic: repo read mirrors what the cubit sees', () async {
    final rows = await inspections.listInspections();
    // ignore: avoid_print
    print('DIAG rows=${rows.length} first=${rows.isEmpty ? null : rows.first}');
    final cubit = QcInspectionsCubit(repo: inspections, templates: templates);
    addTearDown(cubit.close);
    await cubit.load();
    // ignore: avoid_print
    print(
      'DIAG cubit inspections=${cubit.state.inspections.length} '
      'error=${cubit.state.error}',
    );
    expect(cubit.state.error, isNull);
  });

  testWidgets('quality register lists a real inspection row', (tester) async {
    final cubit = QcInspectionsCubit(repo: inspections, templates: templates)
      ..load();
    addTearDown(cubit.close);
    await tester.pumpWidget(host(const QcInspectionsScreen(), cubit));
    await settleOn(find.text('LOT-9'), tester);
    expect(find.text('LOT-9'), findsOneWidget);
  });

  testWidgets('opening a real sheet renders its items', (tester) async {
    final cubit = QcInspectionsCubit(repo: inspections, templates: templates)
      ..load();
    addTearDown(cubit.close);
    await tester.pumpWidget(host(const QcInspectionsScreen(), cubit));
    await settleOn(find.text('LOT-9'), tester);
    await tester.tap(find.text('LOT-9'));
    await settleOn(find.text('No rust'), tester);
    expect(find.text('No rust'), findsOneWidget);
    expect(find.text('Thickness'), findsOneWidget);
  });
}
