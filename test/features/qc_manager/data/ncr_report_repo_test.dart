import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/qc_manager/data/ncr_report_repo.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_filters.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_kpis.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// The read-only NCR projection on its own (plan V6_ENHANCED §22.5, P7).
///
/// Rows are inserted straight into SQLite rather than through `QcNcCapaRepo`,
/// because every rule under test here is a *date* rule - on-time closure,
/// overdue, MTTC, the aging bands - and the model layer writes `nowIso()`, which
/// cannot be pinned to a fixed instant. Raw inserts are what let "closed three
/// days late, ten days ago" be expressed at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late Database db;
  late QcNcReportRepo repo;

  String day(int offset) {
    final base = DateTime.now().add(Duration(days: offset));
    return '${base.year.toString().padLeft(4, '0')}-'
        '${base.month.toString().padLeft(2, '0')}-'
        '${base.day.toString().padLeft(2, '0')}';
  }

  String stamp(int offset, {int hour = 9}) =>
      '${day(offset)} ${hour.toString().padLeft(2, '0')}:00:00';

  Future<int> inspection({
    String lot = 'LOT-1',
    String dept = 'Welding',
    String inspectorId = 'u1',
    String inspectorName = 'Ann Inspector',
    String? inspectionDate,
    bool deleted = false,
  }) async {
    return db.insert('qc_inspections', {
      'template_id': 1,
      'inspection_date': inspectionDate ?? day(-10),
      'lot_no': lot,
      'dept': dept,
      'site': 'SiteA',
      'location': 'Bay 3',
      'inspector_id': inspectorId,
      'inspector_name': inspectorName,
      'status': 'Approved',
      'created_at': stamp(-10),
      'updated_at': stamp(-10),
      if (deleted) 'deleted_at': stamp(-1),
    });
  }

  Future<int> finding(
    int inspectionId, {
    String severity = 'Major',
    String status = 'Open',
    String code = '',
    String category = '',
    String type = 'NonConformance',
    int createdOffset = -10,
    String? dueDate,
    String? closedAt,
    String? verifiedAt,
    String? assignedTo,
    String? assignedToName,
    bool deleted = false,
    String description = 'Weld undercut',
  }) async {
    return db.insert('qc_findings_nc', {
      'inspection_id': inspectionId,
      'severity': severity,
      'status': status,
      'type': type,
      'category': category,
      'code': code,
      'description': description,
      'created_at': stamp(createdOffset),
      'updated_at': stamp(createdOffset),
      'due_date': dueDate,
      'closed_at': closedAt,
      'verified_at': verifiedAt,
      'assigned_to': assignedTo,
      'assigned_to_name': assignedToName,
      if (deleted) 'deleted_at': stamp(-1),
    });
  }

  Future<int> capa(
    int findingId, {
    String status = 'Open',
    String? dueAt,
    bool effective = false,
  }) async {
    return db.insert('qc_capa', {
      'finding_id': findingId,
      'type': 'Corrective',
      'action_plan': 'Rework and re-inspect',
      'status': status,
      'priority': 'High',
      'due_at': dueAt,
      'is_effective': effective ? 1 : 0,
      'created_at': stamp(-5),
      'updated_at': stamp(-5),
    });
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_ncr');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
    repo = QcNcReportRepo(dbHelper: helper);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('KPI population (22.3)', () {
    test('an empty report is all zeros with no invented averages', () async {
      final kpis = await repo.kpis(const NcrFilters());

      expect(kpis.total, 0);
      expect(kpis.open, 0);
      expect(kpis.onTimeClosurePct, isNull);
      expect(kpis.mttcDays, isNull);
      expect(kpis.mttvDays, isNull);
    });

    test('status, severity and total all agree with the seeded rows', () async {
      final i1 = await inspection();
      await finding(i1, status: 'Open', severity: 'Critical');
      await finding(i1, status: 'Assigned', severity: 'Major');
      await finding(i1, status: 'InProgress', severity: 'Major');
      await finding(i1, status: 'Verified', severity: 'Minor');
      await finding(i1, status: 'Closed', severity: 'Minor');
      await finding(i1, status: 'Rejected', severity: 'Minor');

      final kpis = await repo.kpis(const NcrFilters());

      expect(kpis.total, 6);
      expect(kpis.assigned, 1);
      expect(kpis.inProgress, 1);
      expect(kpis.verified, 1);
      expect(kpis.closed, 1);
      expect(kpis.rejected, 1);
      // Open + Assigned + InProgress + Verified: a verified-but-unclosed
      // finding is still unresolved and must not be quietly dropped.
      expect(kpis.open, 4);
      expect(kpis.critical, 1);
      expect(kpis.major, 2);
      expect(kpis.minor, 3);
      expect(kpis.resolved, 2);
    });

    test(
      'overdue counts only unresolved findings past their due date',
      () async {
        final i1 = await inspection();
        await finding(i1, status: 'Open', dueDate: day(-1));
        await finding(i1, status: 'InProgress', dueDate: day(5));
        await finding(
          i1,
          status: 'Open',
          dueDate: day(0),
        ); // due today, not yet
        await finding(i1, status: 'Open');
        await finding(
          i1,
          status: 'Closed',
          dueDate: day(-3),
          closedAt: stamp(-4),
        );
        await finding(i1, status: 'Rejected', dueDate: day(-3));

        final kpis = await repo.kpis(const NcrFilters());

        expect(kpis.overdue, 1);
      },
    );

    test('a finding due today is not yet overdue', () async {
      final i1 = await inspection();
      await finding(i1, status: 'Open', dueDate: day(0));

      expect((await repo.kpis(const NcrFilters())).overdue, 0);
    });

    test('on-time closure uses closed_at <= due_date', () async {
      final i1 = await inspection();
      await finding(
        i1,
        status: 'Closed',
        dueDate: day(0),
        createdOffset: -20,
        closedAt: stamp(-2), // early
      );
      await finding(
        i1,
        status: 'Closed',
        dueDate: day(-5),
        createdOffset: -20,
        closedAt: stamp(-2), // late
      );
      await finding(
        i1,
        status: 'Closed',
        createdOffset: -20,
        closedAt: stamp(-2), // no due date at all
      );

      final kpis = await repo.kpis(const NcrFilters());

      expect(kpis.closed, 3);
      expect(kpis.closedOnTime, 1);
      expect(kpis.onTimeClosurePct, closeTo(100 / 3, 0.001));
    });

    test(
      'a closure made after midnight on the due date still counts on time',
      () async {
        final i1 = await inspection();
        await finding(
          i1,
          status: 'Closed',
          dueDate: day(-1),
          createdOffset: -20,
          closedAt: '${day(-1)} 23:30:00',
        );

        final kpis = await repo.kpis(const NcrFilters());
        expect(kpis.onTimeClosurePct, 100);
      },
    );

    test(
      'MTTC and MTTV average only the rows that reached the milestone',
      () async {
        final i1 = await inspection();
        await finding(
          i1,
          status: 'Closed',
          createdOffset: -10,
          closedAt: stamp(0), // 10 days
        );
        await finding(
          i1,
          status: 'Closed',
          createdOffset: -30,
          closedAt: stamp(0), // 30 days
        );
        await finding(
          i1,
          status: 'Verified',
          createdOffset: -4,
          verifiedAt: stamp(0), // 4 days
        );

        final kpis = await repo.kpis(const NcrFilters());

        expect(kpis.mttcDays, closeTo(20, 0.001));
        expect(kpis.mttvDays, closeTo(4, 0.001));
        expect(kpis.verifiedRows, 1);
      },
    );

    test(
      'CAPA coverage and CAPA overdue are counted over the filtered set',
      () async {
        final i1 = await inspection();
        final withCapa = await finding(i1, status: 'Open');
        final overdueCapa = await finding(i1, status: 'Open');
        final closedCapa = await finding(i1, status: 'Closed');
        await capa(withCapa, status: 'Closed');
        await capa(overdueCapa, status: 'Open', dueAt: day(-2));
        await capa(closedCapa, status: 'VerifiedEffective', dueAt: day(-9));

        final kpis = await repo.kpis(const NcrFilters());

        expect(kpis.total, 3);
        expect(kpis.capaLinked, 3);
        expect(kpis.capaCoveragePct, 100);
        // Past due and not Closed/Rejected/VerifiedEffective.
        expect(kpis.capaOverdue, 1);
      },
    );

    test('a rejected CAPA does not count as coverage', () async {
      final i1 = await inspection();
      final id = await finding(i1);
      await capa(id, status: 'Rejected');

      final kpis = await repo.kpis(const NcrFilters());
      expect(kpis.capaLinked, 0);
      expect(kpis.capaCoveragePct, 0);
    });
  });

  group('filtering (22.4)', () {
    test('KPIs and rows describe the same population', () async {
      final weld = await inspection(dept: 'Welding');
      final paint = await inspection(dept: 'Painting');
      await finding(weld, severity: 'Critical');
      await finding(paint, severity: 'Minor');

      final filters = NcrFilters(depts: {'Welding'});
      expect((await repo.kpis(filters)).total, 1);
      expect((await repo.list(filters)).length, 1);
      expect(await repo.count(filters), 1);
    });

    test('multi-select narrows by every dimension at once', () async {
      final i1 = await inspection(dept: 'Welding');
      final i2 = await inspection(dept: 'Painting');
      await finding(
        i1,
        status: 'Open',
        severity: 'Critical',
        type: 'Observation',
      );
      await finding(i1, status: 'Closed', severity: 'Critical');
      await finding(i2, status: 'Open', severity: 'Major');

      final filters = NcrFilters(
        statuses: {'Open', 'Closed'},
        severities: {'Critical'},
        types: {'Observation'},
      );
      final rows = await repo.list(filters);

      expect(rows.length, 1);
      expect(rows.single.status, 'Open');
      expect(rows.single.severity, 'Critical');
    });

    test(
      'an assignedTo entry accepts either the id or the id|Name pair',
      () async {
        final i1 = await inspection();
        await finding(i1, assignedTo: 'u9', assignedToName: 'Zoe Fixer');
        await finding(i1, assignedTo: 'u8', assignedToName: 'Yan Other');

        final byId = await repo.list(const NcrFilters(assignedTo: {'u9'}));
        final byPair = await repo.list(
          const NcrFilters(assignedTo: {'u9|Zoe Fixer'}),
        );

        expect(byId.length, 1);
        expect(byPair.length, 1);
        expect(byId.single.assignedToName, 'Zoe Fixer');
      },
    );

    test('the date range applies to the column the caller picked', () async {
      final i1 = await inspection(inspectionDate: day(-2));
      await finding(i1, createdOffset: -40);
      await finding(i1, createdOffset: -2);

      final byCreated = NcrFilters(
        from: day(-30),
        to: day(0),
        dateField: NcrFilters.dateFieldCreated,
      );
      final byInspection = NcrFilters(
        from: day(-30),
        to: day(0),
        dateField: NcrFilters.dateFieldInspection,
      );

      expect((await repo.list(byCreated)).length, 1);
      expect((await repo.list(byInspection)).length, 2);
    });

    test('onlyOverdue keeps unresolved past-due rows only', () async {
      final i1 = await inspection();
      await finding(i1, status: 'Open', dueDate: day(-4));
      await finding(i1, status: 'Open', dueDate: day(9));
      await finding(
        i1,
        status: 'Closed',
        dueDate: day(-4),
        closedAt: stamp(-5),
      );

      final rows = await repo.list(const NcrFilters(onlyOverdue: true));

      expect(rows.length, 1);
      expect(rows.single.status, 'Open');
    });

    test('lot/batch/po are matched as substrings', () async {
      final i1 = await inspection();
      await db.update(
        'qc_inspections',
        {'lot_no': 'LOT-9001', 'batch_no': 'B-77', 'po_no': 'PO-5'},
        where: 'inspection_id = ?',
        whereArgs: [i1],
      );
      await finding(i1);

      expect((await repo.list(const NcrFilters(lotNo: '900'))).length, 1);
      expect((await repo.list(const NcrFilters(batchNo: 'B-'))).length, 1);
      expect((await repo.list(const NcrFilters(poNo: 'PO-'))).length, 1);
      expect((await repo.list(const NcrFilters(poNo: 'nope'))).length, 0);
    });

    test('clearing filters widens the result set again', () async {
      final i1 = await inspection();
      await finding(i1, status: 'Open');
      await finding(i1, status: 'Closed');

      expect((await repo.list(const NcrFilters(statuses: {'Open'}))).length, 1);
      expect((await repo.list(const NcrFilters())).length, 2);
    });
  });

  group('projection (22.2)', () {
    test(
      'CAPA context is joined through finding_id, not findings.capa_id',
      () async {
        final i1 = await inspection();
        final id = await finding(i1);
        await capa(id, status: 'InProgress', dueAt: day(4));

        final row = (await repo.list(const NcrFilters())).single;

        // `qc_findings_nc.capa_id` is never written by the app, so joining on it
        // would leave every report row without its CAPA.
        expect(
          await db
              .query('qc_findings_nc', where: 'finding_id = ?', whereArgs: [id])
              .then((r) => r.single['capa_id']),
          isNull,
        );
        expect(row.capaId, isNotNull);
        expect(row.capaStatus, 'InProgress');
        expect(row.capaDueAt, day(4));
        expect(row.hasCapa, isTrue);
      },
    );

    test(
      'a soft-deleted finding is excluded but a deleted CAPA still joins',
      () async {
        final i1 = await inspection();
        final live = await finding(i1, code: 'LIVE');
        final dead = await finding(i1, code: 'DEAD', deleted: true);
        await capa(live, status: 'Open');
        await capa(dead, status: 'Open');

        final rows = await repo.list(const NcrFilters());

        expect(rows.length, 1);
        expect(rows.single.code, 'LIVE');
        expect(rows.single.capaId, isNotNull);
      },
    );

    test('a finding whose inspection was deleted is not reportable', () async {
      final live = await inspection(lot: 'KEEP');
      final gone = await inspection(lot: 'GONE', deleted: true);
      await finding(live);
      await finding(gone);

      final rows = await repo.list(const NcrFilters());

      expect(rows.length, 1);
      expect(rows.single.lotNo, 'KEEP');
    });

    test(
      'missing scalars arrive as empty, never as the string "null"',
      () async {
        final i1 = await inspection(inspectorId: '', inspectorName: '');
        await finding(i1);

        final row = (await repo.list(const NcrFilters())).single;

        expect(row.code, '');
        expect(row.assignedTo, '');
        expect(row.capaNo, '');
        expect(row.inspectorName, '');
        expect(row.qtyAffected, -1);
        expect(row.capaIsEffective, isFalse);
      },
    );

    test(
      'detail returns one row with context, and null once deleted',
      () async {
        final i1 = await inspection(lot: 'LOT-D');
        final id = await finding(i1, code: 'NC-77');

        final found = await repo.detail(id);
        expect(found!.findingId, id);
        expect(found.code, 'NC-77');
        expect(found.lotNo, 'LOT-D');
        expect(found.reference, 'NC-77');

        await db.update(
          'qc_findings_nc',
          {'deleted_at': stamp(0)},
          where: 'finding_id = ?',
          whereArgs: [id],
        );
        expect(await repo.detail(id), isNull);
      },
    );

    test('detail hides a finding whose inspection was deleted', () async {
      // The report's whole value is the lot/batch/inspector context, so an NCR
      // under a deleted inspection is excluded from the table. Detail must use
      // that same population, or a row the table would never list is still
      // reachable by id - with an empty context, which reads as data loss.
      final i1 = await inspection(lot: 'LOT-GONE');
      final id = await finding(i1, code: 'NC-ORPHAN');

      expect((await repo.detail(id))!.lotNo, 'LOT-GONE');

      await db.update(
        'qc_inspections',
        {'deleted_at': stamp(0)},
        where: 'inspection_id = ?',
        whereArgs: [i1],
      );

      expect(await repo.detail(id), isNull);
      expect(await repo.list(const NcrFilters()), isEmpty);
    });

    test('a row with no code still gets a human reference', () async {
      final i1 = await inspection();
      final id = await finding(i1, code: '');
      expect((await repo.detail(id))!.reference, 'NC-$id');
    });

    test('ordering is stable and an unknown sort column falls back', () async {
      final i1 = await inspection();
      await finding(i1, createdOffset: -3, severity: 'Minor');
      await finding(i1, createdOffset: -1, severity: 'Critical');

      final desc = await repo.list(const NcrFilters());
      final asc = await repo.list(const NcrFilters(), orderDir: 'ASC');
      expect(desc.first.findingId, greaterThan(desc.last.findingId));
      expect(asc.first.findingId, lessThan(asc.last.findingId));

      // Injection attempt: an unknown column is ignored, not interpolated.
      final junk = await repo.list(
        const NcrFilters(),
        orderBy: '1; DROP TABLE qc_findings_nc; --',
      );
      expect(junk.length, 2);
      expect((await repo.count(const NcrFilters())), 2);
    });

    test('paging returns disjoint pages that cover everything', () async {
      final i1 = await inspection();
      for (var n = 0; n < 5; n++) {
        await finding(i1, description: 'defect $n');
      }

      final first = await repo.list(const NcrFilters(), limit: 2, offset: 0);
      final second = await repo.list(const NcrFilters(), limit: 2, offset: 2);
      final third = await repo.list(const NcrFilters(), limit: 2, offset: 4);

      expect(first.length, 2);
      expect(second.length, 2);
      expect(third.length, 1);
      expect({...first, ...second, ...third}.map((r) => r.findingId).length, 5);
      expect(await repo.count(const NcrFilters()), 5);
    });
  });

  group('aging buckets (22.3)', () {
    test('all five bands are always returned, zero-filled', () async {
      final buckets = await repo.agingBuckets(const NcrFilters());

      expect(buckets.map((b) => b.label), [
        '0-7 days',
        '8-14 days',
        '15-30 days',
        '31-60 days',
        '>60 days',
      ]);
      expect(buckets.every((b) => b.count == 0), isTrue);
    });

    test(
      'open findings age from today, closed ones from their closure',
      () async {
        final i1 = await inspection();
        await finding(i1, createdOffset: -2); // 2 days old
        await finding(i1, createdOffset: -10); // 10 days old
        await finding(i1, createdOffset: -20); // 20
        await finding(i1, createdOffset: -45); // 45
        await finding(i1, createdOffset: -90); // 90
        // Raised 90 days ago, closed 1 day ago -> ages into the first band, not
        // the last, which is what "closed findings age from closure" means.
        await finding(
          i1,
          status: 'Closed',
          createdOffset: -90,
          closedAt: stamp(-1),
        );

        final buckets = await repo.agingBuckets(const NcrFilters());

        expect(buckets[0].count, 2); // 2 days + the just-closed one
        expect(buckets[1].count, 1);
        expect(buckets[2].count, 1);
        expect(buckets[3].count, 1);
        expect(buckets[4].count, 1);
        expect(buckets.fold<int>(0, (sum, b) => sum + b.count), 6);
      },
    );

    test('buckets are inclusive on both bounds', () async {
      const bucket = NcrAgingBucket.over60(0);
      expect(bucket.contains(61), isTrue);
      expect(bucket.contains(1000), isTrue);
      expect(bucket.contains(60), isFalse);
      expect(const NcrAgingBucket.d0to7(0).contains(7), isTrue);
      expect(const NcrAgingBucket.d0to7(0).contains(8), isFalse);
    });
  });

  group('top defects and repeat references (22.3)', () {
    test('top defects group by code, falling back to category', () async {
      final i1 = await inspection();
      await finding(i1, code: 'D-01', severity: 'Critical');
      await finding(i1, code: 'D-01');
      await finding(i1, code: 'D-01');
      await finding(i1, code: 'D-02');
      await finding(i1, category: 'Appearance');
      await finding(i1, category: 'Appearance');
      await finding(i1);

      final defects = await repo.topDefects(const NcrFilters());

      expect(defects.first.code, 'D-01');
      expect(defects.first.count, 3);
      expect(defects.first.criticalCount, 1);
      expect(defects.map((d) => d.label), contains('Appearance'));
      expect(defects.map((d) => d.label), contains('(uncoded)'));
      // Sorted by count, then by label, so two runs of the same report are
      // byte-identical instead of shuffling tied defects between pages.
      for (var n = 1; n < defects.length; n++) {
        final prev = defects[n - 1];
        final curr = defects[n];
        expect(
          prev.count > curr.count ||
              (prev.count == curr.count &&
                  prev.label.compareTo(curr.label) <= 0),
          isTrue,
          reason: '$prev should not sort after $curr',
        );
      }
    });

    test('a code wins over its category when grouping', () async {
      final i1 = await inspection();
      await finding(i1, code: 'D-01', category: 'Weld');
      await finding(i1, code: 'D-02', category: 'Weld');

      final defects = await repo.topDefects(const NcrFilters());
      expect(defects.map((d) => d.label), ['D-01', 'D-02']);
    });

    test('top defects respects the limit', () async {
      final i1 = await inspection();
      for (final code in ['A', 'B', 'C']) {
        await finding(i1, code: code);
      }
      expect((await repo.topDefects(const NcrFilters(), limit: 2)).length, 2);
    });

    test(
      'repeat refs only list lots/batches/refs with more than one NCR',
      () async {
        final shared = await inspection(lot: 'LOT-REPEAT');
        final single = await inspection(lot: 'LOT-ONCE');
        final noRef = await inspection();
        await db.update(
          'qc_inspections',
          {'lot_no': ''},
          where: 'inspection_id = ?',
          whereArgs: [noRef],
        );
        await finding(shared);
        await finding(shared);
        await finding(shared, status: 'Closed');
        await finding(single);
        await finding(noRef);
        await finding(noRef);

        final repeats = await repo.repeatByRef(const NcrFilters());

        expect(repeats.length, 1);
        expect(repeats.single.refKey, 'lot:LOT-REPEAT');
        expect(repeats.single.count, 3);
        expect(repeats.single.openCount, 2);
      },
    );

    test('a batch is used when there is no lot', () async {
      final i1 = await inspection();
      await db.update(
        'qc_inspections',
        {'lot_no': '', 'batch_no': 'B-1'},
        where: 'inspection_id = ?',
        whereArgs: [i1],
      );
      await finding(i1);
      await finding(i1);

      expect(
        (await repo.repeatByRef(const NcrFilters())).single.refKey,
        'batch:B-1',
      );
    });

    test(
      'a bare reference id is used when there is neither lot nor batch',
      () async {
        final i1 = await inspection();
        await db.update(
          'qc_inspections',
          {'lot_no': '', 'ref_id': 'JOB-77'},
          where: 'inspection_id = ?',
          whereArgs: [i1],
        );
        await finding(i1);
        await finding(i1);

        expect(
          (await repo.repeatByRef(const NcrFilters())).single.refKey,
          'ref:JOB-77',
        );
      },
    );
  });

  group('filter options', () {
    test('facets are de-duplicated, sorted and non-empty', () async {
      final i1 = await inspection(
        dept: 'Welding',
        inspectorId: 'u1',
        inspectorName: 'Ann',
      );
      final i2 = await inspection(
        dept: 'Welding',
        inspectorId: 'u2',
        inspectorName: 'Bob',
      );
      await db.update(
        'qc_inspections',
        {'dept': 'Painting'},
        where: 'inspection_id = ?',
        whereArgs: [i2],
      );
      await finding(
        i1,
        status: 'Open',
        severity: 'Critical',
        category: 'Weld',
        assignedTo: 'u1',
        assignedToName: 'Ann',
      );
      await finding(
        i1,
        status: 'Open',
        severity: 'Critical',
        category: 'Weld',
        assignedTo: 'u1',
        assignedToName: 'Ann',
      );
      final id = await finding(i2, status: 'Closed', severity: 'Minor');
      await capa(id, status: 'Closed');

      final options = await repo.filterOptions();

      expect(options.statuses, ['Closed', 'Open']);
      expect(options.severities, ['Critical', 'Minor']);
      expect(options.categories, ['Weld']);
      expect(options.depts, ['Painting', 'Welding']);
      expect(options.capaStatuses, ['Closed']);
      expect(options.inspectors.map((p) => p.id), ['u1', 'u2']);
      expect(options.assignees.single, (id: 'u1', name: 'Ann'));
      expect(options.isEmpty, isFalse);
    });

    test('facets ignore soft-deleted rows', () async {
      final i1 = await inspection(dept: 'Ghost');
      await db.update(
        'qc_inspections',
        {'deleted_at': stamp(0)},
        where: 'inspection_id = ?',
        whereArgs: [i1],
      );
      await finding(i1, category: 'Weld');

      final options = await repo.filterOptions();

      expect(options.depts, isEmpty);
      expect(options.categories, isEmpty);
      expect(options.isEmpty, isTrue);
    });
  });

  group('NcrReportRow date helpers', () {
    test('closedOnTime needs both a due date and a closure stamp', () async {
      final i1 = await inspection();
      expect(
        (await repo.detail(
          await finding(
            i1,
            status: 'Closed',
            closedAt: stamp(-1),
            dueDate: day(-1),
          ),
        ))!.closedOnTime,
        isTrue,
      );
      expect(
        (await repo.detail(
          await finding(i1, status: 'Closed', closedAt: stamp(-1)),
        ))!.closedOnTime,
        isFalse,
      );
      expect(
        (await repo.detail(
          await finding(i1, status: 'Open', dueDate: day(0)),
        ))!.closedOnTime,
        isFalse,
      );
    });

    test('isOverdue only fires on unresolved rows', () async {
      final i1 = await inspection();
      expect(
        (await repo.detail(
          await finding(i1, status: 'Open', dueDate: day(-2)),
        ))!.isOverdue,
        isTrue,
      );
      expect(
        (await repo.detail(
          await finding(i1, status: 'Open', dueDate: day(2)),
        ))!.isOverdue,
        isFalse,
      );
      expect(
        (await repo.detail(
          await finding(
            i1,
            status: 'Closed',
            dueDate: day(-2),
            closedAt: stamp(-3),
          ),
        ))!.isOverdue,
        isFalse,
      );
    });

    test(
      'ageDays is null until the finding reaches a terminal state',
      () async {
        final i1 = await inspection();
        final open = await repo.detail(await finding(i1, createdOffset: -9));
        expect(open!.ageDays, isNull);
        expect(open.openDays, 9);
        expect(open.isOpen, isTrue);

        final closed = await repo.detail(
          await finding(
            i1,
            status: 'Closed',
            createdOffset: -9,
            closedAt: stamp(-2),
          ),
        );
        expect(closed!.ageDays, 7);
        expect(closed.openDays, isNull);
        expect(closed.isOpen, isFalse);
      },
    );

    test(
      'a closure stamped before it was raised is clamped, not negative',
      () async {
        final i1 = await inspection();
        final row = await repo.detail(
          await finding(
            i1,
            status: 'Closed',
            createdOffset: -2,
            closedAt: stamp(-9),
          ),
        );
        expect(row!.ageDays, 0);
      },
    );
  });
}
