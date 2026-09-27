import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/sync/presentation/sync_status_controller.dart';

import 'sync_test_fixture.dart';

/// The badge must never lie: it reads the counters of the real queue and the
/// real metadata (plan §14-P8.1).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncFixture fixture;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late StreamController<bool> connectivity;
  late bool online;

  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    queue = SyncQueue(fixture.helper);
    metadata = SyncMetadata(fixture.helper);
    connectivity = StreamController<bool>.broadcast();
    online = true;
  });

  tearDown(() async {
    await connectivity.close();
    await fixture.dispose();
  });

  SyncStatusController controller() => SyncStatusController(
        queue: queue,
        metadata: metadata,
        isOnline: () => online,
        connectivityChanges: connectivity.stream,
        refreshInterval: const Duration(days: 1),
      );

  Future<void> enqueueSample(String entryCode) => fixture.transaction((txn) => queue.enqueue(
        txn,
        entityType: 'sample',
        entityId: entryCode,
        localRef: 1,
        operation: 'create',
        payload: <String, dynamic>{'entryCode': entryCode},
      ));

  Future<void> insertBlocked(String entryCode) => fixture.db.insert('sync_queue', {
        'entity_type': 'sample',
        'entity_id': entryCode,
        'operation': 'update',
        'payload': jsonEncode(<String, dynamic>{'entryCode': entryCode}),
        'created_at': '2026-09-01 08:00:00',
        'updated_at': '2026-09-01 08:00:00',
        'status': 'conflict',
        'last_error': 'push_rejected',
      });

  test('the initial state follows the connectivity signal', () {
    online = false;
    final c = controller();
    addTearDown(c.dispose);
    expect(c.status.online, isFalse);
    expect(c.status.pending, 0);
    expect(c.status.blocked, 0);
    expect(c.status.lastSync, isNull);
  });

  test('refresh reports the pending and blocked rows of the queue', () async {
    final c = controller();
    addTearDown(c.dispose);
    await enqueueSample('S-1');
    await enqueueSample('S-2');
    await insertBlocked('S-3');

    await c.refresh();
    expect(c.status.pending, 2);
    expect(c.status.blocked, 1);
    expect(c.status.hasWork, isTrue);
  });

  test('listeners are notified only when something actually changed', () async {
    final c = controller();
    addTearDown(c.dispose);
    var notifications = 0;
    c.addListener(() => notifications++);

    await c.refresh();
    expect(notifications, 0, reason: 'nothing changed yet');

    await enqueueSample('S-1');
    await c.refresh();
    expect(notifications, 1);

    await c.refresh();
    expect(notifications, 1, reason: 'a second identical refresh is silent');
  });

  test('lastSync is the most recent successful push or pull', () async {
    final c = controller();
    addTearDown(c.dispose);
    await metadata.markPush(DateTime(2026, 9, 1, 10));
    await metadata.markPull(DateTime(2026, 9, 2, 11));
    await c.refresh();
    expect(c.status.lastSync, DateTime(2026, 9, 2, 11));

    await metadata.markPush(DateTime(2026, 9, 3, 9));
    await c.refresh();
    expect(c.status.lastSync, DateTime(2026, 9, 3, 9), reason: 'push wins when newer');

    await metadata.remove(SyncMetadata.lastPushAtKey);
    await metadata.remove(SyncMetadata.lastPullAtKey);
    await c.refresh();
    expect(c.status.lastSync, isNull, reason: 'a fresh install has never synced');
  });

  test('coming back online refreshes the counters', () async {
    final c = controller();
    addTearDown(c.dispose);
    online = false;
    connectivity.add(false);
    await c.refresh();
    expect(c.status.online, isFalse);

    await enqueueSample('S-1');
    online = true;
    connectivity.add(true);
    // The stream handler refreshes asynchronously; give it a turn.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.status.online, isTrue);
    expect(c.status.pending, 1);
  });

  test('a failing refresh keeps the last known values', () async {
    final c = controller();
    addTearDown(c.dispose);
    await enqueueSample('S-1');
    await c.refresh();
    expect(c.status.pending, 1);

    await fixture.db.close();
    await c.refresh(); // must not throw
    expect(c.status.pending, 1, reason: 'the badge keeps showing what it knew');
  });
}
