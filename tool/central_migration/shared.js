/**
 * Shared plumbing for the central-protocol migration tooling (production
 * readiness 5). Everything reads the SAME manifest, hashing and unique-claim
 * code the server enforces (functions/domain_manifest.json,
 * functions/commands.js, functions/domain_admission.js), so an audit verdict
 * and the reservations it writes can never drift from admission's rules.
 *
 * Runs against the Firestore emulator by default (project `demo-materiallab`,
 * the `demo-` prefix makes it impossible to touch a real project) — a real
 * migration must pass --project and --org explicitly.
 */
'use strict';

// The tool lives outside functions/, so resolve runtime deps through the
// functions package itself (keeps one source of truth for versions).
const {createRequire} = require('module');
const fromFunctions = createRequire(require.resolve('../../functions/package.json'));
const admin = fromFunctions('firebase-admin');
const manifest = require('../../functions/domain_manifest.json');
const {definition} = require('../../functions/domain_commands');
const {SCHEMA_VERSION} = fromFunctions('./commands');
const {uniqueClaims} = fromFunctions('./domain_admission');

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
function parentRemoteId(def, doc, parent) {
  // `material_id` is stored remotely as `materialRemoteId` (camel of
  // `material_remote_id`), nested labConfig payloads keep the snake form.
  const remoteKey = toCamel(parent.localField.replace(/_id$/, '_remote_id'));
  const nested = nestedPayload(def, doc);
  const value = doc[remoteKey] ?? (nested ? nested[remoteKey] : undefined);
  return typeof value === 'string' && value !== '' ? value : null;
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
    const id = parentRemoteId(def, doc, parent);
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
  return snap.docs.map(doc => ({id: doc.id, data: doc.data()}));
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
  process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
  const app = admin.initializeApp({projectId: projectId || 'demo-materiallab'});
  return {admin, app, db: app.firestore(), manifest, definition, SCHEMA_VERSION, uniqueClaims, keyOf};
}

module.exports = {
  admin, manifest, definition, SCHEMA_VERSION, uniqueClaims, keyOf,
  toCamel, entityTypes, collectionOf, nestedPayload, parentRemoteId,
  buildParentRefs, listDocs, loadParentDocs, init,
};
