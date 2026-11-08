import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../auth/session_source.dart';
import '../commands/firestore_direct_store.dart';
import '../utils/app_exceptions.dart';
import 'secure_field_policy.dart';
import 'secure_payload_compiler.dart';

/// Explicit, session-bound reveal. Plaintext is only returned to the requesting
/// view; it is never placed in SQLite, sync state, preferences or reports.
class SecureFieldAccess extends ChangeNotifier {
  SecureFieldAccess({
    required this.source,
    required this.sessionChanges,
    required this.authTime,
    this.store,
  }) {
    _identity = _sessionIdentity;
    sessionChanges.addListener(_sessionChanged);
  }
  final SessionSource source;
  final Listenable sessionChanges;
  final FirestoreDirectStore? store;
  final Future<int?> Function() authTime;
  String _identity = '';
  int _epoch = 0;
  bool _enabled = false;
  bool get mayManage => SecureFieldPolicy(session: source.session).mayManage;
  bool get enabled => _enabled && mayManage && _identity == _sessionIdentity;
  String get _sessionIdentity =>
      '${source.session.uid}|${source.session.organizationId}|${source.session.rolesKey}|${source.session.signedInAt}|${source.session.isActiveMember}|${source.session.organizationStatus}';
  void _sessionChanged() {
    if (_identity == _sessionIdentity && mayManage) return;
    _identity = _sessionIdentity;
    _enabled = false;
    _epoch++;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    final epoch = ++_epoch;
    if (!value) {
      _enabled = false;
      notifyListeners();
    }
    if (!mayManage || store == null) {
      throw const AuthorizationError(
        'الرؤية متاحة لصاحب المؤسسة ومدير الجودة فقط.',
      );
    }
    final identity = _sessionIdentity;
    final s = source.session;
    final time = await authTime();
    if (time == null || identity != _sessionIdentity || epoch != _epoch) {
      throw const AuthorizationError('تغيرت الجلسة.');
    }
    final path = 'organizations/${s.organizationId}/secureVisibility/${s.uid}';
    final previous = await store!.get(path);
    final write = store!.write(
      path,
      {'enabled': value, 'authTime': time, 'deviceId': s.deviceId},
      current: previous,
      timestamps: ['updatedAt'],
    );
    await store!.request(
      '${store!.documents}:commit',
      body: {
        'writes': [write],
      },
    );
    final verified = await store!.get(path);
    if (epoch != _epoch || identity != _sessionIdentity || !mayManage) return;
    if (verified?.data['enabled'] != value ||
        verified?.data['authTime'] != time ||
        verified?.data['deviceId'] != s.deviceId) {
      throw const ValidationError('لم يتأكد حفظ إعداد الرؤية.');
    }
    _enabled = value;
    notifyListeners();
  }

  static Map<String, dynamic> publicRecord(Map<String, dynamic> record) =>
      Map<String, dynamic>.from(record['_securePublic'] as Map? ?? record);

  Future<Map<String, dynamic>> reveal(
    String kind,
    Map<String, dynamic> record,
  ) async => (await revealMany(kind, [record])).single;

  Future<List<Map<String, dynamic>>> revealMany(
    String kind,
    List<Map<String, dynamic>> records,
  ) async {
    final public = records.map(publicRecord).toList();
    if (!enabled || store == null) return public;
    final epoch = _epoch;
    final root = 'organizations/${source.session.organizationId}/labConfig/';
    final ids = public
        .map((r) => r['secure_entry_id'])
        .whereType<String>()
        .where((id) => RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id))
        .toSet()
        .toList();
    final documents = <String, DirectDocument>{};
    for (var offset = 0; offset < ids.length; offset += 100) {
      final docs = await store!.getMany([
        for (final id in ids.skip(offset).take(100)) '$root$id',
      ]);
      if (!enabled || epoch != _epoch) return public;
      for (final doc in docs) {
        documents[doc.id] = doc;
      }
    }
    if (!enabled || epoch != _epoch) return public;
    return [
      for (final row in public)
        _merge(kind, row, documents[row['secure_entry_id']]),
    ];
  }

  Map<String, dynamic> _merge(
    String kind,
    Map<String, dynamic> public,
    DirectDocument? doc,
  ) {
    if (doc == null ||
        doc.data['sourceKind'] != kind ||
        doc.data['configType'] != 'secure_field_submissions') {
      return public;
    }
    final parent = (doc.data['parentRefs'] as Map?)?.values.firstOrNull;
    if (parent is! Map || parent['entityId'] != public['remote_id']) {
      throw const ValidationError('رابط البيانات المحمية غير متطابق.');
    }
    final fields = secureJson(doc.data['fieldsJson']);
    if (kind == 'nirValidationSettings') {
      fields['calibration_snapshot_json'] = doc.data['originalSnapshotJson'];
      fields['parameter'] = doc.data['originalParameter'];
      fields['reset_note'] = doc.data['originalNote'];
    }
    final result = {...public, '_securePublic': public};
    if (kind == 'nutritionFormulation' &&
        doc.data['sourceVersion'] != public['version']) {
      return result;
    }
    for (final entry in fields.entries) {
      if (entry.key.endsWith('_json')) {
        final key = entry.key.substring(0, entry.key.length - 5);
        final private = jsonDecode('${entry.value}');
        final original =
            public[key] ??
            (public[entry.key] is String
                ? jsonDecode(public[entry.key] as String)
                : null);
        final merged =
            kind == 'nirValidationSettings' || kind == 'nutritionFormulation'
            ? private
            : private is Map
            ? {...?original as Map?, ...private}
            : private is List
            ? [...?original as List?, ...private]
            : private;
        result[key] = merged;
        result[entry.key] = jsonEncode(merged);
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  @override
  void dispose() {
    sessionChanges.removeListener(_sessionChanged);
    super.dispose();
  }
}
