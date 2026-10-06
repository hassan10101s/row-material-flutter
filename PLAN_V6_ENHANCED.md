# PLAN_V6_ENHANCED - QC Manager (SOP + Checklist + Goals + NCR Reports) Feature Implementation

> Status: Implementation Plan (Build-Ready)
> Project: row material flutter
> Date: 2026-10-03 (Enhanced: 2026-10-04)

---

## 1. Executive Summary

This plan defines the implementation of a complete **QC Manager** module inside the existing Flutter app. The module adds:
- **SOP Management** (create, version, approve, publish, read acknowledgements, audit trail)
- **QC Checklists** (reusable templates, inspection execution with Pass/Fail/NA, evidence, NCs, CAPA)
- **QC Goal Tracking** (goals, assignments to persons/users, completion tracking with who/when/status/history, linking to inspections/NCRs/CAPAs/SOPs)
- **NCR / Non-Conformance Report** (central NC reporting, KPIs, aging, export PDF/Excel)
- **High Audit Testing** (immutable append-only audits, hash chain integrity, tamper-evidence)
- **Compliance Controls** (RBAC, effective dates, immutability, approvals, audit)

The design aligns with the existing architecture (feature-based folders, Cubit/State, **sqflite/DatabaseHelper only** — no Drift, flat domain files in `domain/`, Equatable + manual `fromMap`/`toMap`, Design System, Routing, manual DI). This is additive with no breaking changes to existing `inspections/lab` flows.

--- 

## 2. Goals & Objectives (Enhanced)

Primary goals (G11 added):

| Goal | Objective | Success Metric |
|---|---|---|
| G1. Standardize Procedures | Centralize SOPs with version control and approvals. | % SOPs published with active revision >= 95% |
| G2. Enforce Compliance | Mandatory read acknowledgements + immutable audit trail. | % required SOP reads completed >= 99% |
| G3. Consistent Inspections | Reusable checklist templates across RM/Process/FG. | # templates reused across jobs >= 3 |
| G4. Prevent Defects/Recurrence | Capture NCs at execution time + close-loop CAPA + effectiveness. | % CAPAs closed within due (On-Time Closure) >= 90% |
| G5. Traceability & Evidence | Link inspections to Batch/Lot/PO/Job + photos/notes. | 100% submitted inspections traceable + audited |
| G6. Data Integrity | Immutable revisions/audits, single-active SOP, required evidence on Fail/Critical. | Zero audit tampering violations; invalid submits blocked 100% |
| G7. Operational Readiness | Offline-first (drafts + photos + queues). | Sync success >= 99%, offline recovery 100% |
| G8. Actionable QC | KPIs (FPY, NC rate, Top Defects, Overdue CAPAs, SOP read compliance). | Dashboard <1s (filtered) |
| G9. Risk Reduction | Risk-based (Critical/Major/Minor), 4-eyes on critical, conditional logic. | Critical NCs enforced per matrix |
| G10. Maintainability | Match repo conventions (flat domain, Cubits, DS, manual DI). | No new global patterns, reuse DS/utils |
| G11. Measurable QC Goals | Define, assign, track and close QC goals with completion evidence + who finished it. | % goals completed on-time >= 90%; 100% completions have `completed_by` + `completed_at` + evidence |

---

## 5. Data Model (ERD + DDL)

### 5.1 Conventions (match repo)
- **No `_dbVersion` bump**: add tables to `DatabaseHelper._createSchema` with `CREATE TABLE IF NOT EXISTS`, indexes to `_createIndexes`. `onUpgrade` never fires (version pinned to 1). 
- **Timestamps**: use `AppDates.nowIso()` format (`yyyy-MM-dd HH:mm:ss`, local time) — do **not** force UTC `Z` unless `AppDates` exposes `nowUtcIso()` (repo uses local). 
- **Booleans**: `INTEGER NOT NULL DEFAULT 0/1`. 
- **Soft delete**: prefer `deleted_at TEXT` (existing repo uses `deleted_at IS NULL` filter). `is_deleted INTEGER` appears in some existing tables; do not mix unless unavoidable. 
- **User IDs**: `TEXT` (Firebase `uid`) for `created_by`, `updated_by`, `assigned_to`, `completed_by`, `inspector_id`, etc. (consistent with `User.uid` and `AppSession`). 
- **JSON**: `*_json TEXT` (store small arrays/objects). 
- **Append-only audits**: INSERT-only, immutable, hash chain. 
- **FKs**: `ON DELETE CASCADE` for children; avoid hard-deleting published/audited rows. 

### 5.2 Core QC Tables (existing from V6, aligned)
Tables: `qc_sops`, `qc_sop_revisions`, `qc_sop_reads`, `qc_sop_audits`, `qc_templates`, `qc_sections`, `qc_items`, `qc_inspections`, `qc_responses`, `qc_findings_nc`, `qc_capa`, `qc_audits`, `qc_defect_codes`. (Keep as specified; align timestamps to local `nowIso()` and consider `deleted_at` over `is_deleted` where filtering is standard.)

---

## 12. QC Goal Tracking (Assign, Track, Complete)

Track measurable QC goals with assignments, actions, KPIs, links, and explicit "who finished it" tracking.

### 12.1 Tables

#### `qc_goals`
```sql
CREATE TABLE IF NOT EXISTS qc_goals (
  goal_id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  description TEXT,
  goal_type TEXT CHECK(goal_type IN ('SOP','Training','NC','CAPA','Audit','KPI','Compliance','Other')) DEFAULT 'Other',
  dept TEXT,
  site TEXT,
  priority TEXT CHECK(priority IN ('Low','Medium','High','Critical')) DEFAULT 'Medium',
  status TEXT CHECK(status IN ('Draft','Active','OnHold','Completed','Cancelled','Archived')) NOT NULL DEFAULT 'Draft',
  target_value REAL,
  target_unit TEXT,
  baseline_value REAL,
  current_value REAL,
  start_date TEXT NOT NULL,
  due_date TEXT,
  completed_at TEXT,
  completed_by TEXT,
  completed_by_name TEXT,
  completion_notes TEXT,
  completion_evidence_json TEXT,
  owner_id TEXT,
  owner_name TEXT,
  approver_id TEXT,
  approver_name TEXT,
  approved_at TEXT,
  tags TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  deleted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_by TEXT,
  updated_by TEXT,
  version INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_qc_goals_status ON qc_goals(status);
CREATE INDEX IF NOT EXISTS idx_qc_goals_dept ON qc_goals(dept);
CREATE INDEX IF NOT EXISTS idx_qc_goals_due ON qc_goals(due_date);
CREATE INDEX IF NOT EXISTS idx_qc_goals_owner ON qc_goals(owner_id);
CREATE INDEX IF NOT EXISTS idx_qc_goals_deleted ON qc_goals(deleted_at);
```

#### `qc_goal_assignments`
```sql
CREATE TABLE IF NOT EXISTS qc_goal_assignments (
  assign_id INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id INTEGER NOT NULL,
  assignee_id TEXT NOT NULL,
  assignee_name TEXT,
  role TEXT CHECK(role IN ('Owner','Lead','Member','Reviewer')) DEFAULT 'Member',
  assigned_at TEXT NOT NULL,
  assigned_by TEXT,
  assigned_by_name TEXT,
  due_date TEXT,
  status TEXT CHECK(status IN ('Pending','InProgress','Completed','Rejected','Cancelled')) DEFAULT 'Pending',
  completed_at TEXT,
  completed_by TEXT,
  completed_by_name TEXT,
  completion_notes TEXT,
  completion_evidence_json TEXT,
  deleted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(goal_id) REFERENCES qc_goals(goal_id) ON DELETE CASCADE,
  UNIQUE(goal_id, assignee_id)
);
CREATE INDEX IF NOT EXISTS idx_qc_goal_assign_goal ON qc_goal_assignments(goal_id);
CREATE INDEX IF NOT EXISTS idx_qc_goal_assign_assignee ON qc_goal_assignments(assignee_id);
```

#### `qc_goal_actions`
```sql
CREATE TABLE IF NOT EXISTS qc_goal_actions (
  action_id INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id INTEGER NOT NULL,
  assign_id INTEGER,
  action_text TEXT NOT NULL,
  status TEXT CHECK(status IN ('Todo','InProgress','Done','Blocked','Cancelled')) DEFAULT 'Todo',
  priority TEXT CHECK(priority IN ('Low','Medium','High')) DEFAULT 'Medium',
  due_date TEXT,
  done_at TEXT,
  done_by TEXT,
  done_by_name TEXT,
  blocked_reason TEXT,
  evidence_json TEXT,
  deleted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_by TEXT,
  updated_by TEXT,
  FOREIGN KEY(goal_id) REFERENCES qc_goals(goal_id) ON DELETE CASCADE,
  FOREIGN KEY(assign_id) REFERENCES qc_goal_assignments(assign_id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_qc_goal_actions_goal ON qc_goal_actions(goal_id);
CREATE INDEX IF NOT EXISTS idx_qc_goal_actions_status ON qc_goal_actions(status);
```

#### `qc_goal_kpis`
```sql
CREATE TABLE IF NOT EXISTS qc_goal_kpis (
  kpi_id INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  target REAL NOT NULL,
  actual REAL,
  unit TEXT,
  measure_date TEXT,
  measured_by TEXT,
  measured_by_name TEXT,
  notes TEXT,
  deleted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(goal_id) REFERENCES qc_goals(goal_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_qc_goal_kpis_goal ON qc_goal_kpis(goal_id);
```

#### `qc_goal_links`
```sql
CREATE TABLE IF NOT EXISTS qc_goal_links (
  link_id INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id INTEGER NOT NULL,
  link_type TEXT CHECK(link_type IN ('SOP','INSPECTION','FINDING','CAPA','TEMPLATE','AUDIT','OTHER')) NOT NULL,
  ref_id TEXT NOT NULL,
  ref_table TEXT,
  notes TEXT,
  deleted_at TEXT,
  created_at TEXT NOT NULL,
  created_by TEXT,
  FOREIGN KEY(goal_id) REFERENCES qc_goals(goal_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_qc_goal_links_goal ON qc_goal_links(goal_id);
CREATE INDEX IF NOT EXISTS idx_qc_goal_links_ref ON qc_goal_links(link_type, ref_id);
```

### 12.2 Domain (flat style, match repo)
Location: `lib/features/qc_manager/domain/` (flat files, no `models/repositories` subdirs unless chosen — but match existing: `inspections/domain/inspection.dart` is flat).

Files:
- `qc_goal.dart` — extends `Equatable`, manual `fromMap(Map<String,dynamic>)`, `toMap({bool withId=true})`, fields `completedBy`, `completedByName`, `completedAt`, `completionEvidenceJson`, `deletedAt`
- `qc_goal_assignment.dart`
- `qc_goal_action.dart`
- `qc_goal_kpi.dart`
- `qc_goal_link.dart`
- `qc_goal_enums.dart` (String constants + `all` lists, not Dart enums)

All use `String` for user IDs/names, `DateTime?` parsed from TEXT if needed, JSON via `app_format.dart` helpers.

### 12.3 Repositories
Interfaces: `abstract interface class QcGoalRepository` in `domain/qc_goal_repository.dart` (flat) with methods: `create`, `update`, `getById`, `list`, `count`, `assign`, `unassign`, `markActionDone`, `markCompleted`, `link`, `unlink`, `softDelete`. Implement `QcGoalRepo` in `data/qc_goal_repo.dart`, take `{DatabaseExecutor? exec}`, return `Map<String,dynamic>` at boundary (match Inspection pattern). Add `OfflineFirstQcGoalRepository` if synced.

Completion rule: setting `status='Completed'` requires `completedBy` (uid), `completedByName`, `completedAt = nowIso()`, and stores `completionEvidenceJson`. History captured in `qc_audits` (append-only).

### 12.4 Cubit/State/UI
- Cubits: `QcGoalsCubit extends AppCubit<QcGoalsState>` (list/filter), `QcGoalFormCubit`, `QcGoalDetailCubit` (assignments/actions/links)
- States: `@immutable + Equatable + const ctor + copyWith`
- Pages: `qc_goals_screen.dart` (list + filters: status/dept/owner/assignee/due range), `qc_goal_form_screen.dart`, `qc_goal_detail_screen.dart` (tabs: Overview, Assignments, Actions, KPIs, Links, History)
- Routes: add `static const String qcGoals = '/qc-goals'`, `qcGoalDetail = '/qc-goals/detail'` (or query) to `AppRoutes`; add to `ShellRoute` and `guardRoute` (require `Permission.qcRead`).

### 12.5 Integration
Link to: `qc_inspections.inspection_id`, `qc_findings_nc.finding_id`, `qc_capa.capa_id`, `qc_sops.sop_id`, `qc_templates.template_id`. RBAC: create/edit/complete per `qc.approve`/role (owner/approver). 

---

## 21. High Audit Test Plan

### 21.1 Objectives
Prove append-only, immutability, hash chain integrity, canonical JSON, actor context, and offline-first transaction safety for `qc_audits` and `qc_sop_audits`.

### 21.2 Hashing (implementation)
Add `lib/core/audit/audit_hasher.dart`:
- Canonicalize JSON: sort keys, no extra spaces, use stable serialization of maps/lists (treat `null` consistently). 
- Payload to hash: `action,entity_type,entity_id,by_user_id,by_user_name,at,before_json,after_json,meta_json,prev_hash` (exclude `hash`, `id`, `immutable` from payload). 
- Algo: `SHA-256` (via `package:crypto/crypto.dart`, present). 
- `computePrevHash(rows: ..., orderBy: 'id ASC, at ASC')` reads last inserted row by `id`/`at`.

### 21.3 Test Suite

#### Unit tests (`test/core/audit/audit_hasher_test.dart`)
- `canonicalizes_sorted_keys` 
- `produces_stable_hash_across_reorders` 
- `hash_changes_if_payload_changes` 
- `handles_nulls_and_empty_strings`

#### Repo immutability tests (`test/features/qc_manager/data/qc_audit_repo_test.dart`)
- `insert_creates_row_with_hash_and_prev_hash_null_for_first` 
- `second_insert_links_prev_hash` 
- `cannot_update_existing_audit_row` (attempt `db.update('qc_audits', ..., where: 'id=?')` via repo must throw/guard; repo exposes only `insert/get/list/verifyChain`)
- `cannot_delete_existing_audit_row` (`db.delete` blocked) 
- `insert_is_idempotent_by_context?` (not expected; inserts are new events)
- `verifyChain_returns_true_for_valid_chain` 
- `verifyChain_returns_false_if_hash_tampered` (flip one char in stored `hash`/payload)
- `verifyChain_returns_false_if_prev_hash_broken` 
- `verifyChain_skips_non_audit?` no; scope to table
- `insert_preserves_immutable_flag_true`

#### Integration (offline-first) (`test/features/qc_manager/data/offline_first_audit_integration_test.dart`)
- `write_in_transaction_writes_local_and_audit_together` (rollback rolls both? or audit is append-only — audit insert must not be rolled back in a way that loses evidence; prefer inserting audit before/after in same txn or use a separate "audit" writer that commits; document: append-only events may be recorded after successful write; but for tamper-evidence, critical state changes write audit in same txn where feasible)
- `concurrent_inserts_maintain_monotonic_chain_by_id` 
- `actor_context_stored(ip_address, device_id, by_user_id, by_user_name)`

#### Cross-entity (`test/features/qc_manager/audit_coverage_test.dart`)
- SOP publish creates audit(s) with `entity_type='SOP'`/`'SOP_REV'`
- Template publish/versioning audited
- Inspection submit/review/approve audited
- NC create/assign/verify/close audited
- CAPA action/verify/effective/close audited
- Goal complete marks `completed_by` + audited

### 21.4 Verification helpers
`QcAuditRepo.verifyChain({limit: int?})` scans `qc_audits` `ORDER BY id ASC` and checks: `prev_hash == null` only id==min, each `hash == sha256(canonical(payload+prev_hash))`, no updates/deletes detected by count/row checks.

---

## 22. NCR / Non-Conformance Report

### 22.1 Purpose
Centralized NCR view derived from `qc_findings_nc` + `qc_capa` with KPIs, aging, drilldown, and export (PDF/Excel). Uses existing `pdf: ^3.10.0`, `excel: ^4.0.6`.

### 22.2 Data model (report view objects)
Flat domain: `ncr_report_row.dart` (Equatable + fromMap), `ncr_kpis.dart`, `ncr_filters.dart`. No new tables (read-only projection).

Fields (from joins):
- finding_id, inspection_id, resp_id, code, severity (Minor/Major/Critical), category, description, status, type, due_date, assigned_to, assigned_to_name, assigned_at, root_cause, action_plan, verified_by/at, closed_at/rejected_at, evidence_json, capa_id, finding_created_at/updated_at/created_by
- inspection: ref_type/ref_id, lot_no/batch_no/po_no, grn_no, location/line/work_center, inspector_id/name, inspection_date
- capa: capa_no, capa_type, capa_status, capa_priority, due_at, target_completion_at, action_completed_at, verified_effective, closed_at, assigned_to (capa)

### 22.3 KPIs
- Total NCRs (filtered)
- Open / Assigned / InProgress / Verified / Closed / Rejected
- By severity (Critical/Major/Minor)
- Overdue (status != Closed/Rejected and due_date < today)
- % On-Time Closure = (Closed with closed_at <= due_date or no due_date? define: closed on/before due_date) / (Closed in range) * 100
- Aging: 0–7, 8–14, 15–30, 31–60, >60 days (from created_at to now or to closed_at)
- MTTC (Mean Time To Close): avg days(closed_at - created_at) for Closed
- MTTV (Mean Time To Verification): avg days(verified_at - created_at) for Verified/Closed
- Top Defects by code/category (count desc)
- Repeat NCs by ref (lot_no/batch_no/ref_id) — count>1
- CAPA coverage: % findings with capa_id linked
- CAPA overdue: capa.due_at < today and capa.status not in (Closed, Rejected, VerifiedEffective)

### 22.4 Filters
Date range: `finding_created_at` between start/end (default last 30 days). Also `inspection_date`, `closed_at`. 
Multi-select: status/severity/type/category/dept (from inspection/template context), inspector_id, assigned_to, lot_no, batch_no, po_no, ref_type/ref_id, capa_status.

### 22.5 Repository/Queries
`QcNcReportRepository` in `domain/` (read-only): 
- `kpis(filters)`, `list(filters,{limit,offset,orderBy})`, `detail(findingId)`, `agingBuckets(filters)`, `topDefects(filters,limit)`, `repeatByRef(filters,limit)`

SQL (CTEs or joins):
```sql
SELECT fn.*, 
       i.ref_type,i.ref_id,i.lot_no,i.batch_no,i.po_no,i.grn_no,i.location,i.line,i.work_center,i.inspector_id,i.inspector_name,i.inspection_date,
       c.capa_no,c.type as capa_type,c.status as capa_status,c.priority as capa_priority,c.due_at as capa_due_at,c.target_completion_at,c.action_completed_at,c.verified_at as capa_verified_at,c.is_effective,c.closed_at as capa_closed_at,c.assigned_to as capa_assigned_to
FROM qc_findings_nc fn
LEFT JOIN qc_inspections i ON i.inspection_id = fn.inspection_id
LEFT JOIN qc_capa c ON c.capa_id = fn.capa_id
WHERE fn.deleted_at IS NULL AND (i.is_deleted IS NULL OR i.is_deleted=0)
ORDER BY fn.finding_id DESC
```
Apply filters with `LIKE`/`IN`/date comparisons (TEXT `yyyy-MM-dd HH:mm:ss`).

### 22.6 Cubit/State/UI
- `QcNcrCubit extends AppCubit<QcNcrState>` loads kpis+list
- State: filters, kpis, rows, loading, error, selectedFindingId
- Screens: `qc_ncr_dashboard_screen.dart` (KPI cards: Open/Overdue/Critical/On-Time%), `qc_ncr_list_screen.dart` (table + filters drawer), `qc_ncr_detail_screen.dart` (finding + inspection context + capa timeline)
- Routes: `qcNcr = '/qc-ncr'`, `qcNcrDetail = '/qc-ncr/detail'`, guard `qcRead`

### 22.7 Export
- PDF: `pdf` to render summary + KPIs + filtered table (reuse DS styles). Include filters, generated_at (`nowIso()`), user.
- Excel: `excel` workbook with sheets: `NCR_List`, `KPIs`, `Top_Defects`, `Aging`. Preserve codes/statuses.

### 22.8 Acceptance
- Filters persist in state; client-side small or server-side via repo
- Overdue computed correctly
- % on-time uses defined rule
- Exports include all filtered rows
- Links to inspection/detail

---

## 23. DatabaseHelper Migration Notes (repo-aligned)

### 23.1 Add to `_createSchema` (idempotent)
Append all `CREATE TABLE IF NOT EXISTS qc_*` for core (5.2) + goals (12.1) in logical order (parents before children). Example:
```dart
// after existing tables
await db.execute('''CREATE TABLE IF NOT EXISTS qc_sops (... )''');
...
await db.execute('''CREATE TABLE IF NOT EXISTS qc_goals (... )''');
await db.execute('''CREATE TABLE IF NOT EXISTS qc_goal_assignments (... )''');
...
```

### 23.2 Add indexes to `_createIndexes`
Add all `CREATE INDEX IF NOT EXISTS idx_qc_*` (status/date/dept/refs/assignees).

### 23.3 Sync (if remote)
If these tables sync to Firestore:
- append to `syncedTables` list (auto-adds version/remote_version/remote_synced_at/sync_state/deleted_at)
- add `SyncEntity` entries to `core/sync/entity_registry.dart` (`type`, `table`, `collection`, `keyFields`, `mutableFields`, `hasOnly([...])`)
- update `firestore.rules` rolePermissions to allow qcRead/qcApprove scoped access

### 23.4 Notes
- **No `_dbVersion`**: do not introduce it. Version stays `1` in `OpenDatabaseOptions`. 
- Use `AppDates.nowIso()` for all timestamps. 
- FK `PRAGMA foreign_keys=ON` already configured. 
- `_runLegacyGuarantees` runs on every open (idempotent) — new columns rare; tables use `IF NOT EXISTS`. 
- Soft deletes: use `deleted_at IS NULL` filters in repos (aliveFilter style). 
- Audit tables: INSERT-only (enforce in repo, not via trigger). 

---

## 24. Implementation Phases (P1–P9)

| Phase | Scope | Owner notes |
|---|---|---|
| P1 | DB schema in `DatabaseHelper` (_createSchema/_createIndexes) + verify | Idempotent, no version bump |
| P2 | Domain models (flat, Equatable, fromMap/toMap) + enums-as-strings | Match Inspection style |
| P3 | Repos + OfflineFirst facades + WriteGuard/AuditLogger integration | exec-aware, aliveFilter, validation |
| P4 | Audit hasher + qc_audit repo + High Audit tests (21) | Hash chain + immutability |
| P5 | SOP + Templates + Inspections + NC/CAPA (core) | Existing V6 scope |
| P6 | Goals (12) — tables+models+repos+cubit+UI+links | Completion tracking with who/when |
| P7 | NCR Reports (22) — repo queries + cubit + UI + PDF/Excel | Read-only projections |
| P8 | Routing + DI + Shell nav + permissions (qcRead/qcApprove) | Update `AppRoutes`, `guardRoute`, `shellNavEntries`, `service_locator` |
| P9 | Lint/typecheck + smoke tests | Follow repo commands if present |

---

## 25. Risks/Mitigations & Acceptance Criteria

### Risks
| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Audit chain break (txn timing) | High | Low | Insert audit in same txn for state changes; verifyChain on load/export; monotonic by id+at |
| Timestamps (local vs UTC) | Med | Low | Stick to `AppDates.nowIso()` (repo standard); document in code |
| Goal completion without evidence | Med | Med | Require `completed_by`, `completed_at`, evidence on critical goals; UI validation |
| Export large NCR sets | Med | Low | Paginate, stream, limit in UI; reuse DS table |
| Schema drift | Low | Low | `IF NOT EXISTS` + `_runLegacyGuarantees`; migration recovery test |

### Acceptance (key)
- [ ] All `qc_*` created idempotently; no `_dbVersion` added
- [ ] Goals: assign persons, track actions, mark complete with `completed_by` + `completed_at` + evidence; history audited
- [ ] High Audit: verifyChain passes; UPDATE/DELETE blocked; chain links correct
- [ ] NCR: KPIs/aging/filters/export PDF+Excel work from `qc_findings_nc+qc_capa+qc_inspections`
- [ ] RBAC enforced; offline-first intact; DS-only UI

---

## 26. Next Steps (Immediate)
1. Add qc_* tables to `lib/core/database/database_helper.dart` (_createSchema + _createIndexes). 
2. Create flat domain files under `lib/features/qc_manager/domain/` (SOP/template/inspection/nc/capa/goal/ncr). 
3. Implement repos (data) + offline-first facades. 
4. Add audit hasher + high audit tests. 
5. Wire routes/nav/DI + run any existing lint/typecheck commands.