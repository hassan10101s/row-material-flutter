'use strict';
// One call: compile a ~60KB syntactically-valid rules source to see whether
// the 503 is size-correlated (large payload) or a flat outage/quota block.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const root = path.resolve(__dirname, '..');
const cli = path.join(os.homedir(), 'AppData/Roaming/npm/node_modules/firebase-tools/lib');
const auth = require(path.join(cli, 'auth.js'));
const {requireAuth} = require(path.join(cli, 'requireAuth.js'));
const rules = require(path.join(cli, 'gcp/rules.js'));
const project = 'materiallab-63405';

(async () => {
  const account = auth.getProjectDefaultAccount(root);
  await requireAuth({project, ...account});
  const unit = "match /probe{n}/{docId} { allow read: if false; }\n";
  let content = "rules_version = '2';\nservice cloud.firestore { match /databases/{database}/documents {\n";
  let n = 0;
  while (content.length < 60000) { content += unit.replace('{n}', n++); }
  content += '} }';
  try {
    const result = await rules.testRuleset(project, [{name: 'probe.rules', content}]);
    console.log('60KB probe -> status', result.status, '| issues', (result.body?.issues ?? []).length);
  } catch (error) {
    console.log('60KB probe -> error', error.status ?? '', (error.message || '').slice(0, 100));
  }
})().catch((error) => {
  console.error('probe failed:', error.status ?? '', error.message || error);
  process.exitCode = 1;
});
