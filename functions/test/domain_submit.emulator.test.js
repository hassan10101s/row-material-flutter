const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const admin = require('firebase-admin');
const vectors = require('./fixtures/domain_wire_vectors.json');
const {buildDomainSubmitHandler, centralCommitTimePlaceholder} = require('../domain_submit');
const {definition} = require('../domain_commands');
const {hashPayload, SCHEMA_VERSION} = require('../commands');
const enabled = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const org = `domain-command-${process.pid}`;
const uid = 'uid_admin';
let app, db, submit, number = 0;
const ref = path => db.doc(`organizations/${org}/${path}`);
const coll = path => db.collection(`organizations/${org}/${path}`);

function frame(name = 'inspection') {
  const payload = structuredClone(vectors[name].payload);
  const count = ++number;
  const ids = new Map(payload.writes.filter(write => write.operation === 'create')
    .map(write => [`${write.entityType}/${write.entityId}`, crypto.randomUUID()]));
  for (const write of payload.writes) {
    if (write.operation === 'create') {
      write.entityId = ids.get(`${write.entityType}/${write.entityId}`);
      write.payload.remoteId = write.entityId;
    }
    write.payload.organizationId = org;
    if (write.operation === 'create' && write.payload.entryCode) write.payload.entryCode += `-${count}`;
    if (write.operation === 'create' && write.entityType === 'inventoryItem') write.payload.name += `-${count}`;
    if (write.operation === 'create' && write.entityType === 'inventoryLot') write.payload.lotNo += `-${count}`;
    for (const relation of Object.values(write.relations || {})) {
      const replacement = ids.get(`${relation.entityType}/${relation.entityId}`);
      if (replacement) relation.entityId = replacement;
    }
  }
  const data = {operationId: crypto.randomUUID(), organizationId: org,
    schemaVersion: SCHEMA_VERSION, commandType: 'domain.commit', entityId: crypto.randomUUID(),
    expectedVersion: 0, payload, deviceId: 'writer', dependencies: {}};
  return {...data, payloadHash: hashPayload(payload)};
}
const request = data => ({auth: {uid}, data});
before(async () => {
  if (!enabled) return;
  app = admin.initializeApp({projectId: 'demo-materiallab'});
  db = app.firestore();
  submit = buildDomainSubmitHandler(admin);
  await db.doc(`users/${uid}`).set({organizationId: org, status: 'active', role: 'admin', displayName: 'Test Admin'});
  await db.doc(`organizations/${org}`).set({status: 'active', commandProtocol: {
    enabled: true, schemaVersion: SCHEMA_VERSION, domainManifestVersion: 1,
    migrationId: 'test-migration', globalReferencesReady: true, uniqueAdmissionComplete: true,
    writerDeviceId: 'writer',
  }});
  await ref('devices/writer').set({uid, status: 'active', readOnly: false});
  await ref('counters/changeSequence').set({value: 0});
  await ref('referenceMaterials/server-material-1').set({version: 1, organizationId: org,
    materialName: 'Test material', createdBy: uid, createdAt: admin.firestore.Timestamp.now()});
});
after(async () => {
  if (!enabled) return;
  await db.recursiveDelete(db.doc(`organizations/${org}`));
  await db.doc(`users/${uid}`).delete();
  await app.delete();
});

test('the real inventory repository write set commits once as one aggregate and one event', {skip: !enabled}, async () => {
  const data = frame('inventory');
  const receipt = await submit(request(data));
  const repeated = await Promise.all(Array.from({length: 20}, () => submit(request(data))));
  for (const value of repeated) assert.deepEqual(value, receipt);
  for (const write of data.payload.writes) {
    const doc = await ref(`${definition(write.entityType).collection}/${write.entityId}`).get();
    assert.equal(doc.exists, true);
    assert.equal(doc.data().version, 1);
    for (const [field, parent] of Object.entries(write.relations || {})) {
      assert.equal(doc.data().parentRefs[field].entityId, parent.entityId);
    }
  }
  const event = (await ref(`changeEvents/event_${receipt.changeSequence}`).get()).data();
  assert.equal(event.changes.length, data.payload.writes.length);
  // The after-image carries the serializable commit-time placeholder (a
  // FieldValue sentinel would be rejected before the transaction), and the
  // event's top-level `committedAt` is the SAME timestamp the live documents
  // received. Resolving the placeholder against `committedAt` - exactly what
  // the client's normalizeApprovedPayload does - reproduces the live values
  // byte for byte, so the event and snapshot channels hash identically.
  const committedIso = event.committedAt.toDate().toISOString();
  for (const change of event.changes) {
    assert.equal(change.data.updatedAt, centralCommitTimePlaceholder);
    assert.equal(change.data.deletedAt, null);
    if (change.operation === 'create') {
      assert.equal(change.data.createdAt, centralCommitTimePlaceholder);
    }
    const live = await ref(`${definition(change.entityType).collection}/${change.entityId}`).get();
    assert.equal(live.data().updatedAt.toDate().toISOString(), committedIso);
    // Simulate the client resolution: the resolved after-image time fields
    // must equal the live document's.
    const resolved = {...change.data};
    if (resolved.updatedAt === centralCommitTimePlaceholder) resolved.updatedAt = committedIso;
    if (resolved.createdAt === centralCommitTimePlaceholder) resolved.createdAt = committedIso;
    assert.equal(resolved.updatedAt, live.data().updatedAt.toDate().toISOString());
    if (change.operation === 'create') {
      assert.equal(resolved.createdAt, live.data().createdAt.toDate().toISOString());
    }
  }
  assert.equal((await ref(`commandReceipts/${data.operationId}`).get()).exists, true);
  // Replay acceptance: the same request 20 more times must not add another
  // event or audit trace - one operation, one effect.
  const eventCount = (await coll('changeEvents').listDocuments()).length;
  assert.equal(eventCount, receipt.changeSequence);
  assert.equal((await coll('auditLogs').listDocuments()).length, 1);
  assert.equal((await coll('notifyRequests').listDocuments()).length, 1);
});

test('a logical delete stores the placeholder tombstone time and resolves to the live value', {skip: !enabled}, async () => {
  const data = frame();
  const first = await submit(request(data));
  const original = data.payload.writes[0];
  const tombstone = {...data, operationId: crypto.randomUUID(), entityId: crypto.randomUUID(), payload: {
    writes: [{entityType: original.entityType, entityId: original.entityId,
      operation: 'tombstone', expectedVersion: 1, payload: {},
      relations: original.relations}],
  }};
  tombstone.payloadHash = hashPayload(tombstone.payload);
  const receipt = await submit(request(tombstone));
  const event = (await ref(`changeEvents/event_${receipt.changeSequence}`).get()).data();
  assert.equal(event.changes[0].operation, 'tombstone');
  assert.equal(event.changes[0].data.deletedAt, centralCommitTimePlaceholder);
  assert.equal(event.changes[0].data.updatedAt, centralCommitTimePlaceholder);
  const live = await ref(`${definition(original.entityType).collection}/${original.entityId}`).get();
  const committedIso = event.committedAt.toDate().toISOString();
  assert.equal(live.data().deletedAt.toDate().toISOString(), committedIso);
  assert.equal(live.data().updatedAt.toDate().toISOString(), committedIso);
  assert.equal(first.changeSequence + 1, receipt.changeSequence);
});

test('one stale effect rejects the whole multi-record action without a partial first write', {skip: !enabled}, async () => {
  const data = frame();
  const extra = structuredClone(data.payload.writes[0]);
  extra.entityId = crypto.randomUUID(); extra.payload.remoteId = extra.entityId;
  extra.payload.entryCode += '-stale';
  extra.operation = 'update'; extra.expectedVersion = 1;
  data.payload.writes.push(extra); data.payloadHash = hashPayload(data.payload);
  await assert.rejects(submit(request(data)), error => error.details.code === 'NOT_FOUND');
  assert.equal((await ref(`samples/${data.payload.writes[0].entityId}`).get()).exists, false);
  assert.equal((await ref(`commandReceipts/${data.operationId}`).get()).exists, false);
});

test('after-images retain the committed operation even after the live record changes', {skip: !enabled}, async () => {
  const data = frame();
  const first = await submit(request(data));
  const original = data.payload.writes[0];
  const update = {...data, operationId: crypto.randomUUID(), entityId: crypto.randomUUID(), payload: {
    writes: [{...original, operation: 'update', expectedVersion: 1,
      payload: {...original.payload, supplier: 'Changed later'}}],
  }};
  update.payloadHash = hashPayload(update.payload);
  await submit(request(update));
  const event = (await ref(`changeEvents/event_${first.changeSequence}`).get()).data();
  assert.equal(event.changes[0].data.supplier, original.payload.supplier);
  assert.equal((await ref(`samples/${original.entityId}`).get()).data().supplier, 'Changed later');
});

test('a stale global parent blocks the operation before any record or receipt exists', {skip: !enabled}, async () => {
  const data = frame();
  data.payload.writes[0].relations.materialId.expectedVersion = 999;
  data.payloadHash = hashPayload(data.payload);
  await assert.rejects(submit(request(data)), error => error.details.code === 'VERSION_CONFLICT');
  assert.equal((await ref(`commandReceipts/${data.operationId}`).get()).exists, false);
});

test('a cached client role cannot bypass the current server role for a new command', {skip: !enabled}, async () => {
  const data = frame();
  await db.doc(`users/${uid}`).update({role: 'viewer'});
  try {
    await assert.rejects(submit(request(data)), error => error.details.code === 'PERMISSION_DENIED');
    assert.equal((await ref(`commandReceipts/${data.operationId}`).get()).exists, false);
  } finally { await db.doc(`users/${uid}`).update({role: 'admin'}); }
});
