'use strict';

// Read-only inspection of a Firestore REST backup. This never modifies either
// the backup or Firestore; ambiguous matches are reported, not selected.
const fs = require('fs');
const readline = require('readline');

function decode(value) {
  if (!value || 'nullValue' in value) return null;
  if ('stringValue' in value) return value.stringValue;
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return value.doubleValue;
  if ('booleanValue' in value) return value.booleanValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('arrayValue' in value) return (value.arrayValue.values || []).map(decode);
  if ('mapValue' in value) return Object.fromEntries(Object.entries(value.mapValue.fields || {}).map(([k,v]) => [k,decode(v)]));
  throw new Error('Unsupported Firestore value in backup');
}
function norm(v) { return String(v || '').trim().toLowerCase(); }
const identityFields = ['materialName','materialCode','physicalReferenceJson','chemicalReferenceJson','active','category','unit'];
function classify(sample, materials) {
  const code = norm(sample.materialCode);
  if (!code) return 'missing_code';
  const candidates = materials.filter(m => norm(m.materialCode) === code);
  if (candidates.length === 0) return 'missing_material';
  if (candidates.length === 1) return 'unique_code';
  const shapes = new Set(candidates.map(m => JSON.stringify(identityFields.map(k => m[k] ?? null))));
  if (shapes.size === 1) return 'duplicate_equivalent';
  const sameDevice = candidates.filter(m => sample.deviceId && m.deviceId === sample.deviceId);
  const sameLocalId = sameDevice.filter(m => m.localId != null && m.localId === sample.materialId);
  if (sameLocalId.length === 1) return 'different_unique_device_and_local_id';
  if (sameDevice.length === 1) return 'different_unique_device';
  return 'different_unresolved';
}
async function analyze(file, organizationId) {
  if (!/^[A-Za-z0-9_-]+$/.test(organizationId)) throw new Error('Invalid organization ID');
  const prefix = `/documents/organizations/${organizationId}/`;
  const materials = [], samples = [];
  const stream = readline.createInterface({input:fs.createReadStream(file),crlfDelay:Infinity});
  for await (const line of stream) {
    if (!line.trim()) continue;
    const doc = JSON.parse(line);
    if (typeof doc.name !== 'string' || !doc.name.includes(prefix)) continue;
    const tail = doc.name.split(prefix)[1].split('/');
    if (tail.length !== 2 || !['referenceMaterials','samples'].includes(tail[0])) continue;
    const data = Object.fromEntries(Object.entries(doc.fields || {}).map(([k,v]) => [k,decode(v)]));
    if (tail[0] === 'referenceMaterials' && data.deletedAt == null) materials.push(data);
    if (tail[0] === 'samples' && data.deletedAt == null) samples.push(data);
  }
  const categories = {};
  for (const sample of samples) {
    const result = classify(sample, materials);
    categories[result] = (categories[result] || 0) + 1;
  }
  return {organizationId, materials:materials.length, liveSamples:samples.length, categories,
    note:'Read-only evidence; duplicate or device matches require a reviewed migration and must not be treated as automatic approval.'};
}
if (require.main === module) {
  const [file, org] = process.argv.slice(2);
  if (!file || !org) { console.error('Usage: node raw_material_plan.js <documents.jsonl> <organizationId>'); process.exit(2); }
  analyze(file,org).then(result=>console.log(JSON.stringify(result,null,2))).catch(error=>{console.error(error.message);process.exitCode=1;});
}
module.exports = {classify,decode,analyze};
