import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_sop.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_sop_detail_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_sops_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_sop_detail_screen.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_sops_screen.dart';
import 'package:material_lab/features/qc_manager/presentation/widgets/sop_pill.dart';

class _SopsMock extends Mock implements QcSopRepository {}

const _now = '2026-02-01 08:00:00';

QcSop _sop({
  int? id = 1,
  String code = 'SOP-001',
  String title = 'Calibrate the press',
  String status = SopStatus.draft,
  String expiry = '',
  bool requiresAck = true,
}) => QcSop(
  sopId: id,
  code: code,
  title: title,
  status: status,
  dept: 'Production',
  category: 'Equipment',
  criticality: QcPriority.high,
  expiryDate: expiry,
  contentText: 'Lock out, verify zero energy, then calibrate.',
  requiresReadAck: requiresAck,
  readAckMandatory: requiresAck,
  createdAt: _now,
  updatedAt: _now,
);

/// Stubs the reads so the fake honours the arguments it was called with, the way
/// SQL would: a stub that ignored `includeArchived` would make the archived
/// filtering untestable.
void _stubSops(
  _SopsMock repo, {
  List<QcSop> rows = const [],
  List<QcSopRevision> revisions = const [],
  List<QcSopRead> reads = const [],
  QcSop? missing,
}) {
  when(
    () => repo.listSops(
      dept: any(named: 'dept'),
      status: any(named: 'status'),
      includeArchived: any(named: 'includeArchived'),
    ),
  ).thenAnswer((invocation) async {
    final status = invocation.namedArguments[#status] as String;
    final dept = invocation.namedArguments[#dept] as String;
    final includeArchived = invocation.namedArguments[#includeArchived] as bool;
    var out = rows;
    if (status.isNotEmpty) out = out.where((s) => s.status == status).toList();
    if (dept.isNotEmpty) out = out.where((s) => s.dept == dept).toList();
    if (!includeArchived) {
      out = out.where((s) => s.status != SopStatus.archived).toList();
    }
    return out;
  });
  when(() => repo.getSop(any())).thenAnswer((_) async => missing);
  when(() => repo.listSopRevisions(any())).thenAnswer((_) async => revisions);
  when(() => repo.listSopReads(any())).thenAnswer((_) async => reads);
}

Widget _host(Widget child, QcSopsCubit cubit) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => BlocProvider.value(
    value: cubit,
    child: MaterialApp(home: child),
  ),
);

/// The detail screen reads both cubits: its own, and the register it was opened
/// from so a lifecycle change can refresh the list behind it.
Widget _hostDetail(
  Widget child,
  QcSopsCubit register,
  QcSopDetailCubit detail,
) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => MultiBlocProvider(
    providers: [
      BlocProvider.value(value: register),
      BlocProvider.value(value: detail),
    ],
    child: MaterialApp(home: child),
  ),
);

/// The detail screen is one long list; at the default test height its later
/// cards are never built, so the window is grown instead of scattering drags
/// through every test that wants to assert on the acknowledgements at the bottom.
void _tallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => AppText.arabic = false);
  tearDownAll(() => AppText.arabic = true);
  setUpAll(() {
    // `any()`/`captureAny` need a value of the argument's type up front.
    registerFallbackValue(_sop());
    registerFallbackValue(
      QcSopRead(sopId: 1, revNo: 1, userId: 'u0', readAt: _now),
    );
  });

  group('QcSopsScreen', () {
    late _SopsMock repo;
    late QcSopsCubit cubit;

    setUp(() {
      repo = _SopsMock();
      cubit = QcSopsCubit(repo: repo);
    });

    tearDown(() => cubit.close());

    testWidgets(
      'an empty register explains itself instead of showing a table',
      (tester) async {
        _stubSops(repo);
        await cubit.load();
        await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
        await tester.pumpAndSettle();

        expect(find.text('No procedures yet'), findsOneWidget);
        expect(find.text('Draft the first procedure'), findsOneWidget);
      },
    );

    testWidgets('each SOP shows its title, code and translated status', (
      tester,
    ) async {
      _stubSops(
        repo,
        rows: [
          _sop(),
          _sop(
            id: 2,
            code: 'SOP-002',
            title: 'Store the resin',
            status: SopStatus.published,
          ),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Calibrate the press'), findsOneWidget);
      expect(find.text('Store the resin'), findsOneWidget);
      // The pill, not a raw "Published" - and scoped to the pill, because the
      // summary strip carries a "Draft" label of its own.
      expect(find.widgetWithText(SopPill, 'Draft'), findsOneWidget);
      expect(find.widgetWithText(SopPill, 'Published'), findsOneWidget);
      expect(find.textContaining('SOP-001'), findsOneWidget);
    });

    testWidgets('the summary strip counts each lifecycle bucket', (
      tester,
    ) async {
      _stubSops(
        repo,
        rows: [
          _sop(),
          _sop(id: 2, code: 'SOP-002', status: SopStatus.pending),
          _sop(id: 3, code: 'SOP-003', status: SopStatus.published),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Total'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Awaiting'), findsOneWidget);
      expect(find.text('1'), findsWidgets);
    });

    testWidgets('a published SOP flags the outstanding acknowledgement', (
      tester,
    ) async {
      _stubSops(
        repo,
        rows: [_sop(status: SopStatus.published, requiresAck: true)],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Needs a read acknowledgement'), findsOneWidget);
    });

    testWidgets('a SOP that does not require a read says nothing', (
      tester,
    ) async {
      _stubSops(
        repo,
        rows: [_sop(status: SopStatus.published, requiresAck: false)],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Needs a read acknowledgement'), findsNothing);
    });

    testWidgets('a lapsed SOP is flagged rather than shown as current', (
      tester,
    ) async {
      _stubSops(
        repo,
        rows: [
          _sop(status: SopStatus.published, expiry: '2000-01-01T00:00:00Z'),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.textContaining('2000-01-01'), findsOneWidget);
    });

    testWidgets('a failed load surfaces the reason', (tester) async {
      _stubSops(repo, rows: [_sop()]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      // The failure has to arrive while the screen is mounted: an error emitted
      // before the first build has no listener to show it.
      when(
        () => repo.listSops(
          dept: any(named: 'dept'),
          status: any(named: 'status'),
          includeArchived: any(named: 'includeArchived'),
        ),
      ).thenThrow(StateError('table is gone'));
      await cubit.load();
      await tester.pumpAndSettle();

      expect(find.textContaining('table is gone'), findsOneWidget);
    });

    testWidgets('the filter sheet narrows by status', (tester) async {
      _stubSops(
        repo,
        rows: [
          _sop(),
          _sop(id: 2, code: 'SOP-002', status: SopStatus.published),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.text('Procedure filters'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilterChip, 'Published'));
      await tester.pumpAndSettle();

      expect(cubit.state.filters.statuses, {SopStatus.published});
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Store the resin'), findsNothing);
      expect(find.text('Calibrate the press'), findsOneWidget);
    });

    testWidgets('an over-narrow filter offers a way back', (tester) async {
      _stubSops(repo, rows: [_sop()]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      await cubit.applyFilters(const QcSopFilters(text: 'nothing'));
      await tester.pumpAndSettle();

      expect(find.text('No procedures match these filters'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Calibrate the press'), findsOneWidget);
    });

    testWidgets('tapping a SOP opens its detail on the same stack', (
      tester,
    ) async {
      _stubSops(repo, rows: [_sop()]);
      when(() => repo.getSop(1)).thenAnswer((_) async => _sop());
      await cubit.load();
      await tester.pumpWidget(_host(const QcSopsScreen(), cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Calibrate the press'));
      await tester.pumpAndSettle();

      expect(find.byType(QcSopDetailScreen), findsOneWidget);
      expect(find.text('Calibrate the press'), findsWidgets);
      expect(find.text('Submit for approval'), findsOneWidget);
    });
  });

  group('QcSopDetailScreen', () {
    late _SopsMock repo;
    late QcSopsCubit register;

    setUp(() {
      repo = _SopsMock();
      register = QcSopsCubit(repo: repo);
    });

    tearDown(() => register.close());

    Future<QcSopDetailCubit> open(
      WidgetTester tester,
      QcSop sop, {
      List<QcSopRevision> revisions = const [],
      List<QcSopRead> reads = const [],
    }) async {
      _tallWindow(tester);
      _stubSops(
        repo,
        rows: [sop],
        revisions: revisions,
        reads: reads,
        missing: sop,
      );
      await register.load();
      final detail = QcSopDetailCubit(
        repo: repo,
        sops: register,
        sopId: sop.sopId ?? 0,
      )..load();
      await tester.pumpWidget(
        _hostDetail(const QcSopDetailScreen(), register, detail),
      );
      await tester.pumpAndSettle();
      return detail;
    }

    testWidgets('shows the procedure and its metadata', (tester) async {
      await open(tester, _sop(expiry: '2099-01-01T00:00:00Z'));

      expect(
        find.text('Lock out, verify zero energy, then calibrate.'),
        findsOneWidget,
      );
      expect(find.textContaining('SOP-001'), findsOneWidget);
      expect(find.textContaining('2099-01-01'), findsOneWidget);
    });

    testWidgets('offers exactly the lifecycle moves the domain allows', (
      tester,
    ) async {
      await open(tester, _sop());

      expect(find.text('Submit for approval'), findsOneWidget);
      // Draft cannot jump straight to published.
      expect(find.text('Publish'), findsNothing);
    });

    testWidgets('an archived SOP offers no moves at all', (tester) async {
      await open(tester, _sop(status: SopStatus.archived));

      expect(find.text('No further steps from here'), findsOneWidget);
    });

    testWidgets('a published SOP hides the edit action', (tester) async {
      await open(tester, _sop(status: SopStatus.published));

      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.text('Acknowledge read'), findsOneWidget);
    });

    testWidgets('a draft offers the edit action', (tester) async {
      await open(tester, _sop());

      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.text('Acknowledge read'), findsNothing);
    });

    testWidgets('advancing a SOP asks the repository and reports the result', (
      tester,
    ) async {
      final detail = await open(tester, _sop());
      when(() => repo.updateSop(any())).thenAnswer((_) async {});

      await tester.tap(find.text('Submit for approval'));
      await tester.pumpAndSettle();

      verify(() => repo.updateSop(any())).called(1);
      expect(detail.state.error, isNull);
    });

    testWidgets('a refused advance shows the reason', (tester) async {
      await open(tester, _sop());
      when(
        () => repo.updateSop(any()),
      ).thenThrow(StateError('needs qcApprove'));

      await tester.tap(find.text('Submit for approval'));
      await tester.pumpAndSettle();

      expect(find.textContaining('needs qcApprove'), findsOneWidget);
    });

    testWidgets('lists who has read the current revision', (tester) async {
      await open(
        tester,
        _sop(status: SopStatus.published),
        revisions: [
          QcSopRevision(
            sopId: 1,
            revNo: 2,
            changeReason: 'Second issue',
            editedAt: _now,
            isPublishedRev: true,
          ),
        ],
        reads: [
          QcSopRead(
            sopId: 1,
            revNo: 2,
            userId: 'u9',
            userName: 'Nadia',
            readAt: '2026-02-01T09:30:00Z',
          ),
        ],
      );

      expect(find.text('Nadia'), findsOneWidget);
      expect(find.text('rev 2'), findsWidgets);
      expect(find.text('Second issue'), findsOneWidget);
    });

    testWidgets('an unread SOP says so instead of showing an empty list', (
      tester,
    ) async {
      await open(tester, _sop(status: SopStatus.published));

      expect(find.text('Nobody has acknowledged it yet'), findsOneWidget);
    });

    testWidgets('cutting a revision asks for a reason before writing', (
      tester,
    ) async {
      final detail = await open(tester, _sop(status: SopStatus.approved));
      when(
        () => repo.publishSopRevision(
          any(),
          changeSummary: any(named: 'changeSummary'),
          effectiveFrom: any(named: 'effectiveFrom'),
        ),
      ).thenAnswer((_) async => 3);

      await tester.ensureVisible(find.text('Cut a revision'));
      await tester.tap(find.text('Cut a revision'));
      await tester.pumpAndSettle();

      expect(find.text('New revision'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Change summary'),
        'Torque figure corrected',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      verify(
        () => repo.publishSopRevision(
          1,
          changeSummary: 'Torque figure corrected',
          effectiveFrom: '',
        ),
      ).called(1);
      expect(detail.state.error, isNull);
    });

    testWidgets('an acknowledgement is filed against the current revision', (
      tester,
    ) async {
      await open(
        tester,
        _sop(status: SopStatus.published),
        revisions: [
          QcSopRevision(
            sopId: 1,
            revNo: 5,
            changeReason: 'Fifth',
            editedAt: _now,
            isPublishedRev: true,
          ),
        ],
      );
      when(() => repo.recordSopRead(any())).thenAnswer((_) async => 1);

      await tester.tap(find.text('Acknowledge read'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'User id'), 'u9');
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pumpAndSettle();

      final captured =
          verify(() => repo.recordSopRead(captureAny())).captured.single
              as QcSopRead;
      expect(captured.revNo, 5);
      expect(captured.userId, 'u9');
      // The screen consumes the notice after showing it, so assert on what the
      // user saw rather than on a flag that is meant to be cleared.
      expect(find.text('Read acknowledgement recorded'), findsOneWidget);
    });

    testWidgets('a deleted SOP explains itself rather than rendering blank', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubSops(repo);
      await register.load();
      final detail = QcSopDetailCubit(repo: repo, sops: register, sopId: 404)
        ..load();
      await tester.pumpWidget(
        _hostDetail(const QcSopDetailScreen(), register, detail),
      );
      await tester.pumpAndSettle();

      expect(find.text('This SOP no longer exists'), findsOneWidget);
    });
  });
}
