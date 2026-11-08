import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/server_confirmed_qc_repository.dart';
import 'package:material_lab/features/qc_manager/data/ncr_report_repo.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_filters.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import '../../sync/sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  late QcNcCapaRepository repo;
  late int batchId, sampleId;
  const stamp = '2026-11-02T10:00:00';
  QcFindingNc finding({
    int? id,
    String description = 'Protein outside the approved limits',
  }) => QcFindingNc(
    findingId: id,
    inspectionId: 0,
    productSampleId: sampleId,
    severity: 'Major',
    description: description,
    createdAt: stamp,
    updatedAt: stamp,
    createdBy: 'uid_admin',
    updatedBy: 'uid_admin',
  );
  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    batchId = await fixture.db.insert('inspections', {
      ...sampleRow(entryCode: 'PRODUCT-001'),
      'inspection_kind': 'product',
      'batch_number': 'B-15',
    });
    sampleId = await fixture.db.insert('product_batch_samples', {
      'batch_id': batchId,
      'sample_no': 3,
      'sample_name': 'Sample 3',
      'sample_taker': 'Mohamed Said',
      'decision_status': 'APPROVED',
      'tested_at': stamp,
      'created_at': stamp,
      'remote_id': 'sample-global-3',
    });
    repo = QcRepositories.serverConfirmed(
      dbHelper: fixture.helper,
      guard: SessionWriteGuard(
        source: SessionSource(
          () => const AppSession(
            uid: 'uid_admin',
            organizationId: 'org',
            memberId: 'member',
            deviceId: 'device',
            role: 'admin',
            status: 'active',
          ),
        ),
        isOnline: () => true,
      ),
      actorReader: () => const QcActor(uid: 'uid_admin', name: 'Manager'),
    ).ncCapa;
  });
  tearDown(() => fixture.dispose());
  test(
    'the decision editor finds an open case before newer closed history',
    () async {
      final open = await repo.saveProductSampleFinding(finding());
      final row = (await fixture.db.query('qc_findings_nc')).single;
      await fixture.db.insert('qc_findings_nc', {
        ...row,
        'finding_id': null,
        'remote_id': 'closed-history',
        'status': 'Closed',
      });
      expect((await repo.getProductSampleFinding(sampleId))?.findingId, open);
    },
  );
  test(
    'finding and decision commit together, appear in quality register and preserve source on edit',
    () async {
      final id = await repo.saveProductSampleFinding(finding());
      final saved = (await fixture.db.query('product_batch_samples')).single;
      final nc = (await fixture.db.query('qc_findings_nc')).single;
      expect(saved['decision_status'], 'NON_CONFORMANCE');
      expect(saved['non_conformance_remote_id'], nc['remote_id']);
      expect(nc['product_sample_id'], sampleId);
      expect(nc['inspection_id'], isNull);
      final row = (await QcNcReportRepo(
        dbHelper: fixture.helper,
      ).list(const NcrFilters())).single;
      expect(row.productSampleId, sampleId);
      expect(row.productInspectionId, batchId);
      expect(row.inspectionRefId, contains('PRODUCT-001'));
      expect(row.inspectionRefId, contains('Sample 3'));
      expect(
        await QcNcReportRepo(
          dbHelper: fixture.helper,
        ).count(const NcrFilters()),
        1,
      );
      await repo.saveProductSampleFinding(
        finding(id: id, description: 'Updated investigation'),
      );
      expect(
        (await repo.getProductSampleFinding(sampleId))!.description,
        'Updated investigation',
      );
      expect(await fixture.db.query('qc_findings_nc'), hasLength(1));
      expect(
        (await fixture.db.query(
          'product_batch_samples',
        )).single['sample_taker'],
        'Mohamed Said',
      );
    },
  );
  test(
    'duplicate finding and deleting the active linked finding are refused; changing decision clears pointer',
    () async {
      final id = await repo.saveProductSampleFinding(finding());
      await expectLater(
        repo.saveProductSampleFinding(finding()),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        repo.deleteFinding(id),
        throwsA(isA<ValidationError>()),
      );
      final lab = LabRepo(dbHelper: fixture.helper);
      await lab.setBatchSampleDecision(sampleId, status: 'APPROVED');
      expect(
        (await fixture.db.query(
          'product_batch_samples',
        )).single['non_conformance_remote_id'],
        '',
      );
      await repo.deleteFinding(id);
      expect(
        await QcNcReportRepo(
          dbHelper: fixture.helper,
        ).count(const NcrFilters()),
        0,
      );
    },
  );
  test(
    'an audit failure rolls both writes back; direct non-conformance decisions cannot bypass the form',
    () async {
      await fixture.db.execute(
        "CREATE TRIGGER reject_ncr_audit BEFORE INSERT ON qc_audits BEGIN SELECT RAISE(ABORT, 'audit unavailable'); END",
      );
      await expectLater(
        repo.saveProductSampleFinding(finding()),
        throwsA(isA<Exception>()),
      );
      expect(await fixture.db.query('qc_findings_nc'), isEmpty);
      expect(
        (await fixture.db.query(
          'product_batch_samples',
        )).single['decision_status'],
        'APPROVED',
      );
      await expectLater(
        LabRepo(
          dbHelper: fixture.helper,
        ).setBatchSampleDecision(sampleId, status: 'NON_CONFORMANCE'),
        throwsA(isA<ValidationError>()),
      );
    },
  );
}
