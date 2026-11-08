import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/session_policy.dart';

void main() {
  final start = DateTime.utc(2026, 11, 1);
  test('deadline is exactly ten days since explicit authentication', () {
    expect(
      SessionPolicy.requiresSignIn(
        start,
        start
            .add(const Duration(days: 10))
            .subtract(const Duration(microseconds: 1)),
      ),
      isFalse,
    );
    expect(
      SessionPolicy.requiresSignIn(start, start.add(const Duration(days: 10))),
      isTrue,
    );
    expect(
      SessionPolicy.requiresSignIn(start, start.add(const Duration(days: 11))),
      isTrue,
    );
  });
  test(
    'unknown age and a clock earlier than sign-in require authentication',
    () {
      expect(SessionPolicy.requiresSignIn(null, start), isTrue);
      expect(
        SessionPolicy.requiresSignIn(start, start, policyVersion: 0),
        isTrue,
      );
      expect(
        SessionPolicy.requiresSignIn(
          start,
          start.subtract(const Duration(seconds: 1)),
        ),
        isTrue,
      );
    },
  );
}
