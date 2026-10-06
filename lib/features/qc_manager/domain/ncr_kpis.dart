import 'package:equatable/equatable.dart';

/// Read-only KPI block for the NCR dashboard (plan V6_ENHANCED §22.3).
///
/// Every figure is scoped to the same filtered set the list shows, so the
/// headline numbers always describe the rows on screen. [empty] is what a
/// filter that matched nothing returns: zeros, not nulls, because "0 open
/// findings" is a real answer and "unknown" would be a worse one.
///
/// Three ratios ([onTimeClosurePct], [mttcDays], [mttvDays]) are nullable, and
/// that is deliberate - they are averages over an empty population, and
/// printing `0%` when nobody has ever closed an NCR would read as "every
/// closure we made was late".
class NcrKpis extends Equatable {
  const NcrKpis({
    this.total = 0,
    this.open = 0,
    this.assigned = 0,
    this.inProgress = 0,
    this.verified = 0,
    this.closed = 0,
    this.rejected = 0,
    this.critical = 0,
    this.major = 0,
    this.minor = 0,
    this.overdue = 0,
    this.closedOnTime = 0,
    this.verifiedRows = 0,
    this.capaLinked = 0,
    this.capaOverdue = 0,
    this.mttcDays,
    this.mttvDays,
  });

  /// The all-zero block a filter that matched nothing returns.
  static const NcrKpis empty = NcrKpis();

  /// Findings matching the filter. The denominator for every percentage below.
  final int total;

  final int open;
  final int assigned;
  final int inProgress;

  /// `Verified` but not yet closed - still unresolved, so [open] includes it.
  final int verified;
  final int closed;
  final int rejected;

  final int critical;
  final int major;
  final int minor;

  /// Unresolved (not `Closed`/`Rejected`) and past `due_date`.
  final int overdue;

  /// `Closed` on or before `due_date`. A closure with no due date does not count
  /// here - there was no date to meet.
  final int closedOnTime;

  /// Findings carrying a `verified_at`, i.e. the population behind [mttvDays].
  final int verifiedRows;

  /// Findings with a linked, non-rejected CAPA.
  final int capaLinked;

  /// CAPAs past `due_at` and not `Closed`/`Rejected`/`VerifiedEffective`.
  final int capaOverdue;

  /// Null when nothing was closed in range.
  ///
  /// Derived rather than stored, so a KPI block built by hand in a test or a
  /// widget agrees with one parsed from SQL. Storing it would let the two drift.
  double? get onTimeClosurePct =>
      closed == 0 ? null : (closedOnTime / closed) * 100;

  /// Mean days from creation to closure. Null when nothing was closed.
  final double? mttcDays;

  /// Mean days from creation to verification. Null when nothing was verified.
  final double? mttvDays;

  int get resolved => closed + rejected;

  /// Severity split, exactly one of which every finding belongs to.
  int get severityTotal => critical + major + minor;

  double get overduePct => total == 0 ? 0 : (overdue / total) * 100;

  double get capaCoveragePct => total == 0 ? 0 : (capaLinked / total) * 100;

  /// Critical share of the *open* backlog, which is the number a quality
  /// manager actually triages by - critical findings that were already closed
  /// are not work anyone is waiting on.
  double get criticalOpenPct => open == 0 ? 0 : (critical / open) * 100;

  /// The four cards the dashboard leads with (§22.6).
  int get cardOpen => open;

  int get cardOverdue => overdue;

  int get cardCritical => critical;

  /// `-1` would be a nonsense percentage; the card shows a dash instead.
  double? get cardOnTimePct => onTimeClosurePct;

  factory NcrKpis.fromMap(Map<String, dynamic> map) {
    final closedCount = _int(map['closed_count']) ?? _int(map['closed']) ?? 0;
    final verifiedCount =
        _int(map['verified_count']) ?? _int(map['verified']) ?? 0;
    return NcrKpis(
      total: _int(map['total']) ?? 0,
      open: _int(map['open_count']) ?? 0,
      assigned: _int(map['assigned_count']) ?? 0,
      inProgress: _int(map['in_progress_count']) ?? 0,
      verified: verifiedCount,
      closed: closedCount,
      rejected: _int(map['rejected_count']) ?? 0,
      critical: _int(map['critical_count']) ?? 0,
      major: _int(map['major_count']) ?? 0,
      minor: _int(map['minor_count']) ?? 0,
      overdue: _int(map['overdue_count']) ?? 0,
      closedOnTime: _int(map['closed_on_time_count']) ?? 0,
      verifiedRows: _int(map['verified_rows_count']) ?? verifiedCount,
      capaLinked: _int(map['capa_linked_count']) ?? 0,
      capaOverdue: _int(map['capa_overdue_count']) ?? 0,
      mttcDays: _double(map['mttc_days']),
      mttvDays: _double(map['mttv_days']),
    );
  }

  @override
  List<Object?> get props => [
    total,
    open,
    assigned,
    inProgress,
    verified,
    closed,
    rejected,
    critical,
    major,
    minor,
    overdue,
    closedOnTime,
    verifiedRows,
    capaLinked,
    capaOverdue,
    mttcDays,
    mttvDays,
  ];
}

/// One aging band (plan §22.3): 0-7, 8-14, 15-30, 31-60, >60 days.
class NcrAgingBucket extends Equatable {
  const NcrAgingBucket({
    required this.label,
    required this.minDays,
    required this.maxDays,
    required this.count,
  });

  /// 0-7 days.
  const NcrAgingBucket.d0to7(int count)
    : this(label: '0-7 days', minDays: 0, maxDays: 7, count: count);

  /// 8-14 days.
  const NcrAgingBucket.d8to14(int count)
    : this(label: '8-14 days', minDays: 8, maxDays: 14, count: count);

  /// 15-30 days.
  const NcrAgingBucket.d15to30(int count)
    : this(label: '15-30 days', minDays: 15, maxDays: 30, count: count);

  /// 31-60 days.
  const NcrAgingBucket.d31to60(int count)
    : this(label: '31-60 days', minDays: 31, maxDays: 60, count: count);

  /// 61+ days. [maxDays] is null because the band has no ceiling.
  const NcrAgingBucket.over60(int count)
    : this(label: '>60 days', minDays: 61, maxDays: null, count: count);

  /// The five bands, in report order, zero-filled.
  ///
  /// Zero-filling matters: a chart that silently drops an empty band implies
  /// the band does not exist, so "nothing has aged past 30 days" renders as a
  /// 3-bar chart that could equally be read as a truncated one.
  static const List<NcrAgingBucket> bands = [
    NcrAgingBucket.d0to7(0),
    NcrAgingBucket.d8to14(0),
    NcrAgingBucket.d15to30(0),
    NcrAgingBucket.d31to60(0),
    NcrAgingBucket.over60(0),
  ];

  final String label;
  final int minDays;

  /// Inclusive upper bound, or null when unbounded.
  final int? maxDays;
  final int count;

  bool contains(int days) =>
      days >= minDays && (maxDays == null || days <= maxDays!);

  @override
  List<Object?> get props => [label, minDays, maxDays, count];
}

/// A recurring defect code or category (plan §22.3 "Top Defects by code").
///
/// [code] wins over [category] when a finding carries both: the code is the
/// thing that gets grouped across unrelated inspections, the category is a
/// coarse label, and mixing the two in one ranking would double-count.
class NcrTopDefect extends Equatable {
  const NcrTopDefect({
    required this.code,
    required this.category,
    required this.count,
    this.criticalCount = 0,
  });

  final String code;
  final String category;
  final int count;
  final int criticalCount;

  /// The label a table shows, never empty: an unnamed defect is still a
  /// grouping, it just gets bucketed under `(uncoded)`.
  String get label => code.isNotEmpty
      ? code
      : category.isNotEmpty
      ? category
      : '(uncoded)';

  @override
  List<Object?> get props => [code, category, count, criticalCount];
}

/// A lot/batch/reference that drew more than one NCR (§22.3).
class NcrRepeatRef extends Equatable {
  const NcrRepeatRef({
    required this.refKey,
    required this.lotNo,
    required this.batchNo,
    required this.refId,
    required this.count,
    this.openCount = 0,
  });

  final String refKey;
  final String lotNo;
  final String batchNo;
  final String refId;
  final int count;
  final int openCount;

  factory NcrRepeatRef.fromMap(Map<String, dynamic> map) => NcrRepeatRef(
    refKey: '${map['ref_key'] ?? ''}',
    lotNo: '${map['lot_no'] ?? ''}',
    batchNo: '${map['batch_no'] ?? ''}',
    refId: '${map['ref_id'] ?? ''}',
    count: _int(map['cnt']) ?? _int(map['count']) ?? 0,
    openCount: _int(map['open_count']) ?? 0,
  );

  @override
  List<Object?> get props => [refKey, lotNo, batchNo, refId, count, openCount];
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v');
}

double? _double(Object? v) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}
