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
    this.onSkippedRecord,
  });
  final FirestoreDirectStore store;
  final SessionSource source;
  final Future<Map<String, dynamic>> Function() manifest;

  /// A single malformed server document (missing/invalid `version` or a
  /// foreign `organizationId`) is quarantined — skipped deterministically by
  /// every device so caches stay identical — instead of aborting the whole
  /// archive download. Each skip is reported here with the document path and
  /// the exact defect so the record can be repaired at the source.
  final void Function(String detail)? onSkippedRecord;
  final List<String> skippedRecords = [];
  static const int _skippedReportLimit = 50;

  void _skip(String path, String defect) {
    final detail = 'سجل تالف تم تجاهله: $path — $defect';
    skippedRecords.add(detail);
    if (skippedRecords.length > _skippedReportLimit) {
      skippedRecords.removeAt(0);
    }
    onSkippedRecord?.call(detail);
  }

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
    // The command audit trail is manual and manager-only (November 10
    // decision): its pages are the largest automatic read consumer, so only
    // the organization manager may walk `auditLogs`.
    final def = type == 'auditLog'
        ? const {'collection': 'auditLogs', 'readPermission': 'devices.read'}
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

  /// Returns a human-readable defect description when the document cannot
  /// participate in the version protocol, or null when it is valid.
  String? _defect(DirectDocument doc, String org) {
    final version = doc.data['version'];
    if (doc.data['organizationId'] != org) {
      return 'organizationId غير متطابق (${doc.data['organizationId']})';
    }
    if (version is! int || version < 1) {
      return 'version غير صالح ($version)';
    }
    return null;
  }

  ApprovedRecord? _approved(String type, DirectDocument doc, String path) {
    final defect = _defect(doc, source.session.organizationId);
    if (defect != null) {
      _skip(path, defect);
      return null;
    }
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
    final approved = <ApprovedRecord>[];
    for (final doc in docs) {
      final record = _approved(entityType, doc, '${def['collection']}/${doc.id}');
      if (record != null) approved.add(record);
    }
    return CentralRecordPage(
      approved,
      docs.length == 100 ? docs.last.id : null,
    );
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
    // The trail itself is manual and manager-only: only the organization
    // manager rides the change feed with the per-operation audit docs.
    if (actor.can(Permission.byId('devices.read')!)) {
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
        if (target == null) throw const CentralSyncGap();
        // A malformed document is quarantined, not a gap: a gap would force a
        // full snapshot rebuild that skips the same record and then gap again
        // on the next event referencing it — an endless rebuild loop.
        final defect = _defect(doc, actor.organizationId);
        if (defect != null) {
          _skip(path, defect);
          continue;
        }
        if (doc.data['version'] != target.version) {
          throw const CentralSyncGap();
        }
        records.add(_approved(target.type, doc, path)!);
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
      final pageRecords = <Map<String, dynamic>>[];
      for (final doc in docs) {
        final docPath = '${def['collection']}/${doc.id}';
        final defect = _defect(doc, actor.organizationId);
        if (defect != null) {
          // Quarantine deterministically so every device skips the same
          // record and their installed caches stay byte-identical.
          _skip(docPath, defect);
          continue;
        }
        pageRecords.add({
          'entityType': type,
          'entityId': doc.id,
          'version': doc.data['version'],
          'data': doc.data,
        });
      }
      result = {
        'throughSequence': watermark,
        'records': pageRecords,
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
          final docPath = '${def['collection']}/${doc.id}';
          final defect = _defect(doc, actor.organizationId);
          if (defect != null) {
            // Quarantine the malformed document and keep the feed moving;
            // the snapshot channel skips the same record deterministically.
            _skip(docPath, defect);
            continue;
          }
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
}
