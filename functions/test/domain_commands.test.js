const test = require('node:test');
const assert = require('node:assert/strict');
const {validateWriteSet, validateAgainstCurrent} = require('../domain_commands');

const vectors = require('./fixtures/domain_wire_vectors.json');
const {hashPayload} = require('../commands');
function write(overrides = {}) {
  const baseline = structuredClone(vectors.inspection.payload.writes[0]);
  return {...baseline, ...overrides};
}
function quality(overrides = {}) {
  return {...structuredClone(vectors.qualityDecision.payload.writes.find(value => value.entityType === 'qualityCheck')), ...overrides};
}

test('actual Dart repository payloads and hashes pass the Node domain contract', () => {
  for (const [name, vector] of Object.entries(vectors)) {
    assert.equal(hashPayload(vector.payload), vector.payloadHash, name);
    assert.equal(validateWriteSet(vector.payload, 'admin', 'org_test'), null, name);
  }
});

test('the complete inspection contract preserves numeric text and existing initial decisions', () => {
  const value = write();
  assert.equal(validateWriteSet({writes: [value]}, 'lab', 'org_test'), null);
  assert.equal(validateAgainstCurrent(value, null, 'lab', [value]), null);
});

test('every effect is authorized; hiding a forbidden QC write beside an allowed sample is rejected', () => {
  const forbidden = quality();
  assert.equal(validateWriteSet({writes: [write(), forbidden]}, 'lab', 'org_test').code, 'PERMISSION_DENIED');
});

test('duplicate identities and append-only mutations are refused before the transaction', () => {
  assert.equal(validateWriteSet({writes: [write(), write()]}, 'admin', 'org_test').code, 'BAD_PAYLOAD');
  const immutable = write({entityType: 'inventoryTransaction', operation: 'update', expectedVersion: 1, payload: {},
    relations: {inventoryId: {entityType: 'inventoryItem', entityId: 'inventory-global-id', expectedVersion: 1}}});
  assert.equal(validateWriteSet({writes: [immutable]}, 'admin', 'org_test').code, 'IMMUTABLE_RECORD');
});

test('non-finite quantities and rejected quantities above the original are refused', () => {
  for (const payload of [{quantity: 'NaN'}, {quantity: 'Infinity'}, {quantity: '-1'},
    {quantity: '2', rejectedQuantity: '2.1'}]) {
    const value = write({payload});
    assert.equal(validateAgainstCurrent(value, null, 'admin', [value]).code, 'VALUE_OUT_OF_RANGE');
  }
});

test('updating a quality decision requires its permission and matching history effect', () => {
  const value = write({operation: 'update', expectedVersion: 2,
    payload: {localId: 1, decisionStatus: 'FULL_REJECTION'}});
  const current = {version: 2, decisionStatus: 'APPROVED'};
  assert.equal(validateAgainstCurrent(value, current, 'lab', [value]).code, 'PERMISSION_DENIED');
  assert.equal(validateAgainstCurrent(value, current, 'admin', [value]).code, 'BAD_PAYLOAD');
  const history = write({entityType: 'qualityCheck', entityId: 'history-id', payload: {
    inspectionId: 1, oldStatus: 'APPROVED', newStatus: 'FULL_REJECTION'},
    relations: {inspectionId: {entityType: 'sample', entityId: value.entityId, expectedVersion: 2}}});
  assert.equal(validateAgainstCurrent(value, current, 'admin', [value, history]), null);
});

test('a raw SQLite parent id never replaces a missing global relationship', () => {
  const value = write({relations: {}, payload: {materialId: 1, decisionStatus: 'APPROVED'}});
  assert.equal(validateWriteSet({writes: [value]}, 'admin', 'org_test').code, 'PARENT_MISSING_OR_DELETED');
});
