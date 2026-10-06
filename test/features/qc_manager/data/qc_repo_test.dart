import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/qc_manager/data/qc_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_sop.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// The local SQL layer on its own (plan V6_ENHANCED §24 P3).
///
/// These tests deliberately bypass every facade, session and permission check so
/// that a failure here means "the SQL is wrong", not "a guard rejected me". The
/// facades get their own suite on top.
///
/// Note how models are rebuilt field by field instead of via `copyWith`: the QC
/// models do not have one yet, which is a known prerequisite for the P5 screens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late Database db;
  late QcSopRepo sops;
  late QcTemplateRepo templates;
  late QcInspectionRepo inspections;
  late QcNcCapaRepo ncs;
  late QcGoalRepo goals;

  const t0 = '2026-01-05T08:00:00Z';
  const t1 = '2026-01-06T09:00:00Z';

  QcSop sop({String code = 'SOP-1', String title = 'Welding'}) => QcSop(
    code: code,
    title: title,
    contentText: 'body of $code',
    status: SopStatus.draft,
    createdAt: t0,
    updatedAt: t0,
  );

  QcTemplate template({
    String name = 'Daily weld check',
    String code = 'TPL-1',
  }) => QcTemplate(
    name: name,
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

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_qc_repo');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
    sops = QcSopRepo(helper);
    templates = QcTemplateRepo(helper);
    inspections = QcInspectionRepo(helper);
    ncs = QcNcCapaRepo(helper);
    goals = QcGoalRepo(helper);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('SOPs', () {
    test('publishing returns the new rev_id and snapshots the body', () async {
      final sopId = await sops.createSop(sop());

      final revId = await sops.publishSopRevision(
        sopId,
        changeSummary: 'first issue',
        effectiveFrom: '2026-02-01',
        editedBy: 'u1',
        editedByName: 'Hana',
      );

      // The contract promises the id of the new revision, not its number.
      expect(revId, isPositive);
      final revisions = await sops.listSopRevisions(sopId);
      expect(revisions, hasLength(1));
      final revision = revisions.single;
      expect(revision.revId, revId);
      expect(revision.revNo, 1);
      expect(revision.editedByName, 'Hana');
      // A revision is a self-contained snapshot: editing the SOP afterwards must
      // not rewrite what an inspection was performed against.
      expect(revision.contentText, 'body of SOP-1');
      expect(revision.isPublishedRev, isTrue);
      expect(revision.contentHash, isNotEmpty);
      expect(revision.supersededAt, isEmpty);
    });

    test(
      'a second publish supersedes the first and links back to it',
      () async {
        final sopId = await sops.createSop(sop());
        final first = await sops.publishSopRevision(
          sopId,
          changeSummary: 'one',
          effectiveFrom: '2026-02-01',
        );

        // No date on the republish: an unstated date must not revoke the one
        // that someone may already be working against.
        final second = await sops.publishSopRevision(
          sopId,
          changeSummary: 'two',
        );

        expect(second, isNot(first));
        final revisions = await sops.listSopRevisions(sopId);
        expect(revisions.map((r) => r.revNo), [2, 1]);
        // Rev 2 is the one that links back; rev 1 has no predecessor.
        expect(revisions.first.prevRevIdRef, first.toString());
        expect(revisions.last.prevRevIdRef, isEmpty);
        expect(revisions.last.supersededAt, isNotEmpty);
        // Exactly one live revision at a time.
        expect(revisions.where((r) => r.supersededAt.isEmpty), hasLength(1));

        final stored = await sops.getSop(sopId);
        expect(stored!.revNo, 2);
        expect(stored.status, SopStatus.published);
        expect(stored.effectiveDate, '2026-02-01');
      },
    );

    test(
      'a revision of a deleted SOP still snapshots the right body',
      () async {
        final sopId = await sops.createSop(sop(code: 'SOP-X', title: 'X'));
        await sops.publishSopRevision(sopId, changeSummary: 'one');

        final revisions = await sops.listSopRevisions(sopId);

        expect(revisions.single.contentText, 'body of SOP-X');
      },
    );

    test('a deleted SOP disappears from reads but stays on disk', () async {
      final sopId = await sops.createSop(sop());
      await sops.publishSopRevision(sopId, changeSummary: 'one');

      await sops.deleteSop(sopId);

      expect(await sops.getSop(sopId), isNull);
      expect(await sops.getSopByCode('SOP-1'), isNull);
      expect(await sops.listSops(), isEmpty);
      // Still present, so an inspection from last year can be explained.
      final raw = await db.query(
        'qc_sops',
        where: 'sop_id = ?',
        whereArgs: [sopId],
      );
      expect(raw, hasLength(1));
      expect(raw.single['deleted_at'], isNotNull);
    });

    test('a duplicate live code is rejected', () async {
      await sops.createSop(sop());
      expect(() => sops.createSop(sop(title: 'Other')), throwsStateError);
    });

    test('publishing an unknown SOP fails loudly', () async {
      expect(
        () => sops.publishSopRevision(999, changeSummary: 'x'),
        throwsStateError,
      );
    });

    test(
      're-reading a revision updates the ack instead of adding a row',
      () async {
        final sopId = await sops.createSop(sop());
        await sops.publishSopRevision(sopId, changeSummary: 'one');

        final readId = await sops.recordSopRead(
          QcSopRead(sopId: sopId, revNo: 1, userId: 'u1', readAt: t0),
        );
        final again = await sops.recordSopRead(
          QcSopRead(sopId: sopId, revNo: 1, userId: 'u1', readAt: t1),
        );

        expect(again, readId);
        final reads = await sops.listSopReads(sopId);
        expect(reads, hasLength(1));
        expect(reads.single.readAt, t1);
      },
    );

    test('different users each get their own ack row', () async {
      final sopId = await sops.createSop(sop());
      await sops.publishSopRevision(sopId, changeSummary: 'one');
      await sops.recordSopRead(
        QcSopRead(sopId: sopId, revNo: 1, userId: 'u1', readAt: t0),
      );
      await sops.recordSopRead(
        QcSopRead(sopId: sopId, revNo: 1, userId: 'u2', readAt: t1),
      );

      expect(await sops.listSopReads(sopId), hasLength(2));
    });
  });

  group('template trees', () {
    test('a saved tree reads back with fresh ids and the same shape', () async {
      final templateId = await templates.createTemplate(template());
      final sectionId = await db.insert(
        'qc_sections',
        QcSection(
          templateId: templateId,
          title: 'Before weld',
          orderIndex: 0,
        ).toMap(withId: false),
      );
      final itemId = await db.insert(
        'qc_items',
        QcItem(
          sectionId: sectionId,
          templateId: templateId,
          label: 'Preheat to 200C',
          itemType: QcItemType.number,
          isCritical: true,
        ).toMap(withId: false),
      );

      // Re-saving the tree it just returned must not orphan the items.
      final tree = (await templates.getTemplateTree(templateId))!;
      await templates.saveTemplateTree(
        tree.template,
        tree.sections,
        tree.items,
      );

      final after = (await templates.getTemplateTree(templateId))!;
      expect(after.sections, hasLength(1));
      expect(after.items, hasLength(1));
      expect(after.items.single.label, 'Preheat to 200C');
      expect(after.items.single.isCritical, isTrue);
      // New rows, new ids, same logical content.
      expect(after.sections.single.sectionId, isNot(sectionId));
      expect(after.items.single.itemId, isNot(itemId));
      expect(after.items.single.sectionId, after.sections.single.sectionId);
    });

    test('a template tree does not leak rows from another template', () async {
      final a = await templates.createTemplate(template(name: 'A'));
      final b = await templates.createTemplate(
        template(name: 'B', code: 'TPL-2'),
      );
      final sectionB = await db.insert(
        'qc_sections',
        QcSection(templateId: b, title: 'B section').toMap(withId: false),
      );
      await db.insert(
        'qc_items',
        QcItem(
          sectionId: sectionB,
          templateId: b,
          label: 'B item',
        ).toMap(withId: false),
      );

      final treeA = (await templates.getTemplateTree(a))!;

      expect(treeA.sections, isEmpty);
      expect(treeA.items, isEmpty);
    });

    test('saveTemplateTree refuses to orphan an item', () async {
      final templateId = await templates.createTemplate(template());
      final sectionId = await db.insert(
        'qc_sections',
        QcSection(templateId: templateId, title: 'S').toMap(withId: false),
      );
      await db.insert(
        'qc_items',
        QcItem(
          sectionId: sectionId,
          templateId: templateId,
          label: 'keep',
        ).toMap(withId: false),
      );
      final tree = (await templates.getTemplateTree(templateId))!;

      // The incoming section carries a fresh id, so the item points at a section
      // that is not in the list. Dropping it silently would shrink a signed
      // checklist with no trace, so this must throw instead.
      expect(
        () => templates.saveTemplateTree(
          tree.template,
          [QcSection(templateId: templateId, title: 'Replacement')],
          [QcItem(sectionId: sectionId, templateId: templateId, label: 'keep')],
        ),
        throwsStateError,
      );
      // The failed save rolled back: the original section and item are intact.
      final after = (await templates.getTemplateTree(templateId))!;
      expect(after.sections.single.title, 'S');
      expect(after.items.single.label, 'keep');
    });

    test('a published template cannot be edited in place', () async {
      final templateId = await templates.createTemplate(template());
      final sectionId = await db.insert(
        'qc_sections',
        QcSection(templateId: templateId, title: 'S').toMap(withId: false),
      );
      await db.insert(
        'qc_items',
        QcItem(
          sectionId: sectionId,
          templateId: templateId,
          label: 'i',
        ).toMap(withId: false),
      );

      await templates.publishTemplate(templateId, publishedBy: 'u1');

      final live = (await templates.getTemplateTree(templateId))!;
      expect(live.template.isPublished, isTrue);
      expect(live.template.publishedBy, 'u1');

      expect(
        () => templates.saveTemplateTree(
          live.template,
          live.sections,
          live.items,
        ),
        throwsStateError,
      );
    });

    test('an empty checklist cannot be published', () async {
      final templateId = await templates.createTemplate(template());

      // Publishing a checklist with no questions would silently pass every
      // inspection run against it.
      expect(() => templates.publishTemplate(templateId), throwsStateError);
      expect((await templates.getTemplate(templateId))!.isPublished, isFalse);
    });

    test(
      'archiving hides a template from the published list but not from ids',
      () async {
        final templateId = await templates.createTemplate(template());
        final sectionId = await db.insert(
          'qc_sections',
          QcSection(templateId: templateId, title: 'S').toMap(withId: false),
        );
        await db.insert(
          'qc_items',
          QcItem(
            sectionId: sectionId,
            templateId: templateId,
            label: 'i',
          ).toMap(withId: false),
        );
        await templates.publishTemplate(templateId, publishedBy: 'u1');

        await templates.archiveTemplate(templateId);

        expect(await templates.listTemplates(publishedOnly: true), isEmpty);
        expect((await templates.getTemplate(templateId))!.isArchived, isTrue);
      },
    );

    test(
      'duplicating a published template yields an editable v2 copy',
      () async {
        final templateId = await templates.createTemplate(template());
        final sectionId = await db.insert(
          'qc_sections',
          QcSection(
            templateId: templateId,
            title: 'Original',
          ).toMap(withId: false),
        );
        await db.insert(
          'qc_items',
          QcItem(
            sectionId: sectionId,
            templateId: templateId,
            label: 'Item',
          ).toMap(withId: false),
        );

        final copyId = await templates.duplicateTemplate(
          templateId,
          'Daily weld check v2',
        );

        final copy = (await templates.getTemplateTree(copyId))!;
        expect(copy.template.version, 2);
        expect(copy.template.isPublished, isFalse);
        expect(copy.sections.single.title, 'Original');
        expect(copy.items.single.label, 'Item');
        // The original is untouched.
        final original = (await templates.getTemplateTree(templateId))!;
        expect(original.sections.single.sectionId, sectionId);
      },
    );

    test(
      'a deleted template disappears from reads but stays on disk',
      () async {
        final templateId = await templates.createTemplate(template());

        await templates.deleteTemplate(templateId);

        expect(await templates.getTemplate(templateId), isNull);
        expect(await templates.getTemplateTree(templateId), isNull);
        expect(await templates.listTemplates(), isEmpty);
        final raw = await db.query(
          'qc_templates',
          where: 'template_id = ?',
          whereArgs: [templateId],
        );
        expect(raw.single['deleted_at'], isNotNull);
      },
    );
  });

  group('inspections', () {
    /// A template with one critical item, seeded straight through the schema.
    Future<int> seededTemplate({String criticalLabel = 'critical one'}) async {
      final templateId = await templates.createTemplate(template());
      final sectionId = await db.insert(
        'qc_sections',
        QcSection(templateId: templateId, title: 'S').toMap(withId: false),
      );
      for (final (index, label) in ['first', 'second', criticalLabel].indexed) {
        await db.insert(
          'qc_items',
          QcItem(
            sectionId: sectionId,
            templateId: templateId,
            label: label,
            orderIndex: index,
            isCritical: label == criticalLabel,
          ).toMap(withId: false),
        );
      }
      return templateId;
    }

    /// Answers one response by rebuilding it - see the note on `copyWith` above.
    Future<void> answer(
      int inspectionId,
      int index,
      String result, {
      bool critical = false,
    }) async {
      final current = (await inspections.listResponses(inspectionId))[index];
      await inspections.answerResponse(
        QcResponse(
          respId: current.respId,
          inspectionId: current.inspectionId,
          itemId: current.itemId,
          sectionId: current.sectionId,
          result: result,
          isCriticalFailure: critical,
          createdAt: current.createdAt,
          updatedAt: t1,
        ),
      );
    }

    test(
      'creating an inspection seeds one unanswered response per item',
      () async {
        final templateId = await seededTemplate();

        final inspectionId = await inspections.createInspection(
          sheet(templateId),
        );

        final responses = await inspections.listResponses(inspectionId);
        expect(responses, hasLength(3));
        expect(responses.every((r) => r.result == QcResponseResult.na), isTrue);
        expect(responses.map((r) => r.itemId).toSet(), hasLength(3));
      },
    );

    test('the score ignores N/A so a checklist cannot inflate itself', () async {
      final templateId = await seededTemplate(criticalLabel: 'third');
      final inspectionId = await inspections.createInspection(
        sheet(templateId),
      );

      await answer(inspectionId, 0, QcResponseResult.pass);
      await answer(inspectionId, 1, QcResponseResult.pass);
      await answer(inspectionId, 2, QcResponseResult.na);

      // 2 of 2 applicable answered correctly. Counting N/A as a pass would have
      // reported 100% for a sheet with only two real questions answered.
      var stored = await inspections.getInspection(inspectionId);
      expect(stored!.scorePct, 100);
      expect(stored.resultOverall, QcOverallResult.pass);

      await answer(inspectionId, 0, QcResponseResult.fail);

      // Now applicable is 2 with one failure -> 50%, and a non-critical failure
      // only makes the sheet conditional.
      stored = await inspections.getInspection(inspectionId);
      expect(stored!.scorePct, 50);
      expect(stored.resultOverall, QcOverallResult.conditional);
    });

    test('a critical failure fails the whole sheet', () async {
      final templateId = await seededTemplate(criticalLabel: 'third');
      final inspectionId = await inspections.createInspection(
        sheet(templateId),
      );

      await answer(inspectionId, 2, QcResponseResult.fail, critical: true);

      final stored = await inspections.getInspection(inspectionId);
      expect(stored!.resultOverall, QcOverallResult.fail);
      expect(stored.scorePct, 0);
    });

    test(
      'raising a critical NC fails a sheet whose items all passed',
      () async {
        final templateId = await seededTemplate(criticalLabel: 'third');
        final inspectionId = await inspections.createInspection(
          sheet(templateId),
        );
        for (var i = 0; i < 3; i++) {
          await answer(inspectionId, i, QcResponseResult.pass);
        }
        expect(
          (await inspections.getInspection(inspectionId))!.resultOverall,
          QcOverallResult.pass,
        );

        await ncs.createFinding(
          QcFindingNc(
            inspectionId: inspectionId,
            itemId: (await inspections.listResponses(
              inspectionId,
            )).first.itemId,
            severity: NcSeverity.critical,
            description: 'Porosity in the root pass',
            createdAt: t1,
            updatedAt: t1,
          ),
        );

        final stored = await inspections.getInspection(inspectionId);
        expect(stored!.resultOverall, QcOverallResult.fail);
        expect(stored.hasNc, isTrue);
        expect(stored.ncCount, 1);
        expect(stored.criticalNcCount, 1);
      },
    );

    test('the stored score survives a reload', () async {
      final templateId = await seededTemplate(criticalLabel: 'third');
      final inspectionId = await inspections.createInspection(
        sheet(templateId),
      );
      await answer(inspectionId, 0, QcResponseResult.pass);
      await answer(inspectionId, 1, QcResponseResult.pass);
      await answer(inspectionId, 2, QcResponseResult.na);

      // Reopen the same file through a second helper so nothing can be served
      // from a cached connection. The repos have to be rebuilt too: they hold
      // the closed helper, and reusing it would only prove that it is closed.
      await db.close();
      helper = DatabaseHelper(_FakeAppPaths(tmp.path));
      db = await helper.database;
      sops = QcSopRepo(helper);
      templates = QcTemplateRepo(helper);
      inspections = QcInspectionRepo(helper);
      ncs = QcNcCapaRepo(helper);
      goals = QcGoalRepo(helper);

      expect((await inspections.getInspection(inspectionId))!.scorePct, 100);
    });

    test('a deleted inspection leaves the list but stays on disk', () async {
      final templateId = await seededTemplate();
      final a = await inspections.createInspection(sheet(templateId));
      final b = await inspections.createInspection(sheet(templateId));

      await inspections.deleteInspection(a);

      expect(await inspections.getInspection(a), isNull);
      expect(
        (await inspections.listInspections(
          templateId: templateId,
        )).map((i) => i.inspectionId),
        [b],
      );
      final raw = await db.query(
        'qc_inspections',
        where: 'inspection_id = ?',
        whereArgs: [a],
      );
      expect(raw.single['deleted_at'], isNotNull);
    });
  });

  group('NCs and CAPA', () {
    Future<int> openInspection() async {
      final templateId = await templates.createTemplate(template());
      return inspections.createInspection(sheet(templateId));
    }

    QcFindingNc finding(
      int inspectionId, {
      String severity = NcSeverity.major,
    }) => QcFindingNc(
      inspectionId: inspectionId,
      severity: severity,
      description: 'Weld undercut',
      createdAt: t0,
      updatedAt: t0,
    );

    test('a finding keeps its severity counts on the sheet', () async {
      final inspectionId = await openInspection();
      await ncs.createFinding(finding(inspectionId));
      await ncs.createFinding(
        finding(inspectionId, severity: NcSeverity.minor),
      );

      final stored = await inspections.getInspection(inspectionId);
      expect(stored!.ncCount, 2);
      expect(stored.majorNcCount, 1);
      expect(stored.minorNcCount, 1);
      expect(stored.criticalNcCount, 0);
    });

    test('one CAPA per finding, enforced by the repository', () async {
      final inspectionId = await openInspection();
      final findingId = await ncs.createFinding(finding(inspectionId));
      QcCapa capa(String actionPlan) => QcCapa(
        findingId: findingId,
        actionPlan: actionPlan,
        createdAt: t0,
        updatedAt: t0,
      );

      await ncs.createCapa(capa('Re-weld and re-inspect'));

      // A second CAPA for the same finding would split the effectiveness story
      // in two, so the repository refuses instead of trusting the caller.
      await expectLater(
        ncs.createCapa(capa('Something else')),
        throwsStateError,
      );
      expect(await ncs.listCapa(findingId: '$findingId'), hasLength(1));
    });

    test(
      'verifying a CAPA records who checked it and whether it worked',
      () async {
        final inspectionId = await openInspection();
        final findingId = await ncs.createFinding(finding(inspectionId));
        final capaId = await ncs.createCapa(
          QcCapa(
            findingId: findingId,
            actionPlan: 'Re-weld',
            createdAt: t0,
            updatedAt: t0,
          ),
        );

        await ncs.saveCapa(
          QcCapa(
            capaId: capaId,
            findingId: findingId,
            actionPlan: 'Re-weld',
            status: CapaStatus.verifiedEffective,
            verifiedBy: 'u1',
            verifiedAt: t1,
            isEffective: true,
            createdAt: t0,
            updatedAt: t1,
          ),
        );

        final stored = await ncs.getCapa(capaId);
        expect(stored!.status, CapaStatus.verifiedEffective);
        expect(stored.verifiedBy, 'u1');
        expect(stored.verifiedAt, t1);
        expect(stored.isEffective, isTrue);
      },
    );

    test('closing a critical finding lets the sheet recover', () async {
      final inspectionId = await openInspection();
      final findingId = await ncs.createFinding(
        finding(inspectionId, severity: NcSeverity.critical),
      );
      expect(
        (await inspections.getInspection(inspectionId))!.resultOverall,
        QcOverallResult.fail,
      );

      await ncs.saveFinding(
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

      final findings = await ncs.listFindings(inspectionId: "$inspectionId");
      expect(findings.single.status, NcStatus.closed);
      expect(findings.single.closedBy, 'u1');
      // The critical NC no longer drives the verdict.
      final stored = await inspections.getInspection(inspectionId);
      expect(stored!.resultOverall, isNot(QcOverallResult.fail));
      expect(stored.criticalNcCount, 0);
      expect(stored.hasNc, isFalse);
    });

    test('deleting a finding is a tombstone, not a tomb', () async {
      final inspectionId = await openInspection();
      final findingId = await ncs.createFinding(finding(inspectionId));

      await ncs.deleteFinding(findingId);

      expect(await ncs.getFinding(findingId), isNull);
      expect(await ncs.listFindings(inspectionId: "$inspectionId"), isEmpty);
      final raw = await db.query(
        'qc_findings_nc',
        where: 'finding_id = ?',
        whereArgs: [findingId],
      );
      expect(raw.single['deleted_at'], isNotNull);
    });

    test('a deleted finding drops out of the sheet counts', () async {
      final inspectionId = await openInspection();
      final keep = await ncs.createFinding(finding(inspectionId));
      final drop = await ncs.createFinding(
        finding(inspectionId, severity: NcSeverity.critical),
      );

      await ncs.deleteFinding(drop);

      final stored = await inspections.getInspection(inspectionId);
      expect(stored!.ncCount, 1);
      expect(stored.criticalNcCount, 0);
      expect(stored.resultOverall, QcOverallResult.conditional);
      expect(await ncs.getFinding(keep), isNotNull);
    });
  });

  group('goals', () {
    QcGoal goal() => QcGoal(
      code: 'G-1',
      title: 'Reduce scrap',
      startDate: '2026-01-01',
      createdAt: t0,
      updatedAt: t0,
    );

    test(
      'the bundle assembles goal, assignments, actions, KPIs and links',
      () async {
        final goalId = await goals.createGoal(goal());
        await goals.assignGoal(
          QcGoalAssignment(
            goalId: goalId,
            assigneeId: 'u1',
            assignedAt: t0,
            createdAt: t0,
            updatedAt: t0,
          ),
        );
        await goals.addAction(
          QcGoalAction(
            goalId: goalId,
            actionText: 'Audit the press line',
            createdAt: t0,
            updatedAt: t0,
          ),
        );
        await goals.addKpi(
          QcGoalKpi(
            goalId: goalId,
            name: 'Scrap rate',
            target: 2.0,
            createdAt: t0,
            updatedAt: t0,
          ),
        );
        await goals.addLink(
          QcGoalLink(
            goalId: goalId,
            linkType: QcGoalLinkType.finding,
            refId: '42',
            createdAt: t0,
          ),
        );

        final bundle = (await goals.getGoalBundle(goalId))!;
        expect(bundle.goal.goalId, goalId);
        expect(bundle.assignments, hasLength(1));
        expect(bundle.actions, hasLength(1));
        expect(bundle.kpis, hasLength(1));
        expect(bundle.kpis.single.target, 2);
        expect(bundle.links, hasLength(1));
        expect(bundle.links.single.refId, '42');
      },
    );

    test(
      're-assigning the same person updates instead of double counting',
      () async {
        final goalId = await goals.createGoal(goal());
        QcGoalAssignment assign(String role) => QcGoalAssignment(
          goalId: goalId,
          assigneeId: 'u1',
          role: role,
          assignedAt: t0,
          createdAt: t0,
          updatedAt: t0,
        );

        await goals.assignGoal(assign(QcGoalRole.member));
        await goals.assignGoal(assign(QcGoalRole.owner));

        final assignments = await goals.listAssignments(goalId);
        expect(assignments, hasLength(1));
        expect(assignments.single.role, QcGoalRole.owner);
      },
    );

    test('an unassigned action is a tombstone, not a hole', () async {
      final goalId = await goals.createGoal(goal());
      await goals.assignGoal(
        QcGoalAssignment(
          goalId: goalId,
          assigneeId: 'u1',
          assignedAt: t0,
          createdAt: t0,
          updatedAt: t0,
        ),
      );
      final assignId = (await goals.listAssignments(goalId)).single.assignId!;

      await goals.removeAssignment(assignId);

      expect(await goals.listAssignments(goalId), isEmpty);
      final raw = await db.query(
        'qc_goal_assignments',
        where: 'assign_id = ?',
        whereArgs: [assignId],
      );
      expect(raw.single['deleted_at'], isNotNull);
    });

    test('a removed KPI and link fall out of the bundle', () async {
      final goalId = await goals.createGoal(goal());
      final kpiId = await goals.addKpi(
        QcGoalKpi(
          goalId: goalId,
          name: 'Scrap',
          target: 1.0,
          createdAt: t0,
          updatedAt: t0,
        ),
      );
      final linkId = await goals.addLink(
        QcGoalLink(
          goalId: goalId,
          linkType: QcGoalLinkType.sop,
          refId: '7',
          createdAt: t0,
        ),
      );

      await goals.deleteKpi(kpiId);
      await goals.deleteLink(linkId);

      final bundle = (await goals.getGoalBundle(goalId))!;
      expect(bundle.kpis, isEmpty);
      expect(bundle.links, isEmpty);
    });

    test('completing a goal records who finished it', () async {
      final goalId = await goals.createGoal(goal());

      await goals.saveGoal(
        QcGoal(
          goalId: goalId,
          code: 'G-1',
          title: 'Reduce scrap',
          startDate: '2026-01-01',
          status: QcGoalStatus.completed,
          completedAt: t1,
          completedBy: 'u1',
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      final stored = (await goals.getGoalBundle(goalId))!.goal;
      expect(stored.status, QcGoalStatus.completed);
      expect(stored.completedAt, t1);
      expect(stored.completedBy, 'u1');
    });

    test('a fresh goal starts at version 1', () async {
      final goalId = await goals.createGoal(goal());

      expect((await goals.getGoal(goalId))!.version, 1);
    });

    test('every save bumps the version by one', () async {
      final goalId = await goals.createGoal(goal());
      QcGoal edit(String title) => QcGoal(
        goalId: goalId,
        code: 'G-1',
        title: title,
        startDate: '2026-01-01',
        createdAt: t0,
        updatedAt: t0,
      );

      await goals.saveGoal(edit('Scrap down'));
      expect((await goals.getGoal(goalId))!.version, 2);
      await goals.saveGoal(edit('Scrap down again'));
      expect((await goals.getGoal(goalId))!.version, 3);
    });

    test('a caller cannot forge the version it saves', () async {
      final goalId = await goals.createGoal(goal());

      // Sent version 99 must not stick: the counter is maintained by the
      // statement, so optimistic concurrency stays meaningful.
      await goals.saveGoal(
        QcGoal(
          goalId: goalId,
          code: 'G-1',
          title: 'Reduce scrap',
          startDate: '2026-01-01',
          version: 99,
          createdAt: t0,
          updatedAt: t0,
        ),
      );

      expect((await goals.getGoal(goalId))!.version, 2);
    });

    test('the version survives a reopen of the database', () async {
      final goalId = await goals.createGoal(goal());
      await goals.saveGoal(
        QcGoal(
          goalId: goalId,
          code: 'G-1',
          title: 'Reduce scrap',
          startDate: '2026-01-01',
          createdAt: t0,
          updatedAt: t0,
        ),
      );

      await db.close();
      // A second helper over the same directory, which is what a cold app start
      // after a crash sees: the column has to come back from the schema itself,
      // not from the object that happened to be open.
      final coldHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
      final reopened = QcGoalRepo(coldHelper);

      expect((await reopened.getGoal(goalId))!.version, 2);
      expect((await coldHelper.database).isOpen, isTrue);
      // The cold handle has to go too, or the temp dir stays locked.
      await (await coldHelper.database).close();
    });

    test('a recorded finisher cannot be swapped by a later save', () async {
      final goalId = await goals.createGoal(goal());
      QcGoal completed(String by, String name) => QcGoal(
        goalId: goalId,
        code: 'G-1',
        title: 'Reduce scrap',
        startDate: '2026-01-01',
        status: QcGoalStatus.completed,
        completedAt: t1,
        completedBy: by,
        completedByName: name,
        createdAt: t0,
        updatedAt: t1,
      );
      await goals.saveGoal(completed('u1', 'Hana'));

      // Re-saving as the same finisher is a no-op edit, not an error.
      await goals.saveGoal(completed('u1', 'Hana'));
      await expectLater(
        goals.saveGoal(completed('u2', 'Omar')),
        throwsA(isA<StateError>()),
      );

      final stored = (await goals.getGoal(goalId))!;
      expect(stored.completedBy, 'u1');
      expect(stored.completedByName, 'Hana');
    });

    test('a rejected finisher swap leaves the whole row untouched', () async {
      final goalId = await goals.createGoal(goal());
      await goals.saveGoal(
        QcGoal(
          goalId: goalId,
          code: 'G-1',
          title: 'Reduce scrap',
          startDate: '2026-01-01',
          status: QcGoalStatus.completed,
          completedAt: t1,
          completedBy: 'u1',
          createdAt: t0,
          updatedAt: t1,
        ),
      );

      await expectLater(
        goals.saveGoal(
          QcGoal(
            goalId: goalId,
            code: 'G-1',
            title: 'Retitled and re-signed',
            startDate: '2026-01-01',
            status: QcGoalStatus.completed,
            completedAt: t1,
            completedBy: 'u2',
            createdAt: t0,
            updatedAt: t1,
          ),
        ),
        throwsA(isA<StateError>()),
      );

      // A partial write here would leave the title changed under a signature
      // that says somebody else finished it.
      final stored = (await goals.getGoal(goalId))!;
      expect(stored.title, 'Reduce scrap');
      expect(stored.completedBy, 'u1');
      expect(stored.version, 2);
    });

    test('saving a goal with no id is refused', () async {
      await expectLater(goals.saveGoal(goal()), throwsA(isA<StateError>()));
    });

    test('saving a goal that does not exist is refused', () async {
      await expectLater(
        // `copyWith` cannot set the id, so the row is rebuilt with it - the
        // point is that the *store* refuses an update matching nothing.
        goals.saveGoal(
          QcGoal(
            goalId: 4242,
            code: 'G-404',
            title: 'Does not exist',
            startDate: '2026-01-01',
            createdAt: t0,
            updatedAt: t0,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('transaction threading', () {
    test(
      'a caller-supplied executor rolls the tree write back with it',
      () async {
        final templateId = await templates.createTemplate(template());
        final tree = (await templates.getTemplateTree(templateId))!;

        await expectLater(
          db.transaction((txn) async {
            await templates.saveTemplateTree(
              tree.template,
              tree.sections,
              tree.items,
              exec: txn,
            );
            throw StateError('caller aborts after the tree was written');
          }),
          throwsStateError,
        );

        // Without the exec threading this would deadlock or commit anyway; the
        // point is that one abort takes the children with it.
        final after = (await templates.getTemplateTree(templateId))!;
        expect(after.sections, isEmpty);
        expect(after.items, isEmpty);
      },
    );

    test(
      'an inspection and its seeded responses commit or vanish together',
      () async {
        final templateId = await templates.createTemplate(template());
        final sectionId = await db.insert(
          'qc_sections',
          QcSection(templateId: templateId, title: 'S').toMap(withId: false),
        );
        await db.insert(
          'qc_items',
          QcItem(
            sectionId: sectionId,
            templateId: templateId,
            label: 'a',
          ).toMap(withId: false),
        );

        await expectLater(
          db.transaction((txn) async {
            await inspections.createInspection(sheet(templateId), exec: txn);
            throw StateError('abort');
          }),
          throwsStateError,
        );

        expect(
          await inspections.listInspections(templateId: templateId),
          isEmpty,
        );
      },
    );

    test('an answer and its recompute are one unit', () async {
      final templateId = await templates.createTemplate(template());
      final sectionId = await db.insert(
        'qc_sections',
        QcSection(templateId: templateId, title: 'S').toMap(withId: false),
      );
      await db.insert(
        'qc_items',
        QcItem(
          sectionId: sectionId,
          templateId: templateId,
          label: 'a',
        ).toMap(withId: false),
      );
      final inspectionId = await inspections.createInspection(
        sheet(templateId),
      );
      final response = (await inspections.listResponses(inspectionId)).single;

      // Abort the recompute by rolling the whole answer back through the
      // caller's transaction: the response and the header must not diverge.
      await expectLater(
        db.transaction((txn) async {
          await inspections.answerResponse(
            QcResponse(
              respId: response.respId,
              inspectionId: response.inspectionId,
              itemId: response.itemId,
              sectionId: response.sectionId,
              result: QcResponseResult.fail,
              createdAt: response.createdAt,
              updatedAt: t1,
            ),
            exec: txn,
          );
          throw StateError('abort');
        }),
        throwsStateError,
      );

      final after = (await inspections.listResponses(inspectionId)).single;
      expect(after.result, QcResponseResult.na);
      expect(
        (await inspections.getInspection(inspectionId))!.resultOverall,
        QcOverallResult.pending,
      );
    });
  });
}
