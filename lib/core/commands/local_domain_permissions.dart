import '../security/secure_field_policy.dart';
import 'dart:convert';

import '../auth/app_session.dart';
import '../auth/permissions.dart';
import '../utils/app_exceptions.dart';

/// Client-side checks for prepared central writes. These are a fail-fast
/// safeguard, not a substitute for independently enforced Firestore rules.
void validateLocalDomainPermissions({
  required AppSession session,
  required Map definitions,
  required List<Map<String, Object?>> writes,
}) {
  if (!session.isSignedIn || !session.hasOrganization || !session.canWrite) {
    throw const AuthorizationError('ليس لديك صلاحية إنشاء طلب اعتماد.');
  }
  final identities = <String>{};
  for (final write in writes) {
    final type = write['entityType'];
    final operation = write['operation'];
    final definition = definitions[type];
    final payload = write['payload'];
    if (type is! String ||
        definition is! Map ||
        payload is! Map ||
        !const {'create', 'update', 'tombstone'}.contains(operation)) {
      throw const ValidationError('نوع العملية أو بياناتها غير صالحة.');
    }
    final id = write['entityId'];
    final version = write['expectedVersion'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 256 ||
        id.contains('/') ||
        id == '.' ||
        id == '..' ||
        RegExp(r'[\x00-\x1f]').hasMatch(id) ||
        RegExp(r'^__.*__$').hasMatch(id) ||
        version is! int ||
        version < 0 ||
        version >= 9007199254740991 ||
        (operation == 'create' && version != 0) ||
        (operation != 'create' && version < 1) ||
        !identities.add('${definition['collection']}/$id')) {
      throw const ValidationError('هوية العملية أو إصدار السجل غير صالح.');
    }
    final privacyMigration = write['privacyMigrationJob'] is String && SecureFieldPolicy(session: session).mayManage;
    if (definition['appendOnly'] == true && operation != 'create' && !(type == 'nirValidationSettings' && privacyMigration)) {
      throw const ValidationError('هذا السجل لا يسمح بالتعديل أو الحذف.');
    }
    var permission = definition['permission'];
    if (type == 'sample' && operation == 'create') {
      permission = 'samples.create';
    } else if (type == 'qualityCheck') {
      final status = '${payload['newStatus'] ?? ''}';
      permission = RegExp(r'reject|رفض', caseSensitive: false).hasMatch(status)
          ? 'qc.reject'
          : 'qc.approve';
    } else if (type == 'member') {
      permission = operation == 'create'
          ? 'users.create'
          : (operation == 'tombstone' || payload['status'] == 'disabled'
                ? 'users.disable'
                : 'users.update');
    }
    if (type == 'nutritionFormulation' && privacyMigration) permission = 'lab_results.update';
    final requiredPermission = permission is String
        ? Permission.byId(permission)
        : null;
    if (requiredPermission == null || !session.can(requiredPermission)) {
      throw const AuthorizationError('صلاحية التغيير غير متاحة لهذا الحساب.');
    }
    final org = payload['organizationId'];
    if (org != null && org != session.organizationId) {
      throw const AuthorizationError('مؤسسة السجل غير متطابقة مع الحساب.');
    }
    final fields = definition['fields'];
    if (fields is! List ||
        payload.keys.any((key) => key is! String || !fields.contains(key))) {
      throw const ValidationError('يحتوي الطلب على حقل غير مسموح.');
    }
    for (final entry in payload.entries) {
      final key = entry.key as String;
      final value = entry.value;
      if (value is num &&
          (!value.isFinite ||
              (value.abs() > 9007199254740991 &&
                  value == value.truncateToDouble()))) {
        throw const ValidationError('يحتوي الطلب على قيمة عددية غير صالحة.');
      }
      if ((key.endsWith('Json') || key == 'payload') &&
          value != null &&
          value != '') {
        if (value is! String) {
          throw const ValidationError('تنسيق بيانات JSON غير صالح.');
        }
        Object? decoded;
        try {
          decoded = jsonDecode(value);
        } on FormatException {
          throw const ValidationError('تنسيق بيانات JSON غير صالح.');
        }
        if (decoded is! Map && decoded is! List) {
          throw const ValidationError('بنية بيانات JSON غير صالحة.');
        }
      }
    }
    final sqlFields = definition['sqlFields'];
    final actors = definition['actors'];
    if (sqlFields is Map) {
      for (final entry in sqlFields.entries) {
        final field = entry.key;
        final column = entry.value;
        if (field is! String || column is! Map || !payload.containsKey(field)) {
          continue;
        }
        final value = payload[field];
        if (value == null ||
            const {
              'createdAt',
              'createdBy',
              'updatedAt',
              'updatedBy',
              'version',
              'deletedAt',
              'deviceId',
              'remoteId',
            }.contains(field)) {
          continue;
        }
        if (actors is List && actors.contains(field)) {
          if (value is! String || value.isEmpty || value.contains('/')) {
            throw const ValidationError('هوية صاحب السجل غير صالحة.');
          }
          continue;
        }
        final sqlType = '${column['type'] ?? ''}'.toUpperCase();
        if (RegExp('INT|REAL|FLOAT|DOUBLE|NUMERIC').hasMatch(sqlType)) {
          if (value is! num ||
              !value.isFinite ||
              (sqlType.contains('INT') && value != value.truncateToDouble())) {
            throw const ValidationError('نوع حقل عددي غير صالح.');
          }
        } else if (RegExp('TEXT|CHAR|CLOB').hasMatch(sqlType) &&
            value is! String) {
          throw const ValidationError('نوع حقل نصي غير صالح.');
        }
      }
    }
    final payloadFields = definition['payloadFields'];
    final nestedValue = payload['payload'];
    if (payloadFields is List &&
        nestedValue is String &&
        nestedValue.isNotEmpty) {
      final nested = jsonDecode(nestedValue);
      if (nested is! Map ||
          nested.keys.any((key) => !payloadFields.contains(key)) ||
          payload['configType'] != definition['table']) {
        throw const ValidationError('محتوى إعدادات المعمل غير مسموح.');
      }
    }
  }
}
