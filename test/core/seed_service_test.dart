import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/services/seed_service.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Builds a one-sheet `.xlsx` in memory so the import can be driven from a
/// fixture instead of the shipped asset. `rootBundle` is `final`, so the only
/// seam is the `flutter/assets` platform channel [PlatformAssetBundle] reads.
ByteData workbook(List<List<String>> rows) {
  final excel = Excel.createExcel();
  final sheet = excel['Sheet1'];
  for (final row in rows) {
    sheet.appendRow([for (final cell in row) TextCellValue(cell)]);
  }
  final bytes = excel.save() ?? const <int>[];
  return ByteData.sublistView(Uint8List.fromList(bytes));
}

/// Replaces the asset channel with [assets]; a key that is absent 404s, which is
/// exactly what `PlatformAssetBundle.load` raises on for a missing file.
void serveAssets(Map<String, ByteData> assets) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (ByteData? message) async {
    final key = utf8.decode(message!.buffer.asUint8List());
    return assets[key];
  });
}

const String referenceAsset = 'assets/Reference.xlsx';
const String unitsAsset = 'assets/units.xlsx';

/// The four headers `importReference` insists on, in the order the service
/// builds its header index from.
const List<String> referenceHeaders = [
  'Raw_Material_Name',
  'Physical_Aspects_Reference',
  'Chemical_Analysis_Reference',
  'code',
];

/// First-run seeding is the one piece of startup logic that mutates the user's
/// reference data, and it runs on **every** launch (`service_locator.dart:308`),
/// so its contract is narrow but strict:
///
///   * it must create the reference/units tables from the shipped assets;
///   * it must be safe to call again on the next launch and change nothing;
///   * it must never overwrite reference data the lab has already edited.
///
/// Every silent-wrong-value in here is a *permanent* one, because the
/// `reference_seed_done` flag latches: once it is written, no later launch ever
/// retries the import. The tests therefore pin both the happy path and the ways
/// a half-finished seed can still be declared "done".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late Database db;
  late SeedService seed;

  Future<int> countOf(String table) async =>
      Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) AS c FROM $table')) ??
      0;

  Future<String?> flagValue() async {
    final rows = await db
        .query('settings', where: 'key = ?', whereArgs: ['reference_seed_done']);
    return rows.isEmpty ? null : '${rows.first['value']}';
  }

  /// Decodes the shipped reference sheet straight from the asset bundle so a test
  /// can compare the database against the spreadsheet it came from.
  Future<List<List<dynamic>>> shippedReferenceRows() async {
    final data = await rootBundle.load(referenceAsset);
    final excel = Excel.decodeBytes(data.buffer.asUint8List());
    return [
      for (final row in excel.tables.values.first.rows)
        [for (final cell in row) cell?.value]
    ];
  }

  Future<void> insertMaterial({
    required String name,
    required String code,
    String physical = '{}',
    String chemical = '{}',
    String importedAt = '2020-01-01 00:00:00',
  }) async {
    await db.insert('reference_materials', <String, dynamic>{
      'material_name': name,
      'material_code': code,
      'physical_reference_json': physical,
      'chemical_reference_json': chemical,
      'imported_at': importedAt,
    });
  }

  Future<void> insertParameter({
    required String name,
    required String unit,
    String importedAt = '2020-01-01 00:00:00',
  }) async {
    await db.insert('parameters', <String, dynamic>{
      'parameter_name': name,
      'unit': unit,
      'imported_at': importedAt,
    });
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_seed');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
    seed = SeedService(dbHelper: helper);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    await helper.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('isSeedDone() — the one-time latch', () {
    test('a fresh database is not seeded: the flag row does not exist at all',
        () async {
      // The absence of the row is the "first run" signal. If the service ever
      // wrote an empty or "0" row on schema creation the two would diverge.
      expect(await seed.isSeedDone(), isFalse);
      expect(await flagValue(), isNull);
    });

    test('only the exact string "1" counts as done', () async {
      // A settings UI that writes `true`, `01` or `yes` here would silently
      // re-seed on every launch.
      for (final value in ['0', 'true', 'yes', '01', ' 1', '1 ']) {
        await db.insert('settings',
            <String, dynamic>{'key': 'reference_seed_done', 'value': value},
            conflictAlgorithm: ConflictAlgorithm.replace);
        expect(await seed.isSeedDone(), isFalse,
            reason: '"$value" must not be read as "already seeded"');
      }
      await db.insert('settings',
          <String, dynamic>{'key': 'reference_seed_done', 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      expect(await seed.isSeedDone(), isTrue);
    });

    test('SettingsRepo\'s "0" default is what a real first launch sees',
        () async {
      // `SettingsRepo.ensureDefaults` writes `reference_seed_done = '0'` before
      // startup calls `ensureInitialImport()`, so the latch has to treat an
      // explicit "0" exactly like a missing row.
      await db.insert('settings',
          <String, dynamic>{'key': 'reference_seed_done', 'value': '0'});
      expect(await seed.isSeedDone(), isFalse);
    });
  });

  group('ensureInitialImport() — first run against the shipped assets', () {
    test('imports materials and units and flips the flag to "1"', () async {
      await seed.ensureInitialImport();

      expect(await countOf('reference_materials'), greaterThan(0));
      expect(await countOf('parameters'), greaterThan(0));
      expect(await flagValue(), '1');
    });

    test('every named row of the spreadsheet became exactly one row', () async {
      final sheet = await shippedReferenceRows();
      final header = sheet.first.map((v) => '${v ?? ''}'.trim()).toList();
      final nameIdx = header.indexOf('Raw_Material_Name');
      final named = <String>{
        for (final row in sheet.skip(1))
          if (row.length > nameIdx) '${row[nameIdx] ?? ''}'.trim()
      }..removeWhere((n) => n.isEmpty);

      await seed.ensureInitialImport();

      // The blank tail of the spreadsheet must not become blank materials, and
      // the header row must not become a material called "Raw_Material_Name".
      final stored = await db.rawQuery('SELECT material_name FROM reference_materials');
      expect(stored.map((r) => '${r['material_name']}').toSet(), named);
      expect(stored, hasLength(named.length));
    });

    test('the header row never lands in the table as a material', () async {
      await seed.ensureInitialImport();
      final rows = await db.rawQuery(
          "SELECT material_name FROM reference_materials WHERE material_name LIKE '%Raw_Material%' OR material_name LIKE '%Chemical_Analysis%'");
      expect(rows, isEmpty);
    });

    test('a non-empty reference cell never degrades into the "{}" fallback',
        () async {
      // `jsonLoads` swallows a parse failure and hands back `{}`, so a material
      // with no limits silently passes every inspection. This pins that the
      // shipped asset really does decode, i.e. the "{}" rows are real empties.
      final sheet = await shippedReferenceRows();
      final header = sheet.first.map((v) => '${v ?? ''}'.trim()).toList();
      final nameIdx = header.indexOf('Raw_Material_Name');
      final physicalIdx = header.indexOf('Physical_Aspects_Reference');
      final expectedNonEmpty = <String>{
        for (final row in sheet.skip(1))
          if (row.length > nameIdx && row.length > physicalIdx &&
              '${row[physicalIdx] ?? ''}'.trim().isNotEmpty)
            '${row[nameIdx] ?? ''}'.trim()
      };

      await seed.ensureInitialImport();

      final rows = await db.query('reference_materials');
      for (final name in expectedNonEmpty) {
        final row = rows.firstWhere((r) => r['material_name'] == name);
        expect('${row['physical_reference_json']}', isNot('{}'),
            reason: '"$name" has reference limits in the sheet but "{}" in the db');
        expect(jsonDecode('${row['physical_reference_json']}'), isA<Map<String, dynamic>>());
        expect(jsonDecode('${row['chemical_reference_json']}'),
            isA<Map<String, dynamic>>());
      }
      expect(expectedNonEmpty, isNotEmpty);
    });

    test('importReference() reports the number of rows it actually wrote',
        () async {
      final reported = await seed.importReference();
      expect(reported, await countOf('reference_materials'),
          reason: 'the migration panel prints this number to the user');
    });

    test('a second launch is a no-op: nothing is rewritten at all', () async {
      await seed.ensureInitialImport();
      final before = await db.rawQuery(
          'SELECT material_name, imported_at, physical_reference_json FROM reference_materials ORDER BY material_name');
      final paramsBefore = await countOf('parameters');

      // Stamp every row so a re-run that upserts would be visible. The second
      // launch must be a pure early return on the flag, not a silent upsert.
      await db.update('reference_materials', <String, dynamic>{
        'imported_at': 'SENTINEL'
      });
      await db.update('parameters', <String, dynamic>{
        'imported_at': 'SENTINEL'
      });

      await seed.ensureInitialImport();

      final after = await db.rawQuery(
          'SELECT material_name, imported_at FROM reference_materials ORDER BY material_name');
      expect(after.map((r) => '${r['material_name']}:${r['imported_at']}'),
          before.map((r) => '${r['material_name']}:SENTINEL').toList());
      expect(after, hasLength(before.length));
      expect(await countOf('parameters'), paramsBefore);
      expect(await flagValue(), '1');
    });

    test('running it three times in a row leaves the same data', () async {
      await seed.ensureInitialImport();
      final materials = await countOf('reference_materials');
      final parameters = await countOf('parameters');

      await seed.ensureInitialImport();
      await seed.ensureInitialImport();

      expect(await countOf('reference_materials'), materials);
      expect(await countOf('parameters'), parameters);
      expect(await seed.isSeedDone(), isTrue);
    });
  });

  group('ensureInitialImport() — data that is already there', () {
    test('a pre-existing material is left alone while the units are filled in',
        () async {
      // The "materials already exist" branch must import units ONLY. Re-running
      // the reference import would silently replace whatever the lab imported
      // or edited by hand.
      await insertMaterial(
          name: 'Locally Imported Material',
          code: 'LOCAL-1',
          physical: '{"Moisture":"hand typed"}');

      await seed.ensureInitialImport();

      final row = await db.query('reference_materials',
          where: 'material_name = ?', whereArgs: ['Locally Imported Material']);
      expect(row, hasLength(1));
      expect(row.single['physical_reference_json'], '{"Moisture":"hand typed"}',
          reason: 'ensureInitialImport must not clobber an existing reference');
      expect(row.single['imported_at'], '2020-01-01 00:00:00');
      expect(await countOf('parameters'), greaterThan(0));
      expect(await flagValue(), '1');
    });

    test('with units already present nothing is imported but the flag is set',
        () async {
      await insertMaterial(name: 'Existing', code: 'E-1');
      await insertParameter(name: 'ExistingUnit', unit: 'mg');

      await seed.ensureInitialImport();

      expect(await countOf('reference_materials'), 1);
      expect(await countOf('parameters'), 1);
      expect(await flagValue(), '1');
    });
  });

  group('importReference() — raw upsert semantics', () {
    test('a re-import upserts by material_name instead of duplicating', () async {
      // `ON CONFLICT(material_name) DO UPDATE` is what makes the migration
      // panel's "re-import reference" button safe to press twice.
      final first = await seed.importReference();
      final rows = await countOf('reference_materials');
      final second = await seed.importReference();

      expect(first, rows);
      expect(second, rows);
      expect(await countOf('reference_materials'), rows);
      final distinct = await db.rawQuery(
          'SELECT COUNT(DISTINCT material_name) AS c FROM reference_materials');
      expect(Sqflite.firstIntValue(distinct), rows);
    });

    test('BUG PINNED: a re-import silently overwrites a local edit', () async {
      // Unlike `ensureInitialImport`, the raw import replaces the whole row. A
      // lab that corrected a reference limit by hand loses the correction the
      // next time anyone presses "re-import", with no warning anywhere.
      // Pick the name straight out of the shipped sheet so the upsert really
      // targets an existing row.
      final sheet = await shippedReferenceRows();
      final header = sheet.first.map((v) => '${v ?? ''}'.trim()).toList();
      final nameIdx = header.indexOf('Raw_Material_Name');
      final name = '${sheet[1][nameIdx] ?? ''}'.trim();

      await insertMaterial(
          name: name,
          code: 'M-LOCAL',
          physical: '{"Moisture":"corrected by the lab"}',
          importedAt: 'SENTINEL');

      await seed.importReference();

      final row = await db.query('reference_materials',
          where: 'material_name = ?', whereArgs: [name]);
      expect(row.single['physical_reference_json'],
          isNot('{"Moisture":"corrected by the lab"}'),
          reason: 'the ON CONFLICT DO UPDATE replaced every column');
      expect(row.single['material_code'], isNot('M-LOCAL'));
      expect(row.single['imported_at'], isNot('SENTINEL'),
          reason: 'imported_at is refreshed too, so the row looks freshly vetted');
    });

    test('a sheet missing a required column is rejected and names every gap',
        () async {
      serveAssets({
        referenceAsset: workbook([
          ['Raw_Material_Name', 'code'],
          ['Alpha', 'A'],
        ]),
      });

      // The service must refuse a wrong workbook rather than insert materials
      // with empty limits, and the message has to say what is missing.
      await expectLater(
        seed.importReference(),
        throwsA(isA<ValidationError>().having((e) => e.message, 'message',
            allOf(contains('Physical_Aspects_Reference'),
                contains('Chemical_Analysis_Reference')))),
      );
      expect(await countOf('reference_materials'), 0);
    });

    test('header order does not matter, only the header names do', () async {
      serveAssets({
        referenceAsset: workbook([
          ['code', 'Chemical_Analysis_Reference', 'Raw_Material_Name',
              'Physical_Aspects_Reference'],
          ['A', '{"c":"1"}', 'Alpha', '{"p":"2"}'],
        ]),
      });

      expect(await seed.importReference(), 1);
      final row = (await db.query('reference_materials')).single;
      expect(row['material_name'], 'Alpha');
      expect(row['material_code'], 'A');
      expect(row['physical_reference_json'], '{"p":"2"}');
      expect(row['chemical_reference_json'], '{"c":"1"}');
    });

    test('blank rows inside the sheet are skipped and source_row tracks the sheet',
        () async {
      serveAssets({
        referenceAsset: workbook([
          referenceHeaders,
          ['Alpha', '{"p":"1"}', '{"c":"1"}', 'A'],
          ['', '', '', ''],
          ['Beta', '{"p":"2"}', '{"c":"2"}', 'B'],
        ]),
      });

      // `i + 1` is the spreadsheet row number, so the blank row still advances
      // `source_row` — that is what lets a user find the row in Excel.
      expect(await seed.importReference(), 2);
      final rows = await db.query('reference_materials',
          orderBy: 'source_row ASC', columns: ['material_name', 'source_row']);
      expect(rows.map((r) => '${r['material_name']}'), ['Alpha', 'Beta']);
      expect(rows.map((r) => r['source_row']), [2, 4]);
    });

    test('BUG PINNED: the return value counts sheet rows, not rows written',
        () async {
      // Two spreadsheet rows share a material name. The upsert collapses them
      // into one row but both iterations still increment `count`, so the UI
      // reports "2 materials imported" when the database gained one.
      serveAssets({
        referenceAsset: workbook([
          referenceHeaders,
          ['Alpha', '{"p":"1"}', '{"c":"1"}', 'A'],
          ['Alpha', '{"p":"9"}', '{"c":"9"}', 'A2'],
        ]),
      });

      expect(await seed.importReference(), 2);
      final rows = await db.query('reference_materials');
      expect(rows, hasLength(1),
          reason: 'the duplicate collapsed onto the second sheet row');
      expect(rows.single['material_code'], 'A2',
          reason: 'last write wins, silently');
    });

    test('BUG PINNED: an unparseable limits cell becomes an empty object',
        () async {
      // `jsonLoads` swallows the parse error and returns `{}`, so a corrupt cell
      // yields a material with no limits at all — every inspection of it then
      // passes. The import reports success and the corruption is invisible.
      serveAssets({
        referenceAsset: workbook([
          referenceHeaders,
          ['Alpha', 'not-json', 'also-not-json', 'A'],
        ]),
      });

      expect(await seed.importReference(), 1);
      final row = (await db.query('reference_materials')).single;
      expect(row['physical_reference_json'], '{}');
      expect(row['chemical_reference_json'], '{}');
    });

    test('a JSON array in a limits cell is also downgraded to an empty object',
        () async {
      // `jsonLoads` only accepts a `Map`; a well-formed array silently becomes
      // `{}` instead of being rejected.
      serveAssets({
        referenceAsset: workbook([
          referenceHeaders,
          ['Alpha', '[1,2,3]', '{"c":"1"}', 'A'],
        ]),
      });

      expect(await seed.importReference(), 1);
      expect((await db.query('reference_materials')).single['physical_reference_json'],
          '{}');
    });

    test('an empty limits cell becomes "{}" and a blank name row is skipped',
        () async {
      serveAssets({
        referenceAsset: workbook([
          referenceHeaders,
          ['   ', '', '', ''],
          ['Alpha', '', '', 'A'],
        ]),
      });

      expect(await seed.importReference(), 1);
      final row = (await db.query('reference_materials')).single;
      expect(row['material_name'], 'Alpha');
      expect(row['physical_reference_json'], '{}');
    });
  });

  group('importUnits()', () {
    test('imports the Element Name / Unit sheet and upserts by name', () async {
      final first = await seed.importUnits();
      final rows = await countOf('parameters');
      final second = await seed.importUnits();

      expect(first, rows);
      expect(second, rows);
      expect(await countOf('parameters'), rows);
      final blank = await db.rawQuery(
          "SELECT parameter_name FROM parameters WHERE parameter_name IS NULL OR TRIM(parameter_name) = ''");
      expect(blank, isEmpty);
    });

    test('a sheet without the two required headers is skipped silently', () async {
      // `return 0` with no reason: the caller cannot tell "no units in the file"
      // from "wrong file". Compare with `importReference`, which throws.
      serveAssets({
        unitsAsset: workbook([
          ['Element', 'Unit'],
          ['Moisture', '%'],
        ]),
      });

      expect(await seed.importUnits(), 0);
      expect(await countOf('parameters'), 0);
    });

    test('BUG PINNED: a missing units asset is swallowed and never retried',
        () async {
      // `importUnits` wraps only `rootBundle.load` in `catch (_) { return 0; }`,
      // then `ensureInitialImport` writes `reference_seed_done = '1'`
      // unconditionally. A packaging mistake therefore produces a database with
      // materials but ZERO units, and because the flag is latched no later
      // launch will ever try again. Nothing is logged and nothing throws.
      final reference = await rootBundle.load(referenceAsset);
      serveAssets({
        referenceAsset:
            ByteData.sublistView(reference.buffer.asUint8List()),
        // 'assets/units.xlsx' deliberately absent.
      });

      await seed.ensureInitialImport();

      expect(await countOf('reference_materials'), greaterThan(0));
      expect(await countOf('parameters'), 0,
          reason: 'the missing asset produced zero units, silently');
      expect(await flagValue(), '1',
          reason: 'and the latch now forbids a retry on the next launch');
      expect(await seed.isSeedDone(), isTrue);
    });
  });
}