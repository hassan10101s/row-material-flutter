"""Read-only receipt coverage evidence; never migrates or writes the cache."""
import collections
import json
from pathlib import Path
import sqlite3
import sys

sys.stdout.reconfigure(encoding='utf-8')

source = Path(sys.argv[1]).resolve(strict=True)
connection = sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)
connection.row_factory = sqlite3.Row
connection.execute('PRAGMA query_only = ON')
materials = connection.execute(
    "SELECT id, material_code, material_name FROM reference_materials "
    "WHERE lower(material_name) LIKE '%corn%' OR lower(material_name) LIKE '%maize%' "
    "OR material_name LIKE '%ذرة%'"
).fetchall()
result = []
for material in materials:
    rows = connection.execute(
        "SELECT inspection_date, decision_status, chemical_results_json "
        "FROM inspections WHERE material_id=? AND inspection_kind='raw' "
        "AND deleted_at IS NULL ORDER BY inspection_date", (material['id'],)
    ).fetchall()
    accepted = [row for row in rows if row['decision_status'] in ('APPROVED', 'CONDITIONAL_APPROVAL')]
    dates = collections.defaultdict(list)
    for row in accepted:
        try:
            values = json.loads(row['chemical_results_json'] or '{}')
        except (ValueError, TypeError):
            continue
        for key, raw in values.items():
            numbers = raw if isinstance(raw, list) else [raw]
            if any(value is not None and str(value).strip() not in ('', '-') for value in numbers):
                dates[key].append(row['inspection_date'])
    result.append({
        **dict(material), 'records': len(rows),
        'decisions': dict(collections.Counter(row['decision_status'] for row in rows)),
        'accepted': len(accepted),
        'accepted_from': accepted[0]['inspection_date'] if accepted else None,
        'accepted_to': accepted[-1]['inspection_date'] if accepted else None,
        'parameters': {key: {'from': min(value), 'to': max(value), 'receipts': len(value)} for key, value in dates.items()},
    })
formulas = []
for row in connection.execute("SELECT name, items_json, parameters_json, updated_at FROM nutrition_formulations WHERE deleted_at IS NULL AND is_archived = 0"):
    items = json.loads(row['items_json'] or '[]')
    formulas.append({'name': row['name'], 'ingredients': len(items), 'weight_kg': sum(float(item.get('quantity_kg') or 0) for item in items), 'settings': json.loads(row['parameters_json'] or '{}'), 'updated_at': row['updated_at']})
print(json.dumps({'read_only': True, 'corn_materials': result, 'saved_formulas': formulas}, ensure_ascii=False, indent=2))
connection.close()
