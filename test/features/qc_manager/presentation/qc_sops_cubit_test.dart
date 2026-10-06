import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_sop.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_sop_detail_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_sops_cubit.dart';

/// In-memory stand-in for [QcSopRepository].
///
/// It mirrors the real repository's one awkward limitation - `listSops` takes no
/// status filter - so the cubit's fan-out and merging are tested against
/// something shaped like the database rather than a stub built to agree.
class _FakeSops implements QcSopRepository {
  _FakeSops(this.sops);

  /// Mutable so a test can swap the whole table for one scenario.
  List<QcSop> sops;
  final Map<int, List<QcSopRevision>> revisions = {};
  final Map<int, List<QcSopRead>> reads = {};

  final List<QcSop> created = [];
  final List<QcSop> updated = [];
  final List<int> deleted = [];
  final List<QcSopRead> acks = [];
  final List<({int sopId, String reason})> published = [];

  Object? failWith;

  @override
  Future<List<QcSop>> listSops({
    String dept = '',
    String status = '',
    bool includeArchived = false,
  }) async {
    if (failWith != null) throw failWith!;
    var rows = sops.where((s) => s.deletedAt.isEmpty).toList();
    if (status.isNotEmpty) {
      rows = rows.where((s) => s.status == status).toList();
    }
    if (dept.isNotEmpty) {
      rows = rows.where((s) => s.dept == dept).toList();
    }
    if (!includeArchived) {
      rows = rows.where((s) => s.status != SopStatus.archived).toList();
    }
    return rows;
  }

  @override
  Future<QcSop?> getSop(int sopId) async =>
      sops.where((s) => s.sopId == sopId).firstOrNull;

  @override
  Future<QcSop?> getSopByCode(String code) async =>
      sops.where((s) => s.code == code).firstOrNull;

  @override
  Future<int> createSop(QcSop sop) async {
    if (failWith != null) throw failWith!;
    created.add(sop);
    sops.add(sop.copyWithStatusOnly(sopId: 50 + created.length));
    return 50 + created.length;
  }

  @override
  Future<void> updateSop(QcSop sop) async {
    if (failWith != null) throw failWith!;
    updated.add(sop);
    final i = sops.indexWhere((s) => s.sopId == sop.sopId);
    if (i >= 0) sops[i] = sop;
  }

  @override
  Future<void> deleteSop(int sopId) async {
    deleted.add(sopId);
    final i = sops.indexWhere((s) => s.sopId == sopId);
    if (i >= 0) sops[i] = sops[i].copyWith(deletedAt: '2026-01-01T00:00:00Z');
  }

  @override
  Future<int> publishSopRevision(
    int sopId, {
    required String changeSummary,
    String effectiveFrom = '',
  }) async {
    if (failWith != null) throw failWith!;
    published.add((sopId: sopId, reason: changeSummary));
    final i = sops.indexWhere((s) => s.sopId == sopId);
    final next = (revisions[sopId]?.length ?? 0) + 1;
    revisions[sopId] = [
      QcSopRevision(
        sopId: sopId,
        revNo: next,
        changeReason: changeSummary,
        editedAt: '2026-01-01T00:00:00Z',
        isPublishedRev: true,
      ),
      ...?revisions[sopId],
    ];
    if (i >= 0) {
      sops[i] = sops[i].copyWith(
        revNo: next,
        publishedAt: '2026-01-01T00:00:00Z',
      );
    }
    return next;
  }

  @override
  Future<List<QcSopRevision>> listSopRevisions(int sopId) async =>
      revisions[sopId] ?? const [];

  @override
  Future<int> recordSopRead(QcSopRead read) async {
    if (failWith != null) throw failWith!;
    acks.add(read);
    // Idempotent per (sop, rev, user), exactly like the unique index.
    final existing = reads[read.sopId];
    if (existing != null &&
        existing.any((r) => r.userId == read.userId && r.revNo == read.revNo)) {
      return existing.first.id ?? 0;
    }
    reads[read.sopId] = [...?existing, read];
    return read.id ?? 1;
  }

  @override
  Future<List<QcSopRead>> listSopReads(int sopId) async =>
      reads[sopId] ?? const [];
}

QcSop _sop({
  int? id = 1,
  String code = 'SOP-001',
  String title = 'Calibrate the press',
  String status = SopStatus.draft,
  String dept = 'Production',
  String category = 'Equipment',
  String criticality = QcPriority.high,
  String expiry = '',
  bool requiresAck = true,
}) => QcSop(
  sopId: id,
  code: code,
  title: title,
  status: status,
  dept: dept,
  category: category,
  criticality: criticality,
  expiryDate: expiry,
  requiresReadAck: requiresAck,
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
);

void main() {
  group('QcSopsCubit', () {
    late _FakeSops repo;

    setUp(() => repo = _FakeSops([_sop()]));

    test('loads the register and summarises it', () async {
      repo.sops.addAll([
        _sop(id: 2, code: 'SOP-002', status: SopStatus.pending),
        _sop(id: 3, code: 'SOP-003', status: SopStatus.published),
        _sop(id: 4, code: 'SOP-004', status: SopStatus.archived),
      ]);
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.sops.map((s) => s.code), isNot(contains('SOP-004')));
      expect(cubit.state.summary.total, 3);
      expect(cubit.state.summary.draft, 1);
      expect(cubit.state.summary.awaitingApproval, 1);
      expect(cubit.state.summary.published, 1);
    });

    test('counts SOPs about to lapse', () async {
      final soon = DateTime.now()
          .add(const Duration(days: 10))
          .toIso8601String()
          .substring(0, 10);
      repo.sops = [
        _sop(status: SopStatus.published, expiry: soon),
        _sop(id: 2, code: 'SOP-002', status: SopStatus.published),
      ];
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.summary.expiringSoon, 1);
    });

    test('archived stays hidden until it is asked for', () async {
      repo.sops.add(_sop(id: 9, code: 'SOP-009', status: SopStatus.archived));
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.sops.length, 1);

      await cubit.applyFilters(const QcSopFilters(includeArchived: true));
      expect(cubit.state.sops.length, 2);
    });

    test(
      'status multi-select fans out over statuses the query cannot filter',
      () async {
        repo.sops.addAll([
          _sop(id: 2, code: 'SOP-002', status: SopStatus.pending),
          _sop(id: 3, code: 'SOP-003', status: SopStatus.published),
        ]);
        final cubit = QcSopsCubit(repo: repo);
        await cubit.load();
        await cubit.toggleStatus(SopStatus.pending);
        expect(cubit.state.sops.map((s) => s.code), ['SOP-002']);

        await cubit.toggleStatus(SopStatus.published);
        expect(
          cubit.state.sops.map((s) => s.code),
          containsAll(['SOP-002', 'SOP-003']),
        );

        await cubit.toggleStatus(SopStatus.pending);
        expect(cubit.state.sops.map((s) => s.code), ['SOP-003']);
      },
    );

    test('search matches code and title but not department', () async {
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      await cubit.applyFilters(const QcSopFilters(text: 'press'));
      expect(cubit.state.sops.length, 1);

      await cubit.applyFilters(const QcSopFilters(text: 'SOP-001'));
      expect(cubit.state.sops.length, 1);

      await cubit.applyFilters(const QcSopFilters(text: 'Maintenance'));
      expect(cubit.state.sops, isEmpty);
    });

    test('clearing filters restores everything', () async {
      repo.sops.add(_sop(id: 2, code: 'SOP-002'));
      final cubit = QcSopsCubit(repo: repo);
      await cubit.applyFilters(const QcSopFilters(text: 'nothing-matches'));
      expect(cubit.state.sops, isEmpty);
      await cubit.clearFilters();
      expect(cubit.state.sops.length, 2);
    });

    test('a failed load reports the error and stops loading', () async {
      repo.failWith = StateError('db is gone');
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, contains('db is gone'));
    });

    test('create adds a draft and reloads', () async {
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      await cubit.createSop(
        _sop(id: null, code: 'SOP-100', title: 'New procedure'),
      );
      expect(repo.created.single.status, SopStatus.draft);
      expect(cubit.state.sops.map((s) => s.code), contains('SOP-100'));
    });

    test('advance refuses an illegal move instead of writing it', () async {
      repo.sops = [_sop(status: SopStatus.published)];
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      final result = await cubit.advance(repo.sops.first, SopStatus.draft);
      expect(result, isNull);
      expect(repo.updated, isEmpty);
    });

    test('advance stamps the timestamps each state implies', () async {
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();

      // Submitted is not reviewed: the reviewer has not looked yet, and a
      // `reviewed_at` here would misreport who has actually seen it.
      await cubit.advance(repo.sops.first, SopStatus.pending);
      expect(repo.updated.single.status, SopStatus.pending);
      expect(repo.updated.single.reviewedAt, isEmpty);

      await cubit.advance(repo.sops.first, SopStatus.approved);
      expect(repo.updated.last.reviewedAt, isNotEmpty);

      await cubit.advance(repo.sops.first, SopStatus.published);
      expect(repo.updated.last.publishedAt, isNotEmpty);
    });

    test('returning a rejected SOP to draft keeps the reason', () async {
      repo.sops = [_sop(id: 3, code: 'SOP-003', status: SopStatus.pending)];
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      await cubit.advance(
        repo.sops.first,
        SopStatus.draft,
        reason: 'Wrong limits',
      );
      expect(repo.updated.single.status, SopStatus.draft);
      expect(repo.updated.single.rejectionReason, 'Wrong limits');
    });

    test('publishing a revision passes the summary through', () async {
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      await cubit.publishRevision(
        repo.sops.first,
        changeSummary: 'Torque figure corrected',
      );
      expect(repo.published.single.reason, 'Torque figure corrected');
      expect(cubit.state.sops.single.revNo, 1);
    });

    test('delete is a tombstone and the row leaves the register', () async {
      final cubit = QcSopsCubit(repo: repo);
      await cubit.load();
      await cubit.deleteSop(1);
      expect(repo.deleted, [1]);
      expect(cubit.state.sops, isEmpty);
    });

    test('a stale load cannot overwrite a newer one', () async {
      final cubit = QcSopsCubit(repo: repo);
      final first = cubit.load();
      repo.sops.add(_sop(id: 2, code: 'SOP-002'));
      await cubit.load();
      await first;
      expect(cubit.state.sops.length, 2);
    });
  });

  group('QcSopDetailCubit', () {
    late _FakeSops repo;
    late QcSopsCubit register;

    setUp(() {
      repo = _FakeSops([_sop()]);
      register = QcSopsCubit(repo: repo);
    });

    test('loads the SOP, its revisions and its readers', () async {
      repo.revisions[1] = [
        QcSopRevision(
          sopId: 1,
          revNo: 3,
          changeReason: 'Third issue',
          editedAt: '2026-01-01T00:00:00Z',
          isPublishedRev: true,
        ),
      ];
      repo.reads[1] = [
        QcSopRead(
          sopId: 1,
          revNo: 3,
          userId: 'u2',
          userName: 'Nadia',
          readAt: '2026-02-01T09:00:00Z',
        ),
      ];
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
      await cubit.load();

      expect(cubit.state.sop?.code, 'SOP-001');
      expect(cubit.state.latestRevision?.revNo, 3);
      expect(cubit.state.reads.single.userName, 'Nadia');
      expect(cubit.state.loading, isFalse);
    });

    test('a missing SOP reports itself instead of rendering nothing', () async {
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 404);
      await cubit.load();
      expect(cubit.state.sop, isNull);
      expect(cubit.state.error, isNotNull);
    });

    test('offers exactly the moves the domain allows', () async {
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
      await cubit.load();
      expect(cubit.state.nextStatuses, SopStatus.transitions[SopStatus.draft]);

      repo.sops[0] = _sop(status: SopStatus.published);
      await cubit.load();
      expect(
        cubit.state.nextStatuses,
        isNot(contains(SopStatus.draft)),
        reason:
            'a published SOP must not offer a way back into an editable state',
      );
    });

    test('an illegal transition is refused before any write', () async {
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
      await cubit.load();
      await cubit.advance(SopStatus.published);
      expect(repo.updated, isEmpty);
      expect(cubit.state.error, isNotNull);
    });

    test(
      'a legal transition writes and refreshes the register behind',
      () async {
        final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
        await register.load();
        await cubit.load();
        await cubit.advance(SopStatus.pending);

        expect(repo.updated.single.status, SopStatus.pending);
        expect(register.state.sops.single.status, SopStatus.pending);
      },
    );

    test('a revision cannot be cut without a reason', () async {
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
      await cubit.load();
      await cubit.publishRevision(changeSummary: '   ');
      expect(repo.published, isEmpty);
      expect(cubit.state.error, isNotNull);
    });

    test('cutting a revision increments revNo and clears the error', () async {
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
      await cubit.load();
      await cubit.publishRevision(changeSummary: 'Clearer wording');
      expect(cubit.state.sop?.revNo, 1);
      expect(cubit.state.notice, isNotNull);
      expect(cubit.state.saving, isFalse);
    });

    test('an acknowledgement needs a reader', () async {
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
      await cubit.load();
      await cubit.acknowledge(userId: '  ');
      expect(repo.acks, isEmpty);
      expect(cubit.state.error, isNotNull);
    });

    test('an acknowledgement is filed against the current revision', () async {
      repo.revisions[1] = [
        QcSopRevision(
          sopId: 1,
          revNo: 4,
          changeReason: 'Fourth',
          editedAt: '2026-01-01T00:00:00Z',
          isPublishedRev: true,
        ),
      ];
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
      await cubit.load();
      await cubit.acknowledge(userId: 'u7', userName: 'Tarek');

      expect(repo.acks.single.revNo, 4);
      expect(repo.acks.single.userName, 'Tarek');
      expect(cubit.state.reads.single.userId, 'u7');
      expect(cubit.state.owesAck('u7'), isFalse);
      expect(cubit.state.owesAck('u8'), isTrue);
    });

    test('reads are scoped to the revision, not the SOP', () async {
      repo.sops[0] = _sop(status: SopStatus.published);
      repo.reads[1] = [
        QcSopRead(
          sopId: 1,
          revNo: 1,
          userId: 'u7',
          readAt: '2026-01-01T00:00:00Z',
        ),
      ];
      final cubit = QcSopDetailCubit(repo: repo, sops: register, sopId: 1);
      await cubit.load();
      // Revision 2 now: having read revision 1 owes nothing, but also proves
      // nothing, so the reader owes an acknowledgement again.
      repo.sops[0] = _sop(status: SopStatus.published).copyWith(revNo: 2);
      await cubit.load();
      expect(cubit.state.owesAck('u7'), isTrue);
    });
  });
}

/// Small helper so the fake can stamp an id without touching identity fields.
extension on QcSop {
  QcSop copyWithStatusOnly({int? sopId}) => QcSop(
    sopId: sopId,
    code: code,
    title: title,
    category: category,
    dept: dept,
    site: site,
    status: status,
    contentType: contentType,
    contentText: contentText,
    revNo: revNo,
    effectiveDate: effectiveDate,
    expiryDate: expiryDate,
    publishedAt: publishedAt,
    isActive: isActive,
    ownerId: ownerId,
    tags: tags,
    criticality: criticality,
    requiresReadAck: requiresReadAck,
    readAckMandatory: readAckMandatory,
    createdAt: createdAt,
    updatedAt: updatedAt,
    createdBy: createdBy,
  );
}
