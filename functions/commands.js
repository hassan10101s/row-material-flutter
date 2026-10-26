/**
 * Central command service (plan SYNC_ARCHITECTURE_PLAN_2026-10-25 §6).
 *
 * One callable, `submitCommand`: the ONLY approved write path after cutover.
 * Clients never write these collections directly (firestore.rules denies
 * it); the server derives identity, membership, role and device trust from
 * the auth request + Firestore's own documents — never from the JSON body.
 *
 * Invariants implemented here:
 *  - one request, one effect: receipts keyed by operationId inside the commit
 *    transaction; a byte-identical replay returns the first outcome, the same
 *    id with different content is refused;
 *  - no partial approval: document, counters, audit, change-event, notify
 *    request and the receipt commit in ONE Firestore transaction;
 *  - official numbers (sampleNo) and the official change sequence come from
 *    server counters inside that same transaction — never device clocks;
 *  - optimistic concurrency via expectedVersion; a conflict overwrites
 *    nothing and tells the client the current server version;
 *  - deleted is terminal: an update cannot revive a tombstoned document.
 *
 * Pure helpers (hashing, validation, permission mapping) are exported for
 * `functions/test/commands.test.js`; no reads happen in export-time.
 */
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const crypto = require("crypto");

const SCHEMA_VERSION = 2;
const MAX_PAYLOAD_KEYS = 120;
const MAX_STRING_FIELD = 20000;

/** Registry + required permission (mirrors lib/core/commands). */
const COMMAND_DEFS = {
  'domain.commit': {permission: 'org.read', entity: 'domainTransaction'},
  "sample.create": {permission: "samples.create", entity: "sample"},
  "sample.update": {permission: "samples.update", entity: "sample"},
  "sample.delete": {permission: "samples.update", entity: "sample"},
};

/** Mirrors firestore.rules `rolePermissions` + permissions.dart. Keep in sync. */
const ROLE_PERMISSIONS = {
  admin: [
    "org.read","org.update",
    "users.read","users.create","users.update","users.disable",
    "samples.read","samples.create","samples.update",
    "lab_results.read","lab_results.create","lab_results.update",
    "qc.read","qc.write","qc.approve","qc.reject",
    "reports.read","reports.create","reports.export",
    "devices.read","devices.register","devices.update","audit.read",
    "formulations.read","formulations.create","formulations.update",
  ],
  trial_owner: [
    "org.read",
    "samples.read","samples.create","samples.update",
    "lab_results.read","lab_results.create","lab_results.update",
    "qc.read","qc.write",
    "reports.read","reports.create","devices.register",
    "formulations.read","formulations.create","formulations.update",
  ],
  quality_manager: [
    "org.read","users.read",
    "samples.read","samples.create","samples.update",
    "lab_results.read","lab_results.create","lab_results.update",
    "qc.read","qc.write","qc.approve","qc.reject",
    "reports.read","reports.create","reports.export","devices.register",
    "audit.read",
    "formulations.read",
  ],
  lab: [
    "org.read",
    "samples.read","samples.create","samples.update",
    "lab_results.read","lab_results.create","lab_results.update",
    "reports.read","devices.register","formulations.read",
  ],
  nutritionist: [
    "org.read","samples.read","lab_results.read","reports.read","devices.register",
    "formulations.read","formulations.create","formulations.update",
  ],
  viewer: [
    "org.read","samples.read","lab_results.read","qc.read","reports.read",
    "devices.register","formulations.read",
  ],
};

// ── pure helpers ────────────────────────────────────────────────────────────

// Typed canonical JSON avoids Dart/JS differences for 1 vs 1.0,
// negative zero, exponent formatting and numeric-looking object keys.
function canonicalize(value) {
  if (value === null) return ['null'];
  if (typeof value === 'boolean') return ['boolean', value];
  if (typeof value === 'string') return ['string', value];
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value))) {
      throw new TypeError('Unsupported JSON number');
    }
    const bytes = Buffer.alloc(8);
    bytes.writeDoubleBE(value === 0 ? 0 : value);
    return ['number', bytes.toString('hex')];
  }
  if (Array.isArray(value)) return ['array', value.map(canonicalize)];
  if (value && typeof value === 'object') {
    return ['object', Object.keys(value).sort().map(key => [key, canonicalize(value[key])])];
  }
  throw new TypeError('Unsupported JSON value');
}

function hashPayload(payload) {
  return crypto.createHash('sha256').update(JSON.stringify(canonicalize(payload))).digest('hex');
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function safeId(value, max = 256) {
  return typeof value === 'string' && value.length > 0 && value.length <= max &&
    !value.includes('/') && !/[\x00-\x1f]/.test(value) && value !== '.' && value !== '..' && !/^__.*__$/.test(value);
}
function requestHash(data) {
  return hashPayload({organizationId: data.organizationId, schemaVersion: data.schemaVersion,
    commandType: data.commandType, entityId: data.entityId, expectedVersion: data.expectedVersion,
    payload: data.payload, payloadHash: data.payloadHash, deviceId: data.deviceId,
    dependencies: data.dependencies || {}});
}

function roleCan(role, permission) {
  if (Array.isArray(role)) {
    return role.some((item) => roleCan(item, permission));
  }
  return Object.hasOwn(ROLE_PERMISSIONS, role) && ROLE_PERMISSIONS[role].includes(permission);
}

function profileRoles(profile) {
  if (profile && Object.hasOwn(profile, 'roles')) {
    return Array.isArray(profile.roles) ? profile.roles : [];
  }
  return [profile && profile.role || ''];
}

function validRoleSet(roles, primaryRole) {
  if (!Array.isArray(roles) || roles.length < 1 || roles.length > 5 ||
      roles[0] !== primaryRole || new Set(roles).size !== roles.length ||
      roles.some((role) => !Object.hasOwn(ROLE_PERMISSIONS, role))) return false;
  return roles.length === 1 || !roles.some((role) =>
    role === 'admin' || role === 'trial_owner' || role === 'viewer');
}

const SAMPLE_FIELDS = [
  "productName","productCode","materialName","materialCode","sampleName",
  "batchNumber","formulaNumber","inspectionDate","supplier","truckNumber",
  "quantity","rejectedQuantity","sampleTakenBy","specialistName","notes",
];

/** create/update field allow-list + shallow type checks. */
function validatePayload(entity, operation, payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return badPayload("حمولة غير صالحة.");
  }
  const keys = Object.keys(payload).filter((k) => k !== "organizationId");
  if (keys.length > MAX_PAYLOAD_KEYS) {
    return badPayload("حمولة كبيرة غير مقبولة.");
  }
  if (entity !== "sample") {
    return badPayload("نوع كيان غير مدعوم.");
  }
  if (operation === "delete") {
    // Tombstones never carry fields (§7): a delete is only a marker.
    if (keys.length > 0) {
      return badPayload("أمر الحذف لا يحمل حقولاً.");
    }
    return null;
  }
  for (const key of keys) {
    if (!SAMPLE_FIELDS.includes(key)) {
      return badPayload(`حقل غير مسموح: ${key}`);
    }
    const v = payload[key];
    if (key === 'quantity' || key === 'rejectedQuantity') {
      if (v !== null && (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > Number.MAX_SAFE_INTEGER)) return badPayload('كمية غير صالحة.');
    } else if (v !== null && typeof v !== 'string') {
      return badPayload(`قيمة حقل غير صالحة: ${key}`);
    }
    if (typeof v === "string" && v.length > MAX_STRING_FIELD) {
      return badPayload(`حقل أكبر من الحد المسموح: ${key}`);
    }
  }
  if (payload.inspectionDate != null && payload.inspectionDate !== '') {
    const date = payload.inspectionDate;
    const time = Date.parse(date.replace(' ', 'T'));
    if (!/^\d{4}-\d{2}-\d{2}(?:[T ].+)?$/.test(date) || !Number.isFinite(time) ||
        new Date(time).toISOString().slice(0, 10) !== date.slice(0, 10)) return badPayload('تاريخ فحص غير صالح.');
  }
  return null;
}

function badPayload(message) {
  return {code: "BAD_PAYLOAD", messageAr: message};
}

/** Command frame validation (§6 step 2). Returns an error map or null. */
function validateSessionFrame(data) {
  const invalid = messageAr => ({http: 'invalid-argument', code: 'BAD_PAYLOAD', messageAr});
  if (!isObject(data)) return invalid('حمولة أمر غير صالحة.');
  const allowed = ['operationId','organizationId','schemaVersion','commandType','entityId',
    'expectedVersion','payload','payloadHash','deviceId','dependencies'];
  if (Object.keys(data).some(key => !allowed.includes(key))) return invalid('حقول أمر غير مسموحة.');
  if (typeof data.operationId !== 'string' || !/^[A-Za-z0-9_-]{8,64}$/.test(data.operationId)) return invalid('معرف عملية غير صالح.');
  if (!safeId(data.organizationId, 128) || !safeId(data.entityId) || !safeId(data.deviceId, 128)) return invalid('هوية غير صالحة.');
  if (data.schemaVersion !== SCHEMA_VERSION) return {code: 'SCHEMA_VERSION_MISMATCH', messageAr: 'حدّث نسخة التطبيق.'};
  if (typeof data.commandType !== 'string' || !Object.hasOwn(COMMAND_DEFS, data.commandType)) return {code: 'BAD_COMMAND_TYPE', messageAr: 'نوع أمر غير معروف.'};
  if (!Number.isSafeInteger(data.expectedVersion) || data.expectedVersion < 0 ||
      (data.commandType.endsWith('.create') && data.expectedVersion !== 0)) return invalid('نسخة متوقعة غير صالحة.');
  if (!isObject(data.payload) || !isObject(data.dependencies || {})) return invalid('حقول أو علاقات غير صالحة.');
  const dependencies = data.dependencies || {};
  if (Object.keys(dependencies).some(key => key !== 'parent_sample') ||
      Object.values(dependencies).some(value => !safeId(value)) ||
      (!data.commandType.endsWith('.create') && Object.keys(dependencies).length)) return invalid('علاقات غير مسموحة.');
  if (typeof data.payloadHash !== 'string' || !/^[a-f0-9]{64}$/.test(data.payloadHash)) return invalid('بصمة غير صالحة.');
  try {
    if (hashPayload(data.payload) !== data.payloadHash) return invalid('المحتوى لا يطابق البصمة.');
  } catch (_) { return invalid('قيمة غير مدعومة.'); }
  if (Buffer.byteLength(JSON.stringify(data), 'utf8') > 800000) return invalid('حمولة أكبر من الحد المسموح.');
  return null;
}

/**
 * Membership/permission/device trust, derived from Firestore documents the
 * client cannot forge (§6 step 1). `orgId` comes from the doc path.
 */
function validateMembership(profile, orgId, orgData, commandDef, deviceId) {
  const fail = (code, messageAr, http) => ({code, messageAr, http});
  if (!profile || !profile.organizationId) {
    return fail("MEMBERSHIP_PENDING", "لا يوجد ربط بحساب مؤسسة.",
      "permission-denied");
  }
  if (profile.organizationId !== orgId) {
    return fail("WRONG_ORG", "الطلب لا يعود لمؤسسة الحساب.",
      "failed-precondition");
  }
  if (profile.status !== "active") {
    return fail("MEMBERSHIP_PENDING", "الحساب غير مفعّل؛ انتظر تفعيل المدير.",
      "permission-denied");
  }
  const status = (orgData && orgData.status) || "";
  if (status !== "active" && status !== "trial") {
    return fail("ORG_SUSPENDED", "المؤسسة موقوفة حاليًا.",
      "failed-precondition");
  }
  const roles = profileRoles(profile);
  if (!validRoleSet(roles, profile.role) || !roleCan(roles, commandDef.permission)) {
    return fail("PERMISSION_DENIED", "لا تمتلك صلاحية هذا الأمر.",
      "permission-denied");
  }
  if (!deviceId || typeof deviceId !== "string" || deviceId.length > 128) {
    return fail("DEVICE_UNTRUSTED", "جهاز غير مسجل للطلب.",
      "permission-denied");
  }
  return null;
}

/** The stable code set the client branches on (must equal commandPermanentErrors). */
const PERMANENT_CODES = new Set([
  "UNAUTHENTICATED","MEMBERSHIP_PENDING","ORG_SUSPENDED","PERMISSION_DENIED",
  "DEVICE_UNTRUSTED","READ_ONLY_DEVICE","WRONG_ORG","SCHEMA_VERSION_MISMATCH",
  "BAD_COMMAND_TYPE","BAD_PAYLOAD","DUPLICATE_OPERATION_ID_CONTENT",
  "PARENT_MISSING_OR_DELETED","PARENT_DELETED_CANNOT_LINK","PARENT_WRONG_TYPE",
  "VERSION_CONFLICT","DELETED_CANNOT_MODIFY","NOT_FOUND","VALUE_OUT_OF_RANGE",
  "INVALID_FIELD","PROTOCOL_NOT_READY",
]);

/** Map a stable code onto the HttpsError shape the transport classifies. */
const HTTPS_CODE_BY_STABLE = {
  UNAUTHENTICATED: "unauthenticated",
  MEMBERSHIP_PENDING: "permission-denied",
  PERMISSION_DENIED: "permission-denied",
  READ_ONLY_DEVICE: "permission-denied",
  DEVICE_UNTRUSTED: "permission-denied",
  WRONG_ORG: "failed-precondition",
  ORG_SUSPENDED: "failed-precondition",
  SCHEMA_VERSION_MISMATCH: "failed-precondition",
  BAD_COMMAND_TYPE: "invalid-argument",
  BAD_PAYLOAD: "invalid-argument",
  DUPLICATE_OPERATION_ID_CONTENT: "failed-precondition",
  PARENT_MISSING_OR_DELETED: "failed-precondition",
  PARENT_DELETED_CANNOT_LINK: "failed-precondition",
  PARENT_WRONG_TYPE: "failed-precondition",
  VERSION_CONFLICT: "failed-precondition",
  DELETED_CANNOT_MODIFY: "failed-precondition",
  NOT_FOUND: "not-found",
  VALUE_OUT_OF_RANGE: "invalid-argument",
  INVALID_FIELD: "invalid-argument",
  INTERNAL: "internal",
  UNAVAILABLE: "unavailable",
  PROTOCOL_NOT_READY: "failed-precondition",
};

function httpsCodeFor(code) {
  return HTTPS_CODE_BY_STABLE[code] || "internal";
}

/** HttpsError with our stable code+message in `details`. */
function throwStable(code, messageAr, extra) {
  const details = {code, messageAr, ...(extra || {})};
  throw new HttpsError(httpsCodeFor(code), messageAr, details);
}

module.exports = {
  SCHEMA_VERSION,
  COMMAND_DEFS,
  ROLE_PERMISSIONS,
  profileRoles,
  validRoleSet,
  PERMANENT_CODES,
  canonicalize,
  requestHash,
  hashPayload,
  roleCan,
  validatePayload,
  validateSessionFrame,
  validateMembership,
  httpsCodeFor,
  throwStable,
};
