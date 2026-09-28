import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/database/db_trace.dart';
import 'package:sqflite/sqflite.dart' show Database;

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Why this file exists.
///
/// sqflite prints
///
///     Warning database has been locked for 0:00:10.000000. Make sure you
///     always use the transaction object for database operations during a
///     transaction
///
/// whenever a call on the **root** connection waited more than ten seconds for
/// the connection lock. The message is misleading about the cause, and the stack
/// it prints is worthless: `SqfliteDatabaseMixinBase.txnSynchronized` fires the
/// warning from the `Timer` of `timeoutCompleter.future.timeout(...)`, so the
/// frames are always `Future.timeout -> Timer._runTimers`.
///
/// The real mechanism, on the FFI factory:
///
///  * a statement that is **not** part of the transaction currently open on the
///    connection is not executed at all. `sqflite_common_ffi` parks it in
///    `SqfliteFfiDatabase._noTransactionHandlerQueue` and only drains that queue
///    when a statement *inside* the transaction completes, i.e. on COMMIT or
///    ROLLBACK (`sqflite_ffi_impl.dart:270`);
///  * the parked call is already holding the connection's non-reentrant
///    `_rawLock` (`sqflite_common/database_mixin.dart:575`) - which is what the
///    ten-second wait is measured against, and what every later root-handle call
///    then queues behind;
///  * every statement of every database is funnelled through **one** shared
///    background isolate (`database_factory_ffi_io.dart:43`), so one slow
///    statement stalls the whole process.
///
/// So a long transaction is the holder and a root-handle read is the victim -
/// and the two are the same bug seen from either end. The first test below pins
/// that behaviour, because it is the thing that is easy to reintroduce by
/// "simplifying" a helper to use the root handle, and the second set pins
/// [DbTrace], which is the only thing in the codebase that can actually name the
/// call site.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late Database db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_db_trace');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('a root-handle read is parked until the open transaction commits', () async {
    // The behaviour behind the warning. If this ever starts failing because
    // sqflite changed, the "Warning database has been locked" spam is no longer
    // about transactions and the diagnostics in this file need a new rationale.
    final transactionOpen = Completer<void>();
    final releaseTransaction = Completer<void>();
    final transactionEnded = Completer<void>();
    final rootRead = Completer<void>();

    unawaited(
      db.transaction<void>((txn) async {
        // Force the BEGIN through the isolate before anything else can interleave.
        await txn.query('settings');
        transactionOpen.complete();
        await releaseTransaction.future;
        transactionEnded.complete();
      }),
    );

    await transactionOpen.future;

    // Issued on the root handle, i.e. `db.query`, not `txn.query`. This is
    // exactly what a helper that forgot to take an executor would do.
    unawaited(db.query('settings').then((_) => rootRead.complete()));

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      rootRead.isCompleted,
      isFalse,
      reason:
          'a non-transaction statement must not run while a transaction is '
          'open on the same connection',
    );

    releaseTransaction.complete();
    await transactionEnded.future;
    await rootRead.future.timeout(const Duration(seconds: 5));
  });

  group('DbTrace', () {
    test(
      'returns the value and stays quiet when the operation is fast',
      () async {
        final captured = <String>[];
        final value = await runZoned(
          () => DbTrace.run('fast', () async => 42),
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => captured.add(line),
          ),
        );
        expect(value, 42);
        expect(captured, isEmpty);
      },
    );

    test(
      'reports the caller, not the timer, when the budget is exceeded',
      () async {
        final captured = <String>[];
        final value = await runZoned(
          () => DbTrace.run('slow.op', () async {
            await Future<void>.delayed(const Duration(milliseconds: 120));
            return 'ok';
          }, budget: const Duration(milliseconds: 10)),
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => captured.add(line),
          ),
        );
        // The diagnostic must never change the result of what it wraps.
        expect(value, 'ok');
        expect(captured, hasLength(1));
        expect(captured.single, contains('slow.op'));
        // The frame that matters: the caller of `DbTrace.run`, which is what
        // sqflite's own warning can never give us.
        expect(captured.single, contains('db_trace_test.dart'));
      },
    );

    test('names the holder, not just the victim, when calls overlap', () async {
      // The whole point of the in-flight registry. sqflite reports a waiter and
      // gives it a timer stack, so the only way to find the holder is to record
      // every call that is open at the moment one of them overruns.
      final releaseHolder = Completer<void>();
      final holderStarted = Completer<void>();
      final captured = <String>[];

      await runZoned(
        () async {
          // The holder: slow on its own, and labelled so it can be told apart
          // from the victim by its stack.
          unawaited(
            DbTrace.run('holder.work', () async {
              holderStarted.complete();
              await releaseHolder.future;
            }, budget: const Duration(seconds: 30)),
          );
          await holderStarted.future;

          // The victim: over its budget while the holder is still open.
          await DbTrace.run('victim.wait', () async {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }, budget: const Duration(milliseconds: 20));
          releaseHolder.complete();
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => captured.add(line),
        ),
      );

      final report = captured.firstWhere((l) => l.contains('victim.wait'));
      // Both are listed, so the report shows the victim as well...
      expect(report, contains('holder.work'));
      expect(report, contains('victim.wait'));
      // ...and the holder is called out explicitly. The ids are a global
      // counter shared with the other tests, so only the pairing is asserted.
      expect(
        report,
        matches(RegExp(r'holder candidate: \[\d+\] holder\.work')),
      );
      // And the holder's own stack, which is what identifies the code to fix.
      expect(report, contains('db_trace_test.dart'));
    });

    test('a thrown error is neither swallowed nor reported as slow', () async {
      final captured = <String>[];
      await expectLater(
        runZoned(
          () => DbTrace.run('boom', () async {
            throw StateError('nope');
          }, budget: const Duration(seconds: 30)),
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => captured.add(line),
          ),
        ),
        throwsStateError,
      );
      expect(captured, isEmpty);
    });
  });

  group('TracedDatabase', () {
    test('forwards results and the handle\'s own state', () async {
      final traced = TracedDatabase(db);
      expect(traced.path, db.path);
      expect(traced.isOpen, isTrue);
      expect(
        await traced.insert('settings', {'key': 'a', 'value': 'b'}),
        greaterThan(0),
      );
      expect(
        await traced.query('settings', where: 'key = ?', whereArgs: ['a']),
        hasLength(1),
      );
      expect(
        await traced.update(
          'settings',
          {'value': 'c'},
          where: 'key = ?',
          whereArgs: ['a'],
        ),
        1,
      );
      expect(
        (await traced.rawQuery('SELECT value FROM settings WHERE key = ?', [
          'a',
        ])).single['value'],
        'c',
      );
      expect(
        await traced.delete('settings', where: 'key = ?', whereArgs: ['a']),
        1,
      );
    });

    test(
      'a transaction through the decorator commits and rolls back',
      () async {
        final traced = TracedDatabase(db);
        await traced.transaction((txn) async {
          await txn.insert('settings', {'key': 'committed', 'value': '1'});
        });
        expect(
          await traced.query(
            'settings',
            where: 'key = ?',
            whereArgs: ['committed'],
          ),
          hasLength(1),
        );

        await expectLater(
          traced.transaction<void>((txn) async {
            await txn.insert('settings', {'key': 'rolled', 'value': '1'});
            throw StateError('nope');
          }),
          throwsStateError,
        );
        expect(
          await traced.query(
            'settings',
            where: 'key = ?',
            whereArgs: ['rolled'],
          ),
          isEmpty,
        );
      },
    );
  });

  group('tracedTransaction', () {
    test('commits the body', () async {
      await tracedTransaction(db, 'trace.commit', (txn) async {
        await txn.insert('settings', {'key': 'k', 'value': 'v'});
      });
      final rows = await db.query(
        'settings',
        where: 'key = ?',
        whereArgs: ['k'],
      );
      expect(rows, hasLength(1));
    });

    test('rolls the body back and rethrows', () async {
      await expectLater(
        tracedTransaction(db, 'trace.rollback', (txn) async {
          await txn.insert('settings', {'key': 'k', 'value': 'v'});
          throw StateError('nope');
        }),
        throwsStateError,
      );
      final rows = await db.query(
        'settings',
        where: 'key = ?',
        whereArgs: ['k'],
      );
      expect(rows, isEmpty);
    });
  });
}
