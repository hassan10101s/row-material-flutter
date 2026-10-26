/** Server-authoritative pilot. Disabled until an explicit server-side cutover. */
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {SCHEMA_VERSION, COMMAND_DEFS, validatePayload, validateSessionFrame,
  validateMembership, requestHash, httpsCodeFor} = require('./commands');
const {buildDomainSubmitHandler} = require('./domain_submit');

function throwStable(code, messageAr, extra) {
  throw new HttpsError(httpsCodeFor(code), messageAr, {code, messageAr, ...(extra || {})});
}
function countOf(snapshot) {
  const value = snapshot.exists ? snapshot.data().value : null;
  if (!Number.isSafeInteger(value) || value < 0 || value >= Number.MAX_SAFE_INTEGER) {
    throwStable('PROTOCOL_NOT_READY', 'عدادات البروتوكول تحتاج تهيئة موثوقة.');
  }
  return value;
}
function trialExpired(org) {
  if (org.status !== 'trial' || org.manuallyActivated === true || !org.trialEndsAt) return false;
  const end = org.trialEndsAt.toMillis ? org.trialEndsAt.toMillis() : Date.parse(org.trialEndsAt);
  return Number.isFinite(end) && end <= Date.now();
}
function buildSubmitCommandHandler(admin) {
  return async request => {
    const callerUid = request.auth && request.auth.uid;
    if (!callerUid) throwStable('UNAUTHENTICATED', 'سجّل الدخول أولًا.');
    const data = request.data;
    const frameError = validateSessionFrame(data);
    if (frameError) throwStable(frameError.code, frameError.messageAr);
    const payloadError = validatePayload('sample', data.commandType.split('.')[1], data.payload);
    if (payloadError) throwStable(payloadError.code, payloadError.messageAr);
    if (data.payload.organizationId !== undefined && data.payload.organizationId !== data.organizationId) {
      throwStable('WRONG_ORG', 'هوية مؤسسة غير متطابقة.');
    }
    const db = admin.firestore();
    const orgRef = db.collection('organizations').doc(data.organizationId);
    const samples = orgRef.collection('samples');
    const receiptRef = orgRef.collection('commandReceipts').doc(data.operationId);
    const fingerprint = requestHash(data);
    await db.runTransaction(async tx => {
      // Authorization is read under the SAME transaction as the effect.
      const profileSnap = await tx.get(db.collection('users').doc(callerUid));
      const orgSnap = await tx.get(orgRef);
      const profile = profileSnap.exists ? profileSnap.data() : {};
      const org = orgSnap.exists ? orgSnap.data() : {};
      if (profile.organizationId !== data.organizationId) throwStable('WRONG_ORG', 'مؤسسة الطلب لا تطابق الحساب.');
      if (profile.status !== 'active') throwStable('MEMBERSHIP_PENDING', 'العضوية غير نشطة.');
      if (!orgSnap.exists || !['active', 'trial'].includes(org.status) || trialExpired(org)) {
        throwStable('ORG_SUSPENDED', 'المؤسسة غير متاحة للاعتماد.');
      }
      const saved = await tx.get(receiptRef);
      if (saved.exists) {
        const receipt = saved.data();
        if (receipt.uid !== callerUid || receipt.requestHash !== fingerprint) {
          throwStable('DUPLICATE_OPERATION_ID_CONTENT', 'معرف العملية مستخدم لأمر مختلف.');
        }
        // An active member may acknowledge a prior commit even after losing
        // write permission. This reads an immutable receipt; it never writes.
        return;
      }
      const gate = org.commandProtocol;
      if (!gate || gate.enabled !== true || gate.schemaVersion !== SCHEMA_VERSION) {
        throwStable('PROTOCOL_NOT_READY', 'الاعتماد المركزي لم يُفعّل بعد لهذه المؤسسة.');
      }
      const membershipError = validateMembership(profile, data.organizationId, org,
        COMMAND_DEFS[data.commandType], data.deviceId);
      if (membershipError) throwStable(membershipError.code, membershipError.messageAr);
      const deviceSnap = await tx.get(orgRef.collection('devices').doc(data.deviceId));
      const device = deviceSnap.exists ? deviceSnap.data() : {};
      if (!deviceSnap.exists || device.uid !== callerUid || (device.status || 'active') !== 'active') {
        throwStable('DEVICE_UNTRUSTED', 'جهاز غير مسجل أو مسحوب الصلاحية.');
      }
      if (device.readOnly !== false) throwStable('READ_ONLY_DEVICE', 'الجهاز للقراءة فقط.');
      if (gate.writerDeviceId !== data.deviceId) throwStable('DEVICE_UNTRUSTED', 'الجهاز ليس جهاز الكتابة المعتمد.');
      const operation = data.commandType.split('.')[1];
      const docRef = samples.doc(data.entityId);
      const current = await tx.get(docRef);
      const doc = current.exists ? current.data() : null;
      const sequenceRef = orgRef.collection('counters').doc('changeSequence');
      const sequenceSnap = await tx.get(sequenceRef);
      const changeSequence = countOf(sequenceSnap) + 1;
      let numberRef, sampleNo, version;
      if (operation === 'create') {
        const parentId = (data.dependencies || {}).parent_sample;
        if (parentId) {
          const parent = await tx.get(samples.doc(parentId));
          if (!parent.exists || parent.data().deletedAt) throwStable('PARENT_MISSING_OR_DELETED', 'الأب غير متاح.');
          if (parent.data().organizationId !== data.organizationId) throwStable('WRONG_ORG', 'مؤسسة الأب غير متطابقة.');
          if (parent.data().inspectionKind !== 'product') throwStable('PARENT_WRONG_TYPE', 'الأب ليس فحص منتج.');
          // A product's operational sample belongs in productBatchSamples,
          // not a raw inspection header. That command is not in this pilot.
          throwStable('BAD_COMMAND_TYPE', 'إنشاء العينات التشغيلية غير متاح في نطاق الأوامر التجريبي.');
        }
        if (doc) throwStable('VERSION_CONFLICT', 'المعرف العالمي موجود بالفعل.', {currentVersion: doc.version});
        numberRef = orgRef.collection('counters').doc('sampleNumber');
        sampleNo = countOf(await tx.get(numberRef)) + 1;
        const occupied = await tx.get(samples.where('entryCode', '==', officialEntryCode(sampleNo)).limit(1));
        if (!occupied.empty) throwStable('PROTOCOL_NOT_READY', 'عداد الأرقام يتعارض مع بيانات موجودة.');
        version = 1;
      } else {
        if (!doc) throwStable('NOT_FOUND', 'السجل غير موجود.');
        if (doc.organizationId !== data.organizationId) throwStable('WRONG_ORG', 'مؤسسة السجل غير متطابقة.');
        if (doc.deletedAt) throwStable('DELETED_CANNOT_MODIFY', 'السجل محذوف.');
        if (!Number.isSafeInteger(doc.version) || doc.version < 1 || doc.version >= Number.MAX_SAFE_INTEGER) {
          throwStable('PROTOCOL_NOT_READY', 'إصدار السجل غير صالح.');
        }
        if (data.expectedVersion !== doc.version) throwStable('VERSION_CONFLICT', 'تغير إصدار السجل.', {currentVersion: doc.version, currentEntityId: data.entityId});
        version = doc.version + 1;
      }
      const quantity = data.payload.quantity === undefined ? doc && doc.quantity : data.payload.quantity;
      const rejected = data.payload.rejectedQuantity === undefined ? doc && doc.rejectedQuantity : data.payload.rejectedQuantity;
      if (quantity != null && rejected != null && rejected > quantity) throwStable('VALUE_OUT_OF_RANGE', 'الكمية المرفوضة تتجاوز الكمية.');
      // ALL reads above. Firestore prohibits reads after the first write.
      const stamp = admin.firestore.FieldValue.serverTimestamp();
      const fields = {...data.payload};
      delete fields.organizationId;
      if (operation === 'create') {
        tx.set(numberRef, {value: sampleNo});
        tx.create(docRef, {...fields, organizationId: data.organizationId,
          sampleNo, entryCode: officialEntryCode(sampleNo), inspectionKind: 'raw',
          decisionStatus: 'PENDING', decisionVersion: 1, version,
          createdBy: callerUid, createdAt: stamp, updatedAt: stamp, updatedBy: callerUid,
          deviceId: data.deviceId, remoteId: data.entityId, deletedAt: null,
          protocol: {operationId: data.operationId, schemaVersion: SCHEMA_VERSION}});
      } else {
        tx.update(docRef, {...(operation === 'delete' ? {deletedAt: stamp} : fields),
          version, updatedAt: stamp, updatedBy: callerUid, deviceId: data.deviceId});
      }
      tx.set(sequenceRef, {value: changeSequence});
      const eventRef = orgRef.collection('changeEvents').doc(`event_${changeSequence}`);
      tx.create(eventRef, {seq: changeSequence, entityType: 'sample', entityId: data.entityId,
        operation: data.commandType, committedVersion: version, actorUid: callerUid,
        deviceId: data.deviceId, committedAt: stamp, changedBy: callerUid});
      tx.create(orgRef.collection('auditLogs').doc(`cmd_${data.operationId}`), {
        userId: callerUid, userName: '', organizationId: data.organizationId,
        action: {'create': 'SAMPLE_CREATED', 'update': 'SAMPLE_UPDATED', 'delete': 'SAMPLE_DELETED'}[operation],
        entityType: 'sample', entityId: data.entityId,
        detailsJson: JSON.stringify({operationId: data.operationId, expectedVersion: data.expectedVersion}),
        deviceId: data.deviceId, occurredAt: stamp, version: 1});
      tx.create(orgRef.collection('notifyRequests').doc(`notify_${data.operationId}`), {
        organizationId: data.organizationId, eventId: eventRef.id, entityType: 'sample',
        entityId: data.entityId, operation: data.commandType, createdBy: callerUid,
        notifyTargets: operation === 'create'
          ? [{kind: 'inspection', entityType: 'sample', entityId: data.entityId}]
          : [],
        sourceDeviceId: data.deviceId, createdAt: stamp, delivered: false});
      const outcome = {operationId: data.operationId, status: 'approved', entityId: data.entityId,
        committedVersion: version, committedAt: stamp, changeSequence};
      tx.create(receiptRef, {uid: callerUid, deviceId: data.deviceId, commandType: data.commandType,
        requestHash: fingerprint, payloadHash: data.payloadHash, outcome, createdAt: stamp});
    });
    const stored = (await receiptRef.get()).data().outcome;
    return {...stored, committedAt: stored.committedAt.toDate().toISOString()};
  };
}
function officialEntryCode(sampleNo) { return `SN-${String(sampleNo).padStart(6, '0')}`; }
function createSubmitCommand(admin) {
  // Both protocols share one callable so clients cannot accidentally bypass
  // the central write path by changing a function name. The domain handler
  // performs its own complete write-set validation and transaction gates.
  return onCall({enforceAppCheck: false, cors: true}, request => {
    if (request.data && request.data.commandType === 'domain.commit') {
      return buildDomainSubmitHandler(admin)(request);
    }
    return buildSubmitCommandHandler(admin)(request);
  });
}
module.exports = {createSubmitCommand, buildSubmitCommandHandler, officialEntryCode};
