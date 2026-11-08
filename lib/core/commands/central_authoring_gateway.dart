import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../auth/session_source.dart';
import '../database/business_transaction.dart';
import '../database/database_helper.dart';
import '../sync/sync_run_scope.dart';
import '../sync/entity_registry.dart';
import '../utils/app_exceptions.dart';
import 'command_outbox.dart';
import 'command_contract.dart';
import 'drafts_store.dart';
import 'domain_manifest.dart';
import 'local_domain_permissions.dart';
import 'qc_audit_contract.dart';
import '../audit/audit_hasher.dart';
import '../security/secure_payload_compiler.dart';

/// A saved request is not an approved business write. Callers retain their
/// authoring input while the request is waiting for a server receipt.
class CentralDraftPending extends AppError implements PendingOperation {
  CentralDraftPending(this.draftId, {bool unsent = false, bool tooLarge = false})
    : super(
        tooLarge
            ? largeOperationMessage
            : unsent
            ? 'حُفظت مسودة على هذا الجهاز. راجعها وأرسلها من المسودات عند توفر الاتصال.'
            : 'بانتظار تأكيد نتيجة العملية. يمكنك التحقق منها من المسودات دون تكرارها.',
      );

  final String draftId;
}

/// The central archive is not proven `ready` yet (`central_sync_state`), so a
/// write would base itself on an unproven archive version. Startup
/// housekeeping catches this specific type and defers the step to the sync
/// driver's `ready` transition instead of failing the bind.
class ArchiveNotReadyError extends AppError {
  const ArchiveNotReadyError(super.message);
}

/// Executes the existing domain calculation under a savepoint, captures its
/// complete write set, then rolls the business changes back before atomically
/// saving the draft and command in their durable protocol database. Approved
/// tables never contain those changes; cache identity reservations are derived.
///
/// The completion callback must return true only after a verified receipt AND
/// its complete read-model effects have been applied. A transport response by
/// itself cannot make this method return a successful domain result.
class CentralAuthoringGateway implements BusinessTransactionGateway {
  CentralAuthoringGateway({
    required this.databaseHelper,
    required this.source,
    required this.outbox,
    this.complete,
    this.isOnline,
    this.chooseOfflineDraft,
    this.onPending,
    this.prepareSecureDefinitions,
  });

  static const commandType = 'domain.commit';
  final DatabaseHelper databaseHelper;
  final SessionSource source;
  final CommandOutbox outbox;
  final Future<bool> Function(CommandOutboxEntry entry)? complete;
  final bool Function()? isOnline;

  /// Offline writes require explicit consent to retain a local manual draft.
  final Future<bool> Function()? chooseOfflineDraft;
  final void Function(String message)? onPending;
  final Future<Future<void> Function()?> Function(List<Map<String, Object?>> writes)? prepareSecureDefinitions;

  Never _pending(CentralDraftPending pending) {
    onPending?.call(pending.userMessage);
    throw pending;
  }

  Map<String, dynamic>? _manifest;
  int? _manifestGeneration;
  int? _captureGeneration;

  Future<void> _ensureCapture(
    Database db,
    Map definitions,
    int generation,
  ) async {
    if (_captureGeneration == generation) return;
    await db.execute(
      'CREATE TABLE IF NOT EXISTS central_capture_flag (enabled INTEGER NOT NULL)',
    );
    await db.execute(
      'INSERT INTO central_capture_flag(enabled) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM central_capture_flag)',
    );
    await db.execute('''CREATE TABLE IF NOT EXISTS central_capture_changes (
      entity_type TEXT NOT NULL, local_ref TEXT NOT NULL,
      first_operation TEXT NOT NULL, last_operation TEXT NOT NULL,
      PRIMARY KEY(entity_type, local_ref))''');
    for (final entry in definitions.entries) {
      final definition = entry.value as Map;
      final table = definition['table'] as String;
      final pk = definition['primaryKey'] as String;
      if (![
        table,
        pk,
        '${entry.key}',
      ].every((v) => RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(v))) {
        throw StateError('Unsafe capture identifier');
      }
      for (final operation in const ['INSERT', 'UPDATE', 'DELETE']) {
        final row = operation == 'DELETE' ? 'OLD' : 'NEW';
        await db.execute(
          '''CREATE TRIGGER IF NOT EXISTS central_capture_${table}_${operation.toLowerCase()}
          AFTER $operation ON $table WHEN (SELECT enabled FROM central_capture_flag LIMIT 1) = 1
          BEGIN
            INSERT OR IGNORE INTO central_capture_changes VALUES ('${entry.key}', CAST($row.$pk AS TEXT), '$operation', '$operation');
            UPDATE central_capture_changes SET last_operation = '$operation'
              WHERE entity_type = '${entry.key}' AND local_ref = CAST($row.$pk AS TEXT);
          END''',
        );
      }
    }
    _captureGeneration = generation;
  }

  @override
  Future<T> run<T>(
    Database database,
    Future<T> Function(DatabaseExecutor executor) operation,
  ) async {
    final scope = SyncRunScope(source, databaseHelper);
    final actor = scope.session;
    if (!actor.canWrite || !actor.isSignedIn || !actor.hasOrganization) {
      throw const AuthorizationError('ليس لديك صلاحية إنشاء طلب اعتماد.');
    }
    var offlineDraft = false;
    if (isOnline != null && !isOnline!()) {
      if (chooseOfflineDraft == null || !await chooseOfflineDraft!()) {
        throw const BusinessActionCancelled();
      }
      scope.check();
      offlineDraft = true;
    }
    final draftId = const Uuid().v4();
    if (_manifestGeneration != scope.generation) {
      _manifest = await buildDomainManifest(database);
      _manifestGeneration = scope.generation;
    }
    scope.check();
    await _ensureCapture(
      database,
      _manifest!['entities'] as Map,
      scope.generation,
    );
    late T value;
    CommandDraft? preparedDraft;
    final preparedWrites = <Map<String, Object?>>[];
    final protocolDb = await outbox.dbHelper.database;
    final protocolGeneration = outbox.dbHelper.connectionGeneration;
    final canonicalState = await protocolDb.query(
      'central_sync_state',
      where: 'organization_id = ? AND uid = ?',
      whereArgs: [actor.organizationId, actor.uid],
      limit: 1,
    );
    if (canonicalState.length != 1 ||
        canonicalState.single['role'] != actor.rolesKey ||
        canonicalState.single['protocol_schema'] != commandSchemaVersion ||
        canonicalState.single['bootstrap_state'] != 'ready') {
      // `catching_up` means the snapshot is in place but the change events the
      // server committed during its download are not fully applied yet: a save
      // here would base itself on an unproven archive version.
      throw const ArchiveNotReadyError(
        'الأرشيف المعتمد لم يكتمل تنزيله بعد؛ بانتظار استكمال أحداث التغيير. '
        'أعد المحاولة عند ظهور حالة المزامنة جاهزة.',
      );
    }
    final queuedLocks = {
      for (final row in await protocolDb.query('central_command_entities'))
        "${row['entity_type']}/${row['entity_id']}",
    };
    scope.check();
    await database.transaction((txn) async {
      scope.check();
      final oldQueue = await txn.query('sync_queue', columns: ['id'], limit: 1);
      if (oldQueue.isNotEmpty) {
        throw StateError(
          'Legacy queue must be archived before central authoring',
        );
      }
      final initialSequences = {
        for (final row in await txn.query('sqlite_sequence'))
          row['name'] as String: (row['seq'] as num).toInt(),
      };
      // A fixed, non-user-controlled savepoint name; SQLite transactions are
      // serialized and this gateway is entered only at an authoring boundary.
      await txn.execute('SAVEPOINT central_authoring');
      await txn.delete('central_capture_changes');
      await txn.update('central_capture_flag', {'enabled': 1});
      final before = (await txn.rawQuery(
        'SELECT total_changes() AS n',
      )).single['n'];
      final aggregateEffects = <String, String>{};
      value = await BusinessAuthoringContext.run(
        initialSequences,
        () => operation(txn),
        aggregateEffects: aggregateEffects,
      );
      scope.check();
      final captured = [...await txn.query('sync_queue', orderBy: 'id')];
      // QC audits are captured directly from the append-only SQL journal.
      // They never enter or reactivate the legacy upload queue.
      final auditRows = await txn.query(
        'qc_audits',
        where: 'id > ?',
        whereArgs: [initialSequences['qc_audits'] ?? 0],
        orderBy: 'id',
      );
      for (final audit in auditRows) {
        if (audit['by_user_id'] != actor.uid ||
            AuditHasher.hash(audit) != audit['hash']) {
          throw const AuthorizationError('هوية سجل الجودة أو بصمته غير صالحة.');
        }
        captured.add({
          'entity_type': 'qcAudit',
          'local_ref': audit['id'],
          'owner_uid': actor.uid,
          'status': 'pending',
          'operation': 'create',
          'base_version': 0,
        });
      }
      final declared = {
        for (final row in captured) '${row['entity_type']}/${row['local_ref']}',
      };
      final changes = await txn.query('central_capture_changes');
      for (final change in changes) {
        if (change['first_operation'] == 'INSERT' &&
            change['last_operation'] == 'DELETE') {
          continue;
        }
        final key = '${change['entity_type']}/${change['local_ref']}';
        if (const {
              'labAnalysisItem',
              'labFieldLink',
              'labUnit',
            }.contains(change['entity_type']) &&
            declared.contains(aggregateEffects[key])) {
          continue;
        }
        if (!declared.contains(key)) {
          throw StateError('Business mutation omitted its remote effect: $key');
        }
      }
      final after = (await txn.rawQuery(
        'SELECT total_changes() AS n',
      )).single['n'];
      final writes = <Map<String, Object?>>[];
      final sources =
          <String, ({SyncEntity entity, Map<String, Object?> row})>{};
      final localTargets = <String, ({String id, int version})>{};
      final reservations = <({String type, String id, int localRef})>[];
      for (final row in captured) {
        if (row['entity_type'] == 'auditLog') continue;
        if (row['owner_uid'] != actor.uid || row['status'] != 'pending') {
          throw StateError('Unowned or unsettled authoring write');
        }
        final entity = SyncEntity.byType(row['entity_type'] as String);
        final localRef = row['local_ref'];
        if (entity == null || localRef is! int) {
          throw StateError('Unregistered authoring effect');
        }
        final rows = await txn.query(
          entity.localTable,
          where: '${entity.pkColumn} = ?',
          whereArgs: [localRef],
        );
        if (rows.length != 1) {
          throw StateError('Authoring effect has no unique source row');
        }
        final known = await txn.query(
          'central_entity_identities',
          where: 'entity_type = ? AND local_ref = ?',
          whereArgs: [entity.type, localRef],
        );
        // Serialize the final transactional image, rather than a queue snapshot
        // captured before later updates within the same business operation.
        final payload = buildRemotePayload(
          entity,
          Map<String, dynamic>.from(rows.single),
          SyncPayloadContext(
            organizationId: actor.organizationId,
            uid: actor.uid,
            deviceId: actor.deviceId,
            version: (row['base_version'] as int) + 1,
            versionField: 'version',
          ),
          asCreate: row['base_version'] == 0,
        );
        final String id;
        var operationKind = row['operation'] as String;
        if (known.isNotEmpty && (known.single['approved_version'] as int) > 0) {
          id = known.single['entity_id'] as String;
          if (known.single['approved_version'] != row['base_version']) {
            throw const ValidationError(
              'نسخة الأرشيف لا تطابق أساس التعديل. أعد تنزيل السجل.',
            );
          }
          if (operationKind != 'tombstone') operationKind = 'update';
        } else if (known.isEmpty &&
            row['base_version'] == 0 &&
            ((_manifest!['entities'] as Map)[entity.type]
                    as Map)['autoIncrement'] ==
                true &&
            localRef > (initialSequences[entity.localTable] ?? 0)) {
          if (operationKind == 'tombstone') continue;
          operationKind = 'create';
          final remote = payload['remoteId'];
          id =
              remote is String &&
                  RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}$').hasMatch(remote)
              ? remote
              : const Uuid().v4();
          reservations.add((type: entity.type, id: id, localRef: localRef));
          payload['remoteId'] = id;
        } else {
          throw const ValidationError(
            'السجل غير معتمد على السيرفر؛ لا يمكن تحويل بيانات محلية قديمة إلى طلب جديد.',
          );
        }
        if (queuedLocks.contains('${entity.type}/$id')) {
          throw const ValidationError(
            'يوجد طلب سابق لهذا السجل بانتظار الحسم.',
          );
        }
        localTargets['${entity.type}/$localRef'] = (
          id: id,
          version: row['base_version'] as int,
        );
        sources['${entity.type}/$id'] = (entity: entity, row: rows.single);
        writes.add({
          'entityType': row['entity_type'],
          'entityId': id,
          'operation': operationKind,
          'expectedVersion': row['base_version'],
          'payload': payload,
        });
      }
      final definitions = _manifest!['entities'] as Map;
      for (final write in writes) {
        final sourceRow =
            sources['${write['entityType']}/${write['entityId']}']!;
        final definition = definitions[write['entityType']] as Map;
        final payload = write['payload'] as Map<String, dynamic>;
        if (sourceRow.entity.type == 'qcAudit') {
          final targetType = qcAuditTargets[payload['entityType']];
          final target =
              localTargets['$targetType/${sourceRow.row['entity_id']}'];
          if (targetType == null || target == null) {
            throw const ValidationError(
              'سجل الجودة يجب أن يرتبط بالتغيير نفسه داخل عملية الاعتماد.',
            );
          }
          payload['targetEntityType'] = targetType;
          payload['targetGlobalId'] = target.id;
          final previousHash = payload['prevHash'];
          String? previousId;
          if (previousHash is String && previousHash.isNotEmpty) {
            for (final candidate in writes) {
              if (candidate['entityType'] == 'qcAudit' &&
                  (candidate['payload'] as Map)['hash'] == previousHash) {
                previousId = candidate['entityId'] as String;
              }
            }
            if (previousId == null) {
              final previous = await txn.query(
                'central_qc_audits',
                columns: ['entity_id'],
                where: 'origin_hash = ?',
                whereArgs: [previousHash],
                limit: 1,
              );
              if (previous.isNotEmpty) {
                previousId = previous.single['entity_id'] as String;
              }
            }
            if (previousId == null) {
              throw const ValidationError(
                'سلسلة تدقيق الجودة غير مكتملة؛ أعد التحديث أولًا.',
              );
            }
          }
          payload['previousAuditId'] = previousId;
        }
        if (sourceRow.entity.type == 'qualityCheck') {
          payload['businessVersion'] = sourceRow.row['version'];
        }
        for (final rawField in definition['actors'] as List) {
          final field = rawField as String;
          if (field == 'createdBy' || field == 'updatedBy') continue;
          final original = sourceRow.row[camelToSnake(field)];
          if (original == null || original == 0) {
            payload[field] = null;
          } else if (original is num) {
            final actor = await txn.query(
              'users',
              columns: ['uid'],
              where: 'id = ?',
              whereArgs: [original],
            );
            if (actor.length != 1 ||
                actor.single['uid'] is! String ||
                (actor.single['uid'] as String).isEmpty) {
              throw const ValidationError(
                'هوية أحد أصحاب السجل غير متاحة. أعد تنزيل الأعضاء أولًا.',
              );
            }
            payload[field] = actor.single['uid'];
          } else if (original is String && original.isNotEmpty) {
            payload[field] = original;
          } else {
            throw const ValidationError('هوية صاحب السجل غير صالحة.');
          }
        }
        final relations = <String, Map<String, Object>>{};
        for (final raw in definition['parents'] as List) {
          final parent = raw as Map;
          final column = parent['localField'] as String;
          if (sourceRow.entity.type == 'sample' &&
              column == 'material_id' &&
              sourceRow.row['inspection_kind'] == 'product') {
            continue;
          }
          final local = sourceRow.row[column];
          if (local == null || local == 0) {
            if (parent['required'] == true) {
              throw ValidationError('رابط ${parent['relation']} مطلوب.');
            }
            continue;
          }
          final type = parent['type'] as String;
          var target = localTargets['$type/$local'];
          if (target == null) {
            final approved = await txn.query(
              'central_entity_identities',
              where:
                  'entity_type = ? AND local_ref = ? AND approved_version > 0',
              whereArgs: [type, local],
            );
            if (approved.length == 1) {
              target = (
                id: approved.single['entity_id'] as String,
                version: approved.single['approved_version'] as int,
              );
            }
          }
          if (target == null) {
            throw ValidationError(
              'الرابط ${parent['relation']} لا يشير إلى سجل معتمد.',
            );
          }
          relations[parent['relation'] as String] = {
            'entityType': type,
            'entityId': target.id,
            'expectedVersion': target.version,
          };
        }
        write['relations'] = relations;
      }
      await compileSecurePayloads(db: txn, session: actor, writes: writes);
      validateLocalDomainPermissions(
        session: actor,
        definitions: definitions,
        writes: writes,
      );
      final sequences = await txn.query('sqlite_sequence');
      // Restore values AND domain side effects (balances, history and audit)
      // before writing the protocol stores. An exception rolls back everything.
      await txn.execute(';ROLLBACK TO SAVEPOINT central_authoring');
      await txn.execute('RELEASE SAVEPOINT central_authoring');
      if (writes.isEmpty) {
        if (before != after) {
          throw StateError(
            'An authoring mutation did not declare its shared effects',
          );
        }
        return;
      }
      final tables = {
        for (final definition in definitions.values)
          (definition as Map)['table'],
      };
      for (final sequence in sequences) {
        if (!tables.contains(sequence['name'])) continue;
        final changed = await txn.rawUpdate(
          'UPDATE sqlite_sequence SET seq = MAX(COALESCE(seq, 0), ?) WHERE name = ?',
          [sequence['seq'], sequence['name']],
        );
        if (changed == 0) {
          await txn.insert(
            'sqlite_sequence',
            Map<String, Object?>.from(sequence),
          );
        }
      }
      for (final reservation in reservations) {
        await txn.insert('central_entity_identities', {
          'entity_type': reservation.type,
          'entity_id': reservation.id,
          'local_ref': reservation.localRef,
          'approved_version': 0,
        });
      }
      final payload = <String, dynamic>{'writes': writes};
      final now = DateTime.now().toUtc().toIso8601String();
      preparedDraft = CommandDraft(
        id: draftId,
        organizationId: actor.organizationId,
        uid: actor.uid,
        entityType: 'domainTransaction',
        operation: 'commit',
        entityId: draftId,
        baseVersion: 0,
        state: DraftState.localDraft,
        payload: payload,
        createdAt: now,
        updatedAt: now,
      );
      preparedWrites.addAll(writes);
      scope.check();
    });
    final draft = preparedDraft;
    if (draft == null) return value;
    scope.check();
    if (!offlineDraft && isOnline != null && !isOnline!()) {
      if (chooseOfflineDraft == null || !await chooseOfflineDraft!()) {
        throw const BusinessActionCancelled();
      }
      scope.check();
      offlineDraft = true;
    }
    Future<void> Function()? finishSecureDefinition;
    if (!offlineDraft && preparedWrites.length <= businessEffectLimit(preparedWrites)) {
      finishSecureDefinition = await prepareSecureDefinitions?.call(preparedWrites);
      scope.check();
    }
    final entry = await protocolDb.transaction<CommandOutboxEntry?>((
      txn,
    ) async {
      scope.check();
      if (outbox.dbHelper.connectionGeneration != protocolGeneration) {
        throw const SyncRunCancelled();
      }
      for (final write in preparedWrites) {
        final locked = await txn.query(
          'central_command_entities',
          where: 'entity_type = ? AND entity_id = ?',
          whereArgs: [write['entityType'], write['entityId']],
          limit: 1,
        );
        if (locked.isNotEmpty) {
          throw const ValidationError(
            'يوجد طلب سابق لهذا السجل بانتظار الحسم.',
          );
        }
      }
      await txn.insert('drafts', draft.toRow());
      // Offline and oversized work stays a local draft. Only an explicit
      // online action creates a send request.
      if (preparedWrites.length > businessEffectLimit(preparedWrites) ||
          offlineDraft) {
        return null;
      }
      final staged = await outbox.enqueueDraftSubmit(
        txn,
        draft: draft,
        commandType: commandType,
        entityId: draftId,
        expectedVersion: 0,
        payload: draft.payload,
        dependencies: const {},
      );
      for (final write in preparedWrites) {
        await txn.insert('central_command_entities', {
          'entity_type': write['entityType'],
          'entity_id': write['entityId'],
          'operation_id': staged.operationId,
        });
      }
      scope.check();
      return staged;
    });
    if (entry == null) {
      _pending(
        CentralDraftPending(
          draftId,
          unsent: true,
          tooLarge: preparedWrites.length > businessEffectLimit(preparedWrites),
        ),
      );
    }
    final completion = complete;
    if (completion != null && await completion(entry)) {
      scope.check();
      await finishSecureDefinition?.call();
      return publicAuthoringValue(value, preparedWrites) as T;
    }
    final current = await outbox.getByOperationId(entry.operationId);
    _pending(
      CentralDraftPending(
        draftId,
        unsent:
            current?.state == OutboxState.archived && current?.attempts == 0,
      ),
    );
  }
}
