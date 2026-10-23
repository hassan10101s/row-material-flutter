import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspections_cubit.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

class _ReportServiceMock extends Mock implements ReportRepository {}

Future<void> _insert(
  DatabaseHelper helper, {
  required String entryCode,
  required String date,
  String status = 'PENDING',
  String kind = 'raw',
  String reason = '',
}) async {
  final db = await helper.database;
  await db.insert('inspections', {
    'entry_code': entryCode,
    'material_id': 1,
    'material_name': 'Wheat',
    'material_code': 'W1',
    'inspection_date': date,
    'specialist_name': 'tester',
    'physical_results_json': '{}',
    'chemical_results_json': '{}',
    'physical_reference_json': '{}',
    'chemical_reference_json': '{}',
    'decision_status': status,
    'decision_reason': reason,
    'snapshot_json': '{}',
    'sample_names_json': '[]',
    'created_by': 0,
    'created_by_name': '',
    'created_at': '${date}T08:00:00',
    'updated_at': '${date}T08:00:00',
    'inspection_kind': kind,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  group('InspectionRepo date filters (real DB)', () {
    late Directory tmp;
    late DatabaseHelper helper;
    late InspectionRepo repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('matlab_insp_filter');
      helper = DatabaseHelper(_FakeAppPaths(tmp.path));
      final db = await helper.database;
      await db.insert('reference_materials', {
        'material_name': 'Wheat',
        'material_code': 'W1',
        'physical_reference_json': '{}',
        'chemical_reference_json': '{}',
        'imported_at': '2026-01-01T00:00:00',
        'active': 1,
      });
      await _insert(helper, entryCode: 'E-001', date: '2026-09-01');
      await _insert(helper, entryCode: 'E-002', date: '2026-09-15');
      await _insert(
        helper,
        entryCode: 'E-003',
        date: '2026-10-01',
        status: 'APPROVED',
      );
      repo = InspectionRepo(
        dbHelper: helper,
        referenceRepo: ReferenceRepo(dbHelper: helper),
      );
    });

    tearDown(() async {
      await helper.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('no bounds returns everything', () async {
      expect((await repo.list()).map((r) => r['entry_code']), hasLength(3));
      expect(await repo.count(), 3);
    });

    test('materialId filters by material, unknown id matches nothing',
        () async {
      expect(
        (await repo.list(materialId: 1)).map((r) => r['entry_code']),
        hasLength(3),
      );
      expect(await repo.count(materialId: 1), 3);
      expect(await repo.list(materialId: 999), isEmpty);
      expect(await repo.count(materialId: 999), 0);
    });

    test('productId filters product inspections only', () async {
      // Fixtures are raw inspections (`product_id` NULL): nothing matches.
      expect(await repo.list(productId: 1), isEmpty);
      expect(await repo.count(productId: 1), 0);
    });

    test('dateFrom drops older rows in list and count', () async {
      final rows = await repo.list(dateFrom: '2026-09-15');
      expect(
        rows.map((r) => r['entry_code']),
        containsAll(['E-002', 'E-003']),
      );
      expect(rows, hasLength(2));
      expect(await repo.count(dateFrom: '2026-09-15'), 2);
    });

    test('dateTo drops newer rows in list and count', () async {
      final rows = await repo.list(dateTo: '2026-09-15');
      expect(rows.map((r) => r['entry_code']), containsAll(['E-001', 'E-002']));
      expect(rows, hasLength(2));
      expect(await repo.count(dateTo: '2026-09-15'), 2);
    });

    test('closed range is inclusive on both ends', () async {
      final rows = await repo.list(
        dateFrom: '2026-09-15',
        dateTo: '2026-09-15',
      );
      expect(rows.map((r) => r['entry_code']), ['E-002']);
      expect(
        await repo.count(dateFrom: '2026-09-15', dateTo: '2026-09-15'),
        1,
      );
    });

    test('dates combine with status', () async {
      final rows = await repo.list(
        status: 'APPROVED',
        dateFrom: '2026-09-01',
      );
      expect(rows.map((r) => r['entry_code']), ['E-003']);
      expect(
        await repo.count(status: 'APPROVED', dateFrom: '2026-09-01'),
        1,
      );
    });

    test('short/malformed bounds are ignored, never throw', () async {
      expect((await repo.list(dateFrom: '2026', dateTo: '')), hasLength(3));
      expect(await repo.count(dateFrom: 'x', dateTo: 'y'), 3);
    });

    test('reason matches decision_reason substring in list and count',
        () async {
      await _insert(
        helper,
        entryCode: 'E-004',
        date: '2026-10-02',
        reason: 'سوس',
      );
      await _insert(
        helper,
        entryCode: 'E-005',
        date: '2026-10-02',
        reason: 'رطوبة عالية',
      );
      // Substring, not exact: «سوس» inside «سوسة» still matches.
      await _insert(
        helper,
        entryCode: 'E-006',
        date: '2026-10-02',
        reason: 'إصابة سوسة',
      );
      expect(
        (await repo.list(reason: 'سوس')).map((r) => r['entry_code']),
        containsAll(['E-004', 'E-006']),
      );
      expect(await repo.count(reason: 'سوس'), 2);
      expect(
        (await repo.list(reason: 'رطوبة')).map((r) => r['entry_code']),
        ['E-005'],
      );
      expect(await repo.count(reason: 'رطوبة'), 1);
      expect(await repo.list(reason: 'مفيش'), isEmpty);
      expect(await repo.count(reason: 'مفيش'), 0);
      // Blank reason is a no-op (the whole register comes back).
      expect(await repo.count(reason: '   '), 6);
    });
  });

  group('InspectionsCubit filter actions', () {
    test('applyFilters stores dates and refetches', () async {
      final repo = _RepoMock();
      when(() => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
          )).thenAnswer((_) async => const []);
      when(() => repo.count(
            query: any(named: 'query'),
            status: any(named: 'status'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
          )).thenAnswer((_) async => 0);
      final cubit = InspectionsCubit(repo: repo, reports: _ReportServiceMock());
      await cubit.applyFilters(
        status: 'APPROVED',
        dateFrom: '2026-09-01',
        dateTo: '2026-09-30',
        materialId: null,
        materialName: '',
      );
      expect(cubit.state.status, 'APPROVED');
      expect(cubit.state.dateFrom, '2026-09-01');
      expect(cubit.state.dateTo, '2026-09-30');
      verify(() => repo.list(
            query: any(named: 'query'),
            status: 'APPROVED',
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: '2026-09-01',
            dateTo: '2026-09-30',
          )).called(1);
      await cubit.close();
    });

    test('clearFilters resets status+dates and clearChip removes one group',
        () async {
      final repo = _RepoMock();
      when(() => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
          )).thenAnswer((_) async => const []);
      when(() => repo.count(
            query: any(named: 'query'),
            status: any(named: 'status'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
          )).thenAnswer((_) async => 0);
      final cubit = InspectionsCubit(repo: repo, reports: _ReportServiceMock());
      await cubit.applyFilters(
        status: 'APPROVED',
        dateFrom: '2026-09-01',
        dateTo: '2026-09-30',
        materialId: null,
        materialName: '',
      );
      await cubit.clearChip('dates');
      expect(cubit.state.dateFrom, isEmpty);
      expect(cubit.state.dateTo, isEmpty);
      expect(cubit.state.status, 'APPROVED');
      await cubit.clearFilters();
      expect(cubit.state.status, isEmpty);
      await cubit.close();
    });

    test('material filter passes materialId through and clearChip removes it',
        () async {
      final repo = _RepoMock();
      when(() => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            materialId: any(named: 'materialId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => const []);
      when(() => repo.count(
            query: any(named: 'query'),
            status: any(named: 'status'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            materialId: any(named: 'materialId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => 0);
      final cubit = InspectionsCubit(repo: repo, reports: _ReportServiceMock());
      await cubit.applyFilters(
        status: '',
        dateFrom: '',
        dateTo: '',
        materialId: 7,
        materialName: 'Wheat',
      );
      expect(cubit.state.materialId, 7);
      expect(cubit.state.materialName, 'Wheat');
      verify(() => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            materialId: 7,
            productId: null,
          )).called(1);
      await cubit.clearChip('material');
      expect(cubit.state.materialId, isNull);
      expect(cubit.state.materialName, isEmpty);
      verify(() => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            materialId: null,
            productId: null,
          )).called(1);
      await cubit.close();
    });

    test('reason filter passes decision_reason through and clearChip removes it',
        () async {
      final repo = _RepoMock();
      when(() => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            reason: any(named: 'reason'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            materialId: any(named: 'materialId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => const []);
      when(() => repo.count(
            query: any(named: 'query'),
            status: any(named: 'status'),
            reason: any(named: 'reason'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            materialId: any(named: 'materialId'),
            productId: any(named: 'productId'),
          )).thenAnswer((_) async => 0);
      final cubit = InspectionsCubit(repo: repo, reports: _ReportServiceMock());
      await cubit.applyFilters(
        status: '',
        reason: 'سوس',
        dateFrom: '',
        dateTo: '',
        materialId: null,
        materialName: '',
      );
      expect(cubit.state.reason, 'سوس');
      verify(() => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            reason: 'سوس',
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            materialId: null,
            productId: null,
          )).called(1);
      await cubit.clearChip('reason');
      expect(cubit.state.reason, isEmpty);
      await cubit.close();
    });
  });
}

class _RepoMock extends Mock implements InspectionRepository {}
