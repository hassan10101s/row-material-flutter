const {HttpsError} = require('firebase-functions/v2/https');
const {SCHEMA_VERSION, COMMAND_DEFS, validateSessionFrame, validateMembership,
  requestHash, httpsCodeFor, profileRoles} = require('./commands');
const {definition, validateWriteSet, validateAgainstCurrent} = require('./domain_commands');
const {uniqueClaims, validateRelations, validateInventoryEffects, keyOf} = require('./domain_admission');

function stop(code, messageAr) {
  throw new HttpsError(httpsCodeFor(code), messageAr, {code, messageAr});
}
function check(error) { if (error) stop(error.code, error.messageAr); }
function trialExpired(org) {
  if (org.status !== 'trial' || org.manuallyActivated === true || !org.trialEndsAt) return false;
  const end = org.trialEndsAt.toMillis ? org.trialEndsAt.toMillis() : Date.parse(org.trialEndsAt);
  return !Number.isFinite(end) || end <= Date.now();
}

/**
 * Serializable stand-in for commit-managed times inside `changes[].data`.
 * Firestore's Admin SDK rejects `FieldValue.serverTimestamp()` inside an
 * array ("cannot be used inside of an array") BEFORE the transaction is
 * ever sent, which would make every `domain.commit` unusable. The event's
 * top-level `committedAt` field (outside the array) carries the real
 * server-transaction time; clients resolve this placeholder against it, so
 * an event-delivered version and a snapshot-delivered version of the same
 * record are byte-identical and hash identically.
 *
 * Must stay equal to `centralCommitTimePlaceholder` in
 * `lib/core/commands/central_projection.dart`.
 */
const centralCommitTimePlaceholder = '__CENTRAL_EVENT_COMMIT_TIME__';

/** One receipt covers every effect. No client cache is updated by this code. */
function buildDomainSubmitHandler(admin) {
  return async request => {
    const uid = request.auth && request.auth.uid;
    if (!uid) stop('UNAUTHENTICATED', 'سجّل الدخول أولًا.');
    const data = request.data;
    check(validateSessionFrame(data));
    if (data.commandType !== 'domain.commit' || data.expectedVersion !== 0) {
      stop('BAD_COMMAND_TYPE', 'نوع عملية غير صالح.');
    }
    const db = admin.firestore();
    const root = db.collection('organizations').doc(data.organizationId);
    const receiptRef = root.collection('commandReceipts').doc(data.operationId);
    const fingerprint = requestHash(data);
    await db.runTransaction(async tx => {
      const profileSnap = await tx.get(db.collection('users').doc(uid));
      const orgSnap = await tx.get(root);
      const profile = profileSnap.exists ? profileSnap.data() : {};
      const org = orgSnap.exists ? orgSnap.data() : {};
      if (profile.organizationId !== data.organizationId) stop('WRONG_ORG', 'مؤسسة الحساب غير متطابقة.');
      if (profile.status !== 'active') stop('MEMBERSHIP_PENDING', 'العضوية غير نشطة.');
      if (!orgSnap.exists || !['active','trial'].includes(org.status) || trialExpired(org)) {
        stop('ORG_SUSPENDED', 'المؤسسة غير متاحة للاعتماد.');
      }
      const receipt = await tx.get(receiptRef);
      if (receipt.exists) {
        if (receipt.data().uid !== uid || receipt.data().requestHash !== fingerprint) {
          stop('DUPLICATE_OPERATION_ID_CONTENT', 'معرف العملية مستخدم لمحتوى مختلف.');
        }
        return;
      }
      const gate = org.commandProtocol || {};
      if (gate.enabled !== true || gate.schemaVersion !== SCHEMA_VERSION ||
          gate.domainManifestVersion !== 1 || !gate.migrationId ||
          gate.globalReferencesReady !== true || gate.uniqueAdmissionComplete !== true) {
        stop('PROTOCOL_NOT_READY', 'ترحيل الاعتماد المركزي لم يكتمل.');
      }
      check(validateMembership(profile, data.organizationId, org, COMMAND_DEFS[data.commandType], data.deviceId));
      check(validateWriteSet(data.payload, profileRoles(profile), data.organizationId));
      const deviceSnap = await tx.get(root.collection('devices').doc(data.deviceId));
      const device = deviceSnap.exists ? deviceSnap.data() : {};
      if (!deviceSnap.exists || device.uid !== uid || device.status !== 'active' ||
          gate.writerDeviceId !== data.deviceId) stop('DEVICE_UNTRUSTED', 'جهاز الكتابة غير معتمد.');
      if (device.readOnly !== false) stop('READ_ONLY_DEVICE', 'الجهاز للقراءة فقط.');
      const sequenceRef = root.collection('counters').doc('changeSequence');
      const counter = await tx.get(sequenceRef);
      const previous = counter.exists ? counter.data().value : null;
      if (!Number.isSafeInteger(previous) || previous < 0 || previous >= Number.MAX_SAFE_INTEGER) {
        stop('PROTOCOL_NOT_READY', 'عداد الأحداث يحتاج تهيئة موثوقة.');
      }
      const sequence = previous + 1;
      const writes = data.payload.writes;
      const prepared = [];
      const refs = writes.map(write => root.collection(definition(write.entityType).collection).doc(write.entityId));
      const snapshots = await tx.getAll(...refs);
      for (let index = 0; index < writes.length; index++) {
        const write = writes[index], ref = refs[index], snap = snapshots[index];
        const current = snap.exists ? snap.data() : null;
        if (current && current.organizationId !== data.organizationId) stop('WRONG_ORG', 'مؤسسة السجل غير متطابقة.');
        check(validateAgainstCurrent(write, current, profileRoles(profile), writes));
        if (current && (!current.createdAt || typeof current.createdBy !== 'string')) {
          stop('PROTOCOL_NOT_READY', 'بيانات منشئ السجل تحتاج مراجعة الترحيل.');
        }
        // Relationship, numbering and uniqueness admission is required before
        // this handler can be enabled by a migration. A manifest entry alone
        // is never treated as proof that a deployment is ready.
        prepared.push({write, ref, current, version: current ? current.version + 1 : 1});
      }
      const inAction = new Map(prepared.map(item => [keyOf(item.write), item]));
      const parentRefs = new Map();
      for (const write of writes) for (const ref of Object.values(write.relations || {})) {
        if (!inAction.has(keyOf(ref))) parentRefs.set(keyOf(ref), ref);
      }
      const externalParents = [...parentRefs.values()];
      const parents = new Map();
      if (externalParents.length) {
        const documents = await tx.getAll(...externalParents.map(ref =>
          root.collection(definition(ref.entityType).collection).doc(ref.entityId)));
        for (let i = 0; i < documents.length; i++) {
          parents.set(keyOf(externalParents[i]), documents[i].exists ? documents[i].data() : null);
        }
      }
      check(validateRelations(prepared, parents, data.organizationId));
      check(validateInventoryEffects(prepared));
      const claimed = new Map(), released = new Map();
      for (const item of prepared) {
        const {write, current} = item;
        const after = {...(current || {}), ...write.payload,
          deletedAt: write.operation === 'tombstone' ? true : null};
        const next = uniqueClaims(write.entityType, write.entityId, after, write.relations);
        for (const claim of next) {
          const duplicate = claimed.get(claim.key);
          if (duplicate && keyOf(duplicate) !== keyOf(claim)) stop('BAD_PAYLOAD', 'قيمة فريدة مكررة داخل العملية.');
          claimed.set(claim.key, claim);
        }
        if (current) for (const previousClaim of uniqueClaims(write.entityType, write.entityId, current, current.parentRefs)) {
          if (!next.some(claim => claim.key === previousClaim.key)) released.set(previousClaim.key, previousClaim);
        }
      }
      const claims = [...claimed.values()];
      if (claims.length) {
        const held = await tx.getAll(...claims.map(claim => root.collection('uniqueReservations').doc(claim.key)));
        for (let i = 0; i < held.length; i++) {
          if (held[i].exists && keyOf(held[i].data()) !== keyOf(claims[i])) {
            stop('VERSION_CONFLICT', 'القيمة الفريدة محجوزة لسجل آخر.');
          }
        }
      }
      // Every read and every rejection is above the first write.
      const stamp = admin.firestore.FieldValue.serverTimestamp();
      const changes = [];
      const effects = [];
      for (const {write, ref, current, version} of prepared) {
        const fields = {...write.payload};
        for (const key of ['createdAt','createdBy','updatedAt','updatedBy','deviceId','version','deletedAt','organizationId']) delete fields[key];
        const next = {...fields, organizationId: data.organizationId, version,
          updatedAt: stamp, updatedBy: uid, deviceId: data.deviceId,
          deletedAt: write.operation === 'tombstone' ? stamp : null,
          protocol: {operationId: data.operationId, schemaVersion: SCHEMA_VERSION, migrationId: gate.migrationId}};
        const afterImage = {...(current || {}), ...next,
          // Commit-managed times in the after-image use the serializable
          // placeholder, never a FieldValue sentinel (sentinels are rejected
          // inside arrays). The live documents above carry the real
          // serverTimestamp for the SAME transaction, and the event's
          // top-level `committedAt` is the identical timestamp, so client
          // resolution of the placeholder reproduces the live values exactly.
          createdAt: current ? current.createdAt : centralCommitTimePlaceholder,
          createdBy: current ? current.createdBy : uid,
          updatedAt: centralCommitTimePlaceholder,
          deletedAt: write.operation === 'tombstone' ? centralCommitTimePlaceholder : null,
          parentRefs: Object.fromEntries(Object.entries(write.relations || {}).map(([name, ref]) => [name, {
            entityType: ref.entityType, entityId: ref.entityId,
            version: inAction.get(keyOf(ref))?.version || ref.expectedVersion,
          }])),
        };
        effects.push({ref, current, next: {...next, parentRefs: afterImage.parentRefs}});
        changes.push({entityType: write.entityType, entityId: write.entityId,
          operation: write.operation, committedVersion: version, data: afterImage});
      }
      // A single immutable after-image event keeps linked records consistent
      // during replay. It has one timestamp transform, rather than transforms
      // inside arrays or hundreds of repeated transforms on one document.
      if (Buffer.byteLength(JSON.stringify(changes), 'utf8') > 900000) {
        stop('BAD_PAYLOAD', 'حجم آثار العملية يتجاوز حد الاعتماد الذري.');
      }
      for (const effect of effects) {
        if (!effect.current) tx.create(effect.ref, {...effect.next, createdAt: stamp, createdBy: uid});
        else tx.update(effect.ref, effect.next);
      }
      for (const [key] of released) if (!claimed.has(key)) tx.delete(root.collection('uniqueReservations').doc(key));
      for (const claim of claims) tx.set(root.collection('uniqueReservations').doc(claim.key), {
        entityType: claim.entityType, entityId: claim.entityId,
      });
      tx.set(sequenceRef, {value: sequence});
      tx.create(root.collection('changeEvents').doc(`event_${sequence}`), {
        seq: sequence, entityType: 'domainTransaction', entityId: data.entityId,
        operationId: data.operationId, changes, actorUid: uid,
        deviceId: data.deviceId, committedAt: stamp,
      });
      tx.create(root.collection('auditLogs').doc(`cmd_${data.operationId}`), {
        userId: uid, userName: profile.displayName || '', organizationId: data.organizationId,
        action: 'DOMAIN_COMMITTED', entityType: 'domainTransaction', entityId: data.entityId,
        detailsJson: JSON.stringify({operationId: data.operationId,
          changes: changes.map(({data: _data, ...summary}) => summary)}),
        deviceId: data.deviceId, occurredAt: stamp, version: 1,
      });
      // Central notification fan-out (blocking 4): which generic alerts this
      // operation deserves, computed from the validated write set - never
      // from free text. Creations of the three product-facing families plus
      // quality decisions on existing inspections. Logical deletes and every
      // other edit stay silent; the consumer of notifyRequests maps each
      // target to its push kind and dedupes per event + recipient.
      const notifyTargets = [];
      const seenKinds = new Set();
      for (const {write} of prepared) {
        if (write.operation === 'tombstone') continue;
        const kind = write.entityType === 'sample'
          ? (write.operation === 'create' ? 'inspection'
            : (write.payload.decisionStatus != null && write.payload.decisionStatus !== 'PENDING'
              ? 'decision' : null))
          : write.entityType === 'labResult' ? 'lab'
          : write.entityType === 'productBatchSample' ? 'productSample'
          : null;
        if (!kind) continue;
        const targetKey = `${kind}/${write.entityId}`;
        if (seenKinds.has(targetKey)) continue;
        seenKinds.add(targetKey);
        notifyTargets.push({kind, entityType: write.entityType, entityId: write.entityId});
      }
      tx.create(root.collection('notifyRequests').doc(`notify_${data.operationId}`), {
        organizationId: data.organizationId, eventId: `event_${sequence}`,
        entityType: 'domainTransaction', entityId: data.entityId,
        changes: changes.map(({data: _data, ...summary}) => summary),
        notifyTargets,
        createdBy: uid, sourceDeviceId: data.deviceId, createdAt: stamp, delivered: false,
      });
      tx.create(receiptRef, {uid, deviceId: data.deviceId, commandType: data.commandType,
        requestHash: fingerprint, payloadHash: data.payloadHash, createdAt: stamp,
        outcome: {operationId: data.operationId, status: 'approved', entityId: data.entityId,
          committedVersion: 1, changeSequence: sequence, committedAt: stamp},
      });
    });
    const stored = (await receiptRef.get()).data().outcome;
    return {...stored, committedAt: stored.committedAt.toDate().toISOString()};
  };
}

module.exports = {buildDomainSubmitHandler, centralCommitTimePlaceholder};
