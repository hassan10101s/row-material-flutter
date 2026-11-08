import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/connection/presentation/connection_badge.dart';
import 'package:material_lab/features/connection/presentation/connection_status_controller.dart';

/// Plan §14-P8.1: the badge has to tell the truth about the server-confirmed
/// state at a glance - connection, work waiting for the server, and the last
/// exchange. Rendered from a plain value, so no DI or database is involved.
void main() {
  Future<void> pumpBadge(
    WidgetTester tester,
    ConnectionStatus status, {
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 800),
        builder: (context, child) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: ConnectionBadge(status: status, onTap: onTap),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('offline shows the cloud-off icon and no count', (tester) async {
    await pumpBadge(tester, const ConnectionStatus(online: false));
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(find.byKey(ConnectionBadge.pendingKey), findsNothing);
    expect(find.byKey(ConnectionBadge.blockedKey), findsNothing);
  });

  testWidgets('online and idle is the success state', (tester) async {
    await pumpBadge(tester, const ConnectionStatus(online: true));
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
  });

  testWidgets('an empty outbox does not show success after a pull failure', (
    tester,
  ) async {
    await pumpBadge(
      tester,
      const ConnectionStatus(online: true, hasError: true),
    );
    expect(find.byIcon(Icons.sync_problem_outlined), findsOneWidget);
    expect(find.byIcon(Icons.cloud_done_outlined), findsNothing);
  });

  testWidgets('remaining download pages show a sync icon', (tester) async {
    await pumpBadge(
      tester,
      const ConnectionStatus(online: true, pullIncomplete: true),
    );
    expect(find.byIcon(Icons.cloud_sync_outlined), findsOneWidget);
    expect(find.byIcon(Icons.cloud_done_outlined), findsNothing);
  });

  testWidgets('legacy queue counts never appear on the connection indicator', (
    tester,
  ) async {
    await pumpBadge(tester, const ConnectionStatus(online: true));
    expect(find.text('99+'), findsNothing);
    expect(find.byKey(ConnectionBadge.pendingKey), findsNothing);
    expect(find.byKey(ConnectionBadge.blockedKey), findsNothing);
  });

  testWidgets('never synced reads as such instead of an empty date', (
    tester,
  ) async {
    AppText.useLanguage('en');
    addTearDown(() => AppText.useLanguage('ar'));
    await pumpBadge(tester, const ConnectionStatus(online: true));
    final badge = tester.widget<ConnectionBadge>(find.byType(ConnectionBadge));
    expect(badge.tooltipMessage, contains('Not updated yet'));
  });

  testWidgets('tapping the badge opens the sync screen', (tester) async {
    var taps = 0;
    await pumpBadge(
      tester,
      const ConnectionStatus(online: true),
      onTap: () => taps++,
    );
    await tester.tap(find.byType(ConnectionBadge));
    expect(taps, 1);
  });
}
