import '../security/secure_field_policy.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import '../auth/app_session.dart';
import '../auth/permissions.dart';
import '../sync/shared_settings.dart';
import '../utils/app_exceptions.dart';
import 'command_contract.dart';

/// A refusal from the direct-transport's own admission checks. [message] is
/// an Arabic, person-facing reason; [code] is the stable protocol code the
/// debug log and diagnostics should carry.
class DirectAdmissionFailure implements Exception, UserFacingError {
  const DirectAdmissionFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String get userMessage => message;
  @override
  String toString() => '$code: $message';
}

Never refuseDirect(String code, String message) =>
    throw DirectAdmissionFailure(code, message);

String directKey(Map ref) => '${ref['entityType']}/${ref['entityId']}';
bool directSafeId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 256 &&
    !value.contains('/') &&
    value != '.' &&
    value != '..' &&
    !RegExp(r'[\x00-\x1f]|^__.*__$').hasMatch(value);

/// All state-dependent checks run against the same Firestore transaction.
/// Firestore rules remain the independent identity/role/version boundary.
void validateDirectWrites({
  required List<Map<String, dynamic>> writes,
  required Map definitions,
  required Map<String, Map<String, dynamic>?> current,
  required Map<String, Map<String, dynamic>?> parents,
  required AppSession actor,
}) {
  final pending = {for (final w in writes) directKey(w): w};
  const managed = {
    'createdAt',
    'createdBy',
    'updatedAt',
    'updatedBy',
    'version',
    'deletedAt',
    'deviceId',
    'remoteId',
  };
  for (final w in writes) {
    final type = w['entityType'] as String;
    final def = definitions[type] as Map;
    final before = current[directKey(w)];
    final payload = Map<String, dynamic>.from(w['payload'] as Map);
    final create = w['operation'] == 'create';
    if (create ? before != null : before == null) {
      refuseDirect(
        CommandErrorCodes.versionConflict,
        'السجل غير متطابق مع العملية.',
      );
    }
    if (before != null) {
      if (before['organizationId'] != actor.organizationId) {
        refuseDirect(CommandErrorCodes.wrongOrg, 'مؤسسة السجل غير متطابقة.');
      }
      if (before['deletedAt'] != null &&
          !(w['privacyMigrationJob'] is String &&
              SecureFieldPolicy(session: actor).mayManage)) {
        refuseDirect(CommandErrorCodes.deletedCannotModify, 'السجل محذوف.');
      }
      if (before['version'] != w['expectedVersion']) {
        refuseDirect(
          CommandErrorCodes.versionConflict,
          'تغير السجل؛ حدّث البيانات وراجع التعديل.',
        );
      }
      for (final key in [
        'entryCode',
        'remoteId',
        'organizationId',
        'localId',
      ]) {
        if (before.containsKey(key) &&
            payload.containsKey(key) &&
            before[key] != payload[key]) {
          // localId is origin-owned; receiving devices have different SQL ids.
          if (key == 'localId') continue;
          refuseDirect(CommandErrorCodes.badPayload, 'هوية السجل ثابتة.');
        }
      }
    }
    final relations = Map<String, dynamic>.from(w['relations'] as Map? ?? {});
    final declared = {
      for (final p in def['parents'] as List) (p as Map)['relation']: p,
    };
    for (final e in relations.entries) {
      final p = declared[e.key];
      final r = e.value;
      if (p is! Map ||
          r is! Map ||
          r.keys.any(
            (k) => !const {
              'entityType',
              'entityId',
              'expectedVersion',
            }.contains(k),
          ) ||
          r['entityType'] != p['type'] ||
          !directSafeId(r['entityId']) ||
          r['expectedVersion'] is! int ||
          (r['expectedVersion'] as int) < 0) {
        refuseDirect(CommandErrorCodes.badPayload, 'رابط غير صالح.');
      }
      final key = directKey(r);
      final targetWrite = pending[key];
      final targetBefore = targetWrite == null ? parents[key] : current[key];
      if (r['expectedVersion'] == 0) {
        if (targetWrite == null ||
            targetWrite['operation'] != 'create' ||
            targetBefore != null) {
          refuseDirect(
            CommandErrorCodes.parentMissingOrDeleted,
            'الأب لا ينشأ ضمن العملية.',
          );
        }
      } else if (targetBefore == null ||
          targetBefore['version'] != r['expectedVersion']) {
        refuseDirect(
          CommandErrorCodes.versionConflict,
          'تغير إصدار أحد المراجع.',
        );
      }
      final effective = targetWrite == null
          ? targetBefore
          : {
              ...?targetBefore,
              ...Map<String, dynamic>.from(targetWrite['payload'] as Map),
              'organizationId': actor.organizationId,
              'deletedAt': targetWrite['operation'] == 'tombstone'
                  ? true
                  : null,
            };
      if (effective == null ||
          effective['organizationId'] != actor.organizationId) {
        refuseDirect(CommandErrorCodes.wrongOrg, 'مؤسسة المرجع غير متطابقة.');
      }
      final oldRefs = before?['parentRefs'] as Map? ?? {};
      final unchanged = oldRefs.values.any(
        (v) => v is Map && directKey(v) == key,
      );
      final returningDeletedResult =
          w['entityType'] == 'consumption' &&
          payload['eventType'] == 'REVERSAL' &&
          e.key == 'sampleTestId' &&
          targetWrite?['entityType'] == 'labResult' &&
          targetWrite?['operation'] == 'tombstone' &&
          relations['reversalOfLogId'] is Map;
      if (effective['deletedAt'] != null &&
          w['operation'] != 'tombstone' &&
          !unchanged &&
          !returningDeletedResult &&
          !(type == 'secureFieldSubmission' &&
              w['privacyMigrationJob'] is String &&
              SecureFieldPolicy(session: actor).mayManage)) {
        refuseDirect(CommandErrorCodes.parentMissingOrDeleted, 'المرجع محذوف.');
      }
      final parentDef = definitions[r['entityType']] as Map;
      if (parentDef['collection'] == 'labConfig' &&
          effective['configType'] != parentDef['table']) {
        refuseDirect(
          CommandErrorCodes.parentWrongType,
          'نوع مرجع المعمل غير متطابق.',
        );
      }
      if (type == 'productBatchSample' &&
          r['entityType'] == 'sample' &&
          (r['expectedVersion'] == 0 ||
              effective['inspectionKind'] != 'product')) {
        refuseDirect(
          CommandErrorCodes.parentWrongType,
          'العينة التشغيلية تحتاج فحص منتج معتمدًا.',
        );
      }
    }
    for (final entry in declared.entries) {
      final p = entry.value;
      if (type == 'sample' &&
          entry.key == 'materialId' &&
          payload['inspectionKind'] == 'product') {
        continue;
      }
      if (p['required'] == true && !relations.containsKey(entry.key)) {
        refuseDirect(
          CommandErrorCodes.parentMissingOrDeleted,
          'رابط مطلوب غير متاح.',
        );
      }
    }
    for (final e in (def['sqlFields'] as Map).entries) {
      final field = '${e.key}';
      final column = e.value as Map;
      if (managed.contains(field)) continue;
      if ((!payload.containsKey(field) &&
              create &&
              column['hasDefault'] != true) ||
          (payload.containsKey(field) && payload[field] == null)) {
        if (column['required'] == true &&
            !relations.containsKey(field) &&
            !(type == 'sample' &&
                payload['inspectionKind'] == 'product' &&
                field == 'materialId')) {
          refuseDirect(CommandErrorCodes.badPayload, 'حقل مطلوب: $field');
        }
      }
    }
    if (type == 'organizationSetting' &&
        !sharedSettingKeys.contains(payload['key'])) {
      refuseDirect(CommandErrorCodes.badPayload, 'الإعداد غير قابل للمشاركة.');
    }
    final next = {...?before, ...payload};
    if (type == 'sample') {
      if (!const {
        '',
        'PENDING',
        'APPROVED',
        'CONDITIONAL_APPROVAL',
        'PARTIAL_REJECTION',
        'FULL_REJECTION',
      }.contains(next['decisionStatus'])) {
        refuseDirect(CommandErrorCodes.badPayload, 'حالة الفحص غير صالحة.');
      }
      double? quantity(Object? v) => v == null || v == ''
          ? null
          : double.tryParse('$v'.trim().replaceAll(',', '.'));
      final qty = quantity(next['quantity']);
      final rejected = quantity(next['rejectedQuantity']);
      for (final key in ['quantity', 'rejectedQuantity']) {
        final raw = next[key];
        final number = quantity(raw);
        if (raw != null &&
            raw != '' &&
            (number == null || !number.isFinite || number < 0)) {
          refuseDirect(
            CommandErrorCodes.valueOutOfRange,
            'كمية الفحص غير صالحة.',
          );
        }
      }
      if (qty != null && rejected != null && rejected > qty) {
        refuseDirect(
          CommandErrorCodes.valueOutOfRange,
          'الكمية المرفوضة تتجاوز كمية الفحص.',
        );
      }
      if (before != null &&
          before['decisionStatus'] != next['decisionStatus']) {
        final rejection = RegExp(
          r'reject|رفض',
          caseSensitive: false,
        ).hasMatch('${next['decisionStatus']}');
        if (!actor.can(
          rejection ? Permission.qcReject : Permission.qcApprove,
        )) {
          refuseDirect(
            CommandErrorCodes.permissionDenied,
            'قرار الجودة يحتاج صلاحية الاعتماد.',
          );
        }
        final history = writes.where(
          (x) =>
              x['entityType'] == 'qualityCheck' &&
              ((x['relations'] as Map?)?['inspectionId']
                      as Map?)?['entityId'] ==
                  w['entityId'] &&
              (x['payload'] as Map)['oldStatus'] == before['decisionStatus'] &&
              (x['payload'] as Map)['newStatus'] == next['decisionStatus'],
        );
        if (history.length != 1) {
          refuseDirect(
            CommandErrorCodes.badPayload,
            'قرار الجودة وسجله يجب أن يحفظا معًا.',
          );
        }
      }
    }
  }
  for (final write in writes.where(
    (w) => w['entityType'] == 'productBatchSample',
  )) {
    final next = {...?current[directKey(write)], ...(write['payload'] as Map)};
    if (!const {
      '',
      'PENDING',
      'APPROVED',
      'CONDITIONAL_APPROVAL',
      'PARTIAL_REJECTION',
      'FULL_REJECTION',
      'NON_CONFORMANCE',
      null,
    }.contains(next['decisionStatus'])) {
      refuseDirect(CommandErrorCodes.badPayload, 'قرار عينة المنتج غير صحيح.');
    }
    if (next['decisionStatus'] == 'NON_CONFORMANCE' &&
        '${next['nonConformanceRemoteId'] ?? ''}'.isEmpty) {
      refuseDirect(
        CommandErrorCodes.badPayload,
        'عدم المطابقة تحتاج سجلًا مرتبطًا بالعينة.',
      );
    }
  }
  final items = {
    for (final w in writes)
      if (w['entityType'] == 'inventoryItem') w['entityId']: w,
  };
  final deltas = <String, double>{};
  final consumptionLedger = isConsumptionLedgerOperation(writes);
  if (consumptionLedger) {
    final lotDeltas = <String, double>{};
    for (final w in writes.where((w) => w['entityType'] == 'consumption')) {
      final p = w['payload'] as Map;
      final refs = w['relations'] as Map;
      final qty = p['appliedQty'];
      if (qty is! num || !qty.isFinite || qty < 0) {
        refuseDirect(CommandErrorCodes.badPayload, 'كمية الاستهلاك غير صحيحة.');
      }
      if (qty == 0) continue;
      final inventory = (refs['inventoryId'] as Map)['entityId'] as String;
      final lot = refs['lotId'];
      if (lot is! Map || !items.containsKey(inventory)) {
        refuseDirect(
          CommandErrorCodes.badPayload,
          'الاستهلاك يحتاج الرصيد والتشغيلة في العملية نفسها.',
        );
      }
      final delta = (p['eventType'] == 'REVERSAL' ? qty : -qty).toDouble();
      deltas[inventory] = (deltas[inventory] ?? 0) + delta;
      lotDeltas[lot['entityId'] as String] =
          (lotDeltas[lot['entityId']] ?? 0) + delta;
    }
    final lots = {
      for (final w in writes.where((w) => w['entityType'] == 'inventoryLot'))
        w['entityId']: w,
    };
    if (lotDeltas.keys.any((id) => !lots.containsKey(id))) {
      refuseDirect(
        CommandErrorCodes.badPayload,
        'تشغيلة الاستهلاك غائبة عن العملية.',
      );
    }
    for (final e in lots.entries) {
      final before = current[directKey(e.value)]?['qtyRemaining'];
      final after = (e.value['payload'] as Map)['qtyRemaining'];
      if (before is! num ||
          after is! num ||
          (after - before - (lotDeltas[e.key] ?? 0)).abs() >
              1e-8 * (before.abs() > 1 ? before.abs() : 1)) {
        refuseDirect(
          CommandErrorCodes.valueOutOfRange,
          'تغير التشغيلة لا يطابق الاستهلاك.',
        );
      }
    }
  }
  for (final w in writes.where(
    (w) => w['entityType'] == 'inventoryTransaction',
  )) {
    final r = (w['relations'] as Map?)?['inventoryId'] as Map?;
    final delta = (w['payload'] as Map)['quantityDelta'];
    if (r == null ||
        delta is! num ||
        !delta.isFinite ||
        !items.containsKey(r['entityId'])) {
      refuseDirect(
        CommandErrorCodes.badPayload,
        'حركة المخزون تحتاج رصيدها في العملية نفسها.',
      );
    }
    final id = r['entityId'] as String;
    deltas[id] = (deltas[id] ?? 0) + delta.toDouble();
  }
  for (final e in items.entries) {
    final before = current[directKey(e.value)]?['currentQty'] ?? 0;
    final after = (e.value['payload'] as Map)['currentQty'] ?? before;
    if (before is! num ||
        after is! num ||
        !before.isFinite ||
        !after.isFinite ||
        after < 0 ||
        (after - before - (deltas[e.key] ?? 0)).abs() >
            1e-8 *
                [
                  1.0,
                  after.abs().toDouble(),
                  before.abs().toDouble(),
                ].reduce((a, b) => a > b ? a : b)) {
      refuseDirect(
        CommandErrorCodes.valueOutOfRange,
        'تغير الرصيد لا يطابق حركات المخزون.',
      );
    }
  }
}

Set<String> directUniqueClaims(
  String type,
  Map definition,
  Map<String, dynamic> data,
  Map relations,
) {
  final keys = <String>{};
  var index = -1;
  for (final raw in definition['unique'] as List) {
    index++;
    final rule = raw as Map;
    if (rule['where'] != null &&
        !RegExp(
          r'^deleted_at\s+IS\s+NULL$',
          caseSensitive: false,
        ).hasMatch('${rule['where']}')) {
      refuseDirect(CommandErrorCodes.badPayload, 'قيد تفرّد غير مدعوم.');
    }
    if (rule['where'] != null && data['deletedAt'] != null) continue;
    final nested = data['payload'] is String
        ? jsonDecode(data['payload'] as String)
        : const {};
    final fields = rule['fields'] as List;
    final columns = rule['columns'] as List;
    final collations = rule['collations'] as List;
    final values = <dynamic>[];
    for (var i = 0; i < fields.length; i++) {
      final relation = relations[fields[i]];
      var value = relation is Map
          ? directKey(relation)
          : data[fields[i]] ?? (nested is Map ? nested[columns[i]] : null);
      if (value is String && collations[i] == 'NOCASE') {
        value = value.replaceAllMapped(
          RegExp('[A-Z]'),
          (m) => m[0]!.toLowerCase(),
        );
      }
      if (value is String && collations[i] == 'RTRIM') {
        value = value.replaceFirst(RegExp(r' +$'), '');
      }
      if (!const {'BINARY', 'NOCASE', 'RTRIM'}.contains(collations[i])) {
        refuseDirect(CommandErrorCodes.badPayload, 'قيد ترتيب غير مدعوم.');
      }
      values.add(value);
    }
    if (!values.contains(null)) {
      // Deliberately simple, length-prefixed UTF-8 encoding: Firestore rules
      // recompute this digest from the actual persisted fields. The general
      // command canonicalizer cannot be reproduced safely in rules.
      final wire = StringBuffer('u2|$type|$index|');
      for (final value in values) {
        final text = value is num && value == value.truncateToDouble()
            ? value.toInt().toString()
            : '$value';
        wire.write('${utf8.encode(text).length}:$text');
      }
      keys.add(crypto.sha256.convert(utf8.encode(wire.toString())).toString());
    }
  }
  return keys;
}
