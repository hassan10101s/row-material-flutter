import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/locale/locale_service.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/theme/theme_service.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';
import 'package:material_lab/features/shell/presentation/mobile/app_shell.dart';
import 'package:material_lab/features/shell/presentation/chrome_reveal.dart';
import 'package:material_lab/features/shell/presentation/shell_nav.dart';
import 'package:material_lab/features/sync/presentation/sync_status_controller.dart';

class _QueueMock extends Mock implements SyncQueue {}

class _MetadataMock extends Mock implements SyncMetadata {}

class _SettingsMock extends Mock implements SettingsRepo {}

User _user() => User(
  uid: 'u1',
  email: 'hassan@example.com',
  fullName: 'Hassan Ali',
  role: 'admin',
  status: MemberStatus.active,
);

void main() {
  late _QueueMock queue;
  late _MetadataMock metadata;
  late _SettingsMock settings;
  late LocaleService locale;
  late ThemeService theme;

  setUp(() {
    AppText.useLanguage('en');
    queue = _QueueMock();
    metadata = _MetadataMock();
    settings = _SettingsMock();
    locale = LocaleService(settings: settings);
    theme = ThemeService(settings: settings);
  });

  SyncStatusController badge() {
    when(queue.countPending).thenAnswer((_) async => 0);
    when(queue.countBlocked).thenAnswer((_) async => 0);
    when(metadata.lastPushAt).thenAnswer((_) async => null);
    when(metadata.lastPullAt).thenAnswer((_) async => null);
    return SyncStatusController(
      queue: queue,
      metadata: metadata,
      isOnline: () => true,
    );
  }

  Iterable<ChromeReveal> reveals(WidgetTester tester, ChromeRevealEdge edge) =>
      tester
          .widgetList<ChromeReveal>(find.byType(ChromeReveal))
          .where((w) => w.edge == edge);

  /// Page content tall enough that flings scroll it both ways.
  ///
  /// The child is a bare ListView on purpose: theNotificationListener in the
  /// shell body observes it through the same bubbling a real screen's list
  /// (AppInfiniteList, CustomScrollView) would use.
  Widget page() => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    children: [
      for (var i = 0; i < 60; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text('row $i'),
        ),
    ],
  );

  GoRouter router() => GoRouter(
    initialLocation: '/dashboard',
    routes: [
      ShellRoute(
        builder: (context, state, child) => MobileAppShell(
          user: _user(),
          entries: shellNavEntries(canSeeSettings: true),
          locale: locale,
          theme: theme,
          syncStatus: badge(),
          onNavigate: (path) => {},
          onLogout: () {},
          onLogoutThisDevice: () {},
          onOpenPdfFolder: () {},
          canOpenPdfFolder: false,
          child: child,
        ),
        routes: [
          GoRoute(path: '/dashboard', builder: (context, state) => page()),
        ],
      ),
    ],
  );

  Future<void> pumpShell(WidgetTester tester, {bool keyboard = false}) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 860);

    final r = router();
    addTearDown(r.dispose);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(400, 860),
        minTextAdapt: true,
        builder: (_, _) => keyboard
            ? MediaQuery(
                data: const MediaQueryData(
                  viewInsets: EdgeInsets.only(bottom: 240),
                ),
                child: MaterialApp.router(routerConfig: r),
              )
            : MaterialApp.router(routerConfig: r),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('chrome is visible before any scroll', (tester) async {
    await pumpShell(tester);
    expect(find.byType(ChromeReveal), findsNWidgets(2));
    for (final edge in ChromeRevealEdge.values) {
      expect(reveals(tester, edge).every((w) => w.visible), isTrue);
    }
    final nav = tester.getRect(find.byType(NavigationBar));
    expect(nav.bottom, lessThanOrEqualTo(860));
  });

  testWidgets(
    'scrolling down conceals both bars, scrolled up brings them back',
    (tester) async {
      await pumpShell(tester);

      // The fling leaves a ballistic glide downward; its user-scroll direction
      // reaches the shell controller the same way a dragged AppInfiniteList
      // would.
      await tester.flingFrom(
        const Offset(200, 400),
        const Offset(0, -600),
        900,
      );
      await tester.pumpAndSettle();
      for (final edge in ChromeRevealEdge.values) {
        expect(
          reveals(tester, edge).every((w) => w.visible),
          isFalse,
          reason: '${edge.name} bar should be folded after scrolling down',
        );
      }

      await tester.flingFrom(const Offset(200, 300), const Offset(0, 600), 900);
      await tester.pumpAndSettle();
      for (final edge in ChromeRevealEdge.values) {
        expect(reveals(tester, edge).every((w) => w.visible), isTrue);
      }
    },
  );

  testWidgets('pulling down at the top edge reveals even mid-hidden', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.flingFrom(const Offset(200, 500), const Offset(0, -600), 900);
    await tester.pumpAndSettle();
    expect(
      reveals(tester, ChromeRevealEdge.bottom).every((w) => w.visible),
      isFalse,
    );

    // Overscroll the rubber band: with AlwaysScrollableScrollPhysics the top
    // drag is stretched past the edge, and that gesture reveals.
    await tester.flingFrom(const Offset(200, 300), const Offset(0, 600), 400);
    await tester.pumpAndSettle();
    expect(
      reveals(tester, ChromeRevealEdge.bottom).every((w) => w.visible),
      isTrue,
    );
  });

  testWidgets('the drawer forces the chrome back while it is open', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.flingFrom(const Offset(200, 400), const Offset(0, -600), 900);
    await tester.pumpAndSettle();
    expect(
      reveals(tester, ChromeRevealEdge.bottom).every((w) => w.visible),
      isFalse,
    );

    // Folded chrome cannot be tapped, so the reveal comes from a short upward
    // drag, then the drawer is opened: while it is open the chrome is quoted
    // back by `forced`, even though the page below is still scrolled down.
    await tester.flingFrom(const Offset(200, 300), const Offset(0, 400), 800);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(
      reveals(tester, ChromeRevealEdge.bottom).every((w) => w.visible),
      isTrue,
      reason: 'open drawer must be able to see the chrome',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the keyboard keeps the nav bar folded', (tester) async {
    await pumpShell(tester, keyboard: true);
    // viewInsets bottom is 240 in this harness: shell folds the bottom bar
    // right away so the form body keeps the space.
    expect(
      reveals(tester, ChromeRevealEdge.bottom).every((w) => w.visible),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
