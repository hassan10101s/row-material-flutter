import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_sops_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/sops/qc_sop_form_screen.dart';

class _SopsMock extends Mock implements QcSopRepository {}

/// Regression test: the dialog-embedded form must not build a [Scaffold].
///
/// A Scaffold inside the window's scrollable body receives unbounded
/// height and explodes (`RenderCustomMultiChildLayoutBox was given an
/// infinite size`). The route mode keeps its own Scaffold.
void main() {
  late _SopsMock repo;
  late QcSopsCubit cubit;

  setUp(() {
    repo = _SopsMock();
    cubit = QcSopsCubit(repo: repo);
  });

  tearDown(() async {
    await cubit.close();
  });

  Future<void> pumpEmbedded(WidgetTester tester) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 900),
        builder: (_, _) => MaterialApp(
          home: Scaffold(
            // Same unbounded-height conditions as AppWindow's scroll body.
            body: SingleChildScrollView(
              child: BlocProvider.value(
                value: cubit,
                child: const QcSopFormScreen(embedded: true),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('embedded form lays out inside an unbounded scrollable',
      (tester) async {
    await pumpEmbedded(tester);

    expect(tester.takeException(), isNull);
    // The dialog chrome owns the title; the form shows its fields.
    expect(find.text('💾 حفظ'), findsOneWidget);
  });

  testWidgets('route mode keeps its own Scaffold and app bar', (tester) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(400, 860),
        builder: (_, _) => MaterialApp(
          home: BlocProvider.value(
            value: cubit,
            child: const QcSopFormScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('💾 حفظ'), findsOneWidget);
  });
}
