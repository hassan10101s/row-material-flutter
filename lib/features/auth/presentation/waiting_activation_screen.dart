import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../app/auth_gate.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_strings.dart';
import '../../../di/service_locator.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';

/// `awaitingActivation` destination of the auth state machine (plan §8.3 step 4).
///
/// The organization database **is** already open here, so the device is ready
/// for offline work, but `status != active` means every write is refused
/// locally (`AppSession.canWrite == false`) and remotely (Firestore rules).
class WaitingActivationScreen extends StatelessWidget {
  const WaitingActivationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    final session = gate.session;
    final status = session.isDisabled
        ? AppText.t('حسابك معطّل من قبل مدير المؤسسة.',
            'Your account was disabled by the organization admin.')
        : AppText.t('حسابك في انتظار التفعيل من مدير المؤسسة.',
            'Your account is waiting for activation by the organization admin.');
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460.w),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.hourglass_top, size: 44.r, color: AppColors.warning),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      AppText.t(
                          'الحساب بانتظار التفعيل', 'Account pending activation'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      status,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12.r),
                      ),
                      child: Column(
                        children: [
                          _Row(
                              label: AppText.t('البريد', 'Email'),
                              value: session.email),
                          _Row(
                              label: AppText.t('المؤسسة', 'Organization'),
                              value: session.organizationId),
                          _Row(
                              label: AppText.t('الدور', 'Role'),
                              value: AppRoles.label(session.role)),
                          _Row(
                              label: AppText.t('الحالة', 'Status'),
                              value: session.status),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      AppText.t(
                          'يمكنك قراءة البيانات المحفوظة على هذا الجهاز. الكتابة تبدأ فور تفعيل الحساب من مدير المؤسسة.',
                          'You can read the data saved on this device. Writing starts once the organization admin activates the account.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: 'تحديث الحالة',
                      expanded: true,
                      onPressed: () async {
                        await gate.auth.resolveProfile();
                        gate.updated();
                      },
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: () async {
                        await gate.auth.signOut();
                        gate.updated();
                        if (context.mounted) context.go('/login');
                      },
                      child: Text(AppText.t('تسجيل الخروج', 'Sign out')),
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

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax)),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.spMax, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
