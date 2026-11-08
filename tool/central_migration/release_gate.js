'use strict';
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const root=path.resolve(__dirname,'../..');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const required=['analysis','unitTests','rulesTests','migrationRestore','windowsRelease','androidRelease',
  'windowsAcceptance','androidAcceptance','quotaDay','staging'];
function fingerprint() {
  const files=[];
  function walk(dir) {
    if(!fs.existsSync(dir)) return;
    for(const e of fs.readdirSync(dir,{withFileTypes:true})) {
      if(e.isSymbolicLink()||['node_modules','build','.gradle','.cxx','.git'].includes(e.name)) continue;
      const p=path.join(dir,e.name);
      if(e.isDirectory()) walk(p);
      else if(/\.(dart|js|json|yaml|rules|cpp|h|gradle|kts|xml|cmake)$/.test(e.name)) files.push(p);
    }
  }
  for(const dir of ['lib','test','tool/central_migration','windows','android']) walk(path.join(root,dir));
  for(const file of ['firestore.rules','firebase.json','firestore.indexes.json','pubspec.yaml','pubspec.lock']) files.push(path.join(root,file));
  const lines=files.sort().map(p=>`${path.relative(root,p).replaceAll('\\','/')}\0${sha(fs.readFileSync(p))}`);
  return sha(lines.join('\n'));
}
function assertReleaseEvidence(filename) {
  if(typeof filename!=='string') throw Error('Production gate requires --evidence FILE from this exact source revision');
  const evidence=JSON.parse(fs.readFileSync(filename,'utf8'));
  if(evidence.sourceFingerprint!==fingerprint()) throw Error('Acceptance evidence belongs to a different source revision');
  const missing=required.filter(k=>evidence.checks?.[k]?.status!=='passed');
  if(missing.length) throw Error(`Unpassed release gates: ${missing.join(', ')}`);
  if(!Array.isArray(evidence.unsupportedOperations)||evidence.unsupportedOperations.length) throw Error('Unresolved operation coverage blocks release');
  for(const key of required) {
    const check=evidence.checks[key];
    if(!check.artifact||!check.sha256) throw Error(`Missing evidence artifact: ${key}`);
    const artifact=path.resolve(root,check.artifact);
    if(!artifact.startsWith(root+path.sep)) throw Error('Evidence artifact must be inside the workspace');
    if(sha(fs.readFileSync(artifact))!==check.sha256) throw Error(`Evidence artifact changed: ${key}`);
  }
  return evidence;
}
if(require.main===module) {
  try {
    const args=require('./cli_args').parse();
    if(args.evidence) {assertReleaseEvidence(args.evidence);console.log('Release evidence verified');}
    else console.log(JSON.stringify({sourceFingerprint:fingerprint(),checks:Object.fromEntries(required.map(k=>[k,{status:'not_run'}])),
      releaseScope: require('./release_limits.json'),
      unsupportedOperations:['Verify each enabled operation against releaseScope: expandedEntityTypes allow the larger atomic bound; other families and mixed operations retain maxStandardBusinessEffects. Above-limit operations remain unsent drafts with submission disabled and no partial commit.']},null,2));
  } catch(e) {console.error(e.message);process.exitCode=1;}
}
module.exports={fingerprint,assertReleaseEvidence,required};
