import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';
import 'package:material_lab/features/members/domain/member_repository.dart';
import 'package:material_lab/features/members/presentation/members/members_screen.dart';
import 'package:material_lab/features/organizations/domain/organization_repository.dart';

class _Auth extends Mock implements AuthRepository {}

class _Members extends Mock implements MemberRepository {}

class _Organizations extends Mock implements OrganizationRepository {}

void main() {
  testWidgets(
    'organization name is visible beside the code while Copy copies only the code',
    (tester) async {
      AppText.useLanguage('en');
      final auth = _Auth(),
          members = _Members(),
          organizations = _Organizations();
      when(() => auth.session).thenReturn(
        const AppSession(
          uid: 'u',
          organizationId: 'org_test',
          organizationName: 'شركة الاختبار',
          role: 'admin',
          status: 'active',
          memberId: 'm',
        ),
      );
      when(() => auth.state).thenReturn(AuthState.ready);
      when(() => members.listMembers()).thenAnswer((_) async => []);
      when(() => organizations.loadOrganization()).thenAnswer(
        (_) async => const OrganizationProfile(
          id: 'org_test',
          name: 'شركة الاختبار',
          ownerUid: 'u',
        ),
      );
      getIt.registerSingleton<AuthGate>(AuthGate(auth));
      getIt.registerSingleton<MemberRepository>(members);
      getIt.registerSingleton<OrganizationRepository>(organizations);
      addTearDown(() => getIt.reset());
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(1280, 900),
          builder: (_, child) =>
              const MaterialApp(home: Scaffold(body: MembersScreen())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('شركة الاختبار • org_test'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('copyOrgCode')));
      await tester.tap(find.byKey(const Key('copyOrgCode')));
      await tester.pump();
      expect(copied, 'org_test');
    },
  );
}
