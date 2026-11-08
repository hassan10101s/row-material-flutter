"""Read-only diagnostics of product requests; never alters drafts or cache."""
import json
import sqlite3
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8')
source = Path(sys.argv[1]).resolve(strict=True)
db = sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)
db.row_factory = sqlite3.Row
db.execute('PRAGMA query_only = ON')
requests = []
for row in db.execute('SELECT operation_id, state, attempts, last_error_code, last_error, payload, result_json, created_at, updated_at FROM command_outbox ORDER BY id DESC LIMIT 100'):
    item = dict(row)
    payload = json.loads(item.pop('payload'))
    writes = payload.get('writes', [])
    if not any(w.get('entityType') in ('labProduct', 'labProductAnalysis', 'sample', 'productBatch', 'productBatchSample') for w in writes):
        continue
    item['effects'] = [{k: w.get(k) for k in ('entityType', 'entityId', 'operation', 'expectedVersion', 'relations')} for w in writes]
    requests.append(item)
print(json.dumps({'read_only': True, 'requests': requests, 'draft_states': [dict(r) for r in db.execute('SELECT state, COUNT(*) AS count FROM drafts GROUP BY state')], 'products': [dict(r) for r in db.execute('SELECT id, name, active FROM lab_products ORDER BY id DESC LIMIT 20')]}, ensure_ascii=False, indent=2))
db.close()
