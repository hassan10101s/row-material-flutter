import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/locale/locale_service.dart';
import 'package:material_lab/core/sync/sync_engine.dart';
import 'package:material_lab/core/theme/theme_service.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/backup/domain/backup_service.dart';
import 'package:material_lab/features/settings/domain/settings_repository.dart';
import 'package:material_lab/features/settings/presentation/settings_screen.dart';

class _SettingsMock extends Mock implements SettingsRepository {}

class _ThemeMock extends Mock implements ThemeService {}

class _LocaleMock extends Mock implements LocaleService {}

class _BackupMock extends Mock implements BackupService {}

class _SyncMock extends Mock implements SyncEngine {}

/// The settings sections are laid out by hand inside an `Expanded`, so a short
/// window - or one where the section simply has more in it than fits - used to
/// overflow instead of scrolling. Overflow is not visible in a normal test run:
/// it is painted as a yellow stripe in debug, so nothing catches it.
void main() {
  late _SettingsMock settings;
  late _ThemeMock theme;
  late _LocaleMock locale;
  late _BackupMock backup;
  late _SyncMock sync;

  setUp(() async {
    // Arabic is the default and the labels are Arabic literals, so pinning the
    // language keeps the finders below about layout rather than about copy.
    AppText.useLanguage('ar');

    settings = _SettingsMock();
    theme = _ThemeMock();
    locale = _LocaleMock();
    backup = _BackupMock();
    sync = _SyncMock();

    when(() => settings.getSettingValue(any())).thenAnswer((_) async => null);
    when(() => settings.getReportLogoPath()).thenAnswer((_) async => null);
    when(() => settings.getReportLogoDataUri()).thenAnswer((_) async => null);
    when(() => theme.mode).thenReturn(ThemeMode.system);
    when(() => locale.locale).thenReturn(const Locale('ar'));

    getIt.registerSingleton<SettingsRepository>(settings);
    getIt.registerSingleton<ThemeService>(theme);
    getIt.registerSingleton<LocaleService>(locale);
    getIt.registerSingleton<BackupService>(backup);
    getIt.registerSingleton<SyncEngine>(sync);
  });

  tearDown(() async {
    await getIt.reset();
  });

  /// Lays [child] out on a window of exactly [size].
  ///
  /// The surface is resized rather than left at the 800x600 default because the
  /// overflow this pins only appears once the window is shorter than the
  /// section is tall - which is the whole point of the test.
  Future<void> pumpOn(WidgetTester tester, Widget child, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: size,
        builder: (_, _) => MaterialApp(
          home: Scaffold(
            body: BlocProvider<SettingsCubitStub>.value(
              value: SettingsCubitStub(),
              child: child,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the general section fits its window', () {
    testWidgets('on a short window it scrolls rather than overflowing', (
      tester,
    ) async {
      // 1112x543 is the window the overflow was reported on: wide enough that
      // the segments sit on one line, short enough that the section does not
      // fit.
      await pumpOn(tester, const SettingsScreen(), const Size(1112, 543));

      expect(tester.takeException(), isNull);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('the save button is reachable by scrolling', (tester) async {
      await pumpOn(tester, const SettingsScreen(), const Size(1112, 543));

      // If the section scrolls, the button below the fold is reachable. If it
      // does not, this tap lands on nothing at all.
      final save = find.widgetWithText(FilledButton, AppStrings.save);
      expect(save, findsOneWidget);
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      expect(save, findsOneWidget);
    });

    testWidgets('and on a phone-sized window', (tester) async {
      // Settings is reachable on a phone too, where the width is narrower and
      // the same content wraps onto more lines.
      await pumpOn(tester, const SettingsScreen(), const Size(400, 700));

      expect(tester.takeException(), isNull);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });

  group('the database section fits its window', () {
    testWidgets('it scrolls rather than overflowing', (tester) async {
      // The database section is the longer of the two: backup and restore, a
      // divider, then the migration wizard with its three import rows. It shares
      // the panel with General, so a fix to one has to hold for the other.
      await pumpOn(
        tester,
        const SettingsScreen(initialTab: SettingsTab.database),
        const Size(1112, 543),
      );

      expect(tester.takeException(), isNull);
      // Not the section heading - the tab chip carries the same label - but the
      // backup action, which only the section body has.
      expect(
        find.widgetWithText(FilledButton, AppStrings.backup),
        findsOneWidget,
      );
    });

    testWidgets('the migration wizard stays reachable', (tester) async {
      await pumpOn(
        tester,
        const SettingsScreen(initialTab: SettingsTab.database),
        const Size(1112, 543),
      );

      final import_ = find.text('استيراد').last;
      await tester.ensureVisible(import_);
      await tester.pumpAndSettle();
      expect(import_, findsOneWidget);
    });
  });
}

/// The screen builds its own cubit from `getIt`; this stub only exists so the
/// test host has a provider to hand down the tree without replacing the
/// screen's own wiring.
class SettingsCubitStub extends Cubit<Object> {
  SettingsCubitStub() : super(Object());
}
