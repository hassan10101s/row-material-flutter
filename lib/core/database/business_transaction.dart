import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:async';

/// Identifies rows actually created by this authoring operation. Registry
/// maintenance must not sweep historical local rows into a new user's request.
abstract final class BusinessAuthoringContext {
  static const _key = #materialLabAuthoringSequences;
  static const _aggregateKey = #materialLabAggregateEffects;

  /// Explicitly declares local candidate rows represented inside one shared
  /// aggregate. The gateway still requires that aggregate's remote effect.
  static void representedByAnalysis(String type, int localId, int analysisId) {
    final represented = Zone.current[_aggregateKey] as Map<String, String>?;
    represented?['$type/$localId'] = 'labAnalysis/$analysisId';
  }

  static int? newRowFloor(String table) =>
      (Zone.current[_key] as Map<String, int>?)?[table] ??
      (Zone.current[_key] == null ? null : 0);

  /// Null outside captured authoring. Used to queue actual changes instead
  /// of rewriting unchanged references (and spending atomic-operation slots).
  static Future<Set<int>?> changedRows(
    DatabaseExecutor txn,
    String entityType,
  ) async {
    if (Zone.current[_key] == null) return null;
    final rows = await txn.query(
      'central_capture_changes',
      columns: ['local_ref'],
      where: 'entity_type = ?',
      whereArgs: [entityType],
    );
    return {for (final row in rows) int.parse('${row['local_ref']}')};
  }

  static Future<T> run<T>(
    Map<String, int> initialSequences,
    Future<T> Function() action, {
    Map<String, String>? aggregateEffects,
  }) => runZoned(
    action,
    zoneValues: {
      _key: Map<String, int>.unmodifiable(initialSequences),
      _aggregateKey: aggregateEffects,
    },
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
