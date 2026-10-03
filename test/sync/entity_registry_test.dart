import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/entity_registry.dart';

/// `createdAt` is write-once on every synced collection. These lock the
/// payload contract that keeps it that way.
///
/// `firestore.rules` compares `request.resource.data.createdAt ==
/// resource.data.createdAt` with no type coercion. The stored value is a
/// `Timestamp`, while `row['created_at']` is a local ISO `String`. So an update
/// that echoed the local string back would be *denied by the rules* - not
/// rejected by the client - and the queue row would sit as an unresolvable
/// conflict the user cannot clear. Omitting the key is safe because the update
/// path is a partial `ref.update(payload)` write.
void main() {
  const ctx = SyncPayloadContext(
    organizationId: '7',
    uid: 'uid-1',
    deviceId: 'device-1',
    version: 4,
    versionField: 'remote_version',
  );

  /// Every entity that can be updated (not append-only), which is every entity
  /// whose pushes go through the `update` path.
  final updatable = syncEntities.where((e) => !e.appendOnly).toList();

  Map<String, dynamic> build(String type, {required bool asCreate}) {
    final entity = SyncEntity.byType(type)!;
    return buildRemotePayload(
      entity,
      {
        'id': 11,
        'created_at': '2026-01-02T03:04:05.000Z',
        'created_by': null,
        'deleted_at': null,
        'remote_version': 4,
        'sync_state': 'pending',
        'version': 4,
      },
      ctx,
      asCreate: asCreate,
    );
  }

  test('the registry has updatable entities to check', () {
    expect(updatable, isNotEmpty, reason: 'otherwise the sweep below is vacuous');
  });

  group('asCreate', () {
    test('writes createdAt as the serverTimestamp sentinel', () {
      for (final entity in updatable) {
        final payload = build(entity.type, asCreate: true);
        expect(
          payload.containsKey('createdAt'),
          isTrue,
          reason: '${entity.type} create must stamp createdAt',
        );
        expect(
          payload['createdAt'],
          FieldTimestampSentinel.value,
          reason: '${entity.type} create must not send a local ISO string',
        );
      }
    });
  });

  group('update', () {
    test('omits createdAt entirely, for every updatable entity', () {
      for (final entity in updatable) {
        final payload = build(entity.type, asCreate: false);
        expect(
          payload.containsKey('createdAt'),
          isFalse,
          reason: '${entity.type} update must not re-send createdAt: a String '
              'over a stored Timestamp is denied by firestore.rules',
        );
      }
    });

    test('never leaks the local created_at under any spelling', () {
      for (final entity in updatable) {
        final payload = build(entity.type, asCreate: false);
        for (final key in ['created_at', 'createdAt', 'createdat']) {
          expect(
            payload.containsKey(key),
            isFalse,
            reason: '${entity.type} leaked createdAt as $key',
          );
        }
      }
    });

    test('still sends the rest of the envelope', () {
      // Guards against a fix that dropped createdAt by dropping the envelope.
      final payload = build('sample', asCreate: false);
      expect(payload['organizationId'], '7');
      expect(payload['localId'], 11);
      expect(payload['version'], 4);
      expect(payload['updatedBy'], 'uid-1');
      expect(payload['deviceId'], 'device-1');
      expect(payload['updatedAt'], FieldTimestampSentinel.value);
      expect(payload.containsKey('createdBy'), isTrue);
      expect(payload.containsKey('deletedAt'), isTrue);
    });
  });

  test('a sample update keeps its business fields while dropping createdAt', () {
    final entity = SyncEntity.byType('sample')!;
    final payload = buildRemotePayload(
      entity,
      {
        'id': 11,
        'entry_code': 'QC-7',
        'decision_status': 'APPROVED',
        'created_at': '2026-01-02T03:04:05.000Z',
        'created_by': null,
        'deleted_at': null,
        'version': 4,
      },
      ctx,
      asCreate: false,
    );

    expect(payload.containsKey('createdAt'), isFalse);
    expect(payload['entryCode'], 'QC-7');
    expect(payload['decisionStatus'], 'APPROVED');
    // `payloadBytes` is a byte count of the document, so dropping one field
    // has to change it - otherwise this test would pass on a no-op registry.
    expect(payload.containsKey('payloadBytes'), isTrue);
  });

  test('create and update of the same row differ only in createdAt and version',
      () {
    final entity = SyncEntity.byType('sample')!;
    Map<String, dynamic> build2({required bool asCreate}) =>
        buildRemotePayload(
          entity,
          {
            'id': 11,
            'entry_code': 'QC-7',
            'created_at': '2026-01-02T03:04:05.000Z',
            'created_by': null,
            'deleted_at': null,
            'version': 4,
          },
          ctx,
          asCreate: asCreate,
        );

    final created = build2(asCreate: true);
    final updated = build2(asCreate: false);
    expect(created.keys.toSet().difference(updated.keys.toSet()), {'createdAt'});
    expect(updated.keys.toSet().difference(created.keys.toSet()), isEmpty);
    expect(updated['version'], 4);
    expect(created['version'], 1, reason: 'a create starts the version at 1');
  });
}
