const {HttpsError, onCall} = require('firebase-functions/v2/https');
const {roleCan, profileRoles, validRoleSet} = require('./commands');
const manifest = require('./domain_manifest.json');

const PAGE_SIZE = 20;
const EVENT_PAGE = 1;

function fail(code, messageAr, status = 'permission-denied') {
  throw new HttpsError(status, messageAr, {code, messageAr});
}

function serializable(value) {
  if (value && typeof value.toDate === 'function') return value.toDate().toISOString();
  if (Array.isArray(value)) return value.map(serializable);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, serializable(v)]));
  }
  return value;
}

function safeSequence(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function trialExpired(org) {
  if (org.status !== 'trial' || org.manuallyActivated === true || !org.trialEndsAt) return false;
  const end = org.trialEndsAt.toMillis ? org.trialEndsAt.toMillis() : Date.parse(org.trialEndsAt);
  return !Number.isFinite(end) || end <= Date.now();
}

function buildCentralSyncHandler(admin) {
  return async request => {
    const uid = request.auth && request.auth.uid;
    if (!uid) fail('UNAUTHENTICATED', 'سجّل الدخول أولًا.');
    const data = request.data || {};
    const orgId = data.organizationId;
    const deviceId = data.deviceId;
    if (typeof orgId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(orgId) ||
        typeof deviceId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(deviceId)) {
      fail('BAD_PAYLOAD', 'هوية المؤسسة أو الجهاز غير صالحة.', 'invalid-argument');
    }
    const db = admin.firestore();
    const root = db.collection('organizations').doc(orgId);
    const [profileSnap, orgSnap, deviceSnap] = await Promise.all([
      db.collection('users').doc(uid).get(), root.get(), root.collection('devices').doc(deviceId).get(),
    ]);
    const profile = profileSnap.exists ? profileSnap.data() : {};
    const org = orgSnap.exists ? orgSnap.data() : {};
    const device = deviceSnap.exists ? deviceSnap.data() : {};
    if (profile.organizationId !== orgId) fail('WRONG_ORG', 'مؤسسة الحساب غير متطابقة.', 'failed-precondition');
    if (profile.status !== 'active') fail('MEMBERSHIP_PENDING', 'العضوية غير نشطة.');
    if (!orgSnap.exists || !['active', 'trial'].includes(org.status) || trialExpired(org)) {
      fail('ORG_SUSPENDED', 'المؤسسة غير متاحة.', 'failed-precondition');
    }
    if (!deviceSnap.exists || device.uid !== uid || (device.status || 'active') !== 'active') {
      fail('DEVICE_UNTRUSTED', 'الجهاز غير مسجل أو مسحوب الصلاحية.');
    }
    const gate = org.commandProtocol || {};
    if (gate.enabled !== true || gate.schemaVersion !== 2 || gate.domainManifestVersion !== 1) {
      fail('PROTOCOL_NOT_READY', 'التحميل المركزي غير مفعّل لهذه المؤسسة.', 'failed-precondition');
    }
    const roles = profileRoles(profile);
    if (!validRoleSet(roles, profile.role)) fail('PERMISSION_DENIED', 'دور الحساب غير معروف.');
    const mode = data.mode;
    const allowedKeys = mode === 'snapshotPage'
      ? ['mode', 'organizationId', 'deviceId', 'entityType', 'throughSequence', 'after']
      : mode === 'events'
        ? ['mode', 'organizationId', 'deviceId', 'afterSequence']
        : ['mode', 'organizationId', 'deviceId'];
    if (Object.keys(data).some(key => !allowedKeys.includes(key))) {
      fail('BAD_PAYLOAD', 'حقول طلب المزامنة غير مسموحة.', 'invalid-argument');
    }
    const allowedEntity = entityType => {
      const definition = manifest.entities[entityType];
      if (!definition || entityType === 'auditLog') return null;
      if (!roleCan(roles, definition.readPermission)) return null;
      return definition;
    };
    const sequenceNow = async () => {
      const snap = await root.collection('counters').doc('changeSequence').get();
      const seq = snap.exists ? snap.data().value : 0;
      if (!safeSequence(seq)) fail('PROTOCOL_NOT_READY', 'عداد الأحداث غير صالح.', 'failed-precondition');
      return seq;
    };

    if (mode === 'beginSnapshot') {
      return {throughSequence: await sequenceNow(), manifestVersion: manifest.manifestVersion};
    }
    if (mode === 'snapshotPage') {
      const definition = allowedEntity(data.entityType);
      if (!definition) fail('PERMISSION_DENIED', 'لا تملك صلاحية قراءة هذا النوع.');
      const throughSequence = data.throughSequence;
      if (!safeSequence(throughSequence) || throughSequence > await sequenceNow()) {
        fail('BAD_PAYLOAD', 'نقطة اللقطة غير صالحة.', 'invalid-argument');
      }
      const after = data.after;
      if (after != null && (typeof after !== 'string' || after.length > 256 || after.includes('/'))) {
        fail('BAD_PAYLOAD', 'مؤشر الصفحة غير صالح.', 'invalid-argument');
      }
      let query = root.collection(definition.collection);
      if (definition.collection === 'labConfig') {
        query = query.where('configType', '==', definition.table);
      }
      query = query.orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE_SIZE);
      if (after) query = query.startAfter(after);
      const page = await query.get();
      const records = [];
      for (const doc of page.docs) {
        const value = doc.data();
        if (value.organizationId !== orgId || !Number.isSafeInteger(value.version) || value.version < 1) {
          fail('PROTOCOL_NOT_READY', 'يوجد سجل يحتاج تصحيحًا قبل تهيئة الأرشيف.', 'failed-precondition');
        }
        records.push({entityType: data.entityType, entityId: doc.id,
          version: value.version, data: serializable(value)});
      }
      return {throughSequence, records, nextAfter: page.size === PAGE_SIZE ? page.docs[page.size - 1].id : null};
    }
    if (mode === 'events') {
      const afterSequence = data.afterSequence;
      if (!safeSequence(afterSequence)) fail('BAD_PAYLOAD', 'نقطة الاستئناف غير صالحة.', 'invalid-argument');
      const throughSequence = await sequenceNow();
      if (afterSequence > throughSequence) fail('BAD_PAYLOAD', 'نقطة الاستئناف أحدث من الخادم.', 'invalid-argument');
      const end = Math.min(throughSequence, afterSequence + EVENT_PAGE);
      const refs = [];
      for (let seq = afterSequence + 1; seq <= end; seq++) {
        refs.push(root.collection('changeEvents').doc(`event_${seq}`));
      }
      const snapshots = refs.length ? await db.getAll(...refs) : [];
      const events = [];
      for (let index = 0; index < snapshots.length; index++) {
        const snap = snapshots[index];
        const seq = afterSequence + index + 1;
        if (!snap.exists || snap.data().seq !== seq) {
          fail('EVENT_GAP', 'تسلسل أحداث الخادم غير مكتمل؛ أعد تهيئة الأرشيف.', 'failed-precondition');
        }
        const event = snap.data();
        let changes = Array.isArray(event.changes) ? event.changes : [];
        // Older sample commands store an event delta only. Materialize the
        // current after-image ONLY while the live document is still exactly
        // the version this event committed: substituting a newer document
        // for a historical event image would present later content under the
        // earlier version number, and the event and snapshot channels would
        // disagree for the same version. When the record has moved on, emit
        // no change - clients already treat later versions as superseding.
        if (!changes.length && event.entityType === 'sample' && typeof event.entityId === 'string') {
          const sample = await root.collection('samples').doc(event.entityId).get();
          if (sample.exists && sample.data().organizationId === orgId &&
              sample.data().version === event.committedVersion) {
            changes = [{entityType: 'sample', entityId: sample.id,
              committedVersion: sample.data().version, data: serializable(sample.data())}];
          }
        }
        const visible = [];
        for (const change of changes) {
          const definition = allowedEntity(change.entityType);
          if (!definition) continue;
          if (typeof change.entityId !== 'string' || !Number.isSafeInteger(change.committedVersion) ||
              change.committedVersion < 1 || !change.data || change.data.organizationId !== orgId ||
              change.data.version !== change.committedVersion) {
            fail('PROTOCOL_NOT_READY', 'حدث مركزي غير صالح.', 'failed-precondition');
          }
          visible.push({entityType: change.entityType, entityId: change.entityId,
            version: change.committedVersion, data: serializable(change.data)});
        }
        events.push({sequence: seq, operationId: event.operationId || `event_${seq}`,
          // The approval time of the event. Clients resolve legacy
          // placeholder timestamps in after-images against it, so an
          // event-delivered version matches its snapshot twin byte for byte.
          committedAt: event.committedAt != null ? serializable(event.committedAt) : null,
          records: visible});
      }
      return {throughSequence, events, hasMore: end < throughSequence};
    }
    fail('BAD_PAYLOAD', 'نوع طلب المزامنة غير معروف.', 'invalid-argument');
  };
}

function createCentralSync(admin) {
  return onCall({enforceAppCheck: false, cors: true}, buildCentralSyncHandler(admin));
}

module.exports = {buildCentralSyncHandler, createCentralSync, PAGE_SIZE, EVENT_PAGE};
