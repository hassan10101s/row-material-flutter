import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/backfill_service.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/core/sync/shared_data_writer.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/offline_first_qc_repository.dart';
import 'package:material_lab/features/qc_manager/domain/qc_sop.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';
import 'package:material_lab/features/reference/data/offline_first_reference_repository.dart';

import 'sync_test_fixture.dart';

class _Guard implements WriteGuard {
  _Guard(this.session);
  final AppSession session;
  @override
  String get uid => session.uid;
  @override
  String get email => session.email;
  @override
  String get organizationId => session.organizationId;
  @override
  String get memberId => session.memberId;
  @override
  String get deviceId => session.deviceId;
  @override
  bool get online => true;
  @override
  bool allows(String id) => session.canDo(Permission.byId(id)!);
}

class _Device {
  _Device(this.fixture, String id, {bool viewer = false})
    : session = AppSession(
        uid: 'uid_$id',
        email: '$id@test.invalid',
        organizationId: 'org_shared',
        memberId: 'member_$id',
        role: viewer ? AppRoles.viewer : AppRoles.admin,
        status: 'active',
        deviceId: id,
        readOnlyDevice: viewer,
      );
  final SyncFixture fixture;
  final AppSession session;
  late final guard = _Guard(session);
  late final queue = SyncQueue(fixture.helper);
  late final metadata = SyncMetadata(fixture.helper);
  late final audit = AuditLogger(queue: queue, session: () => session);
  late final settings = SettingsRepo(
    dbHelper: fixture.helper,
    secret: LocalSecret(fixture.dir.path),
    queue: queue,
    guard: guard,
  );
  late final reference = OfflineFirstReferenceRepository(
    dbHelper: fixture.helper,
    guard: guard,
    queue: queue,
    audit: audit,
  );
  late final qc = QcRepositories.offlineFirst(
    dbHelper: fixture.helper,
    guard: guard,
    queue: queue,
  );
  Future<void> push(InMemoryDataSource remote) async {
    final report = await PushWorker(
      queue: queue,
      metadata: metadata,
      remote: remote,
      audit: audit,
      source: SessionSource.empty(() => session),
    ).runOnce();
    expect(report.conflicts, 0);
    expect(report.retried, 0);
    expect(report.failed, 0);
  }

  Future<void> pull(InMemoryDataSource remote) async {
    final report = await PullWorker(
      queue: queue,
      metadata: metadata,
      remote: remote,
      conflicts: ConflictResolver(queue: queue, remote: remote),
      source: SessionSource.empty(() => session),
    ).runOnce();
    expect(report.failed, 0, reason: '${report.error}');
    expect(report.error, isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Device desktop, mobile;
  late InMemoryDataSource remote;
  setUp(() async {
    desktop = _Device(await openSyncFixture(), 'desktop');
    mobile = _Device(await openSyncFixture(), 'phone', viewer: true);
    remote = InMemoryDataSource();
  });
  tearDown(() async {
    await desktop.fixture.dispose();
    await mobile.fixture.dispose();
  });

  test('remote deletions disappear from live registries and counts', () async {
    await desktop.fixture.seedOrganization();
    await desktop.fixture.db.insert('lab_inventory', {
      'name': 'Reagent',
      'category': 'powder',
      'unit': 'g',
      'created_at': '2026-01-01',
      'updated_at': '2026-01-01',
    });
    await desktop.fixture.db.insert('lab_equipment', {
      'name': 'Balance',
      'code': 'BAL-01',
      'created_at': '2026-01-01',
      'updated_at': '2026-01-01',
    });
    await desktop.reference.upsertUnit('g');
    await desktop.fixture.db.transaction((txn) async {
      for (final type in ['referenceMaterial', 'inventoryItem', 'equipment']) {
        await queueSharedRows(
          txn,
          type: type,
          queue: desktop.queue,
          guard: desktop.guard,
        );
      }
    });
    await desktop.push(remote);
    await mobile.pull(remote);
    final lab = LabRepo(dbHelper: mobile.fixture.helper);
    expect(await lab.countInventory(), 1);
    expect(await lab.listEquipment(), hasLength(1));
    final unitCount = await mobile.reference.countUnits();
    expect(
      (await mobile.reference.listUnits()).map((row) => row['symbol']),
      contains('g'),
    );
    for (final collection in [
      SyncCollection.referenceMaterials,
      SyncCollection.inventoryItems,
      SyncCollection.equipment,
      SyncCollection.labConfig,
    ]) {
      final page = await remote.listSince(
        organizationId: desktop.session.organizationId,
        collection: collection,
        startAtTs: '',
        startAtId: '',
      );
      for (final document in page.documents) {
        await remote.deleteTombstone(
          organizationId: desktop.session.organizationId,
          collection: collection,
          documentId: document.id,
        );
      }
    }
    await mobile.pull(remote);
    expect(await lab.listInventory(), isEmpty);
    expect(await lab.countInventory(), 0);
    expect(await lab.listInventoryPaged(), isEmpty);
    expect(await lab.listEquipment(), isEmpty);
    expect(
      (await mobile.reference.listUnits()).map((row) => row['symbol']),
      isNot(contains('g')),
    );
    expect(await mobile.reference.countUnits(), unitCount - 1);
    expect(await mobile.reference.listMaterials(), isEmpty);
  });

  test(
    'analysis recipe inputs map to the receiving inventory identity',
    () async {
      await desktop.fixture.db.insert('lab_inventory', {
        'id': 7,
        'name': 'Recipe reagent',
        'category': 'powder',
        'unit': 'g',
        'created_at': '2026-01-01',
        'updated_at': '2026-01-01',
      });
      await mobile.fixture.db.insert('lab_inventory', {
        'id': 71,
        'name': 'Recipe reagent',
        'category': 'powder',
        'unit': 'g',
        'remote_id': 'receiving-seed',
        'created_at': '2026-01-01',
        'updated_at': '2026-01-01',
      });
      await desktop.fixture.db.insert('lab_analyses', {
        'id': 5,
        'name': 'Residue',
        'unit': '%',
        'created_at': '2026-01-01',
      });
      await desktop.fixture.db.insert('lab_analysis_items', {
        'id': 9,
        'analysis_id': 5,
        'inventory_id': 7,
        'qty_per_sample': 0.25,
        'unit': 'g',
      });
      await desktop.fixture.db.transaction((txn) async {
        for (final type in [
          'inventoryItem',
          'labAnalysis',
          'labAnalysisItem',
        ]) {
          await queueSharedRows(
            txn,
            type: type,
            queue: desktop.queue,
            guard: desktop.guard,
          );
        }
      });
      await desktop.push(remote);
      await mobile.pull(remote);
      final input = (await mobile.fixture.db.query(
        'lab_analysis_items',
      )).single;
      expect(input['inventory_id'], 71);
      expect(input['qty_per_sample'], 0.25);
    },
  );

  test(
    'bounded backfill keeps progressing beyond already queued rows',
    () async {
      for (var i = 0; i < 3; i++) {
        await desktop.fixture.db.insert('lab_inventory', {
          'name': 'Legacy $i',
          'category': 'powder',
          'unit': 'g',
          'created_at': '2026-01-01',
          'updated_at': '2026-01-01',
        });
      }
      final service = BackfillService(
        dbHelper: desktop.fixture.helper,
        queue: desktop.queue,
        guard: desktop.guard,
      );
      for (var i = 0; i < 3; i++) {
        final report = await service.enqueueUnsyncedAll(
          limit: 1,
          onlyTypes: {'inventoryItem'},
        );
        expect(report.queued, 1);
      }
      expect(
        (await service.enqueueUnsyncedAll(
          limit: 1,
          onlyTypes: {'inventoryItem'},
        )).total,
        0,
      );
      final rows = await desktop.fixture.db.query('lab_inventory');
      expect(
        rows.every((row) => '${row['remote_id'] ?? ''}'.isNotEmpty),
        isTrue,
      );
    },
  );

  test(
    'report content and logo replicate, device paths and seals stay local',
    () async {
      await desktop.settings.updateSettings({
        'department_label': 'مختبر الجودة',
        'inspection_report_form_no': 'QA-004',
        'report_logo_data_uri': 'data:image/png;base64,AAAA',
        'report_logo_path': r'C:\desktop\logo.png',
        'export_root_path': r'C:\reports',
        'usage_expiry_date': 'sealed-device-value',
        'app_theme': 'dark',
      });
      await desktop.push(remote);
      await mobile.pull(remote);
      expect(
        await mobile.settings.getSettingValue('department_label'),
        'مختبر الجودة',
      );
      expect(
        await mobile.settings.getSettingValue('inspection_report_form_no'),
        'QA-004',
      );
      expect(
        await mobile.settings.getReportLogoDataUri(),
        'data:image/png;base64,AAAA',
      );
      for (final key in [
        'report_logo_path',
        'export_root_path',
        'usage_expiry_date',
        'app_theme',
      ]) {
        expect(
          await mobile.settings.getSettingValue(key),
          isNot(
            anyOf(
              r'C:\desktop\logo.png',
              r'C:\reports',
              'sealed-device-value',
              'dark',
            ),
          ),
        );
      }
      await expectLater(
        mobile.settings.updateSettings({'department_label': 'forbidden'}),
        throwsA(isA<Exception>()),
      );
      await desktop.settings.clearReportLogo();
      await desktop.push(remote);
      await mobile.pull(remote);
      expect(await mobile.settings.getReportLogoDataUri(), '');
    },
  );

  test(
    'parameters, bounds and SOP revisions preserve links with different local ids',
    () async {
      // Seed unrelated rows on the receiving device so raw numeric ids collide.
      await mobile.fixture.seedOrganization();
      await desktop.fixture.seedOrganization();
      await mobile.fixture.db.insert('parameters', {
        'id': 91,
        'parameter_name': 'Moisture',
        'parameter_type': 'chemical',
        'unit': '%',
        'imported_at': '2026-01-01',
      });
      await desktop.reference.upsertParameter('Moisture', '%');
      final parameter = (await desktop.fixture.db.query(
        'parameters',
        where: 'parameter_name = ?',
        whereArgs: ['Moisture'],
      )).single;
      await desktop.fixture.db.insert('material_parameter_bounds', {
        'material_id': 1,
        'parameter_id': parameter['id'],
        'parameter_type': 'chemical',
        'unit': '%',
        'min_value': 1.5,
        'max_value': 12.0,
        'precision': 2,
        'is_required': 1,
      });
      await desktop.fixture.db.transaction((txn) async {
        await queueSharedRows(
          txn,
          type: 'referenceMaterial',
          queue: desktop.queue,
          guard: desktop.guard,
        );
        await queueSharedRows(
          txn,
          type: 'materialBound',
          queue: desktop.queue,
          guard: desktop.guard,
        );
      });
      await mobile.fixture.db.insert(
        'qc_sops',
        const QcSop(
          sopId: 70,
          code: 'LOCAL',
          title: 'Local',
          createdAt: '2026-01-01',
          updatedAt: '2026-01-01',
        ).toMap(),
      );
      final sopId = await desktop.qc.sops.createSop(
        const QcSop(
          code: 'SOP-001',
          title: 'اختبار الرطوبة',
          contentText: 'Weigh the sample.',
          createdAt: '2026-01-01',
          updatedAt: '2026-01-01',
        ),
      );
      await desktop.qc.sops.publishSopRevision(
        sopId,
        changeSummary: 'Initial release',
      );
      await desktop.push(remote);
      await mobile.pull(remote);
      final bounds = (await mobile.fixture.db.query(
        'material_parameter_bounds',
      )).single;
      expect(bounds['parameter_id'], 91);
      expect(bounds['max_value'], 12.0);
      expect(bounds['is_required'], 1);
      final mirrored = await mobile.qc.sops.getSopByCode('SOP-001');
      expect(mirrored?.sopId, isNot(sopId));
      expect(mirrored?.contentText, 'Weigh the sample.');
      final revisions = await mobile.qc.sops.listSopRevisions(mirrored!.sopId!);
      expect(revisions.single.sopId, mirrored.sopId);
      expect(revisions.single.changeReason, 'Initial release');
      await desktop.reference.deleteParameter('Moisture');
      await desktop.push(remote);
      await mobile.pull(remote);
      expect(await mobile.reference.listParameters(), isEmpty);
      expect(
        (await mobile.fixture.db.query(
          'material_parameter_bounds',
        )).single['deleted_at'],
        isNotNull,
      );
    },
  );
}
