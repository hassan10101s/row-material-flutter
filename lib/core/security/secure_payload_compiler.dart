import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../auth/app_session.dart';
import '../sync/entity_registry.dart';
import '../utils/app_exceptions.dart';
import '../utils/app_format.dart';
import 'secure_field_policy.dart';
import 'secure_migration_scope.dart';

Map<String, dynamic> secureJson(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is! String || value.isEmpty) return {};
  final decoded = jsonDecode(value);
  return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
}

/// Removes duplicate appearances in snapshots as well as the primary columns.
Object? withoutSecureNames(Object? value, Set<String> names) {
  if (value is List) {
    return [
      for (final row in value)
        if ((row is! String || !names.contains(row.trim().toLowerCase())) &&
            (row is! Map ||
                !names.contains(
                  '${row['analysis'] ?? row['parameter'] ?? row['parameter_name'] ?? row['name'] ?? ''}'
                      .trim()
                      .toLowerCase(),
                )))
          withoutSecureNames(row, names),
    ];
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (!names.contains('${entry.key}'.trim().toLowerCase()))
          entry.key: withoutSecureNames(entry.value, names),
    };
  }
  return value;
}

/// Runs once at the atomic authoring boundary. SQL changes are still under the
/// capture savepoint; only the public projection can subsequently reach SQLite.
Future<void> compileSecurePayloads({
  required DatabaseExecutor db,
  required AppSession session,
  required List<Map<String, Object?>> writes,
}) async {
  final privateWrites = <Map<String, Object?>>[];
  final manager = SecureFieldPolicy(session: session).mayManage;
  for (final write in writes) {
    final type = write['entityType'];
    final payload = write['payload'] as Map<String, dynamic>;
    if (type == 'referenceMaterial' || type == 'labProduct') {
      final refs = {
        ...secureJson(payload['physicalReferenceJson']),
        ...secureJson(payload['chemicalReferenceJson']),
      };
      final hasSecure = refs.values.any(isReferenceSecure);
      final table = type == 'referenceMaterial'
          ? 'reference_materials'
          : 'lab_products';
      final previous = await db.query(
        table,
        columns: ['secure_configured'],
        where: 'id = ?',
        whereArgs: [payload['localId']],
      );
      if (!manager &&
          (hasSecure || previous.firstOrNull?['secure_configured'] == 1)) {
        throw const AuthorizationError(
          'إعداد Secure متاح لصاحب المؤسسة ومدير الجودة فقط.',
        );
      }
      payload['secureConfigured'] = hasSecure ? 1 : 0;
      continue;
    }
    final privacyScope = SecureMigrationScope.current;
    if (privacyScope != null &&
        const {
          'sample',
          'productBatchSample',
          'labResult',
          'nirValidationSettings',
          'nutritionFormulation',
        }.contains(type)) {
      payload['publicPrivacyEpoch'] = privacyScope.privacyEpoch;
      payload['securePolicyJob'] = privacyScope.jobId;
      write['privacyMigrationJob'] = privacyScope.jobId;
      if (privacyScope.metadataOnly) continue;
    }
    if (const {
      'nirValidationSettings',
      'nutritionFormulation',
    }.contains(type)) {
      final migration = SecureMigrationScope.current;
      if (migration != null) {
        if (!manager) {
          throw const AuthorizationError(
            'صلاحية نقل البيانات المحمية غير متاحة.',
          );
        }
        payload['securePolicyJob'] = migration.jobId;
        write['privacyMigrationJob'] = migration.jobId;
      }
      if (type == 'nirValidationSettings' &&
          (migration != null || write['expectedVersion'] == 0)) {
        final targets =
            migration?.secureTargets ?? await activeSecureTargets(db);
        final original = secureJson(payload['calibrationSnapshotJson']);
        final summaries = (original['summaries'] as List? ?? const []);
        final retained = [
          for (final raw in summaries)
            if (raw is! Map || !secureNirSummary(raw, targets)) raw,
        ];
        final parentRefs = write['relations'] as Map? ?? {};
        final target =
            (parentRefs['materialId'] ?? parentRefs['productId']) as Map?;
        final ownNames =
            targets['${payload['scope']}|${target?['entityId']}'] ??
            const <String>{};
        final hidden = ownNames.contains(
          '${payload['parameter']}'.trim().toLowerCase(),
        );
        payload['secureEntryId'] = null;
        payload['secureResult'] = 0;
        if (retained.length != summaries.length || hidden) {
          final fields = <String, dynamic>{
            'calibration_snapshot_json': payload['calibrationSnapshotJson'],
            'parameter': payload['parameter'],
            'reset_note': payload['resetNote'],
          };
          final public = {...original, 'summaries': retained}
            ..remove('appliedCorrection');
          payload['calibrationSnapshotJson'] = jsonEncode(public);
          if (hidden) {
            payload['parameter'] = '__secure__';
            payload['resetNote'] = '';
            payload['secureResult'] = 1;
          }
          privateWrites.add(
            _privateSubmission(
              write,
              fields,
              session,
              originals: {
                'original_snapshot_json': fields['calibration_snapshot_json'],
                'original_parameter': fields['parameter'],
                'original_note': fields['reset_note'],
              },
            ),
          );
        }
      } else if (type == 'nutritionFormulation') {
        final names =
            migration?.parameterNames ??
            (secureJson(payload['secureTemplateJson'])['parameters'] as List? ??
                    const [])
                .cast<String>()
                .toSet();
        if (migration != null) payload['secureEntryId'] = null;
        if (names.isNotEmpty) {
          final fields = <String, dynamic>{};
          for (final column in [
            'parametersJson',
            'calculationJson',
            'sourceSnapshotJson',
            'graphParametersJson',
          ]) {
            final value = payload[column];
            if (value is! String || value.isEmpty) continue;
            final filtered = jsonEncode(
              withoutSecureNames(jsonDecode(value), names),
            );
            fields[column.replaceAllMapped(
                  RegExp('[A-Z]'),
                  (m) => '_${m[0]!.toLowerCase()}',
                )] =
                value;
            payload[column] = filtered;
          }
          payload['secureTemplateJson'] = jsonEncode({
            'parameters': names.toList()..sort(),
          });
          if ((migration != null || write['expectedVersion'] == 0) &&
              fields.isNotEmpty) {
            privateWrites.add(_privateSubmission(write, fields, session));
          }
        } else if (migration != null) {
          payload['secureTemplateJson'] = null;
        }
      }
      continue;
    }
    if (!const {'sample', 'productBatchSample', 'labResult'}.contains(type) ||
        (write['operation'] == 'tombstone' &&
            SecureMigrationScope.current == null)) {
      continue;
    }
    final creating = write['expectedVersion'] == 0;
    final migration = SecureMigrationScope.current;
    final partitioning = creating || migration != null;
    if (migration != null) {
      if (!manager) {
        throw const AuthorizationError(
          'صلاحية نقل البيانات المحمية غير متاحة.',
        );
      }
      payload['securePolicyJob'] = migration.jobId;
      write['privacyMigrationJob'] = migration.jobId;
    }
    Map<String, dynamic> physical = secureJson(
      payload['physicalReferenceJson'],
    );
    Map<String, dynamic> chemical = secureJson(
      payload['chemicalReferenceJson'],
    );
    if (type == 'productBatchSample' || type == 'labResult') {
      final sources = await db.query(
        'inspections',
        where: type == 'productBatchSample' ? 'id = ?' : 'entry_code = ?',
        whereArgs: [
          type == 'productBatchSample'
              ? payload['batchId']
              : payload['entryCode'],
        ],
        limit: 1,
      );
      if (sources.isNotEmpty) {
        final source = sources.single;
        final template = secureJson(source['secure_template_json']);
        physical = {
          ...secureJson(source['physical_reference_json']),
          ...secureJson(template['physical']),
        };
        chemical = {
          ...secureJson(source['chemical_reference_json']),
          ...secureJson(template['chemical']),
        };
      }
    }
    if (type == 'labResult' && physical.isEmpty && chemical.isEmpty) {
      final product = payload['sourceType'] == 'product';
      final rows = await db.query(
        product ? 'lab_products' : 'reference_materials',
        where: '${product ? 'name' : 'material_name'} = ?',
        whereArgs: [payload['sourceName']],
        limit: 1,
      );
      if (rows.isNotEmpty && rows.single['secure_configured'] == 1) {
        physical = secureJson(rows.single['physical_reference_json']);
        chemical = secureJson(rows.single['chemical_reference_json']);
      }
    }
    // Saved public records contain only public references. Their protected
    // snapshot and immutable submission pointer cannot be replaced by edits.
    final template = secureJson(payload['secureTemplateJson']);
    physical.addAll(secureJson(template['physical']));
    chemical.addAll(secureJson(template['chemical']));
    if (migration != null) {
      physical = {
        for (final e in physical.entries)
          e.key: withReferenceSecure(
            e.value,
            migration.parameterNames.contains(e.key.trim().toLowerCase()),
          ),
      };
      chemical = {
        for (final e in chemical.entries)
          e.key: withReferenceSecure(
            e.value,
            migration.parameterNames.contains(e.key.trim().toLowerCase()),
          ),
      };
      payload['secureEntryId'] = null;
      payload['secureTemplateJson'] = null;
      if (type == 'labResult') payload['secureResult'] = 0;
      if (type == 'sample') {
        payload['physicalReferenceJson'] = jsonEncode(physical);
        payload['chemicalReferenceJson'] = jsonEncode(chemical);
      }
    }
    final privatePhysical = {
      for (final e in physical.entries)
        if (isReferenceSecure(e.value)) e.key: e.value,
    };
    final privateChemical = {
      for (final e in chemical.entries)
        if (isReferenceSecure(e.value)) e.key: e.value,
    };
    final names = {
      ...privatePhysical.keys,
      ...privateChemical.keys,
    }.map((v) => v.trim().toLowerCase()).toSet();
    if (names.isEmpty && type != 'labResult') continue;
    final fields = <String, dynamic>{};
    if (type == 'labResult') {
      final analyses = await db.rawQuery(
        'SELECT p.parameter_name, a.name FROM lab_analyses a LEFT JOIN parameters p ON p.id = a.parameter_id WHERE a.id = ?',
        [payload['analysisId']],
      );
      final a = analyses.firstOrNull;
      if (!(migration == null && payload['secureResult'] == 1) &&
          !(migration?.parameterNames ?? names).contains(
            '${a?['parameter_name'] ?? a?['name'] ?? ''}'.trim().toLowerCase(),
          )) {
        continue;
      }
      if (partitioning) {
        fields['result_text'] = payload['resultText'];
        fields['dynamic_values_json'] =
            payload['dynamicValuesJson'] ??
            jsonEncode(payload['dynamicValues'] ?? {});
      }
      payload['resultText'] = '';
      payload['dynamicValuesJson'] = '{}';
      payload.remove('dynamicValues');
      payload['secureResult'] = 1;
    } else {
      for (final pair in [
        ('physical', physical, privatePhysical),
        ('chemical', chemical, privateChemical),
      ]) {
        final field = '${pair.$1}ResultsJson';
        Object? all = payload[field];
        if (all is String && all.isNotEmpty) all = jsonDecode(all);
        final public = withoutSecureNames(all, names);
        if (partitioning) {
          fields['${pair.$1}_reference_json'] = jsonEncode(pair.$3);
          fields['${pair.$1}_results_json'] = jsonEncode(
            all is Map
                ? {
                    for (final e in all.entries)
                      if (names.contains('${e.key}'.trim().toLowerCase()))
                        e.key: e.value,
                  }
                : all is List
                ? all
                      .where(
                        (row) =>
                            row is Map &&
                            names.contains(
                              '${row['analysis'] ?? row['parameter'] ?? row['parameter_name'] ?? row['name'] ?? ''}'
                                  .trim()
                                  .toLowerCase(),
                            ),
                      )
                      .toList()
                : [],
          );
        }
        if (all != null) payload[field] = jsonEncode(public);
        if (type == 'sample') {
          payload['${pair.$1}ReferenceJson'] = jsonEncode({
            for (final e in pair.$2.entries)
              if (!isReferenceSecure(e.value)) e.key: e.value,
          });
        }
      }
      payload['secureTemplateJson'] = jsonEncode({
        'physical': privatePhysical,
        'chemical': privateChemical,
      });
      final snapshot = payload['snapshotJson'];
      if (snapshot is String && snapshot.isNotEmpty) {
        payload['snapshotJson'] = jsonEncode(
          withoutSecureNames(jsonDecode(snapshot), names),
        );
      }
    }
    if (!partitioning || fields.isEmpty) continue;
    privateWrites.add(_privateSubmission(write, fields, session));
  }
  writes.addAll(privateWrites);
}

/// Callers receive the approved public projection after a blind submission,
/// including success banners. Candidate inputs remain available only pending
/// approval; an approved result must not echo a protected value back to its author.
Object? publicAuthoringValue(Object? value, List<Map<String, Object?>> writes) {
  if (value is! Map) return value;
  final result = Map<String, dynamic>.from(value);
  if (result['test'] is Map) {
    result['test'] = publicAuthoringValue(result['test'], writes);
  }
  for (final write in writes) {
    final payload = write['payload'] as Map;
    if (!const {
          'sample',
          'productBatchSample',
          'labResult',
        }.contains(write['entityType']) ||
        payload['secureEntryId'] == null ||
        payload['localId'] != result['id']) {
      continue;
    }
    for (final entry in payload.entries) {
      final snake = '${entry.key}'.replaceAllMapped(
        RegExp('[A-Z]'),
        (m) => '_${m[0]!.toLowerCase()}',
      );
      result[snake] = entry.value;
      if (snake.endsWith('_json') && entry.value is String) {
        result[snake.substring(0, snake.length - 5)] = jsonDecode(
          entry.value as String,
        );
      }
    }
  }
  return result;
}

bool secureNirSummary(Map summary, Map<String, Set<String>> targets) {
  final key = '${summary['scope']}|${summary['entityRemoteId']}';
  final names =
      targets[key] ??
      targets['${summary['scope']}|@${summary['entityName']}'] ??
      const <String>{};
  return names.contains('${summary['parameter']}'.trim().toLowerCase());
}

Map<String, Object?> _privateSubmission(
  Map<String, Object?> write,
  Map<String, dynamic> fields,
  AppSession session, {
  Map<String, dynamic> originals = const {},
}) {
  final id = const Uuid().v4();
  (write['payload'] as Map)['secureEntryId'] = id;
  final type = write['entityType'] as String;
  final parent = switch (type) {
    'sample' => ('inspectionId', 'inspection_id'),
    'productBatchSample' => ('batchSampleId', 'batch_sample_id'),
    'labResult' => ('sampleTestId', 'sample_test_id'),
    'nirValidationSettings' => ('nirResetId', 'nir_reset_id'),
    'nutritionFormulation' => ('formulationId', 'formulation_id'),
    _ => throw StateError('Unknown protected source'),
  };
  final entity = SyncEntity.byType('secureFieldSubmission')!;
  final migration = SecureMigrationScope.current;
  final submission = buildRemotePayload(
    entity,
    {
      'id': 0,
      'remote_id': id,
      'source_kind': type,
      'source_version': (write['expectedVersion'] as int) + 1,
      if (migration != null) 'secure_policy_job': migration.jobId,
      'fields_json': jsonEncode(fields),
      for (final field in [
        'inspection_id',
        'batch_sample_id',
        'sample_test_id',
        'nir_reset_id',
        'formulation_id',
      ])
        field: null,
      ...originals,
    },
    SyncPayloadContext(
      organizationId: session.organizationId,
      uid: session.uid,
      deviceId: session.deviceId,
      version: 1,
      versionField: 'version',
    ),
    asCreate: true,
  );
  return {
    if (migration != null) 'privacyMigrationJob': migration.jobId,
    'entityType': entity.type,
    'entityId': id,
    'operation': 'create',
    'expectedVersion': 0,
    'payload': submission,
    'relations': {
      parent.$1: {
        'entityType': type,
        'entityId': write['entityId'],
        'expectedVersion': write['expectedVersion'],
      },
    },
  };
}

Future<Map<String, Set<String>>> activeSecureTargets(
  DatabaseExecutor db,
) async {
  final targets = <String, Set<String>>{};
  for (final kind in [
    ('reference_materials', 'raw_material', 'material_name'),
    ('lab_products', 'product', 'name'),
  ]) {
    for (final ref in await db.query(kind.$1, where: 'secure_configured = 1')) {
      final refs = {
        ...secureJson(ref['physical_reference_json']),
        ...secureJson(ref['chemical_reference_json']),
      };
      final names = {
        for (final e in refs.entries)
          if (isReferenceSecure(e.value)) e.key.trim().toLowerCase(),
      };
      targets['${kind.$2}|${ref['remote_id']}'] = names;
      targets['${kind.$2}|@${ref[kind.$3]}'] = names;
    }
  }
  return targets;
}
