'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {classify,decode}=require('../raw_material_plan');
const base={materialCode:'A', materialName:'Raw', physicalReferenceJson:'{}', chemicalReferenceJson:'{}', active:1, category:'x', unit:'kg'};
test('classifies duplicate equivalents without silently selecting one',()=>{
 assert.equal(classify({materialCode:'a'},[{...base,deviceId:'one'}, {...base,deviceId:'two'}]),'duplicate_equivalent');
});
test('different records require distinctive origin and never match local id across devices',()=>{
 const mats=[{...base,deviceId:'one',localId:2}, {...base,unit:'g',deviceId:'two',localId:2}];
 assert.equal(classify({materialCode:'A',deviceId:'two',materialId:2},mats),'different_unique_device_and_local_id');
 assert.equal(classify({materialCode:'A',materialId:2},mats),'different_unresolved');
 assert.equal(classify({materialCode:'Z'},mats),'missing_material');
});
test('decodes REST backup typed values without treating timestamps as null',()=>{
 assert.equal(decode({timestampValue:'2026-10-27T00:00:00Z'}),'2026-10-27T00:00:00Z');
 assert.equal(decode({nullValue:null}),null);
});
