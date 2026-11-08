import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/reports/data/html_pdf_exporter.dart';
import 'package:material_lab/features/reports/data/report_service.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';
import '../sync/sync_test_fixture.dart';

class _Secret extends Mock implements LocalSecret {}

class _Inspections extends Mock implements InspectionRepo {}

class _Lab extends Mock implements LabRepo {}

class _Settings extends Mock implements SettingsRepo {}

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
  late int liveId;
  late int deletedId;
  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    exporter = _Exporter();
    final settings = _Settings();
    when(
      settings.getSettings,
    ).thenAnswer((_) async => {'report_language': 'en'});
    service = ReportService(
      dbHelper: fixture.helper,
      settingsRepo: settings,
      inspectionRepo: _Inspections(),
      labRepo: _Lab(),
      secret: _Secret(),
      htmlPdf: exporter,
    );
    liveId = await fixture.db.insert('inspections', {
      ...sampleRow(entryCode: 'LIVE'),
      'material_name': 'Live material',
      'quantity': '10',
      'inspection_date': '2026-11-02',
    });
  });
  tearDown(() => fixture.dispose());

  test(
    'deleted raw headers never enter daily, monthly, yearly or explicit follow-up reports',
    () async {
      deletedId = await fixture.db.insert('inspections', {
        ...sampleRow(entryCode: 'DELETED'),
        'material_name': 'DELETED-MATERIAL',
        'quantity': '9999',
        'inspection_date': '2026-11-02',
        'deleted_at': '2026-11-03',
      });
      for (final run in [
        () => service.dailyReport('2026-11-02'),
        () => service.monthlyReport(month: 11, year: 2026),
        () => service.yearlyReport(year: 2026),
        () =>
            service.followUpReport([liveId, deletedId], dateStr: '2026-11-02'),
      ]) {
        await run();
        expect(exporter.html, contains('Live material'));
        expect(exporter.html, isNot(contains('DELETED-MATERIAL')));
        expect(exporter.html, isNot(contains('9999')));
      }
    },
  );

  test(
    'a tombstone in an earlier month cannot change the six-month trend',
    () async {
      await service.monthlyReport(month: 11, year: 2026);
      String withoutClock(String html) => html.replaceAll(
        RegExp(r'\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?'),
        '<clock>',
      );
      final baseline = withoutClock(exporter.html);
      await fixture.db.insert('inspections', {
        ...sampleRow(entryCode: 'OLD-DELETED'),
        'quantity': '9999',
        'inspection_date': '2026-10-01',
        'decision_status': 'FULL_REJECTION',
        'deleted_at': '2026-11-03',
      });
      await service.monthlyReport(month: 11, year: 2026);
      expect(withoutClock(exporter.html), baseline);
      expect(await fixture.db.query('command_outbox'), isEmpty);
    },
  );
}
