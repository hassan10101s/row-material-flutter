import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/presentation/inventory/inventory_log_screen.dart';
import 'package:material_lab/features/lab/presentation/equipment/equipment_dialogs.dart';
import 'package:material_lab/features/settings/domain/settings_repository.dart';
import 'package:material_lab/features/notifications/domain/notification_item.dart';
import 'package:material_lab/features/notifications/domain/notifications_port.dart';
import 'package:material_lab/features/notifications/presentation/notification_controller.dart';
import 'package:material_lab/features/notifications/presentation/notification_bell.dart';
import 'package:material_lab/features/qc_manager/domain/routine_repository.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:material_lab/features/qc_manager/presentation/routine/routine_sheet_screen.dart';

class _Stock extends Mock implements LabLocalRepository {}

class _Settings extends Mock implements SettingsRepository {}

class _Notifications extends Mock implements NotificationsPort {}

class _Routines extends Mock implements RoutineListsRepository {}

void main() {
  setUp(() => AppText.useLanguage('en'));
  tearDown(() async {
    FormFactor.debugSet(null);
    AppText.useLanguage('ar');
    await getIt.reset();
  });

  Future<void> host(
    WidgetTester tester,
    bool mobile,
    WidgetBuilder builder,
  ) async {
    FormFactor.debugSet(mobile ? AppFormFactor.mobile : AppFormFactor.desktop);
    final size = mobile ? const Size(390, 844) : const Size(1280, 900);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: size,
        builder: (_, _) => MaterialApp(
          home: Scaffold(body: Builder(builder: builder)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final mobile in [true, false]) {
    final platform = mobile ? 'phone' : 'desktop';
    testWidgets(
      '$platform stock log uses its platform surface and closes independently',
      (tester) async {
        final stock = _Stock();
        when(
          () => stock.listInventoryLots(7, includeEmpty: true),
        ).thenAnswer((_) async => []);
        when(() => stock.itemStockLog(7)).thenAnswer((_) async => []);
        getIt.registerSingleton<LabLocalRepository>(stock);
        await host(
          tester,
          mobile,
          (context) => TextButton(
            onPressed: () => InventoryLogScreen.open(context, {
              'id': 7,
              'name': 'Acid',
              'unit': 'mL',
            }),
            child: const Text('open'),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Stock log'), findsOneWidget);
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        expect(find.byType(BackButton), mobile ? findsOneWidget : findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('open'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$platform QA number is a short interaction, not a desktop window on phones',
      (tester) async {
        final settings = _Settings();
        when(
          () => settings.getSettingValue('qa'),
        ).thenAnswer((_) async => 'QA-7');
        getIt.registerSingleton<SettingsRepository>(settings);
        await host(
          tester,
          mobile,
          (context) => TextButton(
            onPressed: () => showQaFormNoDialog(context, key: 'qa'),
            child: const Text('open'),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('QA-7'), findsOneWidget);
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        expect(
          find.byType(BottomSheet),
          mobile ? findsOneWidget : findsNothing,
        );
        if (mobile) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 320);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Cancel'));
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        verifyNever(() => settings.updateSettings(any()));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$platform checklist and long task history keep independent back navigation',
      (tester) async {
        final routines = _Routines();
        const stamp = '2026-11-02 08:00:00';
        when(() => routines.loadSheet(1)).thenAnswer(
          (_) async => const RoutineSheet(
            inspection: QcInspection(
              inspectionId: 1,
              templateId: 1,
              inspectionDate: '2026-11-02',
              createdAt: stamp,
              updatedAt: stamp,
            ),
            template: QcTemplate(
              templateId: 1,
              name: 'Daily tasks',
              createdAt: stamp,
              updatedAt: stamp,
            ),
            rows: [
              RoutineRow(
                item: QcItem(
                  itemId: 1,
                  sectionId: 1,
                  templateId: 1,
                  label: 'Check floor',
                ),
                response: QcResponse(
                  inspectionId: 1,
                  itemId: 1,
                  result: '',
                  createdAt: stamp,
                  updatedAt: stamp,
                ),
                taskLogCount: 30,
              ),
            ],
            current: true,
          ),
        );
        when(() => routines.taskLogs(1, itemId: 1)).thenAnswer(
          (_) async => [
            for (var i = 0; i < 30; i++)
              QcTaskLog(
                logId: i,
                inspectionId: 1,
                templateId: 1,
                itemId: 1,
                note: 'Completion note $i',
                loggedBy: 'tech',
                loggedByName: 'Technician',
                loggedAt: stamp,
              ),
          ],
        );
        getIt.registerSingleton<RoutineListsRepository>(routines);
        await host(
          tester,
          mobile,
          (context) => TextButton(
            onPressed: () => RoutineSheetScreen.open(context, inspectionId: 1),
            child: const Text('open'),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        await tester.tap(find.byTooltip('Done log'));
        await tester.pumpAndSettle();
        expect(find.text('Done log: Check floor'), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Completion note 29'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('Completion note 29'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Done log: Check floor'), findsNothing);
        expect(find.text('Check floor'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'phone notifications are a scrollable page and back does not mark items read',
    (tester) async {
      final port = _Notifications();
      when(() => port.recent()).thenAnswer(
        (_) async => [
          for (var i = 0; i < 30; i++)
            NotificationItem(
              id: i,
              type: NotificationType.inspection,
              refId: i,
              entryCode: '$i',
              title: 'Notice $i',
              subtitle: 'Details',
              createdAt: '2026-11-02',
              read: false,
            ),
        ],
      );
      when(() => port.unreadCount()).thenAnswer((_) async => 30);
      final controller = NotificationController(port);
      addTearDown(controller.dispose);
      await host(tester, true, (_) => NotificationBell(controller: controller));
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.ensureVisible(find.text('Notice 29'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Notice 29')).bottom, lessThan(844));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      verifyNever(() => port.markRead(any()));
      verifyNever(() => port.markAllRead());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Windows exposes no notification bell', (tester) async {
    final controller = NotificationController(_Notifications());
    addTearDown(controller.dispose);
    await host(tester, false, (_) => NotificationBell(controller: controller));
    expect(find.byIcon(Icons.notifications_none_outlined), findsNothing);
    expect(find.byType(Tooltip), findsNothing);
  });
}
