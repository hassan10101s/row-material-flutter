'use strict';
// Direct rules contract, verified by the normal-user emulator suite. The CLI
// emits review candidates under build/; generate_rules.js owns the final file.
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'../..');
const manifest=require('./domain_manifest.json');
const targets=Object.fromEntries([...fs.readFileSync(path.join(root,'lib/core/commands/qc_audit_contract.dart'),'utf8').matchAll(/'([^']+)':\s*'([^']+)'/g)].map(m=>[m[1],m[2]]));
const source=fs.readFileSync(path.join(root,'lib/features/qc_manager/data/server_confirmed_qc_repository.dart'),'utf8').split('abstract final class QcAuditAction {')[1].split('\n}')[0];
const actions=[...source.matchAll(/static const String \w+ = '([^']+)'/g)].map(m=>m[1]);
const columns=['action','after_json','at','before_json','by_user_id','by_user_name','entity_id','entity_type','meta_json','prev_hash'];
const camel=s=>s.replace(/_([a-z])/g,(_,c)=>c.toUpperCase());
const literal=v=>JSON.stringify(v).replaceAll('"',"'");
function functions() {
  const jsonQuote = JSON.stringify('"');
  const slashPattern = JSON.stringify(String.raw`\\`);
  const slashReplacement = JSON.stringify(String.raw`\\\\`);
  const quoteReplacement = JSON.stringify(String.raw`\\`+'"');
  return `function auditQuoted(v) { return ${jsonQuote} + v.replace(${slashPattern}, ${slashReplacement}).replace(${jsonQuote}, ${quoteReplacement}) + ${jsonQuote}; }\n` + String.raw`
    function auditTextValid(v) { return v is string && v.matches('^[^\\x00-\\x1f]*$'); }
  `+`
    function qcOperationAudited(orgId, d) {
      let path = /databases/$(database)/documents/organizations/$(orgId)/qcAudits/$(d.protocol.qcAuditId);
      return d.protocol.qcAuditPath == path && getAfter(path).data.protocol.operationId == d.protocol.operationId;
    }
    function qcInspectionDecision(d) {
      let old = resource == null ? '' : resource.data.status;
      return d.status in ['InProgress','Submitted','Reviewed','Approved','Rejected','Closed']
        && ((d.status in ['Approved','Closed'] || old in ['Approved','Closed']
          || !(d.get('approvedBy',null) in [null,'']) || !(d.get('approvedAt',null) in [null,'']) || !(d.get('closedAt',null) in [null,'']))
          ? roleCan('qc.approve') : true)
        && ((d.status == 'Rejected' || old == 'Rejected' || !(d.get('rejectedAt',null) in [null,''])) ? roleCan('qc.reject') : true)
        && (d.get('approvedBy',null) in [null,''] || d.approvedBy == request.auth.uid
          || (resource != null && d.approvedBy == resource.data.approvedBy))
        && (d.get('scorePct',null) == null || (d.scorePct >= 0 && d.scorePct <= 100));
    }
    function qcAuditLinked(orgId, d) {
      let kinds = ${literal(targets)};
      let collections = ${literal(Object.fromEntries(Object.entries(targets).map(([k,t])=>[k,manifest.entities[t].collection])))};
      let targetPath = /databases/$(database)/documents/organizations/$(orgId)/$(collections.get(d.entityType,''))/$(d.targetGlobalId);
      let target = getAfter(targetPath);
      let previous = d.previousAuditId == null ? null : getAfter(/databases/$(database)/documents/organizations/$(orgId)/qcAudits/$(d.previousAuditId));
      let canonical = '{' + ${columns.map((c,i)=>`'${(i?',':'')}"${c}":' + auditQuoted(d.${camel(c)})`).join(' + ')} + '}';
      return d.byUserId == request.auth.uid && d.immutable == 1
        && d.action in ${literal(actions)}
        && d.targetEntityType == kinds.get(d.entityType, '')
        && d.protocol.auditTargetPath == targetPath
        && target.data.protocol.operationId == d.protocol.operationId
        && target.data.updatedAt == request.time
        && ${columns.map(c=>`auditTextValid(d.${camel(c)})`).join(' && ')}
        && d.hash == hashing.sha256(canonical.toUtf8()).toHexString().lower()
        && (d.prevHash == '' ? d.previousAuditId == null :
          (previous != null && previous.data.hash == d.prevHash
            && (previous.data.protocol.operationId != d.protocol.operationId
              || previous.data.protocol.auditOrdinal < d.protocol.auditOrdinal)));
    }
  `;
}
function candidate(rules) {
  // `can` and the fresh receipt both validate the role set. Canonical admins
  // already possess every declared permission; keep additive roles unchanged.
  // The profile lookup is null-safe: an unbound account (no `users/{uid}`
  // document yet, e.g. during genesis) must evaluate to a clean `false`
  // instead of an evaluation error that poisons sibling statements.
  if (!rules.includes('function roleCanRoles(perm, data) {')) {
    rules=rules.replace('function roleCan(perm) {',"function roleCan(perm) {\n      let doc = userDoc(request.auth.uid);\n      return doc != null\n        && (doc.data.role == 'admin' || roleCanRoles(perm, doc.data));\n    }\n    function roleCanRoles(perm, data) {");
  }
  const limit=require('./release_limits.json').maxBusinessEffects;
  rules=rules.replace(/(request\.resource\.data\.recordPaths\.size\(\) <= )\d+/g, `$1${limit}`);
  const marker='// BEGIN GENERATED DIRECT DOMAIN RULES (generate_rules.js)';
  rules=rules.replace(marker,()=>marker+'\n'+functions());
  // The nine-column extension proves table definitions, not larger inventory
  // balance operations. Keep their separately verified lookup bound intact.
  const inventoryLimit = 4;
  const sum=(field,fn)=>Array.from({length:inventoryLimit},(_,i)=>`(d.protocol.${field}.size() > ${i} ? ${fn}(orgId, d, d.protocol.${field}[${i}]) : 0)`).join(' + ');
  rules=rules.replace(/function inventoryBalance\(orgId, d\) \{[\s\S]*?\n    \}/,`function inventoryBalance(orgId, d) {
      let before = resource == null ? 0 : resource.data.currentQty;
      let compact = d.protocol.get('ledgerMode', '') == 'consumption_v1';
      let delta = compact ? consumptionDelta(d, 0) + consumptionDelta(d, 1) + consumptionDelta(d, 2) + consumptionDelta(d, 3) : ${sum('ledgerPaths','ledgerDeltaAt')};
      let lots = compact ? 0 : ${sum('lotPaths','lotDeltaAt')};
      let consumed = d.protocol.get('consumptionPaths', []);
      return d.currentQty is number && d.currentQty >= 0 && d.currentQty < 1000000000000000
        && d.protocol.ledgerPaths.size() <= ${inventoryLimit} && d.protocol.ledgerPaths.toSet().size() == d.protocol.ledgerPaths.size()
        && d.protocol.lotPaths.size() <= ${inventoryLimit} && d.protocol.lotPaths.toSet().size() == d.protocol.lotPaths.size()
        && consumed is list && consumed.size() <= ${inventoryLimit} && consumed.toSet().size() == consumed.size()
        && (!compact || (consumed.size() > 0 && d.protocol.ledgerPaths.size() == 0))
        && (compact || math.abs(lots - delta) <= 0.00000001 * (math.abs(delta) > 1 ? math.abs(delta) : 1))
        && math.abs(d.currentQty - before - delta) <= 0.00000001 * (math.abs(before) > math.abs(d.currentQty) ? (math.abs(before) > 1 ? math.abs(before) : 1) : (math.abs(d.currentQty) > 1 ? math.abs(d.currentQty) : 1));
    }
    function ledgerDeltaAt(orgId, d, path) {
      let ledger = getAfter(path);
      return ledger != null && ledger.data.protocol.entityType == 'inventoryTransaction'
        && ledger.data.protocol.operationId == d.protocol.operationId
        && ledger.data.parentRefs.inventoryId.entityId == d.remoteId
        && ledger.data.organizationId == orgId && ledger.data.updatedAt == request.time
        ? ledger.data.quantityDelta : 1000000000000000000;
    }
    function lotDeltaAt(orgId, d, path) {
      let after = getAfter(path);
      let before = get(path);
      return after != null && after.data.organizationId == orgId
        && after.data.protocol.entityType == 'inventoryLot'
        && after.data.parentRefs.inventoryId.entityId == d.remoteId
        && after.data.protocol.operationId == d.protocol.operationId && after.data.updatedAt == request.time
        ? after.data.qtyRemaining - (before == null ? 0 : before.data.qtyRemaining) : 1000000000000000000;
    }`);
  for(const type of [...Object.values(targets),'qcTaskLog','qcAudit']) {
    const check=type==='qcAudit'?'qcAuditLinked':'qcOperationAudited';
    const re=new RegExp(`(function shape_${type}\\(orgId, d\\) \\{[\\s\\S]*?)(;\\n    \\})`);
    if(!re.test(rules)) throw Error(`Missing shape: ${type}`);
    rules=rules.replace(re,(_,part,last)=>part+`\n        && ${check}(orgId, d)`+
      (type==='qcInspection'?'\n        && qcInspectionDecision(d)':'')+last);
  }
  const re=/(match \/qcAudits\/\{docId\} \{)([\s\S]*?)(\n      \})/;
  if(!re.test(rules)) throw Error('Missing QC audit collection');
  return rules.replace(re,(_,head,body,end)=>{
    const closed='allow create, update, delete: if false;';
    const approved="allow create: if roleCan('qc.write') && hasEnvelope(orgId) && directShape();\n        allow update, delete: if false;";
    if(body.includes(closed)) body=body.replace(closed,approved);
    else if(!body.includes(approved)) throw Error('Unexpected QC audit permission branch');
    return head+body+end;
  });
}
if(require.main===module) {
  const output=path.resolve(process.argv[2]||'');
  if(!output.startsWith(path.join(root,'build')+path.sep)||!output.endsWith('.rules')) throw Error('Candidate output must be a .rules file under workspace/build');
  fs.writeFileSync(output,candidate(fs.readFileSync(path.join(root,'firestore.rules'),'utf8')));
}
module.exports={functions,candidate,targets};
