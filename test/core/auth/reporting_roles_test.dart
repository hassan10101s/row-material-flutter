import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/router/app_router.dart';

void main() {
  for (final readOnlyDevice in [false, true]) {
    test(
      'viewer exports existing data without business write access (device=$readOnlyDevice)',
      () {
        final session = AppSession(
          uid: 'viewer',
          organizationId: 'org',
          role: AppRoles.viewer,
          status: MemberStatus.active,
          readOnlyDevice: readOnlyDevice,
        );
        final guard = SessionWriteGuard(
          source: SessionSource(() => session),
          isOnline: () => false,
        );
        expect(session.canWrite, isFalse);
        expect(guard.allows('reports.export'), isTrue);
        expect(
          guard.allows('reports.create'),
          isFalse,
          reason: 'Shared form settings remain protected',
        );
        for (final permission in Permission.values.where(
          (p) => p.writes && !p.technical,
        )) {
          expect(session.canDo(permission), isFalse, reason: permission.id);
        }
        for (final path in [
          AppRoutes.inspections,
          AppRoutes.lab,
          AppRoutes.qcManagement,
          AppRoutes.reports,
        ]) {
          expect(AppRouter.guardRoute(path, session), isNull, reason: path);
        }
        expect(
          AppRouter.guardRoute(AppRoutes.inspectionNew, session),
          AppRoutes.dashboard,
        );
      },
    );
  }
  test(
    'quality specialist sees all three workspaces and keeps owner administration separate',
    () {
      const session = AppSession(
        uid: 'specialist',
        organizationId: 'org',
        role: AppRoles.lab,
        status: MemberStatus.active,
      );
      expect(
        session.permissions,
        containsAll([
          Permission.samplesCreate,
          Permission.samplesUpdate,
          Permission.labResultsCreate,
          Permission.labResultsUpdate,
          Permission.qcRead,
          Permission.qcWrite,
          Permission.qcApprove,
          Permission.qcReject,
          Permission.reportsRead,
          Permission.reportsCreate,
          Permission.reportsExport,
        ]),
      );
      expect(session.can(Permission.usersUpdate), isFalse);
      expect(session.can(Permission.orgUpdate), isFalse);
      expect(
        rolePermissions(AppRoles.admin).containsAll(Permission.values),
        isTrue,
      );
    },
  );
}
