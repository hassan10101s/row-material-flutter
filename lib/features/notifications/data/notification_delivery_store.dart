import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../../core/app_paths.dart';
import '../domain/push_event.dart';

class PushBinding {
  const PushBinding({
    required this.organizationId,
    required this.uid,
    required this.deviceId,
    this.samples = true,
    this.lab = true,
  });
  final String organizationId;
  final String uid;
  final String deviceId;
  final bool samples;
  final bool lab;
}

/// A tiny separate SQLite store shared by foreground, FCM and Workmanager.
/// Opening it does not run the organization's migrations or sync engine.
class NotificationDeliveryStore {
  NotificationDeliveryStore({AppPaths? paths, this._factory})
    : _paths = paths ?? AppPaths();
  final AppPaths _paths;
  final DatabaseFactory? _factory;
  Future<Database>? _opening;
  Future<Database> get _db async {
    final pending = _opening ??= _open();
    try {
      return await pending;
    } on Object {
      if (identical(_opening, pending)) _opening = null;
      rethrow;
    }
  }

  Future<Database> _open() async {
    final root = await _paths.appSupportRoot();
    await root.create(recursive: true);
    return (_factory ?? databaseFactory).openDatabase(
      p.join(root.path, 'notification_delivery.db'),
      options: OpenDatabaseOptions(
        singleInstance: false,
        version: 1,
        onConfigure: (db) async {
          // Android's SQLiteDatabase.execute rejects pragmas that return a
          // result row. busy_timeout returns the configured value.
          await db.rawQuery('PRAGMA busy_timeout = 5000');
        },
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE binding (id INTEGER PRIMARY KEY, organization_id TEXT NOT NULL, uid TEXT NOT NULL, device_id TEXT NOT NULL, samples INTEGER NOT NULL, lab INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE deliveries (event_key TEXT PRIMARY KEY, claimed_at INTEGER NOT NULL, delivered INTEGER NOT NULL DEFAULT 0)',
          );
        },
      ),
    );
  }

  Future<PushBinding?> binding() async {
    final rows = await (await _db).query('binding', where: 'id = 1');
    if (rows.isEmpty) return null;
    final r = rows.single;
    return PushBinding(
      organizationId: r['organization_id'] as String,
      uid: r['uid'] as String,
      deviceId: r['device_id'] as String,
      samples: r['samples'] == 1,
      lab: r['lab'] == 1,
    );
  }

  Future<void> bind(PushBinding? binding) async {
    final db = await _db;
    await db.transaction((tx) async {
      await tx.delete('binding');
      if (binding != null) {
        await tx.insert('binding', {
          'id': 1,
          'organization_id': binding.organizationId,
          'uid': binding.uid,
          'device_id': binding.deviceId,
          'samples': binding.samples ? 1 : 0,
          'lab': binding.lab ? 1 : 0,
        });
      }
      // Bound storage; old acknowledged keys need not grow indefinitely.
      await tx.delete(
        'deliveries',
        where: 'claimed_at < ?',
        whereArgs: [
          DateTime.now()
              .subtract(const Duration(days: 30))
              .millisecondsSinceEpoch,
        ],
      );
    });
  }

  Future<bool> claim(PushEvent event) async {
    final db = await _db;
    return db.transaction((tx) async {
      final rows = await tx.query('binding', where: 'id = 1');
      if (rows.isEmpty) return false;
      final b = rows.single;
      if (b['organization_id'] != event.organizationId ||
          (event.sourceDeviceId.isNotEmpty &&
              event.sourceDeviceId == b['device_id']) ||
          // Decisions surface on the inspections screen; they need the same
          // read permission as inspection content.
          (event.kind == 'lab' ? b['lab'] != 1 : b['samples'] != 1)) {
        return false;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final existing = await tx.query(
        'deliveries',
        where: 'event_key = ?',
        whereArgs: [event.key],
      );
      if (existing.isNotEmpty &&
          (existing.single['delivered'] == 1 ||
              now - (existing.single['claimed_at'] as int) < 60000)) {
        return false;
      }
      await tx.insert('deliveries', {
        'event_key': event.key,
        'claimed_at': now,
        'delivered': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  Future<void> complete(PushEvent event) async => (await _db).update(
    'deliveries',
    {'delivered': 1},
    where: 'event_key = ?',
    whereArgs: [event.key],
  );
  Future<void> release(PushEvent event) async => (await _db).delete(
    'deliveries',
    where: 'event_key = ? AND delivered = 0',
    whereArgs: [event.key],
  );
  Future<void> close() async {
    final db = _opening;
    _opening = null;
    if (db != null) await (await db).close();
  }

  static String tag(PushEvent event) =>
      sha256.convert(utf8.encode(event.key)).toString();
  static int notificationId(PushEvent event) =>
      int.parse(tag(event).substring(0, 8), radix: 16) & 0x7fffffff;
}
