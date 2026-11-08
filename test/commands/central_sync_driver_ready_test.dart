import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/central_projection.dart';
import 'package:material_lab/core/commands/central_sync_driver.dart';
import 'package:material_lab/core/commands/central_sync_transport.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';

import '../sync/sync_test_fixture.dart';

/// The `onReady` hook fires exactly once per `catching_up` -> `ready` flip:
/// startup housekeeping refused by the archive gate defers itself to this
/// transition, so a double-fire would duplicate the deferred steps and a
/// never-fire would brick first-run authoring.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncFixture fixture;
  const session = AppSession(
    uid: 'uid_admin',
    organizationId: 'org_test',
    deviceId: 'device',
    memberId: 'member',
    role: 'admin',
    status: 'active',
  );

  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
  });
  tearDown(() async => fixture.dispose());

  Future<(CentralSyncDriver, _Recording)> driver(
    Future<Map<String, Object?>> Function(
      String mode,
      Map<String, Object?> data,
    )
    transport,
  ) async {
    final recording = _Recording();
    final driver = CentralSyncDriver(
      databaseHelper: fixture.helper,
      source: SessionSource(() => session),
      projection: CentralProjection(
        databaseHelper: fixture.helper,
        source: SessionSource(() => session),
      ),
      transport: _ModeTransport(recording, transport),
      outbox: CommandOutbox(fixture.helper),
      metadata: SyncMetadata(fixture.helper),
      onError: (error) => recording.errors.add(error),
    );
    return (driver, recording);
  }

  test(
    'manifest is reused until the database connection generation changes',
    () async {
      final (d, _) = await driver((mode, data) async {
        if (mode == 'beginSnapshot') {
          return {'throughSequence': 0, 'manifestVersion': 1};
        }
        if (mode == 'snapshotPage') {
          return {
            'throughSequence': 0,
            'records': <Object>[],
            'nextAfter': null,
          };
        }
        return {'throughSequence': 0, 'events': <Object>[], 'hasMore': false};
      });
      await d.syncNow();
      // Deliberately unsupported schema: a rebuild detects it. The existing
      // generation must keep using its already-proven manifest.
      await fixture.db.execute(
        'CREATE UNIQUE INDEX manifest_cache_probe ON lab_units(lower(symbol))',
      );
      await d.syncNow();
      await fixture.helper.rebuild();
      try {
        await expectLater(
          d.syncNow(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Expression uniqueness'),
            ),
          ),
        );
      } finally {
        await fixture.helper.close();
      }
    },
  );

  test(
    'a fresh bootstrap flips exactly once and fires the hook once',
    () async {
      var fires = 0;
      var begins = 0;
      final (d, _) = await driver((mode, data) async {
        if (mode == 'beginSnapshot') {
          return {
            'throughSequence': beginWatermark(begins++, [0, 0]),
            'manifestVersion': 1,
          };
        }
        if (mode == 'snapshotPage') {
          return {
            'throughSequence': data['throughSequence'],
            'records': const <Map<String, Object?>>[],
            'nextAfter': null,
          };
        }
        final after = (data['afterSequence'] as num).toInt();
        return {
          'throughSequence': after,
          'events': const <Map<String, Object?>>[],
          'hasMore': false,
        };
      });
      d.onReady = () async => fires++;
      await d.syncNow();
      expect(fires, 1);
      expect(
        ((await fixture.db.query(
          'central_sync_state',
        )).single)['bootstrap_state'],
        'ready',
      );

      // A second full cycle on an already-ready archive must not re-fire.
      await d.syncNow();
      expect(fires, 1);
    },
  );

  test('a target run stays catching_up without firing; the next full run '
      'promotes on the resumed flip', () async {
    var fires = 0;
    var begins = 0;
    final (d, _) = await driver((mode, data) async {
      if (mode == 'beginSnapshot') {
        return {
          'throughSequence': beginWatermark(begins++, [0, 0]),
          'manifestVersion': 1,
        };
      }
      if (mode == 'snapshotPage') {
        return {
          'throughSequence': data['throughSequence'],
          'records': const <Map<String, Object?>>[],
          'nextAfter': null,
        };
      }
      final after = (data['afterSequence'] as num).toInt();
      return {
        'throughSequence': after,
        'events': const <Map<String, Object?>>[],
        'hasMore': false,
      };
    });
    d.onReady = () async => fires++;

    // An explicit target cannot prove a full drain, so no ready and no hook.
    await d.syncNow(throughSequence: 1);
    expect(fires, 0);
    expect(
      ((await fixture.db.query(
        'central_sync_state',
      )).single)['bootstrap_state'],
      'catching_up',
    );

    // The full run drains the remaining feed exactly once.
    await d.syncNow();
    expect(fires, 1);
    expect(
      ((await fixture.db.query(
        'central_sync_state',
      )).single)['bootstrap_state'],
      'ready',
    );
  });

  test('an archive that is already ready never fires the hook', () async {
    var fires = 0;
    await fixture.db.insert('central_sync_state', {
      'organization_id': 'org_test',
      'uid': 'uid_admin',
      'role': 'admin',
      'bootstrap_state': 'ready',
      'protocol_schema': 3,
      'applied_sequence': 0,
    });
    final (d, _) = await driver((mode, data) async {
      final after = (data['afterSequence'] as num).toInt();
      return {
        'throughSequence': after,
        'events': const <Map<String, Object?>>[],
        'hasMore': false,
      };
    });
    d.onReady = () async => fires++;
    await d.syncNow();
    expect(fires, 0);
    expect(
      ((await fixture.db.query(
        'central_sync_state',
      )).single)['bootstrap_state'],
      'ready',
    );
  });

  test(
    'a firing hook error is reported, not propagated into the sync result',
    () async {
      var fires = 0;
      var begins = 0;
      final (d, recording) = await driver((mode, data) async {
        if (mode == 'beginSnapshot') {
          return {
            'throughSequence': beginWatermark(begins++, [0, 0]),
            'manifestVersion': 1,
          };
        }
        if (mode == 'snapshotPage') {
          return {
            'throughSequence': data['throughSequence'],
            'records': const <Map<String, Object?>>[],
            'nextAfter': null,
          };
        }
        final after = (data['afterSequence'] as num).toInt();
        return {
          'throughSequence': after,
          'events': const <Map<String, Object?>>[],
          'hasMore': false,
        };
      });
      d.onReady = () async {
        fires++;
        throw StateError('deferred housekeeping failed');
      };
      final cursor = await d.syncNow();
      expect(cursor, 0);
      expect(fires, 1);
      expect(
        recording.errors.any((error) => '$error'.contains('housekeeping')),
        isTrue,
      );
    },
  );
}

int beginWatermark(int begins, List<int> watermarks) =>
    watermarks[begins < watermarks.length ? begins : watermarks.length - 1];

class _Recording {
  final List<Object> errors = [];
}

class _ModeTransport implements CentralSyncReader {
  _ModeTransport(this.recording, this.handler);

  final _Recording recording;
  final Future<Map<String, Object?>> Function(
    String mode,
    Map<String, Object?> data,
  )
  handler;

  @override
  Future<Map<String, Object?>> call(Map<String, Object?> data) =>
      handler(data['mode'] as String, data);
}
