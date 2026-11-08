/**
 * The cutover (production readiness 5). Idempotent, staged, and safe to
 * re-run: every stage is recorded in `organizations/{org}/migrationState/current`
 * and is a no-op once done. Stages, in order:
 *
 *   audit        re-run audit.js verdict (refuses to continue on blockers)
 *   counters     create `counters/changeSequence` (max existing event seq, else 0)
 *                and `counters/sampleNumber` (max sampleNo over samples)
 *   parentRefs   backfill `parentRefs` on legacy documents from their
 *                remote-id columns, so the client can materialize the
 *                snapshot channel after cutover (only writes when absent)
 *   freeze       enforce maintenance mode before inspecting or changing data
 *   reservations build `uniqueReservations` for every document, retaining
 *                non-partial unique claims on tombstones — the
 *                exact claims domain admission will enforce
 *   gate         set `commandProtocol` = {enabled, schemaVersion: 3,
 *                domainManifestVersion: 1, migrationId, writePolicy: multi_authorized,
 *                globalReferencesReady: true, uniqueAdmissionComplete: true}
 *
 * `--abort` enforces maintenance mode; it never reopens a legacy writer.
 * It records the abort in migrationState, and leaves every other
 * artifact in place for a later re-run.
 *
 * Usage:
 *   node migrate.js --org <orgId> [--project demo-materiallab]
 *   node migrate.js --org <orgId> --stage gate --evidence FILE --project <prod>
 *   node migrate.js --org <orgId> --abort [--abort-reason "..."]
 */
'use strict';

const {admin, definition, SCHEMA_VERSION, entityTypes, collectionOf, listDocs, loadParentDocs, parentRemoteId} = require('./shared');
const {auditOrganization} = require('./audit');

function chunk(items, size) {
  const out = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

async function readState(orgRef) {
  const snap = await orgRef.collection('migrationState').doc('current').get();
  return snap.exists ? snap.data() : null;
}

async function writeState(orgRef, patch) {
  await orgRef.collection('migrationState').doc('current').set({
    ...patch, updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
}

async function stageAudit(db, orgRef, orgId) {
  const report = await auditOrganization(db, orgId);
  if (!report.ready) {
    const error = new Error(`Audit found ${report.blockerCount} blocker(s); fix them before migrating.`);
    error.blockers = report.entities;
    throw error;
  }
  await writeState(orgRef, {stage: 'audit', migrationId: orgRef.id, audit: {
    auditedAt: report.auditedAt, blockerCount: report.blockerCount,
    docs: Object.fromEntries(Object.entries(report.entities).map(([type, value]) => [type, value.docs])),
  }});
  return report;
}

async function stageCounters(db, orgRef, orgId) {
  const existing = await orgRef.collection('counters').doc('changeSequence').get();
  let maxSeq = 0;
  if (existing.exists && Number.isSafeInteger(existing.data().value)) {
    maxSeq = existing.data().value;
  }
  const events = await orgRef.collection('changeEvents').get();
  for (const doc of events.docs) {
    const seq = doc.data().seq;
    if (Number.isSafeInteger(seq) && seq > maxSeq) maxSeq = seq;
  }
  const existingSample = await orgRef.collection('counters').doc('sampleNumber').get();
  let maxSample = existingSample.exists && Number.isSafeInteger(existingSample.data().value)
    ? existingSample.data().value : 0;
  const samples = await collectionOf(db, orgId, 'sample').get();
  for (const doc of samples.docs) {
    const no = doc.data().sampleNo;
    if (Number.isSafeInteger(no) && no > maxSample) maxSample = no;
  }
  const counter = orgRef.collection('counters');
  await counter.doc('changeSequence').set({value: maxSeq});
  await counter.doc('sampleNumber').set({value: maxSample});
  await writeState(orgRef, {stage: 'counters', changeSequence: maxSeq, sampleNumber: maxSample});
  return {changeSequence: maxSeq, sampleNumber: maxSample};
}

async function stageParentRefs(db, orgRef, orgId) {
  let updated = 0;
  for (const type of entityTypes()) {
    const def = definition(type);
    if (!def.parents.length) continue;
    const docs = await listDocs(db, orgId, type);
    const parentDocs = await loadParentDocs(db, orgId, [...new Set(def.parents.map(p => p.type))]);
    for (const group of chunk(docs, 450)) {
      const batch = db.batch();
      for (const {id, data: doc, updateTime} of group) {
        if (doc.parentRefs && typeof doc.parentRefs === 'object' && Object.keys(doc.parentRefs).length) continue;
        const refs = {};
        for (const parent of def.parents) {
          const idValue = parentRemoteId(def, doc, parent, parentDocs);
          if (idValue == null) continue;
          const snap = parentDocs.get(`${parent.type}/${idValue}`);
          refs[parent.relation] = {
            entityType: parent.type, entityId: idValue,
            version: snap && snap.exists ? snap.data().version : null,
          };
        }
        if (!Object.keys(refs).length) continue;
        batch.update(orgRef.collection(def.collection).doc(id), {parentRefs: refs}, {lastUpdateTime: updateTime});
        updated += 1;
      }
      await batch.commit();
    }
  }
  await writeState(orgRef, {stage: 'parentRefs', documentsUpdated: updated});
  return {documentsUpdated: updated};
}

async function stageReservations(db, orgRef, orgId) {
  let written = 0;
  const reservation = orgRef.collection('uniqueReservations');
  for (const type of entityTypes()) {
    const def = definition(type);
    const docs = await listDocs(db, orgId, type);
    const parentDocs = await loadParentDocs(db, orgId, [...new Set(def.parents.map(p => p.type))]);
    const pending = [];
    for (const {id, data: doc} of docs) {
      const refs = {};
      for (const parent of def.parents) {
        const idValue = parentRemoteId(def, doc, parent, parentDocs);
        if (idValue != null) refs[parent.relation] = {entityType: parent.type, entityId: idValue};
      }
      let claims = [];
      try {
        claims = require('./shared').uniqueClaims(type, id, doc, refs);
      } catch (error) {
        throw new Error(`Unique claims failed for ${type}/${id}: ${error.message}`);
      }
      pending.push(...claims);
    }
    for (const group of chunk(pending, 450)) {
      const batch = db.batch();
      const previous = group.length ? await db.getAll(...group.map(c => reservation.doc(c.key))) : [];
      for (const [index, claim] of group.entries()) {
        const snap = previous[index];
        const data = {entityType: claim.entityType, entityId: claim.entityId, released: false,
          collection: def.collection, recordPath: orgRef.collection(def.collection).doc(claim.entityId)};
        if (snap.exists) {
          if (snap.data().entityType !== claim.entityType || snap.data().entityId !== claim.entityId) {
            throw Error(`Reservation ${claim.key} belongs to another record; a reviewed business decision is required`);
          }
          batch.update(snap.ref, data, {lastUpdateTime: snap.updateTime});
        } else {
          batch.create(reservation.doc(claim.key), data);
        }
        written += 1;
      }
      await batch.commit();
    }
  }
  await writeState(orgRef, {stage: 'reservations', reservations: written});
  return {reservations: written};
}

async function stageGate(orgRef, migrationId, evidence) {
  if (!orgRef.firestore.projectId.startsWith('demo-')) require('./release_gate').assertReleaseEvidence(evidence);
  if (!migrationId) throw new Error('stage gate needs --migration-id');
  const state = await readState(orgRef);
  if (!state || !state.audit || state.audit.blockerCount !== 0 ||
      !Object.hasOwn(state, 'changeSequence') ||
      !Object.hasOwn(state, 'sampleNumber') ||
      !Object.hasOwn(state, 'documentsUpdated') ||
      !Object.hasOwn(state, 'reservations')) {
    throw new Error('Complete audit, counters, parentRefs and reservations before enabling the central protocol.');
  }
  // Recheck the actual server data at cutover; never manufacture readiness
  // flags to bypass missing raw-inspection references or duplicate identities.
  await stageAudit(orgRef.firestore, orgRef, orgRef.id);
  const devices = await orgRef.collection('devices').get();
  if (!devices.docs.some(d => d.data().status === 'active' && d.data().readOnly === false)) {
    throw new Error('Register at least one active writable device before cutover');
  }
  await orgRef.update('commandProtocol', {
    enabled: true, schemaVersion: SCHEMA_VERSION, domainManifestVersion: 1,
    migrationId, mode: 'firestore_direct_v2', writePolicy: 'multi_authorized', maintenance: false,
    globalReferencesReady: true, uniqueAdmissionComplete: true,
  });
  await writeState(orgRef, {stage: 'gate', migrationId, writePolicy: 'multi_authorized', gatedAt: admin.firestore.FieldValue.serverTimestamp()});
  return {migrationId, writePolicy: 'multi_authorized'};
}

async function abort(orgRef, reason) {
  await orgRef.update('commandProtocol.maintenance', true);
  await writeState(orgRef, {stage: 'aborted', abortReason: reason ?? null, abortedAt: admin.firestore.FieldValue.serverTimestamp()});
}

async function migrate(db, orgId, options = {}) {
  const orgRef = db.collection('organizations').doc(orgId);
  if (options.abort) {
    await abort(orgRef, options.abortReason);
    return {aborted: true};
  }
  const gate = (await orgRef.get()).data()?.commandProtocol;
  if (options.stage && options.stage !== 'freeze' && gate?.maintenance !== true) throw new Error('Freeze client writes before migration');
  const migrationId = options.migrationId || `migration-${new Date().toISOString().replace(/[:.]/g, '-')}`;
  const results = {};
  const stages = options.stage ? [options.stage] : ['freeze', 'audit', 'counters', 'parentRefs', 'reservations', 'gate'];
  for (const stage of stages) {
    switch (stage) {
      case 'freeze': await orgRef.set({commandProtocol: {maintenance: true}}, {merge: true}); results.freeze = true; break;
      case 'audit': results.audit = await stageAudit(db, orgRef, orgId); break;
      case 'counters': results.counters = await stageCounters(db, orgRef, orgId); break;
      case 'parentRefs': results.parentRefs = await stageParentRefs(db, orgRef, orgId); break;
      case 'reservations': results.reservations = await stageReservations(db, orgRef, orgId); break;
      case 'gate': results.gate = await stageGate(orgRef, migrationId, options.evidence); break;
      default: throw new Error(`Unknown stage ${stage}`);
    }
  }
  return {migrationId, stages, ...results};
}

async function main() {
  const list = process.argv.slice(2);
  const args = {};
  for (let i = 0; i < list.length; i++) {
    if (list[i].startsWith('--')) {
      const next = list[i + 1];
      args[list[i].slice(2)] = next && !next.startsWith('--') ? next : true;
    }
  }
  const shared = require('./shared');
  const {db} = shared.init(args.project);
  if (!args.org) {
    console.error('Usage: node migrate.js --org <orgId> [--evidence <file>] [--migration-id <id>] [--stage <name>] [--abort] [--project <projectId>]');
    process.exit(2);
  }
  try {
    const result = await migrate(db, args.org, {
      evidence: args.evidence,
      abort: args.abort === true,
      abortReason: args['abort-reason'],
      stage: typeof args.stage === 'string' ? args.stage : undefined,
      migrationId: typeof args['migration-id'] === 'string' ? args['migration-id'] : undefined,
    });
    console.log(JSON.stringify(result, null, 2));
  } finally {
    await shared.admin.app().delete();
  }
}

if (require.main === module) main().catch(error => {
  console.error(error);
  process.exit(1);
});

module.exports = {migrate, readState};
