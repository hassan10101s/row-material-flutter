import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';

import 'sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a bound cursor writer cannot move to a replacement organization file',
    () async {
      final fixture = await openSyncFixture();
      addTearDown(fixture.dispose);
      final metadata = SyncMetadata(fixture.helper);
      final original = metadata.bind(fixture.db);
      await fixture.helper.bindOrg('other_org');
      await expectLater(
        original.setCursor(
          'sample',
          const PullCursor('2026-10-25T10:00:00Z', 'old_response'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(await metadata.cursor('sample'), const PullCursor('', ''));
      await fixture.helper.close();
    },
  );

  test(
    'claim rechecks the session inside the transaction after waiting for SQLite',
    () async {
      final fixture = await openSyncFixture();
      addTearDown(fixture.dispose);
      await fixture.seedOrganization();
      final queue = SyncQueue(fixture.helper);
      final id = await fixture.db.insert(
        'inspections',
        sampleRow(entryCode: 'GUARDED'),
      );
      await fixture.transaction(
        (txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'GUARDED',
          localRef: id,
          operation: 'create',
          payload: const {'entryCode': 'GUARDED'},
        ),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocker = fixture.db.transaction((txn) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var active = true;
      final claim = queue.claim(
        checkCurrent: () {
          if (!active) throw StateError('session changed');
        },
      );
      final rejected = expectLater(claim, throwsStateError);
      active = false;
      release.complete();
      await blocker;
      await rejected;
      expect((await queue.listQueue()).single['status'], 'pending');
    },
  );
}
