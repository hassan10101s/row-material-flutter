'use strict';
// Patient deployment loop: every 10 minutes try ONE compile-only test of the
// prepared artifact (minimal quota usage). As soon as it returns 200, spawn
// the deploy script (create -> recoverByHash -> updateRelease -> verify).
const {spawnSync} = require('node:child_process');
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
  const artifact = fs.readFileSync(path.join(root, 'build/firestore.release.rules'), 'utf8');
  for (let round = 1; round <= 8; round++) {
    const stamp = new Date().toISOString();
    try {
      const result = await rules.testRuleset(project, [{name: 'firestore.release.rules', content: artifact}]);
      console.log(`[${stamp}] round ${round}: compile 200, issues ${(result.body?.issues ?? []).length}`);
      if ((result.body?.issues ?? []).length > 0) {
        console.log('Compile returned issues — NOT deploying. Issues:', JSON.stringify(result.body.issues).slice(0, 2000));
        process.exitCode = 2;
        return;
      }
      console.log('Compile passed — deploying.');
      const deploy = spawnSync(process.execPath, [path.join(root, 'tmp/deploy_rules.cjs')], {encoding: 'utf8', cwd: root, timeout: 600000});
      console.log(deploy.stdout || '');
      if (deploy.stderr) console.error(deploy.stderr);
      process.exitCode = deploy.status === 0 ? 0 : 1;
      return;
    } catch (error) {
      console.log(`[${stamp}] round ${round}: not yet (${error.status ?? ''} ${(error.message || '').slice(0, 80)}) — waiting 10 minutes.`);
      if (round < 8) await new Promise((r) => setTimeout(r, 10 * 60 * 1000));
    }
  }
  console.log('Gave up after 8 rounds (~80 min). Nothing was deployed.');
  process.exitCode = 1;
})().catch((error) => {
  console.error('loop failed:', error.message || error);
  process.exitCode = 1;
});
