'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {parentRemoteId} = require('../shared');

const parent = {type: 'referenceMaterial', localField: 'material_id', relation: 'materialId'};
const sample = {table: 'inspections', collection: 'samples'};
const doc = (materialCode, materialName = 'Material') => ({
  exists: true, data: () => ({materialCode, materialName}),
});

test('legacy raw receipt matches one server material by code, never by local id', () => {
  const materials = new Map([['referenceMaterial/global-a', doc('MAT-A')]]);
  assert.equal(parentRemoteId(sample, {materialId: 77, materialCode: 'mat-a'}, parent, materials), 'global-a');
  assert.equal(parentRemoteId(sample, {materialId: 77, materialCode: 'wrong'}, parent, materials), null);
  assert.equal(parentRemoteId(sample, {materialRemoteId: 'missing'}, parent, materials), null);
  materials.set('referenceMaterial/global-b', doc('MAT-A'));
  assert.equal(parentRemoteId(sample, {materialCode: 'MAT-A'}, parent, materials), null);
});

test('legacy lab config parent stamps are read from snake-case nested payload', () => {
  const def = {collection: 'labConfig', table: 'lab_material_analyses'};
  const materials = new Map([['referenceMaterial/global-a', doc('MAT-A')]]);
  assert.equal(parentRemoteId(def, {payload: '{"material_remote_id":"global-a"}'}, parent, materials), 'global-a');
});
