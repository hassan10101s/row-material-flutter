'use strict';
// Size diagnosis: compile-only tests against three variants, WITHOUT
// creating or deploying anything.
//   A. the exact live-deployed artifact (136,974 bytes, known good)
//   B. live + the three pending QC/reference hunks, WITHOUT the audit split
//   C. the prepared artifact (live + QC hunks + audit split)
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
  await requireAuth({project, ...account});
  const live = fs.readFileSync(path.join(root, 'output/firestore-live-before.rules'), 'utf8');
  const prepared = fs.readFileSync(path.join(root, 'build/firestore.release.rules'), 'utf8');
  const audOld = "match/auditLogs/{docId}{allow read:if can(orgId,'audit.read');";
  const audNew = "match/auditLogs/{docId}{allow get:if can(orgId,'audit.read');allow list:if can(orgId,'devices.read');";

  // Rebuild variant B: apply the QC/reference hunks to live, skip the audit split.
  const b = live
    .replace(';let types=table?', ";let rt=['qcAudit','qcItem','qcSection','qcTemplate'];let routine=first.protocol.entityType in rt;let types=table?")
    .replace("):['labAnalysis','labAnalysisItem','labFieldLink','labUnit']",
             "):routine?rt:['labAnalysis','labAnalysisItem','labFieldLink','labUnit']")
    .replace('(table||consumption||simple||e.records.size()<=6)',
             '(table||consumption||simple||routine||e.records.size()<=6)')
    .replace("'devices.register','audit.read','formulations.read']:role=='viewer'",
             "'devices.register','audit.read','formulations.read','reference.update']:role=='viewer'");
  console.log('B bytes', Buffer.byteLength(b));
  const bPlusAudit = b.replace(audOld, audNew);
  console.log('B+audit === prepared?', bPlusAudit === prepared);

  async function attempt(label, content) {
    try {
      const result = await rules.testRuleset(project, [{name: 'firestore.release.rules', content}]);
      const issues = result.body?.issues ?? [];
      console.log(label, '-> status', result.status, '| issues', issues.length, '| sha', digest(content).slice(0, 12), '| bytes', Buffer.byteLength(content));
      if (issues.length) console.log(label, 'issues:', JSON.stringify(issues).slice(0, 1200));
      return true;
    } catch (error) {
      console.log(label, '-> error', error.status ?? '', (error.message || '').slice(0, 100), '| bytes', Buffer.byteLength(content));
      return false;
    }
  }

  const a = await attempt('A(live)', live);
  await new Promise((r) => setTimeout(r, 15000));
  const bOk = await attempt('B(live+qc)', b);
  await new Promise((r) => setTimeout(r, 15000));
  const cOk = await attempt('C(full)', prepared);
  console.log('summary: A', a, '| B', bOk, '| C', cOk);
})().catch((error) => {
  console.error('diagnosis failed:', error.status ?? '', error.message || error);
  process.exitCode = 1;
});
