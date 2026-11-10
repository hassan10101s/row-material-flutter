import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/design_system/tokens/app_colors.dart';
import 'package:material_lab/design_system/widgets/app_control_strip.dart';

void main() {
  testWidgets('uses the shared surface and consistent control spacing', (
    tester,
  ) async {
    const first = ValueKey('first-control');
    const second = ValueKey('second-control');
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: AppControlStrip(
              key: const ValueKey('control-strip'),
              height: 56,
              spacing: 12,
              children: const [
                SizedBox(key: first, width: 20, height: 20),
                SizedBox(key: second, width: 20, height: 20),
              ],
            ),
          ),
        ),
      ),
    );

    final strip = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('control-strip')),
        matching: find.byType(Container),
      ),
    );
    final decoration = strip.decoration! as BoxDecoration;
    expect(decoration.color, AppColors.surface);

    final firstRect = tester.getRect(find.byKey(first));
    final secondRect = tester.getRect(find.byKey(second));
    expect(secondRect.left - firstRect.right, 12);
  });
}
