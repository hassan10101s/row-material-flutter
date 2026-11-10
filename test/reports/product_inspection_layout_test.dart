import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/reports/data/html_pdf_exporter.dart';
import 'package:material_lab/features/reports/data/pdf_renderer.dart';
import 'package:material_lab/features/reports/data/report_builder.dart';
import 'package:material_lab/features/reports/data/tiny_jinja.dart';

Map<String, dynamic> productInspection({int count = 3, bool arabic = false}) =>
    {
      'id': 1,
      'entry_code': 'PRODUCT-2026-001',
      'inspection_kind': 'product',
      'material_name': arabic ? 'علف نامي دواجن' : 'Poultry grower feed',
      'inspection_date': '2026-11-09',
      'formula_number': 'F-21',
      'batch_number': 'B-100',
      'quantity': '50',
      'decision_status': 'APPROVED',
      'sample_names': <String>[],
      'physical_reference': <String, dynamic>{},
      'chemical_reference': <String, dynamic>{},
      'physical_results': <String, dynamic>{},
      'chemical_results': <String, dynamic>{},
      'batch_samples': [
        for (var i = 1; i <= count; i++)
          {
            'sample_no': i,
            'sample_name': arabic ? 'عينة $i' : 'Sample $i',
            'sample_taker': arabic ? 'أحمد محمود' : 'Ahmed Mahmoud',
            'tested_by_name_resolved': arabic ? 'محمد حسن' : 'Mohamed Hassan',
            'tested_at': '2026-11-09 10:${i.toString().padLeft(2, '0')}',
            'decision_status': 'APPROVED',
            'physical_results_json': jsonEncode({
              arabic ? 'اللون' : 'Color': arabic ? 'طبيعي' : 'Normal',
            }),
            'chemical_results_json': jsonEncode([
              {
                'name': arabic ? 'بروتين' : 'Protein',
                'result': '${20 + i / 10}',
                'unit': '%',
              },
              if (i != 2)
                {'name': arabic ? 'دهون' : 'Fat', 'result': '3.5', 'unit': '%'},
              {
                'name': arabic ? 'رطوبة' : 'Moisture',
                'result': '11.2',
                'unit': '%',
              },
              {'name': arabic ? 'رماد' : 'Ash', 'result': '6.1', 'unit': '%'},
            ]),
          },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'parameters are columns and samples are rows, with missing readings aligned',
    () {
      final ctx = buildInspectionContext(
        productInspection(),
        settings: {'report_language': 'en'},
      );
      final columns = ctx['batch_result_columns'] as List;
      final rows = ctx['batch_result_rows'] as List;
      expect(columns.map((c) => c['name']), [
        'Color',
        'Protein',
        'Fat',
        'Moisture',
        'Ash',
      ]);
      expect(rows, hasLength(3));
      expect(rows[0]['values'], ['Normal', '20.1', '3.5', '11.2', '6.1']);
      expect(rows[1]['values'], ['Normal', '20.2', '-', '11.2', '6.1']);
      expect(rows[2]['label'], contains('Sample 3'));
    },
  );

  test('units and physical/chemical name collisions stay distinct', () {
    final row = productInspection(count: 1);
    (row['batch_samples'] as List).single['chemical_results_json'] = jsonEncode(
      [
        {'name': 'Color', 'result': '1', 'unit': 'g'},
        {'name': 'Color', 'result': '2', 'unit': 'kg'},
      ],
    );
    final ctx = buildInspectionContext(
      row,
      settings: {'report_language': 'en'},
    );
    expect(ctx['batch_result_columns'], hasLength(3));
    expect((ctx['batch_result_rows'] as List).single['values'], [
      'Normal',
      '1',
      '2',
    ]);
  });

  test(
    'production HTML/PDF renders a full-width multipage sample matrix in both languages',
    () async {
      final exporter = HtmlPdfExporter();
      if (await exporter.findBrowser() == null) {
        markTestSkipped('Headless Edge/Chrome unavailable');
        return;
      }
      final template = await File(
        'assets/templates/report_template.html',
      ).readAsString();
      addTearDown(() => AppText.arabic = true);
      for (final language in ['ar', 'en']) {
        final ctx = buildInspectionContext(
          productInspection(count: 40, arabic: language == 'ar'),
          settings: {
            'report_language': language,
            'organization_name': language == 'ar'
                ? 'شركة الصناعات الغذائية'
                : 'Food Industries Company',
          },
        )..['qr_image_data_uri'] = '';
        final html = tinyJinjaRender(template, ctx);
        expect(html, contains('product-sample-results'));
        expect(html, isNot(contains('colspan="2"')));
        expect(html, isNot(contains('{{')));
        final bytes = await exporter.exportPdf(html);
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        AppText.arabic = language == 'ar';
        final native = await PdfRenderer.renderInspection(ctx);
        expect(String.fromCharCodes(native.take(5)), '%PDF-');
        final qa = Platform.environment['MATERIALLAB_REPORT_QA'];
        if (qa != null) {
          await Directory(qa).create(recursive: true);
          await File(
            '$qa/product_inspection_$language.pdf',
          ).writeAsBytes(bytes);
          await File(
            '$qa/product_inspection_$language.html',
          ).writeAsString(await exporter.standaloneHtml(html));
          if (language == 'ar') {
            final preview = buildInspectionContext(
              productInspection(arabic: true),
              settings: {
                'report_language': 'ar',
                'organization_name': 'شركة الصناعات الغذائية',
              },
            )..['qr_image_data_uri'] = ctx['qr_image_data_uri'];
            await File('$qa/product_inspection_preview.pdf').writeAsBytes(
              await exporter.exportPdf(tinyJinjaRender(template, preview)),
            );
          }
        }
      }
      AppText.arabic = true;
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
