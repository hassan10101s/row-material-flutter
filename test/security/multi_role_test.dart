import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/features/auth/domain/user.dart';

void main() {
  const employee = AppSession(
    uid: 'employee',
    organizationId: 'org',
    role: AppRoles.lab,
    roles: [AppRoles.lab, AppRoles.nutritionist],
    status: MemberStatus.active,
  );

  test('combined employee grants survive an offline cache round trip', () {
    final restored = AppSession.decode(AppSession.encode(employee));
    expect(restored.canDo(Permission.samplesCreate), isTrue);
    expect(restored.canDo(Permission.formulationsCreate), isTrue);
    expect(restored.canDo(Permission.usersCreate), isFalse);
    expect(restored.effectiveRoles, employee.effectiveRoles);
    expect(
      restored.copyWith(organizationStatus: 'suspended').canWrite,
      isFalse,
    );
    expect(
      restored
          .copyWith(organizationStatus: 'suspended')
          .canDo(Permission.formulationsCreate),
      isFalse,
    );
    expect(restored.copyWith(readOnlyDevice: true).canWrite, isFalse);
    expect(
      restored
          .copyWith(readOnlyDevice: true)
          .canDo(Permission.formulationsCreate),
      isFalse,
    );
    expect(
      restored
          .copyWith(status: MemberStatus.disabled)
          .canDo(Permission.samplesCreate),
      isFalse,
    );
  });

  test('secondary quality role still requires a fresh online session', () {
    final session = employee.copyWith(
      roles: [AppRoles.lab, AppRoles.qualityManager],
      idTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
    expect(session.canDo(Permission.qcApprove), isTrue);
    expect(session.canDo(Permission.qcApprove, online: false), isFalse);
    expect(
      session.copyWith(clearToken: true).canDo(Permission.qcApprove),
      isFalse,
    );
  });

  test('malformed role arrays never recover primary write grants', () {
    for (final raw in <Object?>[
      [],
      ['lab', 'lab'],
      ['lab', 'unknown'],
      ['lab', 3],
      ['lab', 'admin'],
      ['lab', 'viewer'],
      ['nutritionist', 'lab'],
      'lab',
      <String, Object>{},
      null,
    ]) {
      final restored = AppSession.fromJson({
        'uid': 'employee',
        'organizationId': 'org',
        'role': 'lab',
        'roles': raw,
        'status': 'active',
      });
      expect(restored.canWrite, isFalse, reason: '$raw');
      final profile = UserProfile.fromMap(
        {
          'organizationId': 'org',
          'role': 'lab',
          'roles': raw,
          'status': 'active',
        },
        'employee',
        'employee@lab.test',
      );
      expect(rolesAreReadOnly(profile!.effectiveRoles), isTrue, reason: '$raw');
    }
  });

  test('legacy single-role caches and migrated SQLite rows retain grants', () {
    expect(
      AppSession.fromJson({
        'role': 'Admin',
        'status': 'active',
      }).canDo(Permission.usersCreate),
      isTrue,
    );
    expect(
      User.fromMap({
        'role': 'lab',
        'roles_json': '[]',
        'status': 'active',
      }).canCreateInspection,
      isTrue,
    );
    expect(
      User.fromMap({
        'role': 'admin',
        'roles_json': '{broken',
        'status': 'active',
      }).canEditUsers,
      isFalse,
    );
    expect(
      User.fromMap({
        'role': 'admin',
        'roles_json': 'null',
        'status': 'active',
      }).canEditUsers,
      isFalse,
    );
  });
}
