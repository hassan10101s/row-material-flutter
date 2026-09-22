import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/reports/data/report_html_builder.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;
  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

const UserContext _admin = UserContext(id: 1, fullName: 'Ahmed Ali', role: 'Admin');

late Directory _tmp;
late DatabaseHelper _dbHelper;
late InspectionRepo _repo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    DatabaseHelper.ensureDesktopFactory();
    _tmp = await Directory.systemTemp.createTemp('matlab_html_regen_test');
    _dbHelper = DatabaseHelper(_FakeAppPaths(_tmp.path));
    final secret = LocalSecret(_tmp.path);

    final db = await _dbHelper.database;
    await db.insert('reference_materials', {
      'material_name': 'Sugar',
      'material_code': 'M-SUGAR-01',
      'physical_reference_json': '{"Granulation": "fine"}',
      'chemical_reference_json': '{"Purity": {"min": "99", "max": "100"}}',
      'imported_at': nowIso(),
    });
    await db.insert('users', {
      'username': 'inspector',
      'full_name': 'Ahmed Ali',
      'password_hash': 'x',
      'role': 'Admin',
      'is_active': 1,
      'created_at': nowIso(),
    });

    final settingsRepo = SettingsRepo(
        dbHelper: _dbHelper, secret: secret, paths: _FakeAppPaths(_tmp.path));
    final htmlBuilder = ReportHtmlBuilder(
      settingsRepo: settingsRepo,
      labRepo: LabRepo(dbHelper: _dbHelper),
      secret: secret,
      templateLoader: () async =>
          '<h1>{{ material_name }}</h1>|{{ supplier }}|{{ decision_status }}|{{ updated_at }}',
    );
    _repo = InspectionRepo(
      dbHelper: _dbHelper,
      referenceRepo: ReferenceRepo(dbHelper: _dbHelper),
      htmlBuilder: htmlBuilder,
    );
  });

  Map<String, dynamic> basePayload() => {
        'material_id': 1,
        'inspection_date': '2026-09-22',
        'expiry_date': '2026-12-31',
        'supplier': 'Supplier A',
        'truck_number': 'TRK-1',
        'quantity': '500',
        'sample_taken_by': 'Karim',
        'sample_names': ['S1'],
        'physical_results': {'Granulation': ['fine']},
        'chemical_results': {'Purity': ['99.5']},
        'decision_status': 'APPROVED',
      };

  test('report_html regenerated after create, decision and data edit', () async {
    final created = await _repo.create(basePayload(), _admin);
    final createdId = created['id'] as int;
    final createdHtml = '${created['report_html']}';
    // The renderer replaces the minimal preview immediately after insert.
    expect(createdHtml, contains('<h1>Sugar</h1>'));
    expect(createdHtml, contains('|APPROVED|'));

    // Decision update (APPROVED -> CONDITIONAL_APPROVAL) re-renders.
    final decided = await _repo.updateStatus(createdId, {
      'decision_status': 'CONDITIONAL_APPROVAL',
      'decision_reason': 'Pending lab retest',
      'follow_up_note': 'Recheck Purity in lab',
    }, _admin);
    final decidedHtml = '${decided['report_html']}';
    expect(decidedHtml, contains('|CONDITIONAL_APPROVAL|'));
    expect(decidedHtml, isNot(createdHtml));

    // Data edit (supplier change) re-renders with the new values.
    final edited = await _repo.update(createdId, {
      'supplier': 'Supplier B',
      'physical_results': {'Granulation': ['coarse']},
    }, _admin);
    final editedHtml = '${edited['report_html']}';
    expect(editedHtml, contains('|Supplier B|'));
    expect(editedHtml, isNot(decidedHtml));

    final db = await _dbHelper.database;
    final stored = await db.query('inspections',
        columns: ['report_html'], where: 'id = ?', whereArgs: [createdId]);
    expect('${stored.first['report_html']}', editedHtml);
  });

  test('a fresh create has no other decision history but still regenerates', () async {
    final created = await _repo.create(basePayload()..['supplier'] = 'Supplier C', _admin);
    expect('${created['report_html']}', contains('|Supplier C|'));
    final history = await _repo.getStatusHistory(created['id'] as int);
    expect(history, isEmpty);
  });
}