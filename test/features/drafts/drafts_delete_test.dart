import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/commands/direct_write_service.dart';
import 'package:material_lab/core/commands/drafts_store.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/drafts/presentation/drafts_screen.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';

class _Drafts extends Mock implements DraftsStore {}

class _Writes extends Mock implements DirectWriteService {}

class _Gate extends Mock implements AuthGate {}

void main() {
  testWidgets('uncertain event is removed only after explicit confirmation', (
    tester,
  ) async {
    AppText.useLanguage('en');
    final drafts = _Drafts(), writes = _Writes(), gate = _Gate();
    var removed = false;
    final entry = CommandOutboxEntry(
      id: 1,
      draftId: 'draft',
      operationId: 'op',
      organizationId: 'org',
      uid: 'owner',
      deviceId: 'device',
      commandType: 'domain.commit',
      entityId: 'draft',
      expectedVersion: 0,
      payload: const {'writes': []},
      payloadHash: 'hash',
      dependencies: const {},
      state: OutboxState.pending,
      attempts: 1,
      createdAt: '2026-11-02',
      updatedAt: '2026-11-02',
    );
    when(
      () => drafts.listOpen(limit: any(named: 'limit')),
    ).thenAnswer((_) async => []);
    when(writes.openRequests).thenAnswer((_) async => removed ? [] : [entry]);
    when(() => writes.isSending('op')).thenReturn(false);
    when(() => writes.dismissRequest(entry)).thenAnswer((_) async {
      removed = true;
    });
    when(() => gate.online).thenReturn(false);
    getIt.registerSingleton<DraftsStore>(drafts);
    getIt.registerSingleton<DirectWriteService>(writes);
    getIt.registerSingleton<AuthGate>(gate);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(800, 600),
        builder: (_, _) =>
            const MaterialApp(home: Scaffold(body: DraftsScreen())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Remove event'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    verifyNever(() => writes.dismissRequest(entry));
    await tester.tap(find.widgetWithText(AppButton, 'Remove event'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove event').last);
    await tester.pumpAndSettle();
    verify(() => writes.dismissRequest(entry)).called(1);
    expect(find.text('Event removed from list'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Remove event'), findsNothing);
    expect(find.text('Show removed events'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  tearDown(() async {
    await getIt.reset();
    AppText.useLanguage('ar');
  });
  testWidgets(
    'offline local draft can be deleted after confirmation; cancel never deletes',
    (tester) async {
      AppText.useLanguage('en');
      final drafts = _Drafts(), writes = _Writes(), gate = _Gate();
      var deleted = false;
      const now = '2026-11-02T12:00:00';
      final draft = CommandDraft(
        id: 'draft',
        organizationId: 'org',
        uid: 'owner',
        entityType: 'domainTransaction',
        operation: 'create',
        state: DraftState.localDraft,
        payload: const {
          'writes': [
            {
              'operation': 'create',
              'payload': {'name': 'Local material'},
            },
          ],
        },
        createdAt: now,
        updatedAt: now,
      );
      when(
        () => drafts.listOpen(limit: any(named: 'limit')),
      ).thenAnswer((_) async => deleted ? [] : [draft]);
      when(writes.openRequests).thenAnswer((_) async => []);
      when(() => gate.online).thenReturn(false);
      when(() => drafts.deleteUnsent('draft')).thenAnswer((_) async {
        deleted = true;
      });
      getIt.registerSingleton<DraftsStore>(drafts);
      getIt.registerSingleton<DirectWriteService>(writes);
      getIt.registerSingleton<AuthGate>(gate);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(800, 600),
          builder: (_, _) =>
              const MaterialApp(home: Scaffold(body: DraftsScreen())),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.widgetWithText(AppButton, 'Delete draft');
      expect(tester.widget<AppButton>(button).icon, isNotNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(() => drafts.deleteUnsent(any()));
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete draft').last);
      await tester.pumpAndSettle();
      verify(() => drafts.deleteUnsent('draft')).called(1);
      expect(find.text('Draft deleted'), findsOneWidget);
      expect(find.text('Create: Local material'), findsNothing);
      verify(() => writes.openRequests()).called(2);
      verifyNoMoreInteractions(writes);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    },
  );
}
