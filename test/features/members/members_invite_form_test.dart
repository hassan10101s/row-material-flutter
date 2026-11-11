import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/members/domain/member_repository.dart';
import 'package:material_lab/features/members/presentation/members/members_screen.dart';
import 'package:material_lab/features/organizations/domain/organization_repository.dart';

class _Gate extends Mock implements AuthGate {}

class _Members extends Mock implements MemberRepository {}

class _Organizations extends Mock implements OrganizationRepository {}

AppSession _adminSession() => AppSession(
  uid: 'owner',
  email: 'owner@lab.test',
  organizationId: 'org_test',
  memberId: 'owner',
  role: 'admin',
  status: 'active',
  // The invite button needs a fresh token for `users.create`.
  idTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
);

void _registerStack(
  _Members members,
  _Organizations organizations,
  List<Member> roster,
) {
  final gate = _Gate();
  when(() => gate.canWrite(any())).thenReturn(true);
  when(() => gate.online).thenReturn(true);
  when(() => gate.organizationId).thenReturn('org_test');
  when(() => gate.session).thenReturn(_adminSession());
  when(() => members.listMembers()).thenAnswer((_) async => roster);
  when(() => organizations.loadOrganization()).thenAnswer(
    (_) async => const OrganizationProfile(
      id: 'org_test',
      name: 'Test Company',
      ownerUid: 'owner',
    ),
  );
  getIt
    ..registerSingleton<AuthGate>(gate)
    ..registerSingleton<MemberRepository>(members)
    ..registerSingleton<OrganizationRepository>(organizations);
}

const Member _member = Member(
  id: 'm1',
  email: 'tech@lab.test',
  displayName: 'Lab technician',
  role: 'lab',
  status: 'active',
);

void main() {
  setUpAll(() => registerFallbackValue(Permission.usersUpdate));
  setUp(() => AppText.useLanguage('en'));
  tearDown(() async {
    FormFactor.debugSet(null);
    await getIt.reset();
  });

  Future<void> pumpMembers(WidgetTester tester, bool mobile) async {
    FormFactor.debugSet(mobile ? AppFormFactor.mobile : AppFormFactor.desktop);
    final size = mobile ? const Size(390, 844) : const Size(1280, 900);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: size,
        builder: (_, _) => const MaterialApp(
          home: Scaffold(body: MembersScreen(embedded: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a successful invite clears the field without a "required" error',
    (tester) async {
      final members = _Members(), organizations = _Organizations();
      _registerStack(members, organizations, const [_member]);
      when(
        () => members.invite(
          email: any(named: 'email'),
          role: any(named: 'role'),
          roles: any(named: 'roles'),
        ),
      ).thenAnswer((_) async {});

      await pumpMembers(tester, false);
      await tester.enterText(
        find.byKey(const Key('inviteEmailField')),
        'new@lab.test',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('sendInvite')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sendInvite')));
      await tester.pumpAndSettle();

      verify(
        () => members.invite(
          email: 'new@lab.test',
          role: any(named: 'role'),
          roles: any(named: 'roles'),
        ),
      ).called(1);
      // The field is empty again (regression: the programmatic clear used to
      // trip `onUserInteraction` autovalidate against the emptied field and
      // print "Email is required." right under the "Invite sent." banner).
      final emailField = find.descendant(
        of: find.byKey(const Key('inviteEmailField')),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(emailField).controller!.text,
        isEmpty,
      );
      expect(find.text('Email is required.'), findsNothing);
    },
  );

  testWidgets(
    'a failed invite keeps the typed email for the retry',
    (tester) async {
      final members = _Members(), organizations = _Organizations();
      _registerStack(members, organizations, const [_member]);
      when(
        () => members.invite(
          email: any(named: 'email'),
          role: any(named: 'role'),
          roles: any(named: 'roles'),
        ),
      ).thenThrow(Exception('connection failed'));

      await pumpMembers(tester, false);
      await tester.enterText(
        find.byKey(const Key('inviteEmailField')),
        'new@lab.test',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('sendInvite')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sendInvite')));
      await tester.pumpAndSettle();

      final emailField = find.descendant(
        of: find.byKey(const Key('inviteEmailField')),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(emailField).controller!.text,
        'new@lab.test',
      );
    },
  );

  testWidgets(
    'phone roster with many members scrolls to the last card without overflow',
    (tester) async {
      final members = _Members(), organizations = _Organizations();
      _registerStack(members, organizations, [
        for (var i = 1; i <= 30; i++)
          Member(
            id: 'm$i',
            email: 'member$i@lab.test',
            displayName: 'Member $i',
            role: 'lab',
            status: 'active',
          ),
      ]);

      await pumpMembers(tester, true);

      final last = find.text('member30@lab.test');
      expect(last, findsOneWidget);
      await tester.scrollUntilVisible(last, 300, scrollable: find.byType(Scrollable).first);
      expect(tester.takeException(), isNull);
      expect(last, findsOneWidget);
    },
  );
}
