import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, OpenDatabaseOptions, databaseFactory;

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// `lab_field_chemical_links` is upgraded by a rename -> create -> copy -> drop
/// cycle, and it runs on *every* open (the schema version is pinned at 1, so
/// `onUpgrade` never fires).
///
/// Run outside a transaction, a process death anywhere in that cycle left the
/// database in a half-migrated state. The failure mode was not merely a lost
/// upgrade: the next open saw an empty `PRAGMA table_info` for the live table,
/// concluded there was nothing to do, and then ran
/// `_ensureColumn('lab_field_chemical_links', 'kind', ...)` - an `ALTER TABLE`
/// against a table that no longer existed. The open threw, and because the state
/// was persisted there was no path back: the user's data was unreachable and the
/// app could not start.
///
/// The fix is transactional (an interrupted upgrade rolls back) plus a recovery
/// branch for databases already stuck. The tests below pin the recovery, since
/// it is the only part that can be exercised without killing a process.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late String path;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_mig_recovery');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    path = '${tmp.path}/MaterialLab/material_lab.db';
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Writes [statements] into a fresh database file at [path], standing in for
  /// whatever the previous process managed to commit before it died.
  Future<void> seed(List<String> statements) async {
    await Directory('${tmp.path}/MaterialLab').create(recursive: true);
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys=ON'),
        onCreate: (db, _) async {
          for (final s in statements) {
            await db.execute(s);
          }
        },
      ),
    );
    await db.close();
  }

  /// The pre-V2 shape: no `kind`/`fixed_value`/`list_values`, and `inventory_id`
  /// is NOT NULL - which is exactly why SQLite could not `ALTER` it in place.
  const legacyLinks = '''
    CREATE TABLE lab_field_chemical_links (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      analysis_id INTEGER NOT NULL,
      dynamic_field TEXT NOT NULL,
      inventory_id INTEGER NOT NULL,
      unit TEXT NOT NULL DEFAULT 'mL',
      created_at TEXT NOT NULL
    )
  ''';

  /// Foreign keys are on, and V2's `inventory_id` references `lab_inventory`, so
  /// the parent table has to exist before any row can be carried over.
  const scaffold = [
    'CREATE TABLE lab_analyses (id INTEGER PRIMARY KEY AUTOINCREMENT)',
    'CREATE TABLE lab_inventory (id INTEGER PRIMARY KEY AUTOINCREMENT)',
    'INSERT INTO lab_analyses (id) VALUES (1), (2), (3), (4), (5), (6)',
    'INSERT INTO lab_inventory (id) VALUES (2), (4), (5), (7), (9), (11)',
  ];

  /// The `_old` scratch table a process death left behind: the live table is
  /// gone and its rows are here.
  const leftoverOld = '''
    CREATE TABLE lab_field_chemical_links_old (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      analysis_id INTEGER NOT NULL,
      dynamic_field TEXT NOT NULL,
      inventory_id INTEGER NOT NULL,
      unit TEXT NOT NULL DEFAULT 'mL',
      created_at TEXT NOT NULL
    )
  ''';

  Future<List<Map<String, Object?>>> columnsOf(Database db, String table) async =>
      await db.rawQuery('PRAGMA table_info($table)');

  test('the untouched legacy table is rebuilt with rows preserved', () async {
    await seed([
      ...scaffold,
      legacyLinks,
      "INSERT INTO lab_field_chemical_links "
          "(analysis_id, dynamic_field, inventory_id, created_at) VALUES "
          "(1, 'pH', 5, '2026-01-01'), (2, 'Acidity', 7, '2026-01-02')",
    ]);

    final db = await helper.database;

    final names = (await columnsOf(db, 'lab_field_chemical_links'))
        .map((c) => '${c['name']}')
        .toSet();
    expect(names, containsAll(['kind', 'fixed_value', 'list_values']),
        reason: 'the V2 columns must exist after the rebuild');
    expect(await db.rawQuery(
        'SELECT COUNT(*) c FROM lab_field_chemical_links'), [
      {'c': 2}
    ]);
    // The carried-over values must be the legacy ones, not defaults.
    final rows = await db.query('lab_field_chemical_links',
        where: 'dynamic_field = ?', whereArgs: ['pH']);
    expect(rows.single['inventory_id'], 5);
    expect(rows.single['analysis_id'], 1);
    expect(rows.single['created_at'], '2026-01-01');
  });

  test('a database stuck mid-upgrade is recovered, not abandoned', () async {
    // The exact half-state a process death between the rename and the drop
    // produced: the live table is gone and its rows sit in `_old`.
    await seed([
      ...scaffold,
      leftoverOld,
      "INSERT INTO lab_field_chemical_links_old "
          "(analysis_id, dynamic_field, inventory_id, created_at) VALUES "
          "(3, 'Moisture', 9, '2026-01-03')",
    ]);

    // Before the fix this `await` threw a DatabaseException and the app could
    // not start; asserting the open alone is the regression.
    final db = await helper.database;

    final names = (await columnsOf(db, 'lab_field_chemical_links'))
        .map((c) => '${c['name']}')
        .toSet();
    expect(names, contains('kind'));
    final rows = await db.query('lab_field_chemical_links');
    expect(rows, hasLength(1));
    expect(rows.single['dynamic_field'], 'Moisture');
    expect(rows.single['inventory_id'], 9);
  });

  test('the leftover _old table is dropped once recovery finishes', () async {
    await seed([
      ...scaffold,
      leftoverOld,
      "INSERT INTO lab_field_chemical_links_old "
          "(analysis_id, dynamic_field, inventory_id, created_at) VALUES "
          "(4, 'Ash', 2, '2026-01-04')",
    ]);

    final db = await helper.database;

    expect(await columnsOf(db, 'lab_field_chemical_links_old'), isEmpty,
        reason: 'the scratch table must not linger');
    expect(await db.query('lab_field_chemical_links'), hasLength(1));
  });

  test('reopening a recovered database is a no-op, and keeps the rows',
      () async {
    await seed([
      ...scaffold,
      leftoverOld,
      "INSERT INTO lab_field_chemical_links_old "
          "(analysis_id, dynamic_field, inventory_id, created_at) VALUES "
          "(5, 'Protein', 4, '2026-01-05')",
    ]);

    await helper.database;
    await helper.close();
    final reopened = await helper.database;

    // The `kind` guard has to stop the cycle from re-running, or every open
    // would re-copy the rows and the ids would drift.
    final rows = await reopened.query('lab_field_chemical_links');
    expect(rows, hasLength(1));
    expect(rows.single['dynamic_field'], 'Protein');
    expect(await columnsOf(reopened, 'lab_field_chemical_links_old'), isEmpty);
  });

  test('a value/list config survives, which needs a nullable inventory_id',
      () async {
    // The reason the table had to be rebuilt rather than ALTERed: fixed_value
    // and list_values rows have no inventory item at all, so `inventory_id`
    // had to become nullable. A legacy row still has to round-trip.
    await seed([
      ...scaffold,
      legacyLinks,
      "INSERT INTO lab_field_chemical_links "
          "(analysis_id, dynamic_field, inventory_id, created_at) VALUES "
          "(6, 'Colour', 11, '2026-01-06')",
    ]);

    final db = await helper.database;
    await db.insert('lab_field_chemical_links', {
      'analysis_id': 6,
      'dynamic_field': 'Grade',
      'inventory_id': null,
      'unit': 'mL',
      'kind': 'list',
      'list_values': '["A","B"]',
      'created_at': '2026-02-01',
    });

    final row = (await db.query('lab_field_chemical_links',
        where: 'dynamic_field = ?', whereArgs: ['Grade']))
        .single;
    expect(row['inventory_id'], isNull);
    expect(row['kind'], 'list');
    expect(row['list_values'], contains('"A"'));
  });

  test('a database that never had the table opens cleanly', () async {
    // The recovery must not invent the table from nothing: a file with no
    // `lab_field_chemical_links` and no `_old` scratch table has nothing to
    // carry over and is left to `_createSchema`.
    await seed(['CREATE TABLE notes (id INTEGER PRIMARY KEY)']);

    final db = await helper.database;
    await db.insert('notes', {'id': 1});
    expect(await db.query('notes'), hasLength(1));
  });
}
