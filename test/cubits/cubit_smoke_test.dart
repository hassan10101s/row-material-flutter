import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/auth/data/auth_repo.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/features/auth/presentation/cubit/login_cubit.dart';
import 'package:material_lab/features/auth/presentation/cubit/setup_cubit.dart';
import 'package:material_lab/features/backup/data/backup_manager.dart';
import 'package:material_lab/features/dashboard/data/dashboard_repo.dart';
import 'package:material_lab/features/dashboard/presentation/cubit/dashboard_cubit.dart';
import 'package:material_lab/features/dashboard/presentation/cubit/dashboard_kpis_cubit.dart';
import 'package:material_lab/features/history/presentation/cubit/history_cubit.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_detail_cubit.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_form_cubit.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspections_cubit.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/lab/presentation/cubit/activity_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/analyses_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/constants_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/inventory_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/lab_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/lab_reports_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/run_test_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/test_history_cubit.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/reference/presentation/cubit/reference_cubit.dart';
import 'package:material_lab/features/reports/data/report_service.dart';
import 'package:material_lab/features/reports/presentation/cubit/reports_cubit.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';
import 'package:material_lab/features/settings/presentation/cubit/database_settings_cubit.dart';
import 'package:material_lab/features/settings/presentation/cubit/general_settings_cubit.dart';
import 'package:material_lab/features/settings/presentation/cubit/users_cubit.dart';

class _AuthRepoMock extends Mock implements AuthRepo {}
class _AuthGateMock extends Mock implements AuthGate {}
class _DashboardRepoMock extends Mock implements DashboardRepo {}
class _InspectionRepoMock extends Mock implements InspectionRepo {}
class _ReferenceRepoMock extends Mock implements ReferenceRepo {}
class _ReportServiceMock extends Mock implements ReportService {}
class _SettingsRepoMock extends Mock implements SettingsRepo {}
class _BackupManagerMock extends Mock implements BackupManager {}
class _LabRepoMock extends Mock implements LabRepo {}

const _user = User(username: 'u', fullName: 'U', role: 'Admin', createdAt: 'now');

ReportDoc _doc(String name) =>
    ReportDoc(filename: name, bytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46]));

void main() {
  setUpAll(() {
    registerFallbackValue(const UserContext(id: 0, fullName: '', role: ''));
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(ReportDoc(filename: '', bytes: Uint8List.fromList([])));
  });

  group('LoginCubit', () {
    late _AuthRepoMock auth;
    late _AuthGateMock gate;
    late LoginCubit cubit;

    setUp(() {
      auth = _AuthRepoMock();
      gate = _AuthGateMock();
      cubit = LoginCubit(auth: auth, gate: gate);
    });

    tearDown(() => cubit.close());

    test('submits, notifies gate and succeeds', () async {
      when(() => auth.login(username: 'u', password: 'p'))
          .thenAnswer((_) async => _user);
      when(() => gate.updated()).thenReturn(null);

      final ok = await cubit.submit(username: 'u', password: 'p');

      expect(ok, isTrue);
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.error, isNull);
      verify(() => auth.login(username: 'u', password: 'p')).called(1);
      verify(() => gate.updated()).called(1);
    });

    test('surfaces AppError and fails', () async {
      when(() => auth.login(username: 'u', password: 'p'))
          .thenThrow(const AppError('bad login'));
      when(() => gate.updated()).thenReturn(null);

      final ok = await cubit.submit(username: 'u', password: 'p');

      expect(ok, isFalse);
      expect(cubit.state.error, 'bad login');
      verifyNever(() => gate.updated());
    });

    test('safeEmit tolerates a closed cubit', () async {
      when(() => auth.login(username: 'u', password: 'p'))
          .thenAnswer((_) async => _user);
      when(() => gate.updated()).thenReturn(null);
      await cubit.close();
      final ok = await cubit.submit(username: 'u', password: 'p');
      expect(ok, isTrue);
    });
  });

  group('SetupCubit', () {
    test('creates the first admin', () async {
      final auth = _AuthRepoMock();
      final gate = _AuthGateMock();
      when(() => auth.createAdmin(
            username: 'admin',
            fullName: 'Admin',
            password: 'pw',
            role: 'Developer',
            usageExpiryDate: any(named: 'usageExpiryDate'),
          )).thenAnswer((_) async => _user);
      when(() => gate.updated()).thenReturn(null);

      final cubit = SetupCubit(auth: auth, gate: gate);
      final ok = await cubit.createAdmin(
        username: 'admin',
        fullName: 'Admin',
        password: 'pw',
        role: 'Developer',
      );
      expect(ok, isTrue);
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('fail() stores the validation message', () async {
      final cubit =
          SetupCubit(auth: _AuthRepoMock(), gate: _AuthGateMock());
      cubit.fail('Password too short');
      expect(cubit.state.error, 'Password too short');
      await cubit.close();
    });
  });

  group('DashboardCubit', () {
    test('loads summary, KPIs and filter options', () async {
      final repo = _DashboardRepoMock();
      final opts = const DashboardFilterOptions(
          materials: [], suppliers: [], statuses: []);
      when(() => repo.summary(
            period: any(named: 'period'),
            materialId: any(named: 'materialId'),
            supplier: any(named: 'supplier'),
            status: any(named: 'status'),
          )).thenAnswer((_) async => {'total': 5});
      when(() => repo.todayKpis()).thenAnswer((_) async => {'approved': 2});
      when(() => repo.filterOptions()).thenAnswer((_) async => opts);

      final cubit =
          DashboardCubit(repo: repo, kpis: DashboardKpisCubit());
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, isNull);
      expect(cubit.state.summary, {'total': 5});
      expect(cubit.state.filterOptions, opts);
      await cubit.close();
    });

    test('surfaces load failures in state', () async {
      final repo = _DashboardRepoMock();
      when(() => repo.summary(
            period: any(named: 'period'),
            materialId: any(named: 'materialId'),
            supplier: any(named: 'supplier'),
            status: any(named: 'status'),
          )).thenThrow(const AppError('db locked'));
      when(() => repo.todayKpis()).thenAnswer((_) async => {});
      when(() => repo.filterOptions())
          .thenAnswer((_) async => const DashboardFilterOptions(
              materials: [], suppliers: [], statuses: []));

      final cubit =
          DashboardCubit(repo: repo, kpis: DashboardKpisCubit());
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, 'db locked');
      await cubit.close();
    });
  });

  group('HistoryCubit', () {
    test('loads rows and applies the query filter via repo', () async {
      final repo = _InspectionRepoMock();
      when(() => repo.list(query: '')).thenAnswer((_) async => [{'entry_code': 'A'}]);
      final cubit = HistoryCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.rows, hasLength(1));

      when(() => repo.list(query: 'abc')).thenAnswer((_) async => []);
      cubit.setQuery('abc');
      expect(cubit.state.query, 'abc');
      await pumpEventQueue();
      expect(cubit.state.rows, isEmpty);
      verify(() => repo.list(query: 'abc')).called(1);
      await cubit.close();
    });
  });

  group('InspectionsCubit', () {
    test('loads rows and filters by status client-side', () async {
      final repo = _InspectionRepoMock();
      final reports = _ReportServiceMock();
      when(() => repo.list(orderBy: 'inspection_date DESC, id DESC'))
          .thenAnswer((_) async => [
                {'id': 1, 'decision_status': 'APPROVED'},
                {'id': 2, 'decision_status': 'REJECTED'},
              ]);
      final cubit = InspectionsCubit(repo: repo, reports: reports);
      await cubit.load();

      expect(cubit.state.visible, hasLength(2));
      cubit.setStatus('APPROVED');
      expect(cubit.state.visible, hasLength(1));
      expect(cubit.state.visible.single['id'], 1);

      cubit.setQuery('zzz');
      expect(cubit.state.visible, isEmpty);
      await cubit.close();
    });

    test('exportFollowUp returns null when nothing to export', () async {
      final repo = _InspectionRepoMock();
      final reports = _ReportServiceMock();
      final cubit = InspectionsCubit(repo: repo, reports: reports);
      expect(await cubit.exportFollowUp(), isNull);
      verifyNever(() => reports.followUpReport(any()));
      await cubit.close();
    });
  });

  group('InspectionDetailCubit', () {
    test('loads the inspection and its history', () async {
      final repo = _InspectionRepoMock();
      when(() => repo.getById(1)).thenAnswer((_) async => {
            'id': 1,
            'inspection_date': '2026-09-05',
            'status_history': [
              {'new_status': 'APPROVED'},
            ],
          });
      final cubit = InspectionDetailCubit(
        inspectionId: 1,
        repo: repo,
        reports: _ReportServiceMock(),
      );
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.inspection?['id'], 1);
      expect(cubit.state.history, hasLength(1));
      await cubit.close();
    });

    test('exports a PDF report and resets busy', () async {
      final repo = _InspectionRepoMock();
      final reports = _ReportServiceMock();
      when(() => repo.getById(1)).thenAnswer((_) async => {'id': 1});
      when(() => reports.inspectionReport(1)).thenAnswer((_) async => _doc('r.pdf'));
      when(() => reports.saveReport(any(), date: any(named: 'date')))
          .thenAnswer((_) async => File('out/r.pdf'));

      final cubit = InspectionDetailCubit(
        inspectionId: 1,
        repo: repo,
        reports: reports,
      );
      final path = await cubit.exportPdf('report');

      expect(path, 'out/r.pdf');
      expect(cubit.state.busy, '');
      verify(() => reports.inspectionReport(1)).called(1);
      await cubit.close();
    });
  });

  group('InspectionFormCubit', () {
    test('selects a material and bumps the reference revision', () async {
      final repo = _InspectionRepoMock();
      final reference = _ReferenceRepoMock();
      when(() => reference.listMaterials())
          .thenAnswer((_) async => [{'id': 1, 'material_name': 'Sugar'}]);
      when(() => reference.getMaterial(1, inspectionDate: '2026-09-05'))
          .thenAnswer((_) async => {
                'material_code': 'S-1',
                'next_entry_code': 'QC-9',
                'physical_reference': {'Moisture': '14%'},
                'chemical_reference': <String, dynamic>{},
              });

      final cubit =
          InspectionFormCubit(repo: repo, reference: reference);
      await cubit.loadMaterials();
      expect(cubit.state.materials, hasLength(1));

      await cubit.selectMaterial(1, date: '2026-09-05');
      expect(cubit.state.materialId, 1);
      expect(cubit.state.entryCode, 'QC-9');
      expect(cubit.state.physicalReference['Moisture'], '14%');
      expect(cubit.state.refRevision, 1);
      await cubit.close();
    });

    test('saves via repo.create', () async {
      final repo = _InspectionRepoMock();
      final reference = _ReferenceRepoMock();
      when(() => repo.create(any(), any()))
          .thenAnswer((_) async => <String, dynamic>{});
      final cubit =
          InspectionFormCubit(repo: repo, reference: reference);

      final ok = await cubit.save(
        {'supplier': 'x'},
        const UserContext(id: 1, fullName: 'U', role: 'Admin'),
      );

      expect(ok, isTrue);
      expect(cubit.state.saving, isFalse);
      verify(() => repo.create(any(), any())).called(1);
      await cubit.close();
    });
  });

  group('ReferenceCubit', () {
    test('loads the material catalog', () async {
      final repo = _ReferenceRepoMock();
      when(() => repo.listMaterials())
          .thenAnswer((_) async => [{'material_name': 'Sugar'}]);

      final cubit = ReferenceCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.materials, hasLength(1));
      await cubit.close();
    });
  });

  group('ReportsCubit', () {
    test('runs a daily report and records the export', () async {
      final repo = _ReportServiceMock();
      when(() => repo.dailyReport('2026-09-05'))
          .thenAnswer((_) async => _doc('d.pdf'));

      final cubit = ReportsCubit(repo: repo);
      await cubit.runDaily('2026-09-05');

      expect(cubit.state.busy, '');
      expect(cubit.state.lastExport, 'd.pdf');
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('rejects concurrent runs', () async {
      final repo = _ReportServiceMock();
      final completer = Completer<ReportDoc>();
      when(() => repo.dailyReport('2026-09-05'))
          .thenAnswer((_) => completer.future);

      final cubit = ReportsCubit(repo: repo);
      final first = cubit.runDaily('2026-09-05');
      await cubit.runDaily('2026-09-05');
      expect(cubit.state.busy, 'daily');

      completer.complete(_doc('d.pdf'));
      await first;
      expect(cubit.state.busy, '');
      expect(cubit.state.lastExport, 'd.pdf');
      await cubit.close();
    });
  });

  group('GeneralSettingsCubit', () {
    test('loads the department label', () async {
      final repo = _SettingsRepoMock();
      when(() => repo.getSettingValue('department_label'))
          .thenAnswer((_) async => 'QA Dept');
      when(() => repo.getReportLogoPath()).thenAnswer((_) async => '');
      when(() => repo.getReportLogoDataUri()).thenAnswer((_) async => '');

      final cubit = GeneralSettingsCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.departmentLabel, 'QA Dept');
      await cubit.close();
    });

    test('saves the department label', () async {
      final repo = _SettingsRepoMock();
      when(() => repo.updateSettings({'department_label': 'New'}))
          .thenAnswer((_) async {});

      final cubit = GeneralSettingsCubit(repo: repo);
      await cubit.save('New');

      expect(cubit.state.saving, isFalse);
      expect(cubit.state.departmentLabel, 'New');
      verify(() => repo.updateSettings({'department_label': 'New'})).called(1);
      await cubit.close();
    });
  });

  group('DatabaseSettingsCubit', () {
    test('exports a backup and records the path', () async {
      final backup = _BackupManagerMock();
      when(() => backup.exportDatabaseBackup())
          .thenAnswer((_) async => {'path': '/tmp/backup.db'});

      final cubit = DatabaseSettingsCubit(backup: backup);
      await cubit.exportBackup();

      expect(cubit.state.busy, isFalse);
      expect(cubit.state.lastPath, '/tmp/backup.db');
      await cubit.close();
    });

    test('restores a backup', () async {
      final backup = _BackupManagerMock();
      when(() => backup.restoreDatabaseBackup('/tmp/x.db'))
          .thenAnswer((_) async => <String, dynamic>{});

      final cubit = DatabaseSettingsCubit(backup: backup);
      await cubit.restoreBackup('/tmp/x.db');

      expect(cubit.state.busy, isFalse);
      expect(cubit.state.error, isNull);
      verify(() => backup.restoreDatabaseBackup('/tmp/x.db')).called(1);
      await cubit.close();
    });
  });

  group('UsersCubit', () {
    test('loads users', () async {
      final repo = _SettingsRepoMock();
      when(() => repo.listUsers()).thenAnswer((_) async => [_user]);

      final cubit = UsersCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.users, hasLength(1));
      await cubit.close();
    });

    test('creates a user and reloads the list', () async {
      final repo = _SettingsRepoMock();
      when(() => repo.createUser(
            username: any(named: 'username'),
            fullName: any(named: 'fullName'),
            password: any(named: 'password'),
            role: any(named: 'role'),
          )).thenAnswer((_) async => _user);
      when(() => repo.listUsers()).thenAnswer((_) async => [_user]);

      final cubit = UsersCubit(repo: repo);
      final ok = await cubit.createUser(
          username: 'x', fullName: 'X', password: 'pw', role: 'Lab User');

      expect(ok, isTrue);
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.users, hasLength(1));
      await cubit.close();
    });
  });

  group('LabCubit', () {
    test('switches tabs and bumps the history tick', () async {
      final cubit = LabCubit();
      cubit.setTab(3);
      expect(cubit.state.tab, 3);
      cubit.setTab(3);
      expect(cubit.state.tab, 3);
      cubit.notifyTestRun();
      expect(cubit.state.historyTick, 1);
      await cubit.close();
    });
  });

  group('InventoryCubit', () {
    test('loads the inventory list', () async {
      final repo = _LabRepoMock();
      when(() => repo.listInventory())
          .thenAnswer((_) async => [
                {'id': 1, 'name': 'Acid', 'current_qty': 5.0},
              ]);

      final cubit = InventoryCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, isNull);
      expect(cubit.state.rows, hasLength(1));
      await cubit.close();
    });
  });

  group('AnalysesCubit', () {
    test('loads analyses and deletes one', () async {
      final repo = _LabRepoMock();
      when(() => repo.listAnalyses())
          .thenAnswer((_) async => [
                {'id': 1, 'name': 'Moisture'},
              ]);
      when(() => repo.deleteAnalysis(1))
          .thenAnswer((_) async => {'archived': true});

      final cubit = AnalysesCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.rows, hasLength(1));
      await cubit.delete(1);
      verify(() => repo.deleteAnalysis(1)).called(1);
      await cubit.close();
    });
  });

  group('ConstantsCubit', () {
    test('loads constants and deletes one', () async {
      final repo = _LabRepoMock();
      when(() => repo.listGlobalConstants())
          .thenAnswer((_) async => [
                {'id': 1, 'name': 'Pi'},
              ]);
      when(() => repo.deleteGlobalConstant(1))
          .thenAnswer((_) async => {'deleted': true});

      final cubit = ConstantsCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.rows, hasLength(1));
      await cubit.delete(1);
      verify(() => repo.deleteGlobalConstant(1)).called(1);
      await cubit.close();
    });
  });

  group('ActivityCubit', () {
    test('loads the activity log', () async {
      final repo = _LabRepoMock();
      when(() => repo.activityLog(limit: 300))
          .thenAnswer((_) async => [
                {'type': 'adjust'},
              ]);

      final cubit = ActivityCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.rows, hasLength(1));
      verify(() => repo.activityLog(limit: 300)).called(1);
      await cubit.close();
    });
  });

  group('TestHistoryCubit', () {
    test('loads the sample-test history', () async {
      final repo = _LabRepoMock();
      when(() => repo.listSampleTests())
          .thenAnswer((_) async => [
                {'id': 1, 'analysis_name': 'pH'},
              ]);

      final cubit = TestHistoryCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.rows, hasLength(1));
      await cubit.close();
    });
  });

  group('RunTestCubit', () {
    test('loads analyses/products and default-selects the first analysis', () async {
      final repo = _LabRepoMock();
      when(() => repo.listAnalyses()).thenAnswer((_) async => [
            {'id': 7, 'name': 'Moisture', 'unit': '%', 'dynamic_fields': ['Sample Name']},
          ]);
      when(() => repo.listProducts()).thenAnswer((_) async => [
            {'id': 3, 'name': 'Gel'},
          ]);

      final cubit = RunTestCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.analyses, hasLength(1));
      expect(cubit.state.products, hasLength(1));
      expect(cubit.state.analysisId, 7);
      await cubit.close();
    });

    test('applies selection, looks up a code and runs a sample test', () async {
      final repo = _LabRepoMock();
      when(() => repo.listAnalyses()).thenAnswer((_) async => [
            {'id': 1, 'name': 'pH', 'unit': 'pH', 'dynamic_fields': ['Sample Name']},
          ]);
      when(() => repo.listProducts()).thenAnswer((_) async => []);
      when(() => repo.resolveInspection('QC-9'))
          .thenAnswer((_) async => {'material_id': 4, 'material_name': 'Sugar'});
      when(() => repo.runSampleTest(
            analysisId: any(named: 'analysisId'),
            sourceType: any(named: 'sourceType'),
            sourceRefId: any(named: 'sourceRefId'),
            sourceName: any(named: 'sourceName'),
            sampleName: any(named: 'sampleName'),
            resultText: any(named: 'resultText'),
            dynamicValues: any(named: 'dynamicValues'),
            user: any(named: 'user'),
            entryCode: any(named: 'entryCode'),
          )).thenAnswer((_) async => {
            'test': {'id': 1, 'result_text': '7.0'},
            'analysis_unit': 'pH',
            'consumption': <dynamic>[],
            'low_stock': <dynamic>[],
          });

      final cubit = RunTestCubit(repo: repo);
      await cubit.load();
      cubit.setSourceType('raw_material');
      expect(await cubit.lookupEntry('QC-9'), isTrue);
      expect(cubit.state.sourceName, 'Sugar');

      final result = await cubit.run(
        sampleName: 'S1',
        resultText: '',
        dynamicValues: <String, dynamic>{},
        entryCode: 'QC-9',
        user: const {'id': 1, 'username': 'u', 'full_name': 'U'},
      );

      expect(cubit.state.running, isFalse);
      expect(result['test'], isNotNull);
      verify(() => repo.runSampleTest(
            analysisId: 1,
            sourceType: 'raw_material',
            sourceRefId: any(named: 'sourceRefId'),
            sourceName: 'Sugar',
            sampleName: 'S1',
            resultText: '',
            dynamicValues: any(named: 'dynamicValues'),
            user: any(named: 'user'),
            entryCode: 'QC-9',
          )).called(1);
      await cubit.close();
    });
  });

  group('LabReportsCubit', () {
    test('runs a daily lab report and records the export', () async {
      final reports = _ReportServiceMock();
      when(() => reports.labReport(type: 'daily', dateStr: '2026-09-05'))
          .thenAnswer((_) async => _doc('lab_daily.pdf'));
      when(() => reports.saveReport(any()))
          .thenAnswer((_) async => File('out/lab_daily.pdf'));

      final cubit = LabReportsCubit(reports: reports);
      await cubit.runDaily('2026-09-05');

      expect(cubit.state.busy, '');
      expect(cubit.state.lastExport, 'out/lab_daily.pdf');
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('rejects concurrent runs', () async {
      final reports = _ReportServiceMock();
      final completer = Completer<ReportDoc>();
      when(() => reports.labReport(type: 'daily', dateStr: '2026-09-05'))
          .thenAnswer((_) => completer.future);

      final cubit = LabReportsCubit(reports: reports);
      final first = cubit.runDaily('2026-09-05');
      await cubit.runDaily('2026-09-05');
      expect(cubit.state.busy, 'daily');

      completer.complete(_doc('lab_daily.pdf'));
      await first;
      expect(cubit.state.busy, '');
      await cubit.close();
    });
  });
}