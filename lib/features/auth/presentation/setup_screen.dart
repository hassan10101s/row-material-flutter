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
import '../../auth/domain/user.dart';
import 'cubit/setup_cubit.dart';

/// First-run setup screen (port of Web SetupScreen + bootstrap_create_admin).
/// Creates the first Administrator and records the usage-expiry license date.
class SetupScreen extends StatefulWidget {
  final User? initialDeveloper;
  const SetupScreen({super.key, this.initialDeveloper});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _fullName = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  DateTime? _expiryDate;

  @override
  void dispose() {
    _fullName.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _pickExpiryDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 365)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked != null) setState(() => _expiryDate = picked);
  }

  String get _expiryIso {
    final d = _expiryDate;
    if (d == null) return '';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _submit() async {
    final fullName = _fullName.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    if (fullName.isEmpty) return _fail(AppText.t('الاسم الكامل مطلوب', 'Full name is required'));
    if (username.isEmpty) return _fail(AppText.t('اسم المستخدم مطلوب', 'Username is required'));
    if (password.isEmpty) return _fail(AppText.t('كلمة المرور مطلوبة', 'Password is required'));
    if (password != _confirm.text) return _fail(AppText.t('كلمتا المرور غير متطابقتين', 'Passwords do not match'));
    if (_expiryDate == null) return _fail(AppText.t('تاريخ انتهاء الاستخدام مطلوب', 'Usage expiry date is required'));

    final ok = await context.read<SetupCubit>().createAdmin(
          username: username,
          fullName: fullName,
          password: password,
          role: 'Admin',
          usageExpiryDate: _expiryIso,
        );
    if (!mounted || !ok) return;
    context.go(AppRoutes.dashboard);
  }

  void _fail(String message) {
    if (!mounted) return;
    context.read<SetupCubit>().fail(message);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SetupCubit>().state;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 440.w),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.science, size: 44.r, color: AppColors.primary),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'إعداد النظام | System Setup',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'أنشئ حساب المسؤول الأول وسيتم استيراد بيانات المراجع من Reference.xlsx تلقائياً.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppField(
                      label: 'الاسم الكامل | Full Name',
                      controller: _fullName,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppField(
                      label: 'اسم المستخدم | Username',
                      controller: _username,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppField(
                      label: 'كلمة المرور | Password',
                      controller: _password,
                      obscure: true,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppField(
                      label: 'تأكيد كلمة المرور | Confirm Password',
                      controller: _confirm,
                      obscure: true,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    OutlinedButton.icon(
                      onPressed: _pickExpiryDate,
                      icon: const Icon(Icons.event),
                      label: Text(_expiryDate == null
                          ? AppText.t('تاريخ انتهاء الاستخدام | Usage Expiry …', 'Usage expiry date …')
                          : '${AppText.t('تاريخ انتهاء الاستخدام', 'Usage expiry')}: $_expiryIso'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textStrong,
                        alignment: AlignmentDirectional.centerStart,
                      ),
                    ),
                    if (state.error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        state.error!,
                        style: TextStyle(color: AppColors.danger, fontSize: 13.spMax),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: AppText.t('إنشاء الحساب', 'Create Account'),
                      expanded: true,
                      loading: state.busy,
                      onPressed: state.busy ? null : _submit,
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