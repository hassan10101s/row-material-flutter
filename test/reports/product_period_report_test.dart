import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/reports/data/product_period_report_builder.dart';
import 'package:material_lab/features/reports/data/tiny_jinja.dart';
import 'package:material_lab/features/reports/data/html_pdf_exporter.dart';

Map<String, dynamic> header(
  int id, {
  String batch = 'B-15',
  int product = 1,
  String formula = 'F1',
  num quantity = 10,
}) => {
  'id': id,
  'inspection_kind': 'product',
  'entry_code': 'P-$id',
  'inspection_date': '2026-11-02',
  'product_id': product,
  'material_name': 'Starter | بادئ',
  'formula_number': formula,
  'batch_number': batch,
  'quantity': quantity,
};
Map<String, dynamic> sample(
  int id,
  int parent,
  Object? protein, {
  String unit = '%',
  bool deleted = false,
}) => {
  'id': id,
  'batch_id': parent,
  'sample_no': id,
  'sample_name': 'Sample $id',
  'sample_taker': 'Mohamed Said',
  'decision_status': 'APPROVED',
  'deleted_at': deleted ? '2026-11-02' : null,
  'physical_results_json': jsonEncode({'Color': 'Yellow'}),
  'chemical_results_json': jsonEncode([
    {'name': 'Protein | بروتين', 'result': protein, 'unit': unit},
  ]),
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> context(String type, {String language = 'en'}) =>
      buildProductPeriodContext(
        type: type,
        period: type == 'daily'
            ? '2026-11-02'
            : type == 'yearly'
            ? '2026'
            : '2026-11',
        settings: {
          'report_language': language,
          'organization_name': 'Laboratory Company',
          'qa_form_no': 'QA-01',
        },
        inspections: [header(1, quantity: 10), header(2, quantity: 90)],
        samples: [
          sample(1, 1, '10'),
          sample(2, 1, '20'),
          sample(3, 1, null),
          sample(4, 2, '50'),
          sample(5, 2, '1000', deleted: true),
        ],
      );
  test(
    'monthly means exclude missing and deleted values; quantity counted once per report',
    () {
      final ctx = context('monthly');
      final sections = ctx['sections'] as List;
      expect(ctx['report_count'], 2);
      expect(ctx['sample_count'], 4);
      expect(ctx['total_quantity'], '100.000');
      expect(sections[0]['results'][1]['mean'], 15);
      expect(sections[0]['results'][1]['count'], 2);
      expect(sections[1]['results'][1]['mean'], 50);
    },
  );
  test(
    'annual mean weights reports equally even with unequal sample counts and quantities',
    () {
      final ctx = context('yearly');
      final section = (ctx['sections'] as List).single;
      expect(
        section['results'][1]['mean'],
        32.5,
      ); // (15 + 50) / 2, not 26.667 or 46.5.
      expect(section['results'][1]['count'], 2);
      expect(section['quantity'], '100.000');
      expect(section['report_count'], 2);
      expect(section['reports'], hasLength(2));
    },
  );
  test(
    'annual groups distinguish products, formulas and missing batch numbers; units stay separate',
    () {
      final ctx = buildProductPeriodContext(
        type: 'yearly',
        period: '2026',
        settings: {},
        inspections: [
          header(1),
          header(2, product: 2),
          header(3, formula: 'F2'),
          header(4, batch: ''),
          header(5, batch: ''),
        ],
        samples: [
          sample(1, 1, '0'),
          sample(2, 1, '10', unit: 'g/kg'),
          sample(3, 1, 'NaN'),
        ],
      );
      expect(ctx['batch_count'], 5);
      final results = (ctx['sections'] as List).first['results'] as List;
      expect(results.where((row) => row['unit'] == '%').single['mean'], 0);
      expect(results.where((row) => row['unit'] == 'g/kg').single['mean'], 10);
    },
  );
  test(
    'daily retains every active sample and historical names, results and decisions',
    () {
      final ctx = context('daily');
      final first = (ctx['sections'] as List).first;
      expect(first['samples'], hasLength(3));
      expect(first['samples'][0]['taker'], 'Mohamed Said');
      expect(first['samples'][0]['results'][1]['value'], '10');
      expect(first['samples'][0]['decision'], isNotEmpty);
    },
  );
  test(
    'daily matrix retains column order, missing cells and every sample across blocks',
    () {
      final ctx = buildProductPeriodContext(
        type: 'daily',
        period: '2026-11-02',
        settings: {},
        inspections: [header(1)],
        samples: [
          for (var i = 1; i <= 19; i++) sample(i, 1, i == 4 ? null : '$i'),
        ],
      );
      final tables = (ctx['sections'] as List).single['sample_tables'] as List;
      expect(tables.map((table) => (table['headers'] as List).length), [
        8,
        8,
        3,
      ]);
      expect(tables.map((table) => table['rotate']), [true, true, false]);
      final lastRow = tables.last['rows'][1];
      expect(lastRow['cells'], ['17', '18', '19']);
      expect(tables.first['rows'][1]['cells'][3], '-');
    },
  );
  for (final lang in ['ar', 'en']) {
    test(
      'product template $lang escapes names and uses one report language',
      () async {
        final ctx = context('yearly', language: lang);
        ctx['organization_name'] = '<script>unsafe</script>';
        final html = tinyJinjaRender(
          await File(
            'assets/templates/product_period_report_template.html',
          ).readAsString(),
          ctx,
        );
        expect(
          html,
          contains(
            lang == 'ar' ? 'lang="ar" dir="rtl"' : 'lang="en" dir="ltr"',
          ),
        );
        expect(
          html,
          contains(
            lang == 'ar'
                ? 'التقرير السنوي لفحوص المنتجات'
                : 'Yearly product inspection report',
          ),
        );
        expect(
          html,
          isNot(
            contains(
              lang == 'ar'
                  ? 'Yearly product inspection report'
                  : 'التقرير السنوي لفحوص المنتجات',
            ),
          ),
        );
        expect(html, contains(lang == 'ar' ? '>بروتين<' : '>Protein<'));
        expect(html, contains('32.500'));
        expect(html, contains('&lt;script&gt;unsafe&lt;/script&gt;'));
        expect(html, isNot(contains('{{')));
      },
    );
  }
  test(
    'product reports render daily, monthly and annual PDFs in both languages',
    () async {
      final exporter = HtmlPdfExporter();
      if (await exporter.findBrowser() == null) {
        markTestSkipped('Headless browser unavailable');
        return;
      }
      final template = await File(
        'assets/templates/product_period_report_template.html',
      ).readAsString();
      final output = Directory(
        'backup/desktop_import_20261028/product_report_qa',
      );
      await output.create(recursive: true);
      for (final type in ['daily', 'monthly', 'yearly']) {
        for (final language in ['ar', 'en']) {
          var ctx = context(type, language: language);
          // Wide sample matrices exercise rotation, continuation and page breaks.
          if (type == 'daily') {
            ctx = buildProductPeriodContext(
              type: type,
              period: '2026-11-02',
              settings: {
                'report_language': language,
                'organization_name': language == 'ar'
                    ? 'شركة المعمل للصناعات الغذائية'
                    : 'Laboratory Company',
              },
              inspections: [header(1)],
              samples: [
                for (var i = 1; i <= 27; i++)
                  {
                    ...sample(i, 1, '${i * 1.25}'),
                    'sample_name': language == 'ar'
                        ? 'العينة رقم $i'
                        : 'Sample $i',
                  },
              ],
            );
          }
          ctx['report_logo_data_uri'] =
              'data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="42"><rect width="100" height="42" rx="8" fill="#182537"/><text x="50" y="28" text-anchor="middle" fill="white" font-size="22">ML</text></svg>'))}';
          final html = tinyJinjaRender(template, ctx);
          final pdf = await exporter.exportPdf(html);
          expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
          await File('${output.path}/${type}_$language.pdf').writeAsBytes(pdf);
          await File(
            '${output.path}/${type}_$language.html',
          ).writeAsString(await exporter.standaloneHtml(html));
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
