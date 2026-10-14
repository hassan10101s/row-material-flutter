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

  group('derived artifacts are never synced', () {
    /// Fails on any non-scalar leaf (a blob that slipped into the payload).
    /// JSON itself only carries num/String/bool/null/List/Map; anything else
    /// is a locally-generated object (Timestamp, Uint8List, PDF bytes).
    void expectScalarLeaves(Object? value, String path) {
      if (value == null || value is num || value is bool || value is String) {
        return;
      }
      if (value is List) {
        for (var i = 0; i < value.length; i++) {
          expectScalarLeaves(value[i], '$path[$i]');
        }
        return;
      }
      if (value is Map) {
        for (final entry in value.entries) {
          expectScalarLeaves(entry.value, '$path.${entry.key}');
        }
        return;
      }
      fail('non-scalar payload leaf at $path: ${value.runtimeType}');
    }

    test('a sample never carries reportHtml, even with a huge stored report',
        () {
      final entity = SyncEntity.byType('sample')!;
      final bigHtml =
          '<!DOCTYPE html><html><body>' '${'x' * 200000}' '</body></html>';
      final payload = buildRemotePayload(
        entity,
        {
          'id': 11,
          'entry_code': 'QC-7',
          'decision_status': 'APPROVED',
          'report_html': bigHtml,
          'last_pdf_path': '/data/data/pkg/files/MaterialLab/r.pdf',
          'created_at': '2026-01-02T03:04:05.000Z',
          'created_by': null,
          'deleted_at': null,
          'version': 4,
        },
        ctx,
        asCreate: false,
      );

      expect(payload.containsKey('reportHtml'), isFalse,
          reason: 'rendered HTML is rebuilt locally, never uploaded');
      expect(payload.containsKey('report_html'), isFalse);
      final encoded = payload.toString();
      expect(encoded, isNot(contains('<html')),
          reason: 'no HTML fragment may leak under any key');
      expect(encoded, isNot(contains('data:image')),
          reason: 'no embedded base64 image may leak');
      expect(encoded, isNot(contains('/data/data/')),
          reason: 'no local file path may leak');
      // 200 kB of HTML in, bytes out must stay tiny: business data only.
      expect(encoded.length, lessThan(10000));
      expectScalarLeaves(payload, 'sample');
    });

    test('no entity payload carries html paths or non-scalar leaves', () {
      for (final entity in syncEntities) {
        final payload = buildRemotePayload(
          entity,
          {
            'id': 11,
            'report_html': '<html>leak</html>',
            'last_pdf_path': '/tmp/leak.pdf',
            'created_at': '2026-01-02T03:04:05.000Z',
            'created_by': null,
            'deleted_at': null,
            'version': 4,
          },
          ctx,
          asCreate: false,
        );
        for (final key in payload.keys) {
          final lower = key.toLowerCase();
          expect(lower.contains('html'), isFalse,
              reason: '${entity.type} leaked derived key $key');
          expect(lower.contains('pdf'), isFalse,
              reason: '${entity.type} leaked file key $key');
        }
        // Catches the nested labConfig `payload` string as well.
        expect(payload.toString(), isNot(contains('<html>')),
            reason: '${entity.type} leaked HTML content');
        expectScalarLeaves(payload, entity.type);
      }
    });
  });
}
