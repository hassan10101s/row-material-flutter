import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/reports/data/report_builder.dart';
import 'package:material_lab/features/reports/data/tiny_jinja.dart';

/// Smoke-renders every shipped template with representative contexts (built by
/// the same [report_builder] builders the service uses) to prove the template
/// engine covers the exact constructs the copied Vue templates rely on:
/// `{% set %}` / `namespace()` / `{% elif %}` / inline ternary / `and` /
/// `range()` / `.lower()` / `+` / `|trim` and `{% for %}`-`{% else %}`.
void main() {
  const settings = <String, dynamic>{
    'department_label': 'Quality Assurance Department',
    'report_logo_data_uri': '',
  };

  group('all shipped templates render with tiny_jinja', () {
    test('daily_report_template.html', () {
      final ctx = buildDailyContext(
        [_row()],
        settings: settings,
        dateStr: '2026-09-22',
      );
      final out = tinyJinjaRender(_tpl('daily_report_template.html'), ctx);
      expect(out, contains('2026-09-22'));
      expect(out, contains('Daily Quality Report'));
      expect(out, isNot(contains(r'{{')));
    });

    test('followup_report_template.html', () {
      final ctx = buildFollowUpContext(
        [_row()],
        settings: settings,
        dateStr: '2026-09-22',
      );
      final out = tinyJinjaRender(_tpl('followup_report_template.html'), ctx);
      expect(out, contains('2026-09-22'));
      expect(out, contains('Quality Follow-Up Report'));
      expect(out, isNot(contains(r'{{')));
    });

    test('monthly_report_template.html', () {
      final ctx = buildMonthlyContext(
        [_row()],
        settings: settings,
        month: 9,
        year: 2026,
        trendRows: const [],
      );
      final out = tinyJinjaRender(_tpl('monthly_report_template.html'), ctx);
      expect(out, contains('2026'));
      expect(out, contains('September'));
      expect(out, isNot(contains(r'{{')));
    });

    test('yearly_report_template.html', () {
      final ctx = buildYearlyContext(
        [_row()],
        settings: settings,
        year: 2026,
      );
      final out = tinyJinjaRender(_tpl('yearly_report_template.html'), ctx);
      expect(out, contains('2026'));
      expect(out, isNot(contains(r'{{')));
    });

    test('label_template.html', () {
      final ctx = buildLabelContext(
        _row(entryCode: 'QC-100'),
        settings: settings,
      )..['qr_image_data_uri'] = '';
      final out = tinyJinjaRender(_tpl('label_template.html'), ctx);
      expect(out, contains('QC-100'));
      expect(out, isNot(contains(r'{{')));
    });

    test('batch_label_template.html', () {
      final ctx = buildBatchLabelsContext(
        [_row(entryCode: 'QC-100'), _row(entryCode: 'QC-101')],
        settings: settings,
      );
      final out = tinyJinjaRender(_tpl('batch_label_template.html'), ctx);
      expect(out, contains('Batch Labels'));
      expect(out, contains('QC-100'));
      expect(out, contains('QC-101'));
      expect(out, isNot(contains(r'{{')));
    });

    test('lab_report_template.html', () {
      final ctx = buildLabReportContext(
        <Map<String, dynamic>>[],
        settings: settings,
        title: 'Lab Tests | فحوصات المعمل',
        periodLabel: '2026-09-22',
      );
      final out = tinyJinjaRender(_tpl('lab_report_template.html'), ctx);
      expect(out, contains('Total Tests'));
      expect(out, isNot(contains(r'{{')));
    });

    test('report_template.html (full inspection)', () {
      final ctx = buildInspectionContext(
        _row(),
        settings: settings,
      )..['qr_image_data_uri'] = '';
      final out = tinyJinjaRender(_tpl('report_template.html'), ctx);
      expect(out, contains('Quality Control Report'));
      expect(out, isNot(contains(r'{{')));
    });
  });

  group('new engine constructs (regression)', () {
    test('set / namespace member assignment persists across a loop', () {
      const tpl = '''
{% set ns = namespace(has=false, count=0) %}
{% for row in rows %}{% set ns.has = true %}{% set ns.count = ns.count + 1 %}{% endfor %}
{{ ns.has }}|{{ ns.count }}''';
      expect(
        tinyJinjaRender(tpl, {'rows': [1, 2, 3]}),
        contains('True|3'),
      );
    });

    test('elif and for-else', () {
      expect(
        tinyJinjaRender(
            '{% for x in items %}{{ x }}{% else %}none{% endfor %}',
            {'items': <int>[]}),
        'none',
      );
      expect(
        tinyJinjaRender(
            '{% for x in items %}{{ x }}{% else %}none{% endfor %}',
            {'items': [1]}),
        '1',
      );
      expect(
        tinyJinjaRender('{% if s == "a" %}A{% elif s == "b" %}B{% else %}C{% endif %}',
            {'s': 'b'}),
        'B',
      );
    });

    test('inline ternary (incl. nested) and and/or', () {
      expect(
        tinyJinjaRender(
            "{{ 'high' if r >= 90 else ('medium' if r >= 70 else 'low') }}",
            {'r': 95}),
        'high',
      );
      expect(
        tinyJinjaRender(
            "{{ 'high' if r >= 90 else ('medium' if r >= 70 else 'low') }}",
            {'r': 50}),
        'low',
      );
      expect(
        tinyJinjaRender(
            '{% if a and b == "-" %}yes{% else %}no{% endif %}',
            {'a': 'x', 'b': '-'}),
        'yes',
      );
      expect(
        tinyJinjaRender(
            "{{ x if x else 'fallback' }}",
            {'x': 0}),
        'fallback',
      );
    });

    test('range() + arithmetic + list indexing', () {
      const tpl = '''
{% for page_start in range(0, labels|length, 2) %}{% for i in range(2) %}{% set idx = page_start + i %}{% if idx < labels|length %}{{ labels[idx] }}{% endif %}{% endfor %}|{% endfor %}''';
      final out = tinyJinjaRender(tpl, {'labels': ['a', 'b', 'c']});
      expect(out, 'ab|c|');
    });

    test('.lower() call and |trim filter', () {
      expect(
        tinyJinjaRender('{% set d = s.lower() %}>{{ d }}<', {'s': 'ABC'}),
        '>abc<',
      );
      expect(
        tinyJinjaRender('{% if v|trim != "" %}yes{% endif %}', {'v': '  x '}),
        'yes',
      );
    });
  });
}

Map<String, dynamic> _row({String entryCode = 'QC-001'}) => {
      'id': 1,
      'entry_code': entryCode,
      'material_name': 'Sugar',
      'inspection_date': '2026-09-22',
      'expiry_date': '2027-09-22',
      'supplier': 'Delta',
      'truck_number': 'ABC-123',
      'quantity': '25.000',
      'rejected_quantity': '0',
      'sample_taken_by': 'QA Team',
      'specialist_name': 'Sara',
      'created_by_name': 'Admin',
      'decision_status': 'APPROVED',
      'decision_reason': '',
      'follow_up_note': '-',
      'updated_at': '2026-09-22T10:00:00',
      'sample_names': const ['Sample A', 'Sample B'],
      'physical_reference': <String, dynamic>{},
      'physical_results': <String, dynamic>{},
      'chemical_reference': <String, dynamic>{},
      'chemical_results': <String, dynamic>{},
      'status_history': <dynamic>[],
    };

String _tpl(String name) =>
    File('assets/templates/$name').readAsStringSync();