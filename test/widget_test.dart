import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/features/auth/data/auth_repo.dart';
import 'package:material_lab/features/auth/presentation/cubit/login_cubit.dart';
import 'package:material_lab/features/auth/presentation/login_screen.dart';

class _AuthRepoMock extends Mock implements AuthRepo {}
class _AuthGateMock extends Mock implements AuthGate {}

void main() {
  testWidgets('LoginScreen builds with a provided LoginCubit', (tester) async {
    final auth = _AuthRepoMock();
    final gate = _AuthGateMock();

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, child) => BlocProvider(
          create: (c) => LoginCubit(auth: auth, gate: gate),
          child: const MaterialApp(home: LoginScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
  });
}