import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/feedback/app_error_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import 'cubit/login_cubit.dart';
import 'cubit/login_state.dart';

/// Login screen (plan §8.1): **one Google button** + the four display states
/// (idle / signing-in / error / firebase-unavailable) + the existing support
/// link. The username/password form and the setup wizard are gone.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LoginCubit, LoginState>(
      builder: (context, state) {
        final cubit = context.read<LoginCubit>();
        return AppErrorFeedback<LoginCubit, LoginState>(
          selector: (s) => s.error,
          child: Scaffold(
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
                          if (state.needsConfiguration)
                            _ConfigurationHint(missing: state.missingConfiguration)
                          else
                            _GoogleButton(busy: state.busy, onPressed: cubit.signIn),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            AppText.t(
                              'سيتم إنشاء حساب Google وربطه بمؤسسة واحدة. الأجهزة '
                              'تعمل بدون إنترنت لكل البيانات المحفوظة محلياً.',
                              'A Google account is linked to one organization. '
                              'The app works offline with locally stored data.',
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
                          ),
                          const SizedBox(height: AppSpacing.lg),
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
          ),
        );
      },
    );
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.busy, required this.onPressed});

  final bool busy;
  final Future<bool> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: busy
          ? AppText.t('جارٍ فتح المتصفح…', 'Opening browser…')
          : AppText.t('المتابعة باستخدام Google', 'Continue with Google'),
      expanded: true,
      loading: busy,
      icon: const Icon(Icons.login, size: 18),
      onPressed: busy ? null : () => onPressed(),
    );
  }
}

/// Shown instead of the button when `firebase_options.dart` has no values.
class _ConfigurationHint extends StatelessWidget {
  const _ConfigurationHint({required this.missing});

  final List<String> missing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppText.t('إعداد Firebase غير مكتمل', 'Firebase is not configured'),
                style: TextStyle(
                    color: AppColors.danger, fontWeight: FontWeight.w700, fontSize: 13.spMax),
              ),
              const SizedBox(height: 6),
              Text(
                missing.isEmpty
                    ? AppText.t(
                        'أضف القيم عبر --dart-define أو ملف assets/firebase/firebase.local.json',
                        'Pass the values with --dart-define or add '
                            'assets/firebase/firebase.local.json',
                      )
                    : missing.join('\n'),
                style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextButton(
          onPressed: () => GoRouter.of(context).refresh(),
          child: Text(AppText.t('إعادة المحاولة', 'Retry')),
        ),
      ],
    );
  }
}
