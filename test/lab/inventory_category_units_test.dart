import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/core/formula_engine.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Category ↔ unit gating: liquids take volume, powders mass, counted items
/// pieces only — enforced in the repository so no surface (dialog, route,
/// seed, sync repair) can store a mismatched pair.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  group('unitAllowedForCategory', () {
    test('accepts matching pairs', () {
      expect(unitAllowedForCategory('L', 'liquid'), isTrue);
      expect(unitAllowedForCategory('mL', 'liquid'), isTrue);
      expect(unitAllowedForCategory('kg', 'powder'), isTrue);
      expect(unitAllowedForCategory('g', 'powder'), isTrue);
      expect(unitAllowedForCategory('pc', 'count'), isTrue);
      expect(unitAllowedForCategory('PC', 'count'), isTrue);
    });

    test('rejects crossed pairs', () {
      expect(unitAllowedForCategory('g', 'liquid'), isFalse);
      expect(unitAllowedForCategory('kg', 'liquid'), isFalse);
      expect(unitAllowedForCategory('L', 'powder'), isFalse);
      expect(unitAllowedForCategory('mL', 'powder'), isFalse);
      expect(unitAllowedForCategory('pc', 'liquid'), isFalse);
      expect(unitAllowedForCategory('pc', 'powder'), isFalse);
      expect(unitAllowedForCategory('L', 'count'), isFalse);
      expect(unitAllowedForCategory('g', 'count'), isFalse);
      expect(unitAllowedForCategory('', 'liquid'), isFalse);
      expect(unitAllowedForCategory('mL', 'unknown'), isFalse);
    });

    test('labels are bilingual', () {
      final wasArabic = AppText.arabic;
      addTearDown(() => AppText.arabic = wasArabic);
      AppText.useLanguage('en');
      expect(inventoryCategoryLabel('liquid'), 'Liquid');
      expect(inventoryCategoryLabel('powder'), 'Powder');
      expect(inventoryCategoryLabel('count'), 'Count');
    });

    test('unit infers its category', () {
      expect(LabRepo.inventoryCategoryForUnit('L'), 'liquid');
      expect(LabRepo.inventoryCategoryForUnit('mL'), 'liquid');
      expect(LabRepo.inventoryCategoryForUnit('kg'), 'powder');
      expect(LabRepo.inventoryCategoryForUnit('g'), 'powder');
      expect(LabRepo.inventoryCategoryForUnit('pc'), 'count');
    });
  });

  group('inventory validation', () {
    late Directory tmp;
    late DatabaseHelper dbHelper;
    late LabRepo repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('matlab_cat_units');
      dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
      await dbHelper.database;
      repo = LabRepo(dbHelper: dbHelper);
    });

    tearDown(() async {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows keeps the file handle around; the temp dir is disposable.
      }
    });

    test('add accepts matching pairs incl. count/pc', () async {
      final liquid = await repo.addInventoryItem(
        name: 'Acid',
        category: 'liquid',
        unit: 'mL',
        qty: 10,
        minQty: 1,
      );
      expect(liquid['unit'], 'mL');
      final powder = await repo.addInventoryItem(
        name: 'Salt',
        category: 'powder',
        unit: 'kg',
        qty: 10,
        minQty: 1,
      );
      expect(powder['unit'], 'kg');
      final counted = await repo.addInventoryItem(
        name: 'Tablet',
        category: 'count',
        unit: 'pc',
        qty: 10,
        minQty: 1,
      );
      expect(counted['category'], 'count');
    });

    test('add rejects crossed pairs', () async {
      expect(
        () => repo.addInventoryItem(
          name: 'Acid',
          category: 'liquid',
          unit: 'g',
          qty: 1,
          minQty: 0,
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => repo.addInventoryItem(
          name: 'Salt',
          category: 'powder',
          unit: 'L',
          qty: 1,
          minQty: 0,
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => repo.addInventoryItem(
          name: 'Tablet',
          category: 'count',
          unit: 'L',
          qty: 1,
          minQty: 0,
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => repo.addInventoryItem(
          name: 'Tablet2',
          category: 'count',
          unit: 'g',
          qty: 1,
          minQty: 0,
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('update validates the effective pair', () async {
      final item = await repo.addInventoryItem(
        name: 'Acid',
        category: 'liquid',
        unit: 'mL',
        qty: 10,
        minQty: 1,
      );
      final id = (item['id'] as num).toInt();
      // Category change alone keeps the old unit -> must fail.
      expect(
        () => repo.updateInventoryItem(id, {'category': 'powder'}),
        throwsA(isA<ValidationError>()),
      );
      // Fixing both together passes.
      final fixed = await repo.updateInventoryItem(id, {
        'category': 'powder',
        'unit': 'g',
      });
      expect(fixed['category'], 'powder');
      expect(fixed['unit'], 'g');
    });

    test('legacy CHECK migrates: count stores and pc rows normalize',
        () async {
      final db = await dbHelper.database;
      // Simulate a pre-count install: old two-value CHECK.
      await db.execute('DROP TABLE lab_inventory');
      await db.execute('''
        CREATE TABLE lab_inventory (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE,
          category TEXT CHECK(category IN ('liquid', 'powder')),
          unit TEXT,
          current_qty REAL NOT NULL DEFAULT 0,
          min_qty REAL NOT NULL DEFAULT 0,
          description TEXT,
          created_by INTEGER,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      const ts = '2026-09-01T07:00:00.000';
      final tabletId = await db.insert('lab_inventory', {
        'name': 'Tablet',
        'category': 'powder',
        'unit': 'pc',
        'current_qty': 10,
        'min_qty': 1,
        'created_at': ts,
        'updated_at': ts,
      });
      await dbHelper.close();

      // Reopen through a fresh helper on the same file: guarantees run,
      // the CHECK widens, and the pc row normalizes to `count`.
      final helper2 = DatabaseHelper(_FakeAppPaths(tmp.path));
      final db2 = await helper2.database;
      try {
        await db2.insert('lab_inventory', {
          'name': 'Vial',
          'category': 'count',
          'unit': 'pc',
          'current_qty': 5,
          'min_qty': 1,
          'created_at': ts,
          'updated_at': ts,
        });
        final rows = await db2.query(
          'lab_inventory',
          where: 'id = ?',
          whereArgs: [tabletId],
        );
        expect(rows.single['category'], 'count');
        expect(rows.single['unit'], 'pc');
      } finally {
        await helper2.close();
      }
    });

    test('analysis items must fit the linked inventory category', () async {
      final liquid = await repo.addInventoryItem(
        name: 'Acid',
        category: 'liquid',
        unit: 'mL',
        qty: 100,
        minQty: 1,
      );
      final liquidId = (liquid['id'] as num).toInt();
      expect(
        () => repo.createAnalysis(
          name: 'Mismatch analysis',
          items: [
            {'inventory_id': liquidId, 'qty_per_sample': 5, 'unit': 'g'},
          ],
        ),
        throwsA(isA<ValidationError>()),
      );
      final ok = await repo.createAnalysis(
        name: 'Match analysis',
        items: [
          {'inventory_id': liquidId, 'qty_per_sample': 5, 'unit': 'mL'},
        ],
      );
      expect(ok['name'], 'Match analysis');
    });
  });
}
