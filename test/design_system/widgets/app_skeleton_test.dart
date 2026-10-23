import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/design_system/widgets/app_skeleton.dart';

void main() {
  Widget harness(double height, {int rows = 6, int lines = 2}) => MaterialApp(
        home: Scaffold(
          body: AppSkeletonList(rows: rows, lines: lines, height: height),
        ),
      );

  testWidgets(
      'a tight fixed box renders only the rows that fit (no overflow)'
      ' — regression: inspections mobile skeleton (h=120, rows=6)',
      (tester) async {
    await tester.pumpWidget(harness(120));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a strip too short for the header drops the header, keeps one row'
      ' (no overflow) — regression: routine sheet skeleton (h=64)',
      (tester) async {
    await tester.pumpWidget(harness(64));
    expect(tester.takeException(), isNull);

    final skeletons = tester
        .widgetList<AppSkeleton>(find.byType(AppSkeleton))
        .toList(growable: false);
    // The 36dp avatar tile cannot fit a 64dp strip once the card padding
    // subtracts: the header must be gone...
    expect(skeletons.any((s) => s.height == 36), isFalse);
    // ...but at least one data row still stands in for the content.
    expect(
      skeletons.where((s) => s.height == 14 || s.height == 12),
      isNotEmpty,
    );
  });

  testWidgets('a roomy box still renders every requested row',
      (tester) async {
    await tester.pumpWidget(harness(420));
    expect(tester.takeException(), isNull);

    // Header line + 6 rows x 2 lines, deduped by height.
    final lines = find.byWidgetPredicate(
      (w) => w is AppSkeleton && (w.height == 14 || w.height == 12),
    );
    expect(lines, findsNWidgets(12));
  });
}
