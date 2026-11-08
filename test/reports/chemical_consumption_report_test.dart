import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/lab/domain/chemical_consumption_report.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reports/data/chemical_consumption_report_builder.dart';
import 'package:material_lab/features/reports/data/html_pdf_exporter.dart';
import 'package:material_lab/features/reports/data/report_service.dart';
import 'package:material_lab/features/reports/data/tiny_jinja.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';

class _Db extends Mock implements DatabaseHelper {}

class _Secret extends Mock implements LocalSecret {}

class _Inspection extends Mock implements InspectionRepo {}

class _Lab extends Mock implements LabRepo {}

class _Settings extends Mock implements SettingsRepo {}

class _Guard extends Mock implements WriteGuard {}

class _Exporter extends HtmlPdfExporter {
  String captured = '';
  @override
  Future<Uint8List> exportPdf(
    String html, {
    String? baseHref,
    bool noPageOverride = false,
  }) async {
    captured = html;
    return Uint8List.fromList('%PDF-test'.codeUnits);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Settings settings;
  late _Exporter exporter;
  late ReportService service;
  final period = ConsumptionPeriod(DateTime(2026, 8, 1), DateTime(2026, 11, 1));
  ChemicalConsumptionReport report({
    bool many = false,
  }) => ChemicalConsumptionReport(
    period: period,
    chemicals: [
      const ChemicalConsumptionRow(
        inventoryId: 1,
        name: 'Sulfuric acid | حمض الكبريتيك',
        unit: 'mL',
        consumed: 150.5,
        returned: 15,
      ),
      const ChemicalConsumptionRow(
        inventoryId: 2,
        name: '<script>alert(1)</script>',
        unit: 'kg',
        consumed: 0,
        returned: 0.25,
      ),
      if (many)
        for (var i = 3; i <= 85; i++)
          ChemicalConsumptionRow(
            inventoryId: i,
            name:
                'Chemical $i | مادة كيميائية رقم $i ذات اسم طويل لاختبار تنظيم التقرير',
            unit: i.isEven ? 'g' : 'pc',
            consumed: i * 1.25,
            returned: 0,
          ),
    ],
  );
  setUp(() {
    settings = _Settings();
    exporter = _Exporter();
    service = ReportService(
      dbHelper: _Db(),
      settingsRepo: settings,
      inspectionRepo: _Inspection(),
      labRepo: _Lab(),
      secret: _Secret(),
      htmlPdf: exporter,
    );
  });
  tearDown(() => AppText.useLanguage('ar'));

  for (final en in [false, true]) {
    test(
      'chemical report ${en ? 'English' : 'Arabic'} uses settings language, branding, escaped names, and the same numbers for print and PDF',
      () async {
        AppText.useLanguage(
          en ? 'ar' : 'en',
        ); // Deliberately opposite UI language.
        when(settings.getSettings).thenAnswer(
          (_) async => {
            'report_language': en ? 'en' : 'ar',
            'organization_name': 'شركة الاختبار',
            'report_logo_data_uri': 'data:image/png;base64,logo',
          },
        );
        final html = await service.chemicalConsumptionHtml(report());
        expect(
          html,
          contains(en ? 'lang="en" dir="ltr"' : 'lang="ar" dir="rtl"'),
        );
        expect(
          html,
          contains(
            en ? 'Chemical consumption report' : 'تقرير استهلاك الكيماويات',
          ),
        );
        expect(
          html,
          isNot(
            contains(
              en ? 'تقرير استهلاك الكيماويات' : 'Chemical consumption report',
            ),
          ),
        );
        expect(html, contains('شركة الاختبار'));
        expect(
          html.indexOf('src="data:image/png;base64,logo"'),
          lessThan(html.indexOf('شركة الاختبار')),
        );
        expect(html, contains('135.5'));
        expect(html, contains('-0.25'));
        expect(html, contains(en ? '>Sulfuric acid<' : '>حمض الكبريتيك<'));
        expect(html, contains('&lt;script&gt;'));
        expect(html, isNot(contains('<script>alert(1)</script>')));
        expect(html, contains('data:font/woff2;base64,'));
        expect(html, isNot(contains('href="fonts/fonts.css"')));
        expect(html, contains('window.print()'));
        final pdf = await service.chemicalConsumptionReport(report());
        expect(pdf.filename, 'Chemical_Consumption_2026-08-01_2026-11-01.pdf');
        expect(
          pdf.title,
          en ? 'Chemical consumption report' : 'تقرير استهلاك الكيماويات',
        );
        expect(exporter.captured, contains('135.5'));
        expect(exporter.captured, contains('-0.25'));
      },
    );
  }

  test(
    'export permission is checked before accessing report settings or rendering',
    () async {
      final guard = _Guard();
      when(() => guard.allows(any())).thenReturn(false);
      final denied = ReportService(
        dbHelper: _Db(),
        settingsRepo: settings,
        inspectionRepo: _Inspection(),
        labRepo: _Lab(),
        secret: _Secret(),
        htmlPdf: exporter,
        guard: guard,
      );
      await expectLater(
        denied.chemicalConsumptionHtml(report()),
        throwsA(isA<AuthorizationError>()),
      );
      await expectLater(
        denied.chemicalConsumptionReport(report()),
        throwsA(isA<AuthorizationError>()),
      );
      verifyNoMoreInteractions(settings);
      expect(exporter.captured, isEmpty);
    },
  );

  test(
    'print PDF rendering supports Arabic, English and multiple pages',
    () async {
      final real = HtmlPdfExporter();
      if (await real.findBrowser() == null) {
        markTestSkipped('Headless Edge/Chrome unavailable');
        return;
      }
      final template = await File(
        'assets/templates/chemical_consumption_report_template.html',
      ).readAsString();
      final qaDirectory = Platform.environment['MATERIALLAB_REPORT_QA'];
      for (final language in ['ar', 'en']) {
        final html = tinyJinjaRender(
          template,
          buildChemicalConsumptionContext(
            report(many: true),
            settings: {
              'report_language': language,
              'organization_name': language == 'ar'
                  ? 'شركة المختبرات للصناعات الغذائية'
                  : 'Material Laboratory Company',
            },
          ),
        );
        final bytes = await real.exportPdf(html);
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        if (qaDirectory != null) {
          final folder = Directory(qaDirectory);
          await folder.create(recursive: true);
          await File(
            '${folder.path}/chemical_consumption_$language.pdf',
          ).writeAsBytes(bytes);
          await File(
            '${folder.path}/chemical_consumption_$language.html',
          ).writeAsString(await real.standaloneHtml(html));
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
