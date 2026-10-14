"""Import legacy raw-material inspections into the current organization DB.

The legacy database has local numeric users and stores the author's name on
each inspection/history row. The current database uses a roster table where
uid is optional, so this migration resolves authors by normalized name and
creates uid-less roster rows when needed. It is idempotent by entry_code for
inspections and by the resulting inspection/status tuple for history rows.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


def norm(value: object) -> str:
    return re.sub(r"[^a-z0-9\u0600-\u06ff]+", "", str(value or "").casefold())


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def json_text(value: object, fallback: str = "{}") -> str:
    if value is None or str(value).strip() == "":
        return fallback
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("legacy", type=Path)
    parser.add_argument("current", type=Path)
    parser.add_argument("--backup", type=Path, required=True)
    args = parser.parse_args()

    shutil.copy2(args.current, args.backup)
    old = sqlite3.connect(f"file:{args.legacy}?mode=ro", uri=True)
    old.row_factory = sqlite3.Row
    db = sqlite3.connect(args.current)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    inserted_users = inserted_inspections = inserted_history = 0
    user_map: dict[int, int] = {}
    inspection_map: dict[int, int] = {}

    try:
        db.execute("BEGIN IMMEDIATE")
        current_users = db.execute(
            "SELECT id, full_name, display_name, email FROM users"
        ).fetchall()
        by_name = {}
        for row in current_users:
            for value in (row["full_name"], row["display_name"], row["email"].split("@")[0]):
                if norm(value):
                    by_name[norm(value)] = int(row["id"])

        for row in old.execute("SELECT * FROM users ORDER BY id"):
            candidates = (row["full_name"], row["username"])
            local_id = next((by_name.get(norm(v)) for v in candidates if norm(v)), None)
            # Known legacy spelling variant of the current administrator.
            if local_id is None and norm(row["username"]) == norm("hassan10101s"):
                local_id = 1
            if local_id is None:
                email = f"legacy.{row['id']}@local.invalid"
                cur = db.execute(
                    """INSERT INTO users
                       (uid, member_id, email, full_name, role, status,
                        permissions_json, display_name, version, updated_at,
                        remote_version, sync_state, created_at)
                       VALUES (NULL, NULL, ?, ?, 'viewer', 'active', '[]', ?,
                               1, ?, 0, 'local', ?)""",
                    (email, row["full_name"], row["full_name"], now(), row["created_at"] or now()),
                )
                local_id = int(cur.lastrowid)
                by_name[norm(row["full_name"])] = local_id
                inserted_users += 1
            user_map[int(row["id"])] = local_id

        materials = {
            (norm(r["material_code"]), norm(r["material_name"])): int(r["id"])
            for r in db.execute("SELECT id, material_code, material_name FROM reference_materials")
        }
        for row in old.execute("SELECT * FROM inspections ORDER BY id"):
            existing = db.execute(
                "SELECT id FROM inspections WHERE entry_code = ?", (row["entry_code"],)
            ).fetchone()
            if existing:
                inspection_map[int(row["id"])] = int(existing[0])
                continue
            material_id = materials.get((norm(row["material_code"]), norm(row["material_name"])))
            if material_id is None:
                # The legacy inspection stores a snapshot code/name. The
                # reference catalog itself was carried forward with stable
                # numeric ids, so use that id when the snapshot text changed.
                candidate = int(row["material_id"] or 0)
                exists = db.execute(
                    "SELECT 1 FROM reference_materials WHERE id = ?", (candidate,)
                ).fetchone()
                if exists:
                    material_id = candidate
            if material_id is None:
                raise RuntimeError(
                    f"Missing reference material for entry {row['entry_code']}: "
                    f"{row['material_code']} / {row['material_name']}"
                )
            created_by = user_map.get(int(row["created_by"] or 0), 0)
            cur = db.execute(
                """INSERT INTO inspections
                (entry_code, material_id, material_name, material_code,
                 inspection_date, supplier, truck_number, quantity,
                 sample_taken_by, specialist_name, physical_results_json,
                 chemical_results_json, physical_reference_json,
                 chemical_reference_json, decision_status, decision_reason,
                 follow_up_note, rejected_quantity, report_html, snapshot_json,
                 sample_names_json, decision_version, created_by, created_by_name,
                 last_pdf_path, created_at, updated_at, inspection_kind,
                 version, remote_version, sync_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, 'raw', 1, 0, 'local')""",
                (
                    row["entry_code"], material_id, row["material_name"], row["material_code"],
                    row["inspection_date"], row["supplier"], row["truck_number"], row["quantity"],
                    row["sample_taken_by"], row["specialist_name"], json_text(row["physical_results_json"]),
                    json_text(row["chemical_results_json"]), json_text(row["physical_reference_json"]),
                    json_text(row["chemical_reference_json"]), row["decision_status"], row["decision_reason"],
                    row["follow_up_note"], row["rejected_quantity"], row["report_html"] or "",
                    json_text(row["snapshot_json"]), json_text(row["sample_names_json"], "[]"),
                    row["decision_version"] or 1, created_by, row["created_by_name"] or "",
                    row["last_pdf_path"], row["created_at"] or now(), row["updated_at"] or now(),
                ),
            )
            inspection_map[int(row["id"])] = int(cur.lastrowid)
            inserted_inspections += 1

        for row in old.execute("SELECT * FROM inspection_status_history ORDER BY id"):
            inspection_id = inspection_map.get(int(row["inspection_id"]))
            changed_by = user_map.get(int(row["changed_by"] or 0), 0)
            if inspection_id is None:
                continue
            exists = db.execute(
                """SELECT 1 FROM inspection_status_history
                   WHERE inspection_id = ? AND version = ? AND changed_at = ?
                     AND new_status = ?""",
                (inspection_id, row["version"], row["changed_at"], row["new_status"]),
            ).fetchone()
            if exists:
                continue
            db.execute(
                """INSERT INTO inspection_status_history
                (inspection_id, version, old_status, new_status, change_reason,
                 follow_up_note, rejected_quantity, changed_by, changed_by_name,
                 changed_at, remote_version, sync_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'local')""",
                (inspection_id, row["version"], row["old_status"], row["new_status"],
                 row["change_reason"], row["follow_up_note"], row["rejected_quantity"],
                 changed_by, row["changed_by_name"] or "", row["changed_at"]),
            )
            inserted_history += 1

        db.commit()
        print(json.dumps({
            "backup": str(args.backup),
            "users_created": inserted_users,
            "inspections_inserted": inserted_inspections,
            "history_inserted": inserted_history,
            "inspection_total": db.execute("SELECT count(*) FROM inspections").fetchone()[0],
        }, ensure_ascii=False))
    except Exception:
        db.rollback()
        raise
    finally:
        old.close()
        db.close()


if __name__ == "__main__":
    main()
