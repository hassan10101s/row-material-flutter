import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';
import 'package:material_lab/features/inspections/presentation/qr/mobile_qr_overlay.dart';
import 'package:material_lab/features/inspections/presentation/qr/qr_scan_screen.dart';

class _Auth extends Mock implements AuthRepository {}

void main() {
  late _Auth auth;
  late AuthGate gate;
  late MobileQrNavigation navigation;
  late GlobalKey<NavigatorState> rootKey;
  late GlobalKey<NavigatorState> shellKey;
  const launcher = Key('global-qr-scan');

  setUp(() {
    AppText.arabic = false;
    auth = _Auth();
    when(() => auth.state).thenReturn(AuthState.ready);
    when(() => auth.session).thenReturn(
      const AppSession(
        uid: 'u',
        role: AppRoles.admin,
        status: MemberStatus.active,
      ),
    );
    gate = AuthGate(auth);
    navigation = MobileQrNavigation();
    rootKey = GlobalKey<NavigatorState>();
    shellKey = GlobalKey<NavigatorState>();
  });

  tearDown(() {
    AppText.arabic = true;
    gate.dispose();
    navigation.dispose();
  });

  Widget host() => ScreenUtilInit(
    designSize: const Size(400, 860),
    builder: (_, _) => MaterialApp(
      navigatorKey: rootKey,
      navigatorObservers: [navigation.rootObserver],
      builder: (_, child) => MobileQrOverlay(
        gate: gate,
        navigation: navigation,
        navigatorKey: rootKey,
        child: child!,
      ),
      home: Navigator(
        key: shellKey,
        observers: [navigation.shellObserver],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: const Center(child: Text('Home')),
            floatingActionButton: FloatingActionButton(
              key: const Key('page-add'),
              heroTag: null,
              onPressed: () {},
              child: const Icon(Icons.add),
            ),
          ),
        ),
      ),
    ),
  );

  for (final size in [const Size(390, 844), const Size(844, 420)]) {
    testWidgets(
      'one launcher survives navigation without covering the page FAB at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(find.byKey(launcher), findsOneWidget);
        expect(
          tester
              .getRect(find.byKey(launcher))
              .overlaps(tester.getRect(find.byKey(const Key('page-add')))),
          isFalse,
        );
        shellKey.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Nested detail')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(launcher), findsOneWidget);
        rootKey.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Root detail')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(launcher), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'dialogs on either navigator hide the launcher and restore it on close',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      for (final root in [true, false]) {
        showDialog<void>(
          context: shellKey.currentContext!,
          useRootNavigator: root,
          builder: (_) => const AlertDialog(content: Text('Dialog')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(launcher), findsNothing);
        (root ? rootKey : shellKey).currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(launcher), findsOneWidget);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'scanner opens once, hides its launcher, and restores it on back',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('material_lab/qr_camera'),
        (_) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('material_lab/qr_camera'),
          null,
        ),
      );
      await tester.tap(find.byKey(launcher));
      await tester.pumpAndSettle();
      expect(find.byType(QrScanScreen), findsOneWidget);
      expect(find.byKey(launcher), findsNothing);
      rootKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(launcher), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'keyboard, sign-out and missing permissions hide the launcher',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(find.byKey(launcher), findsNothing);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.byKey(launcher), findsOneWidget);
      when(() => auth.state).thenReturn(AuthState.signedOut);
      gate.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(launcher), findsNothing);
      when(() => auth.state).thenReturn(AuthState.ready);
      when(
        () => auth.session,
      ).thenReturn(const AppSession(uid: 'u', status: MemberStatus.invited));
      gate.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(launcher), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Windows never offers or constructs the camera scanner',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.byKey(launcher), findsNothing);
      expect(find.byType(QrScanScreen), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
