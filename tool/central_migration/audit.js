/**
 * Read-only pre-cutover audit (production readiness 5). Walks every domain
 * entity of one organization and reports, per entity:
 *   - document count (live + tombstones),
 *   - protocol-shaped blockers: wrong organizationId, invalid `version`,
 *     missing/empty `createdBy`/`createdAt`/`updatedAt` (labConfig documents
 *     may omit `createdBy` — the legacy partial-update path removed it),
 *     missing remote ids for REQUIRED parents,
 *   - unique-key duplicates (the exact claims domain admission would make),
 *   - tombstone sanity (`deletedAt` set).
 * Exit code / `ready: false` means: DO NOT run migrate.js before fixing these.
 *
 * Usage: node audit.js [--project demo-materiallab] --org <orgId> [--json <out>]
 */
'use strict';

const {init, definition, uniqueClaims, keyOf, entityTypes, listDocs, loadParentDocs, parentRemoteId} = require('./shared');

async function auditOrganization(db, orgId) {
  const entities = {};
  let blockerCount = 0;
  for (const type of entityTypes()) {
    const def = definition(type);
    const docs = await listDocs(db, orgId, type);
    const parentTypes = [...new Set(def.parents.map(parent => parent.type))];
    const parentDocs = await loadParentDocs(db, orgId, parentTypes);
    const blockers = [];
    const claims = new Map();
    let live = 0;
    let tombstones = 0;
    for (const {id, data: doc} of docs) {
      const where = `${type}/${id}`;
      if (doc.deletedAt != null) tombstones += 1; else live += 1;
      if (doc.organizationId !== orgId) {
        blockers.push({where, code: 'WRONG_ORG', detail: doc.organizationId ?? null});
      }
      if (!Number.isSafeInteger(doc.version) || doc.version < 1) {
        blockers.push({where, code: 'BAD_VERSION', detail: doc.version ?? null});
      }
      const needsCreator = def.collection !== 'labConfig';
      if (needsCreator && (typeof doc.createdBy !== 'string' || doc.createdBy === '')) {
        blockers.push({where, code: 'MISSING_CREATED_BY'});
      }
      if (doc.createdAt == null || doc.updatedAt == null) {
        blockers.push({where, code: 'MISSING_TIMESTAMPS'});
      }
      // Required parent links must resolve through the remote-id columns.
      for (const parent of def.parents) {
        if (!parent.required) continue;
        if (parentRemoteId(def, doc, parent) == null) {
          blockers.push({where, code: 'MISSING_REQUIRED_PARENT', detail: parent.relation});
        }
      }
      // Unique claims exactly as domain admission will compute them.
      if (doc.deletedAt == null) {
        const refs = {};
        for (const parent of def.parents) {
          const idValue = parentRemoteId(def, doc, parent);
          if (idValue != null) {
            refs[parent.relation] = {entityType: parent.type, entityId: idValue};
          }
        }
        const record = def.collection === 'labConfig' ? {...doc} : doc;
        let computed;
        try {
          computed = uniqueClaims(type, id, record, refs);
        } catch (error) {
          blockers.push({where, code: 'CLAIM_ERROR', detail: String(error && error.message || error)});
          continue;
        }
        for (const claim of computed) {
          const previous = claims.get(claim.key);
          if (previous && keyOf(previous) !== `${type}/${id}`) {
            blockers.push({where, code: 'DUPLICATE_UNIQUE_VALUE', detail: `${keyOf(previous)} vs ${type}/${id}`});
          } else if (!previous) {
            claims.set(claim.key, {entityType: type, entityId: id});
          }
        }
      }
    }
    blockerCount += blockers.length;
    entities[type] = {
      collection: def.collection,
      configType: def.collection === 'labConfig' ? def.table : undefined,
      docs: docs.length,
      live,
      tombstones,
      blockers,
    };
  }
  return {organizationId: orgId, auditedAt: new Date().toISOString(), entities, blockerCount, ready: blockerCount === 0};
}

async function main() {
  const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, arg, index, list) => {
    if (arg.startsWith('--')) pairs.push([arg.slice(2), list[index + 1] && !list[index + 1].startsWith('--') ? list[index + 1] : true]);
    return pairs;
  }, []));
  const {db} = init(args.project);
  const orgId = args.org;
  if (typeof orgId !== 'string' || !orgId) {
    console.error('Usage: node audit.js --org <orgId> [--project <projectId>] [--json <outFile>]');
    process.exit(2);
  }
  const report = await auditOrganization(db, orgId);
  const text = JSON.stringify(report, null, 2);
  if (typeof args.json === 'string') {
    require('fs').writeFileSync(args.json, text);
  }
  console.log(text);
  await require('./shared').admin.app().delete();
  process.exit(report.ready ? 0 : 1);
}

if (require.main === module) main().catch(error => {
  console.error(error);
  process.exit(1);
});

module.exports = {auditOrganization};
