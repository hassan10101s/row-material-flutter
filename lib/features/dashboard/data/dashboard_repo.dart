import 'package:sqflite/sqflite.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_dates.dart';
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

  Future<List<Map<String, dynamic>>> _filtered({
    required String period,
    String? materialId,
    String? supplier,
    String? status,
  }) async {
    final db = await _db;
    final conditions = <String>[];
    final args = <Object?>[];
    switch (period) {
      case '7d':
        conditions.add('inspection_date >= ?');
        args.add(DateTime.now().subtract(const Duration(days: 7)).toIso8601String().substring(0, 10));
        break;
      case '30d':
        conditions.add('inspection_date >= ?');
        args.add(DateTime.now().subtract(const Duration(days: 30)).toIso8601String().substring(0, 10));
        break;
      case '90d':
        conditions.add('inspection_date >= ?');
        args.add(DateTime.now().subtract(const Duration(days: 90)).toIso8601String().substring(0, 10));
        break;
      case '365d':
        conditions.add('inspection_date >= ?');
        args.add(DateTime.now().subtract(const Duration(days: 365)).toIso8601String().substring(0, 10));
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
    final rows = await db.query('inspections',
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
          'decision_status'
        ],
        where: where,
        whereArgs: where == null ? null : args,
        orderBy: 'inspection_date DESC, id DESC');
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
        period: period, materialId: materialId, supplier: supplier, status: status);

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
      final matName = '${i['material_name'] ?? 'غير محدد'}';
      final mat = materialStats.putIfAbsent(
          matName,
          () => {'name': matName, 'total': 0, 'approved': 0, 'conditional': 0, 'rejected': 0});
      mat['total'] = (mat['total'] as int) + 1;
      final supName = '${i['supplier'] ?? 'بدون مورد'}';
      final sup = supplierStats.putIfAbsent(
          supName,
          () => {'name': supName, 'total': 0, 'approved': 0, 'conditional': 0, 'rejected': 0});
      sup['total'] = (sup['total'] as int) + 1;

      final date = '${i['inspection_date'] ?? ''}';
      final d = DateTime.tryParse(date);
      final s = _normalizeStatus('${i['decision_status'] ?? ''}');
      if (d != null) {
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        final buck = monthlyBuckets.putIfAbsent(
            key,
            () =>
                {'year': d.year, 'month': d.month, 'total': 0, 'approved': 0, 'conditional': 0, 'rejected': 0});
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

      if (latest == null || (date.compareTo('${latest['inspection_date'] ?? ''}') > 0)) {
        latest = i;
      }
    }

    final topMaterials = materialStats.values
        .map((m) => {
              ...m,
              'rate': (m['total'] as int) > 0
                  ? (((m['approved'] as int) / (m['total'] as int)) * 100).toStringAsFixed(1)
                  : '0.0',
            })
        .toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));
    if (topMaterials.length > 6) topMaterials.removeRange(6, topMaterials.length);

    final topSuppliers = supplierStats.values
        .map((s) => {
              ...s,
              'approvalRate': (s['total'] as int) > 0
                  ? (((s['approved'] as int) / (s['total'] as int)) * 100).toStringAsFixed(1)
                  : '0.0',
            })
        .toList()
      ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));
    if (topSuppliers.length > 6) topSuppliers.removeRange(6, topSuppliers.length);

    final monthlyTrend = _monthlyTrend(monthlyBuckets);

    final comparison = _comparison(monthlyTrend);
    final recommendations = _recommendations(
        total: total,
        rejectionRate: rejectionRate,
        conditional: conditional,
        topMaterials: topMaterials,
        topSuppliers: topSuppliers,
        approvalRate: approvalRate);
    final insightCards = _insightCards(
        total: total,
        approvalRate: approvalRate,
        rejectionRate: rejectionRate,
        monthlyTrend: monthlyTrend);

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
          ? {'label': 'لا يوجد', 'date': ''}
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
  @override
  Future<Map<String, dynamic>> todayKpis() async {
    final db = await _db;
    final today = todayIso();
    var todayCount = 0, todayApproved = 0, todayRejected = 0;
    final rows = await db.query('inspections',
        columns: ['decision_status'], where: 'inspection_date = ?', whereArgs: [today]);
    for (final r in rows) {
      todayCount++;
      switch (_normalizeStatus('${r['decision_status'] ?? ''}')) {
        case 'APPROVED':
        case 'CONDITIONAL_APPROVAL':
          todayApproved++;
          break;
        case 'FULL_REJECTION':
        case 'PARTIAL_REJECTION':
          todayRejected++;
          break;
      }
    }
    final totalCount = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) AS c FROM inspections')) ??
        0;
    return {
      'today_count': todayCount,
      'today_approved': todayApproved,
      'today_rejected': todayRejected,
      'total_count': totalCount,
    };
  }

  List<Map<String, dynamic>> _monthlyTrend(
      Map<String, dynamic> monthlyBuckets) {
    const monthNames = {
      '01': 'يناير', '02': 'فبراير', '03': 'مارس', '04': 'أبريل',
      '05': 'مايو', '06': 'يونيو', '07': 'يوليو', '08': 'أغسطس',
      '09': 'سبتمبر', '10': 'أكتوبر', '11': 'نوفمبر', '12': 'ديسمبر',
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
        _buildMonthlyBucket(key, monthNames, monthlyBuckets[key] as Map<String, dynamic>?)
    ];
  }

  Map<String, dynamic> _buildMonthlyBucket(String key,
      Map<String, String> names, Map<String, dynamic>? b) {
    final total = (b?['total'] as int?) ?? 0;
    final approved = (b?['approved'] as int?) ?? 0;
    final conditional = (b?['conditional'] as int?) ?? 0;
    final rejected = (b?['rejected'] as int?) ?? 0;
    final approvalRate =
        total > 0 ? ((approved / total) * 100).toStringAsFixed(1) : '0.0';
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
      'approvedWidth':
          total > 0 ? ((approved / total) * 100).toStringAsFixed(2) : '0',
      'conditionalWidth':
          total > 0 ? ((conditional / total) * 100).toStringAsFixed(2) : '0',
      'rejectedWidth':
          total > 0 ? ((rejected / total) * 100).toStringAsFixed(2) : '0',
    };
  }

  Map<String, dynamic> _comparison(List<Map<String, dynamic>> trend) {
    final sorted = [for (final m in trend) if ((m['total'] as int) > 0) m];
    if (sorted.length >= 2) {
      final latest = sorted.last;
      final prev = sorted[sorted.length - 2];
      final delta = double.parse('${latest['approvalRate']}') -
          double.parse('${prev['approvalRate']}');
      return {
        'approvalDeltaSign': delta >= 0 ? '+' : '',
        'approvalDelta': delta.abs().toStringAsFixed(1),
        'label': delta >= 0
            ? 'تحسن عن الشهر السابق (+${delta.abs().toStringAsFixed(1)}%)'
            : 'انخفاض عن الشهر السابق (${delta.toStringAsFixed(1)}%)',
      };
    } else if (sorted.length == 1) {
      return {
        'approvalDeltaSign': '+',
        'approvalDelta': '${sorted.first['approvalRate']}',
        'label': 'نسبة القبول هذا الشهر',
      };
    }
    return {'approvalDeltaSign': '+', 'approvalDelta': '0.0', 'label': 'لا يوجد اتجاه بعد'};
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
    final worstMat =
        topMaterials.where((m) => double.parse('${m['rate']}') < 80).firstOrNull;
    if (worstMat != null) {
      recommendations.add(
          'خامة "${worstMat['name']}" معدل قبول منخفض (${worstMat['rate']}%) — يُنصح بمراجعة مصدر التوريد أو معايير القبول.');
    }
    if (rejectionRate != '0.0' && double.parse(rejectionRate) > 15) {
      recommendations.add(
          'نسبة الرفض العامة $rejectionRate% تتجاوز 15% — يُنصح بتكثيف الفحص أو تغيير الموردين.');
    }
    if (conditional > 0) {
      recommendations.add(
          '$conditional فحص بقبول مشروط — تأكد من متابعة الشروط المعلقة.');
    }
    final worstSup = topSuppliers
        .where((s) => double.parse('${s['approvalRate']}') < 70)
        .firstOrNull;
    if (worstSup != null) {
      recommendations.add(
          'المورد "${worstSup['name']}" معدل القبول ${worstSup['approvalRate']}% — يُنصح بتقييم الجودة معه.');
    }
    if (recommendations.isEmpty && total > 0) {
      recommendations.add('الأداء العام جيد — استمرار في معايير الجودة الحالية.');
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
        'title': 'معدل قبول ممتاز',
        'description': '$approvalRate% معدل القبول — الأداء يتجاوز المعايير المستهدفة.',
        'tone': 'success',
      });
    } else if (approvalPct >= 70) {
      cards.add({
        'title': 'معدل قبول مقبول',
        'description': '$approvalRate% معدل القبول — يمكن تحسينه بمراجعة حالات الرفض.',
        'tone': 'warning',
      });
    } else {
      cards.add({
        'title': 'معدل قبول منخفض',
        'description': '$approvalRate% فقط — يتطلب تدخلًا عاجلًا ومراجعة سلسلة التوريد.',
        'tone': 'danger',
      });
    }
    final rejectPct = double.parse(rejectionRate);
    if (rejectPct > 20) {
      cards.add({
        'title': 'نسبة رفض مرتفعة',
        'description': '$rejectionRate% من الفحوصات مرفوضة — يجب تحليل الأسباب الرئيسية.',
        'tone': 'danger',
      });
    } else if (rejectPct > 5) {
      cards.add({
        'title': 'نسبة رفض ضمن الحدود',
        'description': '$rejectionRate% رفض — ضمن الحدود لكن يحتاج مراقبة مستمرة.',
        'tone': 'warning',
      });
    }
    final lastTwo = monthlyTrend.where((m) => (m['total'] as int) > 0).toList();
    if (lastTwo.length >= 2) {
      final trend = double.parse('${lastTwo[1]['approvalRate']}') -
          double.parse('${lastTwo[0]['approvalRate']}');
      if (trend > 5) {
        cards.add({
          'title': 'اتجاه تحسن',
          'description': 'ارتفاع معدل القبول بـ ${trend.abs().toStringAsFixed(1)}% عن الشهر السابق.',
          'tone': 'success',
        });
      } else if (trend < -5) {
        cards.add({
          'title': 'اتجاه انخفاض',
          'description': 'انخفاض معدل القبول بـ ${trend.abs().toStringAsFixed(1)}% عن الشهر السابق.',
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
    final matRows = await db.query('reference_materials',
        columns: ['id', 'material_name', 'material_code'],
        where: 'active = 1',
        orderBy: 'material_name ASC');
    final supRows = await db.rawQuery(
        "SELECT DISTINCT supplier FROM inspections WHERE supplier IS NOT NULL AND supplier != '' ORDER BY supplier ASC");
    return DashboardFilterOptions(
      materials: [
        {'id': 'ALL', 'name': 'جميع الخامات'},
        for (final r in matRows)
          {'id': '${r['id']}', 'name': '${r['material_name']} (${r['material_code']})'}
      ],
      suppliers: [
        {'id': 'ALL', 'name': 'جميع الموردين'},
        for (final r in supRows)
          {'id': '${r['supplier']}', 'name': '${r['supplier']}'}
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
        period: period, materialId: materialId, supplier: supplier, status: status);
    final volume = await _volumeKpis(db, filtered);
    final quality = _qualityKpis(filtered);
    final lab = await _labKpis(db, period);
    final qc = await _qcCheckKpis(db, period);
    final ncr = await _ncrSummary(db);
    final sopGoals = await _sopGoalKpis(db);
    final inventory = await _inventoryKpis(db);
    final trend = await _trendPoints(db, period);
    return DashboardBundle(
      volume: volume,
      quality: quality,
      lab: lab,
      qc: qc,
      ncr: ncr,
      sopGoals: sopGoals,
      inventory: inventory,
      trend: trend,
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

  Future<bool> _hasTable(Database db, String table) async {
    try {
      final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

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
      Database db, List<Map<String, dynamic>> filtered) async {
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
    // Follow-up note is not projected by _filtered; count it directly.
    try {
      final rows = await db.rawQuery(
          "SELECT COUNT(*) AS c FROM inspections WHERE decision_status IN ('CONDITIONAL_APPROVAL','CONDITIONAL') AND COALESCE(follow_up_note,'') <> ''");
      followUps = _int(rows.first['c']);
    } catch (_) {}
    var weekAvg = 0.0;
    try {
      final counts = <int>[];
      for (var d = 0; d < 7; d++) {
        final day = _day(DateTime.now().subtract(Duration(days: d)));
        final r = await db.rawQuery(
            'SELECT COUNT(*) AS c FROM inspections WHERE substr(inspection_date,1,10) = ?',
            [day]);
        counts.add(_int(r.first['c']));
      }
      if (counts.isNotEmpty) {
        weekAvg = counts.reduce((a, b) => a + b) / counts.length;
      }
    } catch (_) {}
    var total = 0;
    try {
      total = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) AS c FROM inspections')) ??
          filtered.length;
    } catch (_) {
      total = filtered.length;
    }
    final todayRows = await _todayRows(db);
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
      final rows = await db.query('inspections',
          columns: ['decision_status'],
          where: 'substr(inspection_date,1,10) = ?',
          whereArgs: [today]);
      var approved = 0, rejected = 0;
      for (final r in rows) {
        switch (_normalizeStatus('${r['decision_status'] ?? ''}')) {
          case 'APPROVED':
          case 'CONDITIONAL_APPROVAL':
            approved++;
            break;
          case 'FULL_REJECTION':
          case 'PARTIAL_REJECTION':
            rejected++;
            break;
        }
      }
      return [rows.length, approved, rejected];
    } catch (_) {
      return [0, 0, 0];
    }
  }

  QualityKpis _qualityKpis(List<Map<String, dynamic>> filtered) {
    var approved = 0, conditional = 0, partial = 0, rejected = 0;
    var totalQty = 0.0, rejectedQty = 0.0, partialRejSum = 0.0;
    var versionSum = 0, reopened = 0, expiryRisk = 0, expired = 0;
    final today = _today();
    final soon =
        _day(DateTime.now().add(const Duration(days: 30)));
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
    final acceptance = n == 0 ? 0.0 : _round1((approved + conditional) / n * 100);
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
      rejectedQtyRatio:
          totalQty <= 0 ? 0.0 : _round1(rejectedQty / totalQty * 100),
      avgRejectedPerPartial:
          partial == 0 ? 0.0 : _round1(partialRejSum / partial),
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
      final where =
          cutoff == null ? null : 'substr(tested_at,1,10) >= ?';
      final args = cutoff == null ? null : [cutoff];
      final total = Sqflite.firstIntValue(await db.rawQuery(
              'SELECT COUNT(*) AS c FROM lab_sample_tests${where == null ? '' : ' WHERE $where'}',
              args)) ??
          0;
      int evaluated = 0;
      try {
        evaluated = Sqflite.firstIntValue(await db.rawQuery(
                "SELECT COUNT(*) AS c FROM lab_sample_tests WHERE COALESCE(result_text,'') <> ''${where == null ? '' : ' AND $where'}",
                args)) ??
            0;
      } catch (_) {}
      var low = 0;
      try {
        if (await _hasTable(db, 'lab_inventory')) {
          low = Sqflite.firstIntValue(await db.rawQuery(
                  'SELECT COUNT(*) AS c FROM lab_inventory WHERE current_qty < min_qty')) ??
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
      final where =
          cutoff == null ? "deleted_at IS NULL" : "deleted_at IS NULL AND substr(COALESCE(inspection_date,created_at,''),1,10) >= '$cutoff'";
      final rows = await db.rawQuery(
          'SELECT result_overall, score_pct, has_nc, critical_nc_count, major_nc_count, minor_nc_count FROM qc_inspections WHERE $where');
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
      final row = (await db.rawQuery('''
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
''', [today])).first;
      final hasCapa = await _hasTable(db, 'qc_capa');
      var linked = 0, capaOver = 0;
      final total = _int(row['total']);
      if (hasCapa && total > 0) {
        try {
          final c = (await db.rawQuery('''
SELECT SUM(CASE WHEN c.capa_id IS NOT NULL AND c.status <> 'Rejected' THEN 1 ELSE 0 END) AS linked_c,
 SUM(CASE WHEN c.due_at IS NOT NULL AND c.due_at <> '' AND substr(c.due_at,1,10) < ? AND c.status NOT IN ('Closed','Rejected','VerifiedEffective') THEN 1 ELSE 0 END) AS over_c
FROM qc_findings_nc fn LEFT JOIN qc_capa c ON c.finding_id = fn.finding_id AND c.deleted_at IS NULL
WHERE fn.deleted_at IS NULL''', [today])).first;
          linked = _int(c['linked_c']);
          capaOver = _int(c['over_c']);
        } catch (_) {}
      }
      final closed = _int(row['closed_c']);
      final ontime = _int(row['ontime_c']);
      final overdue = _int(row['overdue_c']);
      final mttc = row['mttc'] == null ? null : _num(row['mttc']);
      final mttv = row['mttv'] == null ? null : _num(row['mttv']);
      final aging = await _ncrAging(db, today);
      final defects = await _ncrTopDefects(db);
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
        onTimePct: closed == 0
            ? null
            : _round1(ontime / closed * 100),
        mttcDays: mttc == null ? null : _round1(mttc),
        mttvDays: mttv == null ? null : _round1(mttv),
        capaLinked: linked,
        capaCoveragePct:
            total == 0 ? 0.0 : _round1(linked / total * 100),
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
      final rows = await db.rawQuery('''
SELECT
 SUM(CASE WHEN age BETWEEN 0 AND 7 THEN 1 ELSE 0 END) AS b0,
 SUM(CASE WHEN age BETWEEN 8 AND 14 THEN 1 ELSE 0 END) AS b1,
 SUM(CASE WHEN age BETWEEN 15 AND 30 THEN 1 ELSE 0 END) AS b2,
 SUM(CASE WHEN age BETWEEN 31 AND 60 THEN 1 ELSE 0 END) AS b3,
 SUM(CASE WHEN age > 60 THEN 1 ELSE 0 END) AS b4
FROM (SELECT CAST(julianday(?) - julianday(substr(COALESCE(created_at,''),1,10)) AS INTEGER) AS age
 FROM qc_findings_nc WHERE deleted_at IS NULL AND status NOT IN ('Closed','Rejected'))''', [today]);
      final r = rows.first;
      return [
        _int(r['b0']), _int(r['b1']), _int(r['b2']), _int(r['b3']), _int(r['b4']),
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
          }
      ];
    } catch (_) {
      return [];
    }
  }

  Future<SopGoalKpis> _sopGoalKpis(Database db) async {
    var sopTotal = 0, pub = 0, exp = 0, expSoon = 0, pend = 0;
    var gTotal = 0, gActive = 0, gOver = 0, gDone = 0, gOverActions = 0;
    var progressSum = 0.0;
    var progressN = 0;
    try {
      if (await _hasTable(db, 'qc_sops')) {
        final today = _today();
        final soon = _day(DateTime.now().add(const Duration(days: 30)));
        final r = (await db.rawQuery('''
SELECT COUNT(*) AS t,
 SUM(CASE WHEN status='Published' THEN 1 ELSE 0 END) AS p,
 SUM(CASE WHEN status='Published' AND COALESCE(expiry_date,'') <> '' AND substr(expiry_date,1,10) < ? THEN 1 ELSE 0 END) AS e,
 SUM(CASE WHEN status='Published' AND COALESCE(expiry_date,'') <> '' AND substr(expiry_date,1,10) >= ? AND substr(expiry_date,1,10) <= ? THEN 1 ELSE 0 END) AS s,
 SUM(CASE WHEN status='Pending' THEN 1 ELSE 0 END) AS q
FROM qc_sops WHERE COALESCE(deleted_at,'') = '' ''', [today, today, soon])).first;
        sopTotal = _int(r['t']);
        pub = _int(r['p']);
        exp = _int(r['e']);
        expSoon = _int(r['s']);
        pend = _int(r['q']);
      }
    } catch (_) {}
    try {
      if (await _hasTable(db, 'qc_goals')) {
        final today = _today();
        final r = (await db.rawQuery('''
SELECT COUNT(*) AS t,
 SUM(CASE WHEN status='Active' THEN 1 ELSE 0 END) AS a,
 SUM(CASE WHEN status NOT IN ('Completed','Cancelled','Archived') AND COALESCE(due_date,'') <> '' AND substr(due_date,1,10) < ? THEN 1 ELSE 0 END) AS o,
 SUM(CASE WHEN status='Completed' THEN 1 ELSE 0 END) AS d
FROM qc_goals WHERE COALESCE(deleted_at,'') = '' ''', [today])).first;
        gTotal = _int(r['t']);
        gActive = _int(r['a']);
        gOver = _int(r['o']);
        gDone = _int(r['d']);
        try {
          final grows = await db.rawQuery(
              "SELECT baseline_value, current_value, target_value FROM qc_goals WHERE COALESCE(deleted_at,'') = '' AND baseline_value IS NOT NULL AND target_value IS NOT NULL AND current_value IS NOT NULL");
          for (final g in grows) {
            final b = _num(g['baseline_value']);
            final c = _num(g['current_value']);
            final t = _num(g['target_value']);
            final denom = t - b;
            if (denom == 0) continue;
            var p = (c - b) / denom;
            if (p.isNaN) continue;
            p = p.clamp(0.0, 1.0);
            progressSum += p;
            progressN++;
          }
        } catch (_) {}
        if (await _hasTable(db, 'qc_goal_actions')) {
          try {
            gOverActions = Sqflite.firstIntValue(await db.rawQuery(
                    "SELECT COUNT(*) AS c FROM qc_goal_actions WHERE COALESCE(deleted_at,'') = '' AND status NOT IN ('Done','Cancelled') AND COALESCE(due_date,'') <> '' AND substr(due_date,1,10) < ?",
                    [today])) ??
                0;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return SopGoalKpis(
      sopTotal: sopTotal,
      sopPublished: pub,
      sopExpired: exp,
      sopExpiring: expSoon,
      sopPending: pend,
      goalTotal: gTotal,
      goalActive: gActive,
      goalOverdue: gOver,
      goalCompleted: gDone,
      goalAvgProgress:
          progressN == 0 ? 0.0 : _round1(progressSum / progressN * 100),
      goalKpiMetRate: 0.0,
      goalOverdueActions: gOverActions,
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
            'SELECT name, current_qty, min_qty, unit FROM lab_inventory WHERE current_qty < min_qty ORDER BY (min_qty - current_qty) DESC LIMIT 6');
        items = [for (final r in rows) Map<String, dynamic>.from(r)];
      } catch (_) {}
      return InventoryKpis(
          skus: t, low: l, empty: e, ok: (t - l - e).clamp(0, t), lowItems: items);
    } catch (_) {
      return const InventoryKpis();
    }
  }

  Future<List<TrendPoint>> _trendPoints(Database db, String period) async {
    try {
      const names = {
        '01': 'يناير', '02': 'فبراير', '03': 'مارس', '04': 'أبريل',
        '05': 'مايو', '06': 'يونيو', '07': 'يوليو', '08': 'أغسطس',
        '09': 'سبتمبر', '10': 'أكتوبر', '11': 'نوفمبر', '12': 'ديسمبر',
      };
      final now = DateTime.now();
      final out = <TrendPoint>[];
      for (var back = 5; back >= 0; back--) {
        final d = DateTime(now.year, now.month - back, 1);
        final key =
            '${d.year}-${d.month.toString().padLeft(2, '0')}';
        final like = '$key%';
        var total = 0, approved = 0;
        try {
          final r = (await db.rawQuery(
              "SELECT COUNT(*) AS t, SUM(CASE WHEN decision_status='APPROVED' THEN 1 ELSE 0 END) AS a FROM inspections WHERE inspection_date LIKE ?",
              [like])).first;
          total = _int(r['t']);
          approved = _int(r['a']);
        } catch (_) {}
        final rate = total == 0 ? 0.0 : _round1(approved / total * 100);
        out.add(TrendPoint(
          label: '${names[key.substring(5)] ?? key} ${key.substring(0, 4)}',
          total: total,
          approvalRate: rate,
          passRate: rate,
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}
