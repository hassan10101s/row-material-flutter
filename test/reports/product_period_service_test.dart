import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reports/data/report_service.dart';
import 'package:material_lab/features/reports/data/html_pdf_exporter.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';
import '../sync/sync_test_fixture.dart';

class _Secret extends Mock implements LocalSecret {}

class _Inspections extends Mock implements InspectionRepo {}

class _Lab extends Mock implements LabRepo {}

class _Settings extends Mock implements SettingsRepo {}

class _Guard extends Mock implements WriteGuard {}

class _Exporter extends HtmlPdfExporter {
  String html = '';
  @override
  Future<Uint8List> exportPdf(
    String html, {
    String? baseHref,
    bool noPageOverride = false,
  }) async {
    this.html = html;
    return Uint8List.fromList('%PDF-'.codeUnits);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  late ReportService service;
  late _Exporter exporter;
  late _Guard guard;
  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    exporter = _Exporter();
    guard = _Guard();
    when(() => guard.allows(any())).thenReturn(true);
    final settings = _Settings();
    when(settings.getSettings).thenAnswer(
      (_) async => {
        'report_language': 'en',
        'organization_name': 'QA organization',
      },
    );
    service = ReportService(
      dbHelper: fixture.helper,
      settingsRepo: settings,
      inspectionRepo: _Inspections(),
      labRepo: _Lab(),
      secret: _Secret(),
      htmlPdf: exporter,
      guard: guard,
    );
    for (final record in [
      ('DAY', '2026-11-02', 'product', false),
      ('MONTH', '2026-11-30', 'product', false),
      ('YEAR', '2026-12-31', 'product', false),
      ('NEXT', '2027-01-01', 'product', false),
      ('RAW', '2026-11-02', 'raw', false),
      ('DELETED', '2026-11-02', 'product', true),
    ]) {
      final id = await fixture.db.insert('inspections', {
        ...sampleRow(entryCode: record.$1),
        'inspection_kind': record.$3,
        'inspection_date': record.$2,
        'deleted_at': record.$4 ? '2026-11-03' : null,
        'batch_number': record.$1,
        'quantity': 10,
      });
      await fixture.db.insert('product_batch_samples', {
        'batch_id': id,
        'sample_no': 1,
        'sample_name': 'Sample-${record.$1}',
        'tested_at': record.$2,
        'created_at': record.$2,
        'chemical_results_json':
            '[{"name":"Protein","result":"20","unit":"%"}]',
      });
      if (record.$1 == 'DAY') {
        await fixture.db.insert('product_batch_samples', {
          'batch_id': id,
          'sample_no': 2,
          'sample_name': 'DELETED-SAMPLE',
          'tested_at': record.$2,
          'created_at': record.$2,
          'deleted_at': record.$2,
        });
      }
    }
  });
  tearDown(() => fixture.dispose());
  test(
    'period queries exclude raw, deleted samples/headers and next-period rows',
    () async {
      final daily = await service.productDailyReport('2026-11-02');
      expect(daily.filename, 'Product_daily_2026-11-02.pdf');
      expect(exporter.html, contains('Sample-DAY'));
      for (final excluded in [
        'Sample-MONTH',
        'Sample-YEAR',
        'Sample-NEXT',
        'Sample-RAW',
        'Sample-DELETED',
        'DELETED-SAMPLE',
      ]) {
        expect(exporter.html, isNot(contains(excluded)));
      }
      await service.productMonthlyReport(month: 11, year: 2026);
      expect(exporter.html, contains('MONTH'));
      expect(exporter.html, isNot(contains('YEAR')));
      await service.productYearlyReport(year: 2026);
      expect(exporter.html, contains('YEAR'));
      expect(exporter.html, isNot(contains('NEXT')));
      expect(await fixture.db.query('command_outbox'), isEmpty);
    },
  );
  test(
    'strict period validation and export permission happen before rendering',
    () async {
      await expectLater(
        service.productDailyReport('2026-02-31'),
        throwsA(isA<ValidationError>()),
      );
      await expectLater(
        service.productMonthlyReport(month: 13, year: 2026),
        throwsA(isA<ValidationError>()),
      );
      when(() => guard.allows(any())).thenReturn(false);
      await expectLater(
        service.productDailyReport('2026-11-02'),
        throwsA(isA<AuthorizationError>()),
      );
      await expectLater(
        service.productMonthlyReport(month: 11, year: 2026),
        throwsA(isA<AuthorizationError>()),
      );
      await expectLater(
        service.productYearlyReport(year: 2026),
        throwsA(isA<AuthorizationError>()),
      );
      expect(exporter.html, isEmpty);
    },
  );
}
