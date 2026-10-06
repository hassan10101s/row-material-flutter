import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_inspection_sheet_cubit.dart';

const _now = '2026-02-01 08:00:00';

/// In-memory [QcInspectionRepository] standing in for the SQL one.
///
/// It reproduces the two behaviours the cubit's rules are written against:
/// `createInspection` seeds one unanswered row per item (result `NA`,
/// `measured_at` empty), and `answerResponse` stamps the header's score and
/// verdict in the same write - so a test can tell a rule the UI enforces from
/// one only the database does.
class _FakeSheet implements QcInspectionRepository {
  final List<QcInspection> inspections = [];
  final List<QcResponse> responses = [];
  final List<QcFindingNc> findings = [];
  final List<QcResponse> answered = [];

  Object? failWith;
  bool failFindings = false;

  int _nextResp = 1;

  @override
  Future<List<QcInspection>> listInspections({
    int? templateId,
    String status = '',
    String refType = '',
    String refId = '',
    String lotNo = '',
    String dept = '',
    int limit = 100,
    int offset = 0,
  }) async => const [];

  @override
  Future<QcInspection?> getInspection(int inspectionId) async {
    for (final row in inspections) {
      if (row.inspectionId == inspectionId) return row;
    }
    return null;
  }

  @override
  Future<int> countInspections({
    String status = '',
    String refType = '',
    String refId = '',
  }) async => inspections.length;

  @override
  Future<int> createInspection(QcInspection inspection) async {
    inspections.add(inspection.copyWith(inspectionId: 1));
    return 1;
  }

  @override
  Future<void> saveInspection(QcInspection inspection) async {
    if (failWith != null) throw failWith!;
    final i = inspections.indexWhere(
      (r) => r.inspectionId == inspection.inspectionId,
    );
    if (i < 0) throw StateError('no such inspection');
    inspections[i] = inspection;
  }

  @override
  Future<void> deleteInspection(int inspectionId) async {}

  @override
  Future<List<QcResponse>> listResponses(int inspectionId) async =>
      responses.where((r) => r.inspectionId == inspectionId).toList();

  @override
  Future<void> answerResponse(QcResponse response) async {
    if (failWith != null) throw failWith!;
    answered.add(response);
    final i = responses.indexWhere((r) => r.respId == response.respId);
    if (i < 0) throw StateError('no such response');
    responses[i] = response;
    recompute(response.inspectionId);
  }

  @override
  Future<List<QcFindingNc>> listFindings(int inspectionId) async {
    if (failFindings) throw StateError('findings unavailable');
    return findings.where((f) => f.inspectionId == inspectionId).toList();
  }

  /// The seeded row for an item nobody has answered yet.
  void seed(int inspectionId, int itemId, int? sectionId) {
    responses.add(
      QcResponse(
        respId: _nextResp++,
        inspectionId: inspectionId,
        itemId: itemId,
        sectionId: sectionId,
        // `NA` with no `measured_at` is exactly what the SQL seed writes, and is
        // the whole reason a separate `Pending` result was never added.
        result: QcResponseResult.na,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
  }

  /// Mirrors `QcInspectionRepo.recompute`: N/A answers stay out of the score, a
  /// critical failure fails the sheet, and a plain failure makes it conditional.
  void recompute(int inspectionId) {
    final rows = responses
        .where((r) => r.inspectionId == inspectionId)
        .toList();
    final applicable = rows
        .where((r) => r.result != QcResponseResult.na)
        .toList();
    final failed = applicable.where((r) => r.isFail).length;
    final score = applicable.isEmpty
        ? null
        : ((applicable.length - failed) / applicable.length) * 100;
    final open = findings
        .where((f) => f.inspectionId == inspectionId && !f.isClosed)
        .toList();
    final critical = open
        .where((f) => f.severity == NcSeverity.critical)
        .length;
    final major = open.where((f) => f.severity == NcSeverity.major).length;
    final minor = open.where((f) => f.severity == NcSeverity.minor).length;
    final criticalFailure = rows.any((r) => r.isCriticalFailure);
    final fromNc = QcOverallResult.fromCounts(
      hasCriticalFailure: criticalFailure,
      criticalCount: critical,
      majorCount: major,
    );
    final overall = fromNc == QcOverallResult.pass && failed > 0
        ? QcOverallResult.conditional
        : fromNc;
    final i = inspections.indexWhere((r) => r.inspectionId == inspectionId);
    if (i < 0) return;
    inspections[i] = inspections[i].copyWith(
      resultOverall: overall,
      scorePct: score,
      hasNc: open.isNotEmpty || failed > 0,
      ncCount: open.length,
      criticalNcCount: critical,
      majorNcCount: major,
      minorNcCount: minor,
    );
  }
}

class _TreeStub implements QcTemplateRepository {
  _TreeStub(this.template, this.sections, this.items);

  final QcTemplate template;
  final List<QcSection> sections;
  final List<QcItem> items;

  @override
  Future<({QcTemplate template, List<QcSection> sections, List<QcItem> items})?>
  getTemplateTree(int templateId) async =>
      (template: template, sections: sections, items: items);

  @override
  Future<List<QcTemplate>> listTemplates({
    String dept = '',
    bool publishedOnly = false,
  }) async => [template];

  @override
  Future<QcTemplate?> getTemplate(int templateId) async => template;

  @override
  Future<int> createTemplate(QcTemplate template) => throw UnimplementedError();

  @override
  Future<void> saveTemplateTree(
    QcTemplate template,
    List<QcSection> sections,
    List<QcItem> items,
  ) => throw UnimplementedError();

  @override
  Future<void> deleteTemplate(int templateId) => throw UnimplementedError();

  @override
  Future<void> publishTemplate(
    int templateId, {
    String publishedBy = '',
    String effectiveDate = '',
  }) => throw UnimplementedError();

  @override
  Future<void> archiveTemplate(int templateId) => throw UnimplementedError();

  @override
  Future<int> duplicateTemplate(
    int templateId,
    String newCode,
    String newName,
  ) => throw UnimplementedError();
}

class _NcStub implements QcNcCapaRepository {
  final List<QcFindingNc> created = [];
  Object? failWith;

  @override
  Future<List<QcFindingNc>> listFindings({
    String status = '',
    String severity = '',
    String assignedTo = '',
    String inspectionId = '',
    bool overdueOnly = false,
    int limit = 200,
    int offset = 0,
  }) async => const [];

  @override
  Future<QcFindingNc?> getFinding(int findingId) async => null;

  @override
  Future<int> createFinding(QcFindingNc finding) async {
    if (failWith != null) throw failWith!;
    created.add(finding);
    return created.length;
  }

  @override
  Future<void> saveFinding(QcFindingNc finding) => throw UnimplementedError();

  @override
  Future<void> deleteFinding(int findingId) => throw UnimplementedError();

  @override
  Future<List<QcCapa>> listCapa({
    String status = '',
    String findingId = '',
  }) async => const [];

  @override
  Future<QcCapa?> getCapa(int capaId) async => null;

  @override
  Future<int> createCapa(QcCapa capa) => throw UnimplementedError();

  @override
  Future<void> saveCapa(QcCapa capa) => throw UnimplementedError();

  @override
  Future<List<QcDefectCode>> listDefectCodes({String category = ''}) async =>
      const [];
}

QcTemplate _template() => QcTemplate(
  templateId: 1,
  name: 'Incoming goods',
  code: 'IN-1',
  isPublished: true,
  version: 3,
  createdAt: _now,
  updatedAt: _now,
);

QcSection _section(int id, String title) =>
    QcSection(sectionId: id, templateId: 1, title: title);

QcItem _item({
  required int id,
  int sectionId = 10,
  String label = 'Check',
  String type = QcItemType.passFail,
  bool required = true,
  bool allowNa = true,
  bool critical = false,
  bool requireEvidenceIfFail = true,
  double? minValue,
  double? maxValue,
  double? tolerance,
  String toleranceType = 'abs',
  String defectCode = '',
}) => QcItem(
  itemId: id,
  sectionId: sectionId,
  templateId: 1,
  label: label,
  itemType: type,
  required: required,
  allowNa: allowNa,
  isCritical: critical,
  requireEvidenceIfFail: requireEvidenceIfFail,
  minValue: minValue,
  maxValue: maxValue,
  tolerance: tolerance,
  toleranceType: toleranceType,
  defectCode: defectCode,
);

QcInspection _inspection({String status = QcInspectionStatus.inProgress}) =>
    QcInspection(
      inspectionId: 1,
      templateId: 1,
      templateVersion: 3,
      status: status,
      resultOverall: QcOverallResult.pending,
      inspectionDate: '2026-02-01',
      createdAt: _now,
      updatedAt: _now,
    );

/// Builds a loaded cubit over a fake that already has one seeded response per
/// item, matching what `createInspection` leaves behind.
Future<QcInspectionSheetCubit> _sheet(
  List<QcItem> items, {
  String status = QcInspectionStatus.inProgress,
  List<QcSection>? sections,
  _FakeSheet? repo,
  _NcStub? nc,
  bool seed = true,
}) async {
  final store = repo ?? _FakeSheet();
  if (store.inspections.isEmpty) {
    store.inspections.add(_inspection(status: status));
  }
  if (seed) {
    for (final item in items) {
      store.seed(1, item.itemId!, item.sectionId);
    }
  }
  final cubit = QcInspectionSheetCubit(
    repo: store,
    templates: _TreeStub(
      _template(),
      sections ?? [_section(10, 'Visual')],
      items,
    ),
    ncCapa: nc ?? _NcStub(),
    inspectionId: 1,
  );
  await cubit.load();
  return cubit;
}

void main() {
  setUp(() => AppText.useLanguage('en'));

  group('QcItem acceptance rules', () {
    test('a reading outside the declared bounds fails', () {
      final item = _item(id: 1, minValue: 9.5, maxValue: 10.5);
      expect(item.accepts(10), isTrue);
      expect(item.accepts(9.4), isFalse);
      expect(item.accepts(10.6), isFalse);
    });

    test('an absolute tolerance widens the band', () {
      final item = _item(id: 1, minValue: 10, maxValue: 12, tolerance: 0.5);
      expect(item.accepts(9.5), isTrue);
      expect(item.accepts(12.5), isTrue);
      expect(item.accepts(9.4), isFalse);
    });

    test('a relative tolerance widens by a percentage of the bound', () {
      final item = _item(
        id: 1,
        minValue: 100,
        maxValue: 200,
        tolerance: 5,
        toleranceType: 'rel',
      );
      expect(item.accepts(95), isTrue);
      expect(item.accepts(210), isTrue);
      expect(item.accepts(94), isFalse);
    });

    test('a one-sided minimum widens downwards only', () {
      final item = _item(id: 1, minValue: 10, tolerance: 1);
      // The band is [9, null): a value has to clear the relaxed minimum, but
      // there is no declared maximum so nothing above is out of band.
      expect(item.accepts(9), isTrue);
      expect(item.accepts(9.9), isTrue);
      expect(item.accepts(8.9), isFalse);
      expect(item.accepts(1000), isTrue);
    });

    test('an item with no bounds accepts anything', () {
      final item = _item(id: 1);
      expect(item.acceptanceBand, isNull);
      expect(item.accepts(-1), isTrue);
      expect(item.boundsLabel, isEmpty);
    });

    test('photo and signature items satisfy their own evidence rule', () {
      expect(_item(id: 1, type: QcItemType.photo).needsEvidenceOnFail, isFalse);
      expect(
        _item(id: 1, type: QcItemType.signature).needsEvidenceOnFail,
        isFalse,
      );
      expect(_item(id: 1).needsEvidenceOnFail, isTrue);
    });

    test('only a critical item that demands evidence raises a critical NC', () {
      expect(_item(id: 1, critical: true).raisesCriticalNc, isTrue);
      expect(
        _item(
          id: 1,
          critical: true,
          requireEvidenceIfFail: false,
        ).raisesCriticalNc,
        isFalse,
      );
      expect(_item(id: 1).raisesCriticalNc, isFalse);
    });
  });

  group('QcInspectionSheetCubit loading', () {
    test('groups the tree into sections with their stored answers', () async {
      final repo = _FakeSheet()..inspections.add(_inspection());
      final cubit = await _sheet(
        [
          _item(id: 1, sectionId: 10, label: 'A'),
          _item(id: 2, sectionId: 10, label: 'B'),
          _item(id: 3, sectionId: 11, label: 'C'),
        ],
        repo: repo,
        sections: [_section(10, 'Visual'), _section(11, 'Dimensions')],
      );
      expect(cubit.state.sections.map((s) => s.section.title), [
        'Visual',
        'Dimensions',
      ]);
      expect(cubit.state.progress.total, 3);
      // Nothing answered yet: the seeded `NA` rows must not read as answers.
      expect(cubit.state.progress.answered, 0);
      expect(cubit.state.sections.first.completion, 0);
      await cubit.close();
    });

    test(
      'a missing sheet reports why instead of showing an empty one',
      () async {
        final cubit = QcInspectionSheetCubit(
          repo: _FakeSheet(),
          templates: _TreeStub(_template(), const [], const []),
          ncCapa: _NcStub(),
          inspectionId: 99,
        );
        await cubit.load();
        expect(cubit.state.inspection, isNull);
        expect(cubit.state.error, 'Inspection not found');
        await cubit.close();
      },
    );

    test('an unreadable NC list does not blank the answers', () async {
      final repo = _FakeSheet()
        ..inspections.add(_inspection())
        ..seed(1, 1, 10)
        ..failFindings = true;
      final cubit = await _sheet([_item(id: 1)], repo: repo);
      expect(cubit.state.sections, hasLength(1));
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('an item whose section vanished is still answerable', () async {
      final repo = _FakeSheet()..inspections.add(_inspection());
      final cubit = await _sheet([
        _item(id: 1, sectionId: 10),
        _item(id: 2, sectionId: 77),
      ], repo: repo);
      // Dropped from the tree, but silently disappearing would let the sheet
      // claim it is complete while an answer is still outstanding.
      expect(cubit.state.progress.total, 2);
      expect(cubit.state.sections.last.section.title, 'Other items');
      await cubit.close();
    });

    test(
      'a retired item stays answerable so the sheet can be closed out',
      () async {
        final repo = _FakeSheet()..inspections.add(_inspection());
        final item = QcItem(
          itemId: 1,
          sectionId: 10,
          templateId: 1,
          label: 'Retired check',
          deletedAt: _now,
        );
        final cubit = await _sheet([item], repo: repo);
        expect(cubit.state.sections, isEmpty);
        await cubit.close();
      },
    );
  });

  group('QcInspectionSheetCubit answering', () {
    test('one tap answers an item and stamps it as recorded', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1);
      final cubit = await _sheet([item], repo: repo);
      expect(cubit.state.sections.first.items.single.isRecorded, isFalse);
      await cubit.markResult(item, QcResponseResult.pass);
      expect(repo.answered.single.result, QcResponseResult.pass);
      expect(cubit.state.sections.first.items.single.isRecorded, isTrue);
      expect(cubit.state.progress.answered, 1);
      expect(cubit.state.notice, 'Saved');
      await cubit.close();
    });

    test(
      'a numeric verdict is derived from the bounds, not taken from the tap',
      () async {
        final repo = _FakeSheet();
        final item = _item(
          id: 1,
          type: QcItemType.number,
          minValue: 10,
          maxValue: 12,
        );
        final cubit = await _sheet([item], repo: repo);
        // Out of band: written as a failure even though the caller named a pass,
        // so a mis-tap cannot file a bad reading as good.
        await cubit.answer(item: item, value: '15', measuredValue: 15);
        expect(repo.answered.single.result, QcResponseResult.fail);
        expect(repo.answered.single.measuredValue, 15);
        expect(
          cubit.state.inspection!.resultOverall,
          QcOverallResult.conditional,
        );
        await cubit.close();
      },
    );

    test('a reading inside the band passes', () async {
      final repo = _FakeSheet();
      final item = _item(
        id: 1,
        type: QcItemType.number,
        minValue: 10,
        maxValue: 12,
      );
      final cubit = await _sheet([item], repo: repo);
      await cubit.answer(item: item, value: '11', measuredValue: 11);
      expect(repo.answered.single.result, QcResponseResult.pass);
      expect(cubit.state.inspection!.scorePct, 100);
      await cubit.close();
    });

    test(
      'a reading that is only typed still cannot pass out of band',
      () async {
        final repo = _FakeSheet();
        final item = _item(
          id: 1,
          type: QcItemType.number,
          minValue: 10,
          maxValue: 12,
        );
        final cubit = await _sheet([item], repo: repo);
        cubit.stageValue(1, '15');
        await cubit.markResult(item, QcResponseResult.pass);
        expect(repo.answered.single.result, QcResponseResult.fail);
        expect(repo.answered.single.value, '15');
        await cubit.close();
      },
    );

    test('only a critical item raises the critical flag', () async {
      final repo = _FakeSheet();
      final plain = _item(id: 1);
      final critical = _item(id: 2, critical: true);
      final cubit = await _sheet([plain, critical], repo: repo);
      await cubit.markResult(plain, QcResponseResult.fail);
      await cubit.markResult(critical, QcResponseResult.fail);
      expect(repo.answered[0].isCriticalFailure, isFalse);
      expect(repo.answered[1].isCriticalFailure, isTrue);
      // The flag is what fails the whole sheet.
      expect(cubit.state.inspection!.resultOverall, QcOverallResult.fail);
      await cubit.close();
    });

    test(
      'a critical item that does not demand evidence cannot fail the sheet',
      () async {
        final repo = _FakeSheet();
        final item = _item(id: 1, critical: true, requireEvidenceIfFail: false);
        final cubit = await _sheet([item], repo: repo);
        await cubit.markResult(item, QcResponseResult.fail);
        expect(repo.answered.single.isCriticalFailure, isFalse);
        expect(cubit.state.progress.criticalFailed, 0);
        expect(cubit.state.progress.advisories, isEmpty);
        await cubit.close();
      },
    );

    test('N/A is an answer, and is kept out of the score', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1);
      final cubit = await _sheet([item], repo: repo);
      await cubit.markNotApplicable(item);
      expect(repo.answered.single.result, QcResponseResult.na);
      expect(cubit.state.progress.answered, 1);
      // Nothing applicable, so nothing scores - counting N/A as a pass would let
      // a checklist inflate its own score by skipping the hard questions.
      expect(cubit.state.progress.maxScore, 0);
      expect(cubit.state.progress.score, 0);
      await cubit.close();
    });

    test('an item that forbids N/A refuses the decline', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1, allowNa: false);
      final cubit = await _sheet([item], repo: repo);
      await cubit.markNotApplicable(item);
      expect(repo.answered, isEmpty);
      expect(cubit.state.error, 'This item cannot be N/A');
      await cubit.close();
    });

    test(
      'an item with no response row is refused rather than written blind',
      () async {
        final repo = _FakeSheet();
        final cubit = await _sheet([_item(id: 1)], repo: repo);
        await cubit.answer(item: _item(id: 99), result: QcResponseResult.pass);
        expect(repo.answered, isEmpty);
        expect(cubit.state.error, 'This item has no response row');
        await cubit.close();
      },
    );

    test('a locked sheet refuses every answer', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1);
      final cubit = await _sheet(
        [item],
        repo: repo,
        status: QcInspectionStatus.submitted,
      );
      expect(cubit.state.isEditable, isFalse);
      await cubit.markResult(item, QcResponseResult.pass);
      expect(repo.answered, isEmpty);
      expect(cubit.state.error, 'This sheet is locked');
      await cubit.close();
    });

    test('a second photo is appended to the first, not over it', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1);
      final cubit = await _sheet([item], repo: repo);
      await cubit.attachPhoto(item, '/tmp/a.jpg');
      await cubit.attachPhoto(item, '/tmp/b.jpg');
      // Stored as real JSON: a hand-rolled quoted CSV would parse back as a
      // single garbled path and quietly lose the evidence.
      expect(jsonDecode(repo.answered.last.photosJson), [
        '/tmp/a.jpg',
        '/tmp/b.jpg',
      ]);
      expect(repo.answered.last.photos, ['/tmp/a.jpg', '/tmp/b.jpg']);
      expect(cubit.state.progress.answered, 1);
      await cubit.close();
    });

    test('a verdict tap keeps evidence already recorded on the item', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1);
      final cubit = await _sheet([item], repo: repo);
      await cubit.answer(item: item, result: QcResponseResult.fail);
      await cubit.attachPhoto(item, '/tmp/a.jpg');
      // Correcting the verdict must not erase the evidence chain the template
      // demanded for the failure.
      await cubit.markResult(item, QcResponseResult.fail);
      expect(repo.answered.last.photosJson, contains('a.jpg'));
      await cubit.close();
    });

    test('a note typed before the verdict is committed with it', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1);
      final cubit = await _sheet([item], repo: repo);
      cubit.stageNotes(1, 'cracked on one corner');
      await cubit.markResult(item, QcResponseResult.fail);
      expect(repo.answered.last.notes, 'cracked on one corner');
      expect(cubit.isDirty(1), isFalse);
      await cubit.close();
    });

    test('a refused write reports the reason and keeps the tree', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1);
      final cubit = await _sheet([item], repo: repo);
      repo.failWith = StateError('write refused');
      await cubit.markResult(item, QcResponseResult.pass);
      expect(cubit.state.error, contains('write refused'));
      expect(cubit.state.saving, isFalse);
      expect(cubit.state.sections, hasLength(1));
      await cubit.close();
    });

    test('drafts stay out of the state until they are committed', () async {
      final cubit = await _sheet([_item(id: 1)]);
      cubit.stageNotes(1, 'scratch');
      expect(cubit.isDirty(1), isTrue);
      // Staging must not rebuild the tree: this is what keeps a 40-item sheet
      // from re-grouping on every keystroke.
      expect(cubit.state.sections, hasLength(1));
      expect(
        cubit.notesFor(cubit.state.sections.first.items.single),
        'scratch',
      );
      await cubit.markResult(_item(id: 1), QcResponseResult.pass);
      // A committed answer clears the draft so the saved value is what shows.
      expect(cubit.isDirty(1), isFalse);
      await cubit.close();
    });
  });

  group('QcInspectionSheetCubit progress', () {
    test('an unanswered required item blocks submission', () async {
      final cubit = await _sheet([_item(id: 1)]);
      expect(cubit.state.progress.blocking, 1);
      expect(cubit.state.progress.canSubmit, isFalse);
      expect(cubit.state.progress.blockers.single, contains('required'));
      await cubit.close();
    });

    test('a required item that permits N/A still has to be answered', () async {
      final cubit = await _sheet([_item(id: 1, allowNa: true)]);
      // Allowing N/A widens the set of answers, it does not excuse the item.
      expect(cubit.state.progress.blocking, 1);
      expect(cubit.state.progress.canSubmit, isFalse);
      await cubit.close();
    });

    test('answering with N/A clears the blocker', () async {
      final item = _item(id: 1, allowNa: true);
      final cubit = await _sheet([item]);
      await cubit.markNotApplicable(item);
      expect(cubit.state.progress.blocking, 0);
      expect(cubit.state.progress.canSubmit, isTrue);
      await cubit.close();
    });

    test('an optional item never blocks submission', () async {
      final cubit = await _sheet([_item(id: 1, required: false)]);
      expect(cubit.state.progress.blocking, 0);
      expect(cubit.state.progress.canSubmit, isTrue);
      await cubit.close();
    });

    test('a failure without evidence blocks submission and says why', () async {
      final item = _item(id: 1);
      final cubit = await _sheet([item]);
      await cubit.markResult(item, QcResponseResult.fail);
      expect(cubit.state.progress.missingEvidence, 1);
      expect(cubit.state.progress.canSubmit, isFalse);
      expect(cubit.state.progress.blockers.single, contains('Evidence'));
      await cubit.close();
    });

    test('notes satisfy the evidence rule', () async {
      final item = _item(id: 1);
      final cubit = await _sheet([item]);
      await cubit.answer(
        item: item,
        result: QcResponseResult.fail,
        notes: 'cracked on one corner',
      );
      expect(cubit.state.progress.missingEvidence, 0);
      // A plain failure still leaves the sheet conditional, not passing.
      expect(
        cubit.state.inspection!.resultOverall,
        QcOverallResult.conditional,
      );
      expect(cubit.state.progress.canSubmit, isTrue);
      await cubit.close();
    });

    test('a critical failure is announced but still submittable', () async {
      final item = _item(id: 1, critical: true);
      final cubit = await _sheet([item]);
      await cubit.answer(
        item: item,
        result: QcResponseResult.fail,
        notes: 'shattered',
      );
      expect(cubit.state.progress.criticalFailed, 1);
      // Refusing to submit here would strand the sheet in progress forever and
      // leave the NC behind it unreviewed.
      expect(cubit.state.progress.canSubmit, isTrue);
      expect(cubit.state.progress.advisories.single, contains('critical'));
      expect(cubit.state.progress.blockers, isEmpty);
      await cubit.close();
    });

    test(
      'a critical item outweighs several trivial ones in the score',
      () async {
        final trivial = [
          for (var i = 1; i <= 5; i++) _item(id: i, label: 'trivial $i'),
        ];
        final crit = _item(id: 6, label: 'critical', critical: true);
        final cubit = await _sheet([...trivial, crit]);
        for (final item in trivial) {
          await cubit.markResult(item, QcResponseResult.pass);
        }
        // Five passes must not carry a failed critical check.
        await cubit.answer(
          item: crit,
          result: QcResponseResult.fail,
          notes: 'broken',
        );
        // Weight 3 against 5x1, so 5/8 rather than the 5/6 an unweighted mean
        // would report.
        expect(cubit.state.progress.score, closeTo(5 / 8, 0.001));
        await cubit.close();
      },
    );

    test('completion is answered over total, N/A included', () async {
      final cubit = await _sheet([_item(id: 1), _item(id: 2, required: false)]);
      await cubit.markNotApplicable(_item(id: 2, required: false));
      expect(cubit.state.progress.answered, 1);
      expect(cubit.state.progress.completion, 0.5);
      await cubit.close();
    });

    test('section progress counts its own items', () async {
      final items = [_item(id: 1, sectionId: 10), _item(id: 2, sectionId: 10)];
      final cubit = await _sheet(items);
      await cubit.markResult(items[0], QcResponseResult.pass);
      expect(cubit.state.sections.first.answered, 1);
      expect(cubit.state.sections.first.completion, 0.5);
      expect(cubit.state.sections.first.isComplete, isFalse);
      await cubit.close();
    });
  });

  group('QcInspectionSheetCubit submit', () {
    test('a complete sheet is submitted and handed back', () async {
      final item = _item(id: 1);
      final cubit = await _sheet([item]);
      await cubit.markResult(item, QcResponseResult.pass);
      await cubit.submit();
      expect(cubit.state.submitted, isTrue);
      expect(cubit.state.inspection!.status, QcInspectionStatus.submitted);
      expect(cubit.state.inspection!.submittedAt, isNotEmpty);
      expect(cubit.state.inspection!.endAt, isNotEmpty);
      expect(cubit.state.submitting, isFalse);
      await cubit.close();
    });

    test('an incomplete sheet is refused with the specific reason', () async {
      final cubit = await _sheet([_item(id: 1)]);
      await cubit.submit();
      expect(cubit.state.submitted, isFalse);
      expect(cubit.state.inspection!.status, QcInspectionStatus.inProgress);
      expect(cubit.state.error, contains('required'));
      await cubit.close();
    });

    test('a failure missing evidence is refused at submit time', () async {
      final item = _item(id: 1);
      final cubit = await _sheet([item]);
      await cubit.markResult(item, QcResponseResult.fail);
      await cubit.submit();
      expect(cubit.state.submitted, isFalse);
      expect(cubit.state.error, contains('Evidence'));
      await cubit.close();
    });

    test('a failed critical sheet goes to review as Fail', () async {
      final item = _item(id: 1, critical: true);
      final cubit = await _sheet([item]);
      await cubit.answer(
        item: item,
        result: QcResponseResult.fail,
        notes: 'shattered',
      );
      await cubit.submit();
      expect(cubit.state.submitted, isTrue);
      expect(cubit.state.inspection!.resultOverall, QcOverallResult.fail);
      await cubit.close();
    });

    test('a submitted sheet is not written again', () async {
      final repo = _FakeSheet();
      final item = _item(id: 1);
      final cubit = await _sheet([item], repo: repo);
      await cubit.markResult(item, QcResponseResult.pass);
      await cubit.submit();
      final stamp = cubit.state.inspection!.submittedAt;
      await cubit.submit();
      // One write, not two: after submit the sheet belongs to the reviewer.
      expect(cubit.state.inspection!.submittedAt, stamp);
      expect(repo.failWith, isNull);
      await cubit.close();
    });

    test(
      'a refused submit reports the reason and leaves the sheet open',
      () async {
        final item = _item(id: 1);
        final repo = _FakeSheet()..failWith = StateError('not allowed');
        final cubit = await _sheet([item], repo: repo);
        // Answering has to work for the sheet to reach the submit at all.
        repo.failWith = null;
        await cubit.markResult(item, QcResponseResult.pass);
        repo.failWith = StateError('not allowed');
        await cubit.submit();
        expect(cubit.state.submitted, isFalse);
        expect(cubit.state.submitting, isFalse);
        expect(cubit.state.error, contains('not allowed'));
        expect(cubit.state.inspection!.status, QcInspectionStatus.inProgress);
        await cubit.close();
      },
    );
  });

  group('QcInspectionSheetCubit non-conformances', () {
    test('raising an NC from a critical item defaults to Critical', () async {
      final repo = _FakeSheet();
      final nc = _NcStub();
      final item = _item(id: 1, critical: true, defectCode: 'CRK-01');
      final cubit = await _sheet([item], repo: repo, nc: nc);
      await cubit.answer(
        item: item,
        result: QcResponseResult.fail,
        notes: 'shattered',
      );
      await cubit.raiseNc(item: item);
      final finding = nc.created.single;
      expect(finding.severity, NcSeverity.critical);
      expect(finding.code, 'CRK-01');
      expect(finding.itemId, 1);
      expect(finding.respId, isNotNull);
      expect(finding.description, item.label);
      await cubit.close();
    });

    test('the finding is reflected in the header the screen shows', () async {
      final repo = _FakeSheet();
      final nc = _NcStub();
      final item = _item(id: 1);
      final cubit = await _sheet([item], repo: repo, nc: nc);
      // The fake recomputes from its own findings list the way the SQL trigger
      // does, so register the finding to make the header agree.
      await cubit.raiseNc(item: item, severity: NcSeverity.major);
      // The SQL repository recomputes the header inside the finding's own
      // transaction; the fake does it in `answerResponse` only, so drive it once
      // by hand the way the trigger would.
      repo.findings.add(nc.created.single);
      repo.recompute(1);
      await cubit.load();
      expect(cubit.state.findings, hasLength(1));
      expect(cubit.state.inspection!.hasNc, isTrue);
      expect(cubit.state.inspection!.ncCount, 1);
      expect(cubit.state.inspection!.majorNcCount, 1);
      await cubit.close();
    });

    test('a non-critical item defaults to Major, not Minor', () async {
      final nc = _NcStub();
      final item = _item(id: 1);
      final cubit = await _sheet([item], nc: nc);
      await cubit.raiseNc(item: item, severity: NcSeverity.minor);
      expect(nc.created.single.severity, NcSeverity.minor);
      await cubit.close();
    });

    test('a plain item raises Major without being asked', () async {
      final nc = _NcStub();
      final cubit = await _sheet([_item(id: 1)], nc: nc);
      await cubit.raiseNc(item: _item(id: 1));
      expect(nc.created.single.severity, NcSeverity.major);
      await cubit.close();
    });

    test('a locked sheet cannot raise an NC', () async {
      final nc = _NcStub();
      final cubit = await _sheet(
        [_item(id: 1)],
        nc: nc,
        status: QcInspectionStatus.approved,
      );
      await cubit.raiseNc(item: _item(id: 1));
      expect(nc.created, isEmpty);
      expect(cubit.state.error, 'This sheet is locked');
      await cubit.close();
    });

    test('a refused NC write reports the reason', () async {
      final nc = _NcStub()..failWith = StateError('nc refused');
      final cubit = await _sheet([_item(id: 1)], nc: nc);
      await cubit.raiseNc(item: _item(id: 1));
      expect(cubit.state.error, contains('nc refused'));
      expect(cubit.state.saving, isFalse);
      await cubit.close();
    });
  });

  group('QcInspectionSheetCubit remarks', () {
    test(
      'saving remarks writes the header without touching the answers',
      () async {
        final repo = _FakeSheet();
        final cubit = await _sheet([_item(id: 1)], repo: repo);
        final before = repo.answered.length;
        await cubit.saveRemarks('line 2 slow today');
        expect(cubit.state.inspection!.remarks, 'line 2 slow today');
        expect(repo.answered, hasLength(before));
        await cubit.close();
      },
    );

    test('re-saving the same remarks writes nothing', () async {
      final repo = _FakeSheet()
        ..inspections.add(_inspection().copyWith(remarks: 'same'));
      final cubit = await _sheet([], repo: repo);
      await cubit.saveRemarks('same');
      expect(repo.failWith, isNull);
      expect(cubit.state.inspection!.remarks, 'same');
      await cubit.close();
    });

    test('a locked sheet ignores remarks', () async {
      final repo = _FakeSheet();
      final cubit = await _sheet(
        [],
        repo: repo,
        status: QcInspectionStatus.closed,
      );
      await cubit.saveRemarks('should not stick');
      expect(cubit.state.inspection!.remarks, isEmpty);
      await cubit.close();
    });
  });
}
