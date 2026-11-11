'use strict';
// Proper edge probe v2: remove WHOLE sibling match blocks (brace-balanced)
// from the live artifact so the source stays valid, then compile.
// Establishes how far the deployed ruleset sits from the failing edge.
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
  const live = fs.readFileSync(path.join(root, 'output/firestore-live-before.rules'), 'utf8');

  // Boundaries between sibling match blocks inside the databases match:
  // brace-depth scan; a 'match/' that starts a block at depth 3 (the level
  // of direct children of match/databases/{db}/documents).
  const boundaries = [];
  let depth = 0, inStr = false, esc = false;
  for (let i = 0; i < live.length; i++) {
    const ch = live[i];
    if (inStr) {
      if (esc) { esc = false; }
      else if (ch === '\\') { esc = true; }
      else if (ch === '"') { inStr = false; }
      continue;
    }
    if (ch === '"') { inStr = true; continue; }
    if (ch === '{') { depth++; continue; }
    if (ch === '}') {
      depth--;
      const rest = live.slice(i + 1, i + 7);
      if (depth === 2 && rest.startsWith('match/')) boundaries.push(i + 1);
    }
  }
  console.log('sibling boundaries at block level:', boundaries.length);

  for (const cut of [1200, 4000, 12000]) {
    const target = live.length - cut;
    // Start: last boundary at/before target; end: boundary at/before target+cut.
    let a = -1, b = -1;
    for (const p of boundaries) { if (p <= target) a = p; if (p <= target + cut) b = p; }
    if (a < 0 || b <= a) { console.log('cut', cut, ': no usable span'); continue; }
    const variant = live.slice(0, a) + live.slice(b);
    try {
      const result = await rules.testRuleset(project, [{name: 'cut.rules', content: variant}]);
      console.log(`cut ${live.length - variant.length}B (source ${variant.length}) -> status ${result.status} issues ${(result.body?.issues ?? []).length}`);
      if ((result.body?.issues ?? []).length) console.log(JSON.stringify(result.body.issues).slice(0, 400));
      if (result.status === 200) break;
    } catch (error) {
      console.log(`cut ${cut}B -> error ${error.status ?? ''} ${(error.message || '').slice(0, 90)}`);
    }
    await new Promise((r) => setTimeout(r, 12000));
  }
})().catch((error) => {
  console.error('probe failed:', error.status ?? '', error.message || error);
  process.exitCode = 1;
});
