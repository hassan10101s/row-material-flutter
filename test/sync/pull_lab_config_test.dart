import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';

import 'sync_test_fixture.dart';

/// Pulling a lab-configuration document into a table whose columns are all
/// `NOT NULL`.
///
/// The reported failure was `NOT NULL constraint failed:
/// lab_analysis_items.analysis_id` from an `INSERT OR REPLACE` carrying only
/// `(id, unit, version, remote_version, remote_synced_at, sync_state)`: every
/// payload column but `unit` had been dropped on the way in. Two separate
/// defects produce that, and both are pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fixture;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late ConflictResolver conflicts;
  late InMemoryDataSource remote;
  late AppSession session;

  setUp(() async {
    fixture = await openSyncFixture();
    queue = SyncQueue(fixture.helper);
    metadata = SyncMetadata(fixture.helper);
    remote = InMemoryDataSource();
    conflicts = ConflictResolver(queue: queue, remote: remote);
    session = const AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: orgId,
      memberId: 'member_1',
      role: 'admin',
      status: 'active',
      deviceId: 'dev_1',
    );
    await fixture.seedOrganization();
  });

  tearDown(() async => fixture.dispose());

  PullWorker worker() => PullWorker(
    queue: queue,
    metadata: metadata,
    remote: remote,
    conflicts: conflicts,
    source: SessionSource.empty(() => session),
  );

  /// The FK targets `lab_analysis_items.analysis_id` / `inventory_id` point at.
  Future<void> seedConfigTargets() async {
    await fixture.db.insert('lab_analyses', <String, dynamic>{
      'id': 7,
      'name': 'Calcium',
      'unit': '%',
      'created_at': '2026-09-01T07:00:00.000',
    });
    await fixture.db.insert('lab_inventory', <String, dynamic>{
      'id': 3,
      'name': 'Hydrochloric acid',
      'category': 'liquid',
      'unit': 'L',
      'current_qty': 0,
      'min_qty': 0,
      'created_at': '2026-09-01T07:00:00.000',
      'updated_at': '2026-09-01T07:00:00.000',
    });
  }

  /// A `lab_analysis_items` document carrying a single item (id 15).
  ///
  /// [payloadShape] is the wire shape of the nested `payload` field. The offline
  /// writer nests a `Map`; a JSON-encoded writer nests a `String`.
  Map<String, dynamic> analysisItemDoc({
    int version = 2,
    int localId = 15,
    required String payloadShape,
  }) {
    final item = <String, dynamic>{
      'id': localId,
      'analysis_id': 7,
      'inventory_id': 3,
      'qty_per_sample': 2.5,
      'unit': '%',
    };
    return <String, dynamic>{
      'localId': localId,
      'organizationId': orgId,
      'version': version,
      'updatedBy': 'uid_admin',
      'deviceId': 'dev_2',
      'updatedAt': '2026-10-05T16:21:09.000',
      'configType': 'analysis_item',
      'payload': switch (payloadShape) {
        'map' => item,
        'json' => jsonEncode(item),
        _ => throw ArgumentError('unknown payload shape $payloadShape'),
      },
    };
  }

  String key() =>
      '$orgId/labConfig/${labConfigDocId('lab_analysis_items')({'id': 15})}';

  group('a lab-config document keeps the columns its table requires', () {
    test('payload nested as a Map still lands every NOT NULL column', () async {
      await seedConfigTargets();
      remote.documents[key()] = analysisItemDoc(
        payloadShape: 'map',
        localId: 15,
      );

      final report = await worker().runOnce();

      expect(report.applied, 1, reason: 'the document must not be rejected');
      final rows = await fixture.db.query('lab_analysis_items');
      expect(rows, hasLength(1));
      expect(rows.single['analysis_id'], 7);
      expect(rows.single['inventory_id'], 3);
      expect(rows.single['qty_per_sample'], 2.5);
      expect(rows.single['unit'], '%');
      expect(rows.single['sync_state'], 'synced');
    });

    test('payload nested as a JSON String behaves identically', () async {
      await seedConfigTargets();
      remote.documents[key()] = analysisItemDoc(
        payloadShape: 'json',
        localId: 15,
      );

      final report = await worker().runOnce();

      expect(report.applied, 1);
      final rows = await fixture.db.query('lab_analysis_items');
      expect(rows.single['analysis_id'], 7);
      expect(rows.single['inventory_id'], 3);
      expect(rows.single['qty_per_sample'], 2.5);
    });

    test(
      'a camelCase payload is normalised to the local column names',
      () async {
        await seedConfigTargets();
        // Written by a `payloadBuilder`, which emits camelCase like every other
        // remote field. Copied verbatim these keys are not columns of the table,
        // so they are filtered away and the row is left without its NOT NULLs.
        remote.documents[key()] = <String, dynamic>{
          'localId': 15,
          'organizationId': orgId,
          'version': 2,
          'updatedBy': 'uid_admin',
          'deviceId': 'dev_2',
          'updatedAt': '2026-10-05T16:21:09.000',
          'configType': 'analysis_item',
          'payload': <String, dynamic>{
            'analysisId': 7,
            'inventoryId': 3,
            'qtyPerSample': 2.5,
            'unit': '%',
          },
        };

        final report = await worker().runOnce();

        expect(report.applied, 1);
        final rows = await fixture.db.query('lab_analysis_items');
        expect(rows.single['analysis_id'], 7);
        expect(rows.single['inventory_id'], 3);
        expect(rows.single['qty_per_sample'], 2.5);
      },
    );
  });

  group('one unusable document cannot stall the whole pull', () {
    test('a document missing a required column is skipped, not fatal', () async {
      // The defect behind the original report: the insert violated a NOT NULL
      // and threw, so the pull transaction rolled back and *no* document in the
      // page was applied. One bad row must cost one row.
      await seedConfigTargets();
      remote.documents[key()] = <String, dynamic>{
        'localId': 15,
        'organizationId': orgId,
        'version': 2,
        'updatedBy': 'uid_admin',
        'deviceId': 'dev_2',
        'updatedAt': '2026-10-05T16:21:09.000',
        'configType': 'analysis_item',
        // No payload at all: nothing satisfies analysis_id.
        'payload': <String, dynamic>{'unit': '%'},
      };
      remote.documents['$orgId/samples/R-9'] = <String, dynamic>{
        'entryCode': 'R-9',
        'localId': null,
        'organizationId': orgId,
        'materialId': 1,
        'materialName': 'Cement',
        'materialCode': 'M-CEM-01',
        'inspectionDate': '2026-10-01',
        'specialistName': 'Ahmed Ali',
        'physicalResultsJson': '{}',
        'chemicalResultsJson': '{}',
        'physicalReferenceJson': '{}',
        'chemicalReferenceJson': '{}',
        'snapshotJson': '{}',
        'sampleNamesJson': '[]',
        'version': 1,
        'updatedBy': 'uid_admin',
        'deviceId': 'dev_2',
        'updatedAt': '2026-10-05T16:21:09.000',
      };

      final report = await worker().runOnce();

      expect(report.applied, 1, reason: 'the healthy sample must still land');
      expect(report.failed, 1, reason: 'the broken one is reported');
      expect(await fixture.db.query('lab_analysis_items'), isEmpty);
      final samples = await fixture.db.query(
        'inspections',
        where: 'entry_code = ?',
        whereArgs: ['R-9'],
      );
      expect(samples, hasLength(1));
    });
  });

  group(
    'lab-settings tables sharing the labConfig collection stay separate',
    () {
      test('a document never lands in another lab-settings table', () async {
        await seedConfigTargets();
        // Every lab-settings table is an entity of the one `labConfig`
        // collection, so the collection query returns this document to all
        // seven of them. `localId` 15 is a live row in several of those tables,
        // so without a discriminator the pull overwrites unrelated data.
        await fixture.db.insert('lab_units', <String, dynamic>{
          'id': 15,
          'symbol': 'mg',
          'name': 'Milligram',
          'dimension': 'mass',
          'created_at': '2026-09-01T07:00:00.000',
        });
        await fixture.db.insert('lab_products', <String, dynamic>{
          'id': 15,
          'name': 'Cement bag',
          'category': 'powder',
          'created_at': '2026-09-01T07:00:00.000',
        });
        remote.documents[key()] = analysisItemDoc(
          payloadShape: 'map',
          localId: 15,
        );

        final report = await worker().runOnce();

        expect(report.failed, 0, reason: 'no lab-settings table may reject it');
        expect(
          await fixture.db.query('lab_analysis_items'),
          hasLength(1),
          reason: 'the item belongs here',
        );
        // The three tables that share the id are untouched.
        expect((await fixture.db.query('lab_units')).single['symbol'], 'mg');
        expect(
          (await fixture.db.query('lab_products')).single['name'],
          'Cement bag',
        );
        // `lab_analyses` still holds only the seeded FK target (id 7).
        expect(
          await fixture.db.query('lab_analyses', columns: ['id']),
          <Object?>[
            {'id': 7},
          ],
        );
        expect(await fixture.db.query('lab_constants'), isEmpty);
        expect(await fixture.db.query('lab_product_analyses'), isEmpty);
        expect(await fixture.db.query('lab_field_chemical_links'), isEmpty);
      });

      test(
        'a lab-products document is applied once, not by all seven entities',
        () async {
          remote.documents['$orgId/labConfig/lc_lab_products_4'] =
              <String, dynamic>{
                'localId': 4,
                'organizationId': orgId,
                'version': 1,
                'updatedBy': 'uid_admin',
                'deviceId': 'dev_2',
                'updatedAt': '2026-10-05T16:21:09.000',
                'configType': 'product',
                'payload': <String, dynamic>{
                  'id': 4,
                  'name': 'Cement bag',
                  'category': 'powder',
                  'created_at': '2026-09-01T07:00:00.000',
                },
              };

          final report = await worker().runOnce();

          expect(report.applied, 1);
          expect(report.failed, 0);
          final products = await fixture.db.query('lab_products');
          expect(products, hasLength(1));
          expect(products.single['name'], 'Cement bag');
          expect(await fixture.db.query('lab_units'), isEmpty);
          expect(await fixture.db.query('lab_analyses'), isEmpty);
          expect(await fixture.db.query('lab_analysis_items'), isEmpty);
        },
      );
    },
  );
}
