import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/reports/data/html_pdf_exporter.dart';
import 'package:material_lab/features/reports/data/report_html_builder.dart';
import 'package:material_lab/features/reports/data/report_service.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';
import 'package:material_lab/core/constants/app_strings.dart';

class _Db extends Mock implements DatabaseHelper {}

class _Secret extends Mock implements LocalSecret {}

class _Inspections extends Mock implements InspectionRepo {}

class _Lab extends Mock implements LabRepo {}

class _Settings extends Mock implements SettingsRepo {}

class _Builder extends Mock implements ReportHtmlBuilder {}

class _Exporter extends HtmlPdfExporter {
  String html = '';
  @override
  Future<Uint8List> exportPdf(
    String html, {
    String? baseHref,
    bool noPageOverride = false,
  }) async {
    this.html = html;
    return Uint8List.fromList('%PDF-test'.codeUnits);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppText.useLanguage('en'));

  test(
    'Android labels retain their centimeter dimensions; batch labels retain margins',
    () async {
      final exporter = HtmlPdfExporter();
      final request = await exporter.androidRequest(
        '''<html><head>
      <link rel="stylesheet" href="fonts/fonts.css">
      <style>@page { size: 10cm 5cm; margin: 0; }</style></head><body>اختبار</body></html>''',
        noPageOverride: true,
      );
      expect(request['widthMils'], 3937);
      expect(request['heightMils'], 1969);
      expect(request['topMils'], 0);
      expect(request['html'], contains('data:font/woff2;base64,'));
      expect(request['html'], isNot(contains('href="fonts/fonts.css"')));
      final batch = await exporter.androidRequest(
        '<html><head><style>@page { size:A4; margin:5mm 4mm; }</style></head></html>',
        noPageOverride: true,
      );
      expect(batch['topMils'], 197);
      expect(batch['leftMils'], 157);
      final landscape = await exporter.androidRequest(
        '<html><head><style>@page { size:A4 landscape; }</style></head></html>',
      );
      expect(landscape['widthMils'], 11693);
      expect(landscape['heightMils'], 8268);
      expect(landscape['topMils'], 354);
      expect(landscape['leftMils'], 315);
    },
  );

  test(
    'default inspection HTML is unchanged; detailed export is optional and escaped',
    () async {
      final settings = _Settings();
      final inspections = _Inspections();
      final lab = _Lab();
      final builder = _Builder();
      final exporter = _Exporter();
      final record = <String, dynamic>{
        'material_name': 'Cement',
        'entry_code': 'CEM-001',
        'inspection_kind': 'raw',
        'lab_tests': [
          {
            'analysis_name': '<script>bad</script>',
            'analysis_reference': 'ISO 123',
            'sample_name': 'A',
            'result_text': '12.5',
            'analysis_unit': '%',
            'dynamic_values_json': '{"weight":3.5}',
            'tested_at': '2026-10-01',
          },
        ],
      };
      when(() => settings.getSettings()).thenAnswer((_) async => {});
      when(() => inspections.getById(1)).thenAnswer((_) async => record);
      when(() => lab.injectLabTests(record)).thenAnswer((_) async => record);
      when(
        () => builder.buildContext(record),
      ).thenAnswer((_) async => {'material_name': 'Cement'});
      final service = ReportService(
        dbHelper: _Db(),
        settingsRepo: settings,
        inspectionRepo: inspections,
        labRepo: lab,
        secret: _Secret(),
        htmlBuilder: builder,
        htmlPdf: exporter,
      );
      await service.inspectionReport(1);
      expect(exporter.html, isNot(contains('<h3>Analysis details</h3>')));
      await service.inspectionReport(1, includeAnalysisDetails: true);
      expect(exporter.html, contains('<h3>Analysis details</h3>'));
      expect(exporter.html, contains('&lt;script&gt;bad&lt;/script&gt;'));
      expect(exporter.html, contains('weight: 3.5'));
      expect(exporter.html, contains('ISO 123'));
    },
  );
}
