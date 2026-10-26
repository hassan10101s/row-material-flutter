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
 *   reservations build `uniqueReservations` for every LIVE document — the
 *                exact claims domain admission will enforce
 *   gate         set `commandProtocol` = {enabled, schemaVersion: 2,
 *                domainManifestVersion: 1, migrationId, writerDeviceId,
 *                globalReferencesReady: true, uniqueAdmissionComplete: true}
 *
 * `--abort` flips `commandProtocol.enabled` back to false (the rules then
 * stop rejecting central reads AND `legacyDomainWritesAllowed` re-admits the
 * legacy path), records the abort in migrationState, and leaves every other
 * artifact in place for a later re-run.
 *
 * Usage:
 *   node migrate.js --org <orgId> --writer-device <deviceId> [--project demo-materiallab]
 *   node migrate.js --org <orgId> --stage gate --project <prod>
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
  } else {
    const events = await orgRef.collection('changeEvents').get();
    for (const doc of events.docs) {
      const seq = doc.data().seq;
      if (Number.isSafeInteger(seq) && seq > maxSeq) maxSeq = seq;
    }
  }
  let maxSample = 0;
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
      for (const {id, data: doc} of group) {
        if (doc.parentRefs && typeof doc.parentRefs === 'object' && Object.keys(doc.parentRefs).length) continue;
        const refs = {};
        for (const parent of def.parents) {
          const idValue = parentRemoteId(def, doc, parent);
          if (idValue == null) continue;
          const snap = parentDocs.get(`${parent.type}/${idValue}`);
          refs[parent.relation] = {
            entityType: parent.type, entityId: idValue,
            version: snap && snap.exists ? snap.data().version : null,
          };
        }
        if (!Object.keys(refs).length) continue;
        batch.update(orgRef.collection(def.collection).doc(id), {parentRefs: refs});
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
    const docs = (await listDocs(db, orgId, type)).filter(({data: doc}) => doc.deletedAt == null);
    const parentDocs = await loadParentDocs(db, orgId, [...new Set(def.parents.map(p => p.type))]);
    const pending = [];
    for (const {id, data: doc} of docs) {
      const refs = {};
      for (const parent of def.parents) {
        const idValue = parentRemoteId(def, doc, parent);
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
      for (const claim of group) {
        batch.set(reservation.doc(claim.key), {entityType: claim.entityType, entityId: claim.entityId});
        written += 1;
      }
      await batch.commit();
    }
  }
  await writeState(orgRef, {stage: 'reservations', reservations: written});
  return {reservations: written};
}

async function stageGate(orgRef, migrationId, writerDeviceId) {
  if (!migrationId || typeof writerDeviceId !== 'string' || !writerDeviceId) {
    throw new Error('stage gate needs --migration-id and --writer-device');
  }
  await orgRef.update('commandProtocol', {
    enabled: true, schemaVersion: SCHEMA_VERSION, domainManifestVersion: 1,
    migrationId, writerDeviceId,
    globalReferencesReady: true, uniqueAdmissionComplete: true,
  });
  await writeState(orgRef, {stage: 'gate', migrationId, writerDeviceId, gatedAt: admin.firestore.FieldValue.serverTimestamp()});
  return {migrationId, writerDeviceId};
}

async function abort(orgRef, reason) {
  await orgRef.update('commandProtocol', {enabled: false});
  await writeState(orgRef, {stage: 'aborted', abortReason: reason ?? null, abortedAt: admin.firestore.FieldValue.serverTimestamp()});
}

async function migrate(db, orgId, options = {}) {
  const orgRef = db.collection('organizations').doc(orgId);
  if (options.abort) {
    await abort(orgRef, options.abortReason);
    return {aborted: true};
  }
  const migrationId = options.migrationId || `migration-${new Date().toISOString().replace(/[:.]/g, '-')}`;
  const results = {};
  const stages = options.stage ? [options.stage] : ['audit', 'counters', 'parentRefs', 'reservations', 'gate'];
  for (const stage of stages) {
    switch (stage) {
      case 'audit': results.audit = await stageAudit(db, orgRef, orgId); break;
      case 'counters': results.counters = await stageCounters(db, orgRef, orgId); break;
      case 'parentRefs': results.parentRefs = await stageParentRefs(db, orgRef, orgId); break;
      case 'reservations': results.reservations = await stageReservations(db, orgRef, orgId); break;
      case 'gate': results.gate = await stageGate(orgRef, migrationId, options.writerDeviceId); break;
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
    console.error('Usage: node migrate.js --org <orgId> [--writer-device <id>] [--migration-id <id>] [--stage <name>] [--abort] [--project <projectId>]');
    process.exit(2);
  }
  try {
    const result = await migrate(db, args.org, {
      abort: args.abort === true,
      abortReason: args['abort-reason'],
      stage: typeof args.stage === 'string' ? args.stage : undefined,
      migrationId: typeof args['migration-id'] === 'string' ? args['migration-id'] : undefined,
      writerDeviceId: typeof args['writer-device'] === 'string' ? args['writer-device'] : undefined,
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
