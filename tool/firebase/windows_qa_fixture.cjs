'use strict';

// Explicitly authorized acceptance fixtures. Every write is confined to a new
// qa_win_* organization and qa_win_* Auth/profile identities. Never targets
// the existing organization; credentials are saved only in ignored ven/.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const admin = require(path.join(root, 'tool/central_migration/server/node_modules/firebase-admin'));
const secretPath = path.join(root, 'ven/windows-qa.local.json');
const mode = process.argv[2] || 'create';
const accountPath = 'C:/Users/hassa/OneDrive/Desktop/materiallab-63405-firebase-adminsdk-fbsvc-9057cc9864.json';
const credential = JSON.parse(fs.readFileSync(accountPath, 'utf8').replace(/^\uFEFF/, ''));
if (credential.project_id !== 'materiallab-63405') throw Error('Unexpected credential project.');
admin.initializeApp({credential: admin.credential.cert(credential), projectId: credential.project_id});
const db = admin.firestore();
db.settings({preferRest: true});
const auth = admin.auth();
const save = state => fs.writeFileSync(secretPath, JSON.stringify(state, null, 2));
const check = state => {
  if (state.project !== 'materiallab-63405' || !/^qa_win_20261102_[a-f0-9]+$/.test(state.org) || state.org === 'org_fnjyipt5') throw Error('Unsafe QA scope.');
  for (const user of state.users) if (!user.uid.startsWith(state.org + '_')) throw Error('Unsafe QA identity.');
};

(async () => {
  if (mode === 'cleanup') {
    const state = JSON.parse(fs.readFileSync(secretPath, 'utf8'));
    check(state);
    for (const user of state.users) {
      await auth.deleteUser(user.uid).catch(e => {if (e.code !== 'auth/user-not-found') throw e;});
      await db.doc(`users/${user.uid}`).delete();
    }
    await db.recursiveDelete(db.doc(`organizations/${state.org}`));
    state.cleanedAt = new Date().toISOString();
    save(state);
    console.log(JSON.stringify({cleaned: true, organization: state.org, accounts: state.users.length}));
    return;
  }
  if (mode !== 'create' || fs.existsSync(secretPath)) throw Error('Existing QA manifest or unsupported action; nothing overwritten.');
  const state = {project: 'materiallab-63405', org: 'qa_win_20261102_' + crypto.randomBytes(5).toString('hex'), users: [], createdAt: new Date().toISOString()};
  check(state);
  fs.mkdirSync(path.dirname(secretPath), {recursive: true});
  save(state);
  const roles = ['admin', 'lab', 'quality_manager', 'nutritionist', 'viewer', 'trial_owner'];
  for (const role of roles) {
    const user = {role, uid: `${state.org}_${role}`, email: `qa.windows.${role}.${state.org.slice(-10)}@example.test`, password: crypto.randomBytes(24).toString('base64url') + 'Aa1!'};
    state.users.push(user);
    check(state);
    save(state);
    await auth.createUser({uid: user.uid, email: user.email, password: user.password, emailVerified: true, displayName: `QA Windows ${role}`});
    const profile = {organizationId: state.org, uid: user.uid, memberId: user.uid, email: user.email, displayName: `QA Windows ${role}`, role, roles: [role], status: 'active', version: 1, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp(), updatedBy: user.uid};
    await db.doc(`users/${user.uid}`).set(profile);
    await db.doc(`organizations/${state.org}/members/${user.uid}`).set(profile);
  }
  const owner = state.users[0].uid;
  const org = db.doc(`organizations/${state.org}`);
  await org.set({name: 'QA Windows acceptance — disposable', ownerUid: owner, status: 'active', manuallyActivated: true, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp(), version: 1, commandProtocol: {enabled: true, mode: 'firestore_direct_v2', schemaVersion: 3, domainManifestVersion: 1, migrationId: state.org, globalReferencesReady: true, uniqueAdmissionComplete: true, writePolicy: 'multi_authorized', maintenance: false}});
  await org.collection('counters').doc('changeSequence').set({organizationId: state.org, value: 0});
  const timestamp = admin.firestore.Timestamp.fromDate(new Date('2020-01-01T00:00:00Z'));
  for (const [id, name, code, localId] of [['qa-corn','QA Maize','QA-CORN',1], ['qa-soy','QA Soy','QA-SOY',2]]) {
    await org.collection('referenceMaterials').doc(id).set({organizationId: state.org, remoteId: id, version: 1, materialName: name, materialCode: code, physicalReferenceJson: '{}', chemicalReferenceJson: '{}', importedAt: '2020-01-01', active: 1, deletedAt: null, localId, deviceId: 'qa-fixture', createdBy: owner, updatedBy: owner, createdAt: timestamp, updatedAt: timestamp});
  }
  const vectors = JSON.parse(fs.readFileSync(path.join(root, 'test/fixtures/domain_wire_vectors.json'), 'utf8'));
  const base = vectors.inspection.payload.writes.find(w => w.entityType === 'sample').payload;
  for (const [id, material, date, protein, localId] of [['qa-soy-before','qa-soy','2019-12-01',40,1], ['qa-corn-after','qa-corn','2020-02-10',10,2]]) {
    await org.collection('samples').doc(id).set({...base, organizationId: state.org, remoteId: id, entryCode: id.toUpperCase(), inspectionKind: 'raw', inspectionDate: date, decisionStatus: 'APPROVED', chemicalResultsJson: JSON.stringify({protein:[protein],fat:[4],moisture:[10]}), physicalResultsJson: '{}', localId, version: 1, deletedAt: null, deviceId: 'qa-fixture', createdBy: owner, updatedBy: owner, createdAt: timestamp, updatedAt: timestamp, parentRefs: {materialId:{entityType:'referenceMaterial',entityId:material,version:1}}});
  }
  state.readyAt = new Date().toISOString();
  save(state);
  fs.writeFileSync(path.join(root, 'output/windows-qa-scope.json'), JSON.stringify({organization: state.org, roles, protectedOrganizationExcluded: true, credentialsStoredInIgnoredFile: true}, null, 2));
  console.log(JSON.stringify({ready: true, organization: state.org, roles}));
})().catch(error => {console.error(`QA fixture failed: ${error.message}`); process.exitCode = 1;});
