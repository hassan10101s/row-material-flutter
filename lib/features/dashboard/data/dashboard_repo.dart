import 'package:sqflite/sqflite.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_dates.dart';

/// Inspection dashboard analytics (port of the Vue dashboard computed + the
/// summary endpoints). All heavy lifting is done in SQL; aggregation mirrors
/// web/src/35_dashboard_history_reports.js.
class DashboardRepo {
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
          'decision_status'
        ],
        where: where,
        whereArgs: where == null ? null : args,
        orderBy: 'inspection_date DESC, id DESC');
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  /// Full inspection analytics object for the dashboard.
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
      if (d != null) {
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        final buck = monthlyBuckets.putIfAbsent(
            key,
            () =>
                {'year': d.year, 'month': d.month, 'total': 0, 'approved': 0, 'conditional': 0, 'rejected': 0});
        buck['total'] = (buck['total'] as int) + 1;
      }

      final s = _normalizeStatus('${i['decision_status'] ?? ''}');
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
}

/// Dropdown options for dashboard filters.
class DashboardFilterOptions {
  final List<Map<String, dynamic>> materials;
  final List<Map<String, dynamic>> suppliers;
  final List<String> statuses;

  const DashboardFilterOptions({
    required this.materials,
    required this.suppliers,
    required this.statuses,
  });
}