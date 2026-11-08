import '../auth/app_session.dart';
import '../auth/permissions.dart';
import '../auth/session_source.dart';
import '../utils/app_exceptions.dart';
import 'command_contract.dart';
import 'command_transport.dart';
import 'firestore_direct_store.dart';
import 'firestore_direct_admission.dart';
import 'local_domain_permissions.dart';
import 'qc_audit_contract.dart';

const firestoreDirectMode = 'firestore_direct_v2';

class DirectContext {
  const DirectContext(this.actor, this.organization, this.root);
  final AppSession actor;
  final Map<String, dynamic> organization;
  final String root;
}

Future<DirectContext> loadDirectContext(
  FirestoreDirectStore store,
  SessionSource source, {
  String? transaction,
  bool writing = false,
}) async {
  final session = source.session;
  if (!session.isSignedIn ||
      !session.hasOrganization ||
      session.deviceId.isEmpty) {
    refuseDirect(CommandErrorCodes.unauthenticated, 'سجّل الدخول أولًا.');
  }
  final root = 'organizations/${session.organizationId}';
  final docs = await Future.wait([
    store.get('users/${session.uid}', transaction: transaction),
    store.get(root, transaction: transaction),
    store.get('$root/devices/${session.deviceId}', transaction: transaction),
  ]);
  final profile = docs[0]?.data;
  final org = docs[1]?.data;
  final device = docs[2]?.data;
  if (profile == null ||
      profile['organizationId'] != session.organizationId ||
      profile['status'] != 'active') {
    refuseDirect(
      CommandErrorCodes.permissionDenied,
      'العضوية غير نشطة أو مؤسسة الحساب تغيرت.',
    );
  }
  if (org == null || !const {'active', 'trial'}.contains(org['status'])) {
    refuseDirect(CommandErrorCodes.orgSuspended, 'المؤسسة غير متاحة.');
  }
  if (device == null ||
      device['uid'] != session.uid ||
      (device['status'] ?? 'active') != 'active') {
    refuseDirect(CommandErrorCodes.deviceUntrusted, 'الجهاز غير معتمد.');
  }
  final rawRoles = profile.containsKey('roles')
      ? profile['roles']
      : [profile['role']];
  if (rawRoles is! List ||
      rawRoles.any((role) => role is! String) ||
      !AppRoles.isValidAssignment(rawRoles.cast<String>()) ||
      rawRoles.first != profile['role']) {
    refuseDirect(CommandErrorCodes.permissionDenied, 'أدوار الحساب غير صالحة.');
  }
  final actor = AppSession(
    uid: session.uid,
    organizationId: session.organizationId,
    deviceId: session.deviceId,
    role: '${profile['role'] ?? ''}',
    roles: rawRoles.cast<String>(),
    status: '${profile['status']}',
    organizationStatus: '${org['status']}',
    readOnlyDevice: device['readOnly'] != false,
  );
  if (profile.containsKey('roles') && profile['roles'] is! List ||
      actor.permissions.isEmpty ||
      (profile['roles'] is List &&
          ((profile['roles'] as List).isEmpty ||
              (profile['roles'] as List).first != profile['role']))) {
    refuseDirect(CommandErrorCodes.permissionDenied, 'أدوار الحساب غير صالحة.');
  }
  if (actor.rolesKey != session.rolesKey) {
    refuseDirect(
      CommandErrorCodes.unauthenticated,
      'تغيرت صلاحيات الحساب؛ أعد تسجيل الدخول.',
    );
  }
  if (org['status'] == 'trial' &&
      org['manuallyActivated'] != true &&
      org['trialEndsAt'] != null) {
    final end = DateTime.tryParse('${org['trialEndsAt']}');
    if (end == null || !end.isAfter(DateTime.now().toUtc())) {
      refuseDirect(CommandErrorCodes.orgSuspended, 'انتهت الفترة التجريبية.');
    }
  }
  final gate = org['commandProtocol'] as Map? ?? {};
  if (gate['enabled'] != true ||
      gate['mode'] != firestoreDirectMode ||
      gate['schemaVersion'] != commandSchemaVersion ||
      gate['domainManifestVersion'] != 1 ||
      gate['globalReferencesReady'] != true ||
      gate['uniqueAdmissionComplete'] != true ||
      gate['writePolicy'] != 'multi_authorized' ||
      gate['maintenance'] != false ||
      gate['migrationId'] is! String) {
    refuseDirect(
      CommandErrorCodes.protocolNotReady,
      'ترحيل المزامنة المباشرة لم يكتمل لهذه المؤسسة.',
    );
  }
  if (writing && !actor.canWrite) {
    refuseDirect(
      CommandErrorCodes.readOnlyDevice,
      'الحساب أو الجهاز غير مسموح له بالكتابة.',
    );
  }
  checkDirectSession(source, actor);
  return DirectContext(actor, org, root);
}

void checkDirectSession(SessionSource source, AppSession expected) {
  final actual = source.session;
  if (actual.uid != expected.uid ||
      actual.organizationId != expected.organizationId ||
      actual.deviceId != expected.deviceId ||
      actual.rolesKey != expected.rolesKey ||
      !actual.isActiveMember) {
    refuseDirect(
      CommandErrorCodes.cancelled,
      'تغيرت الجلسة؛ أوقف إرسال العملية.',
    );
  }
}

class FirestoreDirectCommandTransport
    implements CommandTransport, CommandReceiptReader {
  FirestoreDirectCommandTransport({
    required this.store,
    required this.source,
    required this.manifest,
    this.onDiagnostic,
  });
  final FirestoreDirectStore store;
  final SessionSource source;
  final Future<Map<String, dynamic>> Function() manifest;
  final void Function(String code, String message)? onDiagnostic;

  @override
  Future<CommandResult?> lookupReceipt(CommandEnvelope envelope) async {
    final context = await loadDirectContext(store, source);
    if (envelope.organizationId != context.actor.organizationId) {
      refuseDirect(CommandErrorCodes.wrongOrg, 'الطلب لا يخص المؤسسة الحالية.');
    }
    final saved = await store.get(
      '${context.root}/commandReceipts/${envelope.operationId}',
    );
    if (saved == null) return null;
    return _receipt(
      saved,
      envelope,
      context.actor,
      hashPayload(envelope.toWire()),
    );
  }

  @override
  Future<CommandResult> submit(CommandEnvelope envelope) async {
    try {
      if (envelope.commandType != CommandTypes.domainCommit ||
          envelope.schemaVersion != commandSchemaVersion ||
          envelope.expectedVersion != 0 ||
          !directSafeId(envelope.operationId) ||
          !directSafeId(envelope.entityId) ||
          envelope.payloadHash != hashPayload(envelope.payload)) {
        refuseDirect(
          CommandErrorCodes.badPayload,
          'إطار طلب المزامنة غير صالح.',
        );
      }
      final session = source.session;
      if (envelope.organizationId != session.organizationId ||
          envelope.deviceId != session.deviceId) {
        refuseDirect(
          CommandErrorCodes.wrongOrg,
          'الطلب لا يخص الجلسة الحالية.',
        );
      }
      final raw = envelope.payload['writes'];
      if (envelope.payload.keys.any((key) => key != 'writes') ||
          raw is! List ||
          raw.isEmpty ||
          raw.length > businessEffectLimit(raw) ||
          raw.any((r) => r is! Map)) {
        refuseDirect(
          CommandErrorCodes.badPayload,
          'مجموعة تغييرات غير صالحة أو أكبر من حد المعاملة.',
        );
      }
      final writes = [for (final w in raw) Map<String, dynamic>.from(w as Map)];
      final definitions = (await manifest())['entities'] as Map;
      String? retryTransaction;
      for (var attempt = 0; attempt < 7; attempt++) {
        String? transaction;
        var retrying = false;
        var committed = false;
        try {
          transaction = await store.begin(retryTransaction: retryTransaction);
          final result = await _submit(
            envelope,
            writes,
            definitions,
            transaction,
            onCommitted: () => committed = true,
          );
          return result;
        } on DirectStoreError catch (error) {
          if (const {
                'ABORTED',
                'FAILED_PRECONDITION',
                'ALREADY_EXISTS',
              }.contains(error.code) &&
              attempt < 6) {
            // Firestore grants retry priority only to an aborted transaction.
            // A failed precondition is rolled back below and must begin fresh.
            retryTransaction = error.code == 'ABORTED' ? transaction : null;
            retrying = error.code == 'ABORTED';
            final jitter = envelope.operationId.hashCode.abs() % 100;
            await Future<void>.delayed(
              Duration(milliseconds: (100 << attempt) + jitter),
            );
            continue;
          }
          rethrow;
        } finally {
          if (transaction != null && !retrying && !committed) {
            try {
              await store.rollback(transaction);
            } on Object {
              /* committed or expired */
            }
          }
        }
      }
      throw const DirectStoreError(
        'UNAVAILABLE',
        'Transaction could not finish',
      );
    } on DirectAdmissionFailure catch (e) {
      return CommandResult.retryable(envelope.operationId, e.code, e.message);
    } on AuthorizationError catch (e) {
      return CommandResult.retryable(
        envelope.operationId,
        CommandErrorCodes.permissionDenied,
        e.message,
      );
    } on ValidationError catch (e) {
      return CommandResult.retryable(
        envelope.operationId,
        CommandErrorCodes.badPayload,
        e.message,
      );
    } on DirectStoreError catch (e) {
      onDiagnostic?.call(e.code, e.message);
      final code = e.code == 'RESOURCE_EXHAUSTED'
          ? CommandErrorCodes.quotaExceeded
          : e.code == 'UNAUTHENTICATED'
          ? CommandErrorCodes.unauthenticated
          : e.code == 'PERMISSION_DENIED'
          ? CommandErrorCodes.permissionDenied
          : e.code == 'ALREADY_EXISTS' ||
                e.code == 'ABORTED' ||
                e.code == 'FAILED_PRECONDITION'
          ? CommandErrorCodes.unavailable
          : CommandErrorCodes.unavailable;
      return CommandResult.retryable(
        envelope.operationId,
        code,
        code == CommandErrorCodes.quotaExceeded
            ? 'نفدت حصة الخدمة؛ الطلب محفوظ. أعد الإرسال يدويًا بعد توفر الحصة.'
            : code == CommandErrorCodes.permissionDenied
            ? 'رفضت قواعد Firestore العملية؛ راجع الصلاحيات وتجهيز المؤسسة.'
            : 'تعذر تأكيد الحفظ؛ الطلب محفوظ لإعادة المحاولة.',
      );
    } on Object catch (error) {
      onDiagnostic?.call(CommandErrorCodes.unavailable, '$error');
      return CommandResult.retryable(
        envelope.operationId,
        CommandErrorCodes.unavailable,
        'تعذر الاتصال؛ الطلب محفوظ لإعادة المحاولة.',
      );
    }
  }

  Future<CommandResult> _submit(
    CommandEnvelope envelope,
    List<Map<String, dynamic>> writes,
    Map definitions,
    String tx, {
    required void Function() onCommitted,
  }) async {
    final context = await loadDirectContext(
      store,
      source,
      transaction: tx,
      writing: true,
    );
    final actor = context.actor;
    final root = context.root;
    final receiptPath = '$root/commandReceipts/${envelope.operationId}';
    final fingerprint = hashPayload(envelope.toWire());
    final saved = await store.get(receiptPath, transaction: tx);
    if (saved != null) return _receipt(saved, envelope, actor, fingerprint);
    validateLocalDomainPermissions(
      session: actor,
      definitions: definitions,
      writes: writes,
    );
    final currentDocs = <String, DirectDocument?>{};
    final paths = <String, String>{};
    for (final w in writes) {
      final key = directKey(w);
      final def = definitions[w['entityType']] as Map;
      paths[key] = '$root/${def['collection']}/${w['entityId']}';
    }
    final documents = await store.getManyInTransaction(
      paths.values.toList(),
      transaction: tx,
    );
    for (final entry in paths.entries) {
      currentDocs[entry.key] = documents[entry.value];
    }
    final parents = <String, Map<String, dynamic>?>{};
    final parentPaths = <String, String>{};
    for (final w in writes) {
      for (final raw in (w['relations'] as Map? ?? {}).values) {
        if (raw is! Map ||
            !directSafeId(raw['entityId']) ||
            definitions[raw['entityType']] is! Map) {
          refuseDirect(CommandErrorCodes.badPayload, 'رابط غير صالح.');
        }
        final key = directKey(raw);
        if (!currentDocs.containsKey(key) && !parentPaths.containsKey(key)) {
          final def = definitions[raw['entityType']] as Map;
          parentPaths[key] = '$root/${def['collection']}/${raw['entityId']}';
        }
      }
    }
    final parentDocs = await store.getManyInTransaction(
      parentPaths.values.toList(),
      transaction: tx,
    );
    for (final entry in parentPaths.entries) {
      parents[entry.key] = parentDocs[entry.value]?.data;
    }
    validateDirectWrites(
      writes: writes,
      definitions: definitions,
      current: {for (final e in currentDocs.entries) e.key: e.value?.data},
      parents: parents,
      actor: actor,
    );
    final counter = await store.get(
      '$root/counters/changeSequence',
      transaction: tx,
    );
    final previous = counter?.data['value'];
    if (previous is! int || previous < 0 || previous >= 9007199254740991) {
      refuseDirect(
        CommandErrorCodes.protocolNotReady,
        'عداد المزامنة غير مهيأ.',
      );
    }
    final seq = previous + 1;
    final claimed = <String, Map<String, dynamic>>{},
        released = <String, Map<String, dynamic>>{};
    for (final w in writes) {
      final type = w['entityType'] as String;
      final before = currentDocs[directKey(w)]?.data;
      final next = {
        ...?before,
        ...Map<String, dynamic>.from(w['payload'] as Map),
        'deletedAt': w['operation'] == 'tombstone' ? true : null,
      };
      if (before != null) {
        for (final key in directUniqueClaims(
          type,
          definitions[type] as Map,
          before,
          before['parentRefs'] as Map? ?? {},
        )) {
          released[key] = {'entityType': type, 'entityId': w['entityId']};
        }
      }
      for (final key in directUniqueClaims(
        type,
        definitions[type] as Map,
        next,
        w['relations'] as Map? ?? {},
      )) {
        final claim = {'entityType': type, 'entityId': w['entityId']};
        if (claimed.containsKey(key) &&
            directKey(claimed[key]!) != directKey(claim)) {
          refuseDirect(
            CommandErrorCodes.versionConflict,
            'قيمة فريدة مكررة في العملية.',
          );
        }
        claimed[key] = claim;
      }
    }
    final reservationDocs = <String, DirectDocument?>{};
    final reservationKeys = {...claimed.keys, ...released.keys};
    final reservations = await store.getManyInTransaction([
      for (final key in reservationKeys) '$root/uniqueReservations/$key',
    ], transaction: tx);
    for (final key in reservationKeys) {
      final held = reservations['$root/uniqueReservations/$key'];
      reservationDocs[key] = held;
      final incoming = claimed[key];
      if (incoming != null &&
          held != null &&
          held.data['released'] != true &&
          directKey(held.data) != directKey(incoming)) {
        refuseDirect(
          CommandErrorCodes.versionConflict,
          'القيمة الفريدة مستخدمة بالفعل.',
        );
      }
      if (incoming == null &&
          held != null &&
          directKey(held.data) != directKey(released[key]!)) {
        refuseDirect(
          CommandErrorCodes.versionConflict,
          'حجز القيمة الفريدة لا يخص السجل.',
        );
      }
    }
    final consumptionLedger = isConsumptionLedgerOperation(writes);
    final effects = <Map<String, dynamic>>[];
    final records = <Map<String, dynamic>>[];
    for (final w in writes) {
      final key = directKey(w);
      final before = currentDocs[key];
      final version = (w['expectedVersion'] as int) + 1;
      final fields = Map<String, dynamic>.from(w['payload'] as Map);
      // New labConfig records use their validated, typed top-level fields.
      // Do not carry a second, opaque JSON copy that can override them.
      fields.remove('payload');
      if (consumptionLedger && w['entityType'] == 'consumption') {
        // Global parentRefs are authoritative. Origin SQLite numbers and a
        // second lot-id stamp are reconstructed by every receiving cache.
        for (final key in [
          'sampleTestId',
          'inventoryId',
          'lotId',
          'reversalOfLogId',
          'lotRemoteId',
        ]) {
          fields.remove(key);
        }
      }
      for (final f in [
        'createdAt',
        'createdBy',
        'updatedAt',
        'updatedBy',
        'deviceId',
        'version',
        'deletedAt',
        'organizationId',
      ]) {
        fields.remove(f);
      }
      if (before != null) {
        fields['localId'] = before.data['localId'];
      }
      final refs = <String, dynamic>{};
      for (final e in (w['relations'] as Map? ?? {}).entries) {
        final ref = e.value as Map;
        final inAction = writes.where((x) => directKey(x) == directKey(ref));
        refs['${e.key}'] = {
          'entityType': ref['entityType'],
          'entityId': ref['entityId'],
          'version': inAction.isEmpty
              ? ref['expectedVersion']
              : (inAction.single['expectedVersion'] as int) + 1,
        };
      }
      final next = {
        ...?before?.data,
        ...fields,
        'organizationId': actor.organizationId,
        'version': version,
        'remoteId': w['entityId'],
        'updatedBy': actor.uid,
        'deviceId': actor.deviceId,
        'createdBy': before?.data['createdBy'] ?? actor.uid,
        'deletedAt': w['privacyMigrationJob'] != null
            ? before?.data['deletedAt']
            : null,
        'parentRefs': refs,
        'centralSequence': seq,
        'protocol': {
          'mode': firestoreDirectMode,
          'entityType': w['entityType'],
          if (consumptionLedger) 'ledgerMode': 'consumption_v1',
          'chemicalDefinitionAware': true,
          'secureFieldsAware': true,
          if (w['privacyMigrationJob'] != null)
            'secureMigration': w['privacyMigrationJob'],
          if (writes.length > maxStandardBusinessEffects)
            'effect': {
              'collection': (definitions[w['entityType']] as Map)['collection'],
              'entityType': w['entityType'],
              'entityId': w['entityId'],
              'version': version,
            },
          'operationId': envelope.operationId,
          'schemaVersion': commandSchemaVersion,
          'migrationId':
              (context.organization['commandProtocol'] as Map)['migrationId'],
          'uniqueKeys': directUniqueClaims(
            w['entityType'] as String,
            definitions[w['entityType']] as Map,
            {
              ...?before?.data,
              ...fields,
              'deletedAt': w['operation'] == 'tombstone' ? true : null,
            },
            refs,
          ).toList(),
          'ledgerPaths': [
            for (final ledger in writes)
              if (ledger['entityType'] == 'inventoryTransaction' &&
                  ((ledger['relations'] as Map?)?['inventoryId']
                          as Map?)?['entityId'] ==
                      w['entityId'])
                DirectReference(store.name(paths[directKey(ledger)]!)),
          ],
          'consumptionPaths': [
            for (final log in writes)
              if (log['entityType'] == 'consumption' &&
                  ((log['relations'] as Map?)?['inventoryId']
                          as Map?)?['entityId'] ==
                      w['entityId'])
                DirectReference(store.name(paths[directKey(log)]!)),
          ],
          'lotPaths': [
            for (final lot in writes)
              if (lot['entityType'] == 'inventoryLot' &&
                  ((lot['relations'] as Map?)?['inventoryId']
                          as Map?)?['entityId'] ==
                      w['entityId'])
                DirectReference(store.name(paths[directKey(lot)]!)),
          ],
          'qualityHistoryPath': w['entityType'] == 'sample'
              ? _historyPath(w, writes, paths)
              : null,
          'qcAuditPath': _qcAuditPath(writes, paths),
          'qcAuditId': _qcAuditPath(writes, paths)?.name.split('/').last,
          'auditOrdinal': writes.indexOf(w),
          'auditTargetPath': w['entityType'] == 'qcAudit'
              ? DirectReference(
                  store.name(
                    '$root/${(definitions[qcAuditTargets[fields['entityType']]] as Map)['collection']}/${fields['targetGlobalId']}',
                  ),
                )
              : null,
        },
      };
      if (const {
        'sample',
        'productBatchSample',
        'labResult',
        'nirValidationSettings',
        'nutritionFormulation',
      }.contains(w['entityType'])) {
        final gate = context.organization['commandProtocol'] as Map;
        next['publicPrivacyEpoch'] = w['privacyMigrationJob'] != null
            ? gate['secureMaintenanceEpoch'] ?? 0
            : gate['publicPrivacyEpoch'] ?? 0;
      }
      next.remove('payload');
      effects.add(
        store.write(
          paths[key]!,
          next,
          current: before,
          timestamps: [
            if (before == null) 'createdAt',
            'updatedAt',
            if (w['operation'] == 'tombstone' &&
                w['privacyMigrationJob'] == null)
              'deletedAt',
          ],
        ),
      );
      records.add({
        'collection': (definitions[w['entityType']] as Map)['collection'],
        'entityType': w['entityType'],
        'entityId': w['entityId'],
        'version': version,
      });
    }
    final metadata = {
      'organizationId': actor.organizationId,
      'deviceId': actor.deviceId,
      'operationId': envelope.operationId,
      'sequence': seq,
    };
    for (final w in writes.where((w) => w['entityType'] == 'labAnalysis')) {
      final defs = (w['payload'] as Map)['chemicalDefinitions'];
      if (defs is! List || defs.isEmpty || w['operation'] == 'tombstone') {
        continue;
      }
      if (defs.length > maxChemicalDefinitions) {
        throw StateError(
          'At most $maxChemicalDefinitions chemical definitions',
        );
      }
      final proof = '${envelope.operationId}_${w['entityId']}';
      final blocks =
          (defs.length + chemicalDefinitionBlockSize - 1) ~/
          chemicalDefinitionBlockSize;
      for (var block = 0; block < blocks; block++) {
        effects.add(
          store.write(
            '$root/analysisDefinitionProofs/${proof}_$block',
            {
              'analysisId': w['entityId'],
              'operationId': envelope.operationId,
              'block': block,
              'summary': false,
            },
            timestamps: ['committedAt'],
          ),
        );
      }
      effects.add(
        store.write(
          '$root/analysisDefinitionProofs/${proof}_summary',
          {
            'analysisId': w['entityId'],
            'operationId': envelope.operationId,
            'blocks': blocks,
            'summary': true,
          },
          timestamps: ['committedAt'],
        ),
      );
    }
    for (final key in {...claimed.keys, ...released.keys}) {
      final claim = claimed[key] ?? released[key]!;
      final held = reservationDocs[key];
      if (claimed.containsKey(key) &&
          released.containsKey(key) &&
          directKey(claimed[key]!) == directKey(released[key]!) &&
          held != null &&
          held.data['released'] == false &&
          directKey(held.data) == directKey(claim) &&
          held.data['recordPath'] == store.name(paths[directKey(claim)]!)) {
        continue;
      }
      effects.add(
        store.write('$root/uniqueReservations/$key', {
          ...claim,
          ...metadata,
          'released': !claimed.containsKey(key),
          'collection': (definitions[claim['entityType']] as Map)['collection'],
          'recordPath': DirectReference(
            store.name(
              '$root/${(definitions[claim['entityType']] as Map)['collection']}/${claim['entityId']}',
            ),
          ),
        }, current: reservationDocs[key]),
      );
    }
    if (isSimpleBusinessOperation(writes) &&
        writes.length > maxBusinessEffects) {
      effects.add(
        store.write(
          '$root/simpleOperationProofs/${envelope.operationId}',
          {
            'organizationId': actor.organizationId,
            'operationId': envelope.operationId,
            'sequence': seq,
            'records': records,
            'recordPaths': [
              for (final path in paths.values)
                DirectReference(store.name(path)),
            ],
          },
          timestamps: ['committedAt'],
        ),
      );
    }
    effects.add(
      store.write('$root/counters/changeSequence', {
        'value': seq,
        ...metadata,
      }, current: counter),
    );
    effects.add(
      store.write(
        '$root/changeEvents/event_$seq',
        {
          ...metadata,
          'mode': firestoreDirectMode,
          'seq': seq,
          'records': records,
          'recordPaths': [
            for (final path in paths.values) DirectReference(store.name(path)),
          ],
        },
        timestamps: ['committedAt'],
      ),
    );
    effects.add(
      store.write(
        receiptPath,
        {
          ...metadata,
          'uid': actor.uid,
          'requestHash': fingerprint,
          'payloadHash': envelope.payloadHash,
          'status': 'approved',
          'entityId': envelope.entityId,
          'committedVersion': 1,
          'changeSequence': seq,
          'migrationId':
              (context.organization['commandProtocol'] as Map)['migrationId'],
        },
        timestamps: ['committedAt'],
      ),
    );
    effects.add(
      store.write(
        '$root/auditLogs/cmd_${envelope.operationId}',
        {
          'userId': actor.uid,
          'userName': '',
          'organizationId': actor.organizationId,
          'action': 'DOMAIN_COMMITTED',
          'entityType': 'domainTransaction',
          'entityId': envelope.entityId,
          'detailsJson': '',
          'records': records,
          'deviceId': actor.deviceId,
          'version': 1,
          'operationId': envelope.operationId,
          'sequence': seq,
        },
        timestamps: ['occurredAt'],
      ),
    );
    checkDirectSession(source, actor);
    await store.commit(effects, tx);
    onCommitted();
    try {
      checkDirectSession(source, actor);
      final receipt = await store.get(receiptPath);
      if (receipt == null) {
        throw const DirectStoreError('UNAVAILABLE', 'Receipt not visible');
      }
      return _receipt(receipt, envelope, actor, fingerprint);
    } catch (error) {
      // The commit already succeeded. A failed receipt read (including a
      // permission change) must never be reported as a refused business write.
      onDiagnostic?.call(CommandErrorCodes.unavailable, '$error');
      throw const DirectStoreError(
        'UNAVAILABLE',
        'Committed; receipt unverified',
      );
    }
  }

  DirectReference? _historyPath(
    Map<String, dynamic> sample,
    List<Map<String, dynamic>> writes,
    Map<String, String> paths,
  ) {
    final matches = writes.where(
      (w) =>
          w['entityType'] == 'qualityCheck' &&
          ((w['relations'] as Map?)?['inspectionId'] as Map?)?['entityId'] ==
              sample['entityId'],
    );
    return matches.length == 1
        ? DirectReference(store.name(paths[directKey(matches.single)]!))
        : null;
  }

  DirectReference? _qcAuditPath(
    List<Map<String, dynamic>> writes,
    Map<String, String> paths,
  ) {
    for (final write in writes) {
      if (write['entityType'] == 'qcAudit') {
        return DirectReference(store.name(paths[directKey(write)]!));
      }
    }
    return null;
  }

  CommandResult _receipt(
    DirectDocument doc,
    CommandEnvelope envelope,
    AppSession actor,
    String fingerprint,
  ) {
    if (doc.data['uid'] != actor.uid ||
        doc.data['requestHash'] != fingerprint ||
        doc.data['payloadHash'] != envelope.payloadHash ||
        doc.data['deviceId'] != envelope.deviceId) {
      refuseDirect(
        CommandErrorCodes.duplicateOperationIdContent,
        'رقم العملية مستخدم لمحتوى مختلف.',
      );
    }
    final result = CommandResult.fromJson(doc.data);
    if (!result.isApproved ||
        result.operationId != envelope.operationId ||
        result.entityId != envelope.entityId) {
      throw const DirectStoreError('UNAVAILABLE', 'Invalid receipt');
    }
    checkDirectSession(source, actor);
    return result;
  }
}
