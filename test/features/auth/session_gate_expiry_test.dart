import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';

class _Auth extends Mock implements AuthRepository {}

void main() {
  testWidgets(
    'an open application expires at ten days despite a profile refresh',
    (tester) async {
      final auth = _Auth();
      final states = StreamController<AuthState>.broadcast();
      final started = DateTime.utc(2026, 11, 1);
      var now = started
          .add(const Duration(days: 10))
          .subtract(const Duration(minutes: 1));
      var session = AppSession(
        uid: 'u',
        authenticationPolicyVersion: 1,
        signedInAt: started,
        status: 'active',
      );
      var state = AuthState.ready;
      when(() => auth.session).thenAnswer((_) => session);
      when(() => auth.state).thenAnswer((_) => state);
      when(() => auth.currentState).thenAnswer((_) => states.stream);
      when(auth.signOut).thenAnswer((_) async {
        session = const AppSession();
        state = AuthState.signedOut;
        states.add(state);
      });
      final gate = AuthGate(auth, now: () => now)..start();
      expect(gate.isAuthenticated, isTrue);
      states.add(AuthState.ready);
      await tester.pump();
      verifyNever(auth.signOut);
      now = started.add(const Duration(days: 10));
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      verify(auth.signOut).called(1);
      expect(gate.isSignedOut, isTrue);
      expect(gate.isAuthenticated, isFalse);
      gate.dispose();
      await states.close();
    },
  );
}
