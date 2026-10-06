import 'package:sqflite/sqflite.dart';

import '../../../core/database/database_helper.dart';
import '../domain/ncr_filters.dart';
import '../domain/ncr_kpis.dart';
import '../domain/ncr_report_repository.dart';
import '../domain/ncr_report_row.dart';

/// An opened database plus the named bind arguments for one statement.
///
/// A small class rather than a record because the caller merges two of these
/// (`{...filter.args, ...resolved.args}`) and a named record type makes that
/// merge read like something it is not.
class _Bound {
  _Bound(this.db, this.args);

  final Database db;
  final Map<String, Object?> args;
}

/// A WHERE fragment plus its named bind arguments, before any `:today` is added.
class _Clause {
  _Clause(this.where, this.args);

  final String where;
  final Map<String, Object?> args;
}

/// SQL implementation of the NCR projection (plan V6_ENHANCED §22.5).
///
/// Read-only by construction: nothing here writes, and the interface it
/// implements has no mutator.
///
/// Two deviations from the plan's sample SQL, both because the shipped schema
/// disagrees with the document:
///  * it filters `i.deleted_at IS NULL`, not `(i.is_deleted IS NULL OR
///    i.is_deleted=0)` - there is no `is_deleted` column on `qc_inspections`,
///    and querying it would raise "no such column" on every single call;
///  * it joins CAPA on `c.finding_id = fn.finding_id`, not `fn.capa_id`.
///
/// The second one is a correctness fix, not a preference. `qc_findings_nc.capa_id`
/// exists but nothing in the codebase ever populates it, so joining through it
/// silently drops every CAPA; `qc_capa.finding_id` is NOT NULL and is what
/// `QcNcCapaRepo` writes. `LEFT JOIN` on the foreign key, and the selection
/// coalesces `fn.capa_id` with the join key so the row's `capaId` is right
/// either way.
class QcNcReportRepo implements QcNcReportRepository {
  QcNcReportRepo({required this.dbHelper});

  final DatabaseHelper dbHelper;

  Future<Database> get _db => dbHelper.database;

  /// Columns every projection shares. Kept in one place so `list`, `kpis`,
  /// `agingBuckets` and `detail` cannot drift apart - a report whose cards and
  /// rows disagree about which findings exist is worse than no report.
  static const String _from = '''
FROM qc_findings_nc fn
LEFT JOIN qc_inspections i ON i.inspection_id = fn.inspection_id
LEFT JOIN qc_capa c ON c.finding_id = fn.finding_id AND c.deleted_at IS NULL
''';

  /// The dated measures the filters and KPIs are computed from.
  ///
  /// `substr(...,1,10)` trims the time of day so `due_date` (a bare date) can
  /// be compared against a timestamp column: `closed_at <= due_date` would
  /// otherwise fail for every closure made after midnight on its due date,
  /// under-reporting on-time closures by roughly half.
  static const String _measures = '''
  COALESCE(fn.closed_at, '') AS closed_at,
  COALESCE(fn.verified_at, '') AS verified_at,
  COALESCE(fn.due_date, '') AS due_date,
  COALESCE(fn.created_at, '') AS created_at,
  CASE
    WHEN fn.status NOT IN ('Closed', 'Rejected')
         AND fn.due_date IS NOT NULL AND fn.due_date <> ''
         AND substr(fn.due_date, 1, 10) < :today
      THEN 1 ELSE 0
  END AS is_overdue,
  CASE
    WHEN fn.status = 'Closed'
         AND fn.due_date IS NOT NULL AND fn.due_date <> ''
         AND substr(COALESCE(fn.closed_at, ''), 1, 10) <= substr(fn.due_date, 1, 10)
      THEN 1 ELSE 0
  END AS closed_on_time,
  CASE
    WHEN fn.verified_at IS NOT NULL AND fn.verified_at <> ''
      THEN CAST(julianday(substr(fn.verified_at, 1, 10)) - julianday(substr(fn.created_at, 1, 10)) AS INTEGER)
      ELSE NULL
  END AS days_to_verify,
  CASE
    WHEN fn.status = 'Closed' AND fn.closed_at IS NOT NULL AND fn.closed_at <> ''
      THEN CAST(julianday(substr(fn.closed_at, 1, 10)) - julianday(substr(fn.created_at, 1, 10)) AS INTEGER)
      ELSE NULL
  END AS days_to_close,
  CASE
    WHEN COALESCE(fn.closed_at, '') <> '' THEN substr(fn.closed_at, 1, 10)
    ELSE substr(COALESCE(fn.created_at, ''), 1, 10)
  END AS age_anchor,
  CASE
    WHEN COALESCE(fn.closed_at, '') <> ''
      THEN CAST(julianday(:today) - julianday(substr(fn.closed_at, 1, 10)) AS INTEGER)
    ELSE CAST(julianday(:today) - julianday(substr(fn.created_at, 1, 10)) AS INTEGER)
  END AS age_days,
  CASE WHEN c.capa_id IS NOT NULL AND c.status <> 'Rejected' THEN 1 ELSE 0 END AS capa_linked,
  CASE
    WHEN c.due_at IS NOT NULL AND c.due_at <> ''
         AND substr(c.due_at, 1, 10) < :today
         AND c.status NOT IN ('Closed', 'Rejected', 'VerifiedEffective')
      THEN 1 ELSE 0
  END AS capa_overdue
''';

  /// `today` is bound as a named parameter everywhere because the aging and
  /// overdue maths has to agree on one clock reading, and computing it three
  /// times in three statements is how a report ends up claiming a finding is 1
  /// day old on the dashboard and 2 days old in the table.
  Future<_Bound> _resolve(NcrFilters filters, {String? today}) async {
    final db = await _db;
    return _Bound(db, <String, Object?>{'today': today ?? _today()});
  }

  static String _today() => todayStamp();

  /// WHERE fragment + bind args shared by every query.
  ///
  /// An `assignedTo` entry is either an id or `"id|Name"` (the picker offers
  /// both), and matching both makes the filter work whichever the caller sends
  /// instead of silently returning nothing for the human-readable form.
  static _Clause _where(NcrFilters f) {
    final clauses = <String>[];
    final args = <String, Object?>{};

    // Soft-delete guard on the finding. The inspection side is handled by the
    // LEFT JOIN + `i.inspection_id IS NOT NULL` check below.
    clauses.add('fn.deleted_at IS NULL');

    void inClause(String column, Set<String> values, String key) {
      if (values.isEmpty) return;
      final cleaned = values.where((v) => v.trim().isNotEmpty).toList();
      if (cleaned.isEmpty) return;
      final keys = List.generate(cleaned.length, (n) => '$key$n');
      clauses.add('$column IN (${keys.map((k) => ':$k').join(',')})');
      for (var n = 0; n < cleaned.length; n++) {
        args[keys[n]] = cleaned[n];
      }
    }

    inClause('fn.status', f.statuses, 'status');
    inClause('fn.severity', f.severities, 'severity');
    inClause('fn.type', f.types, 'type');
    inClause('fn.category', f.categories, 'category');
    inClause('i.dept', f.depts, 'dept');
    inClause('i.inspector_id', f.inspectorIds, 'inspector');
    inClause('c.status', f.capaStatuses, 'capastatus');

    if (f.assignedTo.isNotEmpty) {
      final ids = <String>[];
      for (final raw in f.assignedTo) {
        final value = raw.trim();
        if (value.isEmpty) continue;
        final bar = value.indexOf('|');
        ids.add(bar >= 0 ? value.substring(0, bar) : value);
      }
      if (ids.isNotEmpty) {
        final keys = List.generate(ids.length, (n) => 'assignee$n');
        clauses.add('fn.assigned_to IN (${keys.map((k) => ':$k').join(',')})');
        for (var n = 0; n < ids.length; n++) {
          args[keys[n]] = ids[n];
        }
      }
    }

    if (f.lotNo.isNotEmpty) {
      clauses.add("COALESCE(i.lot_no, '') LIKE :lot");
      args['lot'] = '%${f.lotNo}%';
    }
    if (f.batchNo.isNotEmpty) {
      clauses.add("COALESCE(i.batch_no, '') LIKE :batch");
      args['batch'] = '%${f.batchNo}%';
    }
    if (f.poNo.isNotEmpty) {
      clauses.add("COALESCE(i.po_no, '') LIKE :po");
      args['po'] = '%${f.poNo}%';
    }
    if (f.refType.isNotEmpty) {
      clauses.add("COALESCE(i.ref_type, '') = :reftype");
      args['reftype'] = f.refType;
    }
    if (f.refId.isNotEmpty) {
      clauses.add("COALESCE(i.ref_id, '') LIKE :refid");
      args['refid'] = '%${f.refId}%';
    }

    // The date range is matched against the column the user picked, date-only
    // on both ends so `from=2026-09-01` includes everything that happened on
    // the 1st, whatever time it happened at.
    final column = switch (f.dateField) {
      NcrFilters.dateFieldInspection => "COALESCE(i.inspection_date, '')",
      NcrFilters.dateFieldClosed => "COALESCE(fn.closed_at, '')",
      _ => "COALESCE(fn.created_at, '')",
    };
    if (f.from.isNotEmpty) {
      clauses.add('substr($column, 1, 10) >= :date_from');
      args['date_from'] = f.from;
    }
    if (f.to.isNotEmpty) {
      clauses.add('substr($column, 1, 10) <= :date_to');
      args['date_to'] = f.to;
    }

    if (f.onlyOverdue) {
      clauses.add(
        "fn.status NOT IN ('Closed', 'Rejected') AND fn.due_date IS NOT NULL "
        "AND fn.due_date <> '' AND substr(fn.due_date, 1, 10) < :today",
      );
    }

    // A finding whose inspection was deleted is not reportable: the report's
    // entire value is the lot/batch/inspector context, and without it the row
    // is an anonymous NC that cannot be traced back to anything.
    clauses.add('i.inspection_id IS NOT NULL');
    clauses.add('i.deleted_at IS NULL');

    return _Clause(clauses.join(' AND '), args);
  }

  /// Rebinds `:name` placeholders into positional `?` marks, in the order they
  /// appear, and returns the values in that same order.
  ///
  /// Two reasons this is not a one-line `replaceAll`:
  ///  * sqflite's Dart VM build rejects `?NNN` but accepts a plain positional
  ///    list, so the named form used throughout the SQL has to be lowered;
  ///  * the scanner has to step over single-quoted literals. The repeat-offence
  ///    query builds keys like `'lot:' || i.lot_no`, and a naive search for `:`
  ///    would find the colon in that literal and either consume the wrong operand
  ///    or desynchronise every bind after it - which fails as "wrong numbers in
  ///    the report", not as a syntax error.
  ///
  /// Every placeholder in this file is named; a bare `?` is rejected rather than
  /// silently bound in the wrong position.
  Future<List<Map<String, dynamic>>> _query(
    Database db,
    String sql, {
    required Map<String, Object?> named,
  }) async {
    final ordered = <Object?>[];
    final out = StringBuffer();
    var i = 0;
    while (i < sql.length) {
      final ch = sql[i];

      if (ch == "'") {
        final end = _endOfLiteral(sql, i);
        out.write(sql.substring(i, end));
        i = end;
        continue;
      }

      if (ch == '?') {
        throw ArgumentError(
          'unbound positional placeholder in NCR query at offset $i; '
          'use a :name bind',
        );
      }

      if ((ch == ':' || ch == '@' || ch == r'$') &&
          i + 1 < sql.length &&
          _isNameChar(sql.codeUnitAt(i + 1))) {
        var j = i + 1;
        while (j < sql.length && _isNameChar(sql.codeUnitAt(j))) {
          j++;
        }
        final key = sql.substring(i + 1, j);
        ordered.add(named[key]);
        out.write('?');
        i = j;
        continue;
      }

      out.write(ch);
      i++;
    }

    return db.rawQuery(out.toString(), ordered);
  }

  static bool _isNameChar(int code) =>
      (code >= 0x30 && code <= 0x39) || // 0-9
      (code >= 0x41 && code <= 0x5A) || // A-Z
      (code >= 0x61 && code <= 0x7A) || // a-z
      code == 0x5F; // _

  /// Index just past the closing quote of the literal starting at [start].
  static int _endOfLiteral(String sql, int start) {
    var i = start + 1;
    while (i < sql.length) {
      if (sql[i] == "'") {
        // Doubled quote is an escaped quote, not the end of the literal.
        if (i + 1 < sql.length && sql[i + 1] == "'") {
          i += 2;
          continue;
        }
        return i + 1;
      }
      i++;
    }
    return sql.length;
  }

  static const String _select =
      '''
SELECT
  fn.finding_id, fn.inspection_id, fn.item_id, fn.resp_id,
  COALESCE(fn.code, '') AS code,
  COALESCE(fn.severity, '') AS severity,
  COALESCE(fn.category, '') AS category,
  COALESCE(fn.description, '') AS description,
  COALESCE(fn.status, '') AS status,
  COALESCE(fn.type, '') AS type,
  COALESCE(fn.qty_affected, -1) AS qty_affected,
  COALESCE(fn.qty_unit, '') AS qty_unit,
  COALESCE(fn.disposition, '') AS disposition,
  COALESCE(fn.evidence_json, '') AS evidence_json,
  COALESCE(fn.created_by, '') AS created_by,
  COALESCE(fn.updated_at, '') AS updated_at,
  COALESCE(fn.assigned_at, '') AS assigned_at,
  COALESCE(fn.root_cause, '') AS root_cause,
  COALESCE(fn.action_plan, '') AS action_plan,
  COALESCE(fn.verified_by, '') AS verified_by,
  COALESCE(fn.verified_by_name, '') AS verified_by_name,
  COALESCE(fn.rejected_at, '') AS rejected_at,
  COALESCE(fn.assigned_to_name, '') AS assigned_to_name,
  COALESCE(i.ref_type, '') AS inspection_ref_type,
  COALESCE(i.ref_id, '') AS inspection_ref_id,
  COALESCE(i.lot_no, '') AS lot_no,
  COALESCE(i.batch_no, '') AS batch_no,
  COALESCE(i.po_no, '') AS po_no,
  COALESCE(i.grn_no, '') AS grn_no,
  COALESCE(i.dept, '') AS dept,
  COALESCE(i.site, '') AS site,
  COALESCE(i.location, '') AS location,
  COALESCE(i.line, '') AS line,
  COALESCE(i.work_center, '') AS work_center,
  COALESCE(i.inspector_id, '') AS inspector_id,
  COALESCE(i.inspector_name, '') AS inspector_name,
  COALESCE(i.inspection_date, '') AS inspection_date,
  COALESCE(i.status, '') AS inspection_status,
  COALESCE(c.capa_no, '') AS capa_no,
  COALESCE(c.type, '') AS capa_type,
  COALESCE(c.status, '') AS capa_status,
  COALESCE(c.priority, '') AS capa_priority,
  COALESCE(c.due_at, '') AS capa_due_at,
  COALESCE(c.target_completion_at, '') AS capa_target_completion_at,
  COALESCE(c.action_completed_at, '') AS capa_action_completed_at,
  COALESCE(c.verified_at, '') AS capa_verified_at,
  COALESCE(c.closed_at, '') AS capa_closed_at,
  COALESCE(c.assigned_to, '') AS capa_assigned_to,
  COALESCE(c.assigned_to_name, '') AS capa_assigned_to_name,
  COALESCE(c.is_effective, 0) AS capa_is_effective,
  COALESCE(fn.capa_id, c.capa_id) AS capa_id,
  $_measures
$_from
''';

  @override
  Future<List<NcrReportRow>> list(
    NcrFilters filters, {
    int? limit,
    int? offset,
    String orderBy = 'finding_id',
    String orderDir = 'DESC',
  }) async {
    final resolved = await _resolve(filters);
    final filter = _where(filters);

    // Only these columns may drive ORDER BY. Interpolating a caller's string
    // straight into SQL is how a sort control turns into a data exfiltration
    // bug, and the report has no need for an expression sort. Each maps to an
    // already-qualified expression - `finding_id` alone is ambiguous once the
    // three tables are joined.
    const sortable = {
      'finding_id': 'fn.finding_id',
      'code': 'fn.code',
      'severity': 'fn.severity',
      'status': 'fn.status',
      'due_date': 'fn.due_date',
      'created_at': 'fn.created_at',
      'closed_at': 'fn.closed_at',
      'age_days': 'age_days',
      'inspection_date': 'i.inspection_date',
      'capa_no': 'c.capa_no',
    };
    final sortColumn = sortable[orderBy] ?? 'fn.finding_id';
    final dir = orderDir.toUpperCase() == 'ASC' ? 'ASC' : 'DESC';

    final rows = await _query(
      resolved.db,
      '''
$_select
WHERE ${filter.where}
ORDER BY $sortColumn $dir, fn.finding_id DESC
LIMIT :row_limit OFFSET :row_offset
''',
      named: {
        ...filter.args,
        ...resolved.args,
        'row_limit': (limit ?? filters.limit).clamp(1, 10000),
        'row_offset': (offset ?? filters.offset).clamp(0, 1 << 31),
      },
    );
    return [for (final row in rows) NcrReportRow.fromMap(row)];
  }

  @override
  Future<int> count(NcrFilters filters) async {
    final resolved = await _resolve(filters);
    final filter = _where(filters);
    final rows = await _query(
      resolved.db,
      'SELECT COUNT(*) AS cnt FROM qc_findings_nc fn '
      'LEFT JOIN qc_inspections i ON i.inspection_id = fn.inspection_id '
      'LEFT JOIN qc_capa c ON c.finding_id = fn.finding_id AND c.deleted_at IS NULL '
      'WHERE ${filter.where}',
      named: {...filter.args, ...resolved.args},
    );
    if (rows.isEmpty) return 0;
    final raw = rows.first['cnt'];
    return raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
  }

  /// The aggregate queries need the dated measures *before* they can sum over
  /// them, and SQLite does not allow a SELECT alias to be referenced by another
  /// expression in the same SELECT list. So the measures are computed once in a
  /// CTE and the aggregation runs over that.
  ///
  /// Deriving the shared WHERE fragment and the join into one string is also
  /// what guarantees the KPI cards and the table count the same population.
  String _base(NcrFilters filters) {
    final filter = _where(filters);
    return '''
WITH base AS (
  SELECT
    fn.finding_id,
    COALESCE(fn.status, '') AS status,
    COALESCE(fn.severity, '') AS severity,
$_measures
$_from
  WHERE ${filter.where}
)
''';
  }

  @override
  Future<NcrKpis> kpis(NcrFilters filters) async {
    final resolved = await _resolve(filters);
    final rows = await _query(
      resolved.db,
      '''
${_base(filters)}
SELECT
  COUNT(*) AS total,
  SUM(CASE WHEN base.status NOT IN ('Closed', 'Rejected') THEN 1 ELSE 0 END) AS open_count,
  SUM(CASE WHEN base.status = 'Assigned' THEN 1 ELSE 0 END) AS assigned_count,
  SUM(CASE WHEN base.status = 'InProgress' THEN 1 ELSE 0 END) AS in_progress_count,
  SUM(CASE WHEN base.status = 'Verified' THEN 1 ELSE 0 END) AS verified_count,
  SUM(CASE WHEN base.status = 'Closed' THEN 1 ELSE 0 END) AS closed_count,
  SUM(CASE WHEN base.status = 'Rejected' THEN 1 ELSE 0 END) AS rejected_count,
  SUM(CASE WHEN base.severity = 'Critical' THEN 1 ELSE 0 END) AS critical_count,
  SUM(CASE WHEN base.severity = 'Major' THEN 1 ELSE 0 END) AS major_count,
  SUM(CASE WHEN base.severity = 'Minor' THEN 1 ELSE 0 END) AS minor_count,
  SUM(base.is_overdue) AS overdue_count,
  SUM(base.closed_on_time) AS closed_on_time_count,
  SUM(CASE WHEN base.days_to_verify IS NOT NULL THEN 1 ELSE 0 END) AS verified_rows_count,
  SUM(base.capa_linked) AS capa_linked_count,
  SUM(base.capa_overdue) AS capa_overdue_count,
  AVG(CASE WHEN base.days_to_close IS NOT NULL AND base.days_to_close >= 0
    THEN base.days_to_close END) AS mttc_days,
  AVG(CASE WHEN base.days_to_verify IS NOT NULL AND base.days_to_verify >= 0
    THEN base.days_to_verify END) AS mttv_days
FROM base
''',
      named: {..._where(filters).args, ...resolved.args},
    );
    if (rows.isEmpty) return NcrKpis.empty;

    // A filter that matched nothing aggregates to one all-NULL row, which would
    // otherwise surface as a KPI block claiming a measured average of nothing.
    final kpis = NcrKpis.fromMap(Map<String, dynamic>.from(rows.first));
    return kpis.total == 0 ? NcrKpis.empty : kpis;
  }

  @override
  Future<NcrReportRow?> detail(int findingId) async {
    final resolved = await _resolve(const NcrFilters());
    // The scope comes from the shared fragment, not a hand-written WHERE. An
    // earlier version filtered only `fn.deleted_at`, so tapping a row whose
    // *inspection* had been deleted still opened a detail page - showing an NCR
    // with no lot, no batch and no inspector that the table itself would never
    // have listed. Same population, or it is not a detail view of that report.
    final scope = _where(const NcrFilters());
    final rows = await _query(
      resolved.db,
      '''
$_select
WHERE ${scope.where} AND fn.finding_id = :finding_id
LIMIT 1
''',
      named: {...scope.args, ...resolved.args, 'finding_id': findingId},
    );
    if (rows.isEmpty) return null;
    return NcrReportRow.fromMap(rows.first);
  }

  @override
  Future<List<NcrAgingBucket>> agingBuckets(NcrFilters filters) async {
    final resolved = await _resolve(filters);
    final rows = await _query(
      resolved.db,
      '''
${_base(filters)}
SELECT
  SUM(CASE WHEN base.age_days BETWEEN 0 AND 7 THEN 1 ELSE 0 END) AS b0,
  SUM(CASE WHEN base.age_days BETWEEN 8 AND 14 THEN 1 ELSE 0 END) AS b1,
  SUM(CASE WHEN base.age_days BETWEEN 15 AND 30 THEN 1 ELSE 0 END) AS b2,
  SUM(CASE WHEN base.age_days BETWEEN 31 AND 60 THEN 1 ELSE 0 END) AS b3,
  SUM(CASE WHEN base.age_days > 60 THEN 1 ELSE 0 END) AS b4
FROM base
''',
      named: {..._where(filters).args, ...resolved.args},
    );

    // Zero-filled: a missing band is reported as 0, never dropped.
    final map = rows.isEmpty ? const <String, dynamic>{} : rows.first;
    int band(Object? key) {
      final raw = map[key];
      return raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
    }

    return [
      NcrAgingBucket.d0to7(band('b0')),
      NcrAgingBucket.d8to14(band('b1')),
      NcrAgingBucket.d15to30(band('b2')),
      NcrAgingBucket.d31to60(band('b3')),
      NcrAgingBucket.over60(band('b4')),
    ];
  }

  @override
  Future<List<NcrTopDefect>> topDefects(
    NcrFilters filters, {
    int limit = 10,
  }) async {
    final resolved = await _resolve(filters);
    final rows = await _query(
      resolved.db,
      '''
WITH labelled AS (
  SELECT
    CASE
      WHEN COALESCE(fn.code, '') <> '' THEN fn.code
      WHEN COALESCE(fn.category, '') <> '' THEN fn.category
      ELSE '(uncoded)'
    END AS defect_label,
    COALESCE(fn.category, '') AS category,
    COALESCE(fn.severity, '') AS severity
$_from
  WHERE ${_where(filters).where}
)
SELECT
  defect_label AS code,
  MAX(category) AS category,
  COUNT(*) AS cnt,
  SUM(CASE WHEN severity = 'Critical' THEN 1 ELSE 0 END) AS critical_cnt
FROM labelled
-- Group by the computed label, not `fn.code`: SQLite resolves a GROUP BY
-- against the real column before the SELECT alias, so grouping by `code` would
-- silently bucket every uncoded finding together and then label that bucket
-- with whichever category happened to come first.
GROUP BY defect_label
ORDER BY cnt DESC, defect_label ASC
LIMIT :row_limit
''',
      named: {
        ..._where(filters).args,
        ...resolved.args,
        'row_limit': limit.clamp(1, 100),
      },
    );
    return [
      for (final row in rows)
        NcrTopDefect(
          code: '${row['code'] ?? ''}',
          category: '${row['category'] ?? ''}',
          count: _asInt(row['cnt']),
          criticalCount: _asInt(row['critical_cnt']),
        ),
    ];
  }

  @override
  Future<List<NcrRepeatRef>> repeatByRef(
    NcrFilters filters, {
    int limit = 10,
  }) async {
    final resolved = await _resolve(filters);
    final filter = _where(filters);
    final rows = await _query(
      resolved.db,
      '''
SELECT
  CASE
    WHEN COALESCE(i.lot_no, '') <> '' THEN 'lot:' || i.lot_no
    WHEN COALESCE(i.batch_no, '') <> '' THEN 'batch:' || i.batch_no
    WHEN COALESCE(i.ref_id, '') <> '' THEN 'ref:' || i.ref_id
    ELSE ''
  END AS ref_key,
  COALESCE(i.lot_no, '') AS lot_no,
  COALESCE(i.batch_no, '') AS batch_no,
  COALESCE(i.ref_id, '') AS ref_id,
  COUNT(*) AS cnt,
  SUM(CASE WHEN fn.status NOT IN ('Closed', 'Rejected') THEN 1 ELSE 0 END) AS open_count
$_from
WHERE ${filter.where}
GROUP BY ref_key
HAVING COUNT(*) > 1 AND ref_key <> ''
ORDER BY cnt DESC, ref_key ASC
LIMIT :row_limit
''',
      named: {
        ...filter.args,
        ...resolved.args,
        'row_limit': limit.clamp(1, 100),
      },
    );
    return [for (final row in rows) NcrRepeatRef.fromMap(row)];
  }

  @override
  Future<NcrFilterOptions> filterOptions() async {
    final resolved = await _resolve(const NcrFilters());
    final db = resolved.db;

    Future<List<String>> distinct(String sql) async {
      final rows = await db.rawQuery(sql);
      return [
        for (final row in rows)
          if ('${row.values.first}' != '') '${row.values.first}',
      ]..sort();
    }

    Future<List<({String id, String name})>> people(
      String idColumn,
      String nameColumn,
    ) async {
      final rows = await db.rawQuery('''
SELECT DISTINCT i.$idColumn AS id, COALESCE(NULLIF(i.$nameColumn, ''), i.$idColumn) AS name
FROM qc_inspections i
WHERE i.deleted_at IS NULL AND COALESCE(i.$idColumn, '') <> ''
''');
      return [
        for (final row in rows)
          (id: '${row['id'] ?? ''}', name: '${row['name'] ?? row['id'] ?? ''}'),
      ]..sort((a, b) => a.name.compareTo(b.name));
    }

    // Facets are drawn from the same population the report itself reports on: a
    // finding whose inspection was soft-deleted is excluded by `_where`, so
    // offering its category in the picker would only ever produce an empty
    // result set for the auditor who selects it.
    String findingScope(String column) =>
        'FROM qc_findings_nc fn '
        'JOIN qc_inspections i ON i.inspection_id = fn.inspection_id '
        'WHERE fn.deleted_at IS NULL AND i.deleted_at IS NULL '
        "AND COALESCE(fn.$column, '') <> ''";

    Future<List<String>> findingFacet(String column) async {
      final rows = await db.rawQuery(
        'SELECT DISTINCT fn.$column AS v ${findingScope(column)}',
      );
      return [
        for (final row in rows)
          if ('${row['v']}' != '') '${row['v']}',
      ]..sort();
    }

    Future<List<String>> inspectionFacet(String column) async {
      final rows = await db.rawQuery(
        'SELECT DISTINCT $column AS v FROM qc_inspections '
        "WHERE deleted_at IS NULL AND COALESCE($column, '') <> ''",
      );
      return [
        for (final row in rows)
          if ('${row['v']}' != '') '${row['v']}',
      ]..sort();
    }

    return NcrFilterOptions(
      statuses: await findingFacet('status'),
      severities: await findingFacet('severity'),
      types: await findingFacet('type'),
      categories: await findingFacet('category'),
      depts: await inspectionFacet('dept'),
      inspectors: await people('inspector_id', 'inspector_name'),
      assignees: await _findingAssignees(db),
      capaStatuses: await distinct(
        "SELECT DISTINCT status FROM qc_capa WHERE deleted_at IS NULL AND COALESCE(status,'') <> ''",
      ),
    );
  }

  static Future<List<({String id, String name})>> _findingAssignees(
    Database db,
  ) async {
    final rows = await db.rawQuery('''
SELECT DISTINCT fn.assigned_to AS id,
       COALESCE(NULLIF(fn.assigned_to_name, ''), fn.assigned_to) AS name
FROM qc_findings_nc fn
JOIN qc_inspections i ON i.inspection_id = fn.inspection_id
WHERE fn.deleted_at IS NULL AND i.deleted_at IS NULL
  AND COALESCE(fn.assigned_to, '') <> ''
''');
    return [
      for (final row in rows)
        (id: '${row['id'] ?? ''}', name: '${row['name'] ?? row['id'] ?? ''}'),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}
