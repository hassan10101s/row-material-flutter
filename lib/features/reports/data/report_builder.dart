import 'package:intl/intl.dart';

import '../../lab/core/formula_engine.dart';
import '../../reference/data/reference_repo.dart';
import '../../../core/domain/rules.dart';
import '../../../core/security/qr_builder.dart';
import '../../../core/services/aggregation.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_format.dart';

/// Port of core/services/report.py data/context builders. Pure logic — no
/// rendering. Mirrors the Jinja context dicts so reports stay 1:1.

const List<int> _qrByteCapacityM = [
  14, 26, 42, 62, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362, 412, 450,
  504, 560, 624, 666, 711, 779, 857, 911, 997, 1059, 1125, 1190, 1264, 1370,
  1452, 1538, 1628, 1722, 1809, 1911, 1989, 2099, 2213, 2331,
];

/// Byte-mode QR capacity fallback (error level M) — port of qrcode table.
int qrCapacityBytesM(int version) => _qrByteCapacityM[version - 1];

/// Resolve inspection sample names; fallback like report.py.
List<String> resolveSampleNames(Object? sampleNames) {
  if (sampleNames is List && sampleNames.isNotEmpty) {
    return sampleNames.map((s) => '$s').toList();
  }
  return const ['النتيجة / Result'];
}

/// Port of ReportService._build_physical_data.
List<Map<String, dynamic>> buildPhysicalData(
  Map<String, dynamic>? physicalReference,
  Map<String, dynamic>? physicalResults,
  List<String> sampleNames,
) {
  final data = <Map<String, dynamic>>[];
  (physicalReference ?? {}).forEach((name, requirement) {
    var reqValue = referenceValueText(requirement);
    if (reqValue.isEmpty) reqValue = '-';
    var results = _resultsFor(physicalResults?[name], sampleNames.length);
    final actuals = <String>[];
    for (final r in results) {
      actuals.add((r.toString().isNotEmpty) ? r.toString() : '-');
    }
    data.add({
      'name': name,
      'req': reqValue,
      'actuals': actuals,
    });
  });
  return data;
}

/// Port of ReportService._build_chemical_data.
List<Map<String, dynamic>> buildChemicalData(
  Map<String, dynamic>? chemicalReference,
  Map<String, dynamic>? chemicalResults,
  List<String> sampleNames,
) {
  final data = <Map<String, dynamic>>[];
  (chemicalReference ?? {}).forEach((name, rangeValue) {
    final parsed = parseNumericRange(rangeValue);
    final unit = inferChemicalUnit(rangeValue, name);
    final results = _resultsFor(chemicalResults?[name], sampleNames.length);
    final isOuts = <bool>[];
    final actualsFormatted = <String>[];
    final minValue = parsed['min_value'] as double?;
    final maxValue = parsed['max_value'] as double?;
    for (final r in results) {
      final text = r.toString();
      isOuts.add(isOutOfRange(text, minValue, maxValue));
      actualsFormatted.add(formatValueWithUnit(text.isEmpty ? '-' : text, unit));
    }
    data.add({
      'name': name,
      'min': parsed['min_text'],
      'max': parsed['max_text'],
      'min_display': formatValueWithUnit('${parsed['min_text']}', unit),
      'max_display': formatValueWithUnit('${parsed['max_text']}', unit),
      'unit': unit,
      'actuals': actualsFormatted,
      'is_outs': isOuts,
    });
  });
  return data;
}

/// Port of ReportService._merge_lab_tests.
List<Map<String, dynamic>> mergeLabTests(
  List<Map<String, dynamic>> chemicalData,
  List<Map<String, dynamic>> labTests,
  List<String> sampleNames,
) {
  final merged = List<Map<String, dynamic>>.from(chemicalData);
  final byAnalysis = <String, List<Map<String, dynamic>>>{};
  for (final test in labTests) {
    final name = '${test['analysis_name'] ?? 'Lab Analysis'}';
    byAnalysis.putIfAbsent(name, () => []).add(test);
  }
  byAnalysis.forEach((analysisName, tests) {
    final rawUnit = '${tests[0]['analysis_unit'] ?? ''}';
    final unit = rawUnit.isEmpty
        ? inferChemicalUnit(null, analysisName)
        : rawUnit;
    final sampleCells = <String>[];
    for (final t in tests) {
      sampleCells
          .add("${t['sample_name'] ?? ''}: ${t['result_text'] ?? '-'}");
    }
    var results = List<String>.from(sampleCells);
    if (results.length < sampleNames.length) {
      results = [
        ...results,
        ...List.filled(sampleNames.length - results.length, ''),
      ];
    }
    results = results.sublist(0, sampleNames.length);
    final actualsFormatted = <String>[];
    for (final r in results) {
      actualsFormatted
          .add(r.isNotEmpty ? '(Lab) ${formatValueWithUnit(r, unit)}' : '');
    }
    final minText = tests.isNotEmpty ? tests[0]['range_min'] : null;
    final maxText = tests.isNotEmpty ? tests[0]['range_max'] : null;
    final isOuts = <bool>[];
    for (final test in tests) {
      isOuts.add(isOutOfRange(
        '${test['result_text']}',
        minText == null ? null : (minText as num?)?.toDouble(),
        maxText == null ? null : (maxText as num?)?.toDouble(),
      ));
    }
    while (isOuts.length < sampleNames.length) {
      isOuts.add(false);
    }
    final isOutsTrimmed = isOuts.sublist(0, sampleNames.length);

    final minDisplay = minText == null
        ? '-'
        : formatValueWithUnit('$minText', unit);
    final maxDisplay = maxText == null
        ? '-'
        : formatValueWithUnit('$maxText', unit);
    merged.add({
      'name': '$analysisName (Lab)',
      'min': '${minText ?? '-'}',
      'max': '${maxText ?? '-'}',
      'min_display': minDisplay,
      'max_display': maxDisplay,
      'unit': unit,
      'actuals': actualsFormatted,
      'is_outs': isOutsTrimmed,
    });
  });
  return merged;
}

List<dynamic> _resultsFor(Object? value, int sampleCount) {
  List<dynamic> results;
  if (value is List) {
    results = value.map((r) => '$r').toList();
  } else {
    results = <String>['${value ?? ''}'];
  }
  if (results.length < sampleCount) {
    results = [
      ...results,
      ...List<dynamic>.filled(sampleCount - results.length, ''),
    ];
  }
  return results.sublist(0, sampleCount);
}

/// Port of render_html status timeline builder.
List<Map<String, dynamic>> buildStatusTimeline(Map<String, dynamic> inspection) {
  final timeline = <Map<String, dynamic>>[];
  final raw = (inspection['status_history'] as List<dynamic>?) ?? const [];
  for (final rawRow in raw.reversed) {
    if (rawRow is! Map) continue;
    final statusCode = '${rawRow['new_status'] ?? ''}';
    if (!decisionCodes.contains(statusCode)) continue;
    final info = decisionMeta(statusCode);
    timeline.add({
      'status_code': statusCode,
      'label_ar': info['label_ar'],
      'label_en': info['label_en'],
      'css_class': info['css_class'],
      'reason': '${rawRow['change_reason'] ?? '-'}',
      'version': '${rawRow['version'] ?? ''}',
      'changed_at': '${rawRow['changed_at'] ?? ''}',
    });
  }
  return timeline;
}

/// Port of render_html — builds the full inspection report context.
Map<String, dynamic> buildInspectionContext(
  Map<String, dynamic> inspection, {
  required Map<String, dynamic> settings,
  List<int>? encryptionSecret,
}) {
  final meta = decisionMeta('${inspection['decision_status']}');
  final sampleNames = resolveSampleNames(inspection['sample_names']);

  final physicalData = buildPhysicalData(
    inspection['physical_reference'] as Map<String, dynamic>? ?? {},
    inspection['physical_results'] as Map<String, dynamic>? ?? {},
    sampleNames,
  );
  for (final entry in physicalData) {
    final isOuts = <bool>[];
    for (final actual in entry['actuals'] as List) {
      isOuts.add(isPhysicalOutOfRange('$actual', entry['req']));
    }
    entry['is_outs'] = isOuts;
  }

  var chemicalData = buildChemicalData(
    inspection['chemical_reference'] as Map<String, dynamic>? ?? {},
    inspection['chemical_results'] as Map<String, dynamic>? ?? {},
    sampleNames,
  );
  final labTests = (inspection['lab_tests'] as List?) ?? const [];
  if (labTests.isNotEmpty) {
    chemicalData = mergeLabTests(
      chemicalData,
      labTests.map((t) => Map<String, dynamic>.from(t as Map)).toList(),
      sampleNames,
    );
  }

  final statusTimeline = buildStatusTimeline(inspection);
final qrPayloadText = buildQrPayloadText(
      inspection: inspection,
      physicalData: physicalData,
      chemicalData: chemicalData,
      encryptKey: encryptionSecret,
    );

  final decisionReason = '${inspection['decision_reason'] ?? ''}'.trim();
  return {
    'inspection_id': inspection['id'] ?? '-',
    'date': inspection['inspection_date'],
    'expiry_date': inspection['expiry_date'] ?? '-',
    'sample_number': inspection['entry_code'],
    'material_name': inspection['material_name'],
    'quantity': inspection['quantity'] ?? '-',
    'supplier': inspection['supplier'] ?? '-',
    'truck_number': inspection['truck_number'] ?? '-',
    'sample_taken_by': inspection['sample_taken_by'] ?? '-',
    'specialist_name': inspection['specialist_name'] ?? '-',
    'created_by_name': inspection['created_by_name'] ?? '-',
    'sample_names': sampleNames,
    'physical_data': physicalData,
    'chemical_data': chemicalData,
    'decision_status': inspection['decision_status'],
    'decision_label':
        '${meta['label_en']} / ${meta['label_ar']}',
    'decision_class': meta['css_class'],
    'decision_reason': decisionReason.isEmpty ? '-' : decisionReason,
    'show_decision_reason': decisionReason.isNotEmpty,
    'follow_up_note': inspection['follow_up_note'] ?? '-',
    'show_follow_up_note':
        inspection['decision_status'] == 'CONDITIONAL_APPROVAL',
    'rejected_quantity': inspection['rejected_quantity'] ?? '-',
    'show_rejected_quantity':
        inspection['decision_status'] == 'PARTIAL_REJECTION',
    'decision_version': inspection['decision_version'] ?? 1,
    'generated_at': inspection['updated_at'] ?? nowIso(),
    'department_label': settings['department_label'] ??
        'Quality Assurance Department',
    'report_logo_data_uri': settings['report_logo_data_uri'] ?? '',
    'status_timeline': statusTimeline,
    'show_status_timeline': statusTimeline.length > 1,
    'qr_payload_text': qrPayloadText,
  };
}

/// Port of render_label_html context.
Map<String, dynamic> buildLabelContext(
  Map<String, dynamic> inspection, {
  required Map<String, dynamic> settings,
  double widthCm = 10,
  double heightCm = 5,
  List<int>? encryptionSecret,
}) {
  final sampleNames = resolveSampleNames(inspection['sample_names']);
  final physicalData = buildPhysicalData(
    inspection['physical_reference'] as Map<String, dynamic>? ?? {},
    inspection['physical_results'] as Map<String, dynamic>? ?? {},
    sampleNames,
  );
  final chemicalData = buildChemicalData(
    inspection['chemical_reference'] as Map<String, dynamic>? ?? {},
    inspection['chemical_results'] as Map<String, dynamic>? ?? {},
    sampleNames,
  );
final qrPayloadText = buildQrPayloadText(
      inspection: inspection,
      physicalData: physicalData,
      chemicalData: chemicalData,
      encryptKey: encryptionSecret,
    );
  return {
    'inspection': inspection,
    'qr_payload_text': qrPayloadText,
    'width_cm': widthCm,
    'height_cm': heightCm,
    'quantity_display': formatLabelQuantity(inspection['quantity']),
    'department_label': settings['department_label'] ??
        'Quality Assurance Department',
    'generated_at': nowIso().substring(0, 16),
  };
}

/// Port of render_batch_label_html context.
Map<String, dynamic> buildBatchLabelsContext(
  List<Map<String, dynamic>> inspections, {
  required Map<String, dynamic> settings,
  List<int>? encryptionSecret,
}) {
  final labels = <Map<String, dynamic>>[];
  for (final insp in inspections) {
    final sampleNames = resolveSampleNames(insp['sample_names']);
    final physicalData = buildPhysicalData(
      insp['physical_reference'] as Map<String, dynamic>? ?? {},
      insp['physical_results'] as Map<String, dynamic>? ?? {},
      sampleNames,
    );
    final chemicalData = buildChemicalData(
      insp['chemical_reference'] as Map<String, dynamic>? ?? {},
      insp['chemical_results'] as Map<String, dynamic>? ?? {},
      sampleNames,
);
final qrPayloadText = buildQrPayloadText(
      inspection: insp,
      physicalData: physicalData,
      chemicalData: chemicalData,
      encryptKey: encryptionSecret,
    );
    final decisionStatus = '${insp['decision_status'] ?? ''}';

    labels.add({
      'id': insp['id'] ?? '',
      'entry_code': insp['entry_code'] ?? '',
      'material_name': insp['material_name'] ?? '',
      'inspection_date': insp['inspection_date'] ?? '',
      'supplier': insp['supplier'] ?? '',
      'truck_number': insp['truck_number'] ?? '',
      'quantity_display': formatLabelQuantity(insp['quantity']),
      'specialist_name': insp['specialist_name'] ?? '',
      'sample_taken_by': insp['sample_taken_by'] ?? '',
      'decision_status': decisionStatus,
      'decision_status_class': decisionStatus.toLowerCase(),
      'decision_version': insp['decision_version'] ?? 1,
      'qr_payload_text': qrPayloadText,
    });
  }
  return {
    'labels': labels,
    'department_label':
        settings['department_label'] ?? 'Quality Assurance Department',
  };
}

/// strftime("%A، %d %B %Y") equivalent (English locale, C-locale parity).
String _formatLongDate(String dateStr) {
  final dateObj = DateTime.tryParse(dateStr);
  if (dateObj == null) return dateStr;
  return DateFormat('EEEE، dd MMMM yyyy', 'en_US').format(dateObj);
}

/// Port of render_daily_report context.
Map<String, dynamic> buildDailyContext(
  List<Map<String, dynamic>> inspections, {
  required Map<String, dynamic> settings,
  required String dateStr,
  String shiftLabel = '',
}) {
  final summary = aggregateTotals(inspections);
  final materialSections = buildMaterialSections(inspections);
  final formattedDate = _formatLongDate(dateStr);
  return {
    'date_str': dateStr,
    'formatted_date': formattedDate,
    'shift_label': shiftLabel,
    'total': inspections.length,
    'approved': summary['approved'],
    'conditional': summary['conditional'],
    'partial': summary['partial'],
    'rejected': summary['rejected'],
    'accepted_total': summary['accepted_total'],
    'conditional_partial': summary['conditional_partial'],
    'approval_rate': summary['approval_rate'],
    'total_quantity': formatQuantity(summary['total_qty']),
    'total_accepted_qty': formatQuantity(summary['total_accepted_qty']),
    'total_rejected_qty': formatQuantity(summary['total_rejected_qty']),
    'unique_suppliers': summary['unique_suppliers'],
    'unique_materials': summary['unique_materials'],
    'materials': groupByMaterial(inspections),
    'material_sections': materialSections,
    'department_label':
        settings['department_label'] ?? 'Quality Assurance Department',
    'report_logo_data_uri': settings['report_logo_data_uri'] ?? '',
    'generation_time': nowIso(),
  };
}

const List<String> _monthsAr = [
  'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
  'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
];

String _monthNameAr(int month) => _monthsAr[month - 1];

double _safeQty(Object? value) => safeFloat(value) ?? 0.0;

Map<String, dynamic> _materialSupplierSectionData(
    List<Map<String, dynamic>> items) {
  var sq = 0.0;
  var srj = 0.0;
  var sa = 0, sp = 0, sr = 0;
  for (final i in items) {
    final status = i['decision_status'];
    final iq = _safeQty(i['quantity']);
    final irjQty = _safeQty(i['rejected_quantity']);
    sq += iq;
    if (status == 'APPROVED' || status == 'CONDITIONAL_APPROVAL') {
      sa++;
    } else if (status == 'PARTIAL_REJECTION') {
      sp++;
      srj += irjQty;
    } else if (status == 'FULL_REJECTION') {
      sr++;
      srj += iq;
    }
  }
  return {
    'count': items.length,
    'total_qty': formatQuantity(sq),
    'accepted_qty': formatQuantity(sq - srj),
    'rejected_qty': formatQuantity(srj),
    'approved': sa,
    'partial': sp,
    'rejected': sr,
    'approval_rate':
        items.isEmpty ? 0.0 : roundPct(sa / items.length * 100),
  };
}

/// Port of render_monthly_report context (trend rows fed by caller DB query).
Map<String, dynamic> buildMonthlyContext(
  List<Map<String, dynamic>> inspections, {
  required Map<String, dynamic> settings,
  required int month,
  required int year,
  List<Map<String, dynamic>>? trendRows,
}) {
  final materials = <String, List<Map<String, dynamic>>>{};
  for (final insp in inspections) {
    final name = '${insp['material_name'] ?? 'Unknown'}';
    materials.putIfAbsent(name, () => []).add(insp);
  }
  final suppliers = <String, List<Map<String, dynamic>>>{};
  for (final insp in inspections) {
    final name = '${insp['supplier'] ?? ''}'.trim().isEmpty
        ? 'بدون مورد'
        : '${insp['supplier'] ?? ''}'.trim();
    suppliers.putIfAbsent(name, () => []).add(insp);
  }

  var approvedCount = 0, conditionalCount = 0, partialCount = 0, rejectedCount = 0;
  var totalQty = 0.0, totalRejectedQty = 0.0;
  for (final i in inspections) {
    final status = i['decision_status'];
    final iq = _safeQty(i['quantity']);
    final irj = _safeQty(i['rejected_quantity']);
    totalQty += iq;
    if (status == 'APPROVED') {
      approvedCount++;
    } else if (status == 'CONDITIONAL_APPROVAL') {
      approvedCount++;
      conditionalCount++;
    } else if (status == 'PARTIAL_REJECTION') {
      partialCount++;
      totalRejectedQty += irj;
    } else if (status == 'FULL_REJECTION') {
      rejectedCount++;
      totalRejectedQty += iq;
    }
  }
  final totalAcceptedQty = totalQty - totalRejectedQty;
  var uniqueSuppliers = <String>{};
  for (final i in inspections) {
    final s = '${i['supplier'] ?? ''}'.trim();
    if (s.isNotEmpty) uniqueSuppliers.add(s);
  }
  final approvalRate = inspections.isEmpty
      ? 0.0
      : roundPct(approvedCount / inspections.length * 100);
  final rejectionRate = inspections.isEmpty
      ? 0.0
      : roundPct((rejectedCount + partialCount) / inspections.length * 100);

  final materialSections = <Map<String, dynamic>>[];
  materials.forEach((matName, matItems) {
    var mq = 0.0, mrj = 0.0;
    var ma = 0, mp = 0, mr = 0;
    final matSuppliers = <String, List<Map<String, dynamic>>>{};
    for (final i in matItems) {
      final status = i['decision_status'];
      final iq = _safeQty(i['quantity']);
      final irjQty = _safeQty(i['rejected_quantity']);
      mq += iq;
      if (status == 'APPROVED' || status == 'CONDITIONAL_APPROVAL') {
        ma++;
      } else if (status == 'PARTIAL_REJECTION') {
        mp++;
        mrj += irjQty;
      } else if (status == 'FULL_REJECTION') {
        mr++;
        mrj += iq;
      }
      final supName = '${i['supplier'] ?? ''}'.trim().isEmpty
          ? 'بدون مورد'
          : '${i['supplier'] ?? ''}'.trim();
      matSuppliers.putIfAbsent(supName, () => []).add(i);
    }
    final matSupplierList = <Map<String, dynamic>>[];
    matSuppliers.forEach((supName, supItems) {
      final data = _materialSupplierSectionData(supItems);
      matSupplierList.add({'name': supName, ...data});
    });
    matSupplierList.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    materialSections.add({
      'name': matName,
      'count': matItems.length,
      'total_qty': formatQuantity(mq),
      'accepted_qty': formatQuantity(mq - mrj),
      'rejected_qty': formatQuantity(mrj),
      'approved': ma,
      'partial': mp,
      'rejected': mr,
      'approval_rate':
          matItems.isEmpty ? 0.0 : roundPct(ma / matItems.length * 100),
      'suppliers': matSupplierList,
    });
  });

  final supplierSections = <Map<String, dynamic>>[];
  suppliers.forEach((supName, supItems) {
    final data = _materialSupplierSectionData(supItems);
    supplierSections.add({'name': supName, ...data});
  });
  supplierSections.sort((a, b) =>
      (a['approval_rate'] as num).compareTo(b['approval_rate'] as num));

  final recommendations = <String>[];
  if (inspections.isEmpty) {
    recommendations.add(
        'لا توجد بيانات كافية لإنشاء توصيات تشغيلية لهذا الشهر. توصي بضمان إدخال جميع الفحوصات في الشهور القادمة.');
  } else {
    if (approvalRate >= 90) {
      recommendations.add(
          'تقديم أداء متميز في الجودة هذا الشهر مع معدل قبول يبلغ ${approvalRate.toStringAsFixed(1)}% — جاري الاستمرار في الحفاظ على هذه المعايير العالية وتوثيق جميع الإجراءات المتبعة.');
    } else if (approvalRate >= 75) {
      recommendations.add(
          'معدل القبول العام يبلغ ${approvalRate.toStringAsFixed(1)}% وهو ضمن المستوى الجيد — جاري تنفيذ مراجعة تفصيلية للحالات المرفوضة والمقبولة مشروطًا لتحديد الأسباب الجذرية وتحسين الأداء في الشهر القادم.');
    } else {
      recommendations.add(
          'معدل القبول العام منخفض (${approvalRate.toStringAsFixed(1)}%) — جاري تفعيل فريق جودة للتحقيق في الأسباب الجذرية وتنفيذ إجراءات تصحيحية فورية لتعديل سلسلة التوريد ومعايير الفحص.');
    }

    Map<String, dynamic>? worstMaterial;
    for (final mat in materialSections) {
      final rate = (mat['approval_rate'] as num).toDouble();
      if (rate < 75 &&
          (worstMaterial == null || rate < (worstMaterial['approval_rate'] as num).toDouble())) {
        worstMaterial = mat;
      }
    }
    if (worstMaterial != null) {
      recommendations.add(
          'خامة "${worstMaterial['name']}" تعاني من أدنى معدل قبول (${(worstMaterial['approval_rate'] as num).toStringAsFixed(1)}%) — جاري تشديد معايير الجودة والفحص لهذه الخامة أو إبلاغ المشتريات بتقييم خيارات الموردين الحاليين ومدى موثوقيتهم.');
    }

    final worstSuppliers = supplierSections
        .where((s) => (s['approval_rate'] as num).toDouble() < 75)
        .toList();
    if (worstSuppliers.length >= 3) {
      final top3 = List.of(worstSuppliers)
        ..sort((a, b) =>
            (a['approval_rate'] as num).compareTo(b['approval_rate'] as num));
      final names = top3
          .take(3)
          .map((s) =>
              '"${s['name']}" (${(s['approval_rate'] as num).toStringAsFixed(1)}%)')
          .toList();
      recommendations.add(
          'أقل ثلاث موردين من حيث معدل القبول هذا الشهر هم:  ${names.join(', ')} — تم التشديد على إجراءات الفحص ونوصي بمراجعة موثوقية الموردين وإعادة تقييم اتفاقيات التوريد بشكل عاجل.');
    } else if (worstSuppliers.length == 2) {
      recommendations.add(
          'الموردين الأقل جودة هذا الشهر هما: 1) "${worstSuppliers[0]['name']}" (${(worstSuppliers[0]['approval_rate'] as num).toStringAsFixed(1)}%) و 2) "${worstSuppliers[1]['name']}" (${(worstSuppliers[1]['approval_rate'] as num).toStringAsFixed(1)}%) — تم التشديد على إجراءات الفحص ونوصي بمراجعة موثوقية الموردين.');
    } else if (worstSuppliers.length == 1) {
      recommendations.add(
          'المورد "${worstSuppliers[0]['name']}" يقدم أداء منخفض هذا الشهر بمعدل قبول ${(worstSuppliers[0]['approval_rate'] as num).toStringAsFixed(1)}% — تم التشديد على إجراءات الفحص ونوصي بمراجعة موثوقية المورد.');
    }

    if (conditionalCount > 0) {
      recommendations.add(
          'يوجد $conditionalCount فحص تم قبوله مشروطًا — جاري متابعة جميع المتطلبات المطلوبة وإغلاقها قبل نهاية الشهر.');
    }
    if (totalRejectedQty > 0 && totalQty > 0) {
      final pct = roundPct(totalRejectedQty / totalQty * 100);
      if (pct > 15) {
        recommendations.add(
            'نسبة الكمية المرفوضة هذا الشهر هي ${pct.toStringAsFixed(1)}% والتي تتجاوز 15% — توصي بتحليل مفصل للأسباب وتنفيذ إجراءات تصحيحية لتجنب خسائر إضافية في الشهور القادمة.');
      }
    }
  }

  final trendMonths = <Map<String, dynamic>>[];
  final trendRanges = <Map<String, dynamic>>[];
  for (var offset = 5; offset >= 0; offset--) {
    var m = month - offset;
    var y = year;
    while (m <= 0) {
      m += 12;
      y -= 1;
    }
    final start = DateTime(y, m, 1);
    final end = DateTime(y + (m == 12 ? 1 : 0), (m < 12 ? m + 1 : 1), 1);
    trendRanges.add({
      'label': '${_monthNameAr(m)} $y',
      'is_current': offset == 0,
      'start': start,
      'end': end,
    });
  }

  final byMonth = <String, List<Map<String, dynamic>>>{};
  for (final r in (trendRows ?? const [])) {
    final key = '${r['inspection_date']}';
    if (key.length >= 7) {
      byMonth.putIfAbsent(key.substring(0, 7), () => []).add(r);
    }
  }

  for (final tr in trendRanges) {
    final start = tr['start'] as DateTime;
    final monthKey =
        '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}';
    var trendCount = 0;
    var trendApp = 0;
    var trendRej = 0;
    var trendQty = 0.0;
    if (tr['is_current'] == true) {
      trendCount = inspections.length;
      trendApp = approvedCount;
      trendRej = partialCount + rejectedCount;
      trendQty = totalQty;
    } else {
      final rows = byMonth[monthKey] ?? const [];
      trendCount = rows.length;
      trendApp = rows
          .where((r) =>
              r['decision_status'] == 'APPROVED' ||
              r['decision_status'] == 'CONDITIONAL_APPROVAL')
          .length;
      trendRej = rows
          .where((r) =>
              r['decision_status'] == 'PARTIAL_REJECTION' ||
              r['decision_status'] == 'FULL_REJECTION')
          .length;
      for (final r in rows) {
        trendQty += _safeQty(r['quantity']);
      }
    }
    trendMonths.add({
      'label': tr['label'],
      'count': trendCount,
      'approved': trendApp,
      'rejected': trendRej,
      'approval_rate':
          trendCount == 0 ? 0.0 : roundPct(trendApp / trendCount * 100),
      'rejection_rate':
          trendCount == 0 ? 0.0 : roundPct(trendRej / trendCount * 100),
      'total_qty': formatQuantity(trendQty),
      'is_current': tr['is_current'] == true,
    });
  }

  return {
    'month': month,
    'month_name': DateFormat('MMMM', 'en_US').format(DateTime(year, month, 1)),
    'month_name_ar': _monthNameAr(month),
    'year': year,
    'total': inspections.length,
    'approved': approvedCount,
    'conditional': conditionalCount,
    'partial': partialCount,
    'rejected': rejectedCount,
    'conditional_partial': conditionalCount + partialCount,
    'total_quantity': formatQuantity(totalQty),
    'total_accepted_quantity': formatQuantity(totalAcceptedQty),
    'total_rejected_quantity': formatQuantity(totalRejectedQty),
    'unique_suppliers': uniqueSuppliers.length,
    'unique_materials': materials.length,
    'approval_rate': approvalRate,
    'rejection_rate': rejectionRate,
    'materials': materialSections,
    'suppliers': supplierSections,
    'recommendations': recommendations,
    'trend_months': trendMonths,
    'department_label':
        settings['department_label'] ?? 'Quality Assurance Department',
    'report_logo_data_uri': settings['report_logo_data_uri'] ?? '',
    'now': nowIso(),
  };
}

/// Port of render_yearly_report context.
Map<String, dynamic> buildYearlyContext(
  List<Map<String, dynamic>> inspections, {
  required Map<String, dynamic> settings,
  required int year,
}) {
  final materials = <String, List<Map<String, dynamic>>>{};
  for (final insp in inspections) {
    final name = '${insp['material_name'] ?? 'Unknown'}';
    materials.putIfAbsent(name, () => []).add(insp);
  }
  final suppliers = <String, List<Map<String, dynamic>>>{};
  for (final insp in inspections) {
    final name = '${insp['supplier'] ?? ''}'.trim().isEmpty
        ? 'بدون مورد'
        : '${insp['supplier'] ?? ''}'.trim();
    suppliers.putIfAbsent(name, () => []).add(insp);
  }

  var approvedCount = 0, conditionalCount = 0, partialCount = 0, rejectedCount = 0;
  var totalQty = 0.0, totalRejectedQty = 0.0;
  for (final i in inspections) {
    final status = i['decision_status'];
    final iq = _safeQty(i['quantity']);
    final irj = _safeQty(i['rejected_quantity']);
    totalQty += iq;
    if (status == 'APPROVED') {
      approvedCount++;
    } else if (status == 'CONDITIONAL_APPROVAL') {
      approvedCount++;
      conditionalCount++;
    } else if (status == 'PARTIAL_REJECTION') {
      partialCount++;
      totalRejectedQty += irj;
    } else if (status == 'FULL_REJECTION') {
      rejectedCount++;
      totalRejectedQty += iq;
    }
  }
  final totalAcceptedQty = totalQty - totalRejectedQty;
  var uniqueSuppliers = <String>{};
  for (final i in inspections) {
    final s = '${i['supplier'] ?? ''}'.trim();
    if (s.isNotEmpty) uniqueSuppliers.add(s);
  }
  final approvalRate = inspections.isEmpty
      ? 0.0
      : roundPct(approvedCount / inspections.length * 100);
  final rejectionRate = inspections.isEmpty
      ? 0.0
      : roundPct((rejectedCount + partialCount) / inspections.length * 100);

  final materialSections = <Map<String, dynamic>>[];
  materials.forEach((matName, matItems) {
    var mq = 0.0, mrj = 0.0;
    var ma = 0, mc = 0, mp = 0, mr = 0;
    final matSuppliers = <String, List<Map<String, dynamic>>>{};
    for (final i in matItems) {
      final status = i['decision_status'];
      final iq = _safeQty(i['quantity']);
      final irjQty = _safeQty(i['rejected_quantity']);
      mq += iq;
      if (status == 'APPROVED') {
        ma++;
      } else if (status == 'CONDITIONAL_APPROVAL') {
        ma++;
        mc++;
      } else if (status == 'PARTIAL_REJECTION') {
        mp++;
        mrj += irjQty;
      } else if (status == 'FULL_REJECTION') {
        mr++;
        mrj += iq;
      }
      final supName = '${i['supplier'] ?? ''}'.trim().isEmpty
          ? 'بدون مورد'
          : '${i['supplier'] ?? ''}'.trim();
      matSuppliers.putIfAbsent(supName, () => []).add(i);
    }
    final matSupplierList = <Map<String, dynamic>>[];
    matSuppliers.forEach((supName, supItems) {
      final data = _materialSupplierSectionData(supItems);
      matSupplierList.add({'name': supName, ...data});
    });
    matSupplierList.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    materialSections.add({
      'name': matName,
      'count': matItems.length,
      'total_qty': formatQuantity(mq),
      'accepted_qty': formatQuantity(mq - mrj),
      'rejected_qty': formatQuantity(mrj),
      'approved': ma,
      'conditional': mc,
      'partial': mp,
      'rejected': mr,
      'approval_rate':
          matItems.isEmpty ? 0.0 : roundPct(ma / matItems.length * 100),
      'suppliers': matSupplierList,
    });
  });
  materialSections.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

  final supplierSections = <Map<String, dynamic>>[];
  suppliers.forEach((supName, supItems) {
    final data = _materialSupplierSectionData(supItems);
    supplierSections.add({'name': supName, ...data});
  });
  supplierSections.sort((a, b) =>
      (a['approval_rate'] as num).compareTo(b['approval_rate'] as num));

  final monthlyStats = <Map<String, dynamic>>[];
  for (var m = 1; m <= 12; m++) {
    final prefix = '${year.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}';
    final monthInspections = inspections
        .where((i) => '${i['inspection_date'] ?? ''}'.startsWith(prefix))
        .toList();
    var mApp = 0, mCond = 0, mPart = 0, mRej = 0;
    var mq = 0.0, mrj = 0.0;
    for (final i in monthInspections) {
      final st = i['decision_status'];
      final q = _safeQty(i['quantity']);
      mq += q;
      if (st == 'APPROVED' || st == 'CONDITIONAL_APPROVAL') mApp++;
      if (st == 'CONDITIONAL_APPROVAL') mCond++;
      if (st == 'PARTIAL_REJECTION') {
        mPart++;
        mrj += _safeQty(i['rejected_quantity']);
      }
      if (st == 'FULL_REJECTION') {
        mRej++;
        mrj += q;
      }
    }
    monthlyStats.add({
      'month': _monthNameAr(m),
      'total': monthInspections.length,
      'approved': mApp,
      'conditional': mCond,
      'partial': mPart,
      'rejected': mRej,
      'conditional_partial': mCond + mPart,
      'total_qty': formatQuantity(mq),
      'accepted_qty': formatQuantity(mq - mrj),
      'rejected_qty': formatQuantity(mrj),
      'approval_rate': monthInspections.isEmpty
          ? 0.0
          : roundPct(mApp / monthInspections.length * 100),
      'rejection_rate': monthInspections.isEmpty
          ? 0.0
          : roundPct((mPart + mRej) / monthInspections.length * 100),
    });
  }

  const quarterNames = [
    'Q1 (يناير - مارس)',
    'Q2 (أبريل - يونيو)',
    'Q3 (يوليو - سبتمبر)',
    'Q4 (أكتوبر - ديسمبر)',
  ];
  final quarterlyStats = <Map<String, dynamic>>[];
  for (var qi = 0; qi < 4; qi++) {
    final qMonths = monthlyStats.sublist(qi * 3, qi * 3 + 3);
    final qTotal = qMonths.fold<int>(0, (s, m) => s + (m['total'] as int));
    final qApproved = qMonths.fold<int>(0, (s, m) => s + (m['approved'] as int));
    final qPartial = qMonths.fold<int>(0, (s, m) => s + (m['partial'] as int));
    final qRejected = qMonths.fold<int>(0, (s, m) => s + (m['rejected'] as int));
    quarterlyStats.add({
      'name': quarterNames[qi],
      'total': qTotal,
      'approved': qApproved,
      'partial': qPartial,
      'rejected': qRejected,
      'approval_rate':
          qTotal == 0 ? 0.0 : roundPct(qApproved / qTotal * 100),
      'rejection_rate': qTotal == 0
          ? 0.0
          : roundPct((qPartial + qRejected) / qTotal * 100),
    });
  }

  final topSuppliers = List.of(supplierSections)
    ..sort((a, b) {
      final av = safeFloat('${a['total_qty']}'.replaceAll(',', '')) ?? 0.0;
      final bv = safeFloat('${b['total_qty']}'.replaceAll(',', '')) ?? 0.0;
      return bv.compareTo(av);
    });
  final topSuppliers5 = topSuppliers.take(5).toList();

  final recommendations = <String>[];
  if (inspections.isEmpty) {
    recommendations.add(
        'لا توجد بيانات كافية لإنشاء توصيات تشغيلية لهذا العام. يُوصى بضمان إدخال جميع الفحوصات بشكل منتظم.');
  } else {
    if (approvalRate >= 90) {
      recommendations.add(
          'أداء متميز في الجودة خلال عام $year بمعدل قبول إجمالي ${approvalRate.toStringAsFixed(1)}% — يُوصى بتوثيق الإجراءات المتبعة كمعيار مرجعي (Benchmark) للأعوام القادمة.');
    } else if (approvalRate >= 75) {
      recommendations.add(
          'معدل القبول العام ${approvalRate.toStringAsFixed(1)}% ضمن المستوى الجيد — يُوصى بتحليل تفصيلي للحالات المرفوضة لتحديد الأنماط المتكررة وتنفيذ إجراءات تحسين مستهدفة.');
    } else {
      recommendations.add(
          'معدل القبول العام منخفض (${approvalRate.toStringAsFixed(1)}%) — يتطلب تفعيل فريق جودة متخصص للتحقيق في الأسباب الجذرية وتنفيذ خطة تصحيحية شاملة.');
    }

    Map<String, dynamic>? worstMaterial;
    for (final mat in materialSections) {
      final rate = (mat['approval_rate'] as num).toDouble();
      if (rate < 75 &&
          (mat['count'] as int) >= 3 &&
          (worstMaterial == null || rate < (worstMaterial['approval_rate'] as num).toDouble())) {
        worstMaterial = mat;
      }
    }
    if (worstMaterial != null) {
      recommendations.add(
          'خامة "${worstMaterial['name']}" سجلت أدنى معدل قبول (${(worstMaterial['approval_rate'] as num).toStringAsFixed(1)}%) من إجمالي ${worstMaterial['count']} فحص — يُوصى بتشديد معايير الفحص لهذه الخامة ومراجعة مصادر التوريد.');
    }

    final worstSuppliers = supplierSections
        .where((s) =>
            (s['approval_rate'] as num).toDouble() < 75 && (s['count'] as int) >= 3)
        .toList();
    if (worstSuppliers.length >= 3) {
      final top3 = List.of(worstSuppliers)
        ..sort((a, b) =>
            (a['approval_rate'] as num).compareTo(b['approval_rate'] as num));
      final names = top3
          .take(3)
          .map((s) =>
              '"${s['name']}" (${(s['approval_rate'] as num).toStringAsFixed(1)}%)')
          .toList();
      recommendations.add(
          'أقل ثلاثة موردين من حيث معدل القبول السنوي: ${names.join('، ')} — يُوصى بمراجعة اتفاقيات التوريد وتقييم البدائل المتاحة.');
    } else if (worstSuppliers.isNotEmpty) {
      for (final ws in worstSuppliers.take(2)) {
        recommendations.add(
            'المورد "${ws['name']}" سجل معدل قبول ${(ws['approval_rate'] as num).toStringAsFixed(1)}% خلال ${ws['count']} فحص — يتطلب مراجعة جدية لموثوقية التوريد.');
      }
    }

    final activeQuarters =
        quarterlyStats.where((q) => (q['total'] as int) > 0).toList();
    if (activeQuarters.length >= 2) {
      Map<String, dynamic>? bestQ;
      Map<String, dynamic>? worstQ;
      for (final q in activeQuarters) {
        if (bestQ == null ||
            (q['approval_rate'] as num) > (bestQ['approval_rate'] as num)) {
          bestQ = q;
        }
        if (worstQ == null ||
            (q['approval_rate'] as num) < (worstQ['approval_rate'] as num)) {
          worstQ = q;
        }
      }
      if (bestQ != null &&
          worstQ != null &&
          (bestQ['approval_rate'] as num) - (worstQ['approval_rate'] as num) > 10) {
        recommendations.add(
            'تفاوت ملحوظ في الأداء بين الأرباع: أفضل ربع ${bestQ['name']} (${(bestQ['approval_rate'] as num).toStringAsFixed(1)}%) وأضعف ربع ${worstQ['name']} (${(worstQ['approval_rate'] as num).toStringAsFixed(1)}%) — يُوصى بتحليل العوامل الموسمية المؤثرة.');
      }
    }

    if (totalRejectedQty > 0 && totalQty > 0) {
      final pct = roundPct(totalRejectedQty / totalQty * 100);
      if (pct > 10) {
        recommendations.add(
            'نسبة الكمية المرفوضة السنوية تبلغ ${pct.toStringAsFixed(1)}% من إجمالي الكميات — يمثل ذلك خسارة مادية كبيرة تستوجب تنفيذ برنامج تأهيل موردين متقدم.');
      }
    }
    if (conditionalCount > 0) {
      final condPct = roundPct(conditionalCount / inspections.length * 100);
      recommendations.add(
          'تم تسجيل $conditionalCount قبول مشروط (${condPct.toStringAsFixed(1)}% من الإجمالي) — يُوصى بمتابعة جميع الشروط المعلقة وضمان إغلاقها وفق الجدول الزمني المحدد.');
    }
  }

  return {
    'year': year,
    'total': inspections.length,
    'approved': approvedCount,
    'conditional': conditionalCount,
    'partial': partialCount,
    'rejected': rejectedCount,
    'conditional_partial': conditionalCount + partialCount,
    'total_quantity': formatQuantity(totalQty),
    'total_accepted_quantity': formatQuantity(totalAcceptedQty),
    'total_rejected_quantity': formatQuantity(totalRejectedQty),
    'unique_suppliers': uniqueSuppliers.length,
    'unique_materials': materials.length,
    'approval_rate': approvalRate,
    'rejection_rate': rejectionRate,
    'materials': materialSections,
    'suppliers': supplierSections,
    'top_suppliers': topSuppliers5,
    'monthly_stats': monthlyStats,
    'quarterly_stats': quarterlyStats,
    'recommendations': recommendations,
    'department_label':
        settings['department_label'] ?? 'Quality Assurance Department',
    'report_logo_data_uri': settings['report_logo_data_uri'] ?? '',
    'now': nowIso(),
  };
}

/// Port of render_follow_up_report context.
Map<String, dynamic> buildFollowUpContext(
  List<Map<String, dynamic>> inspections, {
  required Map<String, dynamic> settings,
  required String dateStr,
  String shiftLabel = '',
}) {
  final summary =
      aggregateTotals(inspections, allowBlankSuppliers: true);
  final materialSections = buildMaterialSections(inspections);
  final formattedDate = _formatLongDate(dateStr);
  return {
    'date_str': dateStr,
    'formatted_date': formattedDate,
    'shift_label': shiftLabel,
    'total': inspections.length,
    'approved': summary['approved'],
    'conditional': summary['conditional'],
    'partial': summary['partial'],
    'rejected': summary['rejected'],
    'accepted_total': (summary['approved'] as int) + (summary['conditional'] as int),
    'conditional_partial': summary['conditional_partial'],
    'approval_rate': summary['approval_rate'],
    'total_quantity': formatQuantity(summary['total_qty']),
    'total_accepted_quantity': formatQuantity(summary['total_accepted_qty']),
    'total_rejected_quantity': formatQuantity(summary['total_rejected_qty']),
    'unique_suppliers': summary['unique_suppliers'],
    'unique_materials': summary['unique_materials'],
    'material_sections': materialSections,
    'department_label':
        settings['department_label'] ?? 'Quality Assurance Department',
    'report_logo_data_uri': settings['report_logo_data_uri'] ?? '',
    'generation_time': nowIso(),
  };
}

String _fmtDt(Object? value) {
  final text = '${value ?? ''}';
  if (text.isEmpty) return '-';
  final cut = text.length > 16 ? text.substring(0, 16) : text;
  return cut.replaceAll('T', ' ');
}

String _rangeText(Map<String, dynamic> item) {
  final minimum = item['min'];
  final maximum = item['max'];
  if (minimum == null && maximum == null) return '-';
  final unit = '${item['range_unit'] ?? ''}'
          .isNotEmpty
      ? '${item['range_unit']}'
      : ('${item['analysis_unit'] ?? ''}'.isNotEmpty ? '${item['analysis_unit']}' : '%');
  if (minimum == null) return '≤ $maximum $unit';
  if (maximum == null) return '≥ $minimum $unit';
  return '$minimum - $maximum $unit';
}

String _resultText(Map<String, dynamic> item) {
  final resultText = '${item['result_text'] ?? ''}'.trim();
  if (resultText.isEmpty) return '-';
  if (item['value'] != null) {
    final unit = '${item['range_unit'] ?? ''}'.isNotEmpty
        ? '${item['range_unit']}'
        : ('${item['analysis_unit'] ?? ''}'.isNotEmpty ? '${item['analysis_unit']}' : '%');
    return '$resultText $unit'.trim();
  }
  return resultText;
}

/// Port of render_lab_report context.
Map<String, dynamic> buildLabReportContext(
  List<Map<String, dynamic>> tests, {
  required Map<String, dynamic> settings,
  required String title,
  required String periodLabel,
}) {
  final sourceSections = <String, Map<String, dynamic>>{};
  for (final test in tests) {
    final sourceType = '${test['source_type'] ?? 'raw_material'}';
    final sourceName = '${test['source_name'] ?? ''}'.isNotEmpty
        ? '${test['source_name']}'
        : ('${test['sample_name'] ?? ''}'.isNotEmpty
            ? '${test['sample_name']}'
            : 'غير محدد');
    final section =
        sourceSections.putIfAbsent(sourceName, () => {
              'name': sourceName,
              'source_type': sourceType,
              'type_label': sourceType == 'product'
                  ? 'منتج | Product'
                  : 'خام | Raw',
              'count': 0,
              'out_count': 0,
              'rows': <Map<String, dynamic>>[],
            });
    section['count'] = (section['count'] as int) + 1;
    final state = '${test['range_state'] ?? 'none'}';
    if (state == 'out') {
      section['out_count'] = (section['out_count'] as int) + 1;
    }
    (section['rows'] as List<Map<String, dynamic>>).add({
      'index': section['count'],
      'tested_at': _fmtDt(test['tested_at']),
      'sample_name': '${test['sample_name'] ?? '-'}',
      'entry_code': '${test['entry_code'] ?? '-'}',
      'analysis_name': '${test['analysis_name'] ?? '-'}',
      'analysis_unit': '${test['analysis_unit'] ?? '%'}',
      'dynamics': test['dynamic_values'] ?? <String, dynamic>{},
      'source_type': sourceType,
      'source_name': sourceName,
      'result_text': _resultText(test),
      'value': test['value'],
      'min': test['min'],
      'max': test['max'],
      'range_text': _rangeText(test),
      'range_state': state,
      'tested_by_name': '${test['tested_by_name'] ?? '-'}',
    });
  }
  final sections = sourceSections.values.toList()
    ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
  final outCount = tests
      .where((t) => '${t['range_state'] ?? 'none'}' == 'out')
      .length;
  final inCount =
      tests.where((t) => '${t['range_state'] ?? 'none'}' == 'in').length;
  final noRangeCount =
      tests.where((t) => '${t['range_state'] ?? 'none'}' == 'none').length;
  return {
    'title': title,
    'period_label': periodLabel,
    'total': tests.length,
    'out_count': outCount,
    'in_count': inCount,
    'no_range_count': noRangeCount,
    'unique_sources': sections.length,
    'sections': sections,
    'department_label':
        settings['department_label'] ?? 'Quality Assurance Department',
    'report_logo_data_uri': settings['report_logo_data_uri'] ?? '',
    'generation_time': nowIso(),
  };
}