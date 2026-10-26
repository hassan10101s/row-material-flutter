/**
 * Emulator proof for the central-protocol migration (production readiness 5).
 *
 * Run under the Firestore emulator:
 *   firebase emulators:exec --only firestore --project demo-materiallab "node tool/central_migration/proof.js"
 * (from the repo root; FIRESTORE_EMULATOR_HOST is set by the exec harness).
 *
 * Seeds a LEGACY-shaped organization (no commandProtocol, no counters, no
 * parentRefs, remote-id columns only), then:
 *   1. audit.js      → ready, zero blockers,
 *   2. backup.js     → JSONL files exist with the expected counts,
 *   3. migrate.js    → counters initialized (changeSequence 0, sampleNumber 1),
 *                      uniqueReservations built (material name + sample
 *                      entry code), parentRefs backfilled on the sample,
 *                      commandProtocol gate set,
 *   4. idempotency   → a second full migrate run changes nothing (parentRefs
 *                      not duplicated, reservations stable),
 *   5. protocol      → the REAL central sync handler serves the migrated org:
 *                      beginSnapshot gates on the new commandProtocol and
 *                      snapshotPage/events return the legacy documents.
 *   6. abort         → gate disabled, migrationState records the abort.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {init, listDocs} = require('./shared');
const {auditOrganization} = require('./audit');
const {backupOrganization} = require('./backup');
const {migrate, readState} = require('./migrate');

const {admin, db} = init('demo-materiallab');
const org = `migration-proof-${process.pid}`;
const uid = 'uid_admin';
const ref = p => db.doc(`organizations/${org}/${p}`);
const now = admin.firestore.Timestamp.now();

async function seedLegacyOrg() {
  await db.doc(`organizations/${org}`).set({status: 'active', name: 'Legacy Org'});
  await db.doc(`users/${uid}`).set({organizationId: org, status: 'active', role: 'admin', displayName: 'Legacy Admin'});
  await ref('devices/writer').set({uid, status: 'active', readOnly: false});
  // Legacy reference material: remote-id column, version, NO parentRefs/protocol.
  await ref('referenceMaterials/legacy-material-1').set({
    organizationId: org, version: 1, materialName: 'Legacy Material', materialCode: 'LM-1',
    createdBy: uid, createdAt: now, updatedAt: now, updatedBy: uid,
    deviceId: 'writer', remoteId: 'legacy-material-1', deletedAt: null,
  });
  // Legacy sample: local int FK (materialId: 1) + global remote id column.
  await ref('samples/legacy-sample-1').set({
    organizationId: org, version: 1, sampleNo: 1, entryCode: 'S-1',
    materialId: 1, materialRemoteId: 'legacy-material-1',
    inspectionKind: 'raw', decisionStatus: 'PENDING', decisionVersion: 1,
    createdBy: uid, createdAt: now, updatedAt: now, updatedBy: uid,
    deviceId: 'writer', remoteId: 'legacy-sample-1', deletedAt: null,
  });
}

async function main() {
  await seedLegacyOrg();
  const results = {};

  // 1. audit: legacy shape is protocol-clean.
  const audit = await auditOrganization(db, org);
  assert.equal(audit.ready, true, JSON.stringify(audit.entities, null, 2));
  assert.equal(audit.blockerCount, 0);
  results.audit = {blockerCount: audit.blockerCount};

  // 2. backup: JSONL exists with expected counts.
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'migration-backup-'));
  const {report} = await backupOrganization(db, org, outDir);
  assert.equal(report.files.samples.docs, 1);
  assert.equal(report.files.referenceMaterials.docs, 1);
  assert.ok(fs.existsSync(path.join(outDir, 'samples.jsonl')));
  assert.ok(fs.readFileSync(path.join(outDir, 'samples.jsonl'), 'utf8').includes('legacy-sample-1'));
  results.backup = {total: report.total};

  // 3. migrate (full): counters, reservations, parentRefs, gate.
  const migration = await migrate(db, org, {writerDeviceId: 'writer', migrationId: 'proof-1'});
  assert.equal(migration.counters.changeSequence, 0);
  assert.equal(migration.counters.sampleNumber, 1);
  assert.equal(migration.parentRefs.documentsUpdated, 1, 'only the sample needs parentRefs');
  assert.equal(migration.reservations.reservations, 2, 'material name + sample entry code');
  const protocol = (await db.doc(`organizations/${org}`).get()).data().commandProtocol;
  assert.equal(protocol.enabled, true);
  assert.equal(protocol.schemaVersion, 2);
  assert.equal(protocol.migrationId, 'proof-1');
  assert.equal(protocol.writerDeviceId, 'writer');
  const sampleDoc = (await ref('samples/legacy-sample-1').get()).data();
  assert.deepEqual(sampleDoc.parentRefs, {
    materialId: {entityType: 'referenceMaterial', entityId: 'legacy-material-1', version: 1},
  });
  assert.equal(sampleDoc.version, 1, 'backfill must not bump versions');
  const reservations = await db.collection(`organizations/${org}/uniqueReservations`).get();
  assert.equal(reservations.size, 2);
  results.migrate = migration;

  // 4. idempotency: a second full run is a no-op.
  const again = await migrate(db, org, {writerDeviceId: 'writer', migrationId: 'proof-2'});
  assert.equal(again.parentRefs.documentsUpdated, 0, 'parentRefs already present');
  assert.equal(again.reservations.reservations, 2, 'reservations are set, not created');
  assert.equal(((await ref('samples/legacy-sample-1').get()).data()).version, 1);

  // 5. the REAL central sync handler serves the migrated org.
  const {buildCentralSyncHandler} = require('../../functions/central_sync');
  const handler = buildCentralSyncHandler(admin);
  const call = (mode, extra) => handler({auth: {uid}, data: {mode, organizationId: org, deviceId: 'writer', ...extra}});
  const snapshot = await call('beginSnapshot', {});
  assert.equal(snapshot.throughSequence, 0);
  const page = await call('snapshotPage', {entityType: 'sample', throughSequence: 0});
  assert.equal(page.records.length, 1);
  assert.equal(page.records[0].version, 1);
  assert.equal(page.records[0].data.parentRefs.materialId.entityId, 'legacy-material-1');
  const events = await call('events', {afterSequence: 0});
  assert.equal(events.events.length, 0);
  results.protocol = {throughSequence: snapshot.throughSequence, samplePage: page.records.length};

  // 6. abort: gate disabled, state recorded.
  await migrate(db, org, {abort: true, abortReason: 'proof rollback'});
  const after = (await db.doc(`organizations/${org}`).get()).data().commandProtocol;
  assert.equal(after.enabled, false);
  const state = await readState(db.collection('organizations').doc(org));
  assert.equal(state.stage, 'aborted');
  results.abort = true;

  console.log(JSON.stringify({org, ok: true, ...results}, null, 2));

  await db.recursiveDelete(db.doc(`organizations/${org}`));
  await db.doc(`users/${uid}`).delete();
  await admin.app().delete();
}

if (require.main === module) main().catch(async error => {
  console.error(error);
  try {
    await db.recursiveDelete(db.doc(`organizations/${org}`));
    await db.doc(`users/${uid}`).delete();
  } catch {}
  await admin.app().delete().catch(() => {});
  process.exit(1);
});
