# PLAN_V6 - QC Manager (SOP + Checklist) Feature Implementation

> Status: Implementation Plan (Build-Ready)
> Project: row material flutter
> Date: 2026-10-03

--- 

## 1. Executive Summary

This plan defines the implementation of a complete **QC Manager** module inside the existing Flutter app. The module adds:
- **SOP Management** (create, version, approve, publish, read acknowledgements, audit trail)
- **QC Checklists** (reusable templates, inspection execution with Pass/Fail/NA, evidence, NCs, CAPA)
- **Compliance Controls** (RBAC, effective dates, immutability, approvals, audit)

The design aligns with the existing architecture (feature-based folders, Cubit/State, Drift/SQLite via DatabaseHelper, Design System, Routing). This is an additive feature (no breaking changes to existing inspections/lab flows).

--- 

## 2. Goals & Objectives (Enhanced for QC)

Primary goals:

| Goal | Objective | Success Metric |
|---|---|---|
| G1. Standardize Procedures | Centralize SOPs with version control and approvals. | % SOPs published with active revision >= 95% |
| G2. Enforce Compliance | Mandatory read acknowledgements + immutable audit trail for QC actions. | % required SOP reads completed >= 99% |
| G3. Consistent Inspections | Reusable checklist templates across RM/Process/FG. | # templates reused across jobs >= 3 |
| G4. Prevent Defects/Recurrence | Capture NCs at execution time and close-loop via CAPA + effectiveness verification. | % CAPAs closed within due (On-Time Closure) >= 90% |
| G5. Traceability & Evidence | Link inspections to Batch/Lot/PO/Job + photos/notes per item. | 100% submitted inspections have traceable ref + audit |
| G6. Data Integrity | Immutable revisions/audits, single-active SOP, required evidence on Fail/Critical. | Zero audit tampering violations, blocked invalid submits = 100% |
| G7. Operational Readiness | Offline-first for plant/warehouse (drafts + photos + queues). | Sync success rate >= 99%, offline submits recoverable 100% |
| G8. Actionable QC | KPIs (FPY, NC rate, Top Defects, Overdue CAPAs, SOP read compliance). | Dashboard live with <1s load (filtered) |
| G9. Risk Reduction | Risk-based (Critical/Major/Minor), 4-eyes on critical, conditional logic. | Critical NCs require review/approval per matrix = enforced |
| G10. Maintainability | Follow existing codebase conventions (feature folders, Cubits, DS widgets, DI). | No new global patterns, reuse DS + utils | 

--- 

## 5. Data Model (ERD + DDL)

### 5.1 ERD (High-Level)
See Mermaid diagram below (core relationships). Full field details in 5.2 DDL. (Mermaid ERD omitted here for brevity in continuation; see full file.)

### 5.2 DDL (SQLite) — Core Tables

Create `qc_*` tables (namespaced to avoid collision). Use UTC ISO8601 (`yyyy-MM-ddTHH:mm:ss.sssZ` or `AppDates`).

#### qc_sops
```sql
CREATE TABLE IF NOT EXISTS qc_sops (
  sop_id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  category TEXT,
  dept TEXT,
  site TEXT,
  status TEXT NOT NULL CHECK(status IN ("Draft","Pending","Approved","Published","Obsolete","Archived")) DEFAULT "Draft",
  content_type TEXT CHECK(content_type IN ("text","file")) DEFAULT "text",
  content_text TEXT,
  file_url TEXT,
  file_name TEXT,
  mime_type TEXT,
  rev_no INTEGER NOT NULL DEFAULT 0,
  effective_date TEXT,
  expiry_date TEXT,
  is_active INTEGER NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  owner_id TEXT,
  approver_id TEXT,
  approved_at TEXT,
  reviewed_at TEXT,
  rejection_reason TEXT,
  tags TEXT,
  criticality TEXT CHECK(criticality IN ("Low","Medium","High","Critical")) DEFAULT "Medium",
  view_roles TEXT,
  edit_roles TEXT,
  approve_roles TEXT,
  publish_roles TEXT,
  requires_read_ack INTEGER NOT NULL DEFAULT 1,
  read_ack_mandatory INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_by TEXT,
  updated_by TEXT,
  version_hash TEXT
);
CREATE INDEX IF NOT EXISTS idx_qc_sops_status ON qc_sops(status);
CREATE INDEX IF NOT EXISTS idx_qc_sops_dept ON qc_sops(dept);
CREATE INDEX IF NOT EXISTS idx_qc_sops_is_active ON qc_sops(is_active);
CREATE INDEX IF NOT EXISTS idx_qc_sops_code ON qc_sops(code);
```


#### qc_sop_revisions
```sql
CREATE TABLE IF NOT EXISTS qc_sop_revisions (
  rev_id INTEGER PRIMARY KEY AUTOINCREMENT,
  sop_id INTEGER NOT NULL,
  rev_no INTEGER NOT NULL,
  content_text TEXT,
  file_url TEXT,
  file_name TEXT,
  mime_type TEXT,
  change_reason TEXT NOT NULL,
  edited_by TEXT,
  edited_at TEXT NOT NULL,
  diff_summary TEXT,
  prev_rev_id_ref TEXT,
  content_hash TEXT,
  is_published_rev INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(sop_id) REFERENCES qc_sops(sop_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_qc_sop_revs_sop ON qc_sop_revisions(sop_id, rev_no);
```


#### qc_sop_reads
```sql
CREATE TABLE IF NOT EXISTS qc_sop_reads (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sop_id INTEGER NOT NULL,
  rev_no INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  user_name TEXT,
  read_at TEXT NOT NULL,
  signature_base64 TEXT,
  device_id TEXT,
  ip_address TEXT,
  geo TEXT,
  ack_method TEXT CHECK(ack_method IN ("manual","signature","biometric")) DEFAULT "manual",
  FOREIGN KEY(sop_id) REFERENCES qc_sops(sop_id) ON DELETE CASCADE,
  UNIQUE(sop_id, rev_no, user_id)
);
CREATE INDEX IF NOT EXISTS idx_qc_sop_reads_sop_rev ON qc_sop_reads(sop_id, rev_no);
CREATE INDEX IF NOT EXISTS idx_qc_sop_reads_user ON qc_sop_reads(user_id);
```


#### qc_sop_audits (append-only)
```sql
CREATE TABLE IF NOT EXISTS qc_sop_audits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sop_id INTEGER,
  rev_no INTEGER,
  action TEXT NOT NULL,
  entity TEXT CHECK(entity IN ("SOP","SOP_REV","SOP_READ","APPROVAL")) DEFAULT "SOP",
  by_user_id TEXT,
  by_user_name TEXT,
  at TEXT NOT NULL,
  meta_json TEXT,
  prev_hash TEXT,
  hash TEXT,
  immutable INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_qc_sop_audits_sop ON qc_sop_audits(sop_id);
```


#### qc_templates
```sql
CREATE TABLE IF NOT EXISTS qc_templates (
  template_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  code TEXT UNIQUE,
  type TEXT CHECK(type IN ("Incoming","InProcess","Final","Packing","Process","RawMaterial","FinishedGoods","Calibration","Other")) DEFAULT "Other",
  dept TEXT,
  site TEXT,
  category TEXT,
  description TEXT,
  version INTEGER NOT NULL DEFAULT 1,
  is_published INTEGER NOT NULL DEFAULT 0,
  is_archived INTEGER NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  requires_approval_on_submit INTEGER NOT NULL DEFAULT 0,
  allow_na INTEGER NOT NULL DEFAULT 1,
  enforce_evidence_on_fail INTEGER NOT NULL DEFAULT 1,
  block_submit_if_critical_fail INTEGER NOT NULL DEFAULT 1,
  owner_id TEXT,
  published_by TEXT,
  published_at TEXT,
  effective_date TEXT,
  expiry_date TEXT,
  tags TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_by TEXT,
  updated_by TEXT,
  revision_note TEXT
);
CREATE INDEX IF NOT EXISTS idx_qc_templates_pub ON qc_templates(is_published, is_deleted, is_archived);
CREATE INDEX IF NOT EXISTS idx_qc_templates_dept ON qc_templates(dept);
```


#### qc_sections
```sql
CREATE TABLE IF NOT EXISTS qc_sections (
  section_id INTEGER PRIMARY KEY AUTOINCREMENT,
  template_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  order_index INTEGER NOT NULL DEFAULT 0,
  is_collapsible INTEGER NOT NULL DEFAULT 1,
  required_all INTEGER NOT NULL DEFAULT 0,
  conditional_rule_json TEXT,
  FOREIGN KEY(template_id) REFERENCES qc_templates(template_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_qc_sections_tpl ON qc_sections(template_id, order_index);
```


#### qc_items
```sql
CREATE TABLE IF NOT EXISTS qc_items (
  item_id INTEGER PRIMARY KEY AUTOINCREMENT,
  section_id INTEGER NOT NULL,
  template_id INTEGER NOT NULL,
  label TEXT NOT NULL,
  item_type TEXT CHECK(item_type IN ("bool","passfail","na","text","number","date","dropdown","multiselect","photo","signature")) DEFAULT "passfail",
  order_index INTEGER NOT NULL DEFAULT 0,
  required INTEGER NOT NULL DEFAULT 1,
  allow_na INTEGER NOT NULL DEFAULT 1,
  is_critical INTEGER NOT NULL DEFAULT 0,
  require_evidence_if_fail INTEGER NOT NULL DEFAULT 1,
  require_evidence_if_value INTEGER NOT NULL DEFAULT 0,
  default_value TEXT,
  options_json TEXT,
  unit TEXT,
  min_value REAL,
  max_value REAL,
  tolerance REAL,
  tolerance_type TEXT CHECK(tolerance_type IN ("abs","pct")) DEFAULT "abs",
  validation_rule_json TEXT,
  conditional_show_json TEXT,
  fail_trigger_json TEXT,
  help_text TEXT,
  defect_code TEXT,
  FOREIGN KEY(section_id) REFERENCES qc_sections(section_id) ON DELETE CASCADE,
  FOREIGN KEY(template_id) REFERENCES qc_templates(template_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_qc_items_sec ON qc_items(section_id, order_index);
CREATE INDEX IF NOT EXISTS idx_qc_items_tpl ON qc_items(template_id);
```


#### qc_inspections
```sql
CREATE TABLE IF NOT EXISTS qc_inspections (
  inspection_id INTEGER PRIMARY KEY AUTOINCREMENT,
  template_id INTEGER NOT NULL,
  ref_type TEXT CHECK(ref_type IN ("Job","Batch","Lot","PO","GRN","Material","WIP","FG","Order","Other")) DEFAULT "Other",
  ref_id TEXT,
  lot_no TEXT,
  batch_no TEXT,
  po_no TEXT,
  grn_no TEXT,
  qty_inspected REAL,
  qty_unit TEXT,
  location TEXT,
  line TEXT,
  work_center TEXT,
  status TEXT CHECK(status IN ("InProgress","Submitted","Reviewed","Approved","Rejected","Closed")) DEFAULT "InProgress",
  result_overall TEXT CHECK(result_overall IN ("Pass","Conditional","Fail","Pending")) DEFAULT "Pending",
  score_pct REAL,
  has_nc INTEGER NOT NULL DEFAULT 0,
  nc_count INTEGER NOT NULL DEFAULT 0,
  critical_nc_count INTEGER NOT NULL DEFAULT 0,
  major_nc_count INTEGER NOT NULL DEFAULT 0,
  minor_nc_count INTEGER NOT NULL DEFAULT 0,
  inspector_id TEXT,
  inspector_name TEXT,
  reviewer_id TEXT,
  reviewer_name TEXT,
  approved_by TEXT,
  approved_by_name TEXT,
  submitted_at TEXT,
  reviewed_at TEXT,
  approved_at TEXT,
  rejected_at TEXT,
  closed_at TEXT,
  inspection_date TEXT NOT NULL,
  start_at TEXT,
  end_at TEXT,
  shift TEXT,
  remarks TEXT,
  review_comments TEXT,
  rejection_reason TEXT,
  sync_state TEXT CHECK(sync_state IN ("pending","synced","failed")) DEFAULT "pending",
  is_deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_by TEXT,
  updated_by TEXT,
  FOREIGN KEY(template_id) REFERENCES qc_templates(template_id)
);
CREATE INDEX IF NOT EXISTS idx_qc_insps_tpl ON qc_inspections(template_id);
CREATE INDEX IF NOT EXISTS idx_qc_insps_status ON qc_inspections(status);
CREATE INDEX IF NOT EXISTS idx_qc_insps_date ON qc_inspections(inspection_date);
CREATE INDEX IF NOT EXISTS idx_qc_insps_ref ON qc_inspections(ref_type, ref_id);
CREATE INDEX IF NOT EXISTS idx_qc_insps_inspector ON qc_inspections(inspector_id);
CREATE INDEX IF NOT EXISTS idx_qc_insps_sync ON qc_inspections(sync_state);
```


#### qc_responses
```sql
CREATE TABLE IF NOT EXISTS qc_responses (
  resp_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inspection_id INTEGER NOT NULL,
  item_id INTEGER NOT NULL,
  section_id INTEGER,
  result TEXT CHECK(result IN ("Pass","Fail","NA")) NOT NULL,
  value TEXT,
  value_type TEXT,
  notes TEXT,
  photos_json TEXT,
  signature_base64 TEXT,
  measured_at TEXT,
  measured_value REAL,
  defect_code TEXT,
  is_critical_failure INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(inspection_id) REFERENCES qc_inspections(inspection_id) ON DELETE CASCADE,
  FOREIGN KEY(item_id) REFERENCES qc_items(item_id)
);
CREATE INDEX IF NOT EXISTS idx_qc_resps_insp ON qc_responses(inspection_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_qc_resps_insp_item ON qc_responses(inspection_id, item_id);
```


#### qc_findings_nc
```sql
CREATE TABLE IF NOT EXISTS qc_findings_nc (
  finding_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inspection_id INTEGER NOT NULL,
  item_id INTEGER,
  resp_id INTEGER,
  code TEXT,
  severity TEXT CHECK(severity IN ("Minor","Major","Critical")) NOT NULL,
  category TEXT,
  description TEXT NOT NULL,
  status TEXT CHECK(status IN ("Open","Assigned","InProgress","Verified","Closed","Rejected")) DEFAULT "Open",
  type TEXT CHECK(type IN ("NonConformance","Observation","Deviation")) DEFAULT "NonConformance",
  due_date TEXT,
  assigned_to TEXT,
  assigned_to_name TEXT,
  assigned_at TEXT,
  root_cause TEXT,
  action_plan TEXT,
  proposed_action TEXT,
  verified_by TEXT,
  verified_by_name TEXT,
  verified_at TEXT,
  closed_at TEXT,
  rejected_at TEXT,
  rejection_reason TEXT,
  evidence_json TEXT,
  capa_id INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_by TEXT,
  updated_by TEXT,
  FOREIGN KEY(inspection_id) REFERENCES qc_inspections(inspection_id) ON DELETE CASCADE,
  FOREIGN KEY(resp_id) REFERENCES qc_responses(resp_id)
);
CREATE INDEX IF NOT EXISTS idx_qc_findings_insp ON qc_findings_nc(inspection_id);
CREATE INDEX IF NOT EXISTS idx_qc_findings_status ON qc_findings_nc(status);
CREATE INDEX IF NOT EXISTS idx_qc_findings_sev ON qc_findings_nc(severity);
```


#### qc_capa
```sql
CREATE TABLE IF NOT EXISTS qc_capa (
  capa_id INTEGER PRIMARY KEY AUTOINCREMENT,
  finding_id INTEGER NOT NULL,
  capa_no TEXT UNIQUE,
  type TEXT CHECK(type IN ("Corrective","Preventive","CorrectivePreventive")) DEFAULT "Corrective",
  title TEXT,
  description TEXT,
  root_cause TEXT,
  root_cause_method TEXT CHECK(root_cause_method IN ("5Why","Fishbone","Ishikawa","Other")) DEFAULT "Other",
  action_plan TEXT NOT NULL,
  action_steps_json TEXT,
  assigned_to TEXT,
  assigned_to_name TEXT,
  dept TEXT,
  status TEXT CHECK(status IN ("Open","InProgress","ActionComplete","VerificationPending","VerifiedEffective","VerifiedIneffective","Closed","Rejected")) DEFAULT "Open",
  priority TEXT CHECK(priority IN ("Low","Medium","High","Critical")) DEFAULT "Medium",
  due_at TEXT,
  target_completion_at TEXT,
  action_completed_at TEXT,
  action_completed_by TEXT,
  action_completion_notes TEXT,
  verified_by TEXT,
  verified_by_name TEXT,
  verified_at TEXT,
  verification_notes TEXT,
  is_effective INTEGER NOT NULL DEFAULT 0,
  effectiveness_checked_at TEXT,
  effectiveness_notes TEXT,
  closure_notes TEXT,
  closed_at TEXT,
  closed_by TEXT,
  rejected_at TEXT,
  rejection_reason TEXT,
  evidence_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  created_by TEXT,
  updated_by TEXT,
  FOREIGN KEY(finding_id) REFERENCES qc_findings_nc(finding_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_qc_capa_finding ON qc_capa(finding_id);
CREATE INDEX IF NOT EXISTS idx_qc_capa_status ON qc_capa(status);
CREATE INDEX IF NOT EXISTS idx_qc_capa_due ON qc_capa(due_at);
CREATE INDEX IF NOT EXISTS idx_qc_capa_assigned ON qc_capa(assigned_to);
```


#### qc_audits (global append-only)
```sql
CREATE TABLE IF NOT EXISTS qc_audits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_type TEXT CHECK(entity_type IN ("SOP","SOP_REV","SOP_READ","TEMPLATE","SECTION","ITEM","INSPECTION","RESPONSE","FINDING","CAPA","APPROVAL")) NOT NULL,
  entity_id TEXT,
  action TEXT NOT NULL,
  by_user_id TEXT,
  by_user_name TEXT,
  at TEXT NOT NULL,
  before_json TEXT,
  after_json TEXT,
  meta_json TEXT,
  prev_hash TEXT,
  hash TEXT,
  immutable INTEGER NOT NULL DEFAULT 1,
  ip_address TEXT,
  device_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_qc_audits_entity ON qc_audits(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_qc_audits_at ON qc_audits(at);
```


#### qc_defect_codes (master)
```sql
CREATE TABLE IF NOT EXISTS qc_defect_codes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  category TEXT,
  severity TEXT CHECK(severity IN ("Minor","Major","Critical")) DEFAULT "Minor",
  default_type TEXT CHECK(default_type IN ("NonConformance","Observation","Deviation")) DEFAULT "NonConformance",
  suggested_capa TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  dept TEXT
);
CREATE INDEX IF NOT EXISTS idx_qc_defcodes_active ON qc_defect_codes(is_active);
```


**Notes on DDL**
- All timestamps use ISO8601 (UTC). Prefer `AppDates.nowUtcIso()` (if exists) or consistent format.
- `*_json` columns store small JSON (arrays/objects) to keep normalized tables + flexible UI (options, photos, actionSteps, evidence, conditional rules).
- Append-only: `qc_sop_audits` and `qc_audits` have `immutable=1` and hash chain fields (`prev_hash`, `hash`) — writes must never update existing rows (only INSERT). Hash payload = `{action,entityType,entityId,byUserId,at,beforeJson,afterJson,metaJson,prevHash}` (canonical JSON).
- Soft deletes: `is_deleted` + filters everywhere. Published SOPs/revisions remain immutable in content (new revision on edit).
- Single-active SOP: when publishing revision R, set previous published rev `is_published_rev=0`, current `is_published_rev=1`, `qc_sops.is_active=1`, `status=Published`, mark others `Obsolete` as appropriate (single active published).
- FK cascades on child rows (revisions/reads/responses/findings/capa). Templates/sections/items cascade on delete (soft-delete preferred over hard-delete for published/audited).

--- 

## 6. Domain Models (Dart)

Create immutable models (freezed or equatable). Suggested `freezed` + `json_serializable` if present in pubspec (check later) — otherwise `Equatable` + manual fromMap/toMap (match existing simple models style). Keep toMap/fromMap for DB (SQLite).

### Suggested Model Files
```text
lib/features/qc_manager/domain/models/
  qc_sop.dart
  qc_sop_revision.dart
  qc_sop_read.dart
  qc_sop_audit.dart
  qc_template.dart
  qc_section.dart
  qc_item.dart
  qc_inspection.dart
  qc_response.dart
  qc_finding_nc.dart
  qc_capa.dart
  qc_audit.dart
  qc_defect_code.dart
  enums.dart  (Status/Type/Severity/ItemType/Result)
```

Key enums (shared): `SopStatus {Draft,Pending,Approved,Published,Obsolete,Archived}`, `QcItemType {bool,passfail,na,text,number,date,dropdown,multiselect,photo,signature}`, `QcResult {Pass,Fail,NA}`, `QcOverall {Pass,Conditional,Fail,Pending}`, `NcSeverity {Minor,Major,Critical}`, `NcStatus {Open,Assigned,InProgress,Verified,Closed,Rejected}`, `CapaType {Corrective,Preventive,CorrectivePreventive}`, `CapaStatus {Open,InProgress,ActionComplete,VerificationPending,VerifiedEffective,VerifiedIneffective,Closed,Rejected}`.

Notes: store enums as strings in DB (CHECK + mapped).

--- 

## 7. Data Layer (Repositories + Data Sources)

Follow existing pattern (Repo interface + implementation + DB ops). Use `DatabaseHelper` for SQLite.

### 7.1 Repository Interfaces
```text
lib/features/qc_manager/domain/repositories/
  qc_sop_repository.dart
  qc_template_repository.dart
  qc_inspection_repository.dart
  qc_nc_capa_repository.dart
  qc_audit_repository.dart
```


--- 

## 20. Risks, Mitigations, Acceptance Criteria & Next Steps

### Risks
| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| DB migration conflicts (existing data) | High | Low | `IF NOT EXISTS`, preserve all existing tables, upgrade test on copy of DB, FK OFF during DDL then ON. |
| Photo storage size/offline | Med | Med | Compress images (quality/resize), thumbnails, local cache cleanup, size limits per item, warn on large. |
| Audit hash chain edge cases (clock skew, order) | Med | Low | Use server/UTC time, global sequence (id) + `at` + monotonic, canonical JSON, verify on export/read-only. |
| Scope creep vs existing Inspections | Low | Med | Strict separation (new `qc_manager`), no edits to `features/inspections/*`, reuse only shared DS/utils. |
| Performance on large templates/inspections | Low | Low | Lazy loading, ordered queries, pagination (reuse `AppPaginatedTable`), index coverage. |

### Acceptance Criteria (MVP Gate)
- [ ] Can create Draft SOP ? Submit ? Approve ? Publish. Single-active enforced. Read Ack recorded per rev (idempotent).
- [ ] Template published only with valid structure; edit published ? new version draft (copy).
- [ ] Start inspection from published template; required + critical + evidence validation blocks invalid submit.
- [ ] Fail critical item auto-creates NC (severity Critical), `blockSubmitIfCriticalFail` respected in review flow.
- [ ] CAPA 2-step closure + effectiveness verification required before closing NC/Inspection (per R14).
- [ ] Append-only audits, hash chain verifiable (no updates/deletes to audit rows).
- [ ] Soft deletes everywhere, filters exclude deleted by default.
- [ ] Offline drafts + submit work (no network required); UI uses DS only.

### Next Steps (Immediate)
1. Read `lib/core/database/database_helper.dart` (get current `_dbVersion`, `_onUpgrade`, table style).
2. Check `pubspec.yaml` for `pdf`, `printing`, `crypto` (add if missing).
3. Read `lib/router/app_router.dart` + `features/shell/*` to add QC routes/nav cleanly.
4. Create folder structure (P1 start) and implement in phase order P1?P8 first.
5. Write minimal unit tests later (validation + hash chain + overall calculation).

---

**Build Note:** This is build-ready. Follow existing conventions strictly, reuse Design System, avoid breaking existing features, and enforce immutable/compliance rules by default. All new code under `features/qc_manager/`. 

