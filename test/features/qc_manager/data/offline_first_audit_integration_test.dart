import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_errors.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/offline_first_qc_repository.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_sop.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, DatabaseException;

/// The offline-first contract for QC (plan V6_ENHANCED §21.3, P3).
///
/// The local repositories are proven elsewhere (`qc_repo_test.dart`). What is
/// proven *here* is the seam the local layer deliberately does not have:
///
///  * the write, its `qc_audits` row and (where relevant) its `sync_queue` row
///    commit as one unit,
///  * the §9.4 guards run before anything is written,
///  * the actor comes from the live session, and
///  * a rollback takes the audit evidence with it rather than leaving a trail of
///    something that never happened.
class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// A guard with an explicit permission set, so a test can say who is signed in.
class _TestGuard implements WriteGuard {
  _TestGuard({this.online = true, Set<String>? allows})
    : _allows = allows ?? {Permission.qcRead.id, Permission.qcWrite.id};

  @override
  final bool online;
  final Set<String> _allows;

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

  /// Mirrors `SessionWriteGuard.allows`, which folds the connectivity rule into
  /// the permission check: a privileged permission is simply not held while
  /// offline. A fake that answered `true` regardless would test nothing.
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

  Future<void> freshDatabase() async {
    tmp = await Directory.systemTemp.createTemp('matlab_qc_offline');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
  }

  /// A guard that also holds the privileged QC permissions.
  _TestGuard approver() => _TestGuard(
    allows: {
      Permission.qcRead.id,
      Permission.qcWrite.id,
      Permission.qcApprove.id,
      Permission.qcReject.id,
    },
  );

  QcRepositories repos(_TestGuard guard, {QcActor? actor}) =>
      QcRepositories.offlineFirst(
        dbHelper: helper,
        guard: guard,
        actorReader: () =>
            actor ??
            QcActor(uid: guard.uid, name: guard.email, deviceId: 'dev-1'),
      );

  const t0 = '2026-01-05T08:00:00Z';
  const t1 = '2026-01-06T09:30:00Z';

  QcSop sop({String code = 'SOP-1'}) => QcSop(
    code: code,
    title: 'Weld inspection',
    contentText: 'body of $code',
    status: SopStatus.draft,
    createdAt: t0,
    updatedAt: t0,
  );

  QcTemplate template({String code = 'TPL-1'}) => QcTemplate(
    name: 'Daily weld check',
    code: code,
    dept: 'Welding',
    createdAt: t0,
    updatedAt: t1,
  );

  QcInspection sheet(int templateId) => QcInspection(
    templateId: templateId,
    inspectionDate: t0,
    status: QcInspectionStatus.inProgress,
    createdAt: t0,
    updatedAt: t0,
  );

  QcGoal goal({String code = 'GOAL-1', String status = QcGoalStatus.draft}) =>
      QcGoal(
        code: code,
        title: 'Cut weld defects',
        goalType: QcGoalType.kpi,
        startDate: t0,
        status: status,
        createdAt: t0,
        updatedAt: t0,
      );

  QcFindingNc finding({
    required int inspectionId,
    String severity = NcSeverity.major,
    String description = 'Surface scratch',
    String status = NcStatus.open,
  }) => QcFindingNc(
    inspectionId: inspectionId,
    severity: severity,
    description: description,
    status: status,
    createdAt: t0,
    updatedAt: t0,
  );

  /// Seeds a checklist with one section and one item, returning its ids.
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

  setUp(freshDatabase);
  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('guards', () {
    test(
      'a write without the QC permission is refused and leaves no row',
      () async {
        final r = repos(_TestGuard(allows: {Permission.qcRead.id}));

        await expectLater(
          r.sops.createSop(sop()),
          throwsA(isA<AuthorizationError>()),
        );

        // The refusal has to happen before the write, not after.
        expect(await db.query('qc_sops'), isEmpty);
        expect(await r.audit.count(), 0);
      },
    );

    test(
      'a privileged write without connectivity is refused as such',
      () async {
        final r = repos(
          _TestGuard(
            online: false,
            allows: {
              Permission.qcRead.id,
              Permission.qcWrite.id,
              Permission.qcApprove.id,
            },
          ),
        );

        await expectLater(
          r.sops.publishSopRevision(1, changeSummary: 'first'),
          throwsA(
            isA<AuthorizationError>().having(
              (e) => e.message,
              'message',
              AppErrors.privilegedOperationNeedsConnection,
            ),
          ),
        );
        expect(await db.query('qc_sops'), isEmpty);
      },
    );

    test('authoring works offline once the permission is held', () async {
      // `qc.write` is deliberately not privileged: a floor inspector filling in
      // a checklist in a basement with no signal is the normal case, not an edge
      // case.
      final r = repos(_TestGuard(online: false));

      final id = await r.sops.createSop(sop());

      expect(id, isNotNull);
      expect((await r.sops.getSop(id))!.code, 'SOP-1');
    });

    test('a missing row is an error rather than a silent no-op', () async {
      final r = repos(approver());

      await expectLater(
        r.sops.updateSop(
          const QcSop(
            sopId: 999,
            code: 'X',
            title: 'X',
            createdAt: t0,
            updatedAt: t0,
          ),
        ),
        throwsA(isA<NotFoundError>()),
      );
    });
  });

  group('one transaction', () {
    test('a created SOP and its audit row commit together', () async {
      final r = repos(approver());

      final id = await r.sops.createSop(sop());

      final audits = await r.audit.list(entityType: QcAuditEntity.sop);
      expect(audits, hasLength(1));
      expect(audits.single.entityId, '$id');
      expect(audits.single.action, QcAuditAction.sopCreated);
      expect(audits.single.byUserId, 'u1');
      expect(audits.single.immutable, isTrue);
    });

    test('the audit row carries the actor from the live session', () async {
      // A trail whose author is chosen by the writing code is not a trail, so the
      // repository reads the session rather than trusting the caller.
      final r = repos(
        approver(),
        actor: const QcActor(
          uid: 'real-user',
          name: 'Real User',
          deviceId: 'dev-9',
        ),
      );

      await r.sops.createSop(sop());

      final audit = (await r.audit.list()).single;
      expect(audit.byUserId, 'real-user');
      expect(audit.byUserName, 'Real User');
      expect(audit.deviceId, 'dev-9');
    });

    test(
      'a rejected call inside the transaction leaves no partial evidence',
      () async {
        final r = repos(approver());

        // Publishing a template with no items throws from inside the transaction.
        final templateId = await r.templates.createTemplate(template());
        await expectLater(
          r.templates.publishTemplate(templateId),
          throwsA(isA<StateError>()),
        );

        final audits = await r.audit.list(
          action: QcAuditAction.templatePublished,
        );
        expect(audits, isEmpty);
        // The template itself survives: the failed call only rolled back the
        // publish, not the earlier, separate create.
        expect(
          (await r.templates.getTemplate(templateId))!.isPublished,
          isFalse,
        );
      },
    );

    test('a goal completion records who finished it and audits it', () async {
      final r = repos(approver());
      final goalId = await r.goals.createGoal(goal());

      final done = goal(status: QcGoalStatus.completed);
      await r.goals.saveGoal(
        QcGoal(
          goalId: goalId,
          code: done.code,
          title: done.title,
          goalType: done.goalType,
          startDate: t0,
          status: QcGoalStatus.completed,
          completedBy: 'u1',
          completedByName: 'Shift Lead',
          completedAt: t1,
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final stored = await r.goals.getGoal(goalId);
      expect(stored!.completedBy, 'u1');
      expect(stored.completedAt, t1);
      final audit = (await r.audit.list(
        action: QcAuditAction.goalCompleted,
      )).single;
      expect(audit.entityId, '$goalId');
      expect(audit.after['completed_by'], 'u1');
    });

    test(
      'completing a goal is refused without the approve permission',
      () async {
        final r = repos(_TestGuard());
        final goalId = await r.goals.createGoal(goal());

        await expectLater(
          r.goals.saveGoal(
            QcGoal(
              goalId: goalId,
              code: 'GOAL-1',
              title: 'Cut weld defects',
              startDate: t0,
              status: QcGoalStatus.completed,
              createdAt: t0,
              updatedAt: t1,
            ),
          ),
          throwsA(isA<AuthorizationError>()),
        );
        expect(
          (await r.goals.getGoal(goalId))!.status,
          isNot(QcGoalStatus.completed),
        );
        expect(
          await r.audit.list(action: QcAuditAction.goalCompleted),
          isEmpty,
        );
      },
    );
  });

  group('validation happens before the write', () {
    test('an SOP with no code is refused', () async {
      final r = repos(approver());

      await expectLater(
        r.sops.createSop(
          QcSop(
            code: '',
            title: 'No code',
            status: SopStatus.draft,
            createdAt: t0,
            updatedAt: t0,
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(await db.query('qc_sops'), isEmpty);
    });

    test('a publish with no change summary is refused', () async {
      final r = repos(approver());
      final id = await r.sops.createSop(sop());

      await expectLater(
        r.sops.publishSopRevision(id, changeSummary: '   '),
        throwsA(isA<ValidationError>()),
      );
      expect((await r.sops.listSopRevisions(id)), isEmpty);
    });

    test('a critical non-conformance with no description is refused', () async {
      final r = repos(approver());
      final (templateId, _) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );

      await expectLater(
        r.ncCapa.createFinding(
          finding(
            inspectionId: inspectionId,
            severity: NcSeverity.critical,
            description: '   ',
          ),
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(await db.query('qc_findings_nc'), isEmpty);
    });

    test('an item pointing outside the tree is refused', () async {
      final r = repos(approver());
      final (templateId, _) = await seedTemplate(r);
      final sectionId = await db.insert(
        'qc_sections',
        QcSection(templateId: templateId, title: 'S').toMap(withId: false),
      );

      await expectLater(
        r.templates.saveTemplateTree(
          template(),
          [QcSection(sectionId: sectionId, templateId: templateId, title: 'S')],
          [QcItem(sectionId: 9999, templateId: templateId, label: 'Orphan')],
        ),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('audit chain', () {
    test('a run of writes leaves one unbroken chain', () async {
      final r = repos(approver());

      final sopId = await r.sops.createSop(sop());
      await r.sops.publishSopRevision(sopId, changeSummary: 'first');
      final (templateId, _) = await seedTemplate(r);
      await r.templates.publishTemplate(templateId, publishedBy: 'u1');

      final verification = await r.audit.verifyChain();
      expect(verification.isValid, isTrue, reason: verification.reason ?? '');
      expect(verification.checked, greaterThanOrEqualTo(4));
    });

    test(
      'an SOP publish is recorded against both the SOP and the revision',
      () async {
        final r = repos(approver());
        final sopId = await r.sops.createSop(sop());

        final revId = await r.sops.publishSopRevision(
          sopId,
          changeSummary: 'first',
        );

        final sopAudit = (await r.audit.list(
          entityType: QcAuditEntity.sop,
        )).firstWhere((a) => a.action == QcAuditAction.sopPublished);
        expect(sopAudit.entityId, '$sopId');
        expect(sopAudit.meta['rev_id'], revId);
        expect(sopAudit.meta['changeSummary'], 'first');
      },
    );

    test('closing a non-conformance is a distinguished event', () async {
      final r = repos(approver());
      final (templateId, _) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );
      final findingId = await r.ncCapa.createFinding(
        finding(
          inspectionId: inspectionId,
          severity: NcSeverity.critical,
          description: 'Weld undercut',
        ),
      );

      await r.ncCapa.saveFinding(
        QcFindingNc(
          findingId: findingId,
          inspectionId: inspectionId,
          severity: NcSeverity.critical,
          description: 'Weld undercut',
          status: NcStatus.closed,
          closedAt: t1,
          closedBy: 'u1',
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final actions = (await r.audit.list(
        entityType: QcAuditEntity.finding,
      )).map((a) => a.action).toList();
      expect(actions, contains(QcAuditAction.findingCreated));
      expect(actions, contains(QcAuditAction.findingClosed));
    });

    test('closing a non-conformance needs the approve permission', () async {
      final r = repos(_TestGuard());
      final (templateId, _) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );
      final findingId = await r.ncCapa.createFinding(
        finding(inspectionId: inspectionId),
      );

      await expectLater(
        r.ncCapa.saveFinding(
          QcFindingNc(
            findingId: findingId,
            inspectionId: inspectionId,
            severity: NcSeverity.major,
            description: 'Surface scratch',
            status: NcStatus.closed,
            createdAt: t0,
            updatedAt: t1,
          ),
        ),
        throwsA(isA<AuthorizationError>()),
      );
      expect((await r.ncCapa.getFinding(findingId))!.status, NcStatus.open);
    });

    test('marking a goal action done is a distinguished event', () async {
      final r = repos(approver());
      final goalId = await r.goals.createGoal(goal());
      final actionId = await r.goals.addAction(
        QcGoalAction(
          goalId: goalId,
          actionText: 'Re-train the welder',
          createdAt: t0,
          updatedAt: t0,
        ),
      );

      await r.goals.saveAction(
        QcGoalAction(
          actionId: actionId,
          goalId: goalId,
          actionText: 'Re-train the welder',
          status: QcGoalActionStatus.done,
          doneAt: t1,
          doneBy: 'u1',
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final audit = (await r.audit.list(
        action: QcAuditAction.goalActionDone,
      )).single;
      expect(audit.entityId, '$actionId');
      expect(audit.before['status'], isNot(QcGoalActionStatus.done));
      expect(audit.after['status'], QcGoalActionStatus.done);
    });
  });

  group('the trail is still append-only through the facade', () {
    test('a tombstone is audited and stays on disk', () async {
      final r = repos(approver());
      final templateId = await r.templates.createTemplate(template());

      await r.templates.deleteTemplate(templateId);

      expect(await r.templates.getTemplate(templateId), isNull);
      final raw = await db.query(
        'qc_templates',
        where: 'template_id = ?',
        whereArgs: [templateId],
      );
      expect(raw.single['deleted_at'], isNotNull);
      final audit = (await r.audit.list(
        action: QcAuditAction.templateDeleted,
      )).single;
      expect(audit.before['deleted_at'], isNull);
      expect(audit.after['deleted_at'], isNotNull);
    });

    test('SQLite itself still refuses to rewrite an audit row', () async {
      final r = repos(approver());
      await r.sops.createSop(sop());

      await expectLater(
        db.update('qc_audits', {'action': 'REWRITTEN'}, where: 'id = 1'),
        throwsA(isA<DatabaseException>()),
      );
      expect((await r.audit.get(1))!.action, QcAuditAction.sopCreated);
    });

    test('a published checklist cannot be edited through the facade', () async {
      final r = repos(approver());
      final (templateId, _) = await seedTemplate(r);
      await r.templates.publishTemplate(templateId, publishedBy: 'u1');

      final tree = (await r.templates.getTemplateTree(templateId))!;

      await expectLater(
        r.templates.saveTemplateTree(tree.template, tree.sections, tree.items),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'duplicating a published checklist is audited as a new version',
      () async {
        final r = repos(approver());
        final (templateId, _) = await seedTemplate(r);
        await r.templates.publishTemplate(templateId, publishedBy: 'u1');

        final newId = await r.templates.duplicateTemplate(
          templateId,
          'TPL-1-v2',
          'Daily weld check v2',
        );

        final copy = await r.templates.getTemplate(newId);
        expect(copy!.isPublished, isFalse);
        final audit = (await r.audit.list(
          action: QcAuditAction.templateDuplicated,
        )).single;
        expect(audit.entityId, '$newId');
        expect(audit.meta['fromTemplateId'], templateId);
      },
    );
  });

  group('answers and their recompute', () {
    test('answering an item audits the answer and the new verdict', () async {
      final r = repos(approver());
      final (templateId, itemId) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );
      final responses = await r.inspections.listResponses(inspectionId);

      await r.inspections.answerResponse(
        QcResponse(
          respId: responses.firstWhere((x) => x.itemId == itemId).respId,
          inspectionId: inspectionId,
          itemId: itemId,
          result: QcResponseResult.fail,
          isCriticalFailure: true,
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final stored = await r.inspections.getInspection(inspectionId);
      expect(stored!.resultOverall, QcOverallResult.fail);
      final audit = (await r.audit.list(
        action: QcAuditAction.itemAnswered,
      )).single;
      expect(audit.meta['inspectionId'], inspectionId);
      expect(audit.after['result'], QcResponseResult.fail);
    });

    test('approving an inspection is a decision, not an edit', () async {
      final r = repos(approver());
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
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final actions = (await r.audit.list(
        entityType: QcAuditEntity.inspection,
      )).map((a) => a.action).toList();
      expect(actions, contains(QcAuditAction.inspectionApproved));
    });

    test('an approval cannot be smuggled in by a plain save', () async {
      // The privileged gate has to be a rule, not a convention the editing screen
      // happens to follow.
      final r = repos(_TestGuard());
      final (templateId, _) = await seedTemplate(r);
      final inspectionId = await r.inspections.createInspection(
        sheet(templateId),
      );

      await expectLater(
        r.inspections.saveInspection(
          QcInspection(
            inspectionId: inspectionId,
            templateId: templateId,
            inspectionDate: t0,
            status: QcInspectionStatus.approved,
            createdAt: t0,
            updatedAt: t1,
          ),
        ),
        throwsA(isA<AuthorizationError>()),
      );
      expect(
        (await r.inspections.getInspection(inspectionId))!.status,
        isNot(QcInspectionStatus.approved),
      );
    });
  });
}
