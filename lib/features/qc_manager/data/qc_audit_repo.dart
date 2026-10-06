import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../core/audit/audit_hasher.dart';
import '../../../core/auth/app_session.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../domain/qc_audit.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_repositories.dart';

/// Who performed an audit event.
///
/// Read from the live session at write time rather than passed in by the caller:
/// an audit trail whose author is chosen by the code doing the writing is not an
/// audit trail. [QcAuditRepo.append] takes no actor argument at all, so there is
/// no way to attribute an edit to somebody who did not make it.
class QcActor {
  const QcActor({
    this.uid = '',
    this.name = '',
    this.deviceId = '',
    this.ipAddress = '',
  });

  final String uid;
  final String name;
  final String deviceId;
  final String ipAddress;

  static const QcActor unknown = QcActor();

  /// Projects the signed-in session onto an audit actor.
  ///
  /// Lives here rather than as a closure in `service_locator.dart` because it is
  /// the rule that decides who a QC audit row names, and a rule that is only
  /// reachable by booting Firebase is a rule nobody checks.
  ///
  /// Two details are deliberate:
  ///
  ///  * a signed-out session yields [unknown] rather than a row with empty
  ///    fields, so "nobody" is visibly different from "somebody whose name we
  ///    lost";
  ///  * `displayName` is preferred over `email`, because a QC trail is read by
  ///    people during an audit. An account can legitimately have no display name,
  ///    in which case the email is the honest fallback rather than a blank.
  factory QcActor.fromSession(AppSession session) {
    if (!session.isSignedIn) return unknown;
    return QcActor(
      uid: session.uid,
      name: session.displayName.isNotEmpty
          ? session.displayName
          : session.email,
      deviceId: session.deviceId,
    );
  }
}

/// Local, append-only repository over `qc_audits` (plan V6_ENHANCED §21).
///
/// ## There is deliberately no update or delete
/// Not as an omission - as the feature. The class exposes `append`, `get`,
/// `list`, `count` and `verifyChain`, and nothing that could rewrite a committed
/// row. Three independent layers keep it that way:
///
///  1. this class has no mutator,
///  2. `QcAuditRepository` (the domain contract) does not declare one, and
///  3. SQLite triggers `qc_audits_block_update` / `qc_audits_block_delete`
///     reject the statement outright, so even a direct `db.update` fails.
///
/// `prev_hash`/`hash` then make tampering *detectable* on top of that, which is
/// the property that survives a restore from an old backup or a tampered file.
class QcAuditRepo implements QcAuditRepository {
  QcAuditRepo({required this.dbHelper, this.actorReader});

  final DatabaseHelper dbHelper;

  /// Live actor reader, mirroring `AuditLogger.sessionReader`: the signed-in
  /// user is resolved at write time, so a sign-out or a user switch cannot
  /// mis-attribute an entry.
  final QcActor Function()? actorReader;

  static const String table = 'qc_audits';

  /// What the repository knows, or what [fallback] carries.
  QcActor actor([QcActor? fallback]) {
    final read = actorReader?.call();
    if (read == null) return fallback ?? QcActor.unknown;
    return read;
  }

  Future<Database> get _db => dbHelper.database;

  /// Appends one entry to the chain and returns its id.
  ///
  /// Pass [exec] to commit inside a caller's transaction, which is how the
  /// offline-first facade guarantees that a state change and its audit row land
  /// together or not at all.
  ///
  /// When no [exec] is supplied this opens its **own** transaction. That is not
  /// tidiness: reading the chain head and inserting the new row have to be one
  /// atomic step, otherwise two writes that overlap - two cubits saving at once,
  /// or eight futures released together - both read the same head and both link
  /// onto it, silently forking the chain. sqflite serialises transactions on the
  /// single connection, which is what makes the read-then-write safe here.
  @override
  Future<int> append({
    required String entityType,
    required String entityId,
    required String action,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    Map<String, dynamic>? meta,
    QcActor? actorOverride,
    String? atOverride,
    DatabaseExecutor? exec,
  }) async {
    if (!QcAuditEntity.all.contains(entityType)) {
      throw ValidationError(
        'Unknown QC audit entity type "$entityType". '
        'Known types: ${QcAuditEntity.all.join(', ')}',
      );
    }
    if (action.trim().isEmpty) {
      throw const ValidationError('An audit action is required');
    }

    // Validation is deliberately before the `exec` branch and before any DB
    // work, so a bad call cannot half-write. `async` (rather than throwing
    // synchronously) keeps the error on the Future, which is the only error path
    // a caller has to handle.
    if (exec != null) {
      return _insert(
        exec,
        entityType,
        entityId,
        action,
        before,
        after,
        meta,
        actorOverride,
        atOverride,
      );
    }
    final db = await _db;
    return db.transaction(
      (txn) => _insert(
        txn,
        entityType,
        entityId,
        action,
        before,
        after,
        meta,
        actorOverride,
        atOverride,
      ),
    );
  }

  Future<int> _insert(
    DatabaseExecutor txn,
    String entityType,
    String entityId,
    String action,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    Map<String, dynamic>? meta,
    QcActor? actorOverride,
    String? atOverride,
  ) async {
    final who = actor(actorOverride);
    final at = (atOverride == null || atOverride.isEmpty)
        ? nowIso()
        : atOverride;

    // Read the head *inside* the transaction, so it cannot change between this
    // read and the insert below.
    final prevHash = await AuditHasher.computePrevHash(txn, table: table) ?? '';

    final row = <String, Object?>{
      'entity_type': entityType,
      'entity_id': entityId,
      'action': action,
      'by_user_id': who.uid,
      'by_user_name': who.name,
      'at': at,
      // Snapshots are stored as the exact canonical text that was hashed, so a
      // verifier re-hashes what is on disk instead of a re-serialized guess.
      'before_json': _snapshot(before),
      'after_json': _snapshot(after),
      'meta_json': _snapshot(meta),
      'prev_hash': prevHash,
      'immutable': 1,
      'ip_address': who.ipAddress,
      'device_id': who.deviceId,
    };
    row['hash'] = AuditHasher.hash(row);

    return txn.insert(table, row);
  }

  /// Canonical JSON for a snapshot column; an absent snapshot is an empty
  /// string rather than null, matching what the hasher expects.
  static String _snapshot(Map<String, dynamic>? value) =>
      value == null ? '' : AuditHasher.canonicalize(value);

  @override
  Future<QcAudit?> get(int id, {DatabaseExecutor? exec}) async {
    final db = await _db;
    final rows = await db.query(
      table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcAudit.fromMap(Map<String, dynamic>.from(rows.first));
  }

  @override
  Future<List<QcAudit>> list({
    String entityType = '',
    String entityId = '',
    String action = '',
    int limit = 200,
    int offset = 0,
    DatabaseExecutor? exec,
  }) async {
    final db = await _db;
    final where = <String>[];
    final args = <Object?>[];
    if (entityType.isNotEmpty) {
      where.add('entity_type = ?');
      args.add(entityType);
    }
    if (entityId.isNotEmpty) {
      where.add('entity_id = ?');
      args.add(entityId);
    }
    if (action.isNotEmpty) {
      where.add('action = ?');
      args.add(action);
    }
    final rows = await db.query(
      table,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'id DESC',
      limit: limit,
      offset: offset,
    );
    return rows
        .map((r) => QcAudit.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  @override
  Future<int> count({
    String entityType = '',
    String entityId = '',
    DatabaseExecutor? exec,
  }) async {
    final db = await _db;
    final where = <String>[];
    final args = <Object?>[];
    if (entityType.isNotEmpty) {
      where.add('entity_type = ?');
      args.add(entityType);
    }
    if (entityId.isNotEmpty) {
      where.add('entity_id = ?');
      args.add(entityId);
    }
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM $table'
      '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}',
      args,
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Re-derives the whole chain. See `AuditHasher.verifyChain` for what is
  /// checked; the result is translated into the feature's own type so that
  /// `lib/core` never has to know about `lib/features`.
  @override
  Future<QcChainVerification> verifyChain({
    int? limit,
    DatabaseExecutor? exec,
  }) async {
    final db = await _db;
    final rows = await db.query(table, orderBy: 'id ASC, at ASC', limit: limit);
    final result = AuditHasher.verifyChain(rows);
    return QcChainVerification(
      isValid: result.isValid,
      checked: result.checked,
      brokenAt: result.brokenAt,
      reason: result.reason,
      headHash: result.headHash,
    );
  }

  /// Exports the trail as JSON text, chain head included, for an auditor or an
  /// offline archive. Read-only, so it needs no guard.
  Future<String> exportJson({int? limit, DatabaseExecutor? exec}) async {
    final db = await _db;
    final rows = await db.query(table, orderBy: 'id ASC, at ASC', limit: limit);
    final verification = await verifyChain(limit: limit, exec: exec);
    return jsonEncode({
      'exported_at': nowIso(),
      'row_count': rows.length,
      'chain_valid': verification.isValid,
      'broken_at': verification.brokenAt,
      'reason': verification.reason,
      'head_hash': verification.headHash,
      'rows': [
        for (final r in rows)
          QcAudit.fromMap(Map<String, dynamic>.from(r)).toMap(),
      ],
    });
  }
}
