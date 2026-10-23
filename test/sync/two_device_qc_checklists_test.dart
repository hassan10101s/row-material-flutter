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
import 'package:material_lab/features/qc_manager/data/offline_first_qc_repository.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/data/qc_repo.dart';
import 'package:material_lab/features/qc_manager/data/qc_sync_writer.dart';
import 'package:material_lab/features/qc_manager/data/routine_lists_repository.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';

import 'sync_test_fixture.dart';

/// plan P8: the QC checklist family (templates/items/sheets/responses/
/// task logs / NC-CAPA) is now in the sync scope. Device 1 is the writing
/// device, device 2 is a read-only viewer: after the authoring device stops
/// blocking the network, everything it queues carries its parent identity
/// stamps, and device 2 pulls it with remapped foreign keys — a routine
/// list authored offline is tickable/readable there, and the NCR/CAPA
/// pipeline does not lose its links.
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

  QcSyncWriter? writer() => QcSyncWriter(
    queue: queue,
    guard: _SyncGuard(this),
    syncAudit: audit,
  );

  RoutineListsRepositoryImpl routine() => RoutineListsRepositoryImpl(
    dbHelper: fixture.helper,
    guard: _SyncGuard(this),
    audit: QcAuditRepo(
      dbHelper: fixture.helper,
      actorReader: () => QcActor.unknown,
    ),
    templates: QcTemplateRepo(fixture.helper),
    inspections: QcInspectionRepo(fixture.helper),
    queue: queue,
    syncAudit: audit,
  );

  OfflineFirstQcNcCapaRepository nc() => OfflineFirstQcNcCapaRepository(
    local: QcNcCapaRepo(fixture.helper),
    guard: _SyncGuard(this),
    audit: QcAuditRepo(
      dbHelper: fixture.helper,
      actorReader: () => QcActor.unknown,
    ),
    dbHelper: fixture.helper,
    sync: writer(),
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

  late _Device laptop; // device 1: the writing device
  late _Device phone; // device 2: the read-only viewer
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
    'a routine list authored offline (list + sheet + tick + done press) '
    'reaches the viewer with remapped foreign keys on every row',
    () async {
      // ── Device 1 authors everything offline ────────────────────────────
      laptop.online = false;
      remote.offline = true;
      final listId = await laptop.routine().saveRoutineList(
        name: 'Shift cleanliness',
        recurrence: QcRecurrence.daily,
        items: const ['Floor swept', 'Bins emptied'],
      );
      final sheet = await laptop.routine().openPeriodSheet(listId);
      final rows = sheet.rows.toList();
      await laptop.routine().toggleCheck(
        inspectionId: sheet.inspection.inspectionId!,
        itemId: rows.first.item.itemId!,
      );
      await laptop.routine().recordDone(
        inspectionId: sheet.inspection.inspectionId!,
        itemId: rows.last.item.itemId!,
        note: 'second pass',
      );

      // Device 2 has nothing yet.
      expect((await phone.puller(remote).runOnce()).applied, 0);

      // ── Device 1 pushes; everything queued lands as ONE payload set ────
      laptop.online = true;
      remote.offline = false;
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.failed, 0,
          reason: 'push failed=${pushed.failed} queued=${pushed.pushed}');

      // The laptop itself stamped remote identities on everything and its
      // own rows kept their business fields.
      final laptopTemplate =
          (await laptop.fixture.db.query('qc_templates')).single;
      final templateRemote = '${laptopTemplate['remote_id']}';
      expect(templateRemote, isNotEmpty);
      final laptopSheet =
          (await laptop.fixture.db.query('qc_inspections')).single;
      expect('${laptopTemplate['name']}', 'Shift cleanliness');
      expect(
        remote.documents['$orgId/qcTemplates/$templateRemote']?['businessVersion'],
        1,
        reason: 'the checklist revision number is published under '
            'businessVersion, not the sync envelope version (plan P8 special '
            'case in buildRemotePayload)',
      );

      // ── Device 2 pulls and converges ───────────────────────────────────
      final pulled = await phone.puller(remote).runOnce();
      expect(pulled.failed, 0,
          reason: 'applied=${pulled.applied} failed=${pulled.failed} '
              'pushedBack=${pulled.pushedBack}');

      final phoneTemplate =
          (await phone.fixture.db.query('qc_templates')).single;
      expect(phoneTemplate['remote_id'], templateRemote);
      expect(phoneTemplate['name'], 'Shift cleanliness');
      expect(
        (phoneTemplate['version'] as num).toInt(),
        1,
        reason: 'the viewer restores the business revision from businessVersion',
      );
      expect('${phoneTemplate['recurrence']}', QcRecurrence.daily);

      // Items live under their own ids with the remapped template FK.
      final phoneItems = await phone.fixture.db.query('qc_items');
      expect(phoneItems, hasLength(2));
      final phoneTemplateId = (phoneTemplate['template_id'] as num).toInt();
      for (final item in phoneItems) {
        expect(item['template_id'], phoneTemplateId);
        expect(item['template_remote_id'], templateRemote);
      }

      final phoneSection =
          (await phone.fixture.db.query('qc_sections')).single;
      expect(
        phoneSection['template_id'],
        phoneTemplateId,
        reason:
            'the implicit section remapped through its own parent identity',
      );

      final phoneSheet =
          (await phone.fixture.db.query('qc_inspections')).single;
      expect(phoneSheet['remote_id'], laptopSheet['remote_id']);
      expect(phoneSheet['template_id'], phoneTemplateId);
      expect(phoneSheet['template_remote_id'], templateRemote);
      final phoneSheetId = (phoneSheet['inspection_id'] as num).toInt();

      final phoneResponses = await phone.fixture.db.query(
        'qc_responses',
        orderBy: 'resp_id ASC',
      );
      expect(phoneResponses, hasLength(2));
      final laptopItemIds = {
        for (final r in await laptop.fixture.db.query('qc_items'))
          (r['remote_id'] as String): r,
      };
      final doneItems = phoneResponses
          .where((r) => '${r['measured_at'] ?? ''}'.isNotEmpty)
          .toList();
      expect(doneItems, hasLength(2));
      for (final resp in phoneResponses) {
        final laptopItem = laptopItemIds['${resp['item_remote_id']}']!;
        final phoneItem = (await phone.fixture.db.query(
          'qc_items',
          where: 'item_id = ?',
          whereArgs: [resp['item_id']],
        )).single;
        expect('${phoneItem['remote_id']}', '${laptopItem['remote_id']}');
        expect(resp['inspection_id'], phoneSheetId);
        expect(
          '${resp['section_remote_id'] ?? ''}',
          isNotEmpty,
          reason: 'the FK to the implicit section is remapped, not dangled',
        );
      }

      final phoneLogs = await phone.fixture.db.query('qc_task_log');
      expect(phoneLogs, hasLength(1));
      final log = phoneLogs.single;
      expect('${log['note']}', 'second pass');
      expect(log['inspection_id'], phoneSheetId);
      expect(log['template_id'], phoneTemplateId);
      final phoneItemId = (await phone.fixture.db.query(
        'qc_items',
        columns: ['item_id'],
        where: 'remote_id = ?',
        whereArgs: [log['item_remote_id']],
      )).single;
      expect(log['item_id'], phoneItemId['item_id']);

      // No pointless pushback, no unresolvable queue rows anywhere.
      expect(await phone.queue.countPending(), 0);
    },
  );

  test(
    'an NC raised against a sheet and its CAPA stay linked on the viewer: '
    'the finding remaps through the sheet/item, the CAPA through the finding',
    () async {
      // Seed device 1 → device 2 first so the viewer holds the tree.
      final listId = await laptop.routine().saveRoutineList(
        name: 'Packing QC',
        items: const ['Carton sealed'],
      );
      final sheet = await laptop.routine().openPeriodSheet(listId);
      await laptop.pusher(remote).runOnce();
      await phone.puller(remote).runOnce();
      final laptopItems = await laptop.fixture.db.query('qc_items');
      final inspectionId = sheet.inspection.inspectionId!;
      final itemId = laptopItems.first['item_id'] as int;
      await laptop.routine().toggleCheck(
        inspectionId: inspectionId,
        itemId: itemId,
      );
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.failed, 0);
      final pulled = await phone.puller(remote).runOnce();
      expect(pulled.failed, 0);

      // ── Device 1 raises an NC against the sheet, then a CAPA on it ──────
      laptop.online = false;
      remote.offline = true;
      final findingId = await laptop.nc().createFinding(
        QcFindingNc(
          inspectionId: inspectionId,
          itemId: itemId,
          severity: NcSeverity.major,
          description: 'Carton was open',
          createdAt: '2026-09-01T08:00:00.000',
          updatedAt: '2026-09-01T08:00:00.000',
        ),
      );
      final capaId = await laptop.nc().createCapa(
        QcCapa(
          findingId: findingId,
          capaNo: 'CAPA-1',
          actionPlan: 'Seal it',
          createdAt: '2026-09-02T08:00:00.000',
          updatedAt: '2026-09-02T08:00:00.000',
        ),
      );
      expect(capaId, isNotNull);

      // ── Device 1 pushes both; device 2 pulls ────────────────────────────
      laptop.online = true;
      remote.offline = false;
      final pushed2 = await laptop.pusher(remote).runOnce();
      expect(pushed2.failed, 0);
      final pulled2 = await phone.puller(remote).runOnce();
      expect(pulled2.failed, 0);
      expect(pulled2.applied, 3,
          reason: 'finding + capa + the sheet row whose NC counters moved');

      final laptopFindings = await laptop.fixture.db.query('qc_findings_nc');
      final phoneFinding =
          (await phone.fixture.db.query('qc_findings_nc')).single;
      expect(laptopFindings, hasLength(1), reason: '$laptopFindings');
      expect(
        phoneFinding['remote_id'],
        '${laptopFindings.single['remote_id']}',
      );
      expect('${phoneFinding['description']}', 'Carton was open');
      expect(phoneFinding['deleted_at'], isNull);
      final phoneCapa = (await phone.fixture.db.query('qc_capa')).single;
      final laptopCapa = (await laptop.fixture.db.query('qc_capa')).single;
      expect(
        '${phoneCapa['remote_id'] ?? ''}',
        '${laptopCapa['remote_id']}',
        reason: 'the CAPA identity travels; its local ids are per-device',
      );
      expect('${phoneCapa['capa_no']}', 'CAPA-1');
      expect('${phoneCapa['finding_remote_id'] ?? ''}',
          phoneFinding['remote_id']);
      final phoneFindingId = (phoneFinding['finding_id'] as num).toInt();
      expect(phoneCapa['finding_id'], phoneFindingId);
      // The finding's sheet link survives the mapping (the sheet was pulled
      // earlier), while resp/capa stamps stay empty as authored.
      final phoneSheets = await phone.fixture.db.query('qc_inspections');
      expect(phoneSheets, hasLength(1));
      expect(await phone.queue.countPending(), 0);
    },
  );
}
