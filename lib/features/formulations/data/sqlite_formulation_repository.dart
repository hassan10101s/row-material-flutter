import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/shared_data_writer.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/formulation_calculator.dart';
import '../domain/formulation_repository.dart';

class SqliteFormulationRepository implements FormulationRepository {
  SqliteFormulationRepository({
    required this.dbHelper,
    required this.guard,
    required this.queue,
    required this.audit,
  });
  final DatabaseHelper dbHelper;
  final WriteGuard guard;
  final SyncQueue queue;
  final AuditLogger audit;

  @override
  Future<List<Map<String, dynamic>>> list({bool archived = false}) async {
    final db = await dbHelper.database;
    final rows = await db.query(
      'nutrition_formulations',
      where: 'deleted_at IS NULL AND is_archived = ?',
      whereArgs: [archived ? 1 : 0],
      orderBy: 'updated_at DESC, id DESC',
    );
    return [for (final row in rows) Map<String, dynamic>.from(row)];
  }

  @override
  Future<List<Map<String, dynamic>>> materials() async {
    final db = await dbHelper.database;
    final rows = await db.query(
      'reference_materials',
      columns: ['id', 'material_name', 'material_code'],
      where: 'active = 1 AND material_name != ?',
      whereArgs: [DatabaseHelper.productSentinelMaterialName],
      orderBy: 'material_name COLLATE NOCASE',
    );
    return [for (final row in rows) Map<String, dynamic>.from(row)];
  }

  @override
  Future<List<Map<String, dynamic>>> products() async {
    final db = await dbHelper.database;
    final rows = await db.query(
      'lab_products',
      columns: ['id', 'name'],
      where: 'active = 1 AND deleted_at IS NULL',
      orderBy: 'name COLLATE NOCASE',
    );
    return [for (final row in rows) Map<String, dynamic>.from(row)];
  }

  @override
  Future<List<Map<String, dynamic>>> parameters() async {
    final db = await dbHelper.database;
    final rows = await db.rawQuery('''
      SELECT p.id, p.parameter_name, COALESCE(p.unit, '') AS unit
      FROM parameters p
      WHERE EXISTS (SELECT 1 FROM lab_analyses a
        WHERE a.parameter_id = p.id AND a.active = 1)
      ORDER BY p.parameter_name COLLATE NOCASE
    ''');
    return [for (final row in rows) Map<String, dynamic>.from(row)];
  }

  dynamic _decode(Object? value) {
    try {
      return value is String && value.isNotEmpty ? jsonDecode(value) : {};
    } on FormatException {
      return {};
    }
  }

  DateTime? _date(Object? value) {
    final date = DateTime.tryParse('$value');
    return date == null ? null : DateTime(date.year, date.month, date.day);
  }

  String _key(String name) {
    return formulationParameterKey(name);
  }

  @override
  Future<List<MaterialReceipt>> receipts(
    List<int> materialIds,
    DateTime from,
    DateTime to,
  ) async {
    if (materialIds.isEmpty) return [];
    final db = await dbHelper.database;
    final ids = materialIds.toSet().toList();
    final marks = List.filled(ids.length, '?').join(',');
    final end = to.toIso8601String().substring(0, 10);
    final rows = await db.rawQuery(
      '''
      SELECT i.id, i.material_id, i.entry_code, i.inspection_date,
        i.chemical_results_json, i.physical_results_json, i.decision_status
      FROM inspections i
      WHERE i.inspection_kind = 'raw' AND i.deleted_at IS NULL
        AND i.decision_status IN ('APPROVED','CONDITIONAL_APPROVAL','PARTIAL_REJECTION')
        AND i.material_id IN ($marks) AND date(i.inspection_date) <= date(?)
      ORDER BY date(i.inspection_date), i.id
    ''',
      [...ids, end],
    );
    final testRows = <Map<String, Object?>>[];
    for (var offset = 0; offset < rows.length; offset += 250) {
      final codes = rows
          .skip(offset)
          .take(250)
          .map((row) => '${row['entry_code']}')
          .where((code) => code.isNotEmpty)
          .toList();
      if (codes.isEmpty) continue;
      final tests = await db.rawQuery(
        '''
        SELECT t.entry_code, t.sample_name, t.analysis_id, t.result_text,
          t.tested_at, a.name AS analysis_name, p.parameter_name
        FROM lab_sample_tests t
        JOIN lab_analyses a ON a.id = t.analysis_id AND a.active = 1
        LEFT JOIN parameters p ON p.id = a.parameter_id
        WHERE t.deleted_at IS NULL AND t.source_type = 'raw_material'
          AND t.entry_code IN (${List.filled(codes.length, '?').join(',')})
          AND date(t.tested_at) <= date(?)
        ORDER BY t.tested_at DESC, t.id DESC
      ''',
        [...codes, end],
      );
      testRows.addAll(tests);
    }
    final testsByCode = <String, List<Map<String, Object?>>>{};
    for (final test in testRows) {
      (testsByCode['${test['entry_code']}'] ??= []).add(test);
    }
    final output = <MaterialReceipt>[];
    for (final row in rows) {
      final received = _date(row['inspection_date']);
      if (received == null) continue;
      final code = '${row['entry_code'] ?? ''}';
      final lab = <String, List<double>>{};
      final labReported = <String>{};
      final seen = <String>{};
      final history = <String, List<ParameterObservation>>{};
      final chemicalKeys = <String>{};
      for (final test in testsByCode[code] ?? const []) {
        final parameterKey = _key(
          '${test['parameter_name'] ?? test['analysis_name'] ?? ''}',
        );
        final testedAt = DateTime.tryParse('${test['tested_at']}');
        if (parameterKey.isNotEmpty && testedAt != null) {
          (history[parameterKey] ??= []).add(
            ParameterObservation(
              sample: '${test['sample_name'] ?? ''}',
              at: testedAt,
              value: FormulationCalculator.number(test['result_text']),
            ),
          );
        }
        final sampleKey =
            '${_key('${test['parameter_name'] ?? test['analysis_name'] ?? ''}')}/${test['sample_name']}';
        if (!seen.add(sampleKey)) continue;
        final key = _key(
          '${test['parameter_name'] ?? test['analysis_name'] ?? ''}',
        );
        if (key.isNotEmpty) {
          labReported.add(key);
          chemicalKeys.add(key);
        }
        final number = FormulationCalculator.number(test['result_text']);
        if (key.isNotEmpty && number != null) {
          lab.putIfAbsent(key, () => []).add(number);
        }
      }
      final raw = <String, List<double>>{};
      final physicalKeys = <String>{};
      for (final entry in [
        ...Map<String, dynamic>.from(
          _decode(row['chemical_results_json']),
        ).entries.map((e) => (e.key, e.value, true)),
        ...Map<String, dynamic>.from(
          _decode(row['physical_results_json']),
        ).entries.map((e) => (e.key, e.value, false)),
      ]) {
        final (field, value, chemical) = entry;
        final values = value is List ? value : [value];
        for (final item in values) {
          final number = FormulationCalculator.number(item);
          if (number != null) {
            final key = _key(field);
            raw.putIfAbsent(key, () => []).add(number);
            (chemical ? chemicalKeys : physicalKeys).add(key);
          }
        }
      }
      final values = <String, double>{};
      final sources = <String, String>{};
      for (final key in {...raw.keys, ...lab.keys}) {
        final preferred = labReported.contains(key) ? lab[key] : raw[key];
        if (preferred == null || preferred.isEmpty) continue;
        values[key] = preferred.reduce((a, b) => a + b) / preferred.length;
        sources[key] = lab[key]?.isNotEmpty == true ? 'lab' : 'inspection';
      }
      if (values.isEmpty && raw.isEmpty && history.isEmpty) continue;
      output.add(
        MaterialReceipt(
          materialId: (row['material_id'] as num).toInt(),
          code: code,
          receivedAt: received,
          source: 'inspection',
          values: values,
          sources: sources,
          inspectionValues: {
            for (final entry in raw.entries)
              entry.key:
                  entry.value.reduce((a, b) => a + b) / entry.value.length,
          },
          labHistory: history,
          // Lab tests are chemical analyses by definition; a physical field
          // that is *also* lab-reported or chemically entered stays a real
          // analysis parameter.
          physicalKeys: {...physicalKeys}..removeAll(chemicalKeys),
        ),
      );
    }
    return output;
  }

  void _check(String permission) {
    if (!guard.allows(permission)) {
      throw const AuthorizationError('لا تملك صلاحية تعديل التركيبات.');
    }
  }

  @override
  Future<int> save(Map<String, dynamic> record, {int? id}) async {
    _check(
      id == null
          ? Permission.formulationsCreate.id
          : Permission.formulationsUpdate.id,
    );
    final now = DateTime.now().toIso8601String();
    late int resultId;
    await dbHelper.businessTransaction((txn) async {
      final values = <String, Object?>{
        'name': '${record['name'] ?? ''}'.trim(),
        'product_id': record['product_id'],
        'items_json': jsonEncode(record['items'] ?? []),
        'parameters_json': jsonEncode(record['parameters'] ?? {}),
        'graph_parameters_json': jsonEncode(
          record['graph_parameters'] ?? ['protein', 'fat'],
        ),
        'calculation_json': jsonEncode(record['calculation'] ?? {}),
        'source_snapshot_json': jsonEncode(record['sources'] ?? []),
        'copied_from_id': record['copied_from_id'],
        'updated_at': now,
        'updated_by': guard.uid,
        'device_id': guard.deviceId,
      };
      if (values['name'] == '') {
        throw const ValidationError('أدخل اسم التركيبة.');
      }
      final rawItems = record['items'];
      final items = rawItems is List
          ? rawItems.whereType<Map>().toList()
          : <Map>[];
      if (items.isEmpty || items.length != (rawItems as List).length) {
        throw const ValidationError('أضف خامة واحدة على الأقل بكمية صالحة.');
      }
      final materialIds = <int>{};
      for (final item in items) {
        final materialId = (item['material_id'] as num?)?.toInt();
        final quantity = FormulationCalculator.number(item['quantity_kg']);
        final price = FormulationCalculator.number(item['price_per_kg']);
        if (materialId == null || !materialIds.add(materialId)) {
          throw const ValidationError('لا يمكن إضافة الخامة نفسها مرتين.');
        }
        if (quantity == null || quantity <= 0) {
          throw const ValidationError('كمية كل خامة يجب أن تكون أكبر من صفر.');
        }
        if (item['price_per_kg'] != null && (price == null || price < 0)) {
          throw const ValidationError(
            'سعر الكيلوجرام يجب أن يكون صفرًا أو أكبر.',
          );
        }
      }
      if (id == null) {
        values.addAll({
          'created_at': now,
          'created_by': guard.uid,
          'remote_id': const Uuid().v4(),
        });
        resultId = await txn.insert('nutrition_formulations', values);
      } else {
        final found = await txn.query(
          'nutrition_formulations',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [id],
          limit: 1,
        );
        if (found.isEmpty) throw const ValidationError('التركيبة غير موجودة.');
        resultId = id;
        await txn.update(
          'nutrition_formulations',
          values,
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await queueSharedRows(
        txn,
        type: 'nutritionFormulation',
        queue: queue,
        guard: guard,
        where: 'id = ?',
        whereArgs: [resultId],
      );
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'nutrition_formulation',
        entityId: '$resultId',
        details: {'name': values['name']},
      );
    });
    return resultId;
  }

  @override
  Future<void> archive(int id) async {
    _check(Permission.formulationsUpdate.id);
    await dbHelper.businessTransaction((txn) async {
      final count = await txn.update(
        'nutrition_formulations',
        {
          'is_archived': 1,
          'updated_at': DateTime.now().toIso8601String(),
          'updated_by': guard.uid,
        },
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [id],
      );
      if (count == 0) throw const ValidationError('التركيبة غير موجودة.');
      await queueSharedRows(
        txn,
        type: 'nutritionFormulation',
        queue: queue,
        guard: guard,
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }
}
