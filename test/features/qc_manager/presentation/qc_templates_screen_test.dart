import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/design_system/tokens/app_colors.dart';
import 'package:material_lab/design_system/widgets/app_summary_card.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_templates_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_template_editor_screen.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_templates_screen.dart';
import 'package:material_lab/features/qc_manager/presentation/widgets/qc_pill.dart';

class _TemplatesMock extends Mock implements QcTemplateRepository {}

const _now = '2026-02-01 08:00:00';

QcTemplate _template({
  int? id = 1,
  String code = 'CHK-001',
  String name = 'Incoming inspection',
  String type = QcTemplateType.incoming,
  String dept = 'Quality',
  bool published = false,
  bool archived = false,
  String expiryDate = '',
  bool requiresApproval = false,
}) => QcTemplate(
  templateId: id,
  code: code,
  name: name,
  type: type,
  dept: dept,
  description: 'Receiving checks',
  version: 1,
  isPublished: published,
  isArchived: archived,
  requiresApprovalOnSubmit: requiresApproval,
  effectiveDate: published ? '2026-01-01' : '',
  expiryDate: expiryDate,
  createdAt: _now,
  updatedAt: _now,
);

QcSection _section({int id = 900, String title = 'Packaging'}) =>
    QcSection(sectionId: id, templateId: 1, title: title, orderIndex: 0);

QcItem _item({
  int id = 950,
  int sectionId = 900,
  String label = 'Cartons intact',
  String itemType = QcItemType.passFail,
  List<String> options = const [],
}) => QcItem(
  itemId: id,
  sectionId: sectionId,
  templateId: 1,
  label: label,
  itemType: itemType,
  orderIndex: 0,
  optionsJson: options.join(', '),
);

/// Stubs the query so it honours its arguments, the way SQL would. A stub that
/// ignored `publishedOnly` would make the "usable today" view untestable.
void _stubTemplates(
  _TemplatesMock repo, {
  List<QcTemplate> rows = const [],
  List<QcSection> sections = const [],
  List<QcItem> items = const [],
  QcTemplate? missing,
}) {
  when(
    () => repo.listTemplates(
      dept: any(named: 'dept'),
      publishedOnly: any(named: 'publishedOnly'),
    ),
  ).thenAnswer((invocation) async {
    final dept = invocation.namedArguments[#dept] as String;
    final publishedOnly = invocation.namedArguments[#publishedOnly] as bool;
    var out = rows;
    if (dept.isNotEmpty) out = out.where((t) => t.dept == dept).toList();
    if (publishedOnly) out = out.where((t) => t.isPublished).toList();
    return out;
  });
  when(() => repo.getTemplate(any())).thenAnswer((_) async => missing);
  when(() => repo.getTemplateTree(any())).thenAnswer(
    (_) async => missing == null
        ? (template: rows.first, sections: sections, items: items)
        : null,
  );
}

Widget _host(Widget child, QcTemplatesCubit cubit) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => BlocProvider.value(
    value: cubit,
    child: MaterialApp(home: child),
  ),
);

/// The tree editor is opened as a pushed route over the library, with both
/// cubits above it - the same shape [QcTemplateEditorScreen.open] builds.
Future<void> _openEditor(
  WidgetTester tester,
  QcTemplatesCubit library,
  int templateId,
) async {
  final detail = QcTemplateDetailCubit(
    repo: library.repo,
    library: library,
    templateId: templateId,
  )..load();
  addTearDown(detail.close);
  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(1280, 720),
      builder: (context, _) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: library),
          BlocProvider.value(value: detail),
        ],
        child: MaterialApp(
          home: QcTemplateEditorScreen(templateId: templateId),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The editor is one long list; its publish gate sits above the sections, so the
/// window is grown rather than dragging through every assertion.
void _tallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => AppText.arabic = false);
  tearDownAll(() => AppText.arabic = true);
  setUpAll(() {
    registerFallbackValue(_template());
    registerFallbackValue(_section());
    registerFallbackValue(_item());
  });

  group('QcTemplatesScreen', () {
    late _TemplatesMock repo;
    late QcTemplatesCubit cubit;

    setUp(() {
      repo = _TemplatesMock();
      cubit = QcTemplatesCubit(repo: repo);
    });

    tearDown(() => cubit.close());

    testWidgets('an empty library explains itself instead of a list', (
      tester,
    ) async {
      _stubTemplates(repo);
      await cubit.load();
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('No checklists yet'), findsOneWidget);
    });

    testWidgets('each template shows its name, code and translated type', (
      tester,
    ) async {
      _stubTemplates(
        repo,
        rows: [
          _template(),
          _template(
            id: 2,
            code: 'CHK-002',
            name: 'In-process check',
            type: QcTemplateType.inProcess,
          ),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Incoming inspection'), findsOneWidget);
      expect(find.text('CHK-001'), findsOneWidget);
      expect(find.widgetWithText(QcPill, 'Incoming'), findsOneWidget);
      expect(find.widgetWithText(QcPill, 'In process'), findsOneWidget);
    });

    testWidgets('the summary counts drafts, published and usable', (
      tester,
    ) async {
      _stubTemplates(
        repo,
        rows: [
          _template(),
          _template(id: 2, code: 'CHK-002', published: true),
          _template(id: 3, code: 'CHK-003'),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Total'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // "Published" appears twice here: the summary card's label and the issued
      // template's pill. Scoping to the summary cards keeps the assertion about
      // the counts rather than about label collisions.
      expect(
        find.descendant(
          of: find.byType(AppSummaryCard),
          matching: find.text('Published'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AppSummaryCard),
          matching: find.text('Usable'),
        ),
        findsOneWidget,
      );
      // Three total, one issued, two drafts, and only the issued one can start
      // an inspection.
      expect(
        tester
            .widgetList<AppSummaryCard>(find.byType(AppSummaryCard))
            .map((c) => '${c.label}=${c.value}'),
        ['Total=3', 'Published=1', 'Draft=2', 'Usable=1'],
      );
    });

    testWidgets('a published template is badged, a draft is too', (
      tester,
    ) async {
      _stubTemplates(
        repo,
        rows: [
          _template(),
          _template(id: 2, code: 'CHK-002', published: true),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(QcPill, 'Published'), findsOneWidget);
      expect(find.widgetWithText(QcPill, 'Draft'), findsOneWidget);
    });

    testWidgets('an archived published template says it cannot be used', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(repo, rows: [_template(published: true, archived: true)]);
      await cubit.load();
      // Archived rows are hidden by default - a retired checklist is not in the
      // running set - so it only appears once the reader asks to see them.
      expect(cubit.state.templates, isEmpty);

      await cubit.applyFilters(const QcTemplateFilters(includeArchived: true));
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(
        find.text('Archived - no longer starts an inspection'),
        findsOneWidget,
      );
    });

    testWidgets('an expired template says it cannot be used', (tester) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template(published: true, expiryDate: '2025-01-01')],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(
        find.text('Expired - no longer starts an inspection'),
        findsOneWidget,
      );
    });

    testWidgets('a checklist needing approval says so on the tile', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(repo, rows: [_template(requiresApproval: true)]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Needs approval before closing'), findsOneWidget);
    });

    testWidgets('a filter with no matches offers a way back', (tester) async {
      _stubTemplates(repo, rows: [_template()]);
      await cubit.load();
      await cubit.applyFilters(const QcTemplateFilters(text: 'zzz'));
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('No checklists match these filters'), findsOneWidget);
      expect(find.text('Clear filters'), findsOneWidget);

      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Incoming inspection'), findsOneWidget);
    });

    testWidgets('a repository failure surfaces instead of an empty list', (
      tester,
    ) async {
      // Loaded before the widget is mounted, so the error is already in state
      // when the screen builds: the screen has to render it, not wait for a
      // listener that was never listening.
      when(
        () => repo.listTemplates(
          dept: any(named: 'dept'),
          publishedOnly: any(named: 'publishedOnly'),
        ),
      ).thenThrow(const AppError('db is offline'));
      await cubit.load();
      await tester.pumpWidget(_host(const QcTemplatesScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.textContaining('db is offline'), findsOneWidget);
    });
  });

  group('QcTemplateEditorScreen', () {
    late _TemplatesMock repo;
    late QcTemplatesCubit library;

    setUp(() {
      repo = _TemplatesMock();
      library = QcTemplatesCubit(repo: repo);
    });

    tearDown(() => library.close());

    testWidgets('renders the tree with its items', (tester) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item()],
      );
      await library.load();
      await _openEditor(tester, library, 1);

      expect(find.text('Packaging'), findsOneWidget);
      expect(find.text('Cartons intact'), findsOneWidget);
      expect(find.text('Pass/Fail'), findsOneWidget);
    });

    testWidgets('a valid draft offers a working publish', (tester) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item()],
      );
      when(
        () => repo.publishTemplate(
          any(),
          publishedBy: any(named: 'publishedBy'),
          effectiveDate: any(named: 'effectiveDate'),
        ),
      ).thenAnswer((_) async {});
      await library.load();
      await _openEditor(tester, library, 1);

      final publish = find.widgetWithText(FilledButton, 'Publish');
      expect(publish, findsOneWidget);
      final button = tester.widget<FilledButton>(publish);
      expect(button.onPressed, isNotNull);
    });

    testWidgets('an empty tree explains why publish is disabled', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(repo, rows: [_template()], sections: [], items: []);
      await library.load();
      await _openEditor(tester, library, 1);

      expect(find.text('The checklist has no sections yet'), findsOneWidget);
      expect(find.text('The checklist has no items yet'), findsOneWidget);

      final publish = find.widgetWithText(FilledButton, 'Publish');
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
    });

    testWidgets('a section with no items names itself as the blocker', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section(title: 'Labelling')],
        items: [_item(sectionId: 999)],
      );
      await library.load();
      await _openEditor(tester, library, 1);

      expect(find.text('Section "Labelling" has no items'), findsOneWidget);
    });

    testWidgets('an unlabelled item is called out in the tree', (tester) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item(label: '')],
      );
      await library.load();
      await _openEditor(tester, library, 1);

      expect(find.text('Item with no label'), findsOneWidget);
    });

    testWidgets('an editor for a template that is gone says so', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(repo, rows: [_template()], missing: _template());
      await library.load();
      await _openEditor(tester, library, 999);

      expect(find.text('This template no longer exists'), findsOneWidget);
    });

    testWidgets('a published template is frozen: no add, only duplicate', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template(published: true)],
        sections: [_section()],
        items: [_item()],
      );
      await library.load();
      await _openEditor(tester, library, 1);

      expect(
        find.text('Published - any change needs a new version'),
        findsOneWidget,
      );
      expect(find.text('Add section'), findsNothing);
      expect(find.text('Add item'), findsNothing);
      expect(
        find.widgetWithText(OutlinedButton, 'Create a draft version'),
        findsOneWidget,
      );
    });

    testWidgets('adding a section shows it as an unsaved change', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item()],
      );
      when(
        () => repo.saveTemplateTree(any(), any(), any()),
      ).thenAnswer((_) async {});
      await library.load();
      await _openEditor(tester, library, 1);

      expect(find.text('Unsaved'), findsNothing);

      await tester.tap(find.text('Add section'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Labelling');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Labelling'), findsOneWidget);
      expect(find.text('Unsaved'), findsOneWidget);
      // Save is available because something changed.
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Save'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('save writes the tree and clears the unsaved marker', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item()],
      );
      when(
        () => repo.saveTemplateTree(any(), any(), any()),
      ).thenAnswer((_) async {});
      await library.load();
      await _openEditor(tester, library, 1);

      await tester.tap(find.text('Add section'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Labelling');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
      await tester.pumpAndSettle();

      verify(() => repo.saveTemplateTree(any(), any(), any())).called(1);
      expect(find.text('Unsaved'), findsNothing);
    });

    testWidgets('publish is blocked while the tree is unsaved', (tester) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item()],
      );
      when(
        () => repo.saveTemplateTree(any(), any(), any()),
      ).thenAnswer((_) async {});
      await library.load();
      await _openEditor(tester, library, 1);

      await tester.tap(find.text('Add section'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Labelling');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      final publish = find.widgetWithText(FilledButton, 'Publish');
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
      expect(find.text('Save the tree before publishing it'), findsOneWidget);
    });

    testWidgets('publishing asks for an effective date, then issues', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item()],
      );
      when(
        () => repo.publishTemplate(
          any(),
          publishedBy: any(named: 'publishedBy'),
          effectiveDate: any(named: 'effectiveDate'),
        ),
      ).thenAnswer((_) async {});
      await library.load();
      await _openEditor(tester, library, 1);

      await tester.tap(find.widgetWithText(FilledButton, 'Publish'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '2026-03-01');
      await tester.tap(find.widgetWithText(FilledButton, 'Publish').last);
      await tester.pumpAndSettle();

      verify(
        () => repo.publishTemplate(
          1,
          publishedBy: any(named: 'publishedBy'),
          effectiveDate: '2026-03-01',
        ),
      ).called(1);
    });

    testWidgets('a new checklist is created then opened as a tree', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item()],
      );
      when(() => repo.createTemplate(any())).thenAnswer((_) async => 42);
      await library.load();
      await tester.pumpWidget(_host(const QcTemplateEditorScreen(), library));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'Outgoing goods',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'CHK-050');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      final captured =
          verify(() => repo.createTemplate(captureAny())).captured.single
              as QcTemplate;
      expect(captured.name, 'Outgoing goods');
      expect(captured.code, 'CHK-050');
      expect(captured.templateId, isNull);
    });

    testWidgets('a create failure keeps the form open', (tester) async {
      _stubTemplates(repo, rows: [_template()]);
      when(
        () => repo.createTemplate(any()),
      ).thenThrow(const AppError('Permission denied'));
      await library.load();
      await tester.pumpWidget(_host(const QcTemplateEditorScreen(), library));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextFormField).at(0),
        'Outgoing goods',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(find.text('Create'), findsOneWidget);
      expect(find.textContaining('Permission denied'), findsOneWidget);
    });

    testWidgets('an item sheet edits a label and writes it back', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item()],
      );
      when(
        () => repo.saveTemplateTree(any(), any(), any()),
      ).thenAnswer((_) async {});
      await library.load();
      await _openEditor(tester, library, 1);

      await tester.tap(find.text('Cartons intact'));
      await tester.pumpAndSettle();

      final sheetLabel = find.widgetWithText(TextField, 'Cartons intact');
      expect(sheetLabel, findsOneWidget);
      await tester.enterText(sheetLabel, 'Cartons undamaged');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      expect(find.text('Cartons undamaged'), findsOneWidget);
      expect(find.text('Unsaved'), findsOneWidget);
    });

    testWidgets('an item with a blank label is styled as a problem', (
      tester,
    ) async {
      _tallWindow(tester);
      _stubTemplates(
        repo,
        rows: [_template()],
        sections: [_section()],
        items: [_item(label: '  ')],
      );
      await library.load();
      await _openEditor(tester, library, 1);

      final text = tester.widget<Text>(find.text('Item with no label'));
      expect(text.style?.color, AppColors.danger);
    });
  });
}
