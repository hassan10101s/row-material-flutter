import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Pins the QC Manager schema (plan V6 §5.2 + V6_ENHANCED §12.1).
///
/// The QC tables are created from `_createSchema` rather than `onUpgrade`,
/// because the schema version is pinned at 1 and `onUpgrade` therefore never
/// fires - so "the tables exist" is a property of every open and has to be
/// tested on every open, not once per upgrade.
///
/// The index assertions are the reason this file exists at all. SQLite resolves
/// an index's columns at CREATE time, so an index naming a column that does not
/// exist makes **every subsequent open of every database fail** - not just the
/// QC code. A single mistyped `id` for `inspection_id` took the whole test
/// suite down with it, which no amount of type checking would have caught.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_qc_schema');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Every QC table, in creation order (parents before children, because the
  /// child FKs have to resolve as the parents appear).
  const qcTables = [
    'qc_sops',
    'qc_sop_revisions',
    'qc_sop_reads',
    'qc_sop_audits',
    'qc_templates',
    'qc_sections',
    'qc_items',
    'qc_inspections',
    'qc_responses',
    'qc_findings_nc',
    'qc_capa',
    'qc_audits',
    'qc_defect_codes',
    'qc_goals',
    'qc_goal_assignments',
    'qc_goal_actions',
    'qc_goal_kpis',
    'qc_goal_links',
  ];

  /// Indexes the NCR report and the goal screens depend on for their queries.
  /// Each is listed with the table it must exist on, so a rename that silently
  /// drops the index shows up as a missing name rather than a slow screen.
  const requiredIndexes = {
    'qc_sops': [
      'idx_qc_sops_code',
      'idx_qc_sops_status',
      'idx_qc_sops_deleted',
    ],
    'qc_inspections': [
      'idx_qc_insps_date',
      'idx_qc_insps_ref',
      'idx_qc_insps_lot',
      'idx_qc_insps_status',
    ],
    'qc_findings_nc': [
      'idx_qc_findings_status_sev',
      'idx_qc_findings_due',
      'idx_qc_findings_assigned',
    ],
    'qc_capa': [
      'idx_qc_capa_status',
      'idx_qc_capa_assigned',
      'idx_qc_capa_due',
    ],
    'qc_audits': [
      'idx_qc_audits_entity',
      'idx_qc_audits_at',
      'idx_qc_audits_actor',
    ],
    'qc_goals': [
      'idx_qc_goals_status',
      'idx_qc_goals_owner',
      'idx_qc_goals_due',
    ],
    'qc_goal_assignments': [
      'idx_qc_goal_assign_goal',
      'idx_qc_goal_assign_user',
    ],
  };

  Future<Set<String>> tablesOf(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    return rows.map((r) => '${r['name']}').toSet();
  }

  Future<Set<String>> indexNamesOn(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA index_list($table)');
    return rows.map((r) => '${r['name']}').toSet();
  }

  test('every qc_ table is created on a fresh database', () async {
    final db = await helper.database;
    final tables = await tablesOf(db);
    expect(tables, containsAll(qcTables));
  });

  test('every qc_ index resolves against real columns', () async {
    final db = await helper.database;

    for (final entry in requiredIndexes.entries) {
      final present = await indexNamesOn(db, entry.key);
      expect(
        present,
        containsAll(entry.value),
        reason: '${entry.key} is missing indexes the reports rely on',
      );
    }
  });

  test('no index anywhere in the schema names a missing column', () async {
    // The general form of the failure above: if any CREATE INDEX in the file
    // references a column that does not exist, this open throws. Reaching this
    // assertion at all is most of the test.
    final db = await helper.database;
    final broken = await db.rawQuery(
      "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index'",
    );
    expect(broken, isNotEmpty);
  });

  test('reopening is idempotent and keeps QC rows', () async {
    final first = await helper.database;
    await first.insert('qc_goals', {
      'code': 'G-TEST-1',
      'title': 'Close every critical NC within 5 days',
      'start_date': '2026-01-01',
      'due_date': '2026-03-31',
      'created_at': '2026-01-01 08:00:00',
      'updated_at': '2026-01-01 08:00:00',
    });
    await first.insert('qc_defect_codes', {
      'code': 'D-001',
      'name': 'Moisture above limit',
    });
    await helper.close();

    // Second open re-runs `_createSchema`; every statement is `IF NOT EXISTS`
    // so this must neither throw nor duplicate anything.
    final second = await helper.database;
    expect(await second.query('qc_goals'), hasLength(1));
    expect(await second.query('qc_defect_codes'), hasLength(1));
    expect(
      await indexNamesOn(second, 'qc_goals'),
      contains('idx_qc_goals_status'),
    );
  });

  test('a goal records who finished it and what they attached', () async {
    final db = await helper.database;
    final id = await db.insert('qc_goals', {
      'code': 'G-TEST-2',
      'title': 'Publish SOP-101 by Q2',
      'status': 'Completed',
      'priority': 'Critical',
      'start_date': '2026-04-01',
      'due_date': '2026-06-30',
      'completed_at': '2026-05-04 11:30:00',
      'completed_by': 'uid-of-hana',
      'completed_by_name': 'Hana',
      'completion_evidence_json': '["/photos/sop101.pdf"]',
      'created_at': '2026-04-01 08:00:00',
      'updated_at': '2026-05-04 11:30:00',
    });

    final row = (await db.query(
      'qc_goals',
      where: 'goal_id = ?',
      whereArgs: [id],
    )).single;
    expect(row['completed_by'], 'uid-of-hana');
    expect(row['completed_by_name'], 'Hana');
    expect(row['completed_at'], '2026-05-04 11:30:00');
    expect(row['completion_evidence_json'], contains('sop101.pdf'));
  });

  test('assignments are unique per person per goal', () async {
    final db = await helper.database;
    final goalId = await db.insert('qc_goals', {
      'code': 'G-TEST-3',
      'title': 'Goal with two people',
      'start_date': '2026-01-01',
      'created_at': '2026-01-01 08:00:00',
      'updated_at': '2026-01-01 08:00:00',
    });

    Map<String, Object?> assignment(String uid) => {
      'goal_id': goalId,
      'assignee_id': uid,
      'assignee_name': uid,
      'assigned_at': '2026-01-01 08:00:00',
      'created_at': '2026-01-01 08:00:00',
      'updated_at': '2026-01-01 08:00:00',
    };

    await db.insert('qc_goal_assignments', assignment('uid-a'));
    await db.insert('qc_goal_assignments', assignment('uid-b'));

    // Re-assigning the same person must not create a second row, or goal
    // progress would count them twice.
    expect(
      () => db.insert('qc_goal_assignments', assignment('uid-a')),
      throwsA(isA<Exception>()),
    );
    expect(
      await db.query(
        'qc_goal_assignments',
        where: 'goal_id = ?',
        whereArgs: [goalId],
      ),
      hasLength(2),
    );
  });

  test('a finding cascades away with its inspection', () async {
    final db = await helper.database;
    final templateId = await db.insert('qc_templates', {
      'name': 'Incoming RM check',
      'created_at': '2026-01-01 08:00:00',
      'updated_at': '2026-01-01 08:00:00',
    });
    final inspectionId = await db.insert('qc_inspections', {
      'template_id': templateId,
      'inspection_date': '2026-02-02',
      'created_at': '2026-02-02 09:00:00',
      'updated_at': '2026-02-02 09:00:00',
    });
    await db.insert('qc_findings_nc', {
      'inspection_id': inspectionId,
      'severity': 'Major',
      'description': 'Foreign matter in sample',
      'created_at': '2026-02-02 09:05:00',
      'updated_at': '2026-02-02 09:05:00',
    });

    expect(await db.query('qc_findings_nc'), hasLength(1));
    await db.delete(
      'qc_inspections',
      where: 'inspection_id = ?',
      whereArgs: [inspectionId],
    );
    expect(
      await db.query('qc_findings_nc'),
      isEmpty,
      reason: 'FK cascade must take the finding with the inspection',
    );
  });

  test('audit rows reject an unknown entity_type', () async {
    final db = await helper.database;
    expect(
      () => db.insert('qc_audits', {
        'entity_type': 'NOT_A_REAL_ENTITY',
        'entity_id': '1',
        'action': 'created',
        'at': '2026-02-02 09:00:00',
      }),
      throwsA(isA<Exception>()),
      reason:
          'the CHECK is what stops a typo from silently creating a gap '
          'in the audit trail',
    );
  });

  test('foreign keys are enforced', () async {
    final db = await helper.database;
    expect(
      () => db.insert('qc_capa', {
        'finding_id': 9999,
        'action_plan': 'Do the thing',
        'created_at': '2026-02-02 09:00:00',
        'updated_at': '2026-02-02 09:00:00',
      }),
      throwsA(isA<Exception>()),
    );
  });

  test('the pre-existing schema is untouched', () async {
    // P1 is additive: a database that already has data must keep it.
    final db = await helper.database;
    expect(
      await tablesOf(db),
      containsAll([
        'users',
        'inspections',
        'reference_materials',
        'lab_inventory',
        'material_parameter_bounds',
        'sync_queue',
        'audit_logs',
      ]),
    );
  });

  /// Child tables first, so the drop order never depends on FK enforcement.
  const qcTablesChildFirst = [
    'qc_goal_links',
    'qc_goal_kpis',
    'qc_goal_actions',
    'qc_goal_assignments',
    'qc_goals',
    'qc_defect_codes',
    'qc_audits',
    'qc_capa',
    'qc_findings_nc',
    'qc_responses',
    'qc_inspections',
    'qc_items',
    'qc_sections',
    'qc_templates',
    'qc_sop_audits',
    'qc_sop_reads',
    'qc_sop_revisions',
    'qc_sops',
  ];

  test('an existing database gains the qc_ tables on open', () async {
    // The regression this pins. The schema version is pinned at 1, so `onCreate`
    // and `onUpgrade` never fire for an already-installed app. Creating the QC
    // tables only from `_createSchema` therefore left every existing install
    // without them, and the first QC query failed with "no such table:
    // qc_goals" - a crash that no fresh-install test or type check would catch.
    //
    // Simulated by building a full database, stripping the QC tables back off,
    // and reopening: that is byte-for-byte what a pre-QC install looks like.
    final first = await helper.database;
    await first.insert('reference_materials', {
      'material_name': 'Kept from before QC existed',
      'material_code': 'RM-LEGACY-1',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': '2025-06-01 08:00:00',
    });
    for (final t in qcTablesChildFirst) {
      await first.execute('DROP TABLE IF EXISTS $t');
    }
    expect(await tablesOf(first), isNot(contains('qc_goals')));
    await helper.close();

    final reopened = await helper.database;

    expect(
      await tablesOf(reopened),
      containsAll(qcTables),
      reason: 'every QC table must be created by the every-open guarantee',
    );

    // ...together with their indexes, not just the tables.
    expect(
      await indexNamesOn(reopened, 'qc_inspections'),
      containsAll(requiredIndexes['qc_inspections']!),
    );
    expect(
      await indexNamesOn(reopened, 'qc_goals'),
      containsAll(requiredIndexes['qc_goals']!),
    );

    // ...and the install's own data is still there.
    final kept = (await reopened.query(
      'reference_materials',
      where: 'material_code = ?',
      whereArgs: ['RM-LEGACY-1'],
    ));
    expect(kept, hasLength(1));
    expect(kept.single['material_name'], 'Kept from before QC existed');
  });

  test('a second reopen after the upgrade stays a no-op', () async {
    final first = await helper.database;
    for (final t in qcTablesChildFirst) {
      await first.execute('DROP TABLE IF EXISTS $t');
    }
    await helper.close();

    await helper.database;
    await helper.close();
    final third = await helper.database;

    expect(await tablesOf(third), containsAll(qcTables));
    // Re-running `CREATE INDEX IF NOT EXISTS` over an existing index must not
    // fail or duplicate it.
    final goalIndexes = await indexNamesOn(third, 'qc_goals');
    expect(goalIndexes.where((n) => n == 'idx_qc_goals_status'), hasLength(1));
  });
}
