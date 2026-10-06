import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_filters.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_kpis.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_report_repository.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_report_row.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_ncr_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_ncr_detail_screen.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_ncr_list_screen.dart';

class _RepoMock extends Mock implements QcNcReportRepository {}

NcrReportRow _row(
  int id, {
  String status = 'Open',
  String severity = 'Major',
  String dueDate = '',
  String description = '',
}) => NcrReportRow(
  findingId: id,
  inspectionId: 1,
  inspectionRefId: 'INS-1',
  code: 'NC-$id',
  severity: severity,
  description: description.isEmpty ? 'defect $id' : description,
  status: status,
  lotNo: 'LOT-$id',
  createdAt: '2026-01-01 09:00:00',
  dueDate: dueDate,
);

void _stub(_RepoMock repo, {List<NcrReportRow> rows = const []}) {
  when(() => repo.kpis(any())).thenAnswer((_) async => const NcrKpis(total: 0));
  when(
    () => repo.list(
      any(),
      limit: any(named: 'limit'),
      offset: any(named: 'offset'),
      orderBy: any(named: 'orderBy'),
      orderDir: any(named: 'orderDir'),
    ),
  ).thenAnswer((_) async => rows);
  when(() => repo.count(any())).thenAnswer((_) async => rows.length);
  when(() => repo.detail(any())).thenAnswer((_) async => null);
  when(() => repo.agingBuckets(any())).thenAnswer((_) async => const []);
  when(
    () => repo.topDefects(any(), limit: any(named: 'limit')),
  ).thenAnswer((_) async => const []);
  when(
    () => repo.repeatByRef(any(), limit: any(named: 'limit')),
  ).thenAnswer((_) async => const []);
  when(() => repo.filterOptions()).thenAnswer(
    (_) async => const NcrFilterOptions(
      statuses: ['Open', 'Closed'],
      severities: ['Critical', 'Minor'],
      capaStatuses: ['Open'],
    ),
  );
}

Widget _host(Widget child, QcNcrCubit cubit) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => BlocProvider.value(
    value: cubit,
    child: MaterialApp(home: child),
  ),
);

/// Scrolls the frontmost scrollable until [target] is on screen.
///
/// Both screens sit inside a page scroll while the drawer adds its own, so
/// `scrollUntilVisible` needs to be told which one to drive - left to itself it
/// throws "Too many elements" instead of picking.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    250,
    scrollable: find.byType(Scrollable).last,
    maxScrolls: 40,
  );
  await tester.pumpAndSettle();
}

void main() {
  // mocktail needs a concrete stand-in for any non-nullable custom argument
  // before `any()` will match it.
  setUpAll(() => registerFallbackValue(const NcrFilters()));

  // `AppText.arabic` is a mutable global that defaults to true, so every
  // `AppText.t(...)` in these widgets resolves to Arabic. Pin it to English so
  // assertions can name the visible strings directly, then put it back so this
  // file cannot leak a language preference into whatever runs next.
  setUp(() => AppText.arabic = false);
  tearDownAll(() => AppText.arabic = true);

  group('QcNcrListScreen', () {
    late _RepoMock repo;
    late QcNcrCubit cubit;

    setUp(() {
      repo = _RepoMock();
      cubit = QcNcrCubit(repo, pageSize: 10);
    });

    tearDown(() => cubit.close());

    testWidgets('renders a row per finding with its pills', (tester) async {
      _stub(
        repo,
        rows: [
          _row(1),
          _row(2, status: 'Closed', severity: 'Critical'),
        ],
      );
      await tester.pumpWidget(_host(QcNcrListScreen(cubit: cubit), cubit));
      await cubit.load();
      await tester.pumpAndSettle();

      expect(find.text('NC-1'), findsOneWidget);
      expect(find.text('NC-2'), findsOneWidget);
      // Severity and status are rendered as pills, not as raw code strings.
      expect(find.text('Critical'), findsOneWidget);
      expect(find.text('Closed'), findsOneWidget);
      expect(find.text('Major'), findsOneWidget);
    });

    testWidgets(
      'an empty result explains itself instead of showing a bare table',
      (tester) async {
        _stub(repo);
        await tester.pumpWidget(_host(QcNcrListScreen(cubit: cubit), cubit));
        await cubit.load();
        await tester.pumpAndSettle();

        expect(find.text('No non-conformances match'), findsOneWidget);
        expect(find.text('No results'), findsOneWidget);
      },
    );

    testWidgets('a failed load offers a retry instead of a blank screen', (
      tester,
    ) async {
      _stub(repo);
      when(() => repo.kpis(any())).thenThrow(Exception('boom'));
      await tester.pumpWidget(_host(QcNcrListScreen(cubit: cubit), cubit));
      await cubit.load();
      await tester.pumpAndSettle();

      expect(find.text('Report unavailable'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    });

    testWidgets('the filter badge only lights up once something is set', (
      tester,
    ) async {
      _stub(repo, rows: [_row(1)]);
      await tester.pumpWidget(_host(QcNcrListScreen(cubit: cubit), cubit));
      await cubit.load();
      await tester.pumpAndSettle();

      Badge badge() => tester.widget<Badge>(find.byType(Badge).first);
      expect(badge().isLabelVisible, isFalse);

      cubit.toggleFilter('status', 'Open');
      await tester.pumpAndSettle();

      expect(badge().isLabelVisible, isTrue);
      expect(find.text('Open'), findsWidgets);
    });

    testWidgets('a tapped row hands the finding id to the caller', (
      tester,
    ) async {
      _stub(repo, rows: [_row(7)]);
      int? tapped;
      await tester.pumpWidget(
        _host(
          QcNcrListScreen(cubit: cubit, onOpenFinding: (id) => tapped = id),
          cubit,
        ),
      );
      await cubit.load();
      await tester.pumpAndSettle();

      await tester.tap(find.text('NC-7'));
      await tester.pumpAndSettle();

      expect(tapped, 7);
    });

    testWidgets('an overdue date is called out, a future one is not', (
      tester,
    ) async {
      _stub(
        repo,
        rows: [
          _row(1, dueDate: '2000-01-01'),
          _row(2, dueDate: '2999-01-01'),
        ],
      );
      await tester.pumpWidget(_host(QcNcrListScreen(cubit: cubit), cubit));
      await cubit.load();
      await tester.pumpAndSettle();

      final overdue = tester.widget<Text>(find.text('2000-01-01'));
      final future = tester.widget<Text>(find.text('2999-01-01'));
      expect(overdue.style?.color, isNotNull);
      expect(future.style?.color, isNull);
    });

    testWidgets('the drawer offers the facets the repo reported', (
      tester,
    ) async {
      _stub(repo);
      await tester.pumpWidget(_host(QcNcrListScreen(cubit: cubit), cubit));
      // The drawer renders whatever `loadOptions` last fetched; with no facets
      // loaded it is legitimately empty, so a missing option would prove
      // nothing about the picker.
      await cubit.loadOptions();
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();

      expect(find.text('Filter results'), findsOneWidget);
      // CAPA status sits below the fold in a phone-sized sheet, so scroll to it
      // rather than asserting only on whatever happens to be visible.
      await _scrollTo(tester, find.text('CAPA status'));
      expect(find.text('CAPA status'), findsOneWidget);
      // Values outside the reported facets are never offered.
      expect(find.text('Rejected'), findsNothing);
    });
  });

  group('QcNcrDetailScreen', () {
    late _RepoMock repo;
    late QcNcrCubit cubit;

    setUp(() {
      repo = _RepoMock();
      cubit = QcNcrCubit(repo);
    });

    tearDown(() => cubit.close());

    testWidgets('shows the finding with its inspection context', (
      tester,
    ) async {
      // _stub first: it installs a catch-all detail(any()) that returns null,
      // so a test-specific stub placed before it would be silently overwritten
      // and the screen would render its "nothing selected" state.
      _stub(repo);
      when(() => repo.detail(5)).thenAnswer(
        (_) async => NcrReportRow(
          findingId: 5,
          inspectionId: 1,
          inspectionRefId: 'INS-9',
          code: 'NC-5',
          severity: 'Critical',
          description: 'cracked flange',
          status: 'InProgress',
          lotNo: 'LOT-A',
          dept: 'Welding',
          inspectorName: 'Hassan',
          createdAt: '2026-01-01 09:00:00',
          assignedAt: '2026-01-02 09:00:00',
          assignedToName: 'Ali',
        ),
      );

      await tester.pumpWidget(
        _host(QcNcrDetailScreen(cubit: cubit, findingId: 5), cubit),
      );
      await tester.pumpAndSettle();

      expect(find.text('NC-5'), findsWidgets);
      expect(find.text('cracked flange'), findsWidgets);
      expect(find.text('LOT-A'), findsOneWidget);
      expect(find.text('Welding'), findsOneWidget);
      // The timeline is built from the stamps that exist, in order.
      await _scrollTo(tester, find.text('Raised'));
      expect(find.text('Raised'), findsOneWidget);
      expect(find.text('Assigned'), findsOneWidget);
      expect(find.text('Closed'), findsNothing);
    });

    testWidgets('a finding with no CAPA hides the CAPA section', (
      tester,
    ) async {
      _stub(repo);
      when(() => repo.detail(6)).thenAnswer((_) async => _row(6));

      await tester.pumpWidget(
        _host(QcNcrDetailScreen(cubit: cubit, findingId: 6), cubit),
      );
      await tester.pumpAndSettle();

      expect(find.text('Corrective action'), findsNothing);
    });

    testWidgets('a linked CAPA shows its own overdue state', (tester) async {
      _stub(repo);
      when(() => repo.detail(8)).thenAnswer(
        (_) async => NcrReportRow(
          findingId: 8,
          inspectionId: 1,
          code: 'NC-8',
          severity: 'Major',
          description: 'weld undercut',
          status: 'Open',
          createdAt: '2026-01-01 09:00:00',
          capaId: 3,
          capaNo: 'CAPA-3',
          capaStatus: 'Open',
          capaDueAt: '2000-01-01 00:00:00',
        ),
      );

      await tester.pumpWidget(
        _host(QcNcrDetailScreen(cubit: cubit, findingId: 8), cubit),
      );
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('Corrective action'));
      expect(find.text('Corrective action'), findsOneWidget);
      expect(find.text('CAPA-3'), findsOneWidget);
      await _scrollTo(tester, find.text('Not established'));
      expect(find.text('Not established'), findsOneWidget);
    });

    testWidgets('a detail failure says so rather than showing an empty page', (
      tester,
    ) async {
      _stub(repo);
      when(() => repo.detail(9)).thenThrow(Exception('gone'));

      await tester.pumpWidget(
        _host(QcNcrDetailScreen(cubit: cubit, findingId: 9), cubit),
      );
      await tester.pumpAndSettle();

      expect(find.text('Finding unavailable'), findsOneWidget);
    });
  });
}

/// Sentinel that must never appear; keeps the empty-state assertion honest.
class AppEmptyStateProbe extends StatelessWidget {
  const AppEmptyStateProbe({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
