/**
 * Shared plumbing for the central-protocol migration tooling (production
 * readiness 5). Everything reads the SAME manifest, hashing and unique-claim
 * code the server enforces (domain_manifest.json, server/commands.js,
 * server/domain_admission.js), so an audit verdict
 * and the reservations it writes can never drift from admission's rules.
 *
 * Runs against the Firestore emulator by default (project `demo-materiallab`,
 * the `demo-` prefix makes it impossible to touch a real project) — a real
 * migration must pass --project and --org explicitly.
 */
'use strict';

// The manifest and server helpers live in this directory; runtime deps
// (firebase-admin) resolve through server/package.json (one source of truth
// for versions).
const {createRequire} = require('module');
const fromServer = createRequire(require.resolve('./server/package.json'));
const admin = fromServer('firebase-admin');
const manifest = require('./domain_manifest.json');
const {definition} = require('./server/domain_commands');
const {SCHEMA_VERSION} = fromServer('./commands');
const {directUniqueClaims: uniqueClaims} = require('./direct_unique');

const toCamel = value => String(value).replace(/_([a-z0-9])/g, (_, letter) => letter.toUpperCase());
const keyOf = ref => `${ref.entityType}/${ref.entityId}`;

function entityTypes() {
  return Object.keys(manifest.entities).filter(type => type !== 'auditLog');
}

/** The Firestore collection that stores one entity type (labConfig is split by `configType`). */
function collectionOf(db, orgId, entityType) {
  const def = definition(entityType);
  const base = db.collection(`organizations/${orgId}/${def.collection}`);
  return def.collection === 'labConfig' ? base.where('configType', '==', def.table) : base;
}

function safeJson(value) {
  if (typeof value !== 'string') return null;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

/**
 * The nested payload of a labConfig document (snake_case keys, as the legacy
 * write path stored it); `null` for every other entity.
 */
function nestedPayload(def, doc) {
  if (def.collection !== 'labConfig') return null;
  const nested = doc.payload && typeof doc.payload === 'object' ? doc.payload : safeJson(doc.payload);
  return nested && typeof nested === 'object' ? nested : null;
}

/**
 * The parent's GLOBAL id for one declared relation, read from the remote-id
 * columns the legacy write path carries (`material_id` → top-level
 * `materialRemoteId`, nested labConfig payload → `material_remote_id`).
 */
function parentRemoteId(def, doc, parent, parentDocs) {
  // `material_id` is stored remotely as `materialRemoteId` (camel of
  // `material_remote_id`), nested labConfig payloads keep the snake form.
  const remoteColumn = parent.localField.replace(/_id$/, '_remote_id');
  const remoteKey = toCamel(remoteColumn);
  const nested = nestedPayload(def, doc);
  const ref = doc.parentRefs?.[parent.relation];
  if (ref && ref.entityType !== parent.type) return null;
  const candidates = [doc[remoteKey], nested?.[remoteKey], nested?.[remoteColumn], ref?.entityId]
    .filter(v => typeof v === 'string' && v !== '');
  if (new Set(candidates).size > 1) return null;
  const value = candidates[0];
  if (typeof value === 'string' && value !== '') {
    const target = parentDocs?.get(`${parent.type}/${value}`);
    return !parentDocs || (target?.exists && target.data().organizationId === doc.organizationId) ? value : null;
  }
  // Old raw inspections carry a material code instead of a global id. Use it
  // only when exactly one server material matches; never trust a device's id.
  if (def.table === 'inspections' && parent.type === 'referenceMaterial' && parentDocs) {
    const code = typeof doc.materialCode === 'string' ? doc.materialCode.trim().toLowerCase() : '';
    const name = typeof doc.materialName === 'string' ? doc.materialName.trim().toLowerCase() : '';
    if (!code && !name) return null;
    const matches = [...parentDocs.entries()].filter(([key, snap]) => {
      if (!key.startsWith('referenceMaterial/') || !snap.exists) return false;
      const material = snap.data();
      if (material.organizationId !== doc.organizationId) return false;
      return code ? String(material.materialCode || '').trim().toLowerCase() === code
        : String(material.materialName || '').trim().toLowerCase() === name;
    });
    return matches.length === 1 ? matches[0][0].slice('referenceMaterial/'.length) : null;
  }
  return null;
}

/**
 * Builds the `parentRefs` map the central protocol serves with every
 * after-image. Parent versions come from the parent's live document at
 * migration time; a missing optional parent is simply absent, a missing
 * REQUIRED parent is a blocker the caller must report.
 */
async function buildParentRefs(db, orgId, def, doc, parentDocs) {
  const refs = {};
  for (const parent of def.parents) {
    const id = parentRemoteId(def, doc, parent, parentDocs);
    if (id == null) continue;
    const snap = parentDocs.get(`${parent.type}/${id}`);
    refs[parent.relation] = {
      entityType: parent.type,
      entityId: id,
      version: snap && snap.exists ? snap.data().version : null,
    };
  }
  return refs;
}

/** Loads every document of one entity type (with doc.id attached). */
async function listDocs(db, orgId, entityType) {
  const snap = await collectionOf(db, orgId, entityType).get();
  return snap.docs.map(doc => ({id: doc.id, data: doc.data(), updateTime: doc.updateTime}));
}

/** Maps `parentType/parentId` → parent doc snapshot for batched version reads. */
async function loadParentDocs(db, orgId, types) {
  const wanted = new Set(types);
  const map = new Map();
  for (const type of wanted) {
    const snap = await collectionOf(db, orgId, type).get();
    for (const doc of snap.docs) map.set(`${type}/${doc.id}`, doc);
  }
  return map;
}

function init(projectId) {
  const resolvedProject = projectId || 'demo-materiallab';
  if (resolvedProject === 'demo-materiallab') {
    process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
  } else if (resolvedProject !== 'materiallab-63405') {
    throw new Error('Only demo-materiallab or the explicitly authorized materiallab-63405 may be used.');
  } else if (process.env.FIRESTORE_EMULATOR_HOST) {
    throw new Error('Refusing to audit a real project through an emulator endpoint.');
  }
  const app = admin.initializeApp({projectId: resolvedProject});
  return {admin, app, db: app.firestore(), manifest, definition, SCHEMA_VERSION, uniqueClaims, keyOf};
}

module.exports = {
  admin, manifest, definition, SCHEMA_VERSION, uniqueClaims, keyOf,
  toCamel, entityTypes, collectionOf, nestedPayload, parentRemoteId,
  buildParentRefs, listDocs, loadParentDocs, init,
};
