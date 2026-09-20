import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/features/auth/presentation/login_screen.dart';

void main() {
  testWidgets('LoginScreen builds', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: LoginScreen()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
  });
}