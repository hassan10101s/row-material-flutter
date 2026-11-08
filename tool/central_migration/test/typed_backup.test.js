'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {encode,decode,digest}=require('../typed_json');
const {admin}=require('../shared');
test('typed exports preserve timestamps, bytes, references and user maps without tag collisions',()=>{
  const db={doc: p=>({path:p,firestore:true})};
  const original={timestamp:new admin.firestore.Timestamp(123,987654321), bytes:Buffer.from([0,255,42]),
    reference:db.doc('organizations/example/samples/id'),point:new admin.firestore.GeoPoint(30,31),
    userMap:{$type:'timestamp',values:[null,true,'عربي 🧪',1.25]}, nan:NaN, infinity:Infinity};
  const restored=decode(JSON.parse(JSON.stringify(encode(original))),db,admin);
  assert.equal(digest(restored),digest(original));
  assert.equal(restored.timestamp.nanoseconds,987654321);
  assert.deepEqual(restored.bytes,original.bytes);
  assert.equal(restored.userMap.$type,'timestamp');
});
test('reference serialization preserves a different project and database',()=>{
  const foreign = new admin.firestore.Firestore({projectId:'demo-original',databaseId:'archive'});
  const target = new admin.firestore.Firestore({projectId:'demo-target'});
  const original = foreign.doc('organizations/org/samples/sample');
  const restored = decode(JSON.parse(JSON.stringify(encode(original))),target,admin);
  assert.equal(restored.firestore.projectId,'demo-original');
  assert.equal(restored.firestore.databaseId,'archive');
  assert.equal(digest(restored),digest(original));
});
test('backup and restore include root profiles, nested receipts and verify content',{
  skip:!process.env.FIRESTORE_EMULATOR_HOST,
},async()=>{
  const {db,admin}=require('../shared').init('demo-materiallab');
  const org=`backup-proof-${process.pid}`;
  const root=db.doc(`organizations/${org}`),user=db.doc(`users/${org}`);
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'materiallab-backup-'));
  try {
    await root.set({name:'Proof',commandProtocol:{maintenance:true}});
    await user.set({organizationId:org,status:'active'});
    await root.collection('commandReceipts').doc('receipt').set({at:new admin.firestore.Timestamp(123,456000),bytes:Buffer.from([1,2]),ref:user});
    await root.collection('syncReceipts').doc('actor').collection('entries').doc('nested').set({version:1});
    const {report}=await require('../backup').backupOrganization(db,org,directory);
    assert.equal(report.frozen,true);
    assert.equal(report.files.rootUsers.docs,1);
    await db.recursiveDelete(root); await user.delete();
    const result=await require('../restore').restoreBackup(db,admin,directory,{apply:true});
    assert.equal(result.applied,true);
    assert.equal((await root.get()).data().commandProtocol.maintenance,true);
    assert.equal((await user.get()).data().organizationId,org);
    const receipt=(await root.collection('commandReceipts').doc('receipt').get()).data();
    assert.equal(receipt.at.nanoseconds,456000);
    assert.equal(receipt.ref.path,user.path);
    assert.equal((await root.collection('syncReceipts').doc('actor').collection('entries').doc('nested').get()).data().version,1);
    await root.collection('newAfterBackup').doc('new').set({important:true});
    const blocked=await require('../restore').restoreBackup(db,admin,directory,{apply:true});
    assert.equal(blocked.blocked,true);
    assert.ok(blocked.extraDocuments.length>0);
  } finally {await db.recursiveDelete(root);await user.delete();await admin.app().delete();if(path.dirname(path.resolve(directory))!==path.resolve(os.tmpdir())||!path.basename(directory).startsWith('materiallab-backup-')) throw Error('Unsafe temporary directory');fs.rmSync(directory,{recursive:true,force:true});}
});
