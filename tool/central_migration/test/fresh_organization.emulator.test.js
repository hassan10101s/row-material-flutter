'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const project = 'demo-materiallab';
const host = process.env.FIRESTORE_EMULATOR_HOST;
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const enabled = host && authHost;
const stamp = () => ({fieldPath:'createdAt',setToServerValue:'REQUEST_TIME'});
function encode(v) {
  if (v === null) return {nullValue:null};
  if (v instanceof Date) return {timestampValue:v.toISOString()};
  if (Array.isArray(v)) return {arrayValue:{values:v.map(encode)}};
  if (typeof v === 'object') return {mapValue:{fields:Object.fromEntries(Object.entries(v).map(([k,x]) => [k,encode(x)]))}};
  if (typeof v === 'boolean') return {booleanValue:v};
  if (typeof v === 'number') return {integerValue:String(v)};
  return {stringValue:v};
}
test('fresh organization genesis is atomic, readable, and cannot reset an existing organization', {skip:!enabled}, async () => {
  const base = `http://${host}/v1/projects/${project}/databases/(default)/documents`;
  const suffix = Date.now() + '-' + Math.floor(Math.random()*1e6);
  const email = `fresh-${suffix}@example.test`;
  const password = 'TestPassword123!';
  async function auth(method, body, owner=false) {
    const r = await fetch(`http://${authHost}/identitytoolkit.googleapis.com/v1/${method}?key=fake`, {
      method:'POST',headers:{'Content-Type':'application/json',...(owner?{Authorization:'Bearer owner'}:{})},body:JSON.stringify(body),
    });
    const value = await r.json();
    assert.equal(r.status,200,JSON.stringify(value));
    return value;
  }
  const account = await auth('accounts:signUp',{email,password,returnSecureToken:true});
  await auth(`projects/${project}/accounts:update`,{localId:account.localId,emailVerified:true},true);
  const login = await auth('accounts:signInWithPassword',{email,password,returnSecureToken:true});
  const uid = login.localId;
  const headers = {'Content-Type':'application/json',Authorization:'Bearer '+login.idToken};
  const orgId = 'org_fresh_'+suffix;
  const memberId = 'founder';
  function write(path,data,timestamps=true) {
    return {update:{name:`projects/${project}/databases/(default)/documents/${path}`,
      fields:Object.fromEntries(Object.entries(data).map(([k,v])=>[k,encode(v)]))},
      currentDocument:{exists:false},
      ...(timestamps?{updateTransforms:[stamp(),{fieldPath:'updatedAt',setToServerValue:'REQUEST_TIME'}]}:{})};
  }
  function genesis(id) {
    const gate = {enabled:true,schemaVersion:3,domainManifestVersion:1,migrationId:'fresh_'+id,
      mode:'firestore_direct_v2',writePolicy:'multi_authorized',maintenance:false,globalReferencesReady:true,uniqueAdmissionComplete:true};
    const actor = {email,role:'admin',roles:['admin'],status:'active',displayName:'Founder',version:1,updatedBy:uid};
    return [
      write('organizations/'+id,{name:'Fresh test organization',ownerUid:uid,status:'active',schemaVersion:3,
        commandProtocol:gate,trialConsumed:true,manuallyActivated:false,createdBy:uid,updatedBy:uid,version:1}),
      write(`organizations/${id}/members/${memberId}`,{...actor,uid}),
      write('users/'+uid,{...actor,organizationId:id,memberId}),
      write(`organizations/${id}/counters/changeSequence`,{organizationId:id,value:0},false),
    ];
  }
  async function commit(writes) {
    const r = await fetch(base+':commit',{method:'POST',headers,body:JSON.stringify({writes})});
    return {status:r.status,body:await r.text()};
  }
  assert.equal((await commit(genesis(orgId).slice(0,3))).status,403,'missing counter must reject the whole genesis');
  let forged = genesis(orgId);
  forged[0].update.fields.commandProtocol.mapValue.fields.writePolicy = encode('single_writer');
  assert.equal((await commit(forged)).status,403,'forged gate must fail');
  forged = genesis(orgId);
  forged[2].update.fields.role = encode('trial_owner');
  forged[2].update.fields.roles = encode(['trial_owner']);
  assert.equal((await commit(forged)).status,403,'founder role must match the active-company genesis');
  forged = genesis(orgId);
  forged[0].update.fields.status = encode('trial');
  forged[0].update.fields.trialConsumed = encode(false);
  assert.equal((await commit(forged)).status,403,'clients cannot mint a trial company under the current policy');
  const result = await commit(genesis(orgId));
  assert.equal(result.status,200,result.body);
  const counter = await fetch(base+`/organizations/${orgId}/counters/changeSequence`,{headers});
  assert.equal(counter.status,200);
  assert.equal((await counter.json()).fields.value.integerValue,'0');
  const reset = genesis(orgId)[3];
  delete reset.currentDocument;
  assert.equal((await commit([reset])).status,403,'existing counter cannot use genesis');
  assert.equal((await commit(genesis(orgId+'_second'))).status,403,'bound account cannot mint a second company');
});
