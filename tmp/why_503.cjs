'use strict';
// Why is ~137KB failing while 60KB compiles? Two probes, spaced:
//   1. the MINIMAL artifact (live + audit split only, no QC hunks)
//   2. a syntactically-valid dummy of ~130KB (same byte class as the real one)
// Nothing is created or deployed.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const cli = path.join(os.homedir(), 'AppData/Roaming/npm/node_modules/firebase-tools/lib');
const auth = require(path.join(cli, 'auth.js'));
const {requireAuth} = require(path.join(cli, 'requireAuth.js'));
const rules = require(path.join(cli, 'gcp/rules.js'));
const project = 'materiallab-63405';

(async () => {
  const account = auth.getProjectDefaultAccount(root);
  await requireAuth({project, ...account});
  const live = fs.readFileSync(path.join(root, 'output/firestore-live-before.rules'), 'utf8');

  const audOld = "match/auditLogs/{docId}{allow read:if can(orgId,'audit.read');";
  const audNew = "match/auditLogs/{docId}{allow get:if can(orgId,'audit.read');allow list:if can(orgId,'devices.read');";
  const minimal = live.replace(audOld, audNew);
  console.log('minimal bytes:', Buffer.byteLength(minimal), '| sha:', digest(minimal).slice(0, 16));

  try {
    const result = await rules.testRuleset(project, [{name: 'minimal.rules', content: minimal}]);
    console.log('MINIMAL -> status', result.status, '| issues', (result.body?.issues ?? []).length);
  } catch (error) {
    console.log('MINIMAL -> error', error.status ?? '', (error.message || '').slice(0, 120));
  }

  await new Promise((r) => setTimeout(r, 15000));
  let dummy = "rules_version = '2';\nservice cloud.firestore { match /databases/{database}/documents {\n";
  let n = 0;
  while (dummy.length < 130000) { dummy += `match /probe${n}/{docId} { allow read: if request.auth != null; }\n`; n++; }
  dummy += '} }';
  try {
    const result = await rules.testRuleset(project, [{name: 'dummy.rules', content: dummy}]);
    console.log('DUMMY130K -> status', result.status, '| issues', (result.body?.issues ?? []).length);
  } catch (error) {
    console.log('DUMMY130K -> error', error.status ?? '', (error.message || '').slice(0, 120));
  }
})().catch((error) => {
  console.error('probe failed:', error.status ?? '', error.message || error);
  process.exitCode = 1;
});

function digest(s) {
  return crypto.createHash('sha256').update(String(s).replace(/\r\n/g, '\n')).digest('hex');
}
