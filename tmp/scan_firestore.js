// Read-only scan: find malformed documents that break the archive download.
// A document is malformed if `version` is not an integer >= 1, or its
// `organizationId` does not match the org it lives under (the exact checks
// the app's FirestoreDirectSyncReader performs on every snapshot page).
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const PROJECT = 'materiallab-63405';
const cfg = JSON.parse(
  readFileSync(
    join(process.env.USERPROFILE, '.config', 'configstore', 'firebase-tools.json'),
    'utf8',
  ),
);
const tokens = cfg.tokens ?? cfg;
if (!tokens.refresh_token) throw new Error('No refresh token found');

const CLIENT_ID =
  '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com';
const CLIENT_SECRET = 'j9iVZfS8kkCEFUPaAeJV0sAi';

const res = await fetch('https://oauth2.googleapis.com/token', {
  method: 'POST',
  headers: { 'content-type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    refresh_token: tokens.refresh_token,
    grant_type: 'refresh_token',
  }),
});
if (!res.ok) throw new Error(`token: ${res.status} ${await res.text()}`);
const { access_token } = await res.json();
const auth = { authorization: `Bearer ${access_token}` };
const base = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;

async function listDocs(path, pageSize = 300, pageToken) {
  const qs = new URLSearchParams({ pageSize: String(pageSize) });
  if (pageToken) qs.set('pageToken', pageToken);
  const r = await fetch(`${base}/${path}?${qs}`, { headers: auth });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.json();
}

async function* walk(path) {
  let pageToken;
  do {
    const page = await listDocs(path, 300, pageToken);
    for (const d of page.documents ?? []) yield d;
    pageToken = page.nextPageToken;
  } while (pageToken);
}

const def = (doc) => doc.fields?.version;
const versionOf = (doc) => {
  const v = def(doc);
  if (v === undefined) return null;
  if (v.integerValue !== undefined) {
    const n = Number(v.integerValue);
    return Number.isSafeInteger(n) && n >= 1 ? n : null;
  }
  return null; // double/string/etc are all rejected by the reader
};

const COLLECTIONS = [
  'parameters','materialBounds','organizationSettings','qcSops','qcSopRevisions',
  'qcSopReads','samples','qualityChecks','labResults','productBatchSamples',
  'labConfig','members','inventoryItems','inventoryTransactions','inventoryLots',
  'consumption','stockAdjustments','equipment','equipmentEvents','worksheets',
  'referenceMaterials','qcCustomTables','qcCustomTableFields','qcCustomTableRows',
  'qcTemplates','qcSections','qcItems','qcInspections','qcResponses','qcTaskLogs',
  'qcFindingsNc','qcCapa','qcAudits','auditLogs',
];

const orgs = [];
for await (const d of walk('organizations')) orgs.push(d.name);
console.log(`organizations found: ${orgs.length}`);
for (const orgName of orgs) {
  const orgId = orgName.split('/').pop();
  for (const col of COLLECTIONS) {
    try {
      for await (const doc of walk(`organizations/${orgId}/${col}`)) {
        const id = doc.name.split('/').pop();
        const v = versionOf(doc);
        const orgField = doc.fields?.organizationId?.stringValue;
        const problems = [];
        if (v === null) problems.push(`version=${JSON.stringify(def(doc))}`);
        if (orgField !== undefined && orgField !== orgId) {
          problems.push(`organizationId=${orgField}`);
        }
        if (problems.length) {
          const full = doc.name.replace(
            `projects/${PROJECT}/databases/(default)/documents/`, '');
          console.log(`BAD ${full}`);
          console.log(`     ${problems.join('; ')}`);
        }
      }
    } catch (e) {
      if (!String(e).includes('404')) {
        console.log(`SKIP ${orgId}/${col}: ${String(e).slice(0, 120)}`);
      }
    }
  }
}
console.log('scan complete');
