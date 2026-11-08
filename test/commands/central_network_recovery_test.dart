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
}
