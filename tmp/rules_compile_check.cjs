'use strict';
// Read-only compile-only validation of the prepared rules artifact against
// the Firebase Rules API, following the 2026-11-08 pattern:
//   1. health control with a tiny source,
//   2. compile-only test of build/firestore.release.rules,
//   3. report issues (including the compiled-size limit) WITHOUT deploying.
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
  if (!account) throw Error('Firebase CLI login is required.');
  await requireAuth({project, ...account});
  const healthFiles = [{name: 'health.rules', content: "rules_version = '2';\nservice cloud.firestore { match /databases/{database}/documents { allow read: if false; } }"}];
  const health = await rules.testRuleset(project, healthFiles);
  console.log('healthControl:', JSON.stringify({status: health.status, issues: (health.body?.issues ?? []).length}));
  if ((health.body?.issues ?? []).length > 0) throw Error('Health control failed: ' + JSON.stringify(health.body.issues));

  const artifact = fs.readFileSync(path.join(root, 'build/firestore.release.rules'), 'utf8');
  const sha = crypto.createHash('sha256').update(artifact).digest('hex');
  const compiled = await rules.testRuleset(project, [{name: 'firestore.release.rules', content: artifact}]);
  const issues = compiled.body?.issues ?? [];
  console.log('compileOnly:', JSON.stringify({
    sha256: sha,
    artifactBytes: Buffer.byteLength(artifact),
    status: compiled.status,
    issues,
  }, null, 1));
  if (issues.length > 0) process.exitCode = 2;
})().catch((error) => {
  console.error('compile-check failed:', error.status ?? '', error.message || error);
  if (error.body) console.error('body:', JSON.stringify(error.body).slice(0, 2000));
  process.exitCode = 1;
});
