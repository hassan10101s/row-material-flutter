import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';

/// The organization manager (`admin`) may run a privileged operation with no
/// connectivity and no fresh token.
///
/// It is the account of last resort: it is the only role that can rename the
/// organization, invite members and sign off on a QC decision, so requiring the
/// network for exactly that role made it unusable in the situation it exists
/// for. The exemption is scoped to the online requirement and to `admin`.
void main() {
  group('the organization manager is exempt from the online requirement', () {
    test('every privileged permission is allowed offline', () {
      final offline = AppSession(
        uid: 'uid_1',
        organizationId: 'org_1',
        role: AppRoles.admin,
        status: MemberStatus.active,
        // No token and no expiry at all: the fresh-session half of the
        // requirement is gone too, not just connectivity.
      );
      expect(offline.isTokenFresh, isFalse, reason: 'precondition');

      for (final permission in privilegedPermissions) {
        expect(
          offline.canDo(permission, online: false),
          isTrue,
          reason: '${permission.id} must not need the network for admin',
        );
      }
    });

    test('the exemption covers every permission, not a subset', () {
      // Held as a single-element set on purpose: a second role added to it later
      // would silently inherit the ability to decide a QC sheet with no
      // network, which is not something a list edit should be able to do.
      expect(freshSessionExemptRoles, {AppRoles.admin});
    });

    test('a non-admin role still needs connectivity for the same permission', () {
      // `quality_manager` holds the identical `qc.*` set, so it is the control:
      // without it, the test above would also pass if the requirement had simply
      // been deleted.
      for (final role in [
        AppRoles.qualityManager,
        AppRoles.lab,
        AppRoles.viewer,
      ]) {
        final session = AppSession(
          uid: 'uid_1',
          organizationId: 'org_1',
          role: role,
          status: MemberStatus.active,
        );
        for (final permission in privilegedPermissions) {
          if (!roleHas(role, permission)) continue;
          expect(
            session.canDo(permission, online: false),
            isFalse,
            reason: '${permission.id} still needs the network for $role',
          );
        }
      }
    });

    test('an expired token still refuses a non-admin offline operation', () {
      final stale = AppSession(
        uid: 'uid_1',
        organizationId: 'org_1',
        role: AppRoles.qualityManager,
        status: MemberStatus.active,
        idTokenExpiresAt: DateTime(2020),
      );
      expect(stale.canDo(Permission.qcApprove, online: true), isFalse);
    });

    test('the exemption does not touch the other two gates', () {
      AppSession admin({
        bool readOnly = false,
        String status = MemberStatus.active,
      }) => AppSession(
        uid: 'uid_1',
        organizationId: 'org_1',
        role: AppRoles.admin,
        status: status,
        readOnlyDevice: readOnly,
      );

      expect(
        admin(readOnly: true).canDo(Permission.qcApprove, online: false),
        isFalse,
        reason: 'a read-only device writes nothing, whatever the role',
      );
      expect(
        admin(
          status: MemberStatus.disabled,
        ).canDo(Permission.qcApprove, online: false),
        isFalse,
        reason: 'a disabled member writes nothing, whatever the role',
      );
      expect(
        admin(
          status: MemberStatus.invited,
        ).canDo(Permission.qcApprove, online: false),
        isFalse,
        reason: 'an invited member has not activated yet',
      );
    });

    test('an unknown role gains nothing from the exemption', () {
      final corrupt = AppSession(
        uid: 'uid_1',
        organizationId: 'org_1',
        role: 'superuser',
        status: MemberStatus.active,
      );
      expect(corrupt.permissions, isEmpty);
      for (final permission in Permission.values) {
        expect(
          corrupt.canDo(permission, online: false),
          isFalse,
          reason:
              '${permission.id} must not be reachable through an unknown role',
        );
      }
    });

    test('asking without a role answers the role-independent question', () {
      // The repository call sites use the single-argument form only to pick which
      // error message to raise for a refusal they did not cause. Omitting the
      // role must therefore keep saying "this permission is privileged" for every
      // role, or a refusal would start blaming the network for a bad status.
      for (final permission in privilegedPermissions) {
        expect(
          permissionRequiresFreshSession(permission),
          isTrue,
          reason: permission.id,
        );
        expect(
          permissionRequiresFreshSession(permission, role: AppRoles.admin),
          isFalse,
          reason: permission.id,
        );
      }
    });
  });

  group('role labels', () {
    test('the lab role reads as a quality specialist', () {
      expect(AppRoles.label(AppRoles.lab), 'اخصائي جودة');
    });

    test('every role has its own non-empty label', () {
      // The labels were duplicated as literals in the members screen and drifted
      // apart from this table; this is what catches the next copy.
      final labels = AppRoles.all.map(AppRoles.label).toList();
      for (final label in labels) {
        expect(label.trim(), isNotEmpty);
      }
      expect(
        labels.toSet().length,
        labels.length,
        reason: 'two roles share a label',
      );
    });

    test('an unknown role falls back to the raw value', () {
      expect(AppRoles.label('superuser'), 'superuser');
    });

    test('the labels are defined once, in permissions.dart', () {
      // A standalone copy of a role label anywhere else in `lib/` is a second
      // source of truth that a rename cannot reach - which is exactly how the
      // members screen's role pickers went stale. Matched as a *whole* quoted
      // literal on purpose: prose that happens to name the role ("disabled by
      // the organization manager") is copy rather than a label, and rewriting a
      // sentence as a lookup would be worse than the duplication.
      final lib = Directory('lib');
      expect(lib.existsSync(), isTrue, reason: 'run from the package root');

      const labels = [
        'مدير المؤسسة',
        'مدير الجودة',
        'اخصائي جودة',
        'اطّلاع فقط',
      ];
      final offenders = <String>[];
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        if (file.path
            .replaceAll(r'\', '/')
            .endsWith('core/auth/permissions.dart')) {
          continue;
        }
        final source = file.readAsStringSync();
        for (final label in labels) {
          if (source.contains("'$label'")) {
            offenders.add('${file.path}: "$label"');
          }
        }
      }
      expect(offenders, isEmpty, reason: 'use AppRoles.label(role) instead');
    });
  });
}
