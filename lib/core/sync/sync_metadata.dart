import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';

/// Pull cursor of one entity type: `{ts, id}` (plan §6.4).
class PullCursor {
  const PullCursor(this.timestamp, this.documentId);

  final String timestamp;
  final String documentId;

  bool get isEmpty => timestamp.isEmpty || documentId.isEmpty;

  Map<String, dynamic> toJson() => {'ts': timestamp, 'id': documentId};

  static PullCursor fromJson(Map<String, dynamic>? json) {
    if (json == null) return const PullCursor('', '');
    return PullCursor('${json['ts'] ?? ''}', '${json['id'] ?? ''}');
  }

  @override
  bool operator ==(Object other) =>
      other is PullCursor && other.timestamp == timestamp && other.documentId == documentId;

  @override
  int get hashCode => Object.hash(timestamp, documentId);
}

/// Key/value store on top of `sync_metadata`.
///
/// Keys (plan §6.4): `device_id`, `pull_cursor_<entity_type>`,
/// `last_pull_at`, `last_push_at`, `last_error`, `heartbeat_seen_at`,
/// `org_bound_at`.
class SyncMetadata {
  SyncMetadata(this.dbHelper) {
    // The memoized connection must not survive a restore or an organization
    // switch, otherwise cursors and markers would be written to the old file.
    dbHelper.onDatabaseClosed(() => _resolved = null);
  }

  final DatabaseHelper dbHelper;

  Database? _resolved;

  /// `DatabaseHelper.database` is a `Future`, so it has to be awaited; the
  /// result is memoized because the metadata is read/written per operation.
  Future<DatabaseExecutor> get _db async => _resolved ??= await dbHelper.database;

  static String deviceIdKey = 'device_id';
  static String lastPullAtKey = 'last_pull_at';
  static String lastPushAtKey = 'last_push_at';
  static String lastErrorKey = 'last_error';
  static String heartbeatSeenAtKey = 'heartbeat_seen_at';
  static String orgBoundAtKey = 'org_bound_at';
  static String lastFullSyncAtKey = 'last_full_sync_at';
  static String syncEnabledKey = 'sync_enabled';

  static String cursorKey(String entityType) => 'pull_cursor_$entityType';

  Future<String> get(String key) async {
    final db = await _db;
    final rows = await DbTrace.run(
        'metadata.get($key)',
        () => db.query('sync_metadata',
            where: 'key = ?', whereArgs: [key], limit: 1));
    if (rows.isEmpty) return '';
    return '${rows.first['value']}';
  }

  /// Several keys in one round trip.
  ///
  /// The status snapshot reads `last_pull_at`, `last_push_at`, `org_bound_at`
  /// and the sync flag. On the FFI factory each `get` is a separate message to
  /// the one shared background isolate, and a root-handle call holds the
  /// connection's non-reentrant lock while it waits, so four independent reads
  /// are four chances to queue up behind the rest of the app.
  Future<Map<String, String>> readAll(List<String> keys) async {
    if (keys.isEmpty) return const {};
    final placeholders = List.filled(keys.length, '?').join(',');
    final db = await _db;
    final rows = await DbTrace.run(
        'metadata.readAll(${keys.length})',
        () => db.rawQuery(
              'SELECT key, value FROM sync_metadata WHERE key IN ($placeholders)',
              keys,
            ));
    return {
      for (final row in rows) '${row['key']}': '${row['value']}',
    };
  }

  Future<void> set(String key, String value) async {
    final db = await _db;
    await DbTrace.run('metadata.set($key)', () => db.insert(
          'sync_metadata',
          {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        ));
  }

  Future<void> remove(String key) async {
    final db = await _db;
    await DbTrace.run('metadata.remove($key)',
        () => db.delete('sync_metadata', where: 'key = ?', whereArgs: [key]));
  }

  /// Generate (once) and persist the device UUID used for `device_registry`
  /// and the remote `devices/{deviceId}` document.
  Future<String> ensureDeviceId(String Function() generator) async {
    final existing = await get(deviceIdKey);
    if (existing.isNotEmpty) return existing;
    final generated = generator();
    await set(deviceIdKey, generated);
    return generated;
  }

  Future<PullCursor> cursor(String entityType) async {
    final raw = await get(cursorKey(entityType));
    if (raw.isEmpty) return const PullCursor('', '');
    try {
      return PullCursor.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const PullCursor('', '');
    }
  }

  Future<void> setCursor(String entityType, PullCursor cursor) =>
      set(cursorKey(entityType), jsonEncode(cursor.toJson()));

  Future<DateTime?> lastPullAt() => _date(lastPullAtKey);

  Future<void> markPull(DateTime at) => set(lastPullAtKey, at.toIso8601String());

  Future<DateTime?> lastPushAt() => _date(lastPushAtKey);

  Future<void> markPush(DateTime at) => set(lastPushAtKey, at.toIso8601String());

  Future<void> markHeartbeatSeen(DateTime at) =>
      set(heartbeatSeenAtKey, at.toIso8601String());

  Future<void> markOrgBound(DateTime at) =>
      set(orgBoundAtKey, at.toIso8601String());

  Future<void> markError(String? error) async {
    if (error == null || error.isEmpty) {
      await remove(lastErrorKey);
      return;
    }
    await set(lastErrorKey, error);
  }

  Future<String> lastError() => get(lastErrorKey);

  /// Master switch used by the Sync screen.
  Future<bool> isSyncEnabled() async => (await get(syncEnabledKey)) != '0';

  Future<void> setSyncEnabled(bool value) => set(syncEnabledKey, value ? '1' : '0');

  Future<DateTime?> _date(String key) async {
    final raw = await get(key);
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static String nowIsoString() => nowIso();
}
