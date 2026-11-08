import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import '../support/retired/core/sync/conflict_resolver.dart';
import '../support/retired/core/sync/pull_worker.dart';
import '../support/retired/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/formulations/data/sqlite_formulation_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import 'sync_test_fixture.dart';

/// Two devices of the same organization (Release 1: one writing device + a
/// read-only viewer) and the nutrition-formulation records between them.
///
/// The formulation is written through the production repository and must
/// round-trip through the shared `labConfig` collection (`nf_` documents)
/// with every business column intact — items, graph parameters, calculation
/// and the archive flag — landing `synced` and not re-queued on the viewer.
///
/// Each device gets its **own** SQLite file created by the production
/// [DatabaseHelper]; the remote is an in-memory double. No Firebase involved.
class _FormulationDevice {
  _FormulationDevice(this.fixture, this.session);

  final SyncFixture fixture;
  AppSession session;
  bool online = true;

  late final SyncQueue queue = SyncQueue(fixture.helper);
  late final SyncMetadata metadata = SyncMetadata(fixture.helper);
  late final AuditLogger audit = AuditLogger(
    queue: queue,
    session: () => session,
  );

  SessionSource get source => SessionSource.empty(() => session);

  PushWorker pusher(InMemoryDataSource remote) => PushWorker(
    queue: queue,
    metadata: metadata,
    remote: remote,
    audit: audit,
    source: source,
  );

  PullWorker puller(InMemoryDataSource remote) => PullWorker(
    queue: queue,
    metadata: metadata,
    remote: remote,
    conflicts: ConflictResolver(queue: queue, remote: remote),
    source: source,
  );

  SqliteFormulationRepository repo() => SqliteFormulationRepository(
    dbHelper: fixture.helper,
    guard: SessionWriteGuard(
      source: SessionSource(() => session),
      isOnline: () => online,
    ),
    queue: queue,
    audit: audit,
  );

  Future<List<Map<String, Object?>>> rows() =>
      fixture.db.query('nutrition_formulations');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late _FormulationDevice writer;
  late _FormulationDevice viewer;
  late InMemoryDataSource remote;

  setUp(() async {
    final a = await openSyncFixture();
    final b = await openSyncFixture();
    await a.seedOrganization();
    await b.seedOrganization();
    for (final fixture in [a, b]) {
      await fixture.db.insert('reference_materials', {
        'id': 2,
        'material_name': 'Sand',
        'material_code': 'M-SAND',
        'physical_reference_json': '{}',
        'chemical_reference_json': '{}',
        'imported_at': '2026-01-01',
        'remote_id': 'material-sand',
      });
      await fixture.db.update(
        'reference_materials',
        {'remote_id': 'material-cement'},
        where: 'id = ?',
        whereArgs: [1],
      );
      await fixture.db.insert('lab_products', {
        'id': 1,
        'name': 'Feed',
        'created_at': '2026-01-01',
        'remote_id': 'product-feed',
      });
    }
    writer = _FormulationDevice(
      a,
      const AppSession(
        uid: 'uid_writer',
        email: 'writer@material-lab.test',
        organizationId: orgId,
        memberId: 'member_writer',
        role: 'nutritionist',
        status: 'active',
        deviceId: 'dev_writer',
      ),
    );
    // The Release-1 viewer: same organization, read-only device. It never
    // writes a formulation — it only pulls what the writer produces.
    viewer = _FormulationDevice(
      b,
      const AppSession(
        uid: 'uid_viewer',
        email: 'viewer@material-lab.test',
        organizationId: orgId,
        memberId: 'member_viewer',
        role: 'nutritionist',
        status: 'active',
        deviceId: 'dev_viewer',
        readOnlyDevice: true,
      ),
    );
    remote = InMemoryDataSource(
      rolesByUid: const {'uid_writer': 'nutritionist', 'uid_viewer': 'viewer'},
    );
  });

  tearDown(() async {
    await writer.fixture.dispose();
    await viewer.fixture.dispose();
  });

  Map<String, dynamic> record() => {
    'name': 'Starter mix',
    'product_id': 1,
    'items': [
      {
        'material_id': 1,
        'material_name': 'Cement',
        'quantity_kg': 100,
        'price_per_kg': 2,
      },
      {
        'material_id': 2,
        'material_name': 'Sand',
        'quantity_kg': 40,
        'price_per_kg': 1.5,
      },
    ],
    'parameters': {'protein': 30},
    'graph_parameters': ['protein', 'moisture'],
    'calculation': {'total_kg': 140, 'cost_per_kg': 1.857},
    'sources': [
      {'key': 'protein', 'source': 'lab'},
    ],
  };

  test('a formulation saved on the writer reaches the viewer intact', () async {
    // The viewer starts empty and a pull brings nothing.
    expect((await viewer.puller(remote).runOnce()).applied, 0);
    expect(await viewer.rows(), isEmpty);

    await writer.repo().save(record());
    final writerRow = (await writer.rows()).single;
    final remoteId = '${writerRow['remote_id']}';
    expect(remoteId, isNotEmpty);

    // Writer pushes: exactly one labConfig document named after the remote id.
    final pushed = await writer.pusher(remote).runOnce();
    expect(pushed.failed, 0);
    final docKey = '$orgId/labConfig/nf_$remoteId';
    expect(remote.documents.containsKey(docKey), isTrue);

    // Viewer pulls: the business payload lands byte-for-byte.
    final pulled = await viewer.puller(remote).runOnce();
    expect(pulled.applied, 1);
    expect(pulled.failed, 0);
    final row = (await viewer.rows()).single;
    expect(row['name'], 'Starter mix');
    expect(row['remote_id'], remoteId);
    expect(row['product_id'], 1);
    expect(row['is_archived'], 0);
    expect(row['copied_from_id'], isNull);
    final remoteItems = (jsonDecode('${row['items_json']}') as List)
        .map(
          (item) => Map<String, dynamic>.from(item as Map)
            ..remove('_material_code')
            ..remove('_material_remote_id'),
        )
        .toList();
    expect(remoteItems, record()['items']);
    final parameters = Map<String, dynamic>.from(
      jsonDecode('${row['parameters_json']}') as Map,
    )..remove('_product_reference');
    expect(parameters, record()['parameters']);
    expect(
      jsonDecode('${row['graph_parameters_json']}'),
      record()['graph_parameters'],
    );
    expect(jsonDecode('${row['calculation_json']}'), record()['calculation']);
    expect(jsonDecode('${row['source_snapshot_json']}'), record()['sources']);
    expect(row['sync_state'], 'synced');
    expect((row['remote_version'] as num).toInt(), 1);

    // The received row is not queued for a pointless push back.
    expect(await viewer.queue.countPending(), 0);
  });

  test(
    'formulation references resolve on a viewer with different local IDs',
    () async {
      await viewer.fixture.db.update(
        'reference_materials',
        {'id': 71},
        where: 'id = ?',
        whereArgs: [1],
      );
      await viewer.fixture.db.update(
        'reference_materials',
        {'id': 72},
        where: 'id = ?',
        whereArgs: [2],
      );
      await viewer.fixture.db.update(
        'lab_products',
        {'id': 81},
        where: 'id = ?',
        whereArgs: [1],
      );
      await writer.repo().save(record());
      expect((await writer.pusher(remote).runOnce()).failed, 0);
      expect((await viewer.puller(remote).runOnce()).failed, 0);
      final received = (await viewer.repo().list()).single;
      expect(received['product_id'], 81);
      final items = jsonDecode(received['items_json'] as String) as List;
      expect(items.map((item) => item['material_id']), [71, 72]);
      expect(received['_missing_references'], false);
    },
  );

  test('an edit and an archive on the writer propagate in order', () async {
    final id = await writer.repo().save(record());
    await writer.pusher(remote).runOnce();
    await viewer.puller(remote).runOnce();

    // ── Edit: quantities and name change, version bumps ───────────────────
    await writer.repo().save({
      ...record(),
      'name': 'Starter mix (revised)',
      'items': [
        {
          'material_id': 1,
          'material_name': 'Cement',
          'quantity_kg': 120,
          'price_per_kg': 2,
        },
      ],
      'calculation': {'total_kg': 120, 'cost_per_kg': 2.0},
    }, id: id);
    final pushed = await writer.pusher(remote).runOnce();
    expect(pushed.failed, 0);
    expect(pushed.conflicts, 0);

    final pulled = await viewer.puller(remote).runOnce();
    expect(pulled.applied, greaterThanOrEqualTo(1));
    final row = (await viewer.rows()).single;
    expect(row['name'], 'Starter mix (revised)');
    expect((row['remote_version'] as num).toInt(), 2);
    final items = jsonDecode('${row['items_json']}') as List;
    expect(items.single['quantity_kg'], 120);
    expect(jsonDecode('${row['calculation_json']}'), {
      'total_kg': 120,
      'cost_per_kg': 2.0,
    });

    // ── Archive: the flag crosses, the row stays (no tombstone) ──────────
    await writer.repo().archive(id);
    expect((await writer.pusher(remote).runOnce()).failed, 0);
    await viewer.puller(remote).runOnce();

    final archived = (await viewer.rows()).single;
    expect((archived['is_archived'] as num).toInt(), 1);
    expect(archived['name'], 'Starter mix (revised)');
    // Still not queued back on the viewer.
    expect(await viewer.queue.countPending(), 0);
  });

  test(
    'the viewer (read-only device) cannot push a formulation back',
    () async {
      await writer.repo().save(record());
      await writer.pusher(remote).runOnce();
      await viewer.puller(remote).runOnce();

      // Simulate a tampered viewer: it must not be able to enqueue+push a
      // change to the formulation. The write guard refuses the permission.
      await expectLater(
        viewer.repo().save({'name': 'Evil', 'items': record()['items']}),
        throwsA(isA<AuthorizationError>()),
      );
      // Only the pulled formulation exists; the tampered save wrote nothing.
      final rows = await viewer.rows();
      expect(rows, hasLength(1));
      expect(rows.single['name'], 'Starter mix');
    },
  );
}
