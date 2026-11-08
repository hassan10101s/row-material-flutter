import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/commands/central_authoring_gateway.dart';
import 'package:material_lab/features/reference/presentation/units/units_editor.dart';

void main() {
  testWidgets('a pending unit request cannot be submitted twice', (
    tester,
  ) async {
    final key = GlobalKey<UnitsEditorState>();
    var calls = 0;
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1440, 900),
        builder: (context, child) => MaterialApp(
          home: Scaffold(
            body: UnitsEditor(
              key: key,
              onSubmit: (symbol, {name = '', dimension = ''}) async {
                calls++;
                throw CentralDraftPending('draft');
              },
              actions: (context, state) => UnitsEditorActions(state: state),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'kg');
    await key.currentState!.submit();
    await tester.pump();
    expect(key.currentState!.pending, isTrue);
    expect(key.currentState!.saving, isFalse);
    await key.currentState!.submit();
    expect(calls, 1);
  });
}
