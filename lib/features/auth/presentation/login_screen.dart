import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../di/service_locator.dart';
import '../../../router/app_router.dart';
import '../../auth/data/auth_repo.dart';

/// Login screen (port of Web LoginScreen + controller.auth_login).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;
  String? _error;
  var _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await getIt<AuthRepo>().login(
        username: _username.text.trim(),
        password: _password.text,
      );
      getIt<AuthGate>().updated();
      if (mounted) context.go(AppRoutes.dashboard);
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.science, size: 48, color: AppColors.primary),
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
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13),
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
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.danger, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: AppStrings.login,
                      expanded: true,
                      loading: _busy,
                      onPressed: _busy ? null : _submit,
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
                                child: const Text('حسناً | OK')),
                          ],
                        ),
                      ),
                      icon: const Icon(Icons.support_agent, size: 18),
                      label: const Text('الدعم | Support'),
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