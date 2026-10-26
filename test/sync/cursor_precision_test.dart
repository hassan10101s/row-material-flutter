import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_cursor_time.dart';

void main() {
  test('a Firestore cursor preserves all nanoseconds across persistence', () {
    final anchor = SyncCursorTime.parse('2026-10-25T10:00:00.123456789Z');
    expect(anchor.nanoseconds, 123456789);
    expect(anchor.iso, '2026-10-25T10:00:00.123456789Z');
    expect(SyncCursorTime.parse(anchor.iso).seconds, anchor.seconds);
    expect(
      SyncCursorTime.compare(
        '2026-10-25T10:00:00.123Z',
        '2026-10-25T10:00:00.123000001Z',
      ),
      lessThan(0),
    );
    expect(
      SyncCursorTime.compare(
        '2026-10-25T12:00:00.123+02:00',
        '2026-10-25T10:00:00.123000000Z',
      ),
      0,
    );
  });

  test(
    'exclusive one-row pages do not stall at a sub-microsecond anchor',
    () async {
      final remote = InMemoryDataSource();
      remote.seed(
        'org',
        SyncCollection.samples,
        'z',
        {},
        updatedAt: '2026-10-25T10:00:00.123456001Z',
      );
      remote.seed(
        'org',
        SyncCollection.samples,
        'a',
        {},
        updatedAt: '2026-10-25T10:00:00.123456002Z',
      );
      final first = await remote.listSince(
        organizationId: 'org',
        collection: SyncCollection.samples,
        limit: 1,
      );
      expect(first.documents.single.id, 'z');
      expect(first.hasMore, isTrue);
      final second = await remote.listSince(
        organizationId: 'org',
        collection: SyncCollection.samples,
        limit: 1,
        startAtTs: first.documents.single.updatedAt!,
        startAtId: 'z',
      );
      expect(second.documents.single.id, 'a');
      expect(second.hasMore, isFalse);
    },
  );
}
