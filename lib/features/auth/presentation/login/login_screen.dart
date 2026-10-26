import '../../../../design_system/widgets/app_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_support.dart';
import '../cubit/login_cubit.dart';
import '../cubit/login_state.dart';

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
            body: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 800) {
                  return _MobileLoginView(state: state, cubit: cubit);
                }
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.page),
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
                                      color: Colors.white.withValues(
                                        alpha: 0.35,
                                      ),
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.science,
                                    size: 32.r,
                                    color: Colors.white,
                                  ),
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
                                const SizedBox(height: AppSpacing.xs),
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
                          AppCard(
                            margin: EdgeInsets.zero,
                            padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (state.needsConfiguration)
                                  const _ConfigurationHint()
                                else ...[
                                  _GoogleButton(
                                    busy: state.busy,
                                    onPressed: cubit.signIn,
                                  ),
                                  const SizedBox(height: AppSpacing.sm),
                                  AppButton(
                                    label: AppText.t(
                                      'الدخول بالبريد وكلمة المرور',
                                      'Sign in with email',
                                    ),
                                    icon: const Icon(Icons.email_outlined),
                                    onPressed: state.busy
                                        ? null
                                        : () => _openEmailDialog(
                                            context,
                                            create: false,
                                          ),
                                    style: AppButtonStyle.secondary,
                                    expanded: true,
                                  ),
                                  const SizedBox(height: AppSpacing.xs),
                                  AppButton(
                                    label: AppText.t(
                                      'إنشاء كلمة مرور للتطبيق',
                                      'Create an app password',
                                    ),
                                    icon: const Icon(
                                      Icons.key_outlined,
                                      size: 18,
                                    ),
                                    onPressed: state.busy
                                        ? null
                                        : () => _openEmailDialog(
                                            context,
                                            create: true,
                                          ),
                                    style: AppButtonStyle.ghost,
                                    expanded: true,
                                  ),
                                ],
                                const SizedBox(height: AppSpacing.md),
                                Text(
                                  AppText.t(
                                    'يمكن ربط الحساب بشركة واحدة. الأجهزة '
                                        'تعمل بدون إنترنت لكل البيانات المحفوظة محلياً.',
                                    'A Google account is linked to one company. '
                                        'The app works offline with locally stored data.',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 12.spMax,
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                // Single elegant support entry at the bottom —
                                // company + channels live in the sheet.
                                const AppSupportButton(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _openEmailDialog(
    BuildContext context, {
    required bool create,
  }) async {
    // The cubit is scoped to the login page route; the dialog opens on a
    // new route above it, so re-provide the same instance into the dialog.
    final cubit = context.read<LoginCubit>();
    await showAppDialog<void>(
      context,
      builder: (_) => BlocProvider.value(
        value: cubit,
        child: _EmailPasswordDialog(create: create),
      ),
    );
  }
}

class _MobileLoginView extends StatefulWidget {
  const _MobileLoginView({required this.state, required this.cubit});

  final LoginState state;
  final LoginCubit cubit;

  @override
  State<_MobileLoginView> createState() => _MobileLoginViewState();
}

class _MobileLoginViewState extends State<_MobileLoginView> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      AppFeedback.error(
        context,
        AppText.t('أدخل البريد وكلمة المرور.', 'Enter email and password.'),
      );
      return;
    }
    await widget.cubit.signInWithEmail(
      email: _email.text.trim(),
      password: _password.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight:
              MediaQuery.sizeOf(context).height -
              MediaQuery.paddingOf(context).vertical,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 42, 24, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: .22),
                        blurRadius: 22,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.science_outlined,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                AppStrings.appTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 25.spMax,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textStrong,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                AppText.t('سجّل دخولك إلى حسابك', 'Sign in to your account'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 14.spMax,
                ),
              ),
              const SizedBox(height: AppSpacing.xxxl),
              if (state.needsConfiguration)
                const _ConfigurationHint()
              else ...[
                AppField(
                  label: AppText.t('البريد الإلكتروني', 'Email'),
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofocus: true,
                ),
                const SizedBox(height: 14),
                AppField(
                  label: AppText.t('كلمة المرور', 'Password'),
                  controller: _password,
                  obscure: true,
                  onFieldSubmitted: (_) => _signIn(),
                ),
                if (state.error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    state.error!,
                    style: TextStyle(
                      color: AppColors.danger,
                      fontSize: 12.spMax,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                AppButton(
                  label: state.busy
                      ? AppText.t('جارٍ الدخول…', 'Signing in…')
                      : AppText.t('تسجيل الدخول', 'Sign in'),
                  expanded: true,
                  loading: state.busy,
                  icon: const Icon(Icons.login),
                  onPressed: state.busy ? null : _signIn,
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: AppText.t(
                    'المتابعة باستخدام Google',
                    'Continue with Google',
                  ),
                  icon: const _GoogleLogo(),
                  onPressed: state.busy ? null : widget.cubit.signIn,
                  style: AppButtonStyle.secondary,
                  expanded: true,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: AppText.t(
                    'إنشاء كلمة مرور للتطبيق',
                    'Create an app password',
                  ),
                  onPressed: state.busy
                      ? null
                      : () => showAppDialog<void>(
                          context,
                          // Same scoping fix as [_openEmailDialog]: the dialog
                          // route sits above the page provider.
                          builder: (_) => BlocProvider.value(
                            value: widget.cubit,
                            child: const _EmailPasswordDialog(create: true),
                          ),
                        ),
                  style: AppButtonStyle.ghost,
                  expanded: true,
                ),
              ],
              const SizedBox(height: 26),
              // Single elegant support entry at the bottom.
              const AppSupportButton(),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmailPasswordDialog extends StatefulWidget {
  const _EmailPasswordDialog({required this.create});

  final bool create;

  @override
  State<_EmailPasswordDialog> createState() => _EmailPasswordDialogState();
}

class _EmailPasswordDialogState extends State<_EmailPasswordDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@')) {
      _showError(
        AppText.t(
          'أدخل بريدًا إلكترونيًا صحيحًا.',
          'Enter a valid email address.',
        ),
      );
      return;
    }
    if (password.length < 6) {
      _showError(
        AppText.t(
          'كلمة المرور يجب أن تكون 6 أحرف على الأقل.',
          'Password must be at least 6 characters.',
        ),
      );
      return;
    }
    if (widget.create && password != _confirmation.text) {
      _showError(
        AppText.t('تأكيد كلمة المرور غير مطابق.', 'Passwords do not match.'),
      );
      return;
    }
    final cubit = context.read<LoginCubit>();
    final ok = widget.create
        ? await cubit.createPasswordAccount(email: email, password: password)
        : await cubit.signInWithEmail(email: email, password: password);
    if (ok && mounted) Navigator.of(context).pop();
  }

  void _showError(String message) {
    AppFeedback.error(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LoginCubit>().state;
    // scrollable: the whole dialog scrolls on short windows / open keyboard
    // instead of overflowing (no nested scroll view inside).
    return AppDialog(
      icon: Icons.lock_outline,
      title: widget.create
          ? AppText.t('إنشاء كلمة مرور للتطبيق', 'Create an app password')
          : AppText.t('تسجيل الدخول بالبريد', 'Sign in with email'),
      actions: [
        AppButton(
          label: AppText.t('إلغاء', 'Cancel'),
          onPressed: state.busy ? null : () => Navigator.of(context).pop(),
          style: AppButtonStyle.ghost,
        ),
        AppButton(
          label: widget.create
              ? AppText.t('إنشاء', 'Create')
              : AppText.t('دخول', 'Sign in'),
          icon: const Icon(Icons.check),
          loading: state.busy,
          onPressed: state.busy ? null : _submit,
        ),
      ],
      child: BlocBuilder<LoginCubit, LoginState>(
        builder: (context, state) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.create
                  ? AppText.t(
                      'سيتم حفظ الحساب ويمكن استخدامه لاحقًا على أي جهاز.',
                      'The account is saved and can be used later on any device.',
                    )
                  : AppText.t(
                      'استخدم البريد وكلمة المرور المحفوظين لحسابك.',
                      'Use the email and password saved for your account.',
                    ),
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
            const SizedBox(height: AppSpacing.md),
            AppField(
              label: AppText.t('البريد الإلكتروني', 'Email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppField(
              label: AppText.t('كلمة المرور', 'Password'),
              controller: _password,
              obscure: true,
            ),
            if (widget.create) ...[
              const SizedBox(height: AppSpacing.sm),
              AppField(
                label: AppText.t('تأكيد كلمة المرور', 'Confirm password'),
                controller: _confirmation,
                obscure: true,
              ),
            ],
            if (state.error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                state.error!,
                style: TextStyle(color: AppColors.danger, fontSize: 12.spMax),
              ),
            ],
          ],
        ),
      ),
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
      icon: const _GoogleLogo(),
      onPressed: busy ? null : () => onPressed(),
    );
  }
}

class _GoogleLogo extends StatelessWidget {
  const _GoogleLogo();

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/images/google_g.svg',
    width: 20,
    height: 20,
    semanticsLabel: 'Google',
  );
}

/// Shown instead of the sign-in options when the remote service is unavailable.
class _ConfigurationHint extends StatelessWidget {
  const _ConfigurationHint();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppText.t('الخدمة غير متاحة حاليًا', 'Service unavailable'),
                style: TextStyle(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.spMax,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                AppText.t(
                  'تعذر الاتصال بالخدمة. تحقق من اتصالك بالإنترنت ثم أعد المحاولة.',
                  'Could not reach the service. Check your internet connection and try again.',
                ),
                style: TextStyle(
                  fontSize: 12.spMax,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton(
          label: AppText.t('إعادة المحاولة', 'Retry'),
          onPressed: () => GoRouter.of(context).refresh(),
          style: AppButtonStyle.ghost,
          expanded: true,
        ),
      ],
    );
  }
}
