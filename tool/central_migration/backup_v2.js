'use strict';
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {encode,digest}=require('./typed_json');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
async function backupOrganization(db,orgId,outDir) {
  if(!/^[^/]+$/.test(orgId)) throw Error('Invalid organization');
  fs.mkdirSync(outDir,{recursive:true});
  if(fs.existsSync(path.join(outDir,'restore-report.json'))) throw Error('Backup destination already contains a report; choose a new directory');
  const root=db.doc(`organizations/${orgId}`);
  const before=await root.get();
  if(!before.exists) throw Error('Organization not found');
  const report={formatVersion:2,organizationId:orgId,projectId:db.projectId,
    backedUpAt:new Date().toISOString(),frozen:before.data().commandProtocol?.maintenance===true,
    files:{},total:0};
  let index=0;
  const write=async(name,docs)=>{
    const filename=`${String(index++).padStart(4,'0')}.jsonl`;
    const rows=docs.map(doc=>({path:doc.ref.path,id:doc.id,
      updateTime:encode(doc.updateTime),data:encode(doc.data()),contentHash:digest(doc.data())}));
    const bytes=Buffer.from(rows.map(row=>JSON.stringify(row)+'\n').join(''));
    fs.writeFileSync(path.join(outDir,filename),bytes,{flag:'wx'});
    report.files[name]={file:filename,docs:docs.length,sha256:sha(bytes)};
    report.total+=docs.length;
  };
  const walk=async ref=>{
    for(const collection of await ref.listCollections()) {
      // listDocuments also returns missing parent documents that have live
      // subcollections (notably syncReceipts/{uid}/entries).
      const refs=await collection.listDocuments();
      const docs=[];
      for(let i=0;i<refs.length;i+=100) docs.push(...await db.getAll(...refs.slice(i,i+100)));
      await write(collection.path,docs.filter(doc=>doc.exists));
      for(const child of refs) await walk(child);
    }
  };
  await write('organization',[before]);
  await walk(root);
  const profiles=await db.collection('users').where('organizationId','==',orgId).get();
  await write('rootUsers',profiles.docs);
  for(const doc of profiles.docs) await walk(doc.ref);
  const after=await root.get();
  if(!after.exists || !before.updateTime.isEqual(after.updateTime)) throw Error('Organization changed during export; discard this incomplete backup');
  const reportFile=path.join(outDir,'restore-report.json');
  fs.writeFileSync(reportFile,JSON.stringify(report,null,2),{flag:'wx'});
  return {report,reportFile};
}
async function main() {
  const args=require('./cli_args').parse();
  if(!args.org || !args.out) throw Error('Usage: backup.js --org ID --out NEW_DIRECTORY --project PROJECT');
  const {db,admin}=require('./shared').init(args.project);
  try { console.log(JSON.stringify((await backupOrganization(db,args.org,args.out)).report,null,2)); }
  finally {await admin.app().delete();}
}
module.exports={backupOrganization,main};
