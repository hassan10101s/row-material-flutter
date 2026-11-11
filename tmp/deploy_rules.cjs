'use strict';
// Deployment following the verified 2026-11-08/09 recovery playbook:
//   1. createRuleset (POST rulesets) — a 503 here is NOT proof of failure;
//      the service has historically created the ruleset despite returning 503.
//   2. listAllRulesets and locate the ruleset whose source content hash
//      matches the prepared artifact (recoverByHash). A ruleset can only
//      exist if Firebase compiled it successfully (256KB limit enforced).
//   3. bind release cloud.firestore to it via updateRelease.
//   4. verify by reading the release content back and hashing it.
// NEVER treats a 503 as success; every step is confirmed by read-back.
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

(async () => {
  const account = auth.getProjectDefaultAccount(root);
  if (!account) throw Error('Firebase CLI login is required.');
  await requireAuth({project, ...account});

  const artifact = fs.readFileSync(path.join(root, 'build/firestore.release.rules'), 'utf8');
  const artifactHash = digest(artifact);
  console.log('artifact sha256:', artifactHash, '| bytes:', Buffer.byteLength(artifact));

  // Step 0: never overwrite a live release with the same content — idempotent.
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
  }

  // Step 1: attempt createRuleset; tolerate 503/UNAVAILABLE as unknown state.
  let createError = null;
  try {
    await rules.createRuleset(project, [{name: 'firestore.release.rules', content: artifact}]);
    console.log('createRuleset: returned success.');
  } catch (error) {
    createError = error;
    console.log('createRuleset: returned error', error.status ?? '', (error.message || '').slice(0, 120));
  }

  // Step 2: recover by hash — find a ruleset whose content matches exactly.
  let created = null;
  let attempts = 0;
  while (created === null && attempts < 5) {
    attempts++;
    const sets = await rules.listAllRulesets(project);
    for (const set of sets) {
      if (!set.metadata?.createTime) continue;
      // Only rulesets created in the last 30 minutes are candidates; older
      // identical content would have been found in step 0 (live release).
      const ageMs = Date.now() - new Date(set.metadata.createTime).getTime();
      if (ageMs > 30 * 60 * 1000) continue;
      const content = await rules.getRulesetContent(set.name);
      if (content.length === 1 && digest(content[0].content) === artifactHash) {
        created = set;
        break;
      }
    }
    if (created === null) {
      console.log(`read-back ${attempts}: no ruleset with the artifact hash yet.`);
      if (attempts < 5) await new Promise((r) => setTimeout(r, 20000));
    }
  }
  if (created === null) {
    throw Error(`The ruleset was never created after ${attempts} read-backs. Last create error: ${createError ? (createError.message || createError) : 'none'}. Not deploying anything.`);
  }
  console.log('recoveredByHash: ruleset created and compiled successfully:', created.name);
  console.log('compiled metadata:', JSON.stringify(created.metadata ?? {}));

  // Step 3: bind the release.
  await rules.updateRelease(project, 'cloud.firestore', created.name);
  console.log('updateRelease: release cloud.firestore ->', created.name);

  // Step 4: verify by reading back.
  const releases = await rules.listAllReleases(project);
  const release = releases.find((r) => r.name === `projects/${project}/releases/cloud.firestore`)
    || releases.find((r) => r.name === `projects/${project}/releases/cloud.firestore/(default)`);
  if (!release || release.rulesetName !== created.name) {
    throw Error('Release does not point at the created ruleset after update.');
  }
  const verified = await rules.getRulesetContent(release.rulesetName);
  if (verified.length !== 1 || digest(verified[0].content) !== artifactHash) {
    throw Error('Release content hash mismatch after activation.');
  }
  console.log('VERIFIED: live release =', release.rulesetName, '| content sha256 =', digest(verified[0].content));
})().catch((error) => {
  console.error('deploy failed:', error.status ?? '', error.message || error);
  if (error.body) console.error('body:', JSON.stringify(error.body).slice(0, 2000));
  process.exitCode = 1;
});
