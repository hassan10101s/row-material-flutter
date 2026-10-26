import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// Serializes foreground and Workmanager cycles using the same SQLite file.
/// An in-memory single-flight flag cannot protect two Dart isolates/processes.
class SyncCycleLease {
  SyncCycleLease(this.db);

  final Database db;
  final String owner = const Uuid().v4();
  Timer? _renewal;
  bool _held = false;
  int _expiresAt = 0;
  bool get held {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _held && _expiresAt > now && _expiresAt <= now + ttlMs + 60000;
  }

  bool _renewing = false;
  static const key = 'legacy-sync-cycle';
  static const ttlMs = 120000;

  Future<bool> acquire() async {
    _held = await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final existing = await txn.query(
        'sync_runtime_leases',
        where: 'lease_key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final until = existing.single['expires_at'] as int;
        if (until > now && until <= now + ttlMs + 60000) return false;
      }
      _expiresAt = now + ttlMs;
      await txn.insert('sync_runtime_leases', {
        'lease_key': key,
        'owner': owner,
        'expires_at': now + ttlMs,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
    if (held) {
      _renewal = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(_renew());
      });
    }
    return held;
  }

  Future<void> _renew() async {
    if (!held || _renewing) return;
    _renewing = true;
    try {
      final until = DateTime.now().millisecondsSinceEpoch + ttlMs;
      final count = await db.update(
        'sync_runtime_leases',
        {'expires_at': until},
        where: 'lease_key = ? AND owner = ?',
        whereArgs: [key, owner],
      );
      if (count != 1) {
        _held = false;
      } else {
        _expiresAt = until;
      }
    } on Object {
      _held = false;
    } finally {
      _renewing = false;
    }
  }

  Future<void> release() async {
    _renewal?.cancel();
    _held = false;
    try {
      // The original handle is intentional: never release a replacement
      // organization's lease after this database was closed.
      await db.delete(
        'sync_runtime_leases',
        where: 'lease_key = ? AND owner = ?',
        whereArgs: [key, owner],
      );
    } on Object {
      // Closing the old file leaves an expiring lease, not an active worker.
    }
  }
}
