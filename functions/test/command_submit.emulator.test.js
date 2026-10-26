'use strict';
const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');
const {buildSubmitCommandHandler} = require('../command_submit');
const {hashPayload, SCHEMA_VERSION} = require('../commands');
const enabled = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
let db, app, submit;
const org = `command-audit-${process.pid}`;
const uid = `writer-${process.pid}`;
function frame(patch = {}) {
  const data = {operationId: require('crypto').randomUUID(), organizationId: org,
    schemaVersion: SCHEMA_VERSION, commandType: 'sample.create', entityId: require('crypto').randomUUID(),
    expectedVersion: 0, payload: {sampleName: 'A', quantity: 3}, deviceId: 'writer-device', dependencies: {}, ...patch};
  return {...data, payloadHash: hashPayload(data.payload)};
}
const request = data => ({auth: {uid}, data});
before(async () => {
  if (!enabled) return;
  // Never connect a security/integration test to a real project.
  app = admin.initializeApp({projectId: 'demo-materiallab'});
  db = app.firestore();
  submit = buildSubmitCommandHandler(admin);
  await db.doc(`users/${uid}`).set({organizationId: org, status: 'active', role: 'lab'});
  await db.doc(`organizations/${org}`).set({status: 'active', commandProtocol: {enabled: true, schemaVersion: SCHEMA_VERSION, writerDeviceId: 'writer-device'}});
  await db.doc(`organizations/${org}/devices/writer-device`).set({uid, status: 'active', readOnly: false});
  for (const counter of ['sampleNumber', 'changeSequence']) await db.doc(`organizations/${org}/counters/${counter}`).set({value: 0});
});
after(async () => {
  if (!enabled) return;
  await db.recursiveDelete(db.doc(`organizations/${org}`));
  await db.doc(`users/${uid}`).delete();
  await app.delete();
});
test('real transaction commits document, receipt, counters, audit, event and notification atomically', {skip: !enabled}, async () => {
  const data = frame();
  const receipt = await submit(request(data));
  assert.equal(receipt.entityId, data.entityId);
  assert.equal(receipt.committedVersion, 1);
  const root = db.doc(`organizations/${org}`);
  const sample = await root.collection('samples').doc(data.entityId).get();
  assert.equal(sample.data().decisionStatus, 'PENDING');
  assert.equal(sample.data().createdAt.toDate().toISOString(), receipt.committedAt);
  for (const path of [`auditLogs/cmd_${data.operationId}`, `changeEvents/event_${receipt.changeSequence}`, `notifyRequests/notify_${data.operationId}`, `commandReceipts/${data.operationId}`]) {
    assert.equal((await root.collection(path.split('/')[0]).doc(path.split('/')[1]).get()).exists, true);
  }
  const repeated = await Promise.all(Array.from({length: 10}, () => submit(request(data))));
  for (const result of repeated) assert.deepEqual(result, receipt);
  assert.equal((await root.collection('counters').doc('changeSequence').get()).data().value, receipt.changeSequence);
});
test('same operation cannot acknowledge a different target, version or dependencies', {skip: !enabled}, async () => {
  const data = frame();
  await submit(request(data));
  for (const patch of [{entityId: 'different-id'}, {dependencies: {parent_sample: 'different-parent'}}]) {
    await assert.rejects(submit(request({...data, ...patch})), error => error.details.code === 'DUPLICATE_OPERATION_ID_CONTENT');
  }
});
test('concurrent edits permit one commit and leave the other unchanged', {skip: !enabled}, async () => {
  const data = frame(); await submit(request(data));
  const before = (await db.doc(`organizations/${org}/counters/changeSequence`).get()).data().value;
  const edits = ['B', 'C'].map(sampleName => frame({commandType: 'sample.update', entityId: data.entityId, expectedVersion: 1, payload: {sampleName}}));
  const results = await Promise.allSettled(edits.map(value => submit(request(value))));
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(results.find(result => result.status === 'rejected').reason.details.code, 'VERSION_CONFLICT');
  assert.equal((await db.doc(`organizations/${org}/counters/changeSequence`).get()).data().value, before + 1);
});
test('receipt replay remains true after write permission is removed; no new write is allowed', {skip: !enabled}, async () => {
  const data = frame(); const receipt = await submit(request(data));
  await db.doc(`users/${uid}`).update({role: 'viewer'});
  try {
    assert.deepEqual(await submit(request(data)), receipt);
    await assert.rejects(submit(request(frame())), error => error.details.code === 'PERMISSION_DENIED');
  } finally { await db.doc(`users/${uid}`).update({role: 'lab'}); }
});
test('revoked device and expired trial are denied before any receipt is created', {skip: !enabled}, async () => {
  const data = frame();
  const device = db.doc(`organizations/${org}/devices/writer-device`);
  await device.update({status: 'revoked'});
  try { await assert.rejects(submit(request(data)), error => error.details.code === 'DEVICE_UNTRUSTED'); }
  finally { await device.update({status: 'active'}); }
  const organization = db.doc(`organizations/${org}`);
  await organization.update({status: 'trial', trialEndsAt: '2000-01-01T00:00:00Z'});
  try { await assert.rejects(submit(request(data)), error => error.details.code === 'ORG_SUSPENDED'); }
  finally { await organization.update({status: 'active'}); }
  assert.equal((await db.doc(`organizations/${org}/commandReceipts/${data.operationId}`).get()).exists, false);
});
test('new protocol stays closed before an explicit server-side pilot gate', {skip: !enabled}, async () => {
  const organization = db.doc(`organizations/${org}`);
  await organization.update({'commandProtocol.enabled': false});
  try { await assert.rejects(submit(request(frame())), error => error.details.code === 'PROTOCOL_NOT_READY'); }
  finally { await organization.update({'commandProtocol.enabled': true}); }
});
