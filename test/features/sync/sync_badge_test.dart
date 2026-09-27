import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/sync/presentation/sync_badge.dart';
import 'package:material_lab/features/sync/presentation/sync_status_controller.dart';

/// Plan §14-P8.1: the badge has to tell the truth about the offline-first
/// state at a glance - connection, work waiting for the server, and the last
/// exchange. Rendered from a plain value, so no DI or database is involved.
void main() {
  Future<void> pumpBadge(WidgetTester tester, SyncBadgeStatus status, {VoidCallback? onTap}) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(1280, 800),
      builder: (context, child) => MaterialApp(
        home: Scaffold(body: Center(child: SyncBadge(status: status, onTap: onTap))),
      ),
    ));
  }

  testWidgets('offline shows the cloud-off icon and no count', (tester) async {
    await pumpBadge(tester, const SyncBadgeStatus(online: false, pending: 0));
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(find.byKey(SyncBadge.pendingKey), findsNothing);
    expect(find.byKey(SyncBadge.blockedKey), findsNothing);
  });

  testWidgets('online and idle is the success state', (tester) async {
    await pumpBadge(tester, const SyncBadgeStatus(online: true));
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
  });

  testWidgets('pending changes are counted', (tester) async {
    await pumpBadge(tester, const SyncBadgeStatus(online: true, pending: 3));
    expect(find.byIcon(Icons.cloud_sync_outlined), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    final bubble = tester.widget<Container>(find.byKey(SyncBadge.pendingKey));
    expect((bubble.decoration as BoxDecoration).color, isNotNull);
  });

  testWidgets('blocked rows are shown apart from the pending ones', (tester) async {
    await pumpBadge(tester, const SyncBadgeStatus(online: true, pending: 2, blocked: 1));
    expect(find.byIcon(Icons.cloud_queue_outlined), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('a huge queue is capped in the bubble', (tester) async {
    await pumpBadge(tester, const SyncBadgeStatus(online: true, pending: 1200));
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('the tooltip states connection, counters and last sync',
      (tester) async {
    AppText.useLanguage('en');
    addTearDown(() => AppText.useLanguage('ar'));
    final when = DateTime(2026, 9, 20, 14, 5);
    const status = SyncBadgeStatus(online: false, pending: 4, blocked: 2, lastSync: null);
    await pumpBadge(tester, SyncBadgeStatus(
      online: status.online,
      pending: status.pending,
      blocked: status.blocked,
      lastSync: when,
    ));

    final badge = tester.widget<SyncBadge>(find.byType(SyncBadge));
    expect(badge.tooltipMessage, contains('Offline'));
    expect(badge.tooltipMessage, contains('pending: 4'));
    expect(badge.tooltipMessage, contains('blocked: 2'));
    expect(badge.tooltipMessage, contains('2026-09-20 14:05'));
  });

  testWidgets('never synced reads as such instead of an empty date',
      (tester) async {
    AppText.useLanguage('en');
    addTearDown(() => AppText.useLanguage('ar'));
    await pumpBadge(tester, const SyncBadgeStatus(online: true));
    final badge = tester.widget<SyncBadge>(find.byType(SyncBadge));
    expect(badge.tooltipMessage, contains('never'));
  });

  testWidgets('tapping the badge opens the sync screen', (tester) async {
    var taps = 0;
    await pumpBadge(tester, const SyncBadgeStatus(online: true, pending: 1), onTap: () => taps++);
    await tester.tap(find.byType(SyncBadge));
    expect(taps, 1);
  });

  testWidgets('the state label mirrors the connection', (tester) async {
    AppText.useLanguage('en');
    addTearDown(() => AppText.useLanguage('ar'));
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(1280, 800),
      builder: (context, child) => const MaterialApp(
        home: Scaffold(body: SyncStateLabel(online: false)),
      ),
    ));
    expect(find.text('Offline'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
  });
}
