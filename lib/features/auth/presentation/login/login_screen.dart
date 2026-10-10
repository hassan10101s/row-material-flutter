import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../cubit/login_cubit.dart';
import '../cubit/login_state.dart';

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
                  constraints: BoxConstraints(maxWidth: 440.w),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Brand hero.
                      Container(
                        padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topRight,
                            end: Alignment.bottomLeft,
                            colors: [
                              AppColors.primary,
                              AppColors.primary.withValues(alpha: 0.78),
                            ],
                          ),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(20.r),
                          ),
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 64.r,
                              height: 64.r,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(18.r),
                                border: Border.all(
                                  color:
                                      Colors.white.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Icon(Icons.science,
                                  size: 32.r, color: Colors.white),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              AppStrings.appTitle,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 22.spMax,
                                fontWeight: FontWeight.w800,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              AppStrings.tagline,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13.spMax,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Card(
                        margin: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(20.r),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
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
                            onPressed: () => showAppAlert(
                              context,
                              title: AppText.t('الدعم', 'Support'),
                              message:
                                  'للحصول على الدعم تواصل عبر واتساب على الرقم 201213473838\nSupport via WhatsApp: +201213473838',
                              okLabel: AppText.t('حسناً', 'OK'),
                              icon: Icons.support_agent,
                            ),
                            icon: Icon(Icons.support_agent, size: 18.r),
                            label: Text(AppText.t('الدعم', 'Support')),
                          ),
                            ],
                          ),
                        ),
                      ),
                    ],
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
