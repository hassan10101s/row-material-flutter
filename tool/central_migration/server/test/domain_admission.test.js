const test = require('node:test');
const assert = require('node:assert/strict');
const {uniqueClaims, validateRelations, validateInventoryEffects} = require('../domain_admission');

test('a composite unique claim uses global references across different local row numbers', () => {
  const refs = {batchId: {entityType: 'sample', entityId: 'the-same-batch', expectedVersion: 3}};
  const left = uniqueClaims('productBatchSample', 'a', {batchId: 1, sampleNo: 2}, refs);
  const right = uniqueClaims('productBatchSample', 'b', {batchId: 91, sampleNo: 2}, refs);
  assert.equal(left[0].key, right[0].key);
});

test('a numeric origin id does not make a stale parent version current', () => {
  const write = {entityType: 'productBatchSample', entityId: 'sample', operation: 'create',
    payload: {batchId: 1}, relations: {batchId: {entityType: 'sample', entityId: 'batch', expectedVersion: 2}}};
  const parent = {organizationId: 'org', version: 3, inspectionKind: 'product'};
  assert.equal(validateRelations([{write, current: null}], new Map([['sample/batch', parent]]), 'org').code, 'VERSION_CONFLICT');
});

test('an operational sample cannot point at a raw-material inspection', () => {
  const write = {entityType: 'productBatchSample', entityId: 'sample', operation: 'create',
    payload: {}, relations: {batchId: {entityType: 'sample', entityId: 'batch', expectedVersion: 2}}};
  assert.equal(validateRelations([{write, current: null}], new Map([['sample/batch', {
    organizationId: 'org', version: 2, inspectionKind: 'raw',
  }]]), 'org').code, 'PARENT_WRONG_TYPE');
});

test('opening stock and every later quantity change must match their ledger effects', () => {
  const item = {write: {entityType: 'inventoryItem', entityId: 'inventory', operation: 'create', payload: {currentQty: 10}}, current: null};
  const movement = {write: {entityType: 'inventoryTransaction', entityId: 'movement', operation: 'create',
    payload: {quantityDelta: 10}, relations: {inventoryId: {entityType: 'inventoryItem', entityId: 'inventory'}}}, current: null};
  assert.equal(validateInventoryEffects([item]).code, 'VALUE_OUT_OF_RANGE');
  assert.equal(validateInventoryEffects([item, movement]), null);
  assert.equal(validateInventoryEffects([movement]).code, 'BAD_PAYLOAD');
  assert.equal(validateInventoryEffects([{...item, current: {currentQty: 20}}, movement]).code, 'VALUE_OUT_OF_RANGE');
});
