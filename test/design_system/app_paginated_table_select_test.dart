import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/design_system/widgets/app_paginated_table.dart';

/// Hidden-until-long-press circular selection: the checkbox column stays
/// away until the user long-presses a row (or taps the header toggle), then
/// modern circular boxes appear; clearing the pick hides them again.
class _Harness extends StatefulWidget {
  const _Harness({this.selectHidden = false, this.onRowTap});

  final bool selectHidden;
  final void Function(int index)? onRowTap;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final Set<int> selected = <int>{};
  final List<int> tapped = <int>[];

  @override
  Widget build(BuildContext context) {
    return AppPaginatedTable(
      headers: const ['Name'],
      rows: const [
        [Text('one')],
        [Text('two')],
      ],
      selectHidden: widget.selectHidden,
      selectedIndices: selected,
      onToggleIndex: (i) => setState(() {
        if (!selected.remove(i)) selected.add(i);
      }),
      selectAllValue: selected.isEmpty
          ? false
          : selected.length >= 2
              ? true
              : null,
      onToggleAll: (_) => setState(() {
        if (selected.length >= 2) {
          selected.clear();
        } else {
          selected.addAll([0, 1]);
        }
      }),
      onRowTap: widget.onRowTap == null
          ? null
          : (i) {
              tapped.add(i);
              widget.onRowTap!(i);
            },
    );
  }
}

Future<void> pumpHarness(
  WidgetTester tester, {
  bool selectHidden = false,
  void Function(int index)? onRowTap,
}) async {
  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(1280, 800),
      builder: (_, _) => MaterialApp(
        home: Scaffold(
          body: _Harness(selectHidden: selectHidden, onRowTap: onRowTap),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('hidden long-press selection', () {
    testWidgets('column hidden until toggle or long-press', (tester) async {
      await pumpHarness(tester, selectHidden: true);

      expect(find.byType(Checkbox), findsNothing);
      expect(find.byTooltip('Select'), findsOneWidget);

      // Header toggle reveals circular boxes without picking anything.
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(3));
      final box = tester.widget<Checkbox>(find.byType(Checkbox).first);
      expect(box.shape, isA<CircleBorder>());
    });

    testWidgets('long-press enters select mode and picks the row',
        (tester) async {
      final tapped = <int>[];
      await pumpHarness(
        tester,
        selectHidden: true,
        onRowTap: tapped.add,
      );

      // A plain tap still opens the row while selection is hidden.
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
      expect(tapped, [0]);
      expect(find.byType(Checkbox), findsNothing);

      await tester.longPress(find.text('two'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(3));
      // The long-pressed row is picked; tapping another row toggles now.
      await tester.tap(find.text('one'));
      await tester.pumpAndSettle();
      expect(tapped, [0]);
    });

    testWidgets('clearing the pick hides the column again', (tester) async {
      await pumpHarness(tester, selectHidden: true);

      await tester.longPress(find.text('one'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(3));

      // Header box selects the rest first (indeterminate → all)...
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(3));
      // ...then clears everything, which exits select mode.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byTooltip('Select'), findsOneWidget);
    });

    testWidgets('visible mode keeps the classic always-on column',
        (tester) async {
      await pumpHarness(tester);

      expect(find.byType(Checkbox), findsNWidgets(3));
      expect(find.byTooltip('Select'), findsNothing);
    });
  });
}
