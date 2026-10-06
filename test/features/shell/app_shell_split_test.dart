import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/locale/locale_service.dart';
import 'package:material_lab/core/network/connectivity_service.dart';
import 'package:material_lab/core/platform/file_delivery.dart';
import 'package:material_lab/core/platform/folder_picker.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/theme/theme_service.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';
import 'package:material_lab/features/settings/domain/export_root_service.dart';
import 'package:material_lab/features/shell/presentation/app_shell.dart';
import 'package:material_lab/features/shell/presentation/desktop/app_shell.dart';
import 'package:material_lab/features/shell/presentation/mobile/app_shell.dart';
import 'package:material_lab/features/shell/presentation/shell_chrome.dart';
import 'package:material_lab/features/shell/presentation/shell_nav.dart';
import 'package:material_lab/features/sync/presentation/sync_status_controller.dart';

class _QueueMock extends Mock implements SyncQueue {}

class _MetadataMock extends Mock implements SyncMetadata {}

class _AuthMock extends Mock implements AuthRepository {}

class _SettingsMock extends Mock implements SettingsRepo {}

/// A delivery port whose answer is chosen by the test.
///
/// The shell asks [FileDelivery.canReveal] and hides the exports-folder button
/// when it is false, so a configurable port is the only way to assert both
/// branches without depending on which platform the suite happens to run on.
class _FakeDelivery implements FileDelivery {
  const _FakeDelivery({required this.canReveal});

  @override
  final bool canReveal;

  @override
  bool get canShare => true;

  @override
  Future<bool> reveal(String filePath) async => canReveal;

  @override
  Future<bool> share(String filePath, {String? subject}) async => true;
}

const desktopGrid = Size(1280, 720);
const mobileGrid = Size(400, 860);

/// Every route the shell owns, in the order [shellNavEntries] declares them.
const shellRoutes = <String>[
  '/dashboard',
  '/inspections',
  '/lab',
  '/quality-management',
  '/reference',
  '/settings',
  '/audit',
];

User _userFor(String role) => User(
  uid: 'u1',
  email: 'hassan@example.com',
  fullName: 'Hassan Ali',
  role: role,
  status: MemberStatus.active,
);

void main() {
  late _QueueMock queue;
  late _MetadataMock metadata;
  late _SettingsMock settings;
  late LocaleService locale;
  late ThemeService theme;
  late ExportRootService exportRoot;

  setUp(() {
    // The UI strings are chosen by a global; pin them so the finders below are
    // stable whichever language the previous test left behind.
    AppText.useLanguage('en');

    queue = _QueueMock();
    metadata = _MetadataMock();
    settings = _SettingsMock();
    locale = LocaleService(settings: settings);
    theme = ThemeService(settings: settings);
    exportRoot = ExportRootService(repo: settings);
  });

  tearDown(() {
    // FormFactor memoises, so a test that pinned it must not leak into the next.
    FormFactor.debugSet(null);
  });

  /// The destinations for [role], resolved through the same permission matrix the
  /// shell uses.
  List<ShellNavEntry> entriesFor(String role) => shellNavEntries(
    canSeeSettings: rolePermissions(role).contains(Permission.usersRead),
    canAudit: rolePermissions(role).contains(Permission.auditRead),
  );

  /// A badge that has never been started, so nothing here touches a database.
  ///
  /// [SyncStatusController.refresh] swallows every failure by design - a badge
  /// must never break the shell - so a stubbed queue is belt and braces rather
  /// than a requirement.
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

  /// A router whose shell builder is whatever the test needs, with one route per
  /// destination so `GoRouterState.of(context).uri.path` resolves for real.
  ///
  /// The pages are bare `Center`s on purpose: an extra `Scaffold` inside the
  /// shell would be found by `find.byType(Scaffold)` before the shell's own.
  GoRouter routerWith(Widget Function(Widget child) shell) => GoRouter(
    initialLocation: '/dashboard',
    routes: [
      ShellRoute(
        builder: (context, state, child) => Focus(child: shell(child)),
        routes: [
          for (final path in shellRoutes)
            GoRoute(
              path: path,
              builder: (context, state) => Center(child: Text('page $path')),
            ),
        ],
      ),
    ],
  );

  Future<void> pumpOn(
    WidgetTester tester,
    GoRouter router, {
    required Size grid,
  }) async {
    addTearDown(router.dispose);
    addTearDown(tester.view.reset);

    // The previous tree is unmounted *before* the window changes size. Resizing
    // under a live tree makes it lay out once at the new metrics on the way to
    // being replaced, and the desktop chrome - a 280dp sidebar beside the bar -
    // overflows that transient frame. This is also why each shell is only ever
    // pumped at its own grid below: which chrome to build is a platform
    // decision, so a narrow desktop window is not a case the app supports.
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = grid;

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: grid,
        builder: (_, _) => MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The engine's back gesture, the way Android sends it.
  ///
  /// `tester.pageBack()` cannot be used: it taps a back button, and the shell
  /// has none - the point is that the *system* gesture is intercepted.
  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDesktop(WidgetTester tester, GoRouter router) =>
      pumpOn(tester, router, grid: desktopGrid);

  Future<void> pumpMobile(WidgetTester tester, GoRouter router) =>
      pumpOn(tester, router, grid: mobileGrid);

  /// The shell under test, with every dependency injected - nothing here reaches
  /// for a service locator.
  Widget desktopShell({
    required User user,
    required List<ShellNavEntry> entries,
    required void Function(String path) onNavigate,
    bool canOpenPdfFolder = true,
    required Widget child,
  }) => DesktopAppShell(
    user: user,
    entries: entries,
    locale: locale,
    theme: theme,
    syncStatus: badge(),
    onNavigate: onNavigate,
    onLogout: () {},
    onLogoutThisDevice: () {},
    onOpenPdfFolder: () {},
    canOpenPdfFolder: canOpenPdfFolder,
    child: child,
  );

  Widget mobileShell({
    required User user,
    required List<ShellNavEntry> entries,
    required void Function(String path) onNavigate,
    bool canOpenPdfFolder = true,
    required Widget child,
  }) => MobileAppShell(
    user: user,
    entries: entries,
    locale: locale,
    theme: theme,
    syncStatus: badge(),
    onNavigate: onNavigate,
    onLogout: () {},
    onLogoutThisDevice: () {},
    onOpenPdfFolder: () {},
    canOpenPdfFolder: canOpenPdfFolder,
    child: child,
  );

  /// The labels a chrome currently lists, read off the widgets rather than off
  /// the rendered text - the identity card renders text too, so a `find.text`
  /// sweep would be measuring the wrong thing.
  List<String> listedLabels(WidgetTester tester, {Finder? within}) {
    final finder = within == null
        ? find.byType(ShellNavItem)
        : find.descendant(of: within, matching: find.byType(ShellNavItem));
    return [
      for (final item in tester.widgetList<ShellNavItem>(finder)) item.label,
    ];
  }

  /// The labels on the bar, read off the destinations themselves rather than off
  /// the rendered text: the drawer and the identity card also render labels.
  List<String> bottomBarLabels(WidgetTester tester) => [
    for (final destination
        in tester
            .widget<NavigationBar>(find.byType(NavigationBar))
            .destinations)
      if (destination case final NavigationDestination nav) nav.label,
  ];

  Finder bottomBarIcon(WidgetTester tester, ShellNavEntry entry) =>
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(entry.icon),
      );

  Finder moreSlot(WidgetTester tester) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.byIcon(Icons.more_horiz),
  );

  group('the destination list is described once, for both experiences', () {
    test('the unconditional destinations come first, in order', () {
      expect(
        shellNavEntries(
          canSeeSettings: false,
          canAudit: false,
        ).map((e) => e.path),
        ['/dashboard', '/inspections', '/lab'],
        reason:
            'material reports are integrated into inspections and the base '
            'destinations are consistent across roles',
      );
    });

    test('the bottom bar is the first available destinations', () {
      for (final canSeeSettings in [false, true]) {
        for (final canAudit in [false, true]) {
          final entries = shellNavEntries(
            canSeeSettings: canSeeSettings,
            canAudit: canAudit,
          );
          expect(
            shellBottomBarEntries(entries).map((e) => e.path),
            entries.take(shellBottomBarSlots).map((e) => e.path),
            reason: 'settings=$canSeeSettings audit=$canAudit',
          );
        }
      }
    });

    test('the gated destinations are appended after the base entries', () {
      expect(
        shellNavEntries(
          canSeeSettings: true,
          canAudit: true,
        ).map((e) => e.path),
        [...shellRoutes.take(3), '/reference', '/settings', '/audit'],
      );
    });

    test('the QC destination appears only for a member who can read it', () {
      // Someone without `qc.read` must not be offered a screen the route guard
      // would bounce them out of.
      expect(
        shellNavEntries(
          canSeeSettings: true,
          canAudit: true,
        ).map((e) => e.path),
        everyElement(
          isNot(
            anyOf(
              '/quality-management',
            ),
          ),
        ),
      );
      expect(
        shellNavEntries(
          canSeeSettings: true,
          canAudit: true,
          canReadQc: true,
        ).map((e) => e.path),
        contains('/quality-management'),
      );
    });

    test('quality management is one gated destination before settings', () {
      expect(
        shellNavEntries(
          canSeeSettings: false,
          canAudit: false,
          canReadQc: true,
        ).map((e) => e.path),
        [
          '/dashboard',
          '/inspections',
          '/lab',
          '/quality-management',
        ],
      );
    });

    test('an inspection sheet lights the inspections section', () {
      // `/qc-inspections/detail` is longer than `/qc-inspections`, so the
      // longest-prefix match is what keeps the QC block lit while a sheet is
      // open - and it must not be mistaken for the NCR report.
      final entries = shellNavEntries(
        canSeeSettings: false,
        canAudit: false,
        canReadQc: true,
      );
      expect(
        shellSectionIndex(entries, '/qc-inspections/detail?inspectionId=7'),
        shellSectionIndex(entries, '/qc-inspections'),
      );
      expect(
        shellSectionIndex(entries, '/qc-inspections/detail?inspectionId=7'),
        shellSectionIndex(entries, '/quality-management'),
      );
    });

    test('the goals detail route lights the goals section', () {
      final entries = shellNavEntries(
        canSeeSettings: false,
        canAudit: false,
        canReadQc: true,
      );
      expect(
        shellSectionIndex(entries, '/qc-goals/detail?goalId=7'),
        shellSectionIndex(entries, '/qc-goals'),
      );
      expect(
        shellSectionIndex(entries, '/qc-goals/detail?goalId=7'),
        shellSectionIndex(entries, '/quality-management'),
      );
    });

    test('a detail route under the NCR report still lights its section', () {
      // The list and detail routes are longer than `/qc-ncr`, so longest-prefix
      // matching has to keep the section highlighted on the way in.
      final entries = shellNavEntries(
        canSeeSettings: false,
        canAudit: false,
        canReadQc: true,
      );
      expect(
        shellSectionIndex(entries, '/qc-ncr/detail?findingId=7'),
        shellSectionIndex(entries, '/quality-management'),
      );
      expect(
        shellSectionIndex(entries, '/qc-ncr/detail?findingId=7'),
        isNonNegative,
      );
    });

    test('the audit gate is independent of the settings gate', () {
      // A device switched read-only keeps `org.read` but can be stripped of
      // `audit.read`, so the two gates cannot be folded into one condition.
      final auditOnly = shellNavEntries(canSeeSettings: false, canAudit: true);
      expect(auditOnly.map((e) => e.path), contains('/audit'));
      expect(auditOnly.map((e) => e.path), isNot(contains('/settings')));
      expect(auditOnly.map((e) => e.path), isNot(contains('/reference')));
    });

    test('a detail route lights its section, not nothing', () {
      final entries = shellNavEntries(canSeeSettings: true, canAudit: true);
      expect(shellSectionIndex(entries, '/inspections'), 1);
      expect(shellSectionIndex(entries, '/inspections/42'), 1);
      expect(shellSectionIndex(entries, '/reports'), 1);
      expect(shellSectionIndex(entries, '/settings'), 4);
      expect(shellSectionIndex(entries, '/nowhere'), -1);
    });

    test('the longest matching prefix wins', () {
      // Guards against a prefix match that stops at the first hit: if `/lab` and
      // `/lab/deep` were both destinations, the detail route must light the more
      // specific one.
      const entries = [
        ShellNavEntry('/lab', 'Lab', Icons.biotech_outlined),
        ShellNavEntry('/lab/deep', 'Deep', Icons.extension_outlined),
      ];
      expect(shellSectionIndex(entries, '/lab/deep/x'), 1);
    });

    test('the shortcut list stops at the ninth digit', () {
      final many = [
        for (var i = 0; i < 12; i++)
          ShellNavEntry('/p$i', 'P$i', Icons.circle_outlined),
      ];
      expect(shellShortcutPaths(many), hasLength(shellShortcutCount));
      expect(shellShortcutPaths(many).last, '/p8');
    });

    test('the shortcut bindings are Ctrl+1.. in destination order', () {
      final entries = shellNavEntries(canSeeSettings: true, canAudit: true);
      final navigated = <String>[];
      final bindings = shellShortcutBindings(entries, navigated.add);

      expect(bindings, hasLength(entries.length));
      for (var i = 0; i < entries.length; i++) {
        final activator = bindings.keys.elementAt(i) as SingleActivator;
        expect(activator.control, isTrue);
        expect(
          activator.trigger,
          LogicalKeyboardKey(0x31 + i),
          reason: 'Ctrl+${i + 1} must address ${entries[i].path}',
        );
      }
    });
  });

  group('the desktop variant is the pre-split shell', () {
    testWidgets('a sidebar, no bottom bar and no drawer', (tester) async {
      final entries = entriesFor(AppRoles.admin);
      await pumpDesktop(
        tester,
        routerWith(
          (child) => desktopShell(
            user: _userFor(AppRoles.admin),
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(Drawer), findsNothing);
      expect(
        listedLabels(tester),
        entries.map((e) => e.label).toList(),
        reason: 'the sidebar lists every destination, in order',
      );
    });

    testWidgets('Ctrl+1..9 addresses every destination in order', (
      tester,
    ) async {
      final navigated = <String>[];
      final entries = entriesFor(AppRoles.admin);

      await pumpDesktop(
        tester,
        routerWith(
          (child) => desktopShell(
            user: _userFor(AppRoles.admin),
            entries: entries,
            onNavigate: navigated.add,
            child: child,
          ),
        ),
      );

      for (var i = 0; i < entries.length; i++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey(0x31 + i));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      expect(
        navigated,
        entries.map((e) => e.path).toList(),
        reason: 'Ctrl+1 must be the first destination and Ctrl+2 the second',
      );
    });
  });

  group('the phone variant reaches the same destinations', () {
    testWidgets('the bottom bar holds the first four, More opens the drawer', (
      tester,
    ) async {
      final navigated = <String>[];
      final entries = entriesFor(AppRoles.admin);

      await pumpMobile(
        tester,
        routerWith(
          (child) => mobileShell(
            user: _userFor(AppRoles.admin),
            entries: entries,
            onNavigate: navigated.add,
            child: child,
          ),
        ),
      );

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(Drawer), findsNothing);
      expect(bottomBarLabels(tester), [
        ...shellBottomBarEntries(entries).map((e) => e.label),
        AppStrings.more,
      ]);

      for (final entry in shellBottomBarEntries(entries)) {
        await tester.tap(bottomBarIcon(tester, entry));
        await tester.pumpAndSettle();
      }
      expect(
        navigated,
        entries.take(shellBottomBarSlots).map((e) => e.path).toList(),
      );

      navigated.clear();
      await tester.tap(moreSlot(tester));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(
        listedLabels(tester, within: find.byType(Drawer)),
        entries.map((e) => e.label).toList(),
        reason: 'the drawer is the sidebar equivalent: every destination, once',
      );
    });

    testWidgets(
      'bottom-bar targets and drawer targets together equal the sidebar list',
      (tester) async {
        final entries = entriesFor(AppRoles.admin);

        // Desktop: every destination is one tap on the sidebar.
        final desktopTaps = <String>[];
        await pumpDesktop(
          tester,
          routerWith(
            (child) => desktopShell(
              user: _userFor(AppRoles.admin),
              entries: entries,
              onNavigate: desktopTaps.add,
              child: child,
            ),
          ),
        );
        for (final entry in entries) {
          await tester.tap(find.text(entry.label));
          await tester.pumpAndSettle();
        }

        // Phone: four on the bottom bar, the rest through More. Selecting from
        // the drawer closes it, so it is reopened for each gated destination -
        // which is itself the behaviour being asserted.
        final phoneTaps = <String>[];
        await pumpMobile(
          tester,
          routerWith(
            (child) => mobileShell(
              user: _userFor(AppRoles.admin),
              entries: entries,
              onNavigate: phoneTaps.add,
              child: child,
            ),
          ),
        );
        for (final entry in shellBottomBarEntries(entries)) {
          await tester.tap(bottomBarIcon(tester, entry));
          await tester.pumpAndSettle();
        }
        for (final entry in entries.skip(shellBottomBarSlots)) {
          await tester.tap(moreSlot(tester));
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(Drawer),
              matching: find.text(entry.label),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byType(Drawer),
            findsNothing,
            reason: '${entry.path} must dismiss the drawer on the way out',
          );
        }

        expect(
          desktopTaps,
          phoneTaps,
          reason:
              'a destination the desktop offers must be reachable on the phone '
              'too, in the same order',
        );
        expect(desktopTaps, entries.map((e) => e.path).toList());
      },
    );

    testWidgets('long press is the phone answer to Ctrl+1..9', (tester) async {
      final navigated = <String>[];
      final entries = entriesFor(AppRoles.admin);

      await pumpMobile(
        tester,
        routerWith(
          (child) => mobileShell(
            user: _userFor(AppRoles.admin),
            entries: entries,
            onNavigate: navigated.add,
            child: child,
          ),
        ),
      );

      await tester.longPress(bottomBarIcon(tester, entries.first));
      await tester.pumpAndSettle();

      // A long press is not a tap: the destination must not also have been
      // selected on the way to opening the sheet.
      expect(navigated, isEmpty);

      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      final jumpPaths = shellShortcutPaths(entries);
      for (final path in jumpPaths) {
        final label = entries.firstWhere((e) => e.path == path).label;
        expect(
          find.descendant(of: sheet, matching: find.text(label)),
          findsOneWidget,
          reason: path,
        );
      }
      expect(
        tester
            .widgetList<ListTile>(
              find.descendant(of: sheet, matching: find.byType(ListTile)),
            )
            .length,
        jumpPaths.length,
        reason: 'the sheet addresses exactly what Ctrl+1..9 addresses',
      );

      final settings = entries.firstWhere((e) => e.path == '/settings');
      await tester.tap(
        find.descendant(of: sheet, matching: find.text(settings.label)),
      );
      await tester.pumpAndSettle();
      expect(navigated, ['/settings']);
    });

    testWidgets('the drawer closes on the system back gesture', (tester) async {
      await pumpMobile(
        tester,
        routerWith(
          (child) => mobileShell(
            user: _userFor(AppRoles.admin),
            entries: entriesFor(AppRoles.admin),
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );

      final guard = tester.widget<PopScope>(
        find.byKey(const Key('shell-back-guard')),
      );
      expect(guard.canPop, isTrue);

      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(
        tester
            .widget<PopScope>(find.byKey(const Key('shell-back-guard')))
            .canPop,
        isFalse,
        reason: 'while the drawer is up, back must not leave the page',
      );

      await systemBack(tester);

      expect(
        find.byType(Drawer),
        findsNothing,
        reason: 'back closes the drawer instead of popping the route',
      );
      // Still inside the shell, on the same page.
      expect(find.text('page /dashboard'), findsOneWidget);
      expect(
        tester
            .widget<PopScope>(find.byKey(const Key('shell-back-guard')))
            .canPop,
        isTrue,
        reason: 'a second back must be allowed through once the drawer is gone',
      );
    });
  });

  group('both chrome variants offer the same affordances', () {
    Future<void> pumpRole(WidgetTester tester, String role) async {
      final entries = entriesFor(role);
      final user = _userFor(role);

      await pumpDesktop(
        tester,
        routerWith(
          (child) => desktopShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );
      final sidebar = listedLabels(tester);

      await pumpMobile(
        tester,
        routerWith(
          (child) => mobileShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );
      expect(
        bottomBarLabels(tester),
        [
          ...shellBottomBarEntries(entries).map((e) => e.label),
          AppStrings.more,
        ],
        reason: '$role: the bar holds the available slots plus More',
      );

      await tester.tap(moreSlot(tester));
      await tester.pumpAndSettle();
      expect(
        listedLabels(tester, within: find.byType(Drawer)),
        sidebar,
        reason: '$role: the drawer lists exactly what the sidebar lists',
      );
    }

    testWidgets('an admin sees the same six destinations on both', (
      tester,
    ) async {
      expect(entriesFor(AppRoles.admin), hasLength(6));
      await pumpRole(tester, AppRoles.admin);
    });

    testWidgets('a viewer sees the same three on both', (tester) async {
      final viewer = entriesFor(AppRoles.viewer);
      expect(viewer, hasLength(3));
      expect(
        viewer.map((e) => e.path),
        isNot(contains('/settings')),
        reason: 'a viewer has no `users.read`, so no Settings destination',
      );
      await pumpRole(tester, AppRoles.viewer);
    });

    testWidgets('a lab user gets neither gated destination', (tester) async {
      // `lab` holds no `users.read` and no `audit.read`, so both gated
      // destinations stay hidden. Reference is gated on the same flag as
      // Settings: they are the two pages inside the settings area.
      final lab = entriesFor(AppRoles.lab);
      expect(lab.map((e) => e.path), isNot(contains('/reference')));
      expect(lab.map((e) => e.path), isNot(contains('/settings')));
      expect(lab.map((e) => e.path), isNot(contains('/audit')));
      await pumpRole(tester, AppRoles.lab);
    });

    testWidgets('both offer the language toggle, theme toggle and badge', (
      tester,
    ) async {
      final entries = entriesFor(AppRoles.admin);
      final user = _userFor(AppRoles.admin);

      // Each chrome at its own window: the desktop bar is designed to sit beside
      // a 280dp sidebar, the phone bar to sit under a full-width page.
      await pumpDesktop(
        tester,
        routerWith(
          (child) => desktopShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );
      expect(find.byTooltip(AppStrings.toggleLanguage), findsOneWidget);
      expect(find.byTooltip(AppStrings.toggleTheme), findsOneWidget);
      expect(find.byKey(const Key('sync-badge')), findsOneWidget);

      await pumpMobile(
        tester,
        routerWith(
          (child) => mobileShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );
      expect(find.byTooltip(AppStrings.toggleLanguage), findsOneWidget);
      expect(find.byTooltip(AppStrings.toggleTheme), findsOneWidget);
      expect(find.byKey(const Key('sync-badge')), findsOneWidget);
    });

    testWidgets('the exports-folder button follows FileDelivery.canReveal', (
      tester,
    ) async {
      final entries = entriesFor(AppRoles.admin);
      final user = _userFor(AppRoles.admin);

      // Cannot reveal: hidden on both, because a tap could only ever fail.
      await pumpDesktop(
        tester,
        routerWith(
          (child) => desktopShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            canOpenPdfFolder: false,
            child: child,
          ),
        ),
      );
      expect(find.text(AppStrings.openPdfFolder), findsNothing);

      await pumpMobile(
        tester,
        routerWith(
          (child) => mobileShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            canOpenPdfFolder: false,
            child: child,
          ),
        ),
      );
      await tester.tap(moreSlot(tester));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.openPdfFolder), findsNothing);

      // Can reveal: offered on both, and it reaches the port rather than a
      // `getIt` lookup.
      final revealed = <String>[];
      await pumpDesktop(
        tester,
        routerWith(
          (child) => DesktopAppShell(
            user: user,
            entries: entries,
            locale: locale,
            theme: theme,
            syncStatus: badge(),
            onNavigate: (_) {},
            onLogout: () {},
            onLogoutThisDevice: () {},
            onOpenPdfFolder: () {},
            canOpenPdfFolder: const _FakeDelivery(canReveal: true).canReveal,
            child: child,
          ),
        ),
      );
      expect(find.text(AppStrings.openPdfFolder), findsOneWidget);
      await tester.tap(find.text(AppStrings.openPdfFolder));
      await tester.pumpAndSettle();

      await pumpMobile(
        tester,
        routerWith(
          (child) => MobileAppShell(
            user: user,
            entries: entries,
            locale: locale,
            theme: theme,
            syncStatus: badge(),
            onNavigate: (_) {},
            onLogout: () {},
            onLogoutThisDevice: () {},
            onOpenPdfFolder: () => revealed.add('folder'),
            canOpenPdfFolder: const _FakeDelivery(canReveal: true).canReveal,
            child: child,
          ),
        ),
      );
      await tester.tap(moreSlot(tester));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.openPdfFolder));
      await tester.pumpAndSettle();
      expect(revealed, ['folder']);
    });

    testWidgets('both sign-outs are reachable on both experiences', (
      tester,
    ) async {
      final entries = entriesFor(AppRoles.admin);
      final user = _userFor(AppRoles.admin);
      const signOutDevice = 'Sign out of this device only';
      const signOut = 'Logout';

      await pumpDesktop(
        tester,
        routerWith(
          (child) => desktopShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );
      expect(find.byTooltip(signOutDevice), findsOneWidget);
      expect(find.byTooltip(signOut), findsOneWidget);

      await pumpMobile(
        tester,
        routerWith(
          (child) => mobileShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );
      await tester.tap(moreSlot(tester));
      await tester.pumpAndSettle();
      final drawer = find.byType(Drawer);
      expect(
        find.descendant(of: drawer, matching: find.byTooltip(signOutDevice)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: drawer, matching: find.byTooltip(signOut)),
        findsOneWidget,
      );
    });

    testWidgets('the read-only role chip is desktop-only', (tester) async {
      final entries = entriesFor(AppRoles.viewer);
      // `viewer` is a read-only role, so the chip is the visible statement of
      // it. The identity card says the same thing, so the phone omits the chip
      // rather than paying 400dp of bar for a duplicate.
      final user = _userFor(AppRoles.viewer);
      expect(user.isReadOnly, isTrue);

      await pumpDesktop(
        tester,
        routerWith(
          (child) => desktopShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );
      expect(find.text(AppRoles.label(AppRoles.viewer)), findsOneWidget);

      await pumpMobile(
        tester,
        routerWith(
          (child) => mobileShell(
            user: user,
            entries: entries,
            onNavigate: (_) {},
            child: child,
          ),
        ),
      );
      expect(find.text(AppRoles.label(AppRoles.viewer)), findsNothing);
      // ... and the drawer still names the role, on the identity card.
      await tester.tap(moreSlot(tester));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.textContaining(AppRoles.viewer),
        ),
        findsOneWidget,
        reason:
            'the identity card states the role by id, so the phone still '
            'says who is signed in',
      );
    });
  });

  group('the host dispatches on the platform, not the window', () {
    AuthGate gateFor(String role) {
      final auth = _AuthMock();
      when(() => auth.state).thenReturn(AuthState.ready);
      when(() => auth.session).thenReturn(
        AppSession(
          uid: 'u1',
          email: 'hassan@example.com',
          displayName: 'Hassan Ali',
          role: role,
          status: MemberStatus.active,
        ),
      );
      return AuthGate(auth);
    }

    Widget host(AuthGate gate, Widget child) => AppShell(
      gate: gate,
      locale: locale,
      theme: theme,
      syncQueue: queue,
      syncMetadata: metadata,
      connectivity: ConnectivityService(),
      exportRoot: exportRoot,
      fileDelivery: const _FakeDelivery(canReveal: true),
      folderPicker: const UnsupportedFolderPicker(),
      child: child,
    );

    Future<void> pumpAs(
      WidgetTester tester,
      AppFormFactor factor,
      GoRouter router,
    ) async {
      FormFactor.debugSet(factor);
      await pumpOn(
        tester,
        router,
        grid: factor.isMobile ? mobileGrid : desktopGrid,
      );
    }

    testWidgets('the desktop form factor builds the sidebar', (tester) async {
      await pumpAs(
        tester,
        AppFormFactor.desktop,
        routerWith((child) => host(gateFor(AppRoles.admin), child)),
      );

      expect(find.byType(DesktopAppShell), findsOneWidget);
      expect(find.byType(MobileAppShell), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(listedLabels(tester), hasLength(shellRoutes.length));

      // Tear the shell down so the badge's periodic timer is cancelled.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the mobile form factor builds the bottom bar', (tester) async {
      await pumpAs(
        tester,
        AppFormFactor.mobile,
        routerWith((child) => host(gateFor(AppRoles.admin), child)),
      );

      expect(find.byType(MobileAppShell), findsOneWidget);
      expect(find.byType(DesktopAppShell), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(bottomBarLabels(tester), hasLength(shellBottomBarSlots + 1));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a signed-out shell renders nothing at all', (tester) async {
      final auth = _AuthMock();
      when(() => auth.state).thenReturn(AuthState.signedOut);
      when(() => auth.session).thenReturn(kEmptySession);

      await pumpAs(
        tester,
        AppFormFactor.desktop,
        routerWith((child) => host(AuthGate(auth), child)),
      );

      expect(find.byType(DesktopAppShell), findsNothing);
      expect(find.byType(MobileAppShell), findsNothing);
    });
  });
}
