import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/sync/backfill_service.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import '../sync/sync_test_fixture.dart';

class _Guard extends Mock implements WriteGuard {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an old synced recipe is replayed once with its parent identity after upgrade',
    () async {
      final fixture = await openSyncFixture();
      try {
        await fixture.db.insert('lab_inventory', {
          'id': 7,
          'name': 'Existing reagent',
          'category': 'powder',
          'unit': 'g',
          'remote_id': 'inventory-global-id',
          'created_at': '2026-01-01',
          'updated_at': '2026-01-01',
        });
        await fixture.db.insert('lab_analysis_items', {
          'id': 9,
          'analysis_id': 5,
          'inventory_id': 7,
          'qty_per_sample': 0.25,
          'unit': 'g',
          'version': 1,
          'remote_version': 1,
          'sync_state': 'synced',
        });
        // Reproduce a file from before the parent-stamp column was introduced.
        await fixture.db.execute(
          'ALTER TABLE lab_analysis_items DROP COLUMN inventory_remote_id',
        );
        await fixture.helper.close();
        final migrated = await fixture.helper.database;
        final row = (await migrated.query('lab_analysis_items')).single;
        expect(row['sync_state'], 'local');
        expect(row['qty_per_sample'], 0.25);
        expect(row['remote_version'], 1);
        final guard = _Guard();
        when(() => guard.organizationId).thenReturn('org');
        when(() => guard.uid).thenReturn('another-authorized-member');
        when(() => guard.deviceId).thenReturn('writer');
        when(() => guard.allows(any())).thenReturn(true);
        final queue = SyncQueue(fixture.helper);
        final result = await BackfillService(
          dbHelper: fixture.helper,
          queue: queue,
          guard: guard,
        ).enqueueUnsyncedAll(onlyTypes: {'labAnalysisItem'});
        expect(result.queued, 1);
        final payload =
            jsonDecode(
                  (await migrated.query('sync_queue')).single['payload']
                      as String,
                )
                as Map;
        expect(payload['inventoryRemoteId'], 'inventory-global-id');
        expect(payload.containsKey('createdBy'), isFalse);
        // A second open does not reset already acknowledged bookkeeping.
        await migrated.update('lab_analysis_items', {'sync_state': 'synced'});
        await fixture.helper.close();
        final reopened = await fixture.helper.database;
        expect(
          (await reopened.query('lab_analysis_items')).single['sync_state'],
          'synced',
        );
      } finally {
        await fixture.helper.close();
        await fixture.dispose();
      }
    },
  );
}
