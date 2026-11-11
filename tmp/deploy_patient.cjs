'use strict';
// Option 1: create-then-poll, following the verified Nov 8/9 recovery
// playbook. One createRuleset attempt (a 503 here is NOT proof of failure —
// the service has historically created the ruleset despite returning 503),
// then poll read-backs by content hash every 15 minutes for up to 75 minutes.
// If the ruleset materializes (compile succeeded server-side), bind the
// release and verify by read-back.
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

const digest = (s) => crypto.createHash('sha256').update(String(s).replace(/\r\n/g, '\n')).digest('hex');
const now = () => new Date().toISOString().slice(11, 19);

(async () => {
  const account = auth.getProjectDefaultAccount(root);
  if (!account) throw Error('Firebase CLI login is required.');
  await requireAuth({project, ...account});

  const artifact = fs.readFileSync(path.join(root, 'build/firestore.release.rules'), 'utf8');
  const artifactHash = digest(artifact);
  console.log(now(), 'artifact sha256:', artifactHash, '| bytes:', Buffer.byteLength(artifact));

  // Step 0: idempotency — never re-deploy identical content.
  const before = await rules.listAllReleases(project);
  const currentRelease = before.find((r) => r.name === `projects/${project}/releases/cloud.firestore`)
    || before.find((r) => r.name === `projects/${project}/releases/cloud.firestore/(default)`);
  if (currentRelease) {
    const live = await rules.getRulesetContent(currentRelease.rulesetName);
    if (live.length === 1 && digest(live[0].content) === artifactHash) {
      console.log('already_deployed: live release content matches the artifact exactly.');
      console.log('ruleset:', currentRelease.rulesetName);
      return;
    }
    console.log(now(), 'live release is', currentRelease.rulesetName, '— proceeding with create attempt.');
  }

  // Step 1: ONE createRuleset attempt; 503/500 = unknown state, keep polling.
  let createError = null;
  try {
    await rules.createRuleset(project, [{name: 'firestore.release.rules', content: artifact}]);
    console.log(now(), 'createRuleset: returned success.');
  } catch (error) {
    createError = error;
    console.log(now(), 'createRuleset: returned error', error.status ?? '', (error.message || '').slice(0, 120));
  }

  // Step 2: poll for the ruleset by hash — every 15 min, up to 75 min.
  const created = Date.now();
  for (let round = 0; round <= 5; round++) {
    if (round > 0) await new Promise((r) => setTimeout(r, 15 * 60 * 1000));
    const sets = await rules.listAllRulesets(project);
    let found = null;
    for (const set of sets) {
      if (!set.metadata?.createTime) continue;
      const ageMs = Date.now() - new Date(set.metadata.createTime).getTime();
      if (ageMs > 2 * 60 * 60 * 1000) continue; // candidate window covers our own attempt
      const content = await rules.getRulesetContent(set.name);
      if (content.length === 1 && digest(content[0].content) === artifactHash) { found = set; break; }
    }
    if (found) {
      console.log(now(), `read-back ${round}: recoveredByHash — ruleset created and compiled successfully:`, found.name);
      // Step 3: bind the release.
      await rules.updateRelease(project, 'cloud.firestore', found.name);
      console.log(now(), 'updateRelease: release cloud.firestore ->', found.name);
      // Step 4: verify by reading back.
      const releases = await rules.listAllReleases(project);
      const release = releases.find((r) => r.name === `projects/${project}/releases/cloud.firestore`)
        || releases.find((r) => r.name === `projects/${project}/releases/cloud.firestore/(default)`);
      if (!release || release.rulesetName !== found.name) throw Error('Release does not point at the created ruleset after update.');
      const verified = await rules.getRulesetContent(release.rulesetName);
      if (verified.length !== 1 || digest(verified[0].content) !== artifactHash) throw Error('Release content hash mismatch after activation.');
      console.log('VERIFIED:', now(), 'live release =', release.rulesetName, '| content sha256 =', digest(verified[0].content));
      return;
    }
    console.log(now(), `read-back ${round}: no ruleset with the artifact hash yet.`);
  }
  console.log(now(), `gave up after 75 minutes of polling. Last create error: ${createError ? (createError.message || createError) : 'none'}. Nothing was deployed.`);
  process.exitCode = 1;
})().catch((error) => {
  console.error('deploy failed:', error.status ?? '', error.message || error);
  if (error.body) console.error('body:', JSON.stringify(error.body).slice(0, 2000));
  process.exitCode = 1;
});
