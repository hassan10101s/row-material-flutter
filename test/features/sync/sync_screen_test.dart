import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/sync_engine.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/sync/presentation/sync/sync_screen.dart';

class _MockEngine extends Mock implements SyncEngine {}

class _MockQueue extends Mock implements SyncQueue {}

class _MockResolver extends Mock implements ConflictResolver {}

class _MockGate extends Mock implements AuthGate {}

/// Every handler on this screen used to be a bare `try { ... } finally { ... }`
/// with no `catch`. A thrown error therefore escaped as an *unhandled* async
/// exception: the busy spinner cleared, no message appeared, and the user was
/// left concluding their row was fine. On a sync screen that is the worst
/// possible failure mode - the one screen whose entire job is to tell the truth
/// about whether work reached the server.
///
/// These pin the fixed contract: a failure in any handler reaches the user as a
/// banner, and a successful load produces no banner.
void main() {
  const clean = SyncStatusSnapshot(
    online: true,
    syncing: false,
    pending: 0,
    blocked: 0,
    conflicts: 0,
  );

  late _MockEngine engine;
  late _MockQueue queue;
  late _MockResolver resolver;
  late _MockGate gate;
  late List<void Function()> cleanups;

  void stubGate({bool online = true, bool offline = false}) {
    when(() => gate.online).thenReturn(online);
    when(() => gate.organizationId).thenReturn('7');
    when(() => gate.session).thenReturn(
      AppSession(uid: 'uid-1', organizationId: '7', deviceId: 'dev-1', offline: offline),
    );
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(1280, 800),
      builder: (context, child) => const MaterialApp(
        home: Scaffold(body: SyncScreen()),
      ),
    ));
    // Drain the deferred first load (a post-frame callback) and the banner
    // animation. `pump` twice: once to run the callback, once to settle.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  setUp(() {
    cleanups = [];
    engine = _MockEngine();
    queue = _MockQueue();
    resolver = _MockResolver();
    gate = _MockGate();

    when(() => engine.status).thenAnswer((_) => const Stream<SyncStatusSnapshot>.empty());
    when(() => queue.listConflicts(limit: any(named: 'limit')))
        .thenAnswer((_) async => const <Map<String, Object?>>[]);
    when(() => queue.listQueue(limit: any(named: 'limit')))
        .thenAnswer((_) async => const <Map<String, Object?>>[]);
    when(() => queue.retryBlocked()).thenAnswer((_) async => 0);
    when(() => queue.retryRow(any(that: isA<int>()))).thenAnswer((_) async => 1);
    stubGate();

    // Registered under the concrete type the screen asks `getIt` for; an
    // `instanceName` under `Object` would not resolve.
    getIt.registerSingleton<SyncEngine>(engine);
    getIt.registerSingleton<SyncQueue>(queue);
    getIt.registerSingleton<ConflictResolver>(resolver);
    getIt.registerSingleton<AuthGate>(gate);
    cleanups.addAll([
      () => getIt.unregister<SyncEngine>(),
      () => getIt.unregister<SyncQueue>(),
      () => getIt.unregister<ConflictResolver>(),
      () => getIt.unregister<AuthGate>(),
    ]);
  });

  tearDown(() {
    for (final cleanup in cleanups) {
      cleanup();
    }
  });

  testWidgets('a failed initial load is reported to the user', (tester) async {
    when(() => engine.syncNow(reason: any(named: 'reason')))
        .thenThrow(StateError('database_closed'));

    await pump(tester);

    // The driver-specific text is flattened, but the cause survives, so the
    // user learns *what* failed rather than only that something did.
    expect(find.textContaining('database_closed'), findsOneWidget);
  });

  testWidgets('the error banner is not an unhandled async exception',
      (tester) async {
    when(() => engine.syncNow(reason: any(named: 'reason')))
        .thenThrow(StateError('boom'));

    // A throw that escaped `_guarded` would fail this test rather than render.
    await pump(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed manual sync is reported and clears the busy state',
      (tester) async {
    when(() => engine.syncNow(reason: 'screen')).thenAnswer((_) async => clean);
    await pump(tester);
    expect(find.textContaining('boom'), findsNothing);

    when(() => engine.syncNow(reason: 'manual'))
        .thenThrow(StateError('permission-denied'));
    await tester.tap(find.text('مزامنة الآن'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('permission-denied'), findsOneWidget);
    // The spinner has to stop, or the button stays permanently "working".
    final button = tester.widget<Text>(find.text('مزامنة الآن'));
    expect(button.data, 'مزامنة الآن');
  });

  testWidgets('a failed download-history is reported', (tester) async {
    when(() => engine.syncNow(reason: 'screen')).thenAnswer((_) async => clean);
    when(() => engine.syncNow(reason: any(named: 'reason'), pullOnly: true))
        .thenThrow(StateError('pull-failed'));
    await pump(tester);

    await tester.tap(find.text('تنزيل السجل'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('pull-failed'), findsOneWidget);
  });

  testWidgets('a failed retry-all is reported', (tester) async {
    const blocked = SyncStatusSnapshot(
      online: true,
      syncing: false,
      pending: 3,
      blocked: 1,
      conflicts: 0,
    );
    when(() => engine.syncNow(reason: 'screen')).thenAnswer((_) async => blocked);
    when(() => queue.retryBlocked()).thenThrow(StateError('retry-failed'));
    await pump(tester);
    expect(find.text('إعادة المحاولة'), findsOneWidget);

    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('retry-failed'), findsOneWidget);
  });

  testWidgets('a successful load shows counters and no banner', (tester) async {
    when(() => engine.syncNow(reason: any(named: 'reason')))
        .thenAnswer((_) async => const SyncStatusSnapshot(
              online: true,
              syncing: false,
              pending: 4,
              blocked: 2,
              conflicts: 1,
            ));

    await pump(tester);

    // The badge reports the most urgent state, so blocked outranks pending.
    expect(find.text('Blocked 2'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the status stream is applied without throwing', (tester) async {
    final controller = StreamController<SyncStatusSnapshot>();
    addTearDown(controller.close);
    when(() => engine.status).thenAnswer((_) => controller.stream);
    when(() => engine.syncNow(reason: any(named: 'reason')))
        .thenAnswer((_) async => clean);

    await pump(tester);

    controller.add(const SyncStatusSnapshot(
      online: true,
      syncing: true,
      pending: 9,
      blocked: 0,
      conflicts: 0,
    ));
    // Two frames: the event is delivered in a microtask, and the setState it
    // triggers schedules the rebuild for the frame after it.
    await tester.pump();
    await tester.pump();

    expect(find.text('Syncing'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
  });

  testWidgets('the header and the tiles lay out on a narrow phone',
      (tester) async {
    // 360dp is the narrowest phone this ships to. As one `Row` with a `Spacer`
    // the title plus three Arabic-labelled buttons exceeded it, and the buttons
    // were pushed off-screen behind a RenderFlex overflow - the sync button was
    // unreachable on exactly the devices least able to wait for a sync.
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    when(() => engine.syncNow(reason: any(named: 'reason')))
        .thenAnswer((_) async => clean);

    await pump(tester);

    expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    // Every action stays reachable.
    expect(find.text('مزامنة الآن'), findsOneWidget);
    expect(find.text('تنزيل السجل'), findsOneWidget);
    expect(find.text('الحالة'), findsOneWidget);
    expect(find.text('في الانتظار'), findsOneWidget);
  });

  testWidgets('the tiles stack on a narrow phone instead of overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    when(() => engine.syncNow(reason: any(named: 'reason'))).thenAnswer(
      (_) async => const SyncStatusSnapshot(
        online: true,
        syncing: false,
        pending: 1234,
        blocked: 5678,
        conflicts: 9012,
      ),
    );

    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('1234'), findsOneWidget);
    expect(find.text('5678'), findsOneWidget);
    expect(find.text('9012'), findsOneWidget);
  });
}
