import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/constants/app_errors.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/core/test_history_logic.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/lab/presentation/test_history/test_history_print.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  group('thRowKey — stable selection identity', () {
    test('prefers the database id', () {
      expect(
        thRowKey({'id': 5, 'entry_code': 'EC-1'}),
        'id:5',
      );
    });

    test('falls back to entry-code/time/analysis without an id', () {
      expect(
        thRowKey({
          'entry_code': 'EC-1',
          'tested_at': '2026-01-01',
          'analysis_name': 'Protein',
        }),
        'ec:EC-1_2026-01-01_Protein',
      );
    });

    test('two different rows never share a key', () {
      final a = thRowKey({'id': 1});
      final b = thRowKey({'id': 2});
      final c = thRowKey({'entry_code': 'EC-1'});
      expect({a, b, c}.length, 3);
    });
  });

  group('TestHistoryPrinter.buildHtml', () {
    final rows = [
      {
        'id': 1,
        'tested_at': '2026-01-01T10:00:00',
        'analysis_name': 'Protein',
        'sample_name': 'S1<script>',
        'source_name': 'Wheat',
        'source_type': 'raw_material',
        'entry_code': 'EC-1',
        'result_text': '12.5',
        'range_unit': '%',
        'min': 10,
        'max': 14,
        'range_state': 'in',
        'tested_by_name': 'Hana',
      },
    ];

    test('arabic document escapes values and offers print', () {
      AppText.useLanguage('ar');
      addTearDown(() => AppText.useLanguage('ar'));
      final html = TestHistoryPrinter.buildHtml(rows);
      expect(html, contains('dir="rtl"'));
      expect(html, contains('window.print()'));
      expect(html, contains('S1&lt;script&gt;'));
      expect(html, isNot(contains('<script>')));
      expect(html, contains('Protein'));
      expect(html, contains('EC-1'));
    });

    test('english document flips direction and labels', () {
      AppText.useLanguage('en');
      addTearDown(() => AppText.useLanguage('ar'));
      final html = TestHistoryPrinter.buildHtml(rows);
      expect(html, contains('dir="ltr"'));
      expect(html, contains('Records: 1'));
      expect(html, contains('<th>Time</th>'));
    });
  });

  group('updateSampleTest — link-key and consumption safety', () {
    final tmp = Directory.systemTemp.createTempSync('matlab_edit_safety');
    late DatabaseHelper dbHelper;
    late LabRepo repo;
    late Database db;
    late int titerId;
    late int analysisId;

    Future<Map<String, dynamic>> testRow(int id) async {
      final rows = await db.query(
        'lab_sample_tests',
        where: 'id = ?',
        whereArgs: [id],
      );
      return rows.single;
    }

    Future<double> titerQty() async {
      final rows = await db.query(
        'lab_inventory',
        where: 'id = ?',
        whereArgs: [titerId],
      );
      return double.parse('${rows.single['current_qty']}');
    }

    Future<List<Map<String, dynamic>>> logs(int testId) async {
      return db.query(
        'lab_consumption_log',
        where: 'sample_test_id = ?',
        whereArgs: [testId],
        orderBy: 'id ASC',
      );
    }

    setUpAll(() async {
      dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
      db = await dbHelper.database;
      repo = LabRepo(dbHelper: dbHelper);
      final ts = nowIso();
      titerId = await db.insert('lab_inventory', {
        'name': 'NaOH 0.1M', 'category': 'liquid', 'unit': 'mL',
        'current_qty': 40, 'min_qty': 0, 'created_at': ts, 'updated_at': ts,
      });
      final created = await repo.createAnalysis(
        name: 'Protein',
        unit: '%',
        dynamicFields: ['Sample Name', 'Titer'],
        fieldChemicalLinks: [
          {
            'dynamic_field': 'Titer',
            'kind': 'link',
            'inventory_id': titerId,
            'unit': 'mL',
          },
        ],
      );
      analysisId = created['id'] as int;
    });

    tearDownAll(() async {
      await dbHelper.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('rewriting a set entry code is refused and changes nothing',
        () async {
      final result = await repo.runSampleTest(
        analysisId: analysisId,
        sourceType: 'raw_material',
        sourceName: 'Wheat',
        sampleName: 'S1',
        dynamicValues: {'Titer': '1'},
        user: null,
      );
      final testId = (result['test'] as Map)['id'] as int;
      // Simulate a linked record (the run flow stores the code at creation).
      await db.update(
        'lab_sample_tests',
        {'entry_code': 'EC-1'},
        where: 'id = ?',
        whereArgs: [testId],
      );

      await expectLater(
        repo.updateSampleTest(testId, entryCode: 'EC-2'),
        throwsA(isA<ValidationError>().having(
          (e) => e.message,
          'message',
          contains(AppErrors.entryCodeImmutable),
        )),
      );
      expect((await testRow(testId))['entry_code'], 'EC-1');
    });

    test('repeating the same entry code is allowed', () async {
      final result = await repo.runSampleTest(
        analysisId: analysisId,
        sourceType: 'raw_material',
        sourceName: 'Wheat',
        sampleName: 'S2',
        dynamicValues: {'Titer': '1'},
        user: null,
      );
      final testId = (result['test'] as Map)['id'] as int;
      await db.update(
        'lab_sample_tests',
        {'entry_code': 'EC-9'},
        where: 'id = ?',
        whereArgs: [testId],
      );
      final updated = await repo.updateSampleTest(
        testId,
        entryCode: 'EC-9',
        sampleName: 'S2b',
      );
      expect(updated['entry_code'], 'EC-9');
      expect(updated['sample_name'], 'S2b');
    });

    test('linking an empty code to a missing inspection is refused',
        () async {
      final result = await repo.runSampleTest(
        analysisId: analysisId,
        sourceType: 'raw_material',
        sourceName: 'Wheat',
        sampleName: 'S3',
        user: null,
      );
      final testId = (result['test'] as Map)['id'] as int;
      await expectLater(
        repo.updateSampleTest(testId, entryCode: 'NOPE'),
        throwsA(isA<ValidationError>()),
      );
      expect('${(await testRow(testId))['entry_code'] ?? ''}', isEmpty);
    });

    test('correcting dynamic values posts a consumption delta', () async {
      // Reset through lots (the pool is SUM(lots): writing it directly
      // would diverge from the lots and the next refresh would undo it).
      await db.delete(
        'inventory_lots',
        where: 'inventory_id = ?',
        whereArgs: [titerId],
      );
      await repo.receiveLot(
        inventoryId: titerId,
        qty: 40,
        expiryDate: '2027-01-01',
        executor: db,
      );
      final result = await repo.runSampleTest(
        analysisId: analysisId,
        sourceType: 'raw_material',
        sourceName: 'Wheat',
        sampleName: 'S4',
        dynamicValues: {'Titer': '3'},
        user: null,
      );
      final testId = (result['test'] as Map)['id'] as int;
      expect(await titerQty(), 37.0);

      await repo.updateSampleTest(testId, dynamicValues: {'Titer': '5'});
      expect(await titerQty(), 35.0, reason: '+2 consumed by the correction');
      final afterUp = await logs(testId);
      expect(
        afterUp.last,
        containsPair('event_type', 'CONSUMPTION'),
      );

      await repo.updateSampleTest(testId, dynamicValues: {'Titer': '4'});
      expect(await titerQty(), 36.0, reason: '-1 reversed by the correction');
      final afterDown = await logs(testId);
      expect(afterDown.last['event_type'], 'REVERSAL');
    });

    test('an uncovered increase refuses the whole edit', () async {
      await db.delete(
        'inventory_lots',
        where: 'inventory_id = ?',
        whereArgs: [titerId],
      );
      await repo.refreshInventoryCache(db, titerId);
      final result = await repo.runSampleTest(
        analysisId: analysisId,
        sourceType: 'raw_material',
        sourceName: 'Wheat',
        sampleName: 'S5',
        dynamicValues: {'Titer': '0'},
        user: null,
      );
      final testId = (result['test'] as Map)['id'] as int;

      await expectLater(
        repo.updateSampleTest(
          testId,
          resultText: '99.9',
          dynamicValues: {'Titer': '50'},
        ),
        throwsA(isA<ValidationError>().having(
          (e) => e.message,
          'message',
          contains(AppErrors.insufficientStock),
        )),
      );
      // Plan-before-patch: the text correction saved nothing either.
      expect('${(await testRow(testId))['result_text'] ?? ''}', isNot('99.9'));
      expect(await titerQty(), 0.0);
    });
  });
}
