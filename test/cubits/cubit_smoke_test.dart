import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/features/auth/presentation/cubit/login_cubit.dart';
import 'package:material_lab/features/auth/presentation/cubit/create_organization_cubit.dart';
import 'package:material_lab/features/auth/presentation/cubit/login_state.dart';
import 'package:material_lab/features/backup/data/backup_manager.dart';
import 'package:material_lab/features/dashboard/domain/dashboard_repository.dart';
import 'package:material_lab/features/dashboard/presentation/cubit/dashboard_cubit.dart';
import 'package:material_lab/features/dashboard/presentation/cubit/dashboard_kpis_cubit.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_detail_cubit.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_form_cubit.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspections_cubit.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/activity_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/analyses_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/inventory_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/lab_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/lab_reports_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/run_test_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/test_history_cubit.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/reference/presentation/cubit/reference_cubit.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';
import 'package:material_lab/features/reports/presentation/cubit/reports_cubit.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';
import 'package:material_lab/features/settings/domain/export_root_service.dart';
import 'package:material_lab/features/settings/presentation/cubit/database_settings_cubit.dart';
import 'package:material_lab/features/settings/presentation/cubit/general_settings_cubit.dart';
import 'package:material_lab/features/organizations/domain/organization_repository.dart';

class _AuthRepositoryMock extends Mock implements AuthRepository {}
class _OrganizationRepositoryMock extends Mock implements OrganizationRepository {}
class _AuthGateMock extends Mock implements AuthGate {}
class _DashboardRepoMock extends Mock implements DashboardRepository {}
class _InspectionRepoMock extends Mock implements InspectionRepository {}
class _ReferenceRepoMock extends Mock implements ReferenceRepo {}
class _ReportServiceMock extends Mock implements ReportRepository {}
class _SettingsRepoMock extends Mock implements SettingsRepo {}
class _BackupManagerMock extends Mock implements BackupManager {}
// The real `OfflineFirstLabRepository` satisfies all three lab contracts, so the
// single stub does too - that is what lets one `repo` stand in for any of them.
class _LabRepoMock extends Mock
    implements LabLocalRepository, LabConfigurationRepository, LabResultRepository {}


ReportDoc _doc(String name) =>
    ReportDoc(filename: name, bytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46]));

void main() {
  setUpAll(() {
    registerFallbackValue(const UserContext(id: 0, fullName: '', role: ''));
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(ReportDoc(filename: '', bytes: Uint8List.fromList([])));
  });

  group('LoginCubit (Google)', () {
    late _AuthRepositoryMock auth;
    late _AuthGateMock gate;
    late LoginCubit cubit;

    setUp(() {
      auth = _AuthRepositoryMock();
      gate = _AuthGateMock();
      when(() => auth.state).thenReturn(AuthState.ready);
      when(() => auth.missingConfiguration).thenReturn(const []);
      when(() => gate.updated()).thenReturn(null);
      cubit = LoginCubit(auth: auth, gate: gate);
    });

    tearDown(() => cubit.close());

    test('signs in, notifies the gate and succeeds', () async {
      when(auth.signInWithGoogle).thenAnswer((_) async {});

      final ok = await cubit.signIn();

      expect(ok, isTrue);
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.error, isNull);
      verify(auth.signInWithGoogle).called(1);
      verify(() => gate.updated()).called(1);
    });

    test('reports a cancelled sign-in as an error', () async {
      when(auth.signInWithGoogle).thenThrow(const AuthFailure('cancelled', code: 'cancelled'));

      final ok = await cubit.signIn();

      expect(ok, isFalse);
      expect(cubit.state.status, LoginStatus.error);
      expect(cubit.state.error, 'cancelled');
      verifyNever(() => gate.updated());
    });

    test('missing Firebase configuration is shown, not thrown', () async {
      when(() => auth.missingConfiguration).thenReturn(const ['GOOGLE_WEB_CLIENT_ID']);
      when(auth.signInWithGoogle).thenThrow(const AuthFailure('no config', code: 'missing_config'));

      final ok = await cubit.signIn();

      expect(ok, isFalse);
      expect(cubit.state.status, LoginStatus.firebaseUnavailable);
      expect(cubit.state.missingConfiguration, ['GOOGLE_WEB_CLIENT_ID']);
    });

    test('applyBootstrap() switches to the configuration state', () {
      when(() => auth.missingConfiguration).thenReturn(const ['FIREBASE_API_KEY']);

      cubit.applyBootstrap();

      expect(cubit.state.status, LoginStatus.firebaseUnavailable);
      expect(cubit.state.missingConfiguration, ['FIREBASE_API_KEY']);
    });

    test('safeEmit tolerates a closed cubit', () async {
      when(auth.signInWithGoogle).thenAnswer((_) async {});
      await cubit.close();
      final ok = await cubit.signIn();
      expect(ok, isTrue);
    });
  });

  group('CreateOrganizationCubit', () {
    late _AuthRepositoryMock auth;
    late _AuthGateMock gate;
    late _OrganizationRepositoryMock orgs;
    late CreateOrganizationCubit cubit;

    setUp(() {
      auth = _AuthRepositoryMock();
      gate = _AuthGateMock();
      orgs = _OrganizationRepositoryMock();
      when(() => gate.updated()).thenReturn(null);
      when(auth.resolveProfile).thenAnswer((_) async => AuthState.ready);
      cubit = CreateOrganizationCubit(auth: auth, organizations: orgs, gate: gate);
    });

    tearDown(() => cubit.close());

    test('creates the organization and resolves the profile', () async {
      when(() => orgs.createOrganization(name: 'Acme'))
          .thenAnswer((_) async => 'org_ABC');

      cubit.setName('Acme');
      final ok = await cubit.submit();

      expect(ok, isTrue);
      verify(() => orgs.createOrganization(name: 'Acme')).called(1);
      verify(auth.resolveProfile).called(1);
      verify(() => gate.updated()).called(1);
    });

    test('rejects an empty organization name locally', () async {
      final ok = await cubit.submit();
      expect(ok, isFalse);
      expect(cubit.state.error, isNotNull);
      verifyNever(() => orgs.createOrganization(name: any(named: 'name')));
    });

    test('surfaces OrganizationFailure (e.g. invite not found)', () async {
      cubit.useInvite();
      cubit.setInviteCode('org_MISSING');
      when(() => orgs.joinWithInvite(organizationId: 'org_MISSING'))
          .thenThrow(const OrganizationFailure('no invite', code: 'invite_not_found'));

      final ok = await cubit.submit();

      expect(ok, isFalse);
      expect(cubit.state.error, 'no invite');
      expect(cubit.state.busy, isFalse);
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

  group('InspectionsCubit', () {
    test('loads a server-filtered page and pages through it', () async {
      final repo = _InspectionRepoMock();
      final reports = _ReportServiceMock();
      when(() => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
          )).thenAnswer((_) async => [
                {'id': 1, 'decision_status': 'APPROVED'},
                {'id': 2, 'decision_status': 'REJECTED'},
              ]);
      when(() => repo.count(
            query: any(named: 'query'),
            status: any(named: 'status'),
            kind: any(named: 'kind'),
          )).thenAnswer((_) async => 2);
      final cubit = InspectionsCubit(repo: repo, reports: reports);
      await cubit.load();

      expect(cubit.state.visible, hasLength(2));
      expect(cubit.state.total, 2);
      // Server-side filtering: a status change refetches from the DB.
      when(() => repo.list(
            query: any(named: 'query'),
            status: 'APPROVED',
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
          )).thenAnswer((_) async => [
                {'id': 1, 'decision_status': 'APPROVED'},
              ]);
      when(() => repo.count(
            query: any(named: 'query'),
            status: 'APPROVED',
            kind: any(named: 'kind'),
          )).thenAnswer((_) async => 1);
      await cubit.setStatus('APPROVED');
      expect(cubit.state.visible, hasLength(1));
      expect(cubit.state.visible.single['id'], 1);

      when(() => repo.list(
            query: 'zzz',
            status: any(named: 'status'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
          )).thenAnswer((_) async => const []);
      when(() => repo.count(
            query: 'zzz',
            status: any(named: 'status'),
            kind: any(named: 'kind'),
          )).thenAnswer((_) async => 0);
      await cubit.setQuery('zzz');
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

    test('loadForEdit restores material, entry code and decision', () async {
      final repo = _InspectionRepoMock();
      final reference = _ReferenceRepoMock();
      when(() => reference.getMaterial(1, inspectionDate: '2026-09-05'))
          .thenAnswer((_) async => {
                'material_code': 'S-1',
                'next_entry_code': 'QC-9',
                'physical_reference': {'Moisture': '14%'},
                'chemical_reference': <String, dynamic>{},
              });
      final cubit =
          InspectionFormCubit(repo: repo, reference: reference);

      await cubit.loadForEdit({
        'id': 7,
        'material_id': 1,
        'inspection_date': '2026-09-05',
        'entry_code': 'QC-3',
        'decision_status': 'FULL_REJECTION',
      });

      expect(cubit.isEditing, isTrue);
      expect(cubit.state.materialId, 1);
      expect(cubit.state.entryCode, 'QC-3');
      expect(cubit.state.decision, 'FULL_REJECTION');
      await cubit.close();
    });

    test('save updates when editing instead of creating', () async {
      final repo = _InspectionRepoMock();
      final reference = _ReferenceRepoMock();
      when(() => reference.getMaterial(1, inspectionDate: '2026-09-05'))
          .thenAnswer((_) async => {
                'material_code': 'S-1',
                'next_entry_code': 'QC-9',
                'physical_reference': <String, dynamic>{},
                'chemical_reference': <String, dynamic>{},
              });
      when(() => repo.update(any(), any(), any()))
          .thenAnswer((_) async => <String, dynamic>{});
      final cubit =
          InspectionFormCubit(repo: repo, reference: reference);
      await cubit.loadForEdit({
        'id': 7,
        'material_id': 1,
        'inspection_date': '2026-09-05',
        'entry_code': 'QC-3',
      });

      final ok = await cubit.save(
        {'supplier': 'Acme'},
        const UserContext(id: 1, fullName: 'U', role: 'Admin'),
      );

      expect(ok, isTrue);
      verify(() => repo.update(7, any(), any())).called(1);
      verifyNever(() => repo.create(any(), any()));
      await cubit.close();
    });
  });

  group('ReferenceCubit', () {
    test('loads the material catalog', () async {
      final repo = _ReferenceRepoMock();
      when(() => repo.listAllMaterials())
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
      // The cubit persists the generated doc; the recorded export is the
      // saved file's path.
      when(() => repo.saveReport(any()))
          .thenAnswer((_) async => File('d.pdf'));

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
      when(() => repo.saveReport(any()))
          .thenAnswer((_) async => File('d.pdf'));

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

  group('ExportRootService', () {
    test('configuredPath trims and nulls empty values', () async {
      final repo = _SettingsRepoMock();
      final service = ExportRootService(repo: repo, paths: null);

      when(() => repo.getSettingValue('export_root_path'))
          .thenAnswer((_) async => r'C:\exports\ ');
      expect(await service.configuredPath(), r'C:\exports\');
      verify(() => repo.getSettingValue('export_root_path')).called(1);

      when(() => repo.getSettingValue('export_root_path'))
          .thenAnswer((_) async => '  ');
      expect(await service.configuredPath(), isNull);
    });

    test('setPath persists the trimmed value', () async {
      final repo = _SettingsRepoMock();
      final service = ExportRootService(repo: repo, paths: null);
      when(() => repo.updateSettings({'export_root_path': r'D:\reports'}))
          .thenAnswer((_) async {});

      await service.setPath(r'  D:\reports  ');

      verify(() => repo.updateSettings({'export_root_path': r'D:\reports'}))
          .called(1);
    });

    test('effectiveRoot creates and returns the configured folder', () async {
      final root = (await Directory.systemTemp.createTemp('matlab_root')).path;
      final repo = _SettingsRepoMock();
      final service = ExportRootService(repo: repo, paths: null);
      when(() => repo.getSettingValue('export_root_path'))
          .thenAnswer((_) async => '$root\\new\\nested');

      final dir = await service.effectiveRoot();

      expect(dir.path, '$root\\new\\nested');
      expect(await dir.exists(), isTrue);
    });
  });

  group('GeneralSettingsCubit', () {
    test('loads the department label', () async {
      final repo = _SettingsRepoMock();
      when(() => repo.getSettingValue('department_label'))
          .thenAnswer((_) async => 'QA Dept');
      when(() => repo.getSettingValue('export_root_path'))
          .thenAnswer((_) async => '');
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

    test('loads the export root path', () async {
      final repo = _SettingsRepoMock();
      when(() => repo.getSettingValue('department_label'))
          .thenAnswer((_) async => 'QA Dept');
      when(() => repo.getReportLogoPath()).thenAnswer((_) async => '');
      when(() => repo.getReportLogoDataUri()).thenAnswer((_) async => '');
      when(() => repo.getSettingValue('export_root_path'))
          .thenAnswer((_) async => r'C:\exports\pdfs');

      final cubit = GeneralSettingsCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.exportRootPath, r'C:\exports\pdfs');
      await cubit.close();
    });

    test('saves the export root path', () async {
      final repo = _SettingsRepoMock();
      when(() =>
              repo.updateSettings({'export_root_path': r'D:\reports'}))
          .thenAnswer((_) async {});

      final cubit = GeneralSettingsCubit(repo: repo);
      await cubit.saveExportRootPath(r'D:\reports');

      expect(cubit.state.saving, isFalse);
      expect(cubit.state.exportRootPath, r'D:\reports');
      verify(() =>
              repo.updateSettings({'export_root_path': r'D:\reports'}))
          .called(1);
      await cubit.close();
    });

    test('clearing the export root path falls back to the default', () async {
      final repo = _SettingsRepoMock();
      when(() => repo.updateSettings({'export_root_path': ''}))
          .thenAnswer((_) async {});

      final cubit = GeneralSettingsCubit(repo: repo);
      await cubit.saveExportRootPath('');

      expect(cubit.state.exportRootPath, isEmpty);
      verify(() => repo.updateSettings({'export_root_path': ''})).called(1);
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

  group('member permissions (V2 replacement of UsersCubit)', () {
    test('a viewer is read-only and cannot manage members', () {
      const viewer = User(
        email: 'v@lab.test',
        role: 'viewer',
        status: 'active',
      );
      expect(viewer.isReadOnly, isTrue);
      expect(viewer.canEditUsers, isFalse);
      expect(viewer.canSeeSettings, isFalse);
      expect(viewer.permissions, isNotEmpty); // reads only
    });

    test('an admin can manage members and organization settings', () {
      const admin = User(email: 'a@lab.test', role: 'admin', status: 'active');
      expect(admin.isReadOnly, isFalse);
      expect(admin.canEditUsers, isTrue);
      expect(admin.canManageSettings, isTrue);
      expect(admin.canApproveQuality, isTrue);
    });

    test('an invited member keeps zero write permissions locally', () {
      const invited = User(
        email: 'i@lab.test',
        role: 'lab',
        status: 'invited',
      );
      // The permissions matrix still lists `samples.create`, but
      // `AppSession.canDo` refuses it while the status is not active.
      expect(invited.canCreateInspection, isTrue);
      const session = AppSession(
        uid: 'u1',
        email: 'i@lab.test',
        role: 'lab',
        status: 'invited',
      );
      expect(session.isActiveMember, isFalse);
      expect(session.canWrite, isFalse);
      expect(session.canDo(Permission.samplesCreate), isFalse);
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
      when(() => repo.listConsumptionLog()).thenAnswer((_) async => []);
      when(() => repo.listAnalyses()).thenAnswer((_) async => []);

      final cubit = TestHistoryCubit(results: repo, local: repo, config: repo);
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
      when(() => repo.listInspectionMaterials())
          .thenAnswer((_) async => <Map<String, dynamic>>[]);

      final cubit = RunTestCubit(config: repo, results: repo, local: repo);
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
      when(() => repo.listInspectionMaterials())
          .thenAnswer((_) async => <Map<String, dynamic>>[]);
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

      final cubit = RunTestCubit(config: repo, results: repo, local: repo);
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
