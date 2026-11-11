'use strict';
const fs = require('fs');
const live = fs.readFileSync('output/firestore-live-before.rules', 'utf8');
const local = fs.readFileSync('build/firestore.release.rules', 'utf8');
const rtChunk = "let rt=['qcAudit','qcItem','qcSection','qcTemplate'];let routine=first.protocol.entityType in rt;";
const before = live.indexOf(';let types=table?');
console.log('types= occurrences in live:', (live.match(/;let types=table\?/g) || []).length);
const t1 = live.slice(0, before + 1) + rtChunk + live.slice(before + 1);
const audOld = "match/auditLogs/{docId}{allow read:if can(orgId,'audit.read');";
const audNew = "match/auditLogs/{docId}{allow get:if can(orgId,'audit.read');allow list:if can(orgId,'devices.read');";
console.log('auditLogs old block found in transformed:', t1.includes(audOld));
const t2 = t1.replace(audOld, audNew)
  .replace("):['labAnalysis','labAnalysisItem','labFieldLink','labUnit']",
           "):routine?rt:['labAnalysis','labAnalysisItem','labFieldLink','labUnit']")
  .replace('(table||consumption||simple||e.records.size()<=6)',
           '(table||consumption||simple||routine||e.records.size()<=6)')
  .replace("'devices.register','audit.read','formulations.read']:role=='viewer'",
           "'devices.register','audit.read','formulations.read','reference.update']:role=='viewer'");
console.log('transformed === local:', t2 === local);
if (t2 !== local) {
  let first = -1;
  const n = Math.min(t2.length, local.length);
  for (let i = 0; i < n; i++) { if (t2[i] !== local[i]) { first = i; break; } }
  console.log('first diff at', first, '| len t2', t2.length, '| len local', local.length);
  console.log('T2   :', JSON.stringify(t2.slice(Math.max(0, first - 60), first + 140)));
  console.log('LOC  :', JSON.stringify(local.slice(Math.max(0, first - 60), first + 140)));
}
