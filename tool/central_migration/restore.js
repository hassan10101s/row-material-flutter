'use strict';
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {decode,digest}=require('./typed_json');
function loadBackup(directory,db,admin) {
  const report=JSON.parse(fs.readFileSync(path.join(directory,'restore-report.json'),'utf8'));
  if(report.formatVersion!==2) throw Error('Only typed formatVersion 2 backups can be restored');
  const prefix=`organizations/${report.organizationId}`;
  const rows=[];
  const seen=new Set();
  for(const file of Object.values(report.files)) {
    if(path.basename(file.file)!==file.file) throw Error('Unsafe backup filename');
    const bytes=fs.readFileSync(path.join(directory,file.file));
    if(crypto.createHash('sha256').update(bytes).digest('hex')!==file.sha256) throw Error(`Checksum mismatch: ${file.file}`);
    const lines=bytes.toString('utf8').split('\n').filter(Boolean);
    if(lines.length!==file.docs) throw Error('Backup count mismatch');
    for(const line of lines) {
      const row=JSON.parse(line);
      if(typeof row.path!=='string' || seen.has(row.path)) throw Error('Invalid/duplicate backup path');
      const data=decode(row.data,db,admin);
      const orgPath=row.path===prefix || row.path.startsWith(prefix+'/');
      const userPath=/^users\/[^/]+$/.test(row.path)&&data.organizationId===report.organizationId;
      const userChild=/^users\/[^/]+\//.test(row.path);
      if(!orgPath&&!userPath&&!userChild) throw Error(`Out of scope: ${row.path}`);
      if(digest(data)!==row.contentHash) throw Error(`Content hash mismatch: ${row.path}`);
      seen.add(row.path);rows.push({...row,decoded:data});
    }
  }
  const rootUsers=new Set(rows.filter(r=>/^users\/[^/]+$/.test(r.path)).map(r=>r.path));
  if(rows.some(r=>r.path.startsWith('users/')&&!rootUsers.has(r.path.split('/').slice(0,2).join('/')))) throw Error('Unowned root-user subtree');
  if(rows.length!==report.total) throw Error('Total backup count mismatch');
  return {report,rows};
}
async function restoreBackup(db,admin,directory,{apply=false}={}) {
  const {report,rows}=loadBackup(directory,db,admin);
  const root=db.doc(`organizations/${report.organizationId}`);
  const current=await root.get();
  if(apply && current.exists && current.data().commandProtocol?.maintenance!==true) throw Error('Restore requires maintenance mode');
  if(apply && !report.frozen && !process.env.FIRESTORE_EMULATOR_HOST) throw Error('A live restore requires a frozen backup');
  const newer=[];
  for(const row of rows) {
    const snap=await db.doc(row.path).get();
    // Any different surviving content requires reconciliation, regardless of
    // clock precision or whether it changed during the export window.
    if(snap.exists && digest(snap.data())!==row.contentHash) newer.push(row.path);
  }
  if(newer.length) return {applied:false,blocked:true,newerDocuments:newer};
  const expected=new Set(rows.map(r=>r.path));
  const extra=[];
  async function scan(ref) {
    for(const collection of await ref.listCollections()) {
      for(const child of await collection.listDocuments()) {
        const doc=await child.get();
        if(doc.exists&&!expected.has(child.path)) extra.push(child.path);
        await scan(child);
      }
    }
  }
  await scan(root);
  const currentUsers = await db.collection('users').where('organizationId','==',report.organizationId).get();
  for (const profile of currentUsers.docs) {
    if (!expected.has(profile.ref.path)) extra.push(profile.ref.path);
  }
  for(const row of rows.filter(r=>/^users\/[^/]+$/.test(r.path))) await scan(db.doc(row.path));
  if(extra.length) return {applied:false,blocked:true,extraDocuments:extra};
  if(!apply) return {applied:false,blocked:false,documents:rows.length,organizationId:report.organizationId};
  // Keep the target frozen throughout partial batches, verification and handoff.
  await root.set({commandProtocol:{maintenance:true}}, {merge:true});
  const contents=rows.filter(r=>r.path!==root.path);
  for(let i=0;i<contents.length;i+=400) {
    const batch=db.batch();
    for(const row of contents.slice(i,i+400)) batch.set(db.doc(row.path),row.decoded);
    await batch.commit();
  }
  const rootRow=rows.find(r=>r.path===root.path);
  if(!rootRow) throw Error('Backup has no organization root');
  await root.set({...rootRow.decoded,commandProtocol:{...rootRow.decoded.commandProtocol,maintenance:true}});
  const mismatches=[];
  const restoredRoot = await root.get();
  const expectedRoot = {...rootRow.decoded,commandProtocol:{...rootRow.decoded.commandProtocol,maintenance:true}};
  if (!restoredRoot.exists || digest(restoredRoot.data()) !== digest(expectedRoot)) mismatches.push(root.path);
  for(const row of contents) {
    const snap=await db.doc(row.path).get();
    if(!snap.exists||digest(snap.data())!==row.contentHash) mismatches.push(row.path);
  }
  if(mismatches.length) throw Error(`Restore verification failed: ${mismatches.join(', ')}`);
  return {applied:true,verified:contents.length,maintenance:true};
}
async function main() {
  const args=require('./cli_args').parse();
  if(!args.from) throw Error('Usage: restore.js --from BACKUP_DIRECTORY --project PROJECT [--apply]');
  const {db,admin}=require('./shared').init(args.project);
  try {
    const result=await restoreBackup(db,admin,args.from,{apply:args.apply===true});
    console.log(JSON.stringify(result,null,2));
    if(result.blocked) process.exitCode=2;
  } finally {await admin.app().delete();}
}
if(require.main===module) main().catch(e=>{console.error(e.message);process.exitCode=1;});
module.exports={loadBackup,restoreBackup};
