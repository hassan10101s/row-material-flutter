import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/design_system/feedback/app_error_feedback.dart';

const _banner = ValueKey('app-feedback-banner');

class _State {
  final String? error;
  const _State({this.error});
}

class _Cubit extends Cubit<_State> {
  _Cubit() : super(const _State());
  void fail(String message) => emit(_State(error: message));
  void clear() => emit(const _State());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_Cubit> pumpSubject(WidgetTester tester) async {
    final cubit = _Cubit();
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<_Cubit>.value(
        value: cubit,
        child: AppErrorFeedback<_Cubit, _State>(
          selector: (s) => s.error,
          child: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    ));
    return cubit;
  }

  /// The banner is raised from an `addPostFrameCallback`, so the overlay entry
  /// only lands two frames after the emit. `pumpAndSettle` covers that plus the
  /// entry animation, without racing the auto-dismiss timer.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pumpAndSettle();
  }

  /// An error banner lives 9s; a test must not end with its timer pending.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
  }

  testWidgets('renders the state error in the banner, not in the child',
      (tester) async {
    final cubit = await pumpSubject(tester);
    expect(find.byKey(_banner), findsNothing);

    cubit.fail('permission denied');
    await settle(tester);

    expect(find.text('permission denied'), findsOneWidget);
    expect(find.byKey(_banner), findsOneWidget);

    await drain(tester);
  });

  testWidgets('a new error replaces the previous message', (tester) async {
    final cubit = await pumpSubject(tester);

    cubit.fail('first');
    await settle(tester);
    expect(find.text('first'), findsOneWidget);

    cubit.fail('second');
    await settle(tester);
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);

    await drain(tester);
  });

  testWidgets('the same error re-appears after it cleared', (tester) async {
    final cubit = await pumpSubject(tester);

    cubit.fail('boom');
    await settle(tester);
    expect(find.text('boom'), findsOneWidget);

    cubit.clear();
    await drain(tester);
    expect(find.byKey(_banner), findsNothing);

    // Suppression is per distinct message, not a latch: the same failure
    // happening again must still be reported.
    cubit.fail('boom');
    await settle(tester);
    expect(find.text('boom'), findsOneWidget);

    await drain(tester);
  });

  testWidgets('a rebuild carrying an identical error does not stack banners',
      (tester) async {
    final cubit = await pumpSubject(tester);

    cubit.fail('boom');
    await settle(tester);
    // Assert it is really on screen, so the check below cannot pass vacuously.
    expect(find.byKey(_banner), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);

    // A fresh state instance carrying the same message must not re-raise.
    cubit.fail('boom');
    await settle(tester);
    expect(find.byKey(_banner), findsOneWidget);

    await drain(tester);
  });
}
