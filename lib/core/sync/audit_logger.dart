import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../auth/app_session.dart';
import '../utils/app_dates.dart';
import 'entity_registry.dart';
import 'sync_codec.dart';
import 'sync_queue.dart';

/// Audit actions (plan §9.7).
abstract final class AuditAction {
  static const String organizationCreated = 'ORGANIZATION_CREATED';
  static const String memberInvited = 'MEMBER_INVITED';
  static const String memberActivated = 'MEMBER_ACTIVATED';
  static const String memberRoleChanged = 'MEMBER_ROLE_CHANGED';
  static const String memberDisabled = 'MEMBER_DISABLED';
  static const String deniedEntry = 'DENIED_ENTRY';
  static const String sampleCreated = 'SAMPLE_CREATED';
  static const String sampleUpdated = 'SAMPLE_UPDATED';
  static const String sampleDeleted = 'SAMPLE_DELETED';
  static const String qcApproved = 'QC_APPROVED';
  static const String qcRejected = 'QC_REJECTED';
  static const String labResultSaved = 'LAB_RESULT_SAVED';
  static const String syncConflict = 'SYNC_CONFLICT';
  static const String backupRestored = 'BACKUP_RESTORED';
  static const String settingsUpdated = 'SETTINGS_UPDATED';
  static const String deviceRegistered = 'DEVICE_REGISTERED';
}

/// Writes `audit_logs` **in the same transaction** as the business write
/// (outbox pattern) and enqueues the matching `sync_queue` row so the entry
/// reaches `organizations/{orgId}/auditLogs` (append-only, plan §9.7).
class AuditLogger {
  AuditLogger({required this.queue, AppSession Function()? session}) : sessionReader = session;

  final SyncQueue queue;

  String deviceId = '';
  String organizationId = '';
  String uid = '';
  String userName = '';

  /// Live session reader (plan §9.7). The actor, the organization and the
  /// device of an audit entry must never be guessed: they are read from the
  /// signed-in session at write time, so a sign-out or a user switch cannot
  /// mis-attribute an entry. [configure] and the fields above stay for callers
  /// that hold an explicit session (and for the tests).
  AppSession Function()? sessionReader;

  void configure(AppSession session) {
    deviceId = session.deviceId;
    organizationId = session.organizationId;
    uid = session.uid;
    userName = session.displayName.isNotEmpty ? session.displayName : session.email;
  }

  Future<int> log(
    DatabaseExecutor txn, {
    required String action,
    required String entityType,
    required String entityId,
    Map<String, dynamic>? details,
  }) async {
    final session = sessionReader?.call();
    final org = organizationId.isNotEmpty ? organizationId : (session?.organizationId ?? '');
    final actor = uid.isNotEmpty ? uid : (session?.uid ?? '');
    final name = userName.isNotEmpty
        ? userName
        : (session == null
            ? ''
            : (session.displayName.isNotEmpty ? session.displayName : session.email));
    final device = deviceId.isNotEmpty
        ? deviceId
        : (session == null || session.deviceId.isEmpty ? 'unknown' : session.deviceId);
    final occurredAt = nowIso();
    // Single sanitized encode reused for both columns: the old code encoded
    // twice and threw on DateTime/Timestamp details, aborting the business txn.
    final detailsJson =
        details == null ? null : SyncCodec.encode(_redact(details));
    final id = await txn.insert('audit_logs', {
      'user_id': actor.isEmpty ? null : actor,
      'user_name': name.isEmpty ? null : name,
      'organization_id': org,
      'action': action,
      'entity_type': entityType,
      'entity_id': entityId,
      'details_json': detailsJson,
      'device_id': device,
      'occurred_at': occurredAt,
      'version': 1,
      'sync_state': 'queued',
    });
    // Exactly the ten keys the Rules allow for `auditLogs` (append-only, and
    // `hasOnly` rejects anything else - a rejected audit push would silently
    // drop the trail of a write that *did* happen locally). `occurredAt` stays
    // a plain string so a pulled document lands with the same `occurred_at`
    // the local screen sorts and filters by.
    final payload = <String, dynamic>{
      'organizationId': org,
      'userId': actor,
      'userName': name,
      'action': action,
      'entityType': entityType,
      'entityId': entityId,
      'detailsJson': detailsJson,
      'deviceId': device,
      'occurredAt': occurredAt,
      'version': 1,
    };
    assert(() {
      const allowed = <String>{
        'userId', 'userName', 'organizationId', 'action', 'entityType', 'entityId',
        'detailsJson', 'deviceId', 'occurredAt', 'version',
      };
      final extra = payload.keys.where((k) => !allowed.contains(k)).toList();
      if (extra.isNotEmpty) {
        throw StateError('audit payload carries keys the Rules reject: $extra');
      }
      return true;
    }());
    await queue.enqueue(
      txn,
      entityType: auditLogEntity.type,
      entityId: auditLogEntity.docId({'device_id': device, 'occurred_at': occurredAt, 'id': id}),
      localRef: id,
      operation: 'create',
      payload: payload,
    );
    return id;
  }

  /// Never write secrets, tokens or password hashes to the audit trail.
  static const Set<String> _sensitiveKeys = {
    'password',
    'password_hash',
    'token',
    'id_token',
    'idToken',
    'secret',
    'apiKey',
    'api_key',
  };

  /// Deep redact + leave sanitization to [SyncCodec]: nested maps/lists are
  /// walked so a `token` buried one level down never reaches the trail, and
  /// DateTime/Timestamp values survive as ISO strings instead of crashing
  /// `jsonEncode`.
  static Map<String, dynamic> _redact(Map<String, dynamic> details) {
    final out = <String, dynamic>{};
    for (final entry in details.entries) {
      final key = entry.key;
      if (_sensitiveKeys.contains(key)) {
        out[key] = '***';
        continue;
      }
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        out[key] = _redact(value);
      } else if (value is Map) {
        out[key] = _redact({
          for (final e in value.entries) '${e.key}': e.value,
        });
      } else if (value is List) {
        out[key] = [
          for (final item in value)
            if (item is Map<String, dynamic>)
              _redact(item)
            else if (item is Map)
              _redact({
                for (final e in item.entries) '${e.key}': e.value,
              })
            else
              item,
        ];
      } else {
        out[key] = value;
      }
    }
    return out;
  }

  /// Housekeeping: drop rows that reached the server and are older than
  /// [retention], then cap the local table at [maxRows] (plan §9.7).
  ///
  /// `sync_state` is the canonical marker - `SyncQueue.markDone` writes it -
  /// the legacy `synced` column is never updated any more.
  Future<void> prune({int maxRows = 20000, Duration retention = const Duration(days: 90)}) async {
    final db = await queue.dbHelper.database;
    await db.rawDelete(
      "DELETE FROM audit_logs WHERE sync_state = 'synced' AND occurred_at < ?",
      [nowIsoAt(DateTime.now().subtract(retention))],
    );
    await db.rawDelete(
      'DELETE FROM audit_logs WHERE id NOT IN ('
      '  SELECT id FROM audit_logs ORDER BY id DESC LIMIT ?)',
      [maxRows],
    );
  }

  /// Paged read for the audit screen (`audit.read` only).
  ///
  /// The date bounds are written in the **same** format `occurred_at` uses
  /// (`yyyy-MM-dd HH:mm:ss`), otherwise the string comparison in SQLite would
  /// compare `' '` (0x20) with `'T'` (0x54) and silently return nothing.
  Future<List<Map<String, Object?>>> query({
    String? entityType,
    String? action,
    DateTime? from,
    DateTime? to,
    int limit = 200,
    int offset = 0,
  }) async {
    final db = await queue.dbHelper.database;
    final where = <String>[];
    final args = <Object?>[];
    if (entityType != null && entityType.isNotEmpty) {
      where.add('entity_type = ?');
      args.add(entityType);
    }
    if (action != null && action.isNotEmpty) {
      where.add('action = ?');
      args.add(action);
    }
    if (from != null) {
      where.add('occurred_at >= ?');
      args.add(nowIsoAt(from));
    }
    if (to != null) {
      where.add('occurred_at <= ?');
      args.add(nowIsoAt(to));
    }
    return db.query(
      'audit_logs',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'occurred_at DESC, id DESC',
      limit: limit,
      offset: offset,
    );
  }

  /// How many entries match the same filters - the screen needs it to know
  /// whether another page exists.
  Future<int> count({
    String? entityType,
    String? action,
    DateTime? from,
    DateTime? to,
  }) async {
    final db = await queue.dbHelper.database;
    final where = <String>[];
    final args = <Object?>[];
    if (entityType != null && entityType.isNotEmpty) {
      where.add('entity_type = ?');
      args.add(entityType);
    }
    if (action != null && action.isNotEmpty) {
      where.add('action = ?');
      args.add(action);
    }
    if (from != null) {
      where.add('occurred_at >= ?');
      args.add(nowIsoAt(from));
    }
    if (to != null) {
      where.add('occurred_at <= ?');
      args.add(nowIsoAt(to));
    }
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM audit_logs'
      '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}',
      args,
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Distinct `entity_type` / `action` values present locally, for the filter
  /// dropdowns of the audit screen.
  Future<({List<String> entityTypes, List<String> actions})> facets() async {
    final db = await queue.dbHelper.database;
    final types = await db.rawQuery(
        'SELECT DISTINCT entity_type AS v FROM audit_logs ORDER BY v');
    final actions = await db.rawQuery(
        'SELECT DISTINCT action AS v FROM audit_logs ORDER BY v');
    return (
      entityTypes: types.map((r) => '${r['v']}').toList(),
      actions: actions.map((r) => '${r['v']}').toList(),
    );
  }
}
