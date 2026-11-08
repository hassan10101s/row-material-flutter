'use strict';
const crypto=require('node:crypto');
const manifest=require('./domain_manifest.json');
function directUniqueClaims(type,id,doc,refs={}) {
  const d=manifest.entities[type];
  if(!d) throw Error(`Unknown type: ${type}`);
  let nested=doc.payload;
  if(typeof nested==='string') nested=JSON.parse(nested);
  return d.unique.flatMap((u,i)=>{
    if(u.collations.some(c=>c!=='BINARY')) throw Error('Unsupported unique collation');
    if(u.where && !/^deleted_at\s+IS\s+NULL$/i.test(u.where)) throw Error('Unsupported predicate');
    if(u.where && doc.deletedAt!=null) return [];
    const values=u.fields.map((f,j)=>refs[f] ? `${refs[f].entityType}/${refs[f].entityId}`
      : doc[f] ?? nested?.[u.columns[j]] ?? null);
    if(values.includes(null)) return [];
    const wire=`u2|${type}|${i}|`+values.map(v=>`${Buffer.byteLength(String(v),'utf8')}:${v}`).join('');
    return [{key:crypto.createHash('sha256').update(wire).digest('hex'),entityType:type,entityId:id}];
  });
}
module.exports={directUniqueClaims};
