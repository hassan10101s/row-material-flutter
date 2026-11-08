'use strict';
// Propose only provable global relationships. No identity ranking, inferred
// authorship, invented historical timestamps or automatic tombstones.
const fs=require('node:fs');
const {init,definition,entityTypes,listDocs,loadParentDocs,parentRemoteId}=require('./shared');
const {encode,decode,digest}=require('./typed_json');
async function planRepair(db,orgId) {
  const proposals=[],unresolved=[];
  for(const type of entityTypes()) {
    const d=definition(type);
    const parents=await loadParentDocs(db,orgId,[...new Set(d.parents.map(p=>p.type))]);
    for(const {id,data} of await listDocs(db,orgId,type)) {
      const after={...data}; const refs={...data.parentRefs}; let changed=false;
      for(const p of d.parents) {
        if(type==='sample'&&p.relation==='materialId'&&data.inspectionKind==='product') continue;
        const target=parentRemoteId(d,data,p,parents);
        if(target) {
          const parent=parents.get(`${p.type}/${target}`);
          const ref={entityType:p.type,entityId:target,version:parent.data().version};
          if(JSON.stringify(refs[p.relation])!==JSON.stringify(ref)) {refs[p.relation]=ref;changed=true;}
        } else if(p.required) unresolved.push({type,id,code:'UNRESOLVED_PARENT',relation:p.relation});
      }
      if(changed) {
        after.parentRefs=refs;
        proposals.push({type,id,beforeHash:digest(data),before:encode(data),after:encode(after),
          evidence:'Existing global reference or one exact business-identity match',reason:'',reviewedBy:''});
      }
      if(data.organizationId!==orgId) unresolved.push({type,id,code:'WRONG_ORG'});
      if(!data.createdAt||!data.updatedAt) unresolved.push({type,id,code:'MISSING_TIMESTAMPS'});
      if(!data.createdBy) unresolved.push({type,id,code:'MISSING_AUTHOR'});
    }
  }
  return {formatVersion:2,orgId,proposals,unresolved};
}
async function applyRepair(db,plan,orgId) {
  const {admin}=require('./shared');
  if(plan.formatVersion!==2||plan.orgId!==orgId) throw Error('Wrong reviewed plan');
  const root=db.doc(`organizations/${orgId}`);
  if((await root.get()).data()?.commandProtocol?.maintenance!==true) throw Error('Repairs require maintenance mode');
  for(const p of plan.proposals) {
    if(!p.reason?.trim()||!p.reviewedBy?.trim()) throw Error('Every repair requires an explicit reason and reviewer');
    const before=decode(p.before,db,admin),after=decode(p.after,db,admin);
    if(digest(before)!==p.beforeHash) throw Error('Invalid before hash');
    if(after.organizationId!==orgId||before.deletedAt!==after.deletedAt) throw Error('Deletion and organization reassignment are not permitted by this repair tool');
  }
  let applied=0;
  for(const p of plan.proposals) {
    const ref=root.collection(definition(p.type).collection).doc(p.id);
    await db.runTransaction(async tx=>{
      const snap=await tx.get(ref);
      if(!snap.exists||digest(snap.data())!==p.beforeHash) throw Error(`Precondition changed: ${ref.path}`);
      const after=decode(p.after,db,admin);
      tx.set(ref,after);
      tx.create(root.collection('migrationRepairs').doc(),{path:ref.path,beforeHash:p.beforeHash,
        afterHash:digest(after),reason:p.reason,reviewedBy:p.reviewedBy,at:admin.firestore.FieldValue.serverTimestamp()});
    });
    applied++;
  }
  return {applied,maintenance:true};
}
async function main() {
  const args=require('./cli_args').parse();
  if(typeof args.org!=='string') throw Error('Usage: repair.js --org ID --out FILE [--apply --reviewed FILE] --project PROJECT');
  const {db,admin}=init(args.project);
  try {
    if(args.apply) {
      if(typeof args.reviewed!=='string') throw Error('--apply requires --reviewed FILE; automatic repair is disabled');
      console.log(JSON.stringify(await applyRepair(db,JSON.parse(fs.readFileSync(args.reviewed,'utf8')),args.org),null,2));
    } else {
      const plan=await planRepair(db,args.org);
      if(args.out) fs.writeFileSync(args.out,JSON.stringify(plan,null,2),{flag:'wx'});
      console.log(JSON.stringify({proposals:plan.proposals.length,unresolved:plan.unresolved.length,applied:false},null,2));
    }
  } finally {await admin.app().delete();}
}
if(require.main===module) main().catch(e=>{console.error(e.message);process.exitCode=1;});
module.exports={planRepair,applyRepair};
