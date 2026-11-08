'use strict';
const crypto = require('node:crypto');
// Every value has an explicit tag; a user map can never masquerade as a type.
function encode(value) {
  if (value === null) return ['null'];
  if (typeof value === 'string' || typeof value === 'boolean') return [typeof value, value];
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return ['number', String(value)];
    return ['number', Object.is(value,-0)?0:value];
  }
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) return ['bytes',Buffer.from(value).toString('base64')];
  if (value instanceof Date) return ['date',value.toISOString()];
  if (value && typeof value.toDate==='function' && Number.isInteger(value.seconds)) {
    return ['timestamp',value.seconds,value.nanoseconds];
  }
  if (value && typeof value.path==='string' && value.firestore) {
    return typeof value.firestore.projectId === 'string'
      ? ['reference',value.path,value.firestore.projectId,value.firestore.databaseId || '(default)']
      : ['reference',value.path];
  }
  if (value && typeof value.latitude==='number' && typeof value.longitude==='number') return ['geopoint',value.latitude,value.longitude];
  if (Array.isArray(value)) return ['array',value.map(encode)];
  if (value && Object.getPrototypeOf(value)===Object.prototype) {
    return ['map',Object.keys(value).sort().map(k=>[k,encode(value[k])])];
  }
  throw new Error(`Unsupported export value: ${value?.constructor?.name || typeof value}`);
}
function decode(value,db,admin) {
  if (!Array.isArray(value)) throw Error('Invalid typed value');
  const [kind,data,extra]=value;
  switch(kind) {
    case 'null': return null;
    case 'string': case 'boolean': return data;
    case 'number': return typeof data==='number'?data:Number(data);
    case 'date': return new Date(data);
    case 'bytes': return Buffer.from(data,'base64');
    case 'timestamp': return new admin.firestore.Timestamp(data,extra);
    case 'reference': {
      if (!extra || (extra === db.projectId && (value[3] || '(default)') === (db.databaseId || '(default)'))) return db.doc(data);
      // Constructing a reference performs no remote read or write. Preserve
      // the original project/database rather than silently rebasing it.
      const foreign = new admin.firestore.Firestore({projectId: extra, databaseId: value[3] || '(default)'});
      return foreign.doc(data);
    }
    case 'geopoint': return new admin.firestore.GeoPoint(data,extra);
    case 'array': return data.map(v=>decode(v,db,admin));
    case 'map': return Object.fromEntries(data.map(([k,v])=>[k,decode(v,db,admin)]));
    default: throw Error(`Unknown export type: ${kind}`);
  }
}
const digest = value => crypto.createHash('sha256').update(JSON.stringify(encode(value))).digest('hex');
module.exports={encode,decode,digest};
