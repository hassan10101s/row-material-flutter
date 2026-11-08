import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/router/app_router.dart';

void main() {
  for (final role in AppRoles.all) {
    test('$role can open account and sync; only owner can open settings', () {
      final session = AppSession(
        uid: 'u',
        organizationId: 'org',
        role: role,
        status: 'active',
      );
      expect(AppRouter.guardRoute(AppRoutes.account, session), isNull);
      expect(AppRouter.guardRoute(AppRoutes.drafts, session), isNull);
      expect(
        AppRouter.guardRoute(AppRoutes.settings, session),
        role == AppRoles.admin ? isNull : AppRoutes.dashboard,
      );
      final user = User(email: 'u@example.test', role: role, status: 'active');
      expect(user.canSeeSettings, role == AppRoles.admin);
    });
  }
  test(
    'organization name survives an offline session and clears on organization switch',
    () {
      const session = AppSession(
        uid: 'u',
        organizationId: 'org',
        organizationName: 'مؤسسة الاختبار',
      );
      final restored = AppSession.decode(AppSession.encode(session));
      expect(restored.organizationName, session.organizationName);
      expect(
        restored.copyWith(organizationId: 'other').organizationName,
        isEmpty,
      );
    },
  );
}
