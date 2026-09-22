import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/reports/data/tiny_jinja.dart';

void main() {
  group('tiny_jinja engine', () {
    test('outputs variables and HTML-escapes', () {
      final out = tinyJinjaRender(
        '<p>{{ text }}</p>',
        {'text': '<b>&"quoted\''},
      );
      expect(out, '<p>&lt;b&gt;&amp;&quot;quoted&#39;</p>');
    });

    test('or fallback keeps first truthy', () {
      expect(
        tinyJinjaRender('{{ value or "-" }}', {'value': 'ok'}),
        'ok',
      );
      expect(
        tinyJinjaRender('{{ value or "-" }}', {'value': ''}),
        '-',
      );
      expect(
        tinyJinjaRender('{{ a or b }}', {
          'a': '',
          'b': 'loopval',
        }),
        'loopval',
      );
    });

    test('if / else / endif', () {
      final tpl = '{% if flag %}Y{% else %}N{% endif %}|{% if base %}B{% endif %}';
      expect(tinyJinjaRender(tpl, {'flag': true, 'base': ''}), 'Y|');
      expect(tinyJinjaRender(tpl, {'flag': null, 'base': 'x'}), 'N|B');
    });

    test('not, comparators and length filter', () {
      expect(
        tinyJinjaRender('{% if not show %}off{% endif %}', {'show': true}),
        '',
      );
      expect(
        tinyJinjaRender(
            '{% if items|length > 2 %}many{% else %}few{% endif %}',
            {'items': [1, 2, 3]}),
        'many',
      );
      expect(
        tinyJinjaRender(
            '{% if items|length > 2 %}many{% else %}few{% endif %}',
            {'items': [1]}),
        'few',
      );
    });

    test('for loop with loop.index/index0/last and is odd', () {
      const tpl =
          '{% for sn in names %}<i>{{ loop.index }}:{{ sn }}</i>{% if loop.last %}!{% endif %}{% endfor %}|'
          '{% for n in nums %}{% if loop.index is odd %}O{% else %}E{% endif %}{% endfor %}';
      final out = tinyJinjaRender(tpl, {
        'names': ['a', 'b'],
        'nums': [1, 2, 3],
      });
      expect(out, '<i>1:a</i><i>2:b</i>!|OEO');
    });

    test('attribute chains, indexing a list with loop.index0', () {
      const tpl =
          '{% for item in items %}<tr>{% for actual in item.actuals %}<td class="c{% if item.is_outs[loop.index0] %} x{% endif %}">{{ actual }}</td>{% endfor %}</tr>{% endfor %}';
      final out = tinyJinjaRender(tpl, {
        'items': [
          {'actuals': ['a1', 'a2'], 'is_outs': [true, false]},
          {'actuals': ['b1', 'b2'], 'is_outs': [false, true]},
        ],
      });
      expect(
        out,
        '<tr><td class="c x">a1</td><td class="c">a2</td></tr>'
        '<tr><td class="c">b1</td><td class="c x">b2</td></tr>',
      );
    });

    test('number formatting and missing vars render empty', () {
      expect(tinyJinjaRender('{{ n }}|{{ missing }}|{{ b }}', {
        'n': 83.3,
        'b': false,
      }), '83.3||False');
    });
  });

  group('report_template.html renders with full context shape', () {
    test('every construct in the shipped template is supported', () async {
      final template =
          await File('assets/templates/report_template.html').readAsString();
      final out = tinyJinjaRender(template, _sampleContext());
      expect(out, contains('محضر فحص خامات | Raw Material Inspection Report'));
      // Physical + chemical rows rendered.
      expect(out, contains('Moisture'));
      expect(out, contains('Ash'));
      // Sample columns looped with index headers.
      expect(out, contains('Result 1'));
      expect(out, contains('Result 2'));
      // Timeline (multi-row flag when >4 not applied here, length 2 still shown).
      expect(out, contains('تسلسل القرارات | Status Timeline'));
      expect(out, contains('v1'));
      // QR present (encrypted data-URI replaced by placeholder value here).
      expect(out, contains('qr-image'));
      expect(out, contains('Scan to view report data'));
      // Decision block.
      expect(out, contains('قرار الجودة  | QC Decision'));
      expect(out, contains('Approved / قبول'));
      expect(out, contains('Quality Assurance Department'));
      // Escaping works: an out-of-range marker class applied from is_outs.
      expect(out, contains('out-of-range'));
    });
  });
}

Map<String, dynamic> _sampleContext() => {
      'inspection_id': 42,
      'date': '2026-09-22',
      'expiry_date': '2027-09-22',
      'sample_number': 'QC-2026-042',
      'material_name': 'Sugar',
      'quantity': '25.000',
      'supplier': 'Delta',
      'truck_number': 'ABC-123',
      'sample_taken_by': 'QA Team',
      'specialist_name': 'Sara',
      'quality_specialist_name': 'Sara',
      'created_by_name': 'Admin',
      'sample_names': ['Sample A', 'Sample B'],
      'physical_data': [
        {
          'name': 'Moisture',
          'req': 'max 14%',
          'actuals': ['12.5%', '13.0%'],
          'is_outs': [false, false],
        },
      ],
      'chemical_data': [
        {
          'name': 'Ash',
          'min': '0.1',
          'max': '0.4',
          'min_display': '0.1 %',
          'max_display': '0.4 %',
          'unit': '%',
          'actuals': ['0.2 %', '0.5 %'],
          'is_outs': [false, true],
        },
      ],
      'decision_status': 'APPROVED',
      'decision_label': 'Approved / قبول',
      'decision_class': 'Approved',
      'decision_reason': '-',
      'show_decision_reason': false,
      'follow_up_note': '-',
      'rejected_quantity': '-',
      'show_follow_up_note': false,
      'show_rejected_quantity': false,
      'decision_version': 1,
      'generated_at': '2026-09-22T10:00:00',
      'updated_at': '2026-09-22T10:00:00',
      'department_label': 'Quality Assurance Department',
      'report_logo_data_uri': '',
      'status_timeline': [
        {
          'status_code': 'APPROVED',
          'label_ar': 'قبول',
          'label_en': 'Approved',
          'css_class': 'Approved',
          'reason': '-',
          'version': '1',
          'changed_at': '2026-09-22T10:00:00',
        },
      ],
      'show_status_timeline': true,
      'qr_image_data_uri': 'data:image/png;base64,placeholder',
      'qr_warning': '',
      'qr_payload_text': 'sealed',
      'base_url': '',
    };