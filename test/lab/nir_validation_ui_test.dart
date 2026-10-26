import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/core/responsive/layout_spec.dart';
import 'package:material_lab/core/responsive/responsive_scope.dart';
import 'package:material_lab/core/theme/app_theme.dart';
import 'package:material_lab/design_system/tokens/app_colors.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/design_system/widgets/app_data_table.dart';
import 'package:material_lab/design_system/widgets/app_paginated_table.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/lab/domain/nir_validation_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/nir_validation_cubit.dart';
import 'package:material_lab/features/lab/presentation/nir_validation/nir_item_details_window.dart';
import 'package:material_lab/features/lab/presentation/nir_validation/nir_validation_tab.dart';

class _Gate extends Mock implements AuthGate {}

NirParameterStats _stats({
  NirScope scope = NirScope.rawMaterial,
  int count = 6,
  String name = 'قمح محلي',
  String parameter = 'البروتين',
  bool noisy = false,
}) => NirParameterStats(
  scope: scope,
  entityId: 1,
  entityName: name,
  parameter: parameter,
  unit: '%',
  points: [
    for (var i = 0; i < count; i++)
      NirValidationPoint(
        inspectionId: i + 1,
        entryCode: 'TEST-${100 + i}',
        inspectionDate: '2026-10-24',
        sampleName: 'عينة مرجعية ${i + 1}',
        nirValue: i + 10.0,
        labValue: noisy
            ? [12.0, 19.0, 8.0, 25.0, 9.0, 15.0][i % 6]
            : (i + 10.0) * 1.04 - .3,
      ),
  ],
);

class _Repository extends Fake implements NirValidationRepository {
  List<NirParameterStats> rows = [
    _stats(),
    _stats(parameter: 'الرطوبة', noisy: true),
    _stats(
      scope: NirScope.product,
      name: 'علف نامي',
      parameter: 'الدهون',
      count: 2,
    ),
  ];
  final resets = <(String, NirScope?, int?, String, String)>[];
  @override
  Future<NirValidationSettings?> getSettings() async => null;
  @override
  Future<List<NirValidationSettings>> listResetHistory({
    int limit = 50,
  }) async => [];
  @override
  Future<NirValidationReport> compute({String? startDate}) async =>
      NirValidationReport(settings: null, stats: rows);
  @override
  Future<NirValidationSettings> resetValidation(
    String startDate, {
    String note = '',
    NirScope? scope,
    int? entityId,
    String entityName = '',
    String parameter = '',
  }) async {
    resets.add((startDate, scope, entityId, entityName, parameter));
    return NirValidationSettings(id: 1, startDate: startDate);
  }
}

final _boundaryKey = GlobalKey();
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool mobile = false,
  Brightness brightness = Brightness.light,
  Size? size,
  double scale = 1,
}) async {
  FormFactor.debugSet(mobile ? AppFormFactor.mobile : AppFormFactor.desktop);
  AppColors.brightness = brightness;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize =
      size ?? (mobile ? const Size(400, 900) : const Size(1200, 900));
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    FormFactor.debugSet(null);
    AppColors.brightness = Brightness.light;
  });
  await tester.pumpWidget(
    ResponsiveScope(
      spec: mobile ? LayoutSpec.mobile : LayoutSpec.desktop,
      child: ScreenUtilInit(
        designSize: mobile ? const Size(400, 860) : const Size(1280, 720),
        builder: (_, _) => MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark()
              : AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: RepaintBoundary(key: _boundaryKey, child: child!),
            ),
          ),
          home: Scaffold(
            body: Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('NIR_PREVIEWS')) return;
  await tester.runAsync(() async {
    final boundary =
        _boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final picture = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    await Directory('.dart_tool/nir_previews').create(recursive: true);
    await File(
      '.dart_tool/nir_previews/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}

Future<NirValidationCubit> _page(
  WidgetTester tester,
  _Repository repo, {
  bool mobile = false,
  Brightness brightness = Brightness.light,
  Size? size,
  double scale = 1,
}) async {
  final cubit = NirValidationCubit(repo: repo);
  await cubit.load();
  addTearDown(cubit.close);
  await _pump(
    tester,
    BlocProvider.value(value: cubit, child: const NirValidationTab()),
    mobile: mobile,
    brightness: brightness,
    size: size,
    scale: scale,
  );
  return cubit;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Cairo',
    )..addFont(rootBundle.load('assets/fonts/Cairo-Variable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  tearDown(() async {
    if (getIt.isRegistered<AuthGate>()) await getIt.unregister<AuthGate>();
  });

  testWidgets(
    'desktop aligns metrics and filters reliability without writing records',
    (tester) async {
      final repo = _Repository();
      await _page(tester, repo);
      expect(find.byType(AppDataTable), findsWidgets);
      expect(find.text('3 تحليل مطابق للفلاتر'), findsOneWidget);
      await _capture(tester, 'desktop_light');
      await tester.tap(find.text('يحتاج مراجعة').first);
      await tester.pumpAndSettle();
      expect(find.text('1 تحليل مطابق للفلاتر'), findsOneWidget);
      expect(find.text('الرطوبة (%)'), findsOneWidget);
      expect(find.text('البروتين (%)'), findsNothing);
      expect(repo.resets, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone cards keep search focus and clear unmatched filters', (
    tester,
  ) async {
    final cubit = await _page(tester, _Repository(), mobile: true);
    expect(find.byType(AppDataTable), findsNothing);
    await _capture(tester, 'mobile_light');
    await tester.enterText(find.byType(TextField), 'غير موجود');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(cubit.state.query, 'غير موجود');
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    expect(find.text('لا توجد نتائج بهذه الفلاتر'), findsOneWidget);
    await tester.ensureVisible(find.text('مسح الفلاتر'));
    await tester.tap(find.text('مسح الفلاتر'));
    await tester.pumpAndSettle();
    expect(cubit.state.query, isEmpty);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing search cancels an earlier pending query', (
    tester,
  ) async {
    final cubit = await _page(tester, _Repository());
    await tester.enterText(find.byType(TextField), 'قمح');
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump(const Duration(milliseconds: 500));
    expect(cubit.state.query, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'phone' : 'desktop'} preview switches method without saving',
      (tester) async {
        final stats = _stats();
        await _pump(
          tester,
          Builder(
            builder: (context) => AppButton(
              label: 'افتح',
              onPressed: () => showNirItemDetails(context, stats),
            ),
          ),
          mobile: mobile,
        );
        await tester.tap(find.text('افتح'));
        await tester.pumpAndSettle();
        expect(find.text('معاينة التصحيح المقترح'), findsOneWidget);
        expect(find.text('بدء فترة جديدة لهذا التحليل'), findsNothing);
        await _capture(tester, mobile ? 'mobile_details' : 'desktop_details');
        final slopeOnly = find.byWidgetPredicate(
          (w) =>
              w is ChoiceChip &&
              (w.label as Text).data!.startsWith('الميل فقط'),
        );
        await tester.ensureVisible(slopeOnly);
        await tester.tap(slopeOnly);
        await tester.pumpAndSettle();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          'Lab = ${stats.slopeOnly.toStringAsFixed(4)} × NIR',
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('إغلاق'));
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('reset confirms only the selected analysis', (tester) async {
    final gate = _Gate();
    when(() => gate.canWrite(Permission.labResultsUpdate)).thenReturn(true);
    getIt.registerSingleton<AuthGate>(gate);
    final repo = _Repository();
    await _page(tester, repo);
    Future<void> openReset() async {
      await tester.tap(find.text('عرض التحليل').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('بدء فترة جديدة لهذا التحليل'));
      await tester.pumpAndSettle();
    }

    await openReset();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();
    expect(repo.resets, isEmpty);
    await openReset();
    await tester.tap(find.text('تأكيد بدء الفترة'));
    await tester.pumpAndSettle();
    expect(repo.resets, hasLength(1));
    final reset = repo.resets.single;
    expect(reset.$2, NirScope.rawMaterial);
    expect(reset.$3, 1);
    expect(reset.$4, 'قمح محلي');
    expect(reset.$5, 'البروتين');
    expect(tester.takeException(), isNull);
  });

  testWidgets('large mobile point sets progressively reveal all readings', (
    tester,
  ) async {
    final stats = _stats(count: 25);
    await _pump(
      tester,
      SingleChildScrollView(
        child: NirPointsTable(points: stats.points, unit: '%'),
      ),
      mobile: true,
    );
    expect(find.text('TEST-124'), findsNothing);
    final more = find.text('عرض قراءات أكثر (5 متبقية)');
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('TEST-124'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow dark phone supports large text without overflow', (
    tester,
  ) async {
    await _page(
      tester,
      _Repository(),
      mobile: true,
      brightness: Brightness.dark,
      size: const Size(360, 800),
      scale: 1.4,
    );
    await _capture(tester, 'mobile_dark_large_text');
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final open = find.text('عرض التحليل والتوصية').first;
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.text('معاينة التصحيح المقترح'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('إغلاق'));
    await tester.pumpAndSettle();
  });

  testWidgets('desktop points use the shared paginated table', (tester) async {
    await _pump(
      tester,
      NirPointsTable(points: _stats(count: 25).points, unit: '%'),
    );
    expect(find.byType(AppPaginatedTable), findsOneWidget);
    expect(find.text('TEST-124'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow desktop retains its table experience', (tester) async {
    await _page(tester, _Repository(), size: const Size(640, 800));
    expect(find.byType(AppDataTable), findsWidgets);
    expect(find.text('عرض التحليل والتوصية'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
