import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../di/service_locator.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../members/domain/member_repository.dart';

/// `awaitingActivation` destination of the auth state machine (plan §8.3 step 4).
///
/// The organization database is **not** opened here and the sync cycle never
/// starts (plan §8): `status != active` means every write is refused locally
/// (`AppSession.canWrite == false`) and remotely (Firestore rules), and no
/// company table is readable before the manager activates the account.
class WaitingActivationScreen extends StatelessWidget {
  const WaitingActivationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    final session = gate.session;
    final status = session.isDisabled
        ? AppText.t(
            'حسابك معطّل من قبل مدير الشركة.',
            'Your account was disabled by the company admin.',
          )
        : session.isPendingActivation
            ? AppText.t(
                'سجّلت دخولك بنجاح. حسابك في انتظار التفعيل من مدير الشركة.',
                'You signed in successfully. Your account is waiting for activation by the company admin.',
              )
            : AppText.t(
                'حسابك في انتظار التفعيل من مدير الشركة.',
                'Your account is waiting for activation by the company admin.',
              );
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.page),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460.w),
            child: AppCard(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                    Icon(
                      Icons.hourglass_top,
                      size: 44.r,
                      color: AppColors.warning,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      AppText.t(
                        'الحساب بانتظار التفعيل',
                        'Account pending activation',
                      ),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13.spMax,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                      ),
                      child: Column(
                        children: [
                          _Row(
                            label: AppText.t('البريد', 'Email'),
                            value: session.email,
                          ),
                          _Row(
                            label: AppText.t('الشركة', 'Company'),
                            value: session.organizationId,
                          ),
                          _Row(
                            label: AppText.t('الدور', 'Role'),
                            value: AppRoles.label(session.role),
                          ),
                          _Row(
                            label: AppText.t('الحالة', 'Status'),
                            value: session.status,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      AppText.t(
                        'لا يمكنك رؤية بيانات الشركة أو الكتابة فيها قبل التفعيل، ولم تبدأ المزامنة بعد.',
                        'You cannot see or write company data before activation, and sync has not started.',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.spMax,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: AppText.t('تحديث الحالة', 'Refresh status'),
                      expanded: true,
                      onPressed: () async {
                        await gate.auth.resolveProfile();
                        gate.updated();
                      },
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppButton(
                      label: AppText.t('تسجيل الخروج', 'Sign out'),
                      onPressed: () async {
                        await gate.auth.signOut();
                        gate.updated();
                        if (context.mounted) context.go('/login');
                      },
                      style: AppButtonStyle.ghost,
                      expanded: true,
                    ),
                    AppButton(
                      label: AppText.t(
                        'مغادرة الشركة والعودة',
                        'Leave the company',
                      ),
                      onPressed: () async {
                        // Leave the pending company so this account returns to
                        // `no_company` and may create a trial company or join
                        // with a new invite (plan §3). Best-effort: a failing
                        // remote leave still signs out locally below.
                        try {
                          await getIt<MemberRepository>().leave();
                        } on Object {
                          // Remote leave failed (offline, revoked): the local
                          // sign-out below must still happen.
                        }
                        await gate.auth.signOut();
                        gate.updated();
                        if (context.mounted) context.go('/login');
                      },
                      style: AppButtonStyle.ghost,
                      expanded: true,
                    ),
                  ],
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
          Text(
            label,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
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
