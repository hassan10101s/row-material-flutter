import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/central_projection.dart';
import 'package:material_lab/core/commands/central_sync_driver.dart';
import 'package:material_lab/core/commands/central_sync_transport.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/firestore_direct_store.dart';
import 'package:material_lab/core/commands/firestore_direct_sync_reader.dart';
import 'package:material_lab/core/network/transient_network_error.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import '../sync/sync_test_fixture.dart';

class _InterruptedReads implements CentralSyncReader {
  int calls = 0;
  bool failing = true;
  @override
  Future<Map<String, dynamic>> call(Map<String, Object?> request) async {
    calls++;
    if (failing) {
      throw TransientNetworkError(StateError('Simulated closed header'));
    }
    return {'events': <Object>[], 'throughSequence': 0, 'hasMore': false};
  }
}

/// Raises CentralSyncGap on every head read: a server-side gap the local
/// cache can never heal. Without the storm guard this forced a full archive
/// re-walk (including the whole `materialBounds` family) on every 30-second
/// foreground tick.
class _GappingHead implements ConsistentCentralSyncReader {
  int heads = 0;

  @override
  Future<Map<String, dynamic>> call(Map<String, Object?> request) async {
    throw StateError('Events channel is not used by a gapping head');
  }

  @override
  Future<CentralReadBoundary> readHead() async {
    heads++;
    throw const CentralSyncGap();
  }

  @override
  Future<CentralRecordPage> readSnapshotPage(
    String entityType,
    CentralReadBoundary boundary, {
    String? after,
  }) async {
    throw const CentralSyncGap();
  }

  @override
  Future<CentralChangeSet> readChanges(
    int afterSequence,
    CentralReadBoundary boundary,
  ) async {
    throw const CentralSyncGap();
  }
}

/// Serves an empty snapshot page for every family except `referenceMaterial`,
/// which spans three pages (`m-1`, `m-2`, end). Page probes are logged so the
/// test can prove a resumed walk never re-reads a family that already
/// finished, and a simulated restart can be injected after page N.
class _ResumableWalk implements ConsistentCentralSyncReader {
  final Future<ApprovedRecord> Function(String id) materialFor;

  _ResumableWalk(this.materialFor);

  int heads = 0;
  int calls = 0;
  int failAtCall = -1;
  final pageLog = <String>[];

  @override
  Future<Map<String, dynamic>> call(Map<String, Object?> request) async {
    throw StateError('Events channel is not used by the walk reader');
  }

  @override
  Future<CentralReadBoundary> readHead() async {
    heads++;
    return const CentralReadBoundary(
      sequence: 7,
      readTime: '2026-11-10T10:00:00Z',
      manifestVersion: 1,
    );
  }

  @override
  Future<CentralRecordPage> readSnapshotPage(
    String entityType,
    CentralReadBoundary boundary, {
    String? after,
  }) async {
    calls++;
    if (calls == failAtCall) throw StateError('simulated restart');
    pageLog.add('$entityType/$after');
    if (entityType == 'referenceMaterial') {
      if (after == null) {
        return CentralRecordPage([await materialFor('m-1')], 'm-1');
      }
      if (after == 'm-1') {
        return CentralRecordPage([await materialFor('m-2')], 'm-2');
      }
      return const CentralRecordPage([], null);
    }
    return const CentralRecordPage([], null);
  }

  @override
  Future<CentralChangeSet> readChanges(
    int afterSequence,
    CentralReadBoundary boundary,
  ) async => const CentralChangeSet(records: [], operationIds: {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'quota pause survives automatic reconnect and manual refresh resumes the real store',
    () async {
      final fixture = await openSyncFixture();
      addTearDown(fixture.dispose);
      await fixture.seedOrganization();
      await fixture.db.insert('central_sync_state', {
        'organization_id': 'org_test',
        'uid': 'uid_admin',
        'role': 'admin',
        'bootstrap_state': 'ready',
        'protocol_schema': 3,
        'applied_sequence': 0,
      });
      const actor = AppSession(
        uid: 'uid_admin',
        organizationId: 'org_test',
        deviceId: 'device',
        role: 'admin',
        status: 'active',
      );
      final source = SessionSource(() => actor);
      var calls = 0;
      var exhausted = true;
      final store = FirestoreDirectStore(
        projectId: 'demo-materiallab',
        tokenProvider: () async => 'token',
        client: MockClient((request) async {
          calls++;
          if (exhausted) {
            return http.Response(
              jsonEncode({
                'error': {'status': 'RESOURCE_EXHAUSTED'},
              }),
              429,
            );
          }
          expect(request.url.path, endsWith(':batchGet'));
          return http.Response(
            jsonEncode([
              {
                'found': {
                  'name':
                      'projects/demo-materiallab/databases/(default)/documents/organizations/org_test/counters/changeSequence',
                  'fields': {
                    'value': {'integerValue': '0'},
                  },
                  'updateTime': '2026-11-08T10:00:00Z',
                },
                'readTime': '2026-11-08T11:00:00Z',
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(store.close);
      final driver = CentralSyncDriver(
        databaseHelper: fixture.helper,
        source: source,
        projection: CentralProjection(
          databaseHelper: fixture.helper,
          source: source,
        ),
        transport: FirestoreDirectSyncReader(
          store: store,
          source: source,
          manifest: () async => {},
        ),
        outbox: CommandOutbox(fixture.helper),
        metadata: SyncMetadata(fixture.helper),
        onManualRequest: store.resumeQuota,
      );
      final cached = await fixture.db.query('reference_materials');
      await driver.refreshForeground();
      expect(store.quotaPaused, isTrue);
      expect(calls, 1);
      exhausted = false;
      for (var i = 0; i < 4; i++) {
        await driver.refreshForeground(immediate: true);
      }
      expect(calls, 1, reason: 'Reconnect cannot reopen the quota gate');
      expect(await driver.syncNow(), 0);
      expect(store.quotaPaused, isFalse);
      expect(calls, 2);
      // A user-driven save/retry can reopen the shared store too. Its receipt
      // projection must restore foreground polling after the read succeeds.
      exhausted = true;
      await driver.refreshForeground();
      expect(store.quotaPaused, isTrue);
      exhausted = false;
      store.resumeQuota();
      expect(await driver.syncNow(resumeQuota: false), 0);
      final afterReceipt = calls;
      await driver.refreshForeground();
      expect(calls, afterReceipt + 1);
      expect(await fixture.db.query('reference_materials'), cached);
      expect(await fixture.db.query('command_outbox'), isEmpty);
    },
  );
  test(
    'automatic reads back off without losing cache; reconnect and manual reads can recover',
    () async {
      final fixture = await openSyncFixture();
      addTearDown(fixture.dispose);
      await fixture.seedOrganization();
      await fixture.db.insert('central_sync_state', {
        'organization_id': 'org_test',
        'uid': 'uid_admin',
        'role': 'admin',
        'bootstrap_state': 'ready',
        'protocol_schema': 3,
        'applied_sequence': 0,
      });
      const actor = AppSession(
        uid: 'uid_admin',
        organizationId: 'org_test',
        deviceId: 'device',
        role: 'admin',
        status: 'active',
      );
      final source = SessionSource(() => actor);
      final reader = _InterruptedReads();
      final metadata = SyncMetadata(fixture.helper);
      var now = DateTime(2026, 11, 2);
      var reports = 0;
      final driver = CentralSyncDriver(
        databaseHelper: fixture.helper,
        source: source,
        projection: CentralProjection(
          databaseHelper: fixture.helper,
          source: source,
        ),
        transport: reader,
        outbox: CommandOutbox(fixture.helper),
        metadata: metadata,
        interval: const Duration(seconds: 30),
        now: () => now,
        onError: (_) => reports++,
      );
      addTearDown(driver.stop);
      final cached = await fixture.db.query('reference_materials');
      await driver.refreshForeground();
      await driver.refreshForeground();
      expect(reader.calls, 1);
      expect(reports, 1);
      now = now.add(const Duration(seconds: 30));
      await driver.refreshForeground();
      expect(reader.calls, 2);
      now = now.add(const Duration(seconds: 30));
      await driver.refreshForeground();
      expect(reader.calls, 2, reason: 'Second failure waits sixty seconds');
      expect(reports, 1, reason: 'One diagnostic per continuous outage');
      expect(await fixture.db.query('reference_materials'), cached);
      expect(await fixture.db.query('command_outbox'), isEmpty);
      reader.failing = false;
      await driver.refreshForeground(immediate: true);
      expect(reader.calls, 3, reason: 'Reconnect bypasses the read backoff');
      expect(
        await metadata.get(SyncMetadata.lastErrorKey),
        anyOf(isNull, isEmpty),
      );
      reader.failing = true;
      await driver.refreshForeground();
      expect(reports, 2, reason: 'A new outage is reported after recovery');
      reader.failing = false;
      await driver.syncNow();
      expect(reader.calls, 5, reason: 'Explicit refresh remains available');
      expect(await fixture.db.query('reference_materials'), cached);
      expect(await fixture.db.query('command_outbox'), isEmpty);
    },
  );
  test('a persistent gap cannot re-walk the archive on every 30-second tick', () async {
    final fixture = await openSyncFixture();
    addTearDown(fixture.dispose);
    await fixture.seedOrganization();
    await fixture.db.insert('central_sync_state', {
      'organization_id': 'org_test',
      'uid': 'uid_admin',
      'role': 'admin',
      'bootstrap_state': 'ready',
      'protocol_schema': 3,
      'applied_sequence': 0,
    });
    const actor = AppSession(
      uid: 'uid_admin',
      organizationId: 'org_test',
      deviceId: 'device',
      role: 'admin',
      status: 'active',
    );
    final source = SessionSource(() => actor);
    final reader = _GappingHead();
    var now = DateTime(2026, 11, 10, 10);
    final driver = CentralSyncDriver(
      databaseHelper: fixture.helper,
      source: source,
      projection: CentralProjection(
        databaseHelper: fixture.helper,
        source: source,
      ),
      transport: reader,
      outbox: CommandOutbox(fixture.helper),
      metadata: SyncMetadata(fixture.helper),
      interval: const Duration(seconds: 30),
      now: () => now,
    );
    addTearDown(driver.stop);
    await driver.refreshForeground();
    expect(reader.heads, 1, reason: 'First gap attempt honestly retries');
    await driver.refreshForeground();
    expect(reader.heads, 1, reason: 'The storm guard defers the next tick');
    now = now.add(const Duration(seconds: 30));
    await driver.refreshForeground();
    expect(reader.heads, 1, reason: 'Still inside the 10-minute backoff');
    now = now.add(const Duration(minutes: 10, seconds: 1));
    await driver.refreshForeground();
    expect(reader.heads, 2, reason: 'After the backoff one attempt is allowed');
    try {
      await driver.syncNow();
    } on CentralSyncGap catch(_) {
      // Expected: the server-side gap persists past the guard.
    }
    expect(reader.heads, 3, reason: 'A manual refresh always bypasses the guard');
  });

  test(
    'an interrupted consistent walk resumes from its disk-staged cursor',
    () async {
      final fixture = await openSyncFixture();
      addTearDown(fixture.dispose);
      await fixture.seedOrganization();
      const actor = AppSession(
        uid: 'uid_admin',
        organizationId: 'org_test',
        deviceId: 'device',
        memberId: 'member',
        role: 'admin',
        status: 'active',
      );
      final source = SessionSource(() => actor);
      Future<ApprovedRecord> materialFor(String id) async {
        final raw =
            Map<String, dynamic>.from(
                (await fixture.db.query(
                  'reference_materials',
                  where: 'id = 1',
                )).single,
              )
              ..['id'] = 913
              ..['material_name'] = 'Resumed material $id'
              ..['material_code'] = 'RES-$id';
        final data = {
          ...buildRemotePayload(
            SyncEntity.byType('referenceMaterial')!,
            raw,
            const SyncPayloadContext(
              organizationId: 'org_test',
              uid: 'uid_admin',
              deviceId: 'origin',
              version: 1,
              versionField: 'version',
            ),
            asCreate: true,
          ),
          'organizationId': 'org_test',
          'remoteId': id,
          'version': 1,
          'createdBy': 'uid_admin',
          'updatedBy': 'uid_admin',
          'createdAt': '2026-11-10T00:00:00.000Z',
          'updatedAt': '2026-11-10T00:00:00.000Z',
          'deletedAt': null,
          'parentRefs': const <String, dynamic>{},
        };
        return ApprovedRecord(
          entityType: 'referenceMaterial',
          entityId: id,
          version: 1,
          data: data,
        );
      }

      final reader = _ResumableWalk(materialFor)..failAtCall = 4;
      final driver = CentralSyncDriver(
        databaseHelper: fixture.helper,
        source: source,
        projection: CentralProjection(
          databaseHelper: fixture.helper,
          source: source,
        ),
        transport: reader,
        outbox: CommandOutbox(fixture.helper),
        metadata: SyncMetadata(fixture.helper),
      );
      await expectLater(driver.syncNow(), throwsStateError);
      final firstPass = List.of(reader.pageLog);
      expect(firstPass, hasLength(3));
      final materialProbes = firstPass
          .where((probe) => probe.startsWith('referenceMaterial'))
          .toList();
      expect(
        materialProbes,
        isEmpty,
        reason: 'The fourth family walk stops before referenceMaterial',
      );

      reader.failAtCall = -1;
      await driver.syncNow();

      expect(reader.heads, 2);
      // The completed families keep exactly one probe each, and the
      // referenceMaterial pages were served exactly once.
      expect(reader.pageLog.toSet().length, reader.pageLog.length);
      expect(
        reader.pageLog.where((p) => p.startsWith('referenceMaterial')),
        ['referenceMaterial/null', 'referenceMaterial/m-1',
         'referenceMaterial/m-2'],
      );
      final m1 = (await fixture.db.query(
        'reference_materials',
        where: "remote_id = 'm-1'",
      )).single;
      final m2 = (await fixture.db.query(
        'reference_materials',
        where: "remote_id = 'm-2'",
      )).single;
      expect(m1['material_name'], 'Resumed material m-1');
      expect(m2['material_name'], 'Resumed material m-2');
      final state = (await fixture.db.query('central_sync_state')).single;
      expect(state['bootstrap_state'], 'ready');
      expect(state['applied_sequence'], 7);
      expect(await fixture.db.query('central_bootstrap_staging'), isEmpty);
      expect(await fixture.db.query('central_bootstrap_state'), isEmpty);
    },
  );
}
