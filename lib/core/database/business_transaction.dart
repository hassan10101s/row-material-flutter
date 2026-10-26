import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:async';

/// Identifies rows actually created by this authoring operation. Registry
/// maintenance must not sweep historical local rows into a new user's request.
abstract final class BusinessAuthoringContext {
  static const _key = #materialLabAuthoringSequences;
  static int? newRowFloor(String table) =>
      (Zone.current[_key] as Map<String, int>?)?[table] ??
      (Zone.current[_key] == null ? null : 0);

  static Future<T> run<T>(
    Map<String, int> initialSequences,
    Future<T> Function() action,
  ) => runZoned(
    action,
    zoneValues: {_key: Map<String, int>.unmodifiable(initialSequences)},
  );
}

/// An authoring boundary, distinct from transactions that apply server data.
/// Repositories provide their existing business operation as one unit; a
/// central implementation can stage the whole unit without changing the
/// approved tables before the server has accepted it.
abstract interface class BusinessTransactionGateway {
  Future<T> run<T>(
    Database database,
    Future<T> Function(DatabaseExecutor executor) operation,
  );
}
