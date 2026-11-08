import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/design_system/widgets/app_autocomplete.dart';
import 'package:material_lab/design_system/widgets/app_autocomplete_overlay.dart';

/// Behavioural cover for the app-wide entity picker.
///
/// `AppAutocomplete` replaces a hand-rolled `RawAutocomplete` that was copied
/// into the inspection form. These tests pin the behaviour that mattered there:
/// the empty query serves the whole list, typing narrows it, a committed choice
/// is read-only, a miss shows an empty label, and the caret re-opens the list.
void main() {
  _watchedHostTests();
  const materials = <(int, String)>[
    (1, 'Water'),
    (2, 'Glass'),
    (3, 'Water softener'),
  ];

  Widget harness({
    (int, String)? selected,
    ValueChanged<(int, String)>? onSelected,
    String emptyLabel = 'No matches',
  }) => ScreenUtilInit(
    designSize: const Size(1280, 720),
    minTextAdapt: true,
    splitScreenMode: true,
    builder: (context, _) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: AppAutocomplete<(int, String)>(
            options: materials,
            selected: selected,
            displayString: (option) => option.$2,
            filter: (option, query) => option.$2.toLowerCase().contains(query),
            onSelected: onSelected ?? (_) {},
            hint: 'Type to search…',
            emptyLabel: emptyLabel,
          ),
        ),
      ),
    ),
  );

  /// Types [text] into the field and pumps the async options overlay up.
  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  testWidgets('an empty query offers the whole list', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Glass'), findsOneWidget);
    expect(find.text('Water softener'), findsOneWidget);
  });

  testWidgets('typing narrows by the provided filter', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await search(tester, 'glass');

    expect(find.text('Glass'), findsOneWidget);
    expect(find.text('Water'), findsNothing);
    expect(find.text('Water softener'), findsNothing);
  });

  testWidgets('committing an option reports it and settles the field', (
    tester,
  ) async {
    (int, String)? committed;
    await tester.pumpWidget(
      harness(onSelected: (option) => committed = option),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await search(tester, 'glass');
    await tester.tap(find.text('Glass'));
    await tester.pumpAndSettle();

    expect(committed, (2, 'Glass'));
    // The field carries the chosen display string.
    expect(
      find.descendant(of: find.byType(TextField), matching: find.text('Glass')),
      findsOneWidget,
    );
  });

  testWidgets('a query with no hits shows the empty label', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await search(tester, 'zzz-no-such-thing');

    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets(
    'a committed selection is read-only and shows the display string',
    (tester) async {
      await tester.pumpWidget(harness(selected: (3, 'Water softener')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue);
      expect(
        find.descendant(
          of: find.byType(TextField),
          matching: find.text('Water softener'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('switching to no selection clears the field', (tester) async {
    final selected = ValueNotifier<(int, String)?>((1, 'Water'));
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: selected,
        builder: (context, value, _) => harness(selected: value),
      ),
    );
    await tester.pumpAndSettle();

    selected.value = null;
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    expect(find.text('Water'), findsNothing);
  });

  testWidgets('the overlay takes the full width of its field', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final overlay = tester.widget<AppAutocompleteOverlay>(
      find.byType(AppAutocompleteOverlay),
    );
    final fieldWidth = tester.getSize(find.byType(TextField)).width;
    expect(overlay.fieldWidth, moreOrLessEquals(fieldWidth));
  });

  testWidgets('the caret re-opens the list from a typed query', (tester) async {
    await tester.pumpWidget(harness());
    await search(tester, 'wat');

    // Overlay is up with the narrowed set…
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Water softener'), findsOneWidget);
  });

  testWidgets('the caret re-opens the list of a committed value', (
    tester,
  ) async {
    await tester.pumpWidget(harness(selected: (3, 'Water softener')));
    await tester.pumpAndSettle();

    // A committed field is read-only, but the caret must still open the full
    // list so the choice can be changed without clearing it first.
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Glass'), findsOneWidget);
  });

  testWidgets('closing a re-opened list restores the committed value', (
    tester,
  ) async {
    await tester.pumpWidget(harness(selected: (3, 'Water softener')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(
      find.descendant(
        of: find.byType(TextField),
        matching: find.text('Water softener'),
      ),
      findsOneWidget,
    );
  });
}

/// Regression harness for the inspection-form crash the picker once caused:
/// a host that owns the controller AND listens to it (the form screens' dirty
/// guards) got notified from `didUpdateWidget` while the framework was
/// building the host's subtree, and the resulting `setState` tripped
/// markNeedsBuild-during-build on this ancestor. The initial-mount sync is
/// deliberately mid-build (see the widget's `initState` comment), so the host
/// copies the hardened dirty guard: it defers a mid-frame `setState` past the
/// frame and records the scheduler phase of every notification.
class _WatchedHost extends StatefulWidget {
  const _WatchedHost({super.key, required this.selected});

  final ValueNotifier<(int, String)?> selected;

  @override
  State<_WatchedHost> createState() => _WatchedHostState();
}

class _WatchedHostState extends State<_WatchedHost> {
  final TextEditingController _controller = TextEditingController();
  final List<String> _notifyPhases = [];

  /// True once the controller notified — the dirty-guard signal the form
  /// screens derive for `PopScope.canPop`.
  bool dirty = false;

  @override
  void initState() {
    super.initState();
    widget.selected.addListener(_onSelectionChanged);
    _controller.addListener(_onControllerChanged);
  }

  void _onSelectionChanged() => setState(() {});

  void _onControllerChanged() {
    _notifyPhases.add(SchedulerBinding.instance.schedulerPhase.name);
    if (dirty) return;
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (dirty || !mounted) return;
        setState(() => dirty = true);
      });
      return;
    }
    setState(() => dirty = true);
  }

  @override
  void dispose() {
    widget.selected.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(1280, 720),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, _) => MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: AppAutocomplete<(int, String)>(
              options: const [
                (1, 'Water'),
                (2, 'Glass'),
                (3, 'Water softener'),
              ],
              selected: widget.selected.value,
              displayString: (option) => option.$2,
              filter: (option, query) =>
                  option.$2.toLowerCase().contains(query),
              onSelected: (_) {},
              controller: _controller,
            ),
          ),
        ),
      ),
    );
  }
}

void _watchedHostTests() {
  testWidgets(
    'a parent-watched controller is never notified mid-build by an external pick',
    (tester) async {
      final selected = ValueNotifier<(int, String)?>((1, 'Water'));
      final host = GlobalKey<_WatchedHostState>();
      await tester.pumpWidget(_WatchedHost(key: host, selected: selected));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The initial sync is documented as mid-build (initState runs before
      // the RawAutocomplete descendant mounts), invites the hardened host to
      // defer; the write lands visibly anyway.
      expect(
        host.currentState!._notifyPhases,
        everyElement(SchedulerPhase.persistentCallbacks.name),
      );
      expect(host.currentState!.dirty, isTrue);
      expect(
        find.descendant(of: find.byType(TextField), matching: find.text('Water')),
        findsOneWidget,
      );
      host.currentState!._notifyPhases.clear();

      // External pick: the host rebuilds, the picker syncs the watched
      // controller — a mid-build notification here is the pinned crash.
      selected.value = (2, 'Glass');
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(
        host.currentState!._notifyPhases,
        everyElement(isNot(SchedulerPhase.persistentCallbacks.name)),
      );
      host.currentState!._notifyPhases.clear();
      expect(
        find.descendant(of: find.byType(TextField), matching: find.text('Glass')),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);

      // External clear: the no-hit helper stays quiet during the pending
      // frame (the field still carries the old committed text), then the
      // deferred sync empties the field and re-opens it for picking.
      selected.value = null;
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        host.currentState!._notifyPhases,
        everyElement(isNot(SchedulerPhase.persistentCallbacks.name)),
      );
      expect(find.text('No matches'), findsNothing);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(TextField), matching: find.text('Glass')),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byType(TextField), matching: find.text('Water')),
        findsNothing,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    },
  );
}
