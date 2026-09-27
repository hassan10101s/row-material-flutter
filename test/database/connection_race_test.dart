import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:sqflite/sqflite.dart' show Database;

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Opening the per-organization database has two ordering hazards.
///
/// `DatabaseHelper.database` used to await `paths.databasePath()` and
/// `_open(path)` *before* assigning `_db`, so a caller could observe a
/// half-open helper, and `close()` could null out handles that an in-flight
/// open was about to assign.
///
/// The second, worse hazard was the phantom read-only connection: the helper
/// opened `OpenDatabaseOptions(readOnly: true)` as a second handle, but
/// sqflite's single-instance cache is keyed by **path only**
/// (`factory_mixin.dart` -> `databaseOpenHelpers[path]`), so that open returned
/// the identical object. `close()` then closed one connection twice. In the real
/// app that surfaced as a startup crash, because the sync queue memoizes the
/// handle and the sync engine reads the counters from an unawaited timer:
///
///     Unhandled Exception: DatabaseException(error database_closed)
///     #3 SyncQueue._count (package:material_lab/core/sync/sync_queue.dart:388)
///     #4 SyncEngine._current (package:material_lab/core/sync/sync_engine.dart:297)
///
/// The tests below pin the contract: one connection, a memoized holder survives
/// a close/reopen cycle only after it is told to drop its handle, and `close()`
/// is safe to interleave with opens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_conn_race');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('concurrent callers share one write connection', () async {
    // Ten simultaneous resolutions, the way the binder's steps pile up.
    final handles = await Future.wait([
      for (var i = 0; i < 10; i++) helper.database,
    ]);

    for (final handle in handles) {
      expect(identical(handle, handles.first), isTrue,
          reason: 'every caller must get the same Database instance');
    }
  });

  test('concurrent readers share one read-only connection', () async {
    final readers = await Future.wait([
      for (var i = 0; i < 10; i++) helper.readDatabase,
    ]);

    for (final handle in readers) {
      expect(identical(handle, readers.first), isTrue,
          reason: 'every caller must get the same read-only instance');
    }
  });

  test('a reader racing a writer never sees a half-open helper', () async {
    // `readDatabase` used to `await database` and then dereference `_readDb!`.
    // When `database` returned early (because `_db` was already assigned while
    // the read-only handle was still opening) that was a null dereference.
    final results = await Future.wait<Object?>([
      helper.database,
      helper.readDatabase,
      helper.database,
      helper.readDatabase,
      helper.readDatabase,
    ]);

    expect(results.whereType<Database>().length, 5);
  });

  test('the connection stays usable for writes after a concurrent open', () async {
    await Future.wait([helper.database, helper.database, helper.database]);
    final db = await helper.database;
    await db.insert('settings', {'key': 'probe', 'value': '1'});
    final rows = await db.query('settings', where: 'key = ?', whereArgs: ['probe']);
    expect(rows, hasLength(1));
  });

  test('close() during an in-flight open does not leak a connection', () async {
    // bindOrg() is `close()` then `database`, and `rebuild()`/restore call
    // `close()` while something else may still be resolving the handle.
    final opening = helper.database;
    final closing = helper.close();
    await Future.wait([opening, closing]);

    // Whatever the interleaving, the helper must end up consistent: a fresh
    // open works and yields a working connection.
    final reopened = await helper.database;
    await reopened.insert('settings', {'key': 'after_close', 'value': '1'});
    final rows = await reopened.query('settings',
        where: 'key = ?', whereArgs: ['after_close']);
    expect(rows, hasLength(1));
  });

  test('reopening after close yields a different, working connection', () async {
    final first = await helper.database;
    await helper.close();
    final second = await helper.database;

    expect(identical(first, second), isFalse);
    await second.insert('settings', {'key': 'second', 'value': '1'});
    final rows = await second.query('settings', where: 'key = ?', whereArgs: ['second']);
    expect(rows, hasLength(1));
  });

  test('readDatabase is the same handle, not a phantom second connection',
      () async {
    // Regression: the helper used to open `readOnly: true` as a second handle.
    // sqflite's single-instance cache ignores `readOnly` and keys by path, so
    // that open returned the identical object. Nothing ever gained a second
    // connection, and `close()` shut one connection down twice.
    final write = await helper.database;
    final read = await helper.readDatabase;
    expect(identical(write, read), isTrue);
  });

  test('a close that races a poll never yields a null dereference', () async {
    // The startup crash in production. The sync engine reads its counters from
    // an unawaited timer while an organization switch closes the database.
    // `close()` empties `_db` synchronously and only then awaits the handle's
    // own shutdown, so a caller could observe an empty `_db`. Returning `_db!`
    // there used to throw `Null check operator used on a null value` from
    // inside whichever service lost its connection.
    await helper.database;

    for (var i = 0; i < 25; i++) {
      final closing = helper.close();
      final db = await helper.database;
      // The getter re-drives the open, so this must always be a usable handle.
      await db.rawQuery('SELECT COUNT(*) FROM settings');
      await closing;
    }
  });

  test('overlapping polls across many close cycles leave no dead handle',
      () async {
    await helper.database;
    for (var i = 0; i < 25; i++) {
      final poll = Future.wait([helper.database, helper.readDatabase]);
      final closing = helper.close();
      final handles = await poll;
      await closing;

      // Handles captured before the close are genuinely closed, so they are not
      // used here; what matters is that the helper is usable again afterwards
      // and that no handle was a null dereference in disguise.
      expect(handles.whereType<Database>().length, 2);
      final fresh = await helper.database;
      await fresh.insert('settings', {'key': 'cycle_$i', 'value': '1'});
      expect(
        await fresh
            .query('settings', where: 'key = ?', whereArgs: ['cycle_$i']),
        hasLength(1),
      );
    }
  });

  test('close() is idempotent and a second close does not throw', () async {
    await helper.database;
    await helper.close();
    await expectLater(helper.close(), completes);

    final reopened = await helper.database;
    await reopened.insert('settings', {'key': 'idem', 'value': '1'});
    expect(
      await reopened.query('settings', where: 'key = ?', whereArgs: ['idem']),
      hasLength(1),
    );
  });

  test('concurrent close() calls are serialised', () async {
    await helper.database;
    await Future.wait([helper.close(), helper.close(), helper.close()]);
    final reopened = await helper.database;
    await reopened.insert('settings', {'key': 'concurrent', 'value': '1'});
    expect(
      await reopened.query('settings',
          where: 'key = ?', whereArgs: ['concurrent']),
      hasLength(1),
    );
  });
}
