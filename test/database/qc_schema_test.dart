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
    'qc_custom_tables',
    'qc_custom_table_fields',
    'qc_custom_table_rows',
  ];

  /// Indexes the NCR report and the register screens depend on for their queries.
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
    'qc_custom_tables': ['idx_qc_custom_tables_deleted'],
    'qc_custom_table_fields': ['idx_qc_custom_fields_table'],
    'qc_custom_table_rows': [
      'idx_qc_custom_rows_table',
      'idx_qc_custom_rows_recorded',
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
    await first.insert('qc_defect_codes', {
      'code': 'D-001',
      'name': 'Moisture above limit',
    });
    await helper.close();

    // Second open re-runs `_createSchema`; every statement is `IF NOT EXISTS`
    // so this must neither throw nor duplicate anything.
    final second = await helper.database;
    expect(await second.query('qc_defect_codes'), hasLength(1));
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

  test('a legacy qc_findings_nc is rebuilt to allow standalone findings',
      () async {
    // The NCR create window raises findings with no inspection linked. A NULL
    // child key satisfies the FK to qc_inspections, but the column shipped as
    // NOT NULL, so pre-existing installs carry it and every standalone save
    // would trip the FK. Simulated like such an install: rebuild the table
    // with the legacy DDL, seed it, close, and let the every-open guarantee
    // run the guarded rebuild.
    final first = await helper.database;
    await first.execute('DROP TABLE qc_capa');
    await first.execute('DROP TABLE qc_findings_nc');
    await first.execute('''
      CREATE TABLE qc_findings_nc (
        finding_id INTEGER PRIMARY KEY AUTOINCREMENT,
        inspection_id INTEGER NOT NULL,
        item_id INTEGER,
        resp_id INTEGER,
        code TEXT,
        severity TEXT CHECK(severity IN ('Minor','Major','Critical')) NOT NULL,
        category TEXT,
        description TEXT NOT NULL,
        status TEXT CHECK(status IN ('Open','Assigned','InProgress','Verified','Closed','Rejected')) DEFAULT 'Open',
        type TEXT CHECK(type IN ('NonConformance','Observation','Deviation')) DEFAULT 'NonConformance',
        due_date TEXT,
        assigned_to TEXT,
        assigned_to_name TEXT,
        assigned_at TEXT,
        root_cause TEXT,
        action_plan TEXT,
        proposed_action TEXT,
        qty_affected REAL,
        qty_unit TEXT,
        disposition TEXT CHECK(disposition IN ('Rework','Scrap','UseAsIs','Return','Concession','Pending')) DEFAULT 'Pending',
        verified_by TEXT,
        verified_by_name TEXT,
        verified_at TEXT,
        closed_at TEXT,
        closed_by TEXT,
        rejected_at TEXT,
        rejection_reason TEXT,
        evidence_json TEXT,
        capa_id INTEGER,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        FOREIGN KEY(inspection_id) REFERENCES qc_inspections(inspection_id) ON DELETE CASCADE,
        FOREIGN KEY(resp_id) REFERENCES qc_responses(resp_id)
      )
    ''');
    await first.execute('''
      CREATE TABLE qc_capa (
        capa_id INTEGER PRIMARY KEY AUTOINCREMENT,
        finding_id INTEGER UNIQUE,
        type TEXT CHECK(type IN ('Corrective','Preventive')) NOT NULL,
        action_plan TEXT,
        root_cause TEXT,
        status TEXT CHECK(status IN ('Open','InProgress','Verified','Closed','Rejected')) DEFAULT 'Open',
        priority TEXT CHECK(priority IN ('Low','Medium','High')) DEFAULT 'Medium',
        due_at TEXT,
        assigned_to TEXT,
        assigned_to_name TEXT,
        target_completion_at TEXT,
        action_completed_at TEXT,
        is_effective INTEGER DEFAULT 0,
        effectiveness_checked_at TEXT,
        effectiveness_notes TEXT,
        closure_notes TEXT,
        closed_at TEXT,
        closed_by TEXT,
        rejected_at TEXT,
        rejection_reason TEXT,
        evidence_json TEXT,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        created_by TEXT,
        updated_by TEXT,
        FOREIGN KEY(finding_id) REFERENCES qc_findings_nc(finding_id) ON DELETE CASCADE
      )
    ''');
    final templateId = await first.insert('qc_templates', {
      'name': 'Legacy template',
      'created_at': '2026-02-01 08:00:00',
      'updated_at': '2026-02-01 08:00:00',
    });
    final inspectionId = await first.insert('qc_inspections', {
      'template_id': templateId,
      'inspection_date': '2026-02-02',
      'created_at': '2026-02-02 09:00:00',
      'updated_at': '2026-02-02 09:00:00',
    });
    await first.insert('qc_findings_nc', {
      'inspection_id': inspectionId,
      'severity': 'Major',
      'description': 'Legacy linked finding',
      'status': 'Closed',
      'created_at': '2026-02-02 09:00:00',
      'updated_at': '2026-02-02 09:00:00',
    });
    final storedSql = await first.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' "
      "AND name = 'qc_findings_nc'",
    );
    // ignore: avoid_print
    print('SQL_AT_CLOSE: '
        '${'${storedSql.first['sql']}'.replaceAll('\n', ' ')}');
    await helper.close();

    final reopened = await helper.database;

    // The constraint itself is gone, not just bypassed.
    final cols = await reopened.rawQuery('PRAGMA table_info(qc_findings_nc)');
    final inspectionCol = cols.singleWhere((c) => c['name'] == 'inspection_id');
    expect(inspectionCol['notnull'], 0);

    // ...the legacy rows travelled with the rebuild...
    final rows = await reopened.query('qc_findings_nc');
    expect(rows, hasLength(1));
    expect(rows.single['description'], 'Legacy linked finding');
    expect(rows.single['status'], 'Closed');

    // ...and the AUTOINCREMENT sequence does not reuse legacy ids.
    final nextId = await reopened.insert('qc_findings_nc', {
      'inspection_id': null,
      'severity': 'Minor',
      'description': 'Standalone after migration',
      'status': 'Open',
      'created_at': '2026-02-03 09:00:00',
      'updated_at': '2026-02-03 09:00:00',
    });
    expect(nextId, greaterThan(1));

    // The FK stays: a NULL child is a standalone finding, but garbage ids
    // are still rejected.
    expect(
      () => reopened.insert('qc_findings_nc', {
        'inspection_id': 4242,
        'severity': 'Minor',
        'description': 'Not an inspection',
        'created_at': '2026-02-03 09:00:00',
        'updated_at': '2026-02-03 09:00:00',
      }),
      throwsA(isA<Exception>()),
    );
  });

  test('a custom table cascades away with its columns and records', () async {
    final db = await helper.database;
    final tableId = await db.insert('qc_custom_tables', {
      'remote_id': 'tbl-remote-1',
      'title': 'Sample weights',
      'created_at': '2026-01-01 08:00:00',
      'updated_at': '2026-01-01 08:00:00',
    });
    final fieldId = await db.insert('qc_custom_table_fields', {
      'table_id': tableId,
      'table_remote_id': 'tbl-remote-1',
      'remote_id': 'fld-remote-1',
      'label': 'Weight',
      'col_type': 'number',
      'required': 1,
      'sort_order': 0,
      'created_at': '2026-01-01 08:00:00',
      'updated_at': '2026-01-01 08:00:00',
    });
    await db.insert('qc_custom_table_rows', {
      'table_id': tableId,
      'table_remote_id': 'tbl-remote-1',
      'remote_id': 'row-remote-1',
      'values_json': '{"fld-remote-1": 12.5}',
      'recorded_at': '2026-01-02 09:00:00',
      'created_at': '2026-01-02 09:00:00',
      'updated_at': '2026-01-02 09:00:00',
    });

    // The column type CHECK is what stops a drift between devices from
    // writing an unrepresentable value.
    expect(
      () => db.insert('qc_custom_table_fields', {
        'table_id': tableId,
        'table_remote_id': 'tbl-remote-1',
        'remote_id': 'fld-remote-2',
        'label': 'Photo',
        'col_type': 'image',
        'required': 0,
        'sort_order': 1,
        'created_at': '2026-01-01 08:00:00',
        'updated_at': '2026-01-01 08:00:00',
      }),
      throwsA(isA<Exception>()),
      reason: 'only number/text/date columns can sync as plain values',
    );

    expect(await db.query('qc_custom_table_fields'), hasLength(1));
    expect(await db.query('qc_custom_table_rows'), hasLength(1));
    await db.delete(
      'qc_custom_tables',
      where: 'table_id = ?',
      whereArgs: [tableId],
    );
    expect(
      await db.query('qc_custom_table_fields'),
      isEmpty,
      reason: 'FK cascade must take the columns with the table',
    );
    expect(
      await db.query('qc_custom_table_rows'),
      isEmpty,
      reason: 'FK cascade must take the records with the table',
    );
    expect(fieldId, greaterThan(0));
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
    'qc_custom_table_rows',
    'qc_custom_table_fields',
    'qc_custom_tables',
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
    // without them, and the first QC query failed with "no such table" - a
    // crash that no fresh-install test or type check would catch.
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
    expect(await tablesOf(first), isNot(contains('qc_inspections')));
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
    final inspectionIndexes = await indexNamesOn(third, 'qc_inspections');
    expect(inspectionIndexes.where((n) => n == 'idx_qc_insps_status'), hasLength(1));
  });
}
