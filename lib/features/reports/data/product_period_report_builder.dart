import '../../../core/constants/report_form_keys.dart';
import '../../reference/data/reference_repo.dart' show decisionMeta;
import '../../../core/utils/report_language.dart';
import '../../lab/domain/product_batch_repository.dart';
import 'report_builder.dart' show qaFormNo;

/// Pure cache report. Monthly means give each sample one vote; annual means
/// give each report one vote, regardless of its quantity or sample count.
Map<String, dynamic> buildProductPeriodContext({
  required String type,
  required String period,
  required List<Map<String, dynamic>> inspections,
  required List<Map<String, dynamic>> samples,
  required Map<String, dynamic> settings,
}) => ReportText.withSettings(settings, () {
  final byHeader = <Object?, List<Map<String, dynamic>>>{};
  for (final sample in samples) {
    if (sample['deleted_at'] != null) continue;
    (byHeader[sample['batch_id']] ??= []).add(sample);
  }
  final reports = <Map<String, dynamic>>[];
  final batches = <(String, String, String), List<Map<String, dynamic>>>{};
  for (final header in inspections) {
    if (header['deleted_at'] != null ||
        header['inspection_kind'] != 'product') {
      continue;
    }
    final rows = byHeader[header['id']] ?? const <Map<String, dynamic>>[];
    final report = <String, dynamic>{
      'entry_code': header['entry_code'] ?? '-',
      'material_name': header['material_name'] ?? '-',
      'date': '${header['inspection_date'] ?? ''}'.split('T').first,
      'batch': '${header['batch_number'] ?? ''}'.trim(),
      'quantity_value': _number(header['quantity']) ?? 0.0,
      'quantity': _format(_number(header['quantity'])),
      'sample_count': rows.length,
      'report_count': 1,
      'results': _averages([for (final sample in rows) _measurements(sample)]),
      'samples': [
        for (final sample in rows)
          {
            'name':
                '${sample['sample_no'] ?? ''} - ${sample['sample_name'] ?? ''}',
            'taker': sample['sample_taker'] ?? '-',
            'decision': _decision(sample['decision_status']),
            'reason': sample['decision_reason'] ?? '',
            'results': _measurements(sample),
          },
      ],
    };
    if (type == 'daily') {
      report['sample_tables'] = _sampleTables(
        report['samples'] as List<Map<String, dynamic>>,
      );
    }
    reports.add(report);
    final batch = report['batch'] as String;
    // Blank batch numbers never collapse unrelated reports. Products and
    // formula revisions with reused batch numbers remain separate.
    final key = (
      '${header['product_id'] ?? header['material_name']}',
      '${header['formula_number'] ?? ''}',
      batch.isEmpty ? 'report:${header['id']}' : 'batch:$batch',
    );
    (batches[key] ??= []).add(report);
  }
  final sections = type != 'yearly'
      ? reports
      : <Map<String, dynamic>>[
          for (final group in batches.values)
            {
              'material_name': group.first['material_name'],
              'batch': group.first['batch'],
              'quantity': _format(
                group.fold<double>(
                  0,
                  (sum, row) => sum + (row['quantity_value'] as double),
                ),
              ),
              'sample_count': group.fold<int>(
                0,
                (sum, row) => sum + (row['sample_count'] as int),
              ),
              'report_count': group.length,
              'reports': group,
              'results': _averages([
                for (final row in group)
                  (row['results'] as List<Map<String, dynamic>>),
              ]),
            },
        ];
  return {
    'is_en': !ReportText.arabic,
    'daily': type == 'daily',
    'yearly': type == 'yearly',
    'title': switch (type) {
      'monthly' => ReportText.t(
        'التقرير الشهري لفحوص المنتجات',
        'Monthly product inspection report',
      ),
      'yearly' => ReportText.t(
        'التقرير السنوي لفحوص المنتجات',
        'Yearly product inspection report',
      ),
      _ => ReportText.t(
        'التقرير اليومي لفحوص المنتجات',
        'Daily product inspection report',
      ),
    },
    'period': period,
    'organization_name': settings['organization_name'] ?? '',
    'department_label': ReportText.department(settings),
    'report_logo_data_uri': settings['report_logo_data_uri'] ?? '',
    'form_no': qaFormNo(settings, switch (type) {
      'monthly' => ReportFormKeys.productMonthlyReport,
      'yearly' => ReportFormKeys.productYearlyReport,
      _ => ReportFormKeys.productDailyReport,
    }),
    'report_count': reports.length,
    'sample_count': reports.fold<int>(
      0,
      (sum, row) => sum + (row['sample_count'] as int),
    ),
    'batch_count': batches.length,
    'total_quantity': _format(
      reports.fold<double>(
        0,
        (sum, row) => sum + (row['quantity_value'] as double),
      ),
    ),
    'note': type == 'daily'
        ? ReportText.t(
            'النتائج والقرارات كما سُجلت لكل عينة. الكمية تخص المحضر، ولا تتكرر بعدد العينات.',
            'Results and decisions as recorded per sample. Quantities belong to reports and are counted once.',
          )
        : type == 'yearly'
        ? ReportText.t(
            'متوسط عادي لمتوسطات المحاضر لكل تشغيلة داخل السنة المختارة؛ دون وزن بالكميات أو عدد العينات. القيم المفقودة لا تُحسب صفرًا. تفصل الوحدات المختلفة، والنتائج الوصفية لا يُحسب لها متوسط رقمي.',
            'Unweighted mean of report means per batch within the selected year. Missing values are excluded, not zero. Different units stay separate; descriptive results have no numeric mean.',
          )
        : ReportText.t(
            'متوسط عادي لعينات كل محضر داخل الشهر المختار. القيم المفقودة لا تُحسب صفرًا. تفصل الوحدات المختلفة، والنتائج الوصفية لا يُحسب لها متوسط رقمي.',
            'Unweighted sample means per report within the selected month. Missing values are excluded, not zero. Different units stay separate; descriptive results have no numeric mean.',
          ),
    'sections': sections,
  };
});

String _decision(Object? status) {
  if ('${status ?? ''}'.isEmpty) return '-';
  final meta = decisionMeta('$status');
  return ReportText.t('${meta['label_ar']}', '${meta['label_en']}');
}

double? _number(Object? value) {
  var text = '${value ?? ''}'.trim();
  for (var i = 0; i < 10; i++) {
    text = text.replaceAll('٠١٢٣٤٥٦٧٨٩'[i], '$i');
  }
  final parsed = double.tryParse(text.replaceAll('٫', '.'));
  return parsed != null && parsed.isFinite ? parsed : null;
}

String _format(num? value) => value == null ? '-' : value.toStringAsFixed(3);

/// At most eight sample columns per block. More samples continue in the next
/// block, preserving readable text and every result rather than shrinking A4.
List<Map<String, dynamic>> _sampleTables(List<Map<String, dynamic>> samples) {
  final tables = <Map<String, dynamic>>[];
  for (var start = 0; start < samples.length; start += 8) {
    final end = start + 8 < samples.length ? start + 8 : samples.length;
    final headers = samples.sublist(start, end);
    final rows = <(String, String, String), List<List<String>>>{};
    for (var index = 0; index < headers.length; index++) {
      for (final result
          in headers[index]['results'] as List<Map<String, dynamic>>) {
        final key = (
          '${result['kind']}',
          '${result['analysis_name']}',
          '${result['unit'] ?? ''}',
        );
        final cells = rows.putIfAbsent(
          key,
          () => List.generate(headers.length, (_) => <String>[]),
        );
        final value = '${result['value'] ?? ''}'.trim();
        if (value.isNotEmpty) cells[index].add(value);
      }
    }
    tables.add({
      'headers': headers,
      'rotate': headers.length >= 6,
      'sample_width': 68 / headers.length,
      'rows': [
        for (final entry in rows.entries)
          {
            'analysis_name': entry.key.$2,
            'unit': entry.key.$3,
            'cells': [
              for (final cell in entry.value)
                cell.isEmpty ? '-' : cell.join(' / '),
            ],
          },
      ],
    });
  }
  return tables;
}

List<Map<String, dynamic>> _measurements(Map<String, dynamic> sample) => [
  for (final entry in decodeBatchPhysical(
    sample['physical_results_json'],
  ).entries)
    {
      'kind': 'physical',
      'analysis_name': entry.key,
      'unit': '',
      'value': entry.value,
      'mean': _number(entry.value),
    },
  for (final row in decodeBatchChemical(sample['chemical_results_json']))
    {
      'kind': 'chemical',
      'analysis_name': row['name'],
      'unit': row['unit'],
      'value': row['result'],
      'mean': _number(row['result']),
    },
];

List<Map<String, dynamic>> _averages(List<List<Map<String, dynamic>>> groups) {
  final numeric = <(String, String, String), List<double>>{};
  final text = <(String, String, String), Set<String>>{};
  for (final group in groups) {
    final perGroup = <(String, String, String), List<double>>{};
    for (final row in group) {
      final key = (
        '${row['kind']}',
        '${row['analysis_name']}',
        '${row['unit'] ?? ''}',
      );
      numeric.putIfAbsent(key, () => []);
      final mean = row['mean'] as double?;
      if (mean != null) {
        (perGroup[key] ??= []).add(mean);
        final description = '${row['descriptive'] ?? ''}'.trim();
        if (description.isNotEmpty) (text[key] ??= {}).add(description);
      } else {
        final value = '${row['value'] ?? ''}'.trim();
        if (value.isNotEmpty && value != '-') (text[key] ??= {}).add(value);
      }
    }
    for (final entry in perGroup.entries) {
      numeric[entry.key]!.add(
        entry.value.reduce((a, b) => a + b) / entry.value.length,
      );
    }
  }
  return [
    for (final entry in numeric.entries)
      {
        'kind': entry.key.$1,
        'analysis_name': entry.key.$2,
        'unit': entry.key.$3,
        'count': entry.value.isEmpty ? '-' : entry.value.length,
        'mean': entry.value.isEmpty
            ? null
            : entry.value.reduce((a, b) => a + b) / entry.value.length,
        'value': entry.value.isEmpty
            ? (text[entry.key]?.join(' / ') ?? '-')
            : _format(entry.value.reduce((a, b) => a + b) / entry.value.length),
        'descriptive': entry.value.isEmpty
            ? ''
            : text[entry.key]?.join(' / ') ?? '',
      },
  ];
}
