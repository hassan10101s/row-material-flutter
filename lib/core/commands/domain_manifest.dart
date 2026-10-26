import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:convert';

import '../sync/entity_registry.dart';
import '../sync/shared_settings.dart';

String centralReadPermission(String entityType) {
  if (entityType == 'nutritionFormulation') return 'formulations.read';
  if (entityType == 'member') return 'users.read';
  if (entityType == 'organizationSetting') return 'reports.read';
  if (entityType.startsWith('qc')) return 'qc.read';
  if (const {
    'sample',
    'referenceMaterial',
    'parameter',
    'materialBound',
  }.contains(entityType)) {
    return 'samples.read';
  }
  return 'lab_results.read';
}

String _camel(String name) {
  final parts = name.split('_');
  return parts.first +
      parts
          .skip(1)
          .map(
            (part) => part.isEmpty
                ? ''
                : '${part[0].toUpperCase()}${part.substring(1)}',
          )
          .join();
}

// Older SQL tables did not declare all their foreign keys. These are domain
// relationships, not permission to interpret arbitrary numeric ids remotely.
const _additionalParents = <String, Map<String, (String, bool)>>{
  'qualityCheck': {'inspection_id': ('sample', true)},
  'labAnalysisItem': {'analysis_id': ('labAnalysis', true)},
  'labFieldLink': {'analysis_id': ('labAnalysis', true)},
  'labProductAnalysis': {
    'product_id': ('labProduct', true),
    'analysis_id': ('labAnalysis', true),
  },
  'labMaterialAnalysis': {'analysis_id': ('labAnalysis', true)},
  'labResult': {
    'analysis_id': ('labAnalysis', true),
    'worksheet_row_id': ('worksheet', false),
  },
  'inventoryLot': {'inventory_id': ('inventoryItem', true)},
  'inventoryTransaction': {'inventory_id': ('inventoryItem', true)},
  'stockAdjustment': {'inventory_id': ('inventoryItem', true)},
  'consumption': {
    'inventory_id': ('inventoryItem', true),
    'sample_test_id': ('labResult', true),
    'lot_id': ('inventoryLot', false),
    'reversal_of_log_id': ('consumption', false),
  },
  'equipmentEvent': {'equipment_id': ('equipment', true)},
  'productBatchSample': {'batch_id': ('sample', true)},
  'qcCustomTableField': {'table_id': ('qcCustomTable', true)},
  'qcCustomTableRow': {'table_id': ('qcCustomTable', true)},
};

/// Generated from the same schema and serializers the actual repositories use.
/// The backend consumes the committed JSON; no executable client rules are
/// downloaded or trusted by the server.
Future<Map<String, dynamic>> buildDomainManifest(DatabaseExecutor db) async {
  final entities = <String, dynamic>{};
  for (final entity in syncEntities) {
    final info = await db.rawQuery('PRAGMA table_info(${entity.localTable})');
    if (info.isEmpty) {
      throw StateError('Missing domain table ${entity.localTable}');
    }
    final tableDefinition = await db.query(
      'sqlite_master',
      columns: ['sql'],
      where: 'type = ? AND name = ?',
      whereArgs: ['table', entity.localTable],
    );
    final shape = <String, dynamic>{
      for (final column in info) column['name'] as String: null,
      entity.pkColumn: 1,
    };
    final payload = buildRemotePayload(
      entity,
      shape,
      const SyncPayloadContext(
        organizationId: 'org',
        uid: 'user',
        deviceId: 'device',
        version: 1,
        versionField: 'version',
      ),
      asCreate: true,
    );
    final fields = {
      ...payload.keys,
      ...entity.mutableFields,
      if (entity.type == 'qualityCheck') 'businessVersion',
    }.toList()..sort();
    final parents = <String, Map<String, dynamic>>{};
    void parent(String column, String type, bool required) {
      parents[column] = {
        'relation': _camel(column),
        'localField': column,
        'type': type,
        'required': required,
      };
    }

    for (final spec in sharedParentSpecs(entity)) {
      parent(spec.refColumn, spec.parentType, spec.isRequired);
    }
    for (final key in await db.rawQuery(
      'PRAGMA foreign_key_list(${entity.localTable})',
    )) {
      final column = key['from'] as String;
      final targets = syncEntities.where(
        (candidate) => candidate.localTable == key['table'],
      );
      if (targets.length != 1 ||
          targets.single.type == 'member' ||
          parents.containsKey(column)) {
        continue;
      }
      parent(
        column,
        targets.single.type,
        info.any((entry) => entry['name'] == column && entry['notnull'] == 1),
      );
    }
    for (final spec in (_additionalParents[entity.type] ?? const {}).entries) {
      if (shape.containsKey(spec.key)) {
        parent(spec.key, spec.value.$1, spec.value.$2);
      }
    }
    final unique = <Map<String, dynamic>>[];
    for (final index in await db.rawQuery(
      'PRAGMA index_list(${entity.localTable})',
    )) {
      if (index['unique'] != 1 || index['origin'] == 'pk') continue;
      final name = (index['name'] as String).replaceAll("'", "''");
      final columns = await db.rawQuery("PRAGMA index_xinfo('$name')");
      final keys = columns.where((column) => column['key'] == 1).toList();
      if (keys.any((column) => column['name'] == null)) {
        throw StateError(
          'Expression uniqueness requires an explicit domain rule: $name',
        );
      }
      final names = keys.map((column) => column['name'] as String).toList();
      if (names.contains('remote_id')) continue;
      final sql = await db.query(
        'sqlite_master',
        columns: ['sql'],
        where: 'name = ?',
        whereArgs: [index['name']],
      );
      final definition = sql.isEmpty ? '' : '${sql.single['sql'] ?? ''}';
      final where = RegExp(
        r'\bWHERE\s+(.+)$',
        caseSensitive: false,
      ).firstMatch(definition)?.group(1)?.trim();
      unique.add({
        'columns': names,
        'fields': names.map(_camel).toList(),
        'collations': keys.map((column) => column['coll']).toList(),
        'where': where,
      });
    }
    entities[entity.type] = {
      'collection': entity.collection.path,
      'table': entity.localTable,
      'primaryKey': entity.pkColumn,
      'autoIncrement': tableDefinition.single['sql']
          .toString()
          .toUpperCase()
          .contains('AUTOINCREMENT'),
      'permission': entity.permission,
      'readPermission': centralReadPermission(entity.type),
      'appendOnly': entity.appendOnly,
      'fields': fields,
      'sqlFields': {
        for (final column in info)
          if (column['name'] != entity.pkColumn &&
              fields.contains(_camel(column['name'] as String)))
            _camel(column['name'] as String): {
              'column': column['name'],
              'type': column['type'],
              'required': column['notnull'] == 1,
              'hasDefault': column['dflt_value'] != null,
            },
      },
      'actors': [
        for (final column in info)
          if ((column['type'] as String).toUpperCase().contains('INT') &&
              (RegExp(r'(_by|_by_id)$').hasMatch(column['name'] as String) ||
                  column['name'] == 'user_id'))
            _camel(column['name'] as String),
      ],
      'payloadFields': payload['payload'] is String
          ? (jsonDecode(payload['payload'] as String) as Map).keys.toList()
          : null,
      'parents': parents.values.toList(),
      'unique': unique,
    };
  }
  return {
    'manifestVersion': 1,
    'entities': entities,
    'sharedSettingKeys': sharedSettingKeys.toList()..sort(),
  };
}
