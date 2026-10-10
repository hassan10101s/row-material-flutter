import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';
import 'package:material_lab/features/auth/presentation/cubit/login_cubit.dart';
import 'package:material_lab/features/auth/presentation/login/login_screen.dart';

class _AuthRepositoryMock extends Mock implements AuthRepository {}

class _AuthGateMock extends Mock implements AuthGate {}

void main() {
  testWidgets('LoginScreen builds with a provided LoginCubit', (tester) async {
    final auth = _AuthRepositoryMock();
    final gate = _AuthGateMock();

    when(() => auth.missingConfiguration).thenReturn(const []);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, child) => BlocProvider(
          create: (c) => LoginCubit(auth: auth, gate: gate),
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: const LoginScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text(AppStrings.appTitle), findsOneWidget);
    expect(
      find.text(AppText.t('المتابعة باستخدام Google', 'Continue with Google')),
      findsOneWidget,
    );
    expect(find.text(AppText.t('الدعم', 'Support')), findsWidgets);
  });
}
