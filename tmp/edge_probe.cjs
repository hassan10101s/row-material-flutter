'use strict';
// Threshold probe: compile the LIVE artifact with trailing match-blocks
// removed in ~1-2KB steps until it compiles. Establishes how far over the
// edge the deployed ruleset currently sits.
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
  // The artifact has no comments; match blocks look like: match/NAME/{...}
  // Cut from the LAST 'match /xxx' boundary before a given byte budget.
  const cuts = [1000, 3000, 8000];
  for (const cut of cuts) {
    const target = live.length - cut;
    // Blocks are adjacent as `...;}match/NAME/{docId}{...}`; cut right after
    // the closing brace of the block that ends nearest the budget.
    const idx = live.lastIndexOf('}match/', target);
    if (idx < 0) { console.log('cut', cut, ': no boundary'); continue; }
    const fixed = live.slice(0, idx + 1) + ' } }';
    try {
      const result = await rules.testRuleset(project, [{name: 'cut.rules', content: fixed}]);
      console.log(`cut ${cut}B (source ${Buffer.byteLength(fixed)}) -> status ${result.status} issues ${(result.body?.issues ?? []).length}`);
      if ((result.body?.issues ?? []).length) console.log(JSON.stringify(result.body.issues).slice(0, 600));
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
