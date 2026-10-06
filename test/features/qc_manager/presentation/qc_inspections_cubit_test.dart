import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_inspections_cubit.dart';

const _now = '2026-02-01 08:00:00';

/// In-memory [QcInspectionRepository] that applies the filters the way SQL
/// would, including the single-`status` limitation the real one has - so the
/// cubit's multi-status fan-out and merge are exercised against something that
/// behaves like the database rather than a stub that always agrees with them.
class _FakeInspections implements QcInspectionRepository {
  _FakeInspections([List<QcInspection>? rows])
    : inspections = rows ?? <QcInspection>[];

  final List<QcInspection> inspections;
  final List<QcResponse> responses = [];
  final List<QcFindingNc> findings = [];

  int createCalls = 0;
  final List<QcInspection> created = [];
  final List<int> deleted = [];
  Object? failWith;
  bool failListFindings = false;

  /// When set, the *first* query waits on it - the hook used to interleave two
  /// loads and prove the stale one is dropped.
  Completer<void>? gate;

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
  }) async {
    final pending = gate;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
    if (failWith != null) throw failWith!;
    var rows = inspections.where((i) => !i.isDeleted).toList();
    if (templateId != null) {
      rows = rows.where((i) => i.templateId == templateId).toList();
    }
    if (status.isNotEmpty) {
      rows = rows.where((i) => i.status == status).toList();
    }
    if (refType.isNotEmpty) {
      rows = rows.where((i) => i.refType == refType).toList();
    }
    if (refId.isNotEmpty) rows = rows.where((i) => i.refId == refId).toList();
    if (lotNo.isNotEmpty) {
      rows = rows.where((i) => i.lotNo.contains(lotNo)).toList();
    }
    if (dept.isNotEmpty) rows = rows.where((i) => i.dept == dept).toList();
    // The repository orders by inspection_date DESC, inspection_id DESC.
    rows.sort((a, b) {
      final byDate = b.inspectionDate.compareTo(a.inspectionDate);
      return byDate != 0
          ? byDate
          : (b.inspectionId ?? 0).compareTo(a.inspectionId ?? 0);
    });
    final start = offset.clamp(0, rows.length);
    final end = (start + limit).clamp(start, rows.length);
    return rows.sublist(start, end);
  }

  @override
  Future<QcInspection?> getInspection(int inspectionId) async =>
      inspections.where((i) => i.inspectionId == inspectionId).firstOrNull;

  @override
  Future<int> countInspections({
    String status = '',
    String refType = '',
    String refId = '',
  }) async {
    var rows = inspections.where((i) => !i.isDeleted).toList();
    if (status.isNotEmpty) {
      rows = rows.where((i) => i.status == status).toList();
    }
    if (refType.isNotEmpty) {
      rows = rows.where((i) => i.refType == refType).toList();
    }
    if (refId.isNotEmpty) rows = rows.where((i) => i.refId == refId).toList();
    return rows.length;
  }

  @override
  Future<int> createInspection(QcInspection inspection) async {
    if (failWith != null) throw failWith!;
    createCalls++;
    created.add(inspection);
    final id = inspections.length + 1;
    inspections.add(inspection.copyWith(inspectionId: id));
    return id;
  }

  @override
  Future<void> saveInspection(QcInspection inspection) async {
    if (failWith != null) throw failWith!;
    final i = inspections.indexWhere(
      (r) => r.inspectionId == inspection.inspectionId,
    );
    if (i >= 0) inspections[i] = inspection;
  }

  @override
  Future<void> deleteInspection(int inspectionId) async {
    if (failWith != null) throw failWith!;
    deleted.add(inspectionId);
    final i = inspections.indexWhere((r) => r.inspectionId == inspectionId);
    if (i >= 0) inspections[i] = inspections[i].copyWith(deletedAt: _now);
  }

  @override
  Future<List<QcResponse>> listResponses(int inspectionId) async =>
      responses.where((r) => r.inspectionId == inspectionId).toList();

  @override
  Future<void> answerResponse(QcResponse response) async {
    if (failWith != null) throw failWith!;
    final i = responses.indexWhere((r) => r.respId == response.respId);
    if (i >= 0) responses[i] = response;
  }

  @override
  Future<List<QcFindingNc>> listFindings(int inspectionId) async {
    if (failListFindings) throw StateError('findings unavailable');
    return findings.where((f) => f.inspectionId == inspectionId).toList();
  }
}

QcInspection _inspection({
  int id = 1,
  String status = QcInspectionStatus.inProgress,
  String lotNo = 'LOT-1',
  String dept = 'Production',
  String inspectionDate = '2026-02-01',
  int? criticalNcCount = 0,
  bool submitted = false,
}) => QcInspection(
  inspectionId: id,
  templateId: 7,
  status: status,
  resultOverall: QcOverallResult.pending,
  criticalNcCount: criticalNcCount ?? 0,
  ncCount: criticalNcCount ?? 0,
  hasNc: (criticalNcCount ?? 0) > 0,
  lotNo: lotNo,
  dept: dept,
  inspectionDate: inspectionDate,
  submittedAt: submitted ? _now : '',
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  setUp(() => AppText.useLanguage('en'));

  group('QcInspectionsCubit', () {
    test('loads the register and clears the loading flag', () async {
      final repo = _FakeInspections([_inspection(id: 1), _inspection(id: 2)]);
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.inspections.length, 2);
      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('a soft-deleted sheet is not in the register', () async {
      final repo = _FakeInspections([
        _inspection(id: 1),
        _inspection(id: 2).copyWith(deletedAt: _now),
      ]);
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.inspections.map((i) => i.inspectionId), [1]);
      await cubit.close();
    });

    test(
      'reports a failure instead of an empty list that looks like success',
      () async {
        final repo = _FakeInspections()..failWith = StateError('db down');
        final cubit = QcInspectionsCubit(repo: repo);
        await cubit.load();
        expect(cubit.state.loading, isFalse);
        expect(cubit.state.error, contains('db down'));
        await cubit.close();
      },
    );

    test('a multi-status filter merges one query per status', () async {
      final repo = _FakeInspections([
        _inspection(id: 1, status: QcInspectionStatus.inProgress),
        _inspection(
          id: 2,
          status: QcInspectionStatus.submitted,
          submitted: true,
        ),
        _inspection(id: 3, status: QcInspectionStatus.approved),
      ]);
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.applyFilters(
        const QcInspectionFilters(
          statuses: {
            QcInspectionStatus.inProgress,
            QcInspectionStatus.submitted,
          },
        ),
      );
      expect(
        cubit.state.inspections.map((i) => i.inspectionId).toList()..sort(),
        [1, 2],
      );
      expect(cubit.state.filters.activeCount, 1);
      await cubit.close();
    });

    test('a merged page is re-sorted newest first', () async {
      final repo = _FakeInspections([
        _inspection(id: 1, inspectionDate: '2026-01-01'),
        _inspection(id: 2, inspectionDate: '2026-03-01'),
        _inspection(id: 3, inspectionDate: '2026-02-01'),
      ]);
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.applyFilters(
        const QcInspectionFilters(statuses: {QcInspectionStatus.inProgress}),
      );
      // One query per status returns the same rows twice; without the re-sort
      // the merge would depend on which query resolved first.
      expect(cubit.state.inspections.map((i) => i.inspectionId), [2, 3, 1]);
      await cubit.close();
    });

    test('lot and dept narrow the query', () async {
      final repo = _FakeInspections([
        _inspection(id: 1, lotNo: 'LOT-A', dept: 'Production'),
        _inspection(id: 2, lotNo: 'LOT-B', dept: 'Quality'),
      ]);
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.applyFilters(
        const QcInspectionFilters(lotNo: 'LOT-A', dept: 'Production'),
      );
      expect(cubit.state.inspections.single.inspectionId, 1);
      await cubit.close();
    });

    test(
      'toggling a status on and off returns to the unfiltered scope',
      () async {
        final repo = _FakeInspections([
          _inspection(id: 1, status: QcInspectionStatus.inProgress),
          _inspection(
            id: 2,
            status: QcInspectionStatus.submitted,
            submitted: true,
          ),
        ]);
        final cubit = QcInspectionsCubit(repo: repo);
        await cubit.toggleStatus(QcInspectionStatus.submitted);
        expect(cubit.state.inspections.single.inspectionId, 2);
        await cubit.toggleStatus(QcInspectionStatus.submitted);
        expect(cubit.state.inspections.length, 2);
        await cubit.close();
      },
    );

    test('clearFilters empties the scope', () async {
      final repo = _FakeInspections([
        _inspection(
          id: 1,
          status: QcInspectionStatus.submitted,
          submitted: true,
        ),
      ]);
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.toggleStatus(QcInspectionStatus.submitted);
      await cubit.clearFilters();
      expect(cubit.state.filters.isEmpty, isTrue);
      await cubit.close();
    });

    test('hasMore is set only while a full page came back', () async {
      final full = [
        for (var i = 1; i <= qcInspectionsPageSize; i++) _inspection(id: i),
      ];
      final cubit = QcInspectionsCubit(repo: _FakeInspections(full));
      await cubit.load();
      expect(cubit.state.hasMore, isTrue);
      await cubit.close();

      final short = QcInspectionsCubit(
        repo: _FakeInspections([_inspection(id: 1)]),
      );
      await short.load();
      expect(short.state.hasMore, isFalse);
      await short.close();
    });

    test('loadMore appends the next page and stops at the end', () async {
      final rows = [
        for (var i = 1; i <= qcInspectionsPageSize + 3; i++) _inspection(id: i),
      ];
      final cubit = QcInspectionsCubit(repo: _FakeInspections(rows));
      await cubit.load();
      expect(cubit.state.inspections.length, qcInspectionsPageSize);
      await cubit.loadMore();
      expect(cubit.state.inspections.length, qcInspectionsPageSize + 3);
      expect(cubit.state.hasMore, isFalse);
      // Asking again must not append the tail twice.
      await cubit.loadMore();
      expect(cubit.state.inspections.length, qcInspectionsPageSize + 3);
      await cubit.close();
    });

    test('the summary counts the rows in scope', () async {
      final repo = _FakeInspections([
        _inspection(id: 1),
        _inspection(
          id: 2,
          status: QcInspectionStatus.submitted,
          submitted: true,
        ),
        _inspection(id: 3, criticalNcCount: 1),
      ]);
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.summary.total, 3);
      expect(cubit.state.summary.inProgress, 2);
      expect(cubit.state.summary.awaitingReview, 1);
      expect(cubit.state.summary.withNc, 1);
      await cubit.close();
    });

    test('starting a sheet publishes its id before reloading', () async {
      final repo = _FakeInspections();
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.load();
      await cubit.startInspection(_inspection());
      expect(repo.createCalls, 1);
      expect(cubit.state.startedId, 1);
      expect(cubit.state.saved, isTrue);
      expect(cubit.state.inspections.single.inspectionId, 1);
      await cubit.close();
    });

    test(
      'a refused start reports the reason and leaves the id unset',
      () async {
        final repo = _FakeInspections()..failWith = StateError('no write');
        final cubit = QcInspectionsCubit(repo: repo);
        await cubit.startInspection(_inspection());
        expect(cubit.state.startedId, isNull);
        expect(cubit.state.error, contains('no write'));
        expect(cubit.state.saving, isFalse);
        await cubit.close();
      },
    );

    test('deleting a sheet takes it out of the register', () async {
      final repo = _FakeInspections([_inspection(id: 1), _inspection(id: 2)]);
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.load();
      await cubit.deleteInspection(1);
      expect(repo.deleted, [1]);
      expect(cubit.state.inspections.map((i) => i.inspectionId), [2]);
      await cubit.close();
    });

    test('the one-shot signals clear on request', () async {
      final repo = _FakeInspections();
      final cubit = QcInspectionsCubit(repo: repo);
      await cubit.startInspection(_inspection());
      cubit.clearStarted();
      expect(cubit.state.startedId, isNull);
      cubit.clearSaved();
      expect(cubit.state.saved, isFalse);
      await cubit.close();
    });

    test('a stale load does not overwrite the newer scope', () async {
      final repo = _FakeInspections([
        _inspection(id: 9, lotNo: 'OLD'),
        _inspection(id: 1, lotNo: 'NEW'),
      ]);
      final gate = Completer<void>();
      repo.gate = gate;
      final cubit = QcInspectionsCubit(repo: repo);
      // The unfiltered load is held inside the repository while the filtered
      // scope resolves; when it finally answers with both rows it must be
      // dropped, or the register would show a lot the user filtered out.
      final stale = cubit.load();
      await cubit.applyFilters(const QcInspectionFilters(lotNo: 'NEW'));
      expect(cubit.state.inspections.single.inspectionId, 1);
      gate.complete();
      await stale;
      expect(cubit.state.inspections.single.inspectionId, 1);
      await cubit.close();
    });

    test('loadStartOptions offers only published, live checklists', () async {
      final templates = _TemplateStub([
        QcTemplate(
          templateId: 1,
          name: 'Incoming',
          code: 'IN-1',
          isPublished: true,
          createdAt: _now,
          updatedAt: _now,
        ),
        QcTemplate(
          templateId: 2,
          name: 'Draft',
          code: 'DR-1',
          createdAt: _now,
          updatedAt: _now,
        ),
        QcTemplate(
          templateId: 3,
          name: 'Retired',
          code: 'RT-1',
          isPublished: true,
          isArchived: true,
          createdAt: _now,
          updatedAt: _now,
        ),
      ]);
      final cubit = QcInspectionsCubit(
        repo: _FakeInspections(),
        templates: templates,
      );
      await cubit.loadStartOptions();
      expect(cubit.state.startTemplates.map((t) => t.templateId), [1]);
      await cubit.close();
    });

    test('loadStartOptions is a no-op without a template repository', () async {
      final cubit = QcInspectionsCubit(repo: _FakeInspections());
      await cubit.loadStartOptions();
      expect(cubit.state.startTemplates, isEmpty);
      await cubit.close();
    });

    test(
      'an unreadable checklist library does not break the register',
      () async {
        final templates = _TemplateStub([])..fail = true;
        final cubit = QcInspectionsCubit(
          repo: _FakeInspections([_inspection()]),
          templates: templates,
        );
        await cubit.load();
        await cubit.loadStartOptions();
        expect(cubit.state.startTemplates, isEmpty);
        expect(cubit.state.error, isNull);
        expect(cubit.state.inspections, hasLength(1));
        await cubit.close();
      },
    );
  });
}

/// Only [listTemplates] is reached by the register; the rest throw so an
/// accidental extra call fails loudly instead of silently returning null.
class _TemplateStub implements QcTemplateRepository {
  _TemplateStub(this.templates);

  final List<QcTemplate> templates;
  bool fail = false;

  @override
  Future<List<QcTemplate>> listTemplates({
    String dept = '',
    bool publishedOnly = false,
  }) async {
    if (fail) throw StateError('templates unavailable');
    final rows = publishedOnly
        ? templates.where((t) => t.isPublished).toList()
        : List<QcTemplate>.from(templates);
    return dept.isEmpty ? rows : rows.where((t) => t.dept == dept).toList();
  }

  @override
  Future<QcTemplate?> getTemplate(int templateId) async =>
      templates.where((t) => t.templateId == templateId).firstOrNull;

  @override
  Future<({QcTemplate template, List<QcSection> sections, List<QcItem> items})?>
  getTemplateTree(int templateId) async => null;

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
