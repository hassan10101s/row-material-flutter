/**
 * Pre-migration backup (production readiness 5). Exports every domain entity
 * of one organization — plus users/devices/counters/changeEvents/migrationState
 * — as JSONL (one JSON document per line, `{path, id, data}`) and writes a
 * `restore-report.json` with per-collection counts and a restore recipe.
 *
 * This is the safety net for migrate.js: if the cutover must be rolled back
 * at the data level, every exported document can be re-set verbatim.
 *
 * Usage: node backup.js --org <orgId> [--out <dir>] [--project <projectId>]
 */
'use strict';

const fs = require('fs');
const path = require('path');
const {definition, entityTypes, listDocs, init} = require('./shared');

const EXTRA_COLLECTIONS = [
  'users', 'devices', 'counters', 'changeEvents', 'uniqueReservations',
  'notifyRequests', 'auditLogs', 'sync_conflicts', 'receipts',
];

async function backupOrganization(db, orgId, outDir) {
  const orgRef = db.collection('organizations').doc(orgId);
  fs.mkdirSync(outDir, {recursive: true});
  const report = {organizationId: orgId, backedUpAt: new Date().toISOString(), files: {}, total: 0};

  const writeJsonl = async (name, collectionPath) => {
    const snap = await db.collection(collectionPath).get();
    const file = path.join(outDir, `${name}.jsonl`);
    const stream = fs.createWriteStream(file);
    for (const doc of snap.docs) {
      stream.write(`${JSON.stringify({path: `${collectionPath}/${doc.id}`, id: doc.id, data: doc.data()})}\n`);
    }
    await new Promise(resolve => stream.end(resolve));
    report.files[name] = {collection: collectionPath, docs: snap.size};
    report.total += snap.size;
  };

  for (const type of entityTypes()) {
    const def = definition(type);
    const name = def.collection === 'labConfig' ? `labConfig_${def.table}` : def.collection;
    if (report.files[name]) continue; // labConfig entities share one collection
    const docs = await listDocs(db, orgId, type);
    const file = path.join(outDir, `${name}.jsonl`);
    fs.writeFileSync(file, docs.map(({id, data}) => JSON.stringify({path: `organizations/${orgId}/${def.collection}/${id}`, id, data})).join('\n') + (docs.length ? '\n' : ''));
    report.files[name] = {collection: `organizations/${orgId}/${def.collection}`, docs: docs.length};
    report.total += docs.length;
  }
  for (const extra of EXTRA_COLLECTIONS) {
    await writeJsonl(extra, `organizations/${orgId}/${extra}`);
  }
  const orgDoc = await orgRef.get();
  const orgFile = path.join(outDir, 'organization.jsonl');
  fs.writeFileSync(orgFile, orgDoc.exists ? `${JSON.stringify({path: `organizations/${orgId}`, id: orgId, data: orgDoc.data()})}\n` : '');
  report.files.organization = {collection: `organizations/${orgId}`, docs: orgDoc.exists ? 1 : 0};
  report.total += orgDoc.exists ? 1 : 0;

  const reportFile = path.join(outDir, 'restore-report.json');
  fs.writeFileSync(reportFile, JSON.stringify(report, null, 2));
  return {report, reportFile};
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
  if (!args.org) {
    console.error('Usage: node backup.js --org <orgId> [--out <dir>] [--project <projectId>]');
    process.exit(2);
  }
  const {db, admin: sharedAdmin} = init(args.project);
  const outDir = typeof args.out === 'string' ? args.out : path.join('backup', `${args.org}-${Date.now()}`);
  const {report} = await backupOrganization(db, args.org, outDir);
  console.log(JSON.stringify(report, null, 2));
  await sharedAdmin.app().delete();
}

if (require.main === module) main().catch(error => {
  console.error(error);
  process.exit(1);
});

module.exports = {backupOrganization};
