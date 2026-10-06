import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/offline_first_qc_repository.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_sop.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

/// Cross-entity audit coverage (plan V6_ENHANCED 21.3, the file P4 asks for by
/// name).
///
/// The other two High Audit suites prove the machinery: the hasher is
/// canonical, the repository is append-only, and one offline write commits with
/// its evidence. This suite proves the opposite direction - that *every*
/// lifecycle event the module cares about is actually distinguishable in the
/// trail. A hash chain over an undifferentiated log is a very good way to record
/// nothing useful, so each entity's transitions get their own action here.
class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

class _TestGuard implements WriteGuard {
  _TestGuard({Set<String>? allows})
    : _allows = allows ?? {Permission.qcRead.id, Permission.qcWrite.id};

  final Set<String> _allows;

  /// Always connected: the privileged-offline refusal is covered by
  /// `offline_first_audit_integration_test.dart`, and this file is about which
  /// events get recorded, not about who is allowed to record them.
  @override
  bool get online => true;

  @override
  String get uid => 'u1';

  @override
  String get email => 'u1@example.test';

  @override
  String get organizationId => 'org-1';

  @override
  String get memberId => 'm-1';

  @override
  String get deviceId => 'dev-1';

  @override
  bool allows(String permissionId) {
    if (!_allows.contains(permissionId)) return false;
    final permission = Permission.byId(permissionId);
    return permission == null ||
        !permissionRequiresFreshSession(permission) ||
        online;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late Database db;

  const t0 = '2026-01-05T08:00:00Z';
  const t1 = '2026-01-06T09:30:00Z';

  /// Holds every QC permission, including the privileged decisions.
  _TestGuard approver() => _TestGuard(
    allows: {
      Permission.qcRead.id,
      Permission.qcWrite.id,
      Permission.qcApprove.id,
      Permission.qcReject.id,
    },
  );

  QcRepositories repos() => QcRepositories.offlineFirst(
    dbHelper: helper,
    guard: approver(),
    actorReader: () =>
        const QcActor(uid: 'u1', name: 'Auditor', deviceId: 'dev-1'),
  );

  QcSop sop({String code = 'SOP-1'}) => QcSop(
    code: code,
    title: 'Weld inspection',
    contentText: 'body',
    status: SopStatus.draft,
    createdAt: t0,
    updatedAt: t0,
  );

  QcTemplate template({String code = 'TPL-1'}) => QcTemplate(
    name: 'Daily weld check',
    code: code,
    dept: 'Welding',
    createdAt: t0,
    updatedAt: t0,
  );

  QcInspection sheet(int templateId) => QcInspection(
    templateId: templateId,
    inspectionDate: t0,
    status: QcInspectionStatus.inProgress,
    createdAt: t0,
    updatedAt: t0,
  );

  QcGoal goal() => QcGoal(
    code: 'GOAL-1',
    title: 'Cut weld defects',
    goalType: QcGoalType.kpi,
    startDate: t0,
    status: QcGoalStatus.draft,
    createdAt: t0,
    updatedAt: t0,
  );

  QcFindingNc finding({
    required int inspectionId,
    int? findingId,
    String severity = NcSeverity.major,
    String status = NcStatus.open,
    String assignedTo = '',
    String verifiedBy = '',
  }) => QcFindingNc(
    findingId: findingId,
    inspectionId: inspectionId,
    severity: severity,
    description: 'Weld undercut',
    status: status,
    assignedTo: assignedTo,
    verifiedBy: verifiedBy,
    createdAt: t0,
    updatedAt: t0,
  );

  QcCapa capa({
    required int findingId,
    int? capaId,
    String status = CapaStatus.open,
    bool isEffective = false,
    String verifiedBy = '',
    String actionCompletedAt = '',
  }) => QcCapa(
    capaId: capaId,
    findingId: findingId,
    capaNo: 'CAPA-1',
    title: 'Re-train the welder',
    actionPlan: 'Two hours of refresher training',
    status: status,
    isEffective: isEffective,
    verifiedBy: verifiedBy,
    actionCompletedAt: actionCompletedAt,
    createdAt: t0,
    updatedAt: t0,
  );

  /// Seeds a checklist with one section and one item.
  Future<(int, int)> seedTemplate(
    QcRepositories r, {
    String code = 'TPL-1',
  }) async {
    final templateId = await r.templates.createTemplate(template(code: code));
    final sectionId = await db.insert(
      'qc_sections',
      QcSection(templateId: templateId, title: 'S').toMap(withId: false),
    );
    final itemId = await db.insert(
      'qc_items',
      QcItem(
        sectionId: sectionId,
        templateId: templateId,
        label: 'i',
      ).toMap(withId: false),
    );
    return (templateId, itemId);
  }

  /// A published finding, so the CAPA tests start from a real parent.
  Future<(int, int)> seedInspection(QcRepositories r) async {
    final (templateId, _) = await seedTemplate(r);
    final inspectionId = await r.inspections.createInspection(
      sheet(templateId),
    );
    final findingId = await r.ncCapa.createFinding(
      finding(inspectionId: inspectionId, severity: NcSeverity.critical),
    );
    return (inspectionId, findingId);
  }

  /// The actions recorded for one entity, oldest first.
  ///
  /// `audit.list` is newest-first like every other repo here, which is right for
  /// a screen and wrong for asserting a lifecycle: the order *is* the thing under
  /// test.
  Future<List<String>> actionsFor(QcRepositories r, String entityType) async =>
      (await r.audit.list(
        entityType: entityType,
      )).map((a) => a.action).toList().reversed.toList();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_qc_coverage');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
  });
  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('SOP publish', () {
    test('is recorded against the SOP and the revision', () async {
      final r = repos();
      final sopId = await r.sops.createSop(sop());

      final revId = await r.sops.publishSopRevision(
        sopId,
        changeSummary: 'tightened the acceptance window',
      );

      expect(await actionsFor(r, QcAuditEntity.sop), [
        QcAuditAction.sopCreated,
        QcAuditAction.sopPublished,
      ]);

      final revAudits = await r.audit.list(
        entityType: QcAuditEntity.sopRevision,
      );
      expect(revAudits, hasLength(1));
      expect(revAudits.single.entityId, '$revId');
      expect(revAudits.single.meta['sopId'], sopId);
      expect(
        revAudits.single.meta['changeSummary'],
        'tightened the acceptance window',
      );
      // The revision entry points at the revision instead of copying its body:
      // the SOP entry already holds the snapshot.
      expect(revAudits.single.before, isEmpty);
      expect(revAudits.single.after, isEmpty);
    });

    test(
      'each further publish adds a revision entry, not a replacement',
      () async {
        final r = repos();
        final sopId = await r.sops.createSop(sop());
        await r.sops.publishSopRevision(sopId, changeSummary: 'first');
        await r.sops.publishSopRevision(sopId, changeSummary: 'second');

        final revAudits = await r.audit.list(
          entityType: QcAuditEntity.sopRevision,
        );
        expect(revAudits.map((a) => a.entityId).toSet(), hasLength(2));
        expect(
          revAudits.map((a) => a.meta['changeSummary']),
          containsAll(['first', 'second']),
        );
      },
    );
  });

  group('template publish and versioning', () {
    test('publish is its own event', () async {
      final r = repos();
      final (templateId, _) = await seedTemplate(r);

      await r.templates.publishTemplate(templateId, publishedBy: 'u1');

      expect(await actionsFor(r, QcAuditEntity.template), [
        QcAuditAction.templateCreated,
        QcAuditAction.templatePublished,
      ]);
      final publish = (await r.audit.list(
        action: QcAuditAction.templatePublished,
      )).single;
      expect(publish.after['is_published'], isNotNull);
    });

    test(
      'duplicating a published checklist is recorded as a new version',
      () async {
        final r = repos();
        final (templateId, _) = await seedTemplate(r);
        await r.templates.publishTemplate(templateId, publishedBy: 'u1');

        final newId = await r.templates.duplicateTemplate(
          templateId,
          'TPL-1-v2',
          'Daily weld check v2',
        );

        final dup = (await r.audit.list(
          action: QcAuditAction.templateDuplicated,
        )).single;
        expect(dup.entityId, '$newId');
        expect(dup.meta['fromTemplateId'], templateId);
      },
    );

    test('archiving is not confused with deleting', () async {
      final r = repos();
      final templateId = await r.templates.createTemplate(template());

      await r.templates.archiveTemplate(templateId);

      final actions = await actionsFor(r, QcAuditEntity.template);
      expect(actions, contains(QcAuditAction.templateArchived));
      expect(actions, isNot(contains(QcAuditAction.templateDeleted)));
    });
  });

  group('inspection submit, review and approve', () {
    test('each status change is a distinct event', () async {
      final r = repos();
      final (templateId, _) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );

      for (final status in [
        QcInspectionStatus.submitted,
        QcInspectionStatus.reviewed,
        QcInspectionStatus.approved,
      ]) {
        await r.inspections.saveInspection(
          QcInspection(
            inspectionId: inspectionId,
            templateId: templateId,
            inspectionDate: t0,
            status: status,
            createdAt: t0,
            updatedAt: t1,
          ),
        );
      }

      expect(await actionsFor(r, QcAuditEntity.inspection), [
        QcAuditAction.inspectionCreated,
        QcAuditAction.inspectionSubmitted,
        QcAuditAction.inspectionReviewed,
        QcAuditAction.inspectionApproved,
      ]);
    });

    test('the approve decision is distinguishable from a review', () async {
      final r = repos();
      final (templateId, _) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );

      await r.inspections.saveInspection(
        QcInspection(
          inspectionId: inspectionId,
          templateId: templateId,
          inspectionDate: t0,
          status: QcInspectionStatus.approved,
          approvedBy: 'u1',
          approvedAt: t1,
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final approve = (await r.audit.list(
        action: QcAuditAction.inspectionApproved,
      )).single;
      expect(approve.entityId, '$inspectionId');
      expect(approve.after['approved_by'], 'u1');
    });

    test('a rejection is recorded as a rejection, not an approval', () async {
      final r = repos();
      final (templateId, _) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );

      await r.inspections.saveInspection(
        QcInspection(
          inspectionId: inspectionId,
          templateId: templateId,
          inspectionDate: t0,
          status: QcInspectionStatus.rejected,
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final actions = await actionsFor(r, QcAuditEntity.inspection);
      expect(actions, contains(QcAuditAction.inspectionRejected));
      expect(actions, isNot(contains(QcAuditAction.inspectionApproved)));
    });
  });

  group('NC create, assign, verify and close', () {
    test('all four are separate actions', () async {
      final r = repos();
      final (inspectionId, findingId) = await seedInspection(r);

      await r.ncCapa.saveFinding(
        finding(
          findingId: findingId,
          inspectionId: inspectionId,
          severity: NcSeverity.critical,
          status: NcStatus.assigned,
          assignedTo: 'welder-7',
        ),
      );
      await r.ncCapa.saveFinding(
        finding(
          findingId: findingId,
          inspectionId: inspectionId,
          severity: NcSeverity.critical,
          status: NcStatus.verified,
          assignedTo: 'welder-7',
          verifiedBy: 'inspector-2',
        ),
      );
      await r.ncCapa.saveFinding(
        finding(
          findingId: findingId,
          inspectionId: inspectionId,
          severity: NcSeverity.critical,
          status: NcStatus.closed,
          assignedTo: 'welder-7',
          verifiedBy: 'inspector-2',
        ),
      );

      expect(await actionsFor(r, QcAuditEntity.finding), [
        QcAuditAction.findingCreated,
        QcAuditAction.findingAssigned,
        QcAuditAction.findingVerified,
        QcAuditAction.findingClosed,
      ]);

      // The verifier is captured, so "who signed this off?" is answerable.
      final verified = (await r.audit.list(
        action: QcAuditAction.findingVerified,
      )).single;
      expect(verified.meta['verifiedBy'], 'inspector-2');
      expect(verified.meta['status'], NcStatus.verified);
    });

    test(
      're-saving the same owner is an update, not a second assignment',
      () async {
        final r = repos();
        final (inspectionId, findingId) = await seedInspection(r);

        final assigned = finding(
          findingId: findingId,
          inspectionId: inspectionId,
          severity: NcSeverity.critical,
          status: NcStatus.assigned,
          assignedTo: 'welder-7',
        );
        await r.ncCapa.saveFinding(assigned);
        await r.ncCapa.saveFinding(
          QcFindingNc(
            findingId: findingId,
            inspectionId: inspectionId,
            severity: NcSeverity.critical,
            description: 'Weld undercut',
            status: NcStatus.inProgress,
            assignedTo: 'welder-7',
            createdAt: t0,
            updatedAt: t1,
          ),
        );

        final actions = await actionsFor(r, QcAuditEntity.finding);
        expect(
          actions.where((a) => a == QcAuditAction.findingAssigned),
          hasLength(1),
        );
        expect(actions, contains(QcAuditAction.findingUpdated));
      },
    );

    test('the verifier and the closer are not the same claim', () async {
      final r = repos();
      final (inspectionId, findingId) = await seedInspection(r);

      await r.ncCapa.saveFinding(
        finding(
          findingId: findingId,
          inspectionId: inspectionId,
          severity: NcSeverity.critical,
          status: NcStatus.verified,
          verifiedBy: 'inspector-2',
        ),
      );

      final actions = await actionsFor(r, QcAuditEntity.finding);
      expect(actions, isNot(contains(QcAuditAction.findingClosed)));
    });
  });

  group('CAPA action, verify, effective and close', () {
    test('all four are separate actions', () async {
      final r = repos();
      final (_, findingId) = await seedInspection(r);
      final capaId = await r.ncCapa.createCapa(capa(findingId: findingId));

      await r.ncCapa.saveCapa(
        capa(
          capaId: capaId,
          findingId: findingId,
          status: CapaStatus.actionComplete,
          actionCompletedAt: t1,
        ),
      );
      await r.ncCapa.saveCapa(
        capa(
          capaId: capaId,
          findingId: findingId,
          status: CapaStatus.verifiedEffective,
          isEffective: true,
          verifiedBy: 'qa-lead',
          actionCompletedAt: t1,
        ),
      );
      await r.ncCapa.saveCapa(
        capa(
          capaId: capaId,
          findingId: findingId,
          status: CapaStatus.closed,
          isEffective: true,
          verifiedBy: 'qa-lead',
          actionCompletedAt: t1,
        ),
      );

      expect(await actionsFor(r, QcAuditEntity.capa), [
        QcAuditAction.capaCreated,
        QcAuditAction.capaActionComplete,
        QcAuditAction.capaVerified,
        QcAuditAction.capaClosed,
      ]);
      expect(capaId, isNotNull);
    });

    test('an ineffective verdict is still a verification', () async {
      final r = repos();
      final (_, findingId) = await seedInspection(r);
      final capaId = await r.ncCapa.createCapa(capa(findingId: findingId));

      await r.ncCapa.saveCapa(
        capa(
          capaId: capaId,
          findingId: findingId,
          status: CapaStatus.verifiedIneffective,
          verifiedBy: 'qa-lead',
        ),
      );

      expect(await actionsFor(r, QcAuditEntity.capa), [
        QcAuditAction.capaCreated,
        QcAuditAction.capaVerified,
      ]);
    });

    test('declaring a CAPA effective is not the same as closing it', () async {
      final r = repos();
      final (_, findingId) = await seedInspection(r);
      final capaId = await r.ncCapa.createCapa(capa(findingId: findingId));

      await r.ncCapa.saveCapa(
        capa(
          capaId: capaId,
          findingId: findingId,
          isEffective: true,
          verifiedBy: 'qa-lead',
        ),
      );

      final actions = await actionsFor(r, QcAuditEntity.capa);
      expect(actions, contains(QcAuditAction.capaVerified));
      expect(actions, isNot(contains(QcAuditAction.capaClosed)));
    });

    test('reporting the action finished needs no approve permission', () async {
      // The owner finishing their own work is routine; only a reviewer may
      // declare the CAPA effective.
      final r = QcRepositories.offlineFirst(
        dbHelper: helper,
        guard: _TestGuard(),
        actorReader: () =>
            const QcActor(uid: 'u1', name: 'Owner', deviceId: 'dev-1'),
      );
      final approverRepos = repos();
      final (_, findingId) = await seedInspection(approverRepos);
      final capaId = await approverRepos.ncCapa.createCapa(
        capa(findingId: findingId),
      );

      await r.ncCapa.saveCapa(
        capa(
          capaId: capaId,
          findingId: findingId,
          status: CapaStatus.actionComplete,
          actionCompletedAt: t1,
        ),
      );

      // Both facades share one audit chain, so the approver's create is already
      // there; what matters is that the owner's report landed on its own.
      expect(await actionsFor(r, QcAuditEntity.capa), [
        QcAuditAction.capaCreated,
        QcAuditAction.capaActionComplete,
      ]);
    });
  });

  group('goal completion', () {
    test('records completed_by alongside the completion event', () async {
      final r = repos();
      final goalId = await r.goals.createGoal(goal());

      await r.goals.saveGoal(
        QcGoal(
          goalId: goalId,
          code: 'GOAL-1',
          title: 'Cut weld defects',
          goalType: QcGoalType.kpi,
          startDate: t0,
          status: QcGoalStatus.completed,
          completedBy: 'shift-lead',
          completedByName: 'Shift Lead',
          completedAt: t1,
          completionEvidenceJson: '{"photo":"weld-7.png"}',
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final stored = await r.goals.getGoal(goalId);
      expect(stored!.completedBy, 'shift-lead');
      expect(stored.completedByName, 'Shift Lead');
      expect(stored.completedAt, t1);

      final complete = (await r.audit.list(
        action: QcAuditAction.goalCompleted,
      )).single;
      expect(complete.entityId, '$goalId');
      expect(complete.after['completed_by'], 'shift-lead');
      expect(complete.after['completed_at'], t1);
      expect(
        complete.after['completion_evidence_json'],
        contains('weld-7.png'),
      );
    });

    test('assignment and action tracking are audited too', () async {
      final r = repos();
      await r.goals.createGoal(goal());

      await r.goals.assignGoal(
        QcGoalAssignment(
          goalId: 1,
          assigneeId: 'analyst-3',
          assigneeName: 'Analyst Three',
          assignedAt: t0,
          assignedBy: 'u1',
          createdAt: t0,
          updatedAt: t0,
        ),
      );
      await r.goals.addAction(
        QcGoalAction(
          goalId: 1,
          actionText: 'Chart the defect Pareto',
          createdAt: t0,
          updatedAt: t0,
        ),
      );

      expect(await actionsFor(r, QcAuditEntity.goalAssignment), [
        QcAuditAction.goalAssigned,
      ]);
      expect(await actionsFor(r, QcAuditEntity.goalAction), [
        QcAuditAction.goalActionAdded,
      ]);
    });
  });

  group('the chain covers all of it', () {
    test('a full pass over every entity still verifies', () async {
      // The point of the coverage above is worthless if the resulting log does
      // not verify, so one chain walk covers the whole suite.
      final r = repos();
      final (templateId, _) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );
      final findingId = await r.ncCapa.createFinding(
        finding(inspectionId: inspectionId, severity: NcSeverity.critical),
      );
      await r.ncCapa.createCapa(capa(findingId: findingId));
      await r.goals.createGoal(goal());
      final sopId = await r.sops.createSop(sop());
      await r.sops.publishSopRevision(sopId, changeSummary: 'first');
      await r.templates.publishTemplate(templateId, publishedBy: 'u1');

      final verification = await r.audit.verifyChain();

      expect(verification.isValid, isTrue, reason: verification.reason ?? '');
      expect(verification.checked, greaterThanOrEqualTo(6));
      // Every entity the module owns contributed to one chain.
      final types = (await r.audit.list()).map((a) => a.entityType).toSet();
      expect(
        types,
        containsAll([
          QcAuditEntity.sop,
          QcAuditEntity.sopRevision,
          QcAuditEntity.template,
          QcAuditEntity.inspection,
          QcAuditEntity.finding,
          QcAuditEntity.capa,
          QcAuditEntity.goal,
        ]),
      );
    });
  });
}
