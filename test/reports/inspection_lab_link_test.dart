import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/reports/data/html_pdf_exporter.dart';
import 'package:material_lab/features/reports/data/report_html_builder.dart';
import 'package:material_lab/features/reports/data/report_service.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';

import '../sync/sync_test_fixture.dart';

class _Settings extends Mock implements SettingsRepo {}

class _Secret extends Mock implements LocalSecret {}

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
  late SyncFixture fx;
  late LabRepo lab;
  late int analysisId;
  late int currentId;
  late InspectionRepo inspections;

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();
    lab = LabRepo(dbHelper: fx.helper);
    inspections = InspectionRepo(
      dbHelper: fx.helper,
      referenceRepo: ReferenceRepo(dbHelper: fx.helper),
    );
    analysisId = await fx.db.insert('lab_analyses', {
      'name': 'Foreign laboratory analysis',
      'unit': '%',
      'created_at': '2026-09-01',
    });
    await fx.db.insert('inspections', sampleRow(entryCode: 'OLD-RECEIPT'));
    currentId = await fx.db.insert(
      'inspections',
      sampleRow(entryCode: 'CURRENT-RECEIPT'),
    );
  });
  tearDown(() => fx.dispose());

  Future<int> testResult(
    String? code, {
    bool secure = false,
    bool deleted = false,
  }) => fx.db.insert('lab_sample_tests', {
    'analysis_id': analysisId,
    'source_type': 'raw_material',
    'source_ref_id': 1,
    'source_name': 'Cement',
    'sample_name': 'S1',
    'entry_code': code,
    'result_text': '87.654',
    'tested_at': '2026-09-01T10:00:00',
    'created_at': '2026-09-01T10:00:00',
    'secure_result': secure ? 1 : 0,
    if (deleted) 'deleted_at': '2026-09-01T11:00:00',
  });

  test(
    'unlinked current receipt never borrows same-material same-day lab result',
    () async {
      final foreign = await testResult('OLD-RECEIPT');
      final current = await inspections.getById(currentId);
      current['chemical_results'] = {
        'Moisture': [19.25],
      };
      current['lab_tests'] = [
        {'id': foreign},
      ]; // Previously enriched maps must also be cleared.
      await lab.injectLabTests(current);
      expect(current['lab_tests'], isEmpty);
      expect(current['chemical_results'], {
        'Moisture': [19.25],
      });
      expect(await fx.db.query('lab_sample_tests'), hasLength(1));
    },
  );

  for (final code in ['', '   ', null]) {
    test(
      'missing receipt code ($code) cannot infer a link from name or date',
      () async {
        await testResult('OLD-RECEIPT');
        final current = await inspections.getById(currentId);
        current['entry_code'] = code;
        await lab.injectLabTests(current);
        expect(current['lab_tests'], isEmpty);
      },
    );
  }

  for (final code in [
    'current-receipt',
    ' CURRENT-RECEIPT',
    'CURRENT-RECEIPT ',
  ]) {
    test(
      'report and entry lookup keep distinct stored code $code separate',
      () async {
        await testResult('CURRENT-RECEIPT');
        final current = await inspections.getById(currentId);
        current['entry_code'] = code;
        await lab.injectLabTests(current);
        expect(current['lab_tests'], isEmpty);
        expect(await lab.listSampleTestsForEntryCode(code), isEmpty);
        expect(
          await lab.listSampleTestsForEntryCode('CURRENT-RECEIPT'),
          hasLength(1),
        );
      },
    );
  }

  test(
    'only exact active visible links survive, regardless of name or date',
    () async {
      final linked = await testResult('CURRENT-RECEIPT');
      await testResult('OLD-RECEIPT');
      await testResult(null);
      await testResult('CURRENT-RECEIPT', secure: true);
      await testResult('CURRENT-RECEIPT', deleted: true);
      await fx.db.update(
        'lab_sample_tests',
        {'source_name': 'Previous name', 'tested_at': '2025-01-01'},
        where: 'id = ?',
        whereArgs: [linked],
      );
      final current = await inspections.getById(currentId);
      await lab.injectLabTests(current);
      expect((current['lab_tests'] as List).map((row) => row['id']), [linked]);
    },
  );

  test(
    'Secure-only receipt does not fall back to another public receipt',
    () async {
      await testResult('CURRENT-RECEIPT', secure: true);
      await testResult('OLD-RECEIPT');
      final current = await inspections.getById(currentId);
      await lab.injectLabTests(current);
      expect(current['lab_tests'], isEmpty);
    },
  );

  test(
    'product report cannot borrow raw-material results with a matching name',
    () async {
      await testResult('OLD-RECEIPT');
      final current = await inspections.getById(currentId);
      current['inspection_kind'] = 'product';
      await lab.injectLabTests(current);
      expect(current['lab_tests'], isEmpty);
      final linked = await testResult('CURRENT-RECEIPT');
      await fx.db.update(
        'lab_sample_tests',
        {'source_type': 'product'},
        where: 'id = ?',
        whereArgs: [linked],
      );
      await lab.injectLabTests(current);
      expect((current['lab_tests'] as List).map((row) => row['id']), [linked]);
    },
  );

  test(
    'HTML context and detailed PDF do not import another receipt lab analysis',
    () async {
      await testResult('OLD-RECEIPT');
      final settings = _Settings();
      final secret = _Secret();
      when(
        settings.getSettings,
      ).thenAnswer((_) async => {'report_language': 'en'});
      when(
        secret.load,
      ).thenAnswer((_) async => Uint8List(32)..fillRange(0, 32, 7));
      final builder = ReportHtmlBuilder(
        settingsRepo: settings,
        labRepo: lab,
        secret: secret,
      );
      final context = await builder.buildContext(
        await inspections.getById(currentId),
      );
      expect(context['chemical_data'], isEmpty);
      final exporter = _Exporter();
      final service = ReportService(
        dbHelper: fx.helper,
        settingsRepo: settings,
        inspectionRepo: inspections,
        labRepo: lab,
        secret: secret,
        htmlBuilder: builder,
        htmlPdf: exporter,
      );
      await service.inspectionReport(currentId, includeAnalysisDetails: true);
      expect(exporter.html, isNot(contains('Foreign laboratory analysis')));
      expect(exporter.html, isNot(contains('87.654')));
      await service.inspectionReport(
        currentId - 1,
        includeAnalysisDetails: true,
      );
      expect(exporter.html, contains('Foreign laboratory analysis'));
      await service.inspectionReport(currentId, includeAnalysisDetails: true);
      expect(exporter.html, isNot(contains('Foreign laboratory analysis')));
    },
  );
}
