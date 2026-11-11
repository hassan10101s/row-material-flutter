'use strict';
// Decisive probe: compile a ~60-90KB span of the REAL live content (whole
// sibling blocks removed, braces valid). Trivial dummies pass at 130KB; if
// real content fails even here, the 503 is a compile-time/deadline issue.
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
      if (depth === 2 && live.slice(i + 1, i + 7).startsWith('match/')) boundaries.push(i + 1);
    }
  }
  const b0 = boundaries[0], b1 = boundaries[1], b2 = boundaries[2];
  console.log('boundaries:', boundaries, 'sizes:', boundaries.map((b, i) => i ? b - boundaries[i - 1] : b));

  const variants = [
    ['first-half removed', live.slice(0, b1) + live.slice(b2)],
    ['middle removed', live.slice(0, b1) + live.slice(b2)], // same as above; adjust after seeing sizes
  ];
  const v1 = live.slice(0, b1) + live.slice(b2);
  console.log('v1 size:', v1.length);
  try {
    const result = await rules.testRuleset(project, [{name: 'v1.rules', content: v1}]);
    console.log('v1 -> status', result.status, '| issues', (result.body?.issues ?? []).length);
    if ((result.body?.issues ?? []).length) console.log(JSON.stringify(result.body.issues).slice(0, 400));
  } catch (error) {
    console.log('v1 -> error', error.status ?? '', (error.message || '').slice(0, 90));
  }
})().catch((error) => {
  console.error('probe failed:', error.status ?? '', error.message || error);
  process.exitCode = 1;
});
