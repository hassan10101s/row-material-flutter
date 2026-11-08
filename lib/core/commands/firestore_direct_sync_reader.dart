import '../auth/permissions.dart';
import '../auth/session_source.dart';
import 'command_contract.dart';
import 'central_sync_transport.dart';
import 'firestore_direct_store.dart';
import 'firestore_direct_command_transport.dart';
import 'firestore_direct_admission.dart';
import 'central_projection.dart';

class FirestoreDirectSyncReader implements ConsistentCentralSyncReader {
  FirestoreDirectSyncReader({
    required this.store,
    required this.source,
    required this.manifest,
  });
  final FirestoreDirectStore store;
  final SessionSource source;
  final Future<Map<String, dynamic>> Function() manifest;

  String get _root => 'organizations/${source.session.organizationId}';

  @override
  Future<CentralReadBoundary> readHead() async {
    final actor = source.session;
    if (!actor.isSignedIn || !actor.isActiveMember || !actor.hasOrganization) {
      refuseDirect(CommandErrorCodes.unauthenticated, 'سجّل الدخول أولًا.');
    }
    final head = await store.head('$_root/counters/changeSequence');
    if (head.document == null) {
      refuseDirect(
        CommandErrorCodes.protocolNotReady,
        'تعذر تنزيل الأرشيف: المؤسسة على السيرفر لم تُهيأ للبروتوكول الحالي (عداد التغييرات غير موجود). يلزم إكمال الترحيل؛ لم تُرفع أي بيانات محلية.',
      );
    }
    final seq = head.document?.data['value'];
    if (seq is! int || seq < 0 || seq > 9007199254740991) {
      refuseDirect(
        CommandErrorCodes.protocolNotReady,
        'عداد المزامنة غير صالح.',
      );
    }
    checkDirectSession(source, actor);
    return CentralReadBoundary(
      sequence: seq,
      readTime: head.readTime,
      manifestVersion: 1,
    );
  }

  Map _definition(Map definitions, String type) {
    final def = type == 'auditLog'
        ? const {'collection': 'auditLogs', 'readPermission': 'audit.read'}
        : definitions[type];
    final permission = def is Map
        ? Permission.byId('${def['readPermission']}')
        : null;
    if (def is! Map || def['privateRead'] == true || permission == null || !source.session.can(permission)) {
      refuseDirect(
        CommandErrorCodes.permissionDenied,
        'صلاحية القراءة غير متاحة.',
      );
    }
    return def;
  }

  ApprovedRecord _approved(String type, DirectDocument doc) {
    _validRecord(doc, source.session.organizationId);
    return ApprovedRecord(
      entityType: type,
      entityId: doc.id,
      version: doc.data['version'] as int,
      data: doc.data,
    );
  }

  @override
  Future<CentralRecordPage> readSnapshotPage(
    String entityType,
    CentralReadBoundary boundary, {
    String? after,
  }) async {
    final actor = source.session;
    final defs = (await manifest())['entities'] as Map;
    final def = _definition(defs, entityType);
    final docs = await store.query(
      '$_root/${def['collection']}',
      after: after,
      configType: def['collection'] == 'labConfig'
          ? def['table'] as String
          : null,
      readTime: boundary.readTime,
      limit: 100,
    );
    checkDirectSession(source, actor);
    return CentralRecordPage([
      for (final doc in docs) _approved(entityType, doc),
    ], docs.length == 100 ? docs.last.id : null);
  }

  @override
  Future<CentralChangeSet> readChanges(
    int afterSequence,
    CentralReadBoundary boundary,
  ) async {
    final actor = source.session;
    if (afterSequence < 0 || afterSequence > boundary.sequence) {
      throw const CentralSyncGap();
    }
    final defs = (await manifest())['entities'] as Map;
    final targets = <String, ({String type, int version})>{};
    final operations = <String>{};
    for (
      var start = afterSequence + 1;
      start <= boundary.sequence;
      start += 50
    ) {
      final end = (start + 50).clamp(start, boundary.sequence + 1);
      final docs = await store.getMany([
        for (var seq = start; seq < end; seq++)
          '$_root/changeEvents/event_$seq',
      ], readTime: boundary.readTime);
      final events = {for (final d in docs) d.data['seq']: d};
      for (var seq = start; seq < end; seq++) {
        final event = events[seq];
        if (event == null ||
            event.data['mode'] != firestoreDirectMode ||
            event.data['records'] is! List ||
            event.data['operationId'] is! String) {
          throw const CentralSyncGap();
        }
        operations.add(event.data['operationId'] as String);
        for (final raw in event.data['records'] as List) {
          if (raw is! Map ||
              !directSafeId(raw['entityId']) ||
              raw['entityType'] is! String ||
              raw['version'] is! int) {
            throw const CentralSyncGap();
          }
          final type = raw['entityType'] as String;
          final def = defs[type];
          if (def is! Map) throw const CentralSyncGap();
          final permission = Permission.byId('${def['readPermission']}');
          if (def['privateRead'] == true || permission == null || !actor.can(permission)) continue;
          final path = '$_root/${def['collection']}/${raw['entityId']}';
          final version = raw['version'] as int;
          if (version < 1 || (targets[path]?.version ?? 0) >= version) {
            throw const CentralSyncGap();
          }
          targets[path] = (type: type, version: version);
        }
      }
      checkDirectSession(source, actor);
    }
    final records = <ApprovedRecord>[];
    // Command audits are committed atomically with their business effects.
    // Fetch them only for authorized audit readers, at the same read boundary.
    if (actor.can(Permission.byId('audit.read')!)) {
      for (final operation in operations) {
        targets['$_root/auditLogs/cmd_$operation'] = (
          type: 'auditLog',
          version: 1,
        );
      }
    }
    final paths = targets.keys.toList();
    for (var i = 0; i < paths.length; i += 50) {
      final chunk = paths.sublist(i, (i + 50).clamp(i, paths.length));
      final docs = await store.getMany(chunk, readTime: boundary.readTime);
      if (docs.length != chunk.length) throw const CentralSyncGap();
      for (final doc in docs) {
        final path = doc.name.substring(store.documents.length + 1);
        final target = targets[path];
        if (target == null || doc.data['version'] != target.version) {
          throw const CentralSyncGap();
        }
        records.add(_approved(target.type, doc));
      }
      checkDirectSession(source, actor);
    }
    return CentralChangeSet(records: records, operationIds: operations);
  }

  @override
  Future<Map<String, dynamic>> call(Map<String, Object?> data) async {
    final context = await loadDirectContext(store, source);
    final actor = context.actor;
    final root = context.root;
    if (data['organizationId'] != actor.organizationId ||
        data['deviceId'] != actor.deviceId) {
      refuseDirect(
        CommandErrorCodes.wrongOrg,
        'هوية طلب المزامنة غير متطابقة.',
      );
    }
    final definitions = (await manifest())['entities'] as Map;
    final head = (await store.get(
      '$root/counters/changeSequence',
    ))?.data['value'];
    if (head is! int || head < 0 || head > 9007199254740991) {
      refuseDirect(
        CommandErrorCodes.protocolNotReady,
        'عداد المزامنة غير صالح.',
      );
    }
    Map definition(String type) {
      final def = definitions[type];
      if (def is! Map || type == 'auditLog') {
        refuseDirect(CommandErrorCodes.badPayload, 'نوع سجل غير صالح.');
      }
      final permission = Permission.byId('${def['readPermission']}');
      if (def['privateRead'] == true || permission == null || !actor.can(permission)) {
        refuseDirect(
          CommandErrorCodes.permissionDenied,
          'صلاحية القراءة غير متاحة.',
        );
      }
      return def;
    }

    final mode = data['mode'];
    Map<String, dynamic> result;
    if (mode == 'beginSnapshot') {
      result = {'throughSequence': head, 'manifestVersion': 1};
    } else if (mode == 'snapshotPage') {
      final type = data['entityType'];
      final after = data['after'];
      final watermark = data['throughSequence'];
      if (type is! String ||
          watermark is! int ||
          watermark < 0 ||
          watermark > head ||
          (after != null && !directSafeId(after))) {
        refuseDirect(CommandErrorCodes.badPayload, 'مؤشر تحميل غير صالح.');
      }
      final def = definition(type);
      final docs = await store.query(
        '$root/${def['collection']}',
        after: after as String?,
        configType: def['collection'] == 'labConfig'
            ? def['table'] as String
            : null,
      );
      for (final doc in docs) {
        _validRecord(doc, actor.organizationId);
      }
      result = {
        'throughSequence': watermark,
        'records': [
          for (final doc in docs)
            {
              'entityType': type,
              'entityId': doc.id,
              'version': doc.data['version'],
              'data': doc.data,
            },
        ],
        'nextAfter': docs.length == 20 ? docs.last.id : null,
      };
    } else if (mode == 'events') {
      final after = data['afterSequence'];
      if (after is! int || after < 0 || after > head) {
        refuseDirect(CommandErrorCodes.badPayload, 'مؤشر الأحداث غير صالح.');
      }
      final end = (after + 10) < head ? after + 10 : head;
      final events = <Map<String, dynamic>>[];
      for (var seq = after + 1; seq <= end; seq++) {
        final event = await store.get('$root/changeEvents/event_$seq');
        if (event == null ||
            event.data['seq'] != seq ||
            event.data['mode'] != firestoreDirectMode ||
            event.data['records'] is! List) {
          throw const CentralSyncGap();
        }
        final records = <Map<String, dynamic>>[];
        final seen = <String>{};
        for (final raw in event.data['records'] as List) {
          if (raw is! Map ||
              raw['entityType'] is! String ||
              !directSafeId(raw['entityId']) ||
              raw['version'] is! int ||
              (raw['version'] as int) < 1 ||
              !seen.add(directKey(raw))) {
            throw const CentralSyncGap();
          }
          final type = raw['entityType'] as String;
          final def = definitions[type];
          if (def is! Map || type == 'auditLog') throw const CentralSyncGap();
          final permission = Permission.byId('${def['readPermission']}');
          if (def['privateRead'] == true || permission == null || !actor.can(permission)) continue;
          final doc = await store.get(
            '$root/${def['collection']}/${raw['entityId']}',
          );
          if (doc == null) throw const CentralSyncGap();
          _validRecord(doc, actor.organizationId);
          if ((doc.data['version'] as int) < (raw['version'] as int)) {
            throw const CentralSyncGap();
          }
          // A newer event supersedes this image; never label later contents
          // with an earlier version. The latest event will materialize it.
          if (doc.data['version'] != raw['version']) continue;
          if (def['collection'] == 'labConfig' &&
              doc.data['configType'] != def['table']) {
            throw const CentralSyncGap();
          }
          records.add({
            'entityType': type,
            'entityId': doc.id,
            'version': doc.data['version'],
            'data': doc.data,
          });
        }
        events.add({
          'sequence': seq,
          'operationId': event.data['operationId'],
          'committedAt': event.data['committedAt'],
          'records': records,
        });
      }
      result = {
        'throughSequence': head,
        'events': events,
        'hasMore': end < head,
      };
    } else {
      refuseDirect(CommandErrorCodes.badPayload, 'طلب مزامنة غير معروف.');
    }
    checkDirectSession(source, actor);
    return result;
  }

  void _validRecord(DirectDocument doc, String org) {
    if (doc.data['organizationId'] != org ||
        doc.data['version'] is! int ||
        (doc.data['version'] as int) < 1) {
      refuseDirect(
        CommandErrorCodes.protocolNotReady,
        'يوجد سجل يحتاج تجهيزًا قبل تنزيل الأرشيف.',
      );
    }
  }
}
