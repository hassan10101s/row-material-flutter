import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/router/app_router.dart';

/// Plan §14-P8.3: a read-only device is a read-only dashboard. The proof is
/// twofold - the route guard sends it back to the dashboard, and the view-model
/// it is built from offers no write affordance at all.
///
/// The Rules (server) and the write guards (repository) are the independent
/// layers behind this one; see `atomicity_test.dart` for those.
void main() {
  AppSession session({
    String role = AppRoles.viewer,
    String status = 'active',
    bool readOnlyDevice = false,
  }) => AppSession(
    uid: 'u1',
    email: 'user@material-lab.test',
    organizationId: 'org_1',
    memberId: 'member_1',
    role: role,
    status: status,
    readOnlyDevice: readOnlyDevice,
  );

  group('route guard', () {
    test('a viewer is sent away from the member management screen', () {
      final s = session();
      expect(
        AppRouter.guardRoute(AppRoutes.members, s),
        AppRoutes.dashboard,
        reason: '`users.read` is not in the viewer matrix',
      );
    });

    test('a viewer keeps org.read screens, read-only', () {
      final s = session();
      expect(s.permissions.contains(Permission.orgRead), isTrue);
      expect(AppRouter.guardRoute(AppRoutes.settings, s), isNull);
      expect(
        AppRouter.guardRoute(AppRoutes.reference, s),
        isNull,
        reason:
            'the screen itself hides its write buttons (canWrite → org.update)',
      );
    });

    test('the audit trail is guarded by audit.read, not by the role', () {
      expect(
        session().permissions.contains(Permission.auditRead),
        isFalse,
        reason: 'a viewer is not in the audit.read matrix',
      );
      expect(
        AppRouter.guardRoute(AppRoutes.audit, session()),
        AppRoutes.dashboard,
      );

      final admin = session(role: AppRoles.admin);
      expect(admin.permissions.contains(Permission.auditRead), isTrue);
      expect(AppRouter.guardRoute(AppRoutes.audit, admin), isNull);

      final qualityManager = session(role: AppRoles.qualityManager);
      expect(
        qualityManager.permissions.contains(Permission.auditRead),
        isTrue,
        reason: 'the quality manager reviews the trail',
      );
      expect(AppRouter.guardRoute(AppRoutes.audit, qualityManager), isNull);

      final lab = session(role: AppRoles.lab);
      expect(lab.permissions.contains(Permission.auditRead), isFalse);
      expect(AppRouter.guardRoute(AppRoutes.audit, lab), AppRoutes.dashboard);
    });

    test('a viewer keeps the read-only screens', () {
      final s = session();
      for (final path in [
        AppRoutes.dashboard,
        AppRoutes.inspections,
        AppRoutes.reports,
        AppRoutes.lab,
        AppRoutes.sync,
      ]) {
        expect(
          AppRouter.guardRoute(path, s),
          isNull,
          reason: '$path must stay readable',
        );
      }
    });

    test('a read-only device never opens the inspection form', () {
      expect(
        AppRouter.guardRoute(
          AppRoutes.inspectionNew,
          session(readOnlyDevice: true),
        ),
        AppRoutes.dashboard,
      );
      // …while the list it would have written into stays open.
      expect(
        AppRouter.guardRoute(
          AppRoutes.inspections,
          session(readOnlyDevice: true),
        ),
        isNull,
      );
    });

    test('every QC destination is gated on `qc.read`, not on write access', () {
      const qcRoutes = [
        AppRoutes.qcManagement,
        AppRoutes.qcNcr,
        AppRoutes.qcNcrList,
        AppRoutes.qcNcrDetail,
        AppRoutes.qcInspections,
        AppRoutes.qcInspectionDetail,
        AppRoutes.qcGoals,
        AppRoutes.qcGoalDetail,
        AppRoutes.qcSops,
        AppRoutes.qcTemplates,
      ];

      // `qc.read` is not granted to every built-in role: a lab user is outside the
      // matrix. Pin the condition the guard is actually enforcing so the routes close
      // and open with the matrix, not with whatever the shell happens to show.
      for (final role in AppRoles.all) {
        final s = session(role: role);
        final allowed = s.permissions.contains(Permission.qcRead);
        for (final path in qcRoutes) {
          expect(
            AppRouter.guardRoute(path, s),
            allowed ? isNull : AppRoutes.dashboard,
            reason:
                '$path follows `qc.read`, which $role '
                '${allowed ? 'has' : 'does not have'}',
          );
        }
      }

      // Reading QC is not a write: a read-only device on a QC role still gets
      // the screens. Refusing there would make the device useless rather than
      // safe, and the repository facade is what actually blocks the writes.
      final readOnly = session(
        role: AppRoles.qualityManager,
        readOnlyDevice: true,
      );
      expect(readOnly.canWrite, isFalse);
      for (final path in qcRoutes) {
        expect(
          AppRouter.guardRoute(path, readOnly),
          isNull,
          reason: '$path stays readable on a read-only device',
        );
      }
    });

    test('a writable admin reaches everything', () {
      final s = session(role: AppRoles.admin);
      for (final path in [
        AppRoutes.dashboard,
        AppRoutes.inspections,
        AppRoutes.reports,
        AppRoutes.inspectionNew,
        AppRoutes.members,
        AppRoutes.settings,
        AppRoutes.reference,
        AppRoutes.lab,
        AppRoutes.sync,
      ]) {
        expect(
          AppRouter.guardRoute(path, s),
          isNull,
          reason: '$path must be reachable',
        );
      }
    });

    test(
      'a disabled member loses the write permissions at the session too',
      () {
        final s = session(role: AppRoles.admin, status: 'disabled');
        expect(s.isActiveMember, isFalse);
        expect(s.canDo(Permission.samplesCreate), isFalse);
      },
    );
  });

  group('view-model affordances', () {
    User user({String role = AppRoles.viewer, bool readOnlyDevice = false}) =>
        User(
          email: 'user@material-lab.test',
          fullName: 'Ahmed Ali',
          role: role,
          status: 'active',
          readOnlyDevice: readOnlyDevice,
        );

    test('a viewer offers no write action', () {
      final u = user();
      expect(u.isReadOnly, isTrue);
      expect(u.canCreateInspection, isFalse);
      expect(u.canEditInspections, isFalse);
      expect(u.canApproveQuality, isFalse);
      expect(u.canEditUsers, isFalse);
      expect(u.canManageSettings, isFalse);
    });

    test('an admin on a read-only device offers no write action either', () {
      final u = user(role: AppRoles.admin, readOnlyDevice: true);
      expect(
        u.permissions.contains(Permission.samplesCreate),
        isTrue,
        reason: 'the role still has the permission…',
      );
      expect(
        u.canCreateInspection,
        isFalse,
        reason: '…but the device is read-only',
      );
      expect(u.canApproveQuality, isFalse);
      expect(u.isReadOnly, isTrue);
    });

    test('a writable admin keeps them', () {
      final u = user(role: AppRoles.admin);
      expect(u.isReadOnly, isFalse);
      expect(u.canCreateInspection, isTrue);
      expect(u.canApproveQuality, isTrue);
    });

    test('reading is never taken away', () {
      final u = user(role: AppRoles.admin, readOnlyDevice: true);
      expect(u.canSeeSettings, isTrue);
      expect(u.canReadAudit, isTrue);
    });
  });
}
