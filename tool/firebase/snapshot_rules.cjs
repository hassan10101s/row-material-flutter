'use strict';

// Read-only deployment evidence. Reuses the CLI login without printing tokens
// and never reads or writes Firestore business documents.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const cli = path.join(os.homedir(), 'AppData/Roaming/npm/node_modules/firebase-tools/lib');
const auth = require(path.join(cli, 'auth.js'));
const {requireAuth} = require(path.join(cli, 'requireAuth.js'));
const rules = require(path.join(cli, 'gcp/rules.js'));
const project = 'materiallab-63405';
const phase = process.argv[2];
if (!['before', 'after'].includes(phase)) throw Error('Expected before or after.');

(async () => {
  const account = auth.getProjectDefaultAccount(root);
  if (!account) throw Error('Firebase CLI login is required.');
  await requireAuth({project, ...account});
  const releases = await rules.listAllReleases(project);
  const release = releases.find(r => r.name === `projects/${project}/releases/cloud.firestore`)
    || releases.find(r => r.name === `projects/${project}/releases/cloud.firestore/(default)`);
  if (!release) throw Error('Default Firestore rules release not found.');
  const files = await rules.getRulesetContent(release.rulesetName);
  if (files.length !== 1 || typeof files[0].content !== 'string') {
    throw Error('Unexpected rules source structure.');
  }
  const normalize = s => s.replace(/\r\n/g, '\n');
  const digest = s => crypto.createHash('sha256').update(normalize(s)).digest('hex');
  const source = files[0].content;
  const local = fs.readFileSync(path.join(root, 'firestore.rules'), 'utf8');
  const prefix = path.join(root, 'output', `firestore-live-${phase}`);
  fs.mkdirSync(path.dirname(prefix), {recursive: true});
  fs.writeFileSync(prefix + '.rules', source, {flag: phase === 'before' ? 'wx' : 'w'});
  const evidence = {
    project, release, sourceName: files[0].name,
    liveSha256: digest(source), localSha256: digest(local),
    matchesLocal: normalize(source) === normalize(local),
    capturedAt: new Date().toISOString(),
  };
  fs.writeFileSync(prefix + '.json', JSON.stringify(evidence, null, 2));
  process.stdout.write(JSON.stringify(evidence) + '\n');
})().catch(error => {
  process.stderr.write(`Rules snapshot failed: ${error.message}\n`);
  process.exitCode = 1;
});
