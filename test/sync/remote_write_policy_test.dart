import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/sync/remote_write_policy.dart';
import 'package:material_lab/core/sync/sync_codec.dart';

Map<String, dynamic> _record({int version = 4}) => {
  'organizationId': 'org',
  'localId': 7,
  'createdBy': 'original-author',
  'createdAt': 'original-server-time',
  'updatedBy': 'writer',
  'deviceId': 'desktop',
  'version': version,
  'updatedAt': 'server-time',
  'remoteId': 'stable-uuid',
  'sampleName': 'A',
  'deletedAt': null,
};

void main() {
  test(
    'an acknowledged row missing remotely is recreated with a complete v1 envelope',
    () {
      final data = _record()
        ..remove('createdAt')
        ..remove('createdBy');
      final plan = RemoteWritePolicy.plan(
        organizationId: 'org',
        data: data,
        baseVersion: 4,
      );
      expect(plan.refusal, isNull);
      expect(plan.version, 1);
      expect(plan.payload['createdAt'], SyncCodec.serverTimestampPlaceholder);
      expect(plan.payload['createdBy'], 'writer');
      expect(plan.payload['localId'], 7);
    },
  );

  test(
    'a second device updates content without overwriting original identity',
    () {
      final incoming = _record()
        ..addAll({
          'localId': 900,
          'createdBy': 'other-author',
          'createdAt': 'device-time',
          'remoteId': 'local-alias',
          'sampleName': 'Edited',
        });
      final current = _record();
      final plan = RemoteWritePolicy.plan(
        organizationId: 'org',
        data: incoming,
        baseVersion: 4,
        current: current,
      );
      expect(plan.refusal, isNull);
      expect(plan.version, 5);
      expect(plan.payload.keys, isNot(contains('localId')));
      expect(plan.payload.keys, isNot(contains('createdAt')));
      expect(plan.payload.keys, isNot(contains('createdBy')));
      expect(plan.payload.keys, isNot(contains('remoteId')));
      final stored = {...current, ...plan.payload};
      expect(stored['sampleName'], 'Edited');
      expect(stored['localId'], 7);
      expect(stored['createdBy'], 'original-author');
      expect(stored['remoteId'], 'stable-uuid');
    },
  );

  test(
    'lost commit acknowledgements are idempotent but actual changes still conflict',
    () {
      final data = _record(version: 3);
      final alreadyCommitted = _record(version: 4);
      final retry = RemoteWritePolicy.plan(
        organizationId: 'org',
        data: data,
        baseVersion: 3,
        current: alreadyCommitted,
      );
      expect(retry.alreadyApplied, isTrue);
      expect(retry.version, 4);
      final collision = RemoteWritePolicy.plan(
        organizationId: 'org',
        data: {...data, 'sampleName': 'Different'},
        baseVersion: 3,
        current: alreadyCommitted,
      );
      expect(collision.refusal, isNotNull);
    },
  );

  test(
    'a live local copy never acknowledges or resurrects a server tombstone',
    () {
      final tombstone = _record()..['deletedAt'] = '2026-10-24';
      final plan = RemoteWritePolicy.plan(
        organizationId: 'org',
        data: _record(),
        baseVersion: 4,
        current: tombstone,
      );
      expect(plan.alreadyApplied, isFalse);
      expect(plan.refusal, isNotNull);
    },
  );

  test('cross-organization and malformed create envelopes are refused', () {
    expect(
      RemoteWritePolicy.plan(
        organizationId: 'other',
        data: _record(),
        baseVersion: 0,
      ).refusal,
      isNotNull,
    );
    expect(
      RemoteWritePolicy.plan(
        organizationId: 'org',
        data: _record()..remove('localId'),
        baseVersion: 0,
      ).refusal,
      isNotNull,
    );
    expect(
      RemoteWritePolicy.plan(
        organizationId: 'org',
        data: _record(),
        baseVersion: 0,
        current: _record()..['organizationId'] = 'other',
      ).refusal,
      isNotNull,
    );
  });
}
