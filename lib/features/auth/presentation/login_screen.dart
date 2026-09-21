import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../router/app_router.dart';
import 'cubit/login_cubit.dart';

/// Login screen (port of Web LoginScreen + controller.auth_login).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  var _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ok = await context.read<LoginCubit>().submit(
          username: _username.text.trim(),
          password: _password.text,
        );
    if (!mounted || !ok) return;
    context.go(AppRoutes.dashboard);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LoginCubit>().state;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 420.w),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.science, size: 48.r, color: AppColors.primary),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      AppStrings.appTitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      AppStrings.tagline,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppField(
                      label: AppText.t('اسم المستخدم', 'Username'),
                      controller: _username,
                      hint: 'username',
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppField(
                      label: AppText.t('كلمة المرور', 'Password'),
                      controller: _password,
                      obscure: _obscure,
                      onChanged: (_) {},
                      suffix: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                            color: AppColors.textMuted),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    if (state.error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        state.error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.danger, fontSize: 13.spMax),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: AppStrings.login,
                      expanded: true,
                      loading: state.busy,
                      onPressed: state.busy ? null : _submit,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text(AppText.t('الدعم', 'Support')),
                          content: const Text(
                              'للحصول على الدعم تواصل عبر واتساب على الرقم 201213473838\nSupport via WhatsApp: +201213473838'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.of(c).pop(),
                                child: Text(AppText.t('حسناً', 'OK'))),
                          ],
                        ),
                      ),
                      icon: Icon(Icons.support_agent, size: 18.r),
                      label: Text(AppText.t('الدعم', 'Support')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}