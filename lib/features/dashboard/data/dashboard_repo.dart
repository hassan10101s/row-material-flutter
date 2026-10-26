import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_dates.dart';
import '../domain/dashboard_analytics.dart' as analytics;
import '../domain/dashboard_kpis.dart';
import '../domain/dashboard_repository.dart';

/// Inspection dashboard analytics (port of the Vue dashboard computed + the
/// summary endpoints). All heavy lifting is done in SQL; aggregation mirrors
/// web/src/35_dashboard_history_reports.js.
class DashboardRepo implements DashboardRepository {
  final DatabaseHelper dbHelper;
  DashboardRepo({required this.dbHelper});

  Future<Database> get _db => dbHelper.database;

  static String _normalizeStatus(String? value) {
    switch (value) {
      case 'CONDITIONAL':
        return 'CONDITIONAL_APPROVAL';
      case 'PARTIAL':
        return 'PARTIAL_REJECTION';
      default:
        return value ?? '';
    }
  }

  /// Overlapping `_filtered` reads with identical filters share one query.
  ///
  /// `DashboardCubit.load` fires `summary()` and `dashboardBundle()` together
  /// and both funnel into `_filtered` with the same filter key: without this,
  /// every dashboard load transferred the full 12-column filtered row set
  /// across the single FFI isolate twice. Same pattern as
  /// `SyncEngine._currentFlight`: concurrent callers share the flight, and the
  /// entry clears on completion so sequential callers (fresh data after a
  /// write) always re-query. No TTL, no stale data — only overlapping calls
  /// coalesce.
  Future<List<Map<String, dynamic>>>? _filteredFlight;
  String? _filteredFlightKey;

  Future<List<Map<String, dynamic>>> _filtered({
    required String period,
    String? materialId,
    String? supplier,
    String? status,
  }) {
    final key = '$period|$materialId|$supplier|$status';
    final flight = _filteredFlight;
    if (flight != null && _filteredFlightKey == key) return flight;
    final next = _filteredQuery(
      period: period,
      materialId: materialId,
      supplier: supplier,
      status: status,
    );
    _filteredFlightKey = key;
    _filteredFlight = next;
    unawaited(
      next.then<void>(
        (_) {
          if (identical(_filteredFlight, next)) {
            _filteredFlight = null;
            _filteredFlightKey = null;
          }
        },
        onError: (_) {
          if (identical(_filteredFlight, next)) {
            _filteredFlight = null;
            _filteredFlightKey = null;
          }
        },
      ),
    );
    return next;
  }

  Future<List<Map<String, dynamic>>> _filteredQuery({
    required String period,
    String? materialId,
    String? supplier,
    String? status,
  }) async {
    final db = await _db;
    // Raw-material analytics only: production batches live in the same table
    // (`inspection_kind = 'product'`) and must not pollute material KPIs.
    // Tombstoned rows (soft-deleted for replication) are excluded everywhere:
    // the ledger hides them via aliveFilter, the dashboard must do the same
    // or totals stay wrong after a delete.
    final conditions = <String>[
      "inspection_kind = 'raw'",
      'deleted_at IS NULL',
    ];
    final args = <Object?>[];
    switch (period) {
      case '7d':
        conditions.add('inspection_date >= ?');
        args.add(
          DateTime.now()
              .subtract(const Duration(days: 7))
              .toIso8601String()
              .substring(0, 10),
        );
        break;
      case '30d':
        conditions.add('inspection_date >= ?');
        args.add(
          DateTime.now()
              .subtract(const Duration(days: 30))
              .toIso8601String()
              .substring(0, 10),
        );
        break;
      case '90d':
        conditions.add('inspection_date >= ?');
        args.add(
          DateTime.now()
              .subtract(const Duration(days: 90))
              .toIso8601String()
              .substring(0, 10),
        );
        break;
      case '365d':
        conditions.add('inspection_date >= ?');
        args.add(
          DateTime.now()
              .subtract(const Duration(days: 365))
              .toIso8601String()
              .substring(0, 10),
        );
        break;
    }
    if (materialId != null && materialId.isNotEmpty && materialId != 'ALL') {
      conditions.add('material_id = ?');
      args.add(int.tryParse(materialId) ?? -1);
    }
    if (supplier != null && supplier.isNotEmpty && supplier != 'ALL') {
      conditions.add('supplier = ?');
      args.add(supplier);
    }
    final normStatus = _normalizeStatus(status);
    if (normStatus.isNotEmpty && status != 'ALL' && status != '') {
      conditions.add('decision_status = ?');
      args.add(normStatus);
    }
    final where = conditions.isEmpty ? null : conditions.join(' AND ');
    final rows = await db.query(
      'inspections',
      columns: [
        'id',
        'entry_code',
        'material_id',
        'material_name',
        'inspection_date',
        'supplier',
        'quantity',
        'rejected_quantity',
        'follow_up_note',
        'expiry_date',
        'decision_version',
        'decision_status',
      ],
      where: where,
      whereArgs: where == null ? null : args,
      orderBy: 'inspection_date DESC, id DESC',
    );
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  /// Full inspection analytics object for the dashboard.
  @override
  Future<Map<String, dynamic>> summary({
    String period = '30d',
    String? materialId,
    String? supplier,
    String? status,
  }) async {
    final filtered = await _filtered(
      period: period,
      materialId: materialId,
      supplier: supplier,
      status: status,
    );

    var approved = 0, conditional = 0, partial = 0, rejected = 0;
    for (final i in filtered) {
      switch (_normalizeStatus('${i['decision_status'] ?? ''}')) {
        case 'APPROVED':
          approved++;
          break;
        case 'CONDITIONAL_APPROVAL':
          conditional++;
          break;
        case 'PARTIAL_REJECTION':
          partial++;
          break;
        case 'FULL_REJECTION':
          rejected++;
          break;
      }
    }
    final total = filtered.length;
    final approvalRate = total == 0
        ? '0.0'
        : ((approved / total) * 100).toStringAsFixed(1);
    final rejectionRate = total == 0
        ? '0.0'
        : (((rejected + partial) / total) * 100).toStringAsFixed(1);

    final materialStats = <String, Map<String, dynamic>>{};
    final supplierStats = <String, Map<String, dynamic>>{};
    final monthlyBuckets = <String, Map<String, dynamic>>{};
    Map<String, dynamic>? latest;
    for (final i in filtered) {
      final rawMat = '${i['material_name'] ?? ''}'.trim();
      final matName = rawMat.isEmpty
          ? AppText.t('غير محدد', 'Unspecified')
          : rawMat;
      final mat = materialStats.putIfAbsent(
        matName,
        () => {
          'name': matName,
          'total': 0,
          'approved': 0,
          'conditional': 0,
          'rejected': 0,
        },
      );
      mat['total'] = (mat['total'] as int) + 1;
      final rawSup = '${i['supplier'] ?? ''}'.trim();
      final supName = rawSup.isEmpty
          ? AppText.t('بدون مورد', 'No supplier')
          : rawSup;
      final sup = supplierStats.putIfAbsent(
        supName,
        () => {
          'name': supName,
          'total': 0,
          'approved': 0,
          'conditional': 0,
          'rejected': 0,
        },
      );
      sup['total'] = (sup['total'] as int) + 1;

      final date = '${i['inspection_date'] ?? ''}';
      final d = DateTime.tryParse(date);
      final s = _normalizeStatus('${i['decision_status'] ?? ''}');
      if (d != null) {
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        final buck = monthlyBuckets.putIfAbsent(
          key,
          () => {
            'year': d.year,
            'month': d.month,
            'total': 0,
            'approved': 0,
            'conditional': 0,
            'rejected': 0,
          },
        );
        buck['total'] = (buck['total'] as int) + 1;
        // FIX (was BUG PINNED in tests): monthly buckets previously counted
        // rows but never the per-status splits, so every bucket rendered
        // 0.0 rates and the MoM comparison/insight cards could never fire.
        if (s == 'APPROVED') {
          buck['approved'] = (buck['approved'] as int) + 1;
        } else if (s == 'CONDITIONAL_APPROVAL') {
          buck['conditional'] = (buck['conditional'] as int) + 1;
        } else if (s == 'FULL_REJECTION' || s == 'PARTIAL_REJECTION') {
          buck['rejected'] = (buck['rejected'] as int) + 1;
        }
      }

      if (s == 'APPROVED') {
        mat['approved'] = (mat['approved'] as int) + 1;
        sup['approved'] = (sup['approved'] as int) + 1;
      } else if (s == 'CONDITIONAL_APPROVAL') {
        mat['conditional'] = (mat['conditional'] as int) + 1;
        sup['conditional'] = (sup['conditional'] as int) + 1;
      } else if (s == 'FULL_REJECTION' || s == 'PARTIAL_REJECTION') {
        mat['rejected'] = (mat['rejected'] as int) + 1;
        sup['rejected'] = (sup['rejected'] as int) + 1;
      }

      if (latest == null ||
          (date.compareTo('${latest['inspection_date'] ?? ''}') > 0)) {
        latest = i;
      }
    }

    final topMaterials =
        materialStats.values
            .map(
              (m) => {
                ...m,
                'rate': (m['total'] as int) > 0
                    ? (((m['approved'] as int) / (m['total'] as int)) * 100)
                          .toStringAsFixed(1)
                    : '0.0',
              },
            )
            .toList()
          ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));
    if (topMaterials.length > 6) {
      topMaterials.removeRange(6, topMaterials.length);
    }

    final topSuppliers =
        supplierStats.values
            .map(
              (s) => {
                ...s,
                'approvalRate': (s['total'] as int) > 0
                    ? (((s['approved'] as int) / (s['total'] as int)) * 100)
                          .toStringAsFixed(1)
                    : '0.0',
              },
            )
            .toList()
          ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));
    if (topSuppliers.length > 6) {
      topSuppliers.removeRange(6, topSuppliers.length);
    }

    final monthlyTrend = _monthlyTrend(monthlyBuckets);

    final comparison = _comparison(monthlyTrend);
    final recommendations = _recommendations(
      total: total,
      rejectionRate: rejectionRate,
      conditional: conditional,
      topMaterials: topMaterials,
      topSuppliers: topSuppliers,
      approvalRate: approvalRate,
    );
    final insightCards = _insightCards(
      total: total,
      approvalRate: approvalRate,
      rejectionRate: rejectionRate,
      monthlyTrend: monthlyTrend,
    );

    return {
      'filtered_count': total,
      'totals': {
        'total': total,
        'approved': approved,
        'conditional': conditional,
        'partial': partial,
        'rejected': rejected,
        'approvalRate': approvalRate,
        'rejectionRate': rejectionRate,
      },
      'latest': latest == null
          ? {'label': AppText.t('لا يوجد', 'None'), 'date': ''}
          : {
              'label': '${latest['material_name'] ?? latest['entry_code']}',
              'date': '${latest['inspection_date'] ?? ''}',
            },
      'period': period,
      'topMaterials': topMaterials,
      'topSuppliers': topSuppliers,
      'monthlyTrend': monthlyTrend,
      'comparison': comparison,
      'recommendations': recommendations,
      'insightCards': insightCards,
    };
  }

  /// Today / shift KPIs for the top of the dashboard.
  ///
  /// Pure SQL: the old version transferred every matching `decision_status`
  /// across the isolate boundary to count them in Dart. The `CASE` sets mirror
  /// `_normalizeStatus` exactly (`CONDITIONAL`→approved bucket,
  /// `PARTIAL`→rejected bucket), and the day predicate stays an exact string
  /// match — a legacy timestamped `inspection_date` is invisible here by
  /// design (pinned in tests), same as before.
  @override
  Future<Map<String, dynamic>> todayKpis() async {
    final db = await _db;
    final today = todayIso();
    final settled = await Future.wait([
      db.rawQuery(
        'SELECT COUNT(*) AS t, '
        "SUM(CASE WHEN decision_status IN ('APPROVED','CONDITIONAL_APPROVAL','CONDITIONAL') THEN 1 ELSE 0 END) AS a, "
        "SUM(CASE WHEN decision_status IN ('FULL_REJECTION','PARTIAL_REJECTION','PARTIAL') THEN 1 ELSE 0 END) AS r "
        "FROM inspections WHERE inspection_kind = 'raw' AND deleted_at IS NULL AND inspection_date = ?",
        [today],
      ),
      db.rawQuery(
        "SELECT COUNT(*) AS c FROM inspections WHERE inspection_kind = 'raw' AND deleted_at IS NULL",
      ),
    ]);
    final day = settled[0].first;
    final totalCount = Sqflite.firstIntValue(settled[1]) ?? 0;
    return {
      'today_count': _int(day['t']),
      'today_approved': _int(day['a']),
      'today_rejected': _int(day['r']),
      'total_count': totalCount,
    };
  }

  List<Map<String, dynamic>> _monthlyTrend(
    Map<String, dynamic> monthlyBuckets,
  ) {
    final monthNames = {
      '01': AppText.t('يناير', 'Jan'),
      '02': AppText.t('فبراير', 'Feb'),
      '03': AppText.t('مارس', 'Mar'),
      '04': AppText.t('أبريل', 'Apr'),
      '05': AppText.t('مايو', 'May'),
      '06': AppText.t('يونيو', 'Jun'),
      '07': AppText.t('يوليو', 'Jul'),
      '08': AppText.t('أغسطس', 'Aug'),
      '09': AppText.t('سبتمبر', 'Sep'),
      '10': AppText.t('أكتوبر', 'Oct'),
      '11': AppText.t('نوفمبر', 'Nov'),
      '12': AppText.t('ديسمبر', 'Dec'),
    };
    final now = DateTime.now();
    final monthKeys = <String>[];
    final monthsPrior = ((monthlyBuckets.length) >= 6)
        ? monthlyBuckets.length
        : 6;
    for (var mi = monthsPrior - 1; mi >= 0; mi--) {
      final d = DateTime(now.year, now.month - mi, 1);
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      monthKeys.add(key);
    }
    return [
      for (final key in monthKeys)
        _buildMonthlyBucket(
          key,
          monthNames,
          monthlyBuckets[key] as Map<String, dynamic>?,
        ),
    ];
  }

  Map<String, dynamic> _buildMonthlyBucket(
    String key,
    Map<String, String> names,
    Map<String, dynamic>? b,
  ) {
    final total = (b?['total'] as int?) ?? 0;
    final approved = (b?['approved'] as int?) ?? 0;
    final conditional = (b?['conditional'] as int?) ?? 0;
    final rejected = (b?['rejected'] as int?) ?? 0;
    final approvalRate = total > 0
        ? ((approved / total) * 100).toStringAsFixed(1)
        : '0.0';
    final rejectionRate = total > 0
        ? (((rejected + conditional) / total) * 100).toStringAsFixed(1)
        : '0.0';
    return {
      'label': '${names[key.substring(5)] ?? ''} ${key.substring(0, 4)}',
      'total': total,
      'approved': approved,
      'conditional': conditional,
      'rejected': rejected,
      'approvalRate': approvalRate,
      'rejectionRate': rejectionRate,
      'approvedWidth': total > 0
          ? ((approved / total) * 100).toStringAsFixed(2)
          : '0',
      'conditionalWidth': total > 0
          ? ((conditional / total) * 100).toStringAsFixed(2)
          : '0',
      'rejectedWidth': total > 0
          ? ((rejected / total) * 100).toStringAsFixed(2)
          : '0',
    };
  }

  Map<String, dynamic> _comparison(List<Map<String, dynamic>> trend) {
    final sorted = [
      for (final m in trend)
        if ((m['total'] as int) > 0) m,
    ];
    if (sorted.length >= 2) {
      final latest = sorted.last;
      final prev = sorted[sorted.length - 2];
      final delta =
          double.parse('${latest['approvalRate']}') -
          double.parse('${prev['approvalRate']}');
      return {
        'approvalDeltaSign': delta >= 0 ? '+' : '',
        'approvalDelta': delta.abs().toStringAsFixed(1),
        'label': delta >= 0
            ? AppText.t(
                'أفضل من الشهر السابق (+${delta.abs().toStringAsFixed(1)}%)',
                'Better than last month (+${delta.abs().toStringAsFixed(1)}%)',
              )
            : AppText.t(
                'أقل من الشهر السابق (${delta.toStringAsFixed(1)}%)',
                'Lower than last month (${delta.toStringAsFixed(1)}%)',
              ),
      };
    } else if (sorted.length == 1) {
      return {
        'approvalDeltaSign': '+',
        'approvalDelta': '${sorted.first['approvalRate']}',
        'label': AppText.t('نسبة القبول هذا الشهر', 'Acceptance this month'),
      };
    }
    return {
      'approvalDeltaSign': '+',
      'approvalDelta': '0.0',
      'label': AppText.t('لا يوجد اتجاه بعد', 'No trend yet'),
    };
  }

  List<String> _recommendations({
    required int total,
    required String rejectionRate,
    required int conditional,
    required List<Map<String, dynamic>> topMaterials,
    required List<Map<String, dynamic>> topSuppliers,
    required String approvalRate,
  }) {
    final recommendations = <String>[];
    final worstMat = topMaterials
        .where((m) => double.parse('${m['rate']}') < 80)
        .firstOrNull;
    if (worstMat != null) {
      recommendations.add(
        AppText.t(
          'الخامة "${worstMat['name']}" قبولها ضعيف (${worstMat['rate']}%) — راجع المورد أو شروط القبول.',
          'Material "${worstMat['name']}" has low acceptance (${worstMat['rate']}%) — check the supplier or acceptance rules.',
        ),
      );
    }
    if (rejectionRate != '0.0' && double.parse(rejectionRate) > 15) {
      recommendations.add(
        AppText.t(
          'الرفض العام $rejectionRate% عالي (فوق 15%) — زوّد الفحص أو راجع الموردين.',
          'Overall rejection $rejectionRate% is high (above 15%) — inspect more or review suppliers.',
        ),
      );
    }
    if (conditional > 0) {
      recommendations.add(
        AppText.t(
          'عندك $conditional فحص مقبول بشرط — تابع الشروط المعلقة.',
          'You have $conditional conditionally accepted inspections — follow up the pending conditions.',
        ),
      );
    }
    final worstSup = topSuppliers
        .where((s) => double.parse('${s['approvalRate']}') < 70)
        .firstOrNull;
    if (worstSup != null) {
      recommendations.add(
        AppText.t(
          'المورد "${worstSup['name']}" قبوله ${worstSup['approvalRate']}% — اتكلم معاه في الجودة.',
          'Supplier "${worstSup['name']}" acceptance is ${worstSup['approvalRate']}% — talk quality with them.',
        ),
      );
    }
    if (recommendations.isEmpty && total > 0) {
      recommendations.add(
        AppText.t(
          'الوضع كويس — كمل بنفس الجودة.',
          'Things look good — keep the same quality.',
        ),
      );
    }
    return recommendations;
  }

  List<Map<String, dynamic>> _insightCards({
    required int total,
    required String approvalRate,
    required String rejectionRate,
    required List<Map<String, dynamic>> monthlyTrend,
  }) {
    final cards = <Map<String, dynamic>>[];
    if (total <= 0) return cards;
    final approvalPct = double.parse(approvalRate);
    if (approvalPct >= 90) {
      cards.add({
        'title': AppText.t('قبول ممتاز', 'Excellent acceptance'),
        'description': AppText.t(
          'القبول $approvalRate% — أداء ممتاز، حافظ عليه.',
          'Acceptance is $approvalRate% — great work, keep it up.',
        ),
        'tone': 'success',
      });
    } else if (approvalPct >= 70) {
      cards.add({
        'title': AppText.t('قبول معقول', 'Fair acceptance'),
        'description': AppText.t(
          'القبول $approvalRate% — راجع حالات الرفض وحسّنها.',
          'Acceptance is $approvalRate% — look at rejections and improve.',
        ),
        'tone': 'warning',
      });
    } else {
      cards.add({
        'title': AppText.t('قبول ضعيف', 'Weak acceptance'),
        'description': AppText.t(
          'القبول $approvalRate% فقط — يلزم تدخّل سريع ومراجعة الموردين.',
          'Acceptance is only $approvalRate% — act fast and review suppliers.',
        ),
        'tone': 'danger',
      });
    }
    final rejectPct = double.parse(rejectionRate);
    if (rejectPct > 20) {
      cards.add({
        'title': AppText.t('رفض عالي', 'High rejection'),
        'description': AppText.t(
          'الرفض $rejectionRate% — راجع الأسباب الأساسية.',
          'Rejection is $rejectionRate% — find the main causes.',
        ),
        'tone': 'danger',
      });
    } else if (rejectPct > 5) {
      cards.add({
        'title': AppText.t('رفض تحت السيطرة', 'Rejection under control'),
        'description': AppText.t(
          'الرفض $rejectionRate% — مقبول، لكن تابع باستمرار.',
          'Rejection is $rejectionRate% — okay but keep watching.',
        ),
        'tone': 'warning',
      });
    }
    final lastTwo = monthlyTrend.where((m) => (m['total'] as int) > 0).toList();
    if (lastTwo.length >= 2) {
      final trend =
          double.parse('${lastTwo[1]['approvalRate']}') -
          double.parse('${lastTwo[0]['approvalRate']}');
      if (trend > 5) {
        cards.add({
          'title': AppText.t('الأداء يتحسن', 'Getting better'),
          'description': AppText.t(
            'ارتفع القبول ${trend.abs().toStringAsFixed(1)}% مقارنة بالشهر السابق.',
            'Acceptance rose ${trend.abs().toStringAsFixed(1)}% vs last month.',
          ),
          'tone': 'success',
        });
      } else if (trend < -5) {
        cards.add({
          'title': AppText.t('الأداء يتراجع', 'Going down'),
          'description': AppText.t(
            'انخفض القبول ${trend.abs().toStringAsFixed(1)}% مقارنة بالشهر السابق.',
            'Acceptance dropped ${trend.abs().toStringAsFixed(1)}% vs last month.',
          ),
          'tone': 'danger',
        });
      }
    }
    return cards;
  }

  /// Dropdown options for materials and suppliers for dashboard filter bars.
  @override
  Future<DashboardFilterOptions> filterOptions() async {
    final db = await _db;
    // Parallel: two independent lookups (was sequential).
    final results = await Future.wait([
      db.query(
        'reference_materials',
        columns: ['id', 'material_name', 'material_code'],
        where: 'active = 1',
        orderBy: 'material_name ASC',
      ),
      db.rawQuery(
        "SELECT DISTINCT supplier FROM inspections WHERE inspection_kind = 'raw' AND deleted_at IS NULL AND supplier IS NOT NULL AND supplier != '' ORDER BY supplier ASC",
      ),
    ]);
    final matRows = results[0];
    final supRows = results[1];
    return DashboardFilterOptions(
      materials: [
        {'id': 'ALL', 'name': AppText.t('جميع الخامات', 'All materials')},
        for (final r in matRows)
          {
            'id': '${r['id']}',
            'name': '${r['material_name']} (${r['material_code']})',
          },
      ],
      suppliers: [
        {'id': 'ALL', 'name': AppText.t('جميع الموردين', 'All suppliers')},
        for (final r in supRows)
          {'id': '${r['supplier']}', 'name': '${r['supplier']}'},
      ],
      statuses: const [
        'ALL',
        'APPROVED',
        'CONDITIONAL_APPROVAL',
        'PARTIAL_REJECTION',
        'FULL_REJECTION',
      ],
    );
  }

  // ── Cross-module KPI bundle ──────────────────────────────────────
  // Every section is best-effort: a missing table yields zeros, never a
  // throw, so a fresh install (or a device that never opened QC) still gets
  // a dashboard. Inspection sections honour the active filters; NCR/lab/QC
  // sections honour `period` only (different dimensions).

  @override
  Future<DashboardBundle> dashboardBundle({
    String period = '30d',
    String? materialId,
    String? supplier,
    String? status,
  }) async {
    final db = await _db;
    final filtered = await _filtered(
      period: period,
      materialId: materialId,
      supplier: supplier,
      status: status,
    );
    final quality = _qualityKpis(filtered);
    // Parallelize the independent KPI sections (was 7 sequential awaits).
    // _volumeKpis needs `filtered` (in-memory) + db; the rest are db-only.
    final settled = await Future.wait([
      _volumeKpis(db, filtered),
      _labKpis(db, period),
      _qcCheckKpis(db, period),
      _ncrSummary(db),
      _sopKpis(db),
      _inventoryKpis(db),
      _trendPoints(db, period),
    ]);
    final volume = settled[0] as VolumeKpis;
    final lab = settled[1] as LabKpis;
    final qc = settled[2] as QcCheckKpis;
    final ncr = settled[3] as NcrKpisSummary;
    final sopGoals = settled[4] as SopKpis;
    final inventory = settled[5] as InventoryKpis;
    final trend = settled[6] as List<TrendPoint>;
    // ── Data-science layer (pure, filter-aware, never throws) ──────
    // Supplier scorecard + Pareto + data-quality read the filtered rows;
    // forecast/stability read the 6-month trend (volume + approval).
    List<SupplierScore> supplierScores = const [];
    List<ParetoEntry> materialPareto = const [];
    List<ParetoEntry> supplierPareto = const [];
    List<ForecastPoint> forecast = const [];
    StabilityKpis stability = const StabilityKpis();
    DataQualityKpis dataQuality = const DataQualityKpis();
    try {
      supplierScores = analytics.buildSupplierScores(filtered);
    } catch (_) {}
    try {
      materialPareto = analytics.buildPareto(
        filtered,
        (r) => '${r['material_name'] ?? ''}',
      );
    } catch (_) {}
    try {
      supplierPareto = analytics.buildPareto(
        filtered,
        (r) => '${r['supplier'] ?? ''}',
      );
    } catch (_) {}
    try {
      forecast = analytics.buildForecast(
        labels: [for (final t in trend) t.label],
        rates: [for (final t in trend) t.approvalRate],
        hasData: [for (final t in trend) t.total > 0],
      );
    } catch (_) {}
    try {
      stability = analytics.buildStability(
        [for (final t in trend) t.approvalRate],
        [for (final t in trend) t.total > 0],
      );
    } catch (_) {}
    try {
      dataQuality = analytics.buildDataQuality(filtered);
    } catch (_) {}
    return DashboardBundle(
      volume: volume,
      quality: quality,
      lab: lab,
      qc: qc,
      ncr: ncr,
      sopGoals: sopGoals,
      inventory: inventory,
      trend: trend,
      supplierScores: supplierScores,
      materialPareto: materialPareto,
      supplierPareto: supplierPareto,
      forecast: forecast,
      stability: stability,
      dataQuality: dataQuality,
    );
  }

  static double _round1(double v) => (v * 10).round() / 10.0;

  static double _num(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? 0.0;
  }

  static int _int(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  final Map<String, bool> _tableExistsCache = {};

  Future<bool> _hasTable(Database db, String table) async {
    final cached = _tableExistsCache[table];
    if (cached != null) return cached;
    try {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [table],
      );
      final exists = rows.isNotEmpty;
      _tableExistsCache[table] = exists;
      return exists;
    } catch (_) {
      return false;
    }
  }

  /// Test hook: schema changes invalidate the sqlite_master cache.
  void clearTableCache() => _tableExistsCache.clear();

  String? _cutoffFor(String period) {
    final now = DateTime.now();
    switch (period) {
      case '7d':
        return _day(now.subtract(const Duration(days: 7)));
      case '30d':
        return _day(now.subtract(const Duration(days: 30)));
      case '90d':
        return _day(now.subtract(const Duration(days: 90)));
      case '365d':
        return _day(now.subtract(const Duration(days: 365)));
      default:
        return null;
    }
  }

  String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _today() => _day(DateTime.now());

  Future<VolumeKpis> _volumeKpis(
    Database db,
    List<Map<String, dynamic>> filtered,
  ) async {
    var pending = 0, followUps = 0;
    for (final i in filtered) {
      final s = '${i['decision_status'] ?? ''}'.trim();
      if (s.isEmpty) pending++;
      final norm = _normalizeStatus(s);
      if (norm == 'CONDITIONAL_APPROVAL') {
        final note = '${i['follow_up_note'] ?? ''}'.trim();
        if (note.isNotEmpty) followUps++;
      }
    }
    // Four independent reads, one wait instead of four sequential round trips
    // on the single FFI isolate. Fallbacks preserve the old sequential
    // semantics exactly (follow-ups fall back to the in-memory count, total to
    // the filtered length, week average and today rows to zeros).
    // Follow-up note is not projected by _filtered; count it directly.
    final weekCutoff = _day(DateTime.now().subtract(const Duration(days: 6)));
    final settled = await Future.wait([
      db
          .rawQuery(
            "SELECT COUNT(*) AS c FROM inspections WHERE inspection_kind = 'raw' AND deleted_at IS NULL AND decision_status IN ('CONDITIONAL_APPROVAL','CONDITIONAL') AND COALESCE(follow_up_note,'') <> ''",
          )
          .then<Object?>((rows) => rows)
          .catchError((_) => null),
      db
          .rawQuery(
            'SELECT substr(inspection_date,1,10) AS d, COUNT(*) AS c FROM inspections '
            "WHERE inspection_kind = 'raw' AND deleted_at IS NULL AND inspection_date >= ? GROUP BY d",
            [weekCutoff],
          )
          .then<Object?>((rows) => rows)
          .catchError((_) => null),
      db
          .rawQuery(
            "SELECT COUNT(*) AS c FROM inspections WHERE inspection_kind = 'raw' AND deleted_at IS NULL",
          )
          .then<Object?>((rows) => rows)
          .catchError((_) => null),
      _todayRows(db),
    ]);
    final followRows = settled[0] as List<Map<String, Object?>>?;
    if (followRows != null && followRows.isNotEmpty) {
      followUps = _int(followRows.first['c']);
    }
    var weekAvg = 0.0;
    final weekRows = settled[1] as List<Map<String, Object?>>?;
    if (weekRows != null && weekRows.isNotEmpty) {
      var sum = 0;
      for (final r in weekRows) {
        sum += _int(r['c']);
      }
      weekAvg = sum / 7.0;
    }
    var total = filtered.length;
    final totalRows = settled[2] as List<Map<String, Object?>>?;
    if (totalRows != null && totalRows.isNotEmpty) {
      total = Sqflite.firstIntValue(totalRows) ?? filtered.length;
    }
    final todayRows = settled[3] as List<int>;
    return VolumeKpis(
      today: todayRows[0],
      todayApproved: todayRows[1],
      todayRejected: todayRows[2],
      total: total,
      pending: pending,
      openFollowUps: followUps,
      weekAvg: _round1(weekAvg),
    );
  }

  Future<List<int>> _todayRows(Database db) async {
    try {
      final today = _today();
      // Day range on the plain column instead of `substr(...)=?`: sargable, so
      // `idx_inspections_kind*` applies, and it matches both `YYYY-MM-DD` and
      // `YYYY-MM-DDTHH:MM:SS` storage (lexicographic ISO comparison).
      final tomorrow = _day(DateTime.now().add(const Duration(days: 1)));
      // Single aggregation instead of fetching every row + Dart loop.
      final row = (await db.rawQuery(
        'SELECT COUNT(*) AS t, '
        "SUM(CASE WHEN decision_status IN ('APPROVED','CONDITIONAL_APPROVAL','CONDITIONAL') THEN 1 ELSE 0 END) AS a, "
        "SUM(CASE WHEN decision_status IN ('FULL_REJECTION','PARTIAL_REJECTION','PARTIAL') THEN 1 ELSE 0 END) AS r "
        "FROM inspections WHERE inspection_kind = 'raw' AND deleted_at IS NULL AND inspection_date >= ? AND inspection_date < ?",
        [today, tomorrow],
      )).first;
      return [_int(row['t']), _int(row['a']), _int(row['r'])];
    } catch (_) {
      return [0, 0, 0];
    }
  }

  QualityKpis _qualityKpis(List<Map<String, dynamic>> filtered) {
    var approved = 0, conditional = 0, partial = 0, rejected = 0;
    var totalQty = 0.0, rejectedQty = 0.0, partialRejSum = 0.0;
    var versionSum = 0, reopened = 0, expiryRisk = 0, expired = 0;
    final today = _today();
    final soon = _day(DateTime.now().add(const Duration(days: 30)));
    for (final i in filtered) {
      final s = _normalizeStatus('${i['decision_status'] ?? ''}');
      final q = _num(i['quantity']);
      final rj = _num(i['rejected_quantity']);
      totalQty += q;
      switch (s) {
        case 'APPROVED':
          approved++;
          break;
        case 'CONDITIONAL_APPROVAL':
          conditional++;
          break;
        case 'PARTIAL_REJECTION':
          partial++;
          rejectedQty += rj;
          partialRejSum += rj;
          break;
        case 'FULL_REJECTION':
          rejected++;
          rejectedQty += q;
          break;
      }
      final v = _int(i['decision_version']);
      if (v > 0) {
        versionSum += v;
        if (v > 1) reopened++;
      }
      final exp = '${i['expiry_date'] ?? ''}';
      if (exp.length >= 10) {
        final day = exp.substring(0, 10);
        if (day.compareTo(today) < 0) {
          expired++;
        } else if (day.compareTo(soon) <= 0) {
          expiryRisk++;
        }
      }
    }
    final n = filtered.length;
    double pct(int c) => n == 0 ? 0.0 : _round1(c / n * 100);
    final acceptance = n == 0
        ? 0.0
        : _round1((approved + conditional) / n * 100);
    return QualityKpis(
      total: n,
      approved: approved,
      conditional: conditional,
      partial: partial,
      rejected: rejected,
      acceptanceRate: acceptance,
      strictRate: pct(approved),
      conditionalShare: pct(conditional),
      partialRate: pct(partial),
      fullRate: pct(rejected),
      rejectionRate: n == 0 ? 0.0 : _round1((partial + rejected) / n * 100),
      totalQty: totalQty,
      rejectedQty: rejectedQty,
      rejectedQtyRatio: totalQty <= 0
          ? 0.0
          : _round1(rejectedQty / totalQty * 100),
      avgRejectedPerPartial: partial == 0
          ? 0.0
          : _round1(partialRejSum / partial),
      churnAvg: n == 0 ? 0.0 : _round1(versionSum / n),
      reopened: reopened,
      expiryRisk: expiryRisk,
      expired: expired,
    );
  }

  Future<LabKpis> _labKpis(Database db, String period) async {
    if (!await _hasTable(db, 'lab_sample_tests')) return const LabKpis();
    try {
      final cutoff = _cutoffFor(period);
      // Plain-column range (ISO lexicographic): the old `substr(...)>=?`
      // defeated `idx_sample_tests_tested` on every dashboard bundle load.
      final where = cutoff == null ? null : 'tested_at >= ?';
      final args = cutoff == null ? null : [cutoff];
      // Parallel: total + evaluated + low-stock are independent.
      final hasInventory = await _hasTable(db, 'lab_inventory');
      final futures = <Future<Object?>>[
        db.rawQuery(
          'SELECT COUNT(*) AS c FROM lab_sample_tests${where == null ? '' : ' WHERE $where'}',
          args,
        ),
        db.rawQuery(
          "SELECT COUNT(*) AS c FROM lab_sample_tests WHERE COALESCE(result_text,'') <> ''${where == null ? '' : ' AND $where'}",
          args,
        ),
        if (hasInventory)
          db.rawQuery(
            'SELECT COUNT(*) AS c FROM lab_inventory WHERE current_qty < min_qty',
          ),
      ];
      final settled = await Future.wait(futures);
      final total =
          Sqflite.firstIntValue(settled[0] as List<Map<String, Object?>>) ?? 0;
      var evaluated = 0;
      try {
        evaluated =
            Sqflite.firstIntValue(settled[1] as List<Map<String, Object?>>) ??
            0;
      } catch (_) {}
      var low = 0;
      try {
        if (hasInventory && settled.length > 2) {
          low =
              Sqflite.firstIntValue(settled[2] as List<Map<String, Object?>>) ??
              0;
        }
      } catch (_) {}
      return LabKpis(
        totalTests: total,
        evaluated: evaluated,
        inRange: 0,
        outOfRange: 0,
        passRate: 0.0,
        lowStockCount: low,
      );
    } catch (_) {
      return const LabKpis();
    }
  }

  Future<QcCheckKpis> _qcCheckKpis(Database db, String period) async {
    if (!await _hasTable(db, 'qc_inspections')) return const QcCheckKpis();
    try {
      final cutoff = _cutoffFor(period);
      // Bound args (was string-interpolated) + sargable plain-column range:
      // `substr(COALESCE(...))` defeated `idx_qc_insps_date` and forced a full
      // scan of every QC inspection on each bundle load.
      List<Object?> qcArgs = const [];
      final where = cutoff == null
          ? "deleted_at IS NULL"
          : "deleted_at IS NULL AND (inspection_date >= ? OR created_at >= ?)";
      if (cutoff != null) qcArgs = [cutoff, cutoff];
      final rows = await db.rawQuery(
        'SELECT result_overall, score_pct, has_nc, critical_nc_count, major_nc_count, minor_nc_count FROM qc_inspections WHERE $where',
        qcArgs,
      );
      var pass = 0, cond = 0, fail = 0, pending = 0, hasNc = 0;
      var crit = 0, maj = 0, min = 0, scoreSum = 0.0, scored = 0;
      for (final r in rows) {
        switch ('${r['result_overall'] ?? ''}') {
          case 'Pass':
            pass++;
            break;
          case 'Conditional':
            cond++;
            break;
          case 'Fail':
            fail++;
            break;
          default:
            pending++;
        }
        if (_int(r['has_nc']) == 1) hasNc++;
        crit += _int(r['critical_nc_count']);
        maj += _int(r['major_nc_count']);
        min += _int(r['minor_nc_count']);
        final s = r['score_pct'];
        if (s != null && '$s'.isNotEmpty) {
          scoreSum += _num(s);
          scored++;
        }
      }
      final n = rows.length;
      return QcCheckKpis(
        total: n,
        pass: pass,
        conditional: cond,
        fail: fail,
        pending: pending,
        avgScore: scored == 0 ? 0.0 : _round1(scoreSum / scored),
        hasNc: hasNc,
        ncRate: n == 0 ? 0.0 : _round1(hasNc / n * 100),
        critical: crit,
        major: maj,
        minor: min,
      );
    } catch (_) {
      return const QcCheckKpis();
    }
  }

  Future<NcrKpisSummary> _ncrSummary(Database db) async {
    if (!await _hasTable(db, 'qc_findings_nc')) return const NcrKpisSummary();
    try {
      final today = _today();
      final row = (await db.rawQuery(
        '''
SELECT COUNT(*) AS total,
 SUM(CASE WHEN fn.status NOT IN ('Closed','Rejected') THEN 1 ELSE 0 END) AS open_c,
 SUM(CASE WHEN fn.status NOT IN ('Closed','Rejected') AND COALESCE(fn.due_date,'') <> '' AND substr(fn.due_date,1,10) < ? THEN 1 ELSE 0 END) AS overdue_c,
 SUM(CASE WHEN fn.severity='Critical' THEN 1 ELSE 0 END) AS crit_c,
 SUM(CASE WHEN fn.severity='Major' THEN 1 ELSE 0 END) AS maj_c,
 SUM(CASE WHEN fn.severity='Minor' THEN 1 ELSE 0 END) AS min_c,
 SUM(CASE WHEN fn.status='Closed' THEN 1 ELSE 0 END) AS closed_c,
 SUM(CASE WHEN fn.status='Closed' AND COALESCE(fn.due_date,'') <> '' AND substr(COALESCE(fn.closed_at,''),1,10) <= substr(fn.due_date,1,10) THEN 1 ELSE 0 END) AS ontime_c,
 AVG(CASE WHEN fn.status='Closed' AND COALESCE(fn.closed_at,'') <> '' THEN julianday(substr(fn.closed_at,1,10)) - julianday(substr(fn.created_at,1,10)) ELSE NULL END) AS mttc,
 AVG(CASE WHEN COALESCE(fn.verified_at,'') <> '' THEN julianday(substr(fn.verified_at,1,10)) - julianday(substr(fn.created_at,1,10)) ELSE NULL END) AS mttv
FROM qc_findings_nc fn WHERE fn.deleted_at IS NULL
''',
        [today],
      )).first;
      final hasCapa = await _hasTable(db, 'qc_capa');
      var linked = 0, capaOver = 0;
      final total = _int(row['total']);
      if (hasCapa && total > 0) {
        try {
          final c = (await db.rawQuery(
            '''
SELECT SUM(CASE WHEN c.capa_id IS NOT NULL AND c.status <> 'Rejected' THEN 1 ELSE 0 END) AS linked_c,
 SUM(CASE WHEN c.due_at IS NOT NULL AND c.due_at <> '' AND substr(c.due_at,1,10) < ? AND c.status NOT IN ('Closed','Rejected','VerifiedEffective') THEN 1 ELSE 0 END) AS over_c
FROM qc_findings_nc fn LEFT JOIN qc_capa c ON c.finding_id = fn.finding_id AND c.deleted_at IS NULL
WHERE fn.deleted_at IS NULL''',
            [today],
          )).first;
          linked = _int(c['linked_c']);
          capaOver = _int(c['over_c']);
        } catch (_) {}
      }
      final closed = _int(row['closed_c']);
      final ontime = _int(row['ontime_c']);
      final overdue = _int(row['overdue_c']);
      final mttc = row['mttc'] == null ? null : _num(row['mttc']);
      final mttv = row['mttv'] == null ? null : _num(row['mttv']);
      // Parallel: aging + top-defects are independent (was sequential).
      final extra = await Future.wait([
        _ncrAging(db, today),
        _ncrTopDefects(db),
      ]);
      final aging = extra[0] as List<int>;
      final defects = extra[1] as List<Map<String, dynamic>>;
      return NcrKpisSummary(
        total: total,
        open: _int(row['open_c']),
        overdue: overdue,
        overduePct: total == 0 ? 0.0 : _round1(overdue / total * 100),
        critical: _int(row['crit_c']),
        major: _int(row['maj_c']),
        minor: _int(row['min_c']),
        closed: closed,
        closedOnTime: ontime,
        onTimePct: closed == 0 ? null : _round1(ontime / closed * 100),
        mttcDays: mttc == null ? null : _round1(mttc),
        mttvDays: mttv == null ? null : _round1(mttv),
        capaLinked: linked,
        capaCoveragePct: total == 0 ? 0.0 : _round1(linked / total * 100),
        capaOverdue: capaOver,
        aging: aging,
        topDefects: defects,
      );
    } catch (_) {
      return const NcrKpisSummary();
    }
  }

  Future<List<int>> _ncrAging(Database db, String today) async {
    try {
      final rows = await db.rawQuery(
        '''
SELECT
 SUM(CASE WHEN age BETWEEN 0 AND 7 THEN 1 ELSE 0 END) AS b0,
 SUM(CASE WHEN age BETWEEN 8 AND 14 THEN 1 ELSE 0 END) AS b1,
 SUM(CASE WHEN age BETWEEN 15 AND 30 THEN 1 ELSE 0 END) AS b2,
 SUM(CASE WHEN age BETWEEN 31 AND 60 THEN 1 ELSE 0 END) AS b3,
 SUM(CASE WHEN age > 60 THEN 1 ELSE 0 END) AS b4
FROM (SELECT CAST(julianday(?) - julianday(substr(COALESCE(created_at,''),1,10)) AS INTEGER) AS age
 FROM qc_findings_nc WHERE deleted_at IS NULL AND status NOT IN ('Closed','Rejected'))''',
        [today],
      );
      final r = rows.first;
      return [
        _int(r['b0']),
        _int(r['b1']),
        _int(r['b2']),
        _int(r['b3']),
        _int(r['b4']),
      ];
    } catch (_) {
      return [0, 0, 0, 0, 0];
    }
  }

  Future<List<Map<String, dynamic>>> _ncrTopDefects(Database db) async {
    try {
      final rows = await db.rawQuery('''
SELECT COALESCE(NULLIF(TRIM(code),''), category, '(uncoded)') AS label,
 COUNT(*) AS cnt,
 SUM(CASE WHEN severity='Critical' THEN 1 ELSE 0 END) AS crit
FROM qc_findings_nc WHERE deleted_at IS NULL
GROUP BY label ORDER BY cnt DESC LIMIT 8''');
      return [
        for (final r in rows)
          {
            'label': '${r['label']}',
            'count': _int(r['cnt']),
            'critical': _int(r['crit']),
          },
      ];
    } catch (_) {
      return [];
    }
  }

  Future<SopKpis> _sopKpis(Database db) async {
    var sopTotal = 0, pub = 0, exp = 0, expSoon = 0, pend = 0;
    try {
      if (await _hasTable(db, 'qc_sops')) {
        final today = _today();
        final soon = _day(DateTime.now().add(const Duration(days: 30)));
        final r = (await db.rawQuery(
          '''
SELECT COUNT(*) AS t,
 SUM(CASE WHEN status='Published' THEN 1 ELSE 0 END) AS p,
 SUM(CASE WHEN status='Published' AND COALESCE(expiry_date,'') <> '' AND substr(expiry_date,1,10) < ? THEN 1 ELSE 0 END) AS e,
 SUM(CASE WHEN status='Published' AND COALESCE(expiry_date,'') <> '' AND substr(expiry_date,1,10) >= ? AND substr(expiry_date,1,10) <= ? THEN 1 ELSE 0 END) AS s,
 SUM(CASE WHEN status='Pending' THEN 1 ELSE 0 END) AS q
FROM qc_sops WHERE COALESCE(deleted_at,'') = '' ''',
          [today, today, soon],
        )).first;
        sopTotal = _int(r['t']);
        pub = _int(r['p']);
        exp = _int(r['e']);
        expSoon = _int(r['s']);
        pend = _int(r['q']);
      }
    } catch (_) {}
    return SopKpis(
      sopTotal: sopTotal,
      sopPublished: pub,
      sopExpired: exp,
      sopExpiring: expSoon,
      sopPending: pend,
    );
  }

  Future<InventoryKpis> _inventoryKpis(Database db) async {
    if (!await _hasTable(db, 'lab_inventory')) return const InventoryKpis();
    try {
      final row = (await db.rawQuery('''
SELECT COUNT(*) AS t,
 SUM(CASE WHEN current_qty <= 0 THEN 1 ELSE 0 END) AS e,
 SUM(CASE WHEN current_qty > 0 AND current_qty < min_qty THEN 1 ELSE 0 END) AS l
FROM lab_inventory''')).first;
      final t = _int(row['t']);
      final e = _int(row['e']);
      final l = _int(row['l']);
      var items = <Map<String, dynamic>>[];
      try {
        final rows = await db.rawQuery(
          'SELECT name, current_qty, min_qty, unit FROM lab_inventory WHERE current_qty < min_qty ORDER BY (min_qty - current_qty) DESC LIMIT 6',
        );
        items = [for (final r in rows) Map<String, dynamic>.from(r)];
      } catch (_) {}
      return InventoryKpis(
        skus: t,
        low: l,
        empty: e,
        ok: (t - l - e).clamp(0, t),
        lowItems: items,
      );
    } catch (_) {
      return const InventoryKpis();
    }
  }

  Future<List<TrendPoint>> _trendPoints(Database db, String period) async {
    try {
      final names = {
        '01': AppText.t('يناير', 'Jan'),
        '02': AppText.t('فبراير', 'Feb'),
        '03': AppText.t('مارس', 'Mar'),
        '04': AppText.t('أبريل', 'Apr'),
        '05': AppText.t('مايو', 'May'),
        '06': AppText.t('يونيو', 'Jun'),
        '07': AppText.t('يوليو', 'Jul'),
        '08': AppText.t('أغسطس', 'Aug'),
        '09': AppText.t('سبتمبر', 'Sep'),
        '10': AppText.t('أكتوبر', 'Oct'),
        '11': AppText.t('نوفمبر', 'Nov'),
        '12': AppText.t('ديسمبر', 'Dec'),
      };
      final now = DateTime.now();
      // Single GROUP BY for the 6-month window (was 6 sequential COUNTs).
      final first = DateTime(now.year, now.month - 5, 1);
      final firstKey =
          '${first.year}-${first.month.toString().padLeft(2, '0')}';
      final grouped = await db.rawQuery(
        "SELECT substr(inspection_date,1,7) AS m, COUNT(*) AS t, "
        "SUM(CASE WHEN decision_status='APPROVED' THEN 1 ELSE 0 END) AS a "
        "FROM inspections WHERE inspection_kind = 'raw' AND deleted_at IS NULL AND inspection_date >= ? GROUP BY m",
        ['$firstKey-01'],
      );
      final byMonth = <String, Map<String, int>>{
        for (final r in grouped)
          '${r['m']}': {'t': _int(r['t']), 'a': _int(r['a'])},
      };
      final out = <TrendPoint>[];
      for (var back = 5; back >= 0; back--) {
        final d = DateTime(now.year, now.month - back, 1);
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        final total = byMonth[key]?['t'] ?? 0;
        final approved = byMonth[key]?['a'] ?? 0;
        final rate = total == 0 ? 0.0 : _round1(approved / total * 100);
        out.add(
          TrendPoint(
            label: '${names[key.substring(5)] ?? key} ${key.substring(0, 4)}',
            total: total,
            approvalRate: rate,
            passRate: rate,
          ),
        );
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}
