'use strict';
// This proves migration and restoration only. Runtime rules and Flutter reader
// are verified separately by test/security/firestore_direct_sync_test.dart.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
if(!process.env.FIRESTORE_EMULATOR_HOST) throw Error('Run proof.js under the demo-materiallab emulator');
const {init}=require('./shared');
const {auditOrganization}=require('./audit');
const {backupOrganization}=require('./backup');
const {restoreBackup}=require('./restore');
const {migrate,readState}=require('./migrate');
const {db,admin}=init('demo-materiallab');
const org=`migration-proof-${process.pid}`,uid=`migration-user-${process.pid}`;
const root=db.doc(`organizations/${org}`),profile=db.doc(`users/${uid}`);
async function main(){
  const now=admin.firestore.Timestamp.now();
  await root.set({status:'active',name:'Migration proof',ownerUid:uid,commandProtocol:{maintenance:true}});
  await profile.set({organizationId:org,status:'active',role:'admin'});
  await root.collection('devices').doc('writer').set({uid,status:'active',readOnly:false});
  await root.collection('referenceMaterials').doc('legacy-material').set({organizationId:org,
    version:1,materialName:'Legacy material',materialCode:'LM-1',createdBy:uid,createdAt:now,
    updatedAt:now,updatedBy:uid,deviceId:'writer',remoteId:'legacy-material',localId:1,
    deletedAt:null,physicalReferenceJson:'{}',chemicalReferenceJson:'{}',active:1,importedAt:'2026-10-27'});
  const payload=require('../../test/fixtures/domain_wire_vectors.json').inspection.payload.writes[0].payload;
  await root.collection('samples').doc('legacy-sample').set({...payload,
    organizationId:org,version:1,entryCode:'S-1',materialCode:'LM-1',materialName:'Legacy material',
    materialId:1,createdBy:uid,createdAt:now,updatedAt:now,updatedBy:uid,deviceId:'writer',
    remoteId:'legacy-sample',localId:1,deletedAt:null});
  const audit=await auditOrganization(db,org);assert.equal(audit.blockerCount,0);
  const beforeDir=fs.mkdtempSync(path.join(os.tmpdir(),'materiallab-before-'));
  const before=await backupOrganization(db,org,beforeDir);
  assert.equal(before.report.frozen,true);assert.equal(before.report.files.rootUsers.docs,1);
  await assert.rejects(()=>migrate(db,org,{stage:'gate',migrationId:'unsafe'}),/Complete audit/);
  const first=await migrate(db,org,{migrationId:'proof-v3'});
  const gate=(await root.get()).data().commandProtocol;
  assert.equal(gate.schemaVersion,3);assert.equal(gate.mode,'firestore_direct_v2');
  assert.equal(gate.writePolicy,'multi_authorized');assert.equal(gate.maintenance,false);
  assert.equal((await root.collection('samples').doc('legacy-sample').get()).data().parentRefs.materialId.entityId,'legacy-material');
  const again=await migrate(db,org,{migrationId:'proof-v3'});
  assert.equal(again.parentRefs.documentsUpdated,0);
  assert.equal((await root.collection('samples').doc('legacy-sample').get()).data().version,1);
  await migrate(db,org,{abort:true,abortReason:'Proof maintenance rollback'});
  assert.equal((await root.get()).data().commandProtocol.maintenance,true);
  assert.equal((await root.get()).data().commandProtocol.enabled,true);
  assert.equal((await readState(root)).stage,'aborted');
  const blocked=await restoreBackup(db,admin,beforeDir,{apply:true});
  assert.equal(blocked.blocked,true,'New migration metadata cannot be silently overwritten');
  const afterDir=fs.mkdtempSync(path.join(os.tmpdir(),'materiallab-after-'));
  const after=await backupOrganization(db,org,afterDir);
  await db.recursiveDelete(root);await profile.delete();
  const restored=await restoreBackup(db,admin,afterDir,{apply:true});
  assert.equal(restored.applied,true);assert.equal(restored.maintenance,true);
  assert.equal((await auditOrganization(db,org)).blockerCount,0);
  console.log(JSON.stringify({ok:true,org,migrated:first.stages,restored:restored.verified,
    backupDocuments:after.report.total,maintenance:true},null,2));
}
main().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{
  await db.recursiveDelete(root);await profile.delete();await admin.app().delete();
});
