import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/qc_manager/domain/qc_audit.dart';
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

typedef _FromMap = Object Function(Map<String, dynamic> row);

/// Binds every QC model to the table it claims to map.
///
/// Two properties are checked per model, and both are the kind of thing the
/// analyzer is blind to:
///
///  * every key `toMap()` emits is a real column. A model that writes `id`
///    where the table has `inspection_id` inserts fine and then reads back null
///    forever after.
///  * `fromMap(toMap(fromMap(row))) == fromMap(row)`. Fields dropped in either
///    direction - a `toMap` that forgets `completed_by`, a `fromMap` that never
///    reads it - are invisible until someone needs that field back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late Database db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_qc_models');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Model, table, and the primary key column, which is spelled differently in
  /// almost every table (`rev_id`, `resp_id`, `assign_id`, ...).
  final bindings = <String, ({_FromMap fromMap, String table, String pk})>{
    'QcSop': (fromMap: QcSop.fromMap, table: 'qc_sops', pk: 'sop_id'),
    'QcSopRevision': (
      fromMap: QcSopRevision.fromMap,
      table: 'qc_sop_revisions',
      pk: 'rev_id',
    ),
    'QcSopRead': (fromMap: QcSopRead.fromMap, table: 'qc_sop_reads', pk: 'id'),
    'QcSopAudit': (
      fromMap: QcSopAudit.fromMap,
      table: 'qc_sop_audits',
      pk: 'id',
    ),
    'QcTemplate': (
      fromMap: QcTemplate.fromMap,
      table: 'qc_templates',
      pk: 'template_id',
    ),
    'QcSection': (
      fromMap: QcSection.fromMap,
      table: 'qc_sections',
      pk: 'section_id',
    ),
    'QcItem': (fromMap: QcItem.fromMap, table: 'qc_items', pk: 'item_id'),
    'QcInspection': (
      fromMap: QcInspection.fromMap,
      table: 'qc_inspections',
      pk: 'inspection_id',
    ),
    'QcResponse': (
      fromMap: QcResponse.fromMap,
      table: 'qc_responses',
      pk: 'resp_id',
    ),
    'QcFindingNc': (
      fromMap: QcFindingNc.fromMap,
      table: 'qc_findings_nc',
      pk: 'finding_id',
    ),
    'QcCapa': (fromMap: QcCapa.fromMap, table: 'qc_capa', pk: 'capa_id'),
    'QcDefectCode': (
      fromMap: QcDefectCode.fromMap,
      table: 'qc_defect_codes',
      pk: 'id',
    ),
    'QcAudit': (fromMap: QcAudit.fromMap, table: 'qc_audits', pk: 'id'),
    'QcGoal': (fromMap: QcGoal.fromMap, table: 'qc_goals', pk: 'goal_id'),
    'QcGoalAssignment': (
      fromMap: QcGoalAssignment.fromMap,
      table: 'qc_goal_assignments',
      pk: 'assign_id',
    ),
    'QcGoalAction': (
      fromMap: QcGoalAction.fromMap,
      table: 'qc_goal_actions',
      pk: 'action_id',
    ),
    'QcGoalKpi': (
      fromMap: QcGoalKpi.fromMap,
      table: 'qc_goal_kpis',
      pk: 'kpi_id',
    ),
    'QcGoalLink': (
      fromMap: QcGoalLink.fromMap,
      table: 'qc_goal_links',
      pk: 'link_id',
    ),
  };

  Future<List<Map<String, Object?>>> columnsOf(String table) =>
      db.rawQuery('PRAGMA table_info($table)');

  /// A plausible value for [col], keyed off its declared type and name.
  ///
  /// Values are deliberately odd rather than tidy: the point is to catch a field
  /// that is dropped, not to be realistic. JSON columns get valid JSON because
  /// the models parse them on the way in.
  Object valueFor(Map<String, Object?> col) {
    final name = '${col['name']}';
    final type = '${col['type']}'.toUpperCase();
    final isPk = col['pk'] == 1;

    if (name.endsWith('_json')) return '[]';
    if (type.contains('INT')) {
      if (isPk) return 7;
      if (name.startsWith('is_') || name == 'active') return 1;
      if (name == 'version' || name == 'order_index') return 1;
      return 3;
    }
    if (type.contains('REAL') ||
        type.contains('FLOA') ||
        type.contains('DOUB')) {
      return 2.5;
    }
    if (name.endsWith('_at') ||
        name.endsWith('_date') ||
        name == 'at' ||
        name == 'rev_no') {
      return '2026-02-03';
    }
    return name;
  }

  test('every model is bound to a distinct table', () {
    final tables = bindings.values.map((b) => b.table).toList();
    expect(
      tables.toSet(),
      hasLength(tables.length),
      reason: 'two models are pointed at the same table',
    );
    expect(bindings, hasLength(18), reason: 'a QC model was left unbound');
  });

  for (final entry in bindings.entries) {
    final name = entry.key;
    final binding = entry.value;

    test('$name writes only real ${binding.table} columns', () async {
      final cols = await columnsOf(binding.table);
      expect(cols, isNotEmpty, reason: '${binding.table} does not exist');
      final columnNames = cols.map((c) => '${c['name']}').toSet();

      final row = <String, dynamic>{
        for (final c in cols) '${c['name']}': valueFor(c),
      };
      final model = binding.fromMap(row) as dynamic;
      final emitted = (model.toMap() as Map).keys.cast<String>().toSet();

      expect(
        emitted.difference(columnNames),
        isEmpty,
        reason:
            '$name emits keys that are not columns of ${binding.table}. '
            'The insert will fail, or the value will be dropped silently. '
            'Extra: ${emitted.difference(columnNames)}',
      );

      // The primary key is the one place a typo is invisible in both
      // directions, because the model omits it entirely when null.
      expect(
        columnNames,
        contains(binding.pk),
        reason: '${binding.table} has no primary key column ${binding.pk}',
      );
    });

    test('$name survives a toMap/fromMap round trip', () async {
      final cols = await columnsOf(binding.table);
      final row = <String, dynamic>{
        for (final c in cols) '${c['name']}': valueFor(c),
      };

      final once = binding.fromMap(row);
      final twice = binding.fromMap(
        (once as dynamic).toMap() as Map<String, dynamic>,
      );

      expect(
        twice,
        equals(once),
        reason: '$name loses or rewrites a field across a round trip',
      );
    });
  }
}
