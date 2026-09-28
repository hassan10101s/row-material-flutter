import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:sqflite_common/sqlite_api.dart';

/// Reports database work that runs long, **with the caller on the stack**.
///
/// sqflite has an advisory warning for this:
///
///     Warning database has been locked for 0:00:10.000000. Make sure you
///     always use the transaction object for database operations during a
///     transaction
///
/// but it cannot be used to find the culprit. `SqfliteDatabaseMixinBase.
/// txnSynchronized` fires it from the `Timer` of
/// `timeoutCompleter.future.timeout(...)`, so the stack it prints is always the
/// timer - never the call that was waiting.
///
/// The reason a wait gets that long is worth spelling out, because it is what
/// makes the warning misleading. With the FFI factory:
///
///  * every statement of every database is funnelled through **one** shared
///    background isolate (`sqflite_common_ffi/database_factory_ffi_io.dart`);
///  * a statement that is not part of the transaction currently open on the
///    connection is not executed at all - `sqflite_common_ffi` parks it in
///    `SqfliteFfiDatabase._noTransactionHandlerQueue` and drains that queue
///    only when a statement *inside* the transaction completes, i.e. on COMMIT
///    or ROLLBACK (`sqflite_ffi_impl.dart:270`);
///  * the parked call is already holding the connection's non-reentrant
///    `_rawLock` (`sqflite_common/database_mixin.dart:575`), which is what the
///    ten seconds is measured against - and what every later caller then queues
///    behind.
///
/// So the warning reports a *victim*, never the *holder*. On this stack the two
/// are the same bug seen from either end, which is why [run] tracks every
/// wrapped call in a registry and, when one of them overruns, prints **all**
/// calls that are in flight at that moment, oldest first. The holder is the
/// entry at the top of that list: the call that has been running the longest,
/// still with a live stack.
///
/// ```dart
/// // Semantic labels for the calls worth naming:
/// await DbTrace.run('pull.apply(${type})', () => db.query(table));
/// // ...and a catch-all for everything else:
/// final db = TracedDatabase(realHandle);
/// ```
///
/// Diagnostic only: it never changes the result of the call it wraps. In a
/// release build what remains per call is one [Stopwatch] and one map entry;
/// the stack capture is behind [captureStacks] and off by default there.
abstract final class DbTrace {
  /// Default budget before a wrapped call is reported.
  ///
  /// Well under sqflite's own 10s `lockWarningDurationDefault`, because by the
  /// time that warning fires the interesting detail is already 10 seconds stale.
  static const Duration defaultLimit = Duration(seconds: 2);

  static Duration limit = defaultLimit;

  /// Set to `false` to make every wrapped call a plain pass-through.
  static bool enabled = true;

  /// Whether to capture a caller's [StackTrace] for the stall reports.
  ///
  /// The stack is the expensive half of a traced call: `StackTrace.current` is
  /// not lazy, it materialises the frames, and [TracedDatabase] wraps *every*
  /// statement of *every* handle. A release build has no console to print a
  /// report to, so the capture is skipped there and the timing - which is one
  /// [Stopwatch] - is kept.
  ///
  /// Assign it to capture in a release build being profiled, or to drop the
  /// capture in a debug build where the reports are not being read.
  static bool captureStacks = kDebugMode;

  /// Frames of each in-flight call printed in a stall report. Enough to name the
  /// call site without burying the useful part in noise.
  static const int _stackFrames = 6;

  static final Map<int, _InFlight> _inFlight = <int, _InFlight>{};
  static int _nextId = 0;

  /// Times [action] as [label] and reports it if it outlives [budget]
  /// (defaults to [limit]).
  ///
  /// A report contains every call that is in flight at the moment [action]
  /// overruns, so it names the holder as well as the victim.
  static Future<T> run<T>(
    String label,
    Future<T> Function() action, {
    Duration? budget,
  }) async {
    if (!enabled) return action();
    // Captured before the first `await`, so the synchronous frames of the
    // caller are still on the stack and this is the useful part of the report.
    // Skipped in release, where nothing can read it and the capture is the
    // dominant cost of the wrapper.
    final entry = _InFlight(
      _nextId++,
      label,
      captureStacks ? StackTrace.current : null,
      Stopwatch()..start(),
    );
    _inFlight[entry.id] = entry;
    final timer = Timer(budget ?? limit, () => _reportStalled(entry));
    try {
      return await action();
    } finally {
      timer.cancel();
      entry.watch.stop();
      _inFlight.remove(entry.id);
      if (entry.watch.elapsed >= limit) _reportCompleted(entry);
    }
  }

  static void _reportStalled(_InFlight stalled) {
    final inFlight = _inFlight.values.toList()
      ..sort((a, b) => b.watch.elapsed.compareTo(a.watch.elapsed));
    final report = StringBuffer()
      ..writeln(
        '[db] ${stalled.label} still running after ${stalled.watch.elapsed}',
      )
      ..writeln('     ${inFlight.length} db call(s) in flight, longest first:');
    for (final call in inFlight) {
      final marker = call.id == stalled.id ? '>' : ' ';
      report.writeln(
        '  $marker[${call.id}] ${call.watch.elapsed}  ${call.label}',
      );
      for (final line in call.frames(_stackFrames)) {
        report.writeln('        $line');
      }
    }
    if (inFlight.length > 1) {
      final holder = inFlight.first;
      report.writeln(
        '     holder candidate: [${holder.id}] ${holder.label} '
        '(${holder.watch.elapsed})',
      );
    } else {
      report.writeln(
        '     nothing else was in flight: this call is the holder '
        'itself, and it is slow on its own rather than blocked.',
      );
    }
    // ignore: avoid_print
    print(report.toString().trimRight());
  }

  /// The final duration of a call that overran, so a stall report can be read
  /// against what it actually cost.
  static void _reportCompleted(_InFlight done) {
    // ignore: avoid_print
    print('[db] ${done.label} took ${done.watch.elapsed} (over $limit)');
  }
}

class _InFlight {
  _InFlight(this.id, this.label, this.stack, this.watch);

  final int id;
  final String label;

  /// Null when [DbTrace.captureStacks] was off, which is what the report says
  /// rather than printing a blank section.
  final StackTrace? stack;
  final Stopwatch watch;

  List<String> frames(int count) {
    final stack = this.stack;
    if (stack == null) return const ['(stack capture disabled)'];
    final lines = stack.toString().split('\n');
    final kept = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed == '<asynchronous suspension>') continue;
      kept.add(trimmed);
      if (kept.length == count) break;
    }
    return kept;
  }
}

/// Reports every call made through a [Database] handle, so a holder that no
/// repository thought to label still shows up with its caller's stack.
///
/// The semantic labels from [DbTrace.run] are worth keeping on the calls that
/// matter (a pull, a push, a backup); this decorator is the safety net that
/// makes the set of suspects complete, which matters because the alternative is
/// a stall report that lists only victims and is therefore useless.
class TracedDatabase implements Database {
  TracedDatabase(this._inner);

  final Database _inner;

  @override
  String get path => _inner.path;

  @override
  bool get isOpen => _inner.isOpen;

  /// sqflite returns `this` for a connection, and so does this: a call that
  /// reaches back through `.database` stays traced instead of escaping onto the
  /// raw handle. (The [Transaction] handed to a transaction body is sqflite's
  /// own, so `txn.database` does bypass the tracer - nothing in this codebase
  /// uses it, and `Database` documents it as "Calls in action must only be done
  /// using the transaction object".)
  @override
  Database get database => this;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) => DbTrace.run(
    'db.transaction',
    () => _inner.transaction<T>(action, exclusive: exclusive),
  );

  @override
  Future<T> readTransaction<T>(Future<T> Function(Transaction txn) action) =>
      DbTrace.run(
        'db.readTransaction',
        () => _inner.readTransaction<T>(action),
      );

  @override
  Future<void> close() => DbTrace.run('db.close', () => _inner.close());

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      DbTrace.run('db.execute', () => _inner.execute(sql, arguments));

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      DbTrace.run('db.rawInsert', () => _inner.rawInsert(sql, arguments));

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => DbTrace.run(
    'db.insert($table)',
    () => _inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => DbTrace.run(
    'db.query($table)',
    () => _inner.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => DbTrace.run('db.rawQuery', () => _inner.rawQuery(sql, arguments));

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) => DbTrace.run(
    'db.rawQueryCursor',
    () => _inner.rawQueryCursor(sql, arguments, bufferSize: bufferSize),
  );

  @override
  Future<QueryCursor> queryCursor(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
    int? bufferSize,
  }) => DbTrace.run(
    'db.queryCursor($table)',
    () => _inner.queryCursor(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      bufferSize: bufferSize,
    ),
  );

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      DbTrace.run('db.rawUpdate', () => _inner.rawUpdate(sql, arguments));

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => DbTrace.run(
    'db.update($table)',
    () => _inner.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    ),
  );

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      DbTrace.run('db.rawDelete', () => _inner.rawDelete(sql, arguments));

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      DbTrace.run(
        'db.delete($table)',
        () => _inner.delete(table, where: where, whereArgs: whereArgs),
      );

  /// Not traced: a [Batch] only records statements, it touches the connection
  /// when it is committed, and that commit is a transaction of its own which
  /// reaches the tracer through [Transaction]. Wrapping the builder would only
  /// measure how long it took to fill it.
  @override
  Batch batch() => _inner.batch();

  @override
  @Deprecated('Dev only')
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) =>
      _inner.devInvokeMethod<T>(method, arguments);

  @override
  @Deprecated('Dev only')
  Future<T> devInvokeSqlMethod<T>(
    String method,
    String sql, [
    List<Object?>? arguments,
  ]) => _inner.devInvokeSqlMethod<T>(method, sql, arguments);

  /// Deliberately **no** `noSuchMethod`.
  ///
  /// With one, Dart stops requiring the members above to be implemented and
  /// routes anything missing here instead - at runtime, with a stack from
  /// `noSuchMethod` that says nothing about which member was missing. That
  /// `batch()` was left out of this class for a while and only failed in
  /// `SettingsRepo.ensureDefaults`. Without it, an unimplemented member is a
  /// compile error naming the member, which is the right trade for a wrapper
  /// that has to stay faithful: if a future sqflite adds to the interface, the
  /// fix is to forward it here, not to discover it at runtime.
}

/// [Database.transaction] under [DbTrace], so a transaction that never commits
/// names itself instead of showing up as somebody else's 10-second lock wait.
Future<T> tracedTransaction<T>(
  Database db,
  String label,
  Future<T> Function(Transaction txn) body,
) => DbTrace.run(label, () => db.transaction<T>(body));
