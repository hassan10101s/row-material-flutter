import 'dart:convert' as convert;

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/offline_first_qc_custom_tables.dart';
import 'package:material_lab/features/qc_manager/data/qc_custom_tables_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_custom_table.dart';

import 'sync_test_fixture.dart';

/// The QC settings feature (user-authored tables) is the first QC family in
/// the sync scope, so its two-device guarantees deserve the same §42-8
/// treatment as the samples: device 1 authors a table and a record offline,
/// device 2 pulls and ends up with the same definition under its OWN local
/// ids (the per-device `table_id` remapped through `table_remote_id`), the
/// record's `values_json` still keyed by the COLUMN remote ids, and a
/// reverse-direction record from device 2 converging back on device 1.
///
/// Each device gets its own SQLite file and they share one fake remote.
class _Device {
  _Device(this.fixture, this.session);

  final SyncFixture fixture;
  AppSession session;

  late final SyncQueue queue = SyncQueue(fixture.helper);
  late final SyncMetadata metadata = SyncMetadata(fixture.helper);
  late final AuditLogger audit = AuditLogger(
    queue: queue,
    session: () => session,
  );
  late bool online = true;

  OfflineFirstQcCustomTablesRepository repo() =>
      OfflineFirstQcCustomTablesRepository(
        local: QcCustomTablesRepo(fixture.helper),
        guard: _SyncGuard(this),
        dbHelper: fixture.helper,
        queue: queue,
      );

  PushWorker pusher(InMemoryDataSource remote) => PushWorker(
    queue: queue,
    metadata: metadata,
    remote: remote,
    audit: audit,
    source: SessionSource.empty(() => session),
  );

  PullWorker puller(InMemoryDataSource remote, {int pageSize = 300}) =>
      PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: ConflictResolver(queue: queue, remote: remote),
        source: SessionSource.empty(() => session),
        pageSize: pageSize,
      );

  Future<List<Map<String, Object?>>> tables() =>
      fixture.db.query('qc_custom_tables');
  Future<List<Map<String, Object?>>> fields() =>
      fixture.db.query('qc_custom_table_fields');
  Future<List<Map<String, Object?>>> rows() =>
      fixture.db.query('qc_custom_table_rows');
}

class _SyncGuard implements WriteGuard {
  _SyncGuard(this.device);

  final _Device device;

  @override
  String get uid => device.session.uid;
  @override
  String get email => device.session.email;
  @override
  String get organizationId => device.session.organizationId;
  @override
  String get memberId => device.session.memberId;
  @override
  String get deviceId => device.session.deviceId;
  @override
  bool get online => device.online;

  @override
  bool allows(String permissionId) => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late _Device laptop; // device 1: authors the definition offline
  late _Device phone; // device 2: pulls it
  late InMemoryDataSource remote;

  AppSession sessionFor(String deviceId) => AppSession(
    uid: 'uid_$deviceId',
    email: '$deviceId@material-lab.test',
    organizationId: orgId,
    memberId: 'member_$deviceId',
    role: AppRoles.admin,
    status: 'active',
    deviceId: deviceId,
  );

  setUp(() async {
    laptop = _Device(await openSyncFixture(), sessionFor('dev_1'));
    phone = _Device(await openSyncFixture(), sessionFor('dev_2'));
    remote = InMemoryDataSource();
  });

  tearDown(() async {
    await laptop.fixture.dispose();
    await phone.fixture.dispose();
  });

  test(
    'a user-authored table and its record authored offline on device 1 '
    'appear on device 2 with remapped local ids and identical value keys',
    () async {
      // ── Device 1 works offline ───────────────────────────────────────────
      laptop.online = false;
      remote.offline = true;
      final laptopTableId = await laptop.repo().createTable(
        QcCustomTable(
          title: 'Sample weights',
          description: 'A register of my own',
          createdAt: '2026-09-01T08:00:00.000',
          updatedAt: '2026-09-01T08:00:00.000',
        ),
        [
          QcCustomTableField(
            label: 'Weight',
            colType: QcCustomColType.number,
            required: true,
            sortOrder: 0,
            createdAt: '2026-09-01T08:00:00.000',
            updatedAt: '2026-09-01T08:00:00.000',
          ),
          QcCustomTableField(
            label: 'Note',
            colType: QcCustomColType.text,
            sortOrder: 1,
            createdAt: '2026-09-01T08:00:00.000',
            updatedAt: '2026-09-01T08:00:00.000',
          ),
        ],
      );
      final weightRemoteLaptop = (await laptop.fields())
          .firstWhere((f) => '${f['label']}' == 'Weight')['remote_id'] as String;
      final laptopRowId = await laptop.repo().addRow(
        QcCustomTableRow(
          tableId: laptopTableId,
          valuesJson: convert.jsonEncode({weightRemoteLaptop: 24.5}),
          note: 'first weighing',
          recordedAt: '2026-09-01T09:00:00.000',
          createdAt: '2026-09-01T09:00:00.000',
          updatedAt: '2026-09-01T09:00:00.000',
        ),
      );
      expect(laptopRowId, isNotNull);

      // Device 2 cannot see any of it yet.
      expect((await phone.puller(remote).runOnce()).applied, 0);
      expect(await phone.tables(), isEmpty);

      // ── Connectivity is back, device 1 pushes the 4 queue rows ───────────
      laptop.online = true;
      remote.offline = false;
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.failed, 0);
      expect(pushed.pushed, 4, reason: 'table + 2 fields + 1 record');

      final laptopTable = (await laptop.tables()).single;
      final tableRemote = '${laptopTable['remote_id']}';
      expect(tableRemote, isNotEmpty);
      expect(
        remote.documents.keys,
        containsAll(
          <Matcher>[
            contains('$orgId/qcCustomTables/$tableRemote'),
          ],
        ),
      );

      // ── Device 2 pulls and converges ─────────────────────────────────────
      final pulled = await phone.puller(remote).runOnce();
      expect(pulled.applied, 4);

      final phoneTable = (await phone.tables()).single;
      expect(phoneTable['remote_id'], tableRemote);
      expect(phoneTable['title'], 'Sample weights');
      expect(
        (phoneTable['table_id'] as num).toInt(),
        greaterThanOrEqualTo(1),
        reason: 'fresh local id assigned by device 2 itself',
      );
      expect(phoneTable['sync_state'], 'synced');
      expect(phoneTable['remote_version'], 1);

      final phoneFields = await phone.fields();
      expect(phoneFields, hasLength(2));
      final phoneTableId = (phoneTable['table_id'] as num).toInt();
      final laptopFieldRemotes = (await laptop.fields())
          .map((f) => '${f['remote_id']}')
          .toSet();
      for (final field in phoneFields) {
        expect(field['table_id'], phoneTableId);
        expect(
          field['table_remote_id'],
          tableRemote,
          reason: 'parent identity stamp survived the roundtrip',
        );
        expect(laptopFieldRemotes, contains(field['remote_id']));
        expect(field['sync_state'], 'synced');
      }
      final labels = phoneFields.map((f) => '${f['label']}').toSet();
      expect(labels, {'Weight', 'Note'});
      final weightRemote =
          (phoneFields.firstWhere((f) => '${f['label']}' == 'Weight'))['remote_id']
              as String;
      expect(weightRemote, weightRemoteLaptop);

      final phoneRow = (await phone.rows()).single;
      expect(
        (phoneRow['table_id'] as num).toInt(),
        phoneTableId,
        reason: 'the origin table_id is meaningless on device 2',
      );
      expect(convert.jsonDecode(phoneRow['values_json'] as String),
          <String, dynamic>{
        weightRemote: 24.5,
      }, reason: 'values are keyed by the column remote ids, not labels');
      expect(phoneRow['remote_id'], '${(await laptop.rows()).single['remote_id']}');
      expect(phoneRow['recorded_by'], laptop.session.uid);
      expect(phoneRow['sync_state'], 'synced');

      // …and nothing of it is queued for a pointless push back.
      expect(await phone.queue.countPending(), 0);
    },
  );

  test(
    'a record written on device 2 under the pulled definition travels back '
    'to device 1, and a whole-table delete tombstones both sides',
    () async {
      // Seed device 1 → device 2 first.
      final laptopTableId = await laptop.repo().createTable(
        QcCustomTable(
          title: 'Trial register',
          createdAt: '2026-09-01T08:00:00.000',
          updatedAt: '2026-09-01T08:00:00.000',
        ),
        [
          QcCustomTableField(
            label: 'Weight',
            colType: QcCustomColType.number,
            required: true,
            createdAt: '2026-09-01T08:00:00.000',
            updatedAt: '2026-09-01T08:00:00.000',
          ),
        ],
      );
      await laptop.pusher(remote).runOnce();
      expect((await phone.puller(remote).runOnce()).applied, 2);
      final phoneTableId = (await phone.tables()).single['table_id'] as int;
      final weightRemote = (await phone.fields()).single['remote_id'] as String;

      // ── Device 2 records offline, under ITS local ids ───────────────────
      phone.online = false;
      remote.offline = true;
      await phone.repo().addRow(
        QcCustomTableRow(
          tableId: phoneTableId,
          valuesJson: convert.jsonEncode({weightRemote: 18.5}),
          note: 'from the phone',
          recordedAt: '2026-09-01T10:00:00.000',
          createdAt: '2026-09-01T10:00:00.000',
          updatedAt: '2026-09-01T10:00:00.000',
        ),
      );
      // ── Device 1 pulls the record back ──────────────────────────────────
      phone.online = true;
      remote.offline = false;
      final pushed = await phone.pusher(remote).runOnce();
      expect(pushed.failed, 0, reason: 'the record leaves the phone');
      final back = await laptop.puller(remote).runOnce();
      expect(back.applied, 1);
      final incoming = (await laptop.rows()).single;
      expect('${incoming['note']}', 'from the phone');
      expect(incoming['recorded_by'], phone.session.uid);
      expect(convert.jsonDecode(incoming['values_json'] as String),
          <String, dynamic>{weightRemote: 18.5});
      expect((incoming['table_id'] as num).toInt(), laptopTableId);
      expect(incoming['sync_state'], 'synced');
      expect(
        incoming['row_id'],
        isNot(0),
      );

      // ── Device 1 deletes the whole table: tombstones both directions ────
      final ops = await laptop.fixture.db.query(
        'sync_queue',
        where: 'status != ?',
        whereArgs: ['done'],
      );
      expect(ops, isEmpty, reason: 'device 1 starts the delete with a clean outbox');
      await laptop.repo().deleteTable(laptopTableId);
      final pending1 = await laptop.queue.countPending();
      expect(pending1, 3, reason: '1 row + 1 field + 1 table tombstone');
      final pushedTombs = await laptop.pusher(remote).runOnce();
      expect(pushedTombs.failed, 0);
      final tombstones = await phone.puller(remote).runOnce();
      expect(tombstones.applied, 3,
          reason:
              'applied=${tombstones.applied} skipped=${tombstones.skipped} '
              'pushedBack=${tombstones.pushedBack} failed=${tombstones.failed}');

      for (final table in await phone.tables()) {
        expect('${table['deleted_at']}', isNotEmpty);
        expect(table['sync_state'], 'synced');
      }
      for (final field in await phone.fields()) {
        expect('${field['deleted_at']}', isNotEmpty);
      }
      for (final row in await phone.rows()) {
        expect('${row['deleted_at']}', isNotEmpty);
      }

      // A deleted definition frees its title on the receiving device too.
      phone.online = true;
      expect(
        await phone.repo().createTable(
          QcCustomTable(
            title: 'Trial register',
            createdAt: '2026-09-01T11:00:00.000',
            updatedAt: '2026-09-01T11:00:00.000',
          ),
          [
            QcCustomTableField(
              label: 'Weight',
              colType: QcCustomColType.number,
              createdAt: '2026-09-01T11:00:00.000',
              updatedAt: '2026-09-01T11:00:00.000',
            ),
          ],
        ),
        isNotNull,
      );
    },
  );
}
