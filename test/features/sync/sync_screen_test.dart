import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/commands/direct_write_service.dart';
import 'package:material_lab/core/commands/drafts_store.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/drafts/presentation/drafts_screen.dart';

class _Drafts extends Mock implements DraftsStore {}

class _Writes extends Mock implements DirectWriteService {}

class _Gate extends Mock implements AuthGate {}

void main() {
  late _Drafts drafts;
  late _Writes writes;
  setUp(() {
    drafts = _Drafts();
    writes = _Writes();
    final gate = _Gate();
    when(() => gate.online).thenReturn(true);
    when(() => drafts.listOpen(limit: 100000)).thenAnswer((_) async => []);
    when(writes.openRequests).thenAnswer((_) async => []);
    getIt.registerSingleton<DraftsStore>(drafts);
    getIt.registerSingleton<DirectWriteService>(writes);
    getIt.registerSingleton<AuthGate>(gate);
  });
  tearDown(() async {
    await getIt.reset();
  });
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 800),
        builder: (_, child) =>
            const MaterialApp(home: Scaffold(body: DraftsScreen())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opening drafts only reads local records and never sends', (
    tester,
  ) async {
    await pump(tester);
    verify(() => drafts.listOpen(limit: 100000)).called(1);
    verify(writes.openRequests).called(1);
    verifyNoMoreInteractions(writes);
    expect(tester.takeException(), isNull);
  });
  testWidgets('load failure is recoverable and hides driver details', (
    tester,
  ) async {
    when(
      () => drafts.listOpen(limit: 100000),
    ).thenThrow(StateError('private SQL detail'));
    await pump(tester);
    expect(find.textContaining('تعذر تحميل المسودات'), findsOneWidget);
    expect(find.textContaining('private SQL'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
