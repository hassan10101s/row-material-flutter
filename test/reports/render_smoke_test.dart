import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/constants/report_form_keys.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/security/qr_builder.dart';
import 'package:material_lab/core/security/qr_payload.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/reports/data/pdf_renderer.dart';
import 'package:material_lab/features/reports/data/qr_render.dart';
import 'package:material_lab/features/reports/data/report_builder.dart';
import 'package:material_lab/features/reports/data/report_service.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';

Map<String, dynamic> _settings() => {
      'department_label': 'Quality Assurance Department',
      'report_logo_data_uri': '',
    };

Map<String, dynamic> _inspection() {
  return {
    'id': 1,
    'entry_code': 'QC-2026-001',
    'material_name': 'Sugar',
    'material_code': 'M-SUGAR-01',
    'inspection_date': '2026-09-19',
    'expiry_date': '2026-12-31',
    'supplier': 'Local Supplier Co.',
    'truck_number': 'TRK-12345',
    'quantity': '500 kg',
    'sample_taken_by': 'Ahmed',
    'specialist_name': 'Mohamed Hassan',
    'created_by_name': 'hassan10101s',
    'updated_at': '2026-09-19 10:30:00',
    'sample_names': ['Sample 1', 'Sample 2'],
    'decision_status': 'APPROVED',
    'decision_reason': '',
    'decision_version': 1,
    'follow_up_note': '',
    'rejected_quantity': '',
    'physical_reference': {'Moisture': '14%'},
    'physical_results': {'Moisture': '13.5'},
    'chemical_reference': {'Ash': '0.5 - 1.0%'},
    'chemical_results': {'Ash': '0.7'},
    'lab_tests': <Map<String, dynamic>>[],
    'status_history': [
      {
        'new_status': 'APPROVED',
        'change_reason': 'Matches specification',
        'version': 1,
        'changed_at': '2026-09-19 10:30:00',
      },
    ],
  };
}

Map<String, dynamic> _monthlyCtx() {
  final inspections = <Map<String, dynamic>>[_inspection()];
  return buildMonthlyContext(
    inspections,
    settings: _settings(),
    month: 9,
    year: 2026,
  );
}

Map<String, dynamic> _labCtx() {
  return buildLabReportContext(
    [
      {
        'tested_at': '2026-09-19 10:00:00',
        'sample_name': 'Sample 1',
        'entry_code': 'QC-2026-001',
        'analysis_name': 'Ash',
        'result_text': '6.2',
        'range_min': 0.5,
        'range_max': 1.0,
        'tested_by_name': 'Ahmed',
        'source': 'Lab',
      },
    ],
    settings: _settings(),
    title: 'Lab Report',
    periodLabel: 'September 2026',
  );
}

Map<String, dynamic> _equipment() {
  return {
    'id': 7,
    'name': 'Drying oven',
    'code': 'EQ-0007',
    'manufacturer': 'Binder',
    'serial_number': 'SN-2024-001',
    'description': '',
    'last_calibration_date': '2026-01-15',
    'next_calibration_date': '2027-01-15',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('qrPngBytes generates a decodable PNG for Arabic payload', () {
    final bytes = qrPngBytes('Quality Lab QC-2026-001', scale: 4);
    expect(bytes, isNotEmpty);
    final decoded = img.decodePng(bytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, greaterThan(0));
  });

  test('inspection PDF renders from the builder context', () async {
    final ctx = buildInspectionContext(
      _inspection(),
      settings: _settings(),
    );
    final bytes = await PdfRenderer.renderInspection(ctx);
    expect(_isPdf(bytes), isTrue);
  });

  test('label and batch labels PDF render', () async {
    final labelCtx =
        buildLabelContext(_inspection(), settings: _settings());
    final bytes = await PdfRenderer.renderLabel(labelCtx);
    expect(_isPdf(bytes), isTrue);

    final batchCtx = buildBatchLabelsContext(
      [_inspection(), _inspection(), _inspection()],
      settings: _settings(),
    );
    final batchBytes = await PdfRenderer.renderBatchLabels(batchCtx);
    expect(_isPdf(batchBytes), isTrue);
  });

  test('daily, monthly, yearly and follow-up PDFs render', () async {
    final inspections = <Map<String, dynamic>>[_inspection()];

    final daily = await PdfRenderer.renderDaily(buildDailyContext(
      inspections,
      settings: _settings(),
      dateStr: '2026-09-19',
    ));
    expect(_isPdf(daily), isTrue);

    final monthly = await PdfRenderer.renderMonthly(_monthlyCtx());
    expect(_isPdf(monthly), isTrue);

    final yearly = await PdfRenderer.renderYearly(buildYearlyContext(
      inspections,
      settings: _settings(),
      year: 2026,
    ));
    expect(_isPdf(yearly), isTrue);

    final followUp = await PdfRenderer.renderFollowUp(buildFollowUpContext(
      inspections,
      settings: _settings(),
      dateStr: '2026-09-19',
    ));
    expect(_isPdf(followUp), isTrue);
  });

  test('lab report PDF renders', () async {
    final bytes = await PdfRenderer.renderLab(_labCtx());
    expect(_isPdf(bytes), isTrue);
  });

  group('qa form number', () {
    test('qaFormNo prefers the global key, falls back to the legacy one', () {
      expect(qaFormNo({'qa_form_no': 'QA-F-07'}), 'QA-F-07');
      expect(
        qaFormNo({'qa_form_no': '', 'equipment_label_form_no': 'QA-F-01'}),
        'QA-F-01',
      );
      expect(qaFormNo({}), '');
    });

    test('each report type reads its own form number key', () {
      // The type key wins over the legacy global value.
      expect(
        qaFormNo({
          ReportFormKeys.global: 'GLOBAL',
          ReportFormKeys.dailyReport: 'QA-D-01',
        }, ReportFormKeys.dailyReport),
        'QA-D-01',
      );
      // An empty type key falls back to the global value.
      expect(
        qaFormNo({ReportFormKeys.global: 'GLOBAL'}, ReportFormKeys.dailyReport),
        'GLOBAL',
      );
    });

    test('plusOneYearIso shifts a year, clamps Feb 29, rejects garbage', () {
      expect(plusOneYearIso('2026-03-15'), '2027-03-15');
      expect(plusOneYearIso('2024-02-29'), '2025-02-28');
      // Impossible input normalizes through DateTime before shifting.
      expect(plusOneYearIso('2023-02-29'), '2024-03-01');
      expect(plusOneYearIso(''), '');
      expect(plusOneYearIso('not-a-date'), '');
    });

    test('equipment QR round-trips with the equipment kind', () {
      final text = buildEquipmentQrPayloadText(
        equipment: {'code': 'EQ-0007'},
      );
      final parsed = tryParseAppQr(text)!;
      expect(parsed.kind, appQrKindEquipment);
      expect(parsed.entryCode, 'EQ-0007');
    });

    test('equipment label context carries the form number', () {
      final ctx = buildEquipmentLabelContext(
        _equipment(),
        settings: {'qa_form_no': 'QA-F-07'},
      );
      expect(ctx['form_no'], 'QA-F-07');
      final parsed = tryParseAppQr('${ctx['qr_payload_text']}')!;
      expect(parsed.kind, appQrKindEquipment);
    });

    test('equipment label PDF renders with and without a form number',
        () async {
      final withForm = await PdfRenderer.renderEquipmentLabel(
        buildEquipmentLabelContext(
          _equipment(),
          settings: {'qa_form_no': 'QA-F-07'},
        ),
      );
      expect(_isPdf(withForm), isTrue);
      final withoutForm = await PdfRenderer.renderEquipmentLabel(
        buildEquipmentLabelContext(_equipment(), settings: _settings()),
      );
      expect(_isPdf(withoutForm), isTrue);
    });
  });

  serviceGroup();
}

/// AppPaths override that avoids path_provider (tests run headless).
class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

late final DatabaseHelper _dbHelper;
late final ReportService _service;

Future<void> zoneSeedDatabase() async {
  final db = await _dbHelper.database;
  await db.insert('settings', {
    'key': 'department_label',
    'value': 'Quality Assurance Department',
  });
  await db.insert('settings', {
    'key': 'report_logo_data_uri',
    'value': '',
  });
  await db.insert('reference_materials', {
    'material_name': 'Sugar',
    'material_code': 'M-SUGAR-01',
    'physical_reference_json': '{"Granulation": "fine"}',
    'chemical_reference_json': '{"Purity": {"min": "99", "max": "100"}}',
    'imported_at': nowIso(),
  });
  await db.insert('users', {
    'id': 1,
    'email': 'inspector@lab.test',
    'full_name': 'Ahmed Ali',
    'role': 'admin',
    'status': 'active',
    'created_at': nowIso(),
  });
  await db.insert('inspections', {
    'entry_code': 'QC-2026-001',
    'material_id': 1,
    'material_name': 'Sugar',
    'material_code': 'M-SUGAR-01',
    'inspection_date': '2026-09-01',
    'expiry_date': '2026-12-31',
    'supplier': 'Local Supplier Co.',
    'truck_number': 'TRK-12345',
    'quantity': '500',
    'sample_taken_by': 'Karim',
    'specialist_name': 'Ahmed Ali',
    'physical_results_json': '{"Granulation": ["fine", "fine"]}',
    'chemical_results_json': '{"Purity": ["99.5", "99.6"]}',
    'physical_reference_json': '{"Granulation": "fine"}',
    'chemical_reference_json': '{"Purity": {"min": "99", "max": "100"}}',
    'decision_status': 'APPROVED',
    'decision_reason': '',
    'follow_up_note': '',
    'rejected_quantity': '0',
    'snapshot_json': '{}',
    'sample_names_json': '["النتيجة / Result", "Sample 2"]',
    'decision_version': 1,
    'created_by': 1,
    'created_by_name': 'Ahmed Ali',
    'created_at': nowIso(),
    'updated_at': nowIso(),
  });
  await db.insert('lab_analyses', {
    'name': 'Moisture',
    'unit': '%',
    'description': 'Moisture content',
    'created_at': nowIso(),
  });
  await db.insert('lab_equipment', {
    'name': 'Drying oven',
    'code': 'EQ-0007',
    'manufacturer': 'Binder',
    'serial_number': 'SN-2024-001',
    'description': '',
    'last_calibration_date': '2026-01-15',
    'next_calibration_date': '2027-01-15',
    'created_at': nowIso(),
    'updated_at': nowIso(),
  });
  // Second device (calibration overdue on purpose) so the batch-label
  // sheet and the OVERDUE branch get real rows to render.
  await db.insert('lab_equipment', {
    'name': 'Precision balance',
    'code': 'EQ-0008',
    'manufacturer': 'Sartorius',
    'serial_number': 'SN-2024-002',
    'description': '',
    'last_calibration_date': '2024-01-10',
    'next_calibration_date': '2025-01-10',
    'created_at': nowIso(),
    'updated_at': nowIso(),
  });
  await db.insert('lab_sample_tests', {
    'analysis_id': 1,
    'source_type': 'raw_material',
    'source_ref_id': 1,
    'source_name': 'Sugar',
    'sample_name': 'النتيجة / Result',
    'result_text': '0.5',
    'entry_code': 'QC-2026-001',
    'tested_at': '2026-09-05 10:00:00',
  });
}

void serviceGroup() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    DatabaseHelper.ensureDesktopFactory();
    final tmp = await Directory.systemTemp.createTemp('matlab_report_svc');
    _dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
    await _dbHelper.database;
    await zoneSeedDatabase();
    final secret = LocalSecret(tmp.path);
    final referenceRepo = ReferenceRepo(dbHelper: _dbHelper);
    _service = ReportService(
      dbHelper: _dbHelper,
      settingsRepo: SettingsRepo(
          dbHelper: _dbHelper, secret: secret, paths: _FakeAppPaths(tmp.path)),
      inspectionRepo: InspectionRepo(dbHelper: _dbHelper, referenceRepo: referenceRepo),
      labRepo: LabRepo(dbHelper: _dbHelper),
      secret: secret,
    );
  });

  group('report_service against seeded DB', () {
    // Real HTML→PDF via headless Edge can be slow when the full suite runs in
    // parallel, so give these service tests room instead of the 30s default.
    test('inspection report', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.inspectionReport(1);
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, 'Sugar_QC-2026-001.pdf');
    });

    test('sample label', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.sampleLabelPdf(1);
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, startsWith('Label_QC-2026-001_'));
      expect(doc.title, 'Label_QC-2026-001');
    });

    test('equipment label', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.equipmentLabelPdf(1);
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, startsWith('EquipmentLabel_EQ-0007_'));
      expect(doc.title, 'EquipmentLabel_EQ-0007');
    });

    test('equipment batch labels', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.equipmentLabelsPdf([1, 2]);
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, startsWith('EquipmentLabels_2_'));
    });

    test('batch labels', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.batchLabelsPdf([1]);
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, startsWith('BatchLabels_1_'));
    });

    test('daily report', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.dailyReport('2026-09-01');
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, 'تقرير_اليومي_2026-09-01.pdf');
      final day = await _service.dailyReport('2026-09-02');
      expect(_isPdf(day.bytes), isTrue);
    });

    test('monthly report with trend', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.monthlyReport(month: 9, year: 2026);
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, 'تقرير_الشهري_202609.pdf');
    });

    test('yearly report', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.yearlyReport(year: 2026);
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, 'تقرير_السنوي_2026.pdf');
    });

    test('follow-up report', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.followUpReport([1], dateStr: '2026-09-20');
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, startsWith('تقرير_المتابعة_2026-09-20_'));
    });

    test('lab report (daily)', timeout: Timeout(const Duration(minutes: 3)), () async {
      final doc = await _service.labReport(type: 'daily', dateStr: '2026-09-05');
      expect(_isPdf(doc.bytes), isTrue);
      expect(doc.filename, startsWith('تقرير_المعمل_daily_'));
      expect(doc.title, 'التقرير اليومي - 2026-09-05');
    });

    test('save report to export dir tree', timeout: Timeout(const Duration(minutes: 3)), () async {
      final db = await _dbHelper.database;
      await db.insert('settings', {
        'key': 'export_root_path',
        'value': (await Directory.systemTemp.createTemp('matlab_exports')).path,
      });
      final doc = await _service.dailyReport('2026-09-02');
      final file = await _service.saveReport(doc, date: DateTime(2026, 9, 2));
      expect(await file.exists(), isTrue);
      expect(file.path, contains(RegExp(r'\\2026\\09\\02\\تقرير_اليومي_2026-09-02\.pdf$')));
      expect(await file.length(), greaterThan(4));
    });
  });
}

bool _isPdf(Uint8List bytes) =>
    bytes.length > 4 && String.fromCharCodes(bytes.sublist(0, 4)) == '%PDF';