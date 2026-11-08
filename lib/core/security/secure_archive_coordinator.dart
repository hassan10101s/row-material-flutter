import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../auth/session_source.dart';
import '../commands/firestore_direct_store.dart';
import '../database/database_helper.dart';
import '../sync/entity_registry.dart';
import '../sync/sync_queue.dart';
import '../sync/sync_write.dart';
import '../utils/app_exceptions.dart';
import '../utils/app_format.dart';
import 'secure_field_access.dart';
import 'secure_migration_scope.dart';
import 'secure_payload_compiler.dart';

Set<String> secureParameterNames(Map definition) => {
  for (final entry in {
    ...secureJson(definition['physicalReferenceJson']),
    ...secureJson(definition['chemicalReferenceJson']),
  }.entries)
    if (isReferenceSecure(entry.value)) entry.key.trim().toLowerCase(),
};

/// Explicit maintenance of independent approved records. The definition does
/// not become active until every historical record has a verified receipt.
/// A pending job fences ordinary writes; reconnect/startup never resume it.
class SecureArchiveCoordinator {
  SecureArchiveCoordinator({
    required this.databaseHelper,
    required this.source,
    required this.queue,
    required this.access,
    this.store,
  });
  final DatabaseHelper databaseHelper;
  final SessionSource source;
  final SyncQueue queue;
  final SecureFieldAccess access;
  final FirestoreDirectStore? store;

  String get _path =>
      'organizations/${source.session.organizationId}/secureControl/state';

  Future<void> _put(Map<String, dynamic> data) async {
    final db = store;
    if (db == null || !access.mayManage) {
      throw const AuthorizationError(
        'نقل البيانات المحمية يتطلب مدير الجودة أو صاحب المؤسسة واتصالًا بالسيرفر.',
      );
    }
    final before = await db.get(_path);
    final orgPath = 'organizations/${source.session.organizationId}';
    final org = await db.get(orgPath);
    if (org == null) throw const ValidationError('المؤسسة غير متاحة.');
    final gate = Map<String, dynamic>.from(org.data['commandProtocol'] as Map);
    gate['secureFieldsEnabled'] =
        gate['secureFieldsEnabled'] == true ||
        (data['parameterNames'] as List).isNotEmpty;
    gate['secureMaintenanceJob'] = data['pending'] == true
        ? data['jobId']
        : null;
    gate['secureMaintenanceDevice'] = data['deviceId'];
    gate['secureMaintenanceTarget'] = data['targetId'];
    gate['secureMaintenanceTargetType'] = data['targetType'];
    gate['secureMaintenanceComplete'] = data['complete'];
    gate['secureMaintenanceEpoch'] = data['privacyEpoch'];
    if (data['pending'] == false) {
      gate['publicPrivacyEpoch'] = data['privacyEpoch'];
    }
    await db.request(
      '${db.documents}:commit',
      body: {
        'writes': [
          db.write(_path, data, current: before, timestamps: ['updatedAt']),
          db.write(orgPath, {
            ...org.data,
            'commandProtocol': gate,
          }, current: org),
        ],
      },
    );
    final verified = await db.get(_path);
    if (verified == null ||
        data.entries.any(
          (e) => jsonEncode(verified.data[e.key]) != jsonEncode(e.value),
        )) {
      throw const ValidationError('لم يتأكد حفظ حالة نقل البيانات المحمية.');
    }
  }

  /// Returns a completion action. The authoring gateway calls it only after
  /// the definition itself has a verified receipt and public read projection.
  Future<Future<void> Function()?> prepare(
    List<Map<String, Object?>> writes,
  ) async {
    final defs = writes
        .where(
          (w) => const {
            'referenceMaterial',
            'labProduct',
          }.contains(w['entityType']),
        )
        .toList();
    if (defs.isEmpty) return null;
    if (defs.length != 1) {
      throw const ValidationError(
        'غيّر إعداد Secure لخامة أو منتج واحد في كل مرة.',
      );
    }
    final definition = defs.single;
    final payload = definition['payload'] as Map<String, dynamic>;
    final names = secureParameterNames(payload);
    final db = await databaseHelper.database;
    final table = definition['entityType'] == 'referenceMaterial'
        ? 'reference_materials'
        : 'lab_products';
    final old = await db.query(
      table,
      where: 'id = ?',
      whereArgs: [payload['localId']],
    );
    final oldNames = old.isEmpty
        ? <String>{}
        : secureParameterNames({
            'physicalReferenceJson': old.single['physical_reference_json'],
            'chemicalReferenceJson': old.single['chemical_reference_json'],
          });
    final namesChanged =
        names.length != oldNames.length || !names.containsAll(oldNames);
    final referencesChanged =
        old.isEmpty ||
        payload['physicalReferenceJson'] !=
            old.single['physical_reference_json'] ||
        payload['chemicalReferenceJson'] !=
            old.single['chemical_reference_json'];
    if (!namesChanged && (!referencesChanged || names.isEmpty)) return null;
    if (!access.mayManage || store == null) {
      throw const AuthorizationError(
        'إعداد Secure متاح لصاحب المؤسسة ومدير الجودة فقط.',
      );
    }
    final actor = source.session;
    final state = await store!.get(_path);
    final desired = names.toList()..sort();
    final sameJob =
        state?.data['pending'] == true &&
        state!.data['targetId'] == definition['entityId'] &&
        jsonEncode(state.data['parameterNames']) == jsonEncode(desired) &&
        state.data['deviceId'] == actor.deviceId;
    if (state?.data['pending'] == true && !sameJob) {
      throw const ValidationError(
        'يوجد نقل بيانات محمية غير مكتمل. استكمله من الجهاز الذي بدأه قبل تغيير إعداد آخر.',
      );
    }
    final job = sameJob ? state.data['jobId'] as String : const Uuid().v4();
    final currentOrg = await store!.get(
      'organizations/${actor.organizationId}',
    );
    final activeEpoch =
        ((currentOrg?.data['commandProtocol'] as Map?)?['publicPrivacyEpoch']
            as int?) ??
        0;
    final epoch = sameJob ? state.data['privacyEpoch'] as int : activeEpoch + 1;
    final control = <String, dynamic>{
      'privacyEpoch': epoch,
      'pending': true,
      'complete': false,
      'jobId': job,
      'targetId': definition['entityId'],
      'targetType': definition['entityType'],
      'parameterNames': desired,
      'deviceId': actor.deviceId,
    };
    await _put(control);
    final inspections = await db.query(
      'inspections',
      where: definition['entityType'] == 'referenceMaterial'
          ? "inspection_kind != 'product' AND material_id = ?"
          : "inspection_kind = 'product' AND product_id = ?",
      whereArgs: [payload['localId']],
    );
    final targets = <String, Set<String>>{};
    for (final kind in [
      ('reference_materials', 'raw_material', 'material_name'),
      ('lab_products', 'product', 'name'),
    ]) {
      for (final ref in await db.query(kind.$1)) {
        final own = ref['remote_id'] == definition['entityId']
            ? names
            : ref['secure_configured'] == 1
            ? secureParameterNames({
                'physicalReferenceJson': ref['physical_reference_json'],
                'chemicalReferenceJson': ref['chemical_reference_json'],
              })
            : <String>{};
        targets['${kind.$2}|${ref['remote_id']}'] = own;
        targets['${kind.$2}|@${ref[kind.$3]}'] = own;
      }
    }
    final ownScope = definition['entityType'] == 'referenceMaterial'
        ? 'raw_material'
        : 'product';
    targets['$ownScope|${definition['entityId']}'] = names;
    final scope = SecureMigrationScope(
      job,
      names,
      secureTargets: targets,
      privacyEpoch: epoch,
    );
    for (final inspection
        in namesChanged ? inspections : <Map<String, Object?>>[]) {
      _check(actor.uid, actor.organizationId, actor.deviceId);
      await _record('sample', inspection, scope);
      if (inspection['inspection_kind'] == 'product') {
        for (final sample in await db.query(
          'product_batch_samples',
          where: 'batch_id = ?',
          whereArgs: [inspection['id']],
        )) {
          await _record('productBatchSample', sample, scope);
        }
      }
      for (final result in await db.query(
        'lab_sample_tests',
        where: 'entry_code = ?',
        whereArgs: [inspection['entry_code']],
      )) {
        await _record('labResult', result, scope);
      }
    }
    if (namesChanged) {
      final sourceNames = {
        payload[table == 'reference_materials' ? 'materialName' : 'name'],
        if (old.isNotEmpty)
          old.single[table == 'reference_materials' ? 'material_name' : 'name'],
      }.whereType<String>().toList();
      for (final name in sourceNames) {
        for (final result in await db.query(
          'lab_sample_tests',
          where:
              "source_type = ? AND source_name = ? AND COALESCE(entry_code, '') = ''",
          whereArgs: [ownScope, name],
        )) {
          await _record('labResult', result, scope);
        }
      }
      for (final reset in await db.query('nir_validation_settings')) {
        await _record('nirValidationSettings', reset, scope);
      }
      for (final formula in await db.query('nutrition_formulations')) {
        final items = jsonDecode('${formula['items_json'] ?? '[]'}');
        final parameters = secureJson(formula['parameters_json']);
        final involved = definition['entityType'] == 'labProduct'
            ? (parameters['_product_reference'] is Map &&
                  (parameters['_product_reference'] as Map)['remote_id'] ==
                      definition['entityId'])
            : items is List &&
                  items.whereType<Map>().any(
                    (item) =>
                        item['_material_remote_id'] == definition['entityId'] ||
                        (item['_material_remote_id'] == null &&
                            old.isNotEmpty &&
                            item['material_name'] ==
                                old.single['material_name']),
                  );
        if (!involved) continue;
        final formulaNames = <String>{};
        if (items is List) {
          for (final item in items.whereType<Map>()) {
            formulaNames.addAll(
              targets['raw_material|${item['_material_remote_id']}'] ??
                  targets['raw_material|@${item['material_name']}'] ??
                  const <String>{},
            );
          }
        }
        final productRef = parameters['_product_reference'];
        if (productRef is Map) {
          formulaNames.addAll(
            targets['product|${productRef['remote_id']}'] ?? const <String>{},
          );
        }
        await _record(
          'nutritionFormulation',
          formula,
          SecureMigrationScope(
            job,
            formulaNames,
            secureTargets: targets,
            privacyEpoch: epoch,
          ),
        );
      }
    }
    // Stamp every public measurement/derived record before advancing the
    // read epoch. A historical read cannot use a pre-privacy document image.
    final stamp = SecureMigrationScope(
      job,
      const {},
      secureTargets: targets,
      privacyEpoch: epoch,
      metadataOnly: true,
    );
    for (final type in [
      'sample',
      'productBatchSample',
      'labResult',
      'nirValidationSettings',
      'nutritionFormulation',
    ]) {
      final entity = SyncEntity.byType(type)!;
      for (final row in await db.query(entity.localTable)) {
        await _record(type, row, stamp);
      }
    }
    await _put({...control, 'complete': true});
    payload['securePolicyJob'] = job;
    for (final write in writes) {
      write['privacyMigrationJob'] = job;
    }
    return () async {
      _check(actor.uid, actor.organizationId, actor.deviceId);
      await _put({...control, 'complete': true, 'pending': false});
    };
  }

  void _check(String uid, String org, String device) {
    if (source.session.uid != uid ||
        source.session.organizationId != org ||
        source.session.deviceId != device ||
        !access.mayManage) {
      throw const AuthorizationError(
        'تغيرت الجلسة أثناء نقل البيانات المحمية.',
      );
    }
  }

  Future<void> _record(
    String type,
    Map<String, Object?> raw,
    SecureMigrationScope scope,
  ) async {
    if (raw['secure_policy_job'] == scope.jobId) return;
    Map<String, dynamic> row = Map<String, dynamic>.from(raw);
    if (row['secure_entry_id'] != null && !scope.metadataOnly) {
      if (!access.enabled) {
        throw const AuthorizationError(
          'فعّل رؤية Secure من الإعدادات لاستكمال تغيير حماية البيانات الموجودة.',
        );
      }
      row = await access.reveal(type, row);
      if (row['_securePublic'] == null) {
        throw const ValidationError(
          'تعذرت قراءة البيانات المحمية؛ لم يتم تغيير السجل.',
        );
      }
    }
    final entity = SyncEntity.byType(type)!;
    final columns = (await (await databaseHelper.database).rawQuery(
      'PRAGMA table_info(${entity.localTable})',
    )).map((r) => r['name']).toSet();
    final patch = <String, Object?>{};
    for (final field in [
      'physical_reference_json',
      'chemical_reference_json',
      'physical_results_json',
      'chemical_results_json',
      'dynamic_values_json',
      'result_text',
      'calibration_snapshot_json',
      'parameter',
      'reset_note',
      'parameters_json',
      'calculation_json',
      'source_snapshot_json',
      'graph_parameters_json',
    ]) {
      if (columns.contains(field) && row.containsKey(field)) {
        patch[field] = row[field];
      }
    }
    if (scope.metadataOnly) patch.clear();
    patch['public_privacy_epoch'] = scope.privacyEpoch;
    patch['secure_policy_job'] = scope.jobId;
    // Reconstruct duplicate snapshot result/reference maps without altering
    // historical dates, bounds, decisions or the measured numbers.
    if (type == 'sample' && !scope.metadataOnly) {
      final snapshot = secureJson(row['snapshot_json']);
      for (final field in [
        'physical_reference',
        'chemical_reference',
        'physical_results',
        'chemical_results',
      ]) {
        if (row['${field}_json'] is String) {
          snapshot[field] = jsonDecode(row['${field}_json'] as String);
        }
      }
      patch['snapshot_json'] = jsonEncode(snapshot);
    }
    await scope.run(
      () => databaseHelper.businessTransaction((txn) async {
        await txn.update(
          entity.localTable,
          patch,
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        final updated = Map<String, dynamic>.from(
          (await txn.query(
            entity.localTable,
            where: 'id = ?',
            whereArgs: [row['id']],
          )).single,
        );
        await enqueueLocalChange(
          executor: txn,
          entity: entity,
          row: updated,
          operation: row['deleted_at'] == null ? 'update' : 'tombstone',
          queue: queue,
          organizationId: source.session.organizationId,
          uid: source.session.uid,
          deviceId: source.session.deviceId,
        );
      }),
    );
  }
}
