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
import '../../../../design_system/widgets/app_support.dart';
import '../../../members/domain/member_repository.dart';

/// `awaitingActivation` destination of the auth state machine (plan §8.3 step 4).
///
/// Covers two cases:
/// 1. Member-level: `status != active` — every write is refused locally
///    (`AppSession.canWrite == false`) and remotely (Firestore rules), and no
///    company table is readable before the manager activates the account.
/// 2. Organization-level: the company itself is `suspended` (30-day trial
///    finished, waiting for manual activation by support). The member row may
///    be `active`, but the dashboard and sync never open; instead the
///    trial-expired screen below is shown with Website / Call / WhatsApp
///    contact circles (Arabic + English).
class WaitingActivationScreen extends StatelessWidget {
  const WaitingActivationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    final session = gate.session;
    if (session.isOrgSuspended) {
      return _TrialExpiredView(
        email: session.email,
        orgId: session.organizationId,
      );
    }
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
                          value: AppRoles.labelMany(session.effectiveRoles),
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

/// Trial-expired view: the company's one-time 30-day trial finished and it is
/// waiting for manual activation by support.
///
/// The company database is **not** opened and sync never starts — same as the
/// pending-activation case above. Shows the exact required bilingual message
/// plus Website / Call / WhatsApp as tappable circles reusing [AppSupport]
/// links, so phone numbers and URLs stay in one source of truth.
class _TrialExpiredView extends StatelessWidget {
  const _TrialExpiredView({required this.email, required this.orgId});

  final String email;
  final String orgId;

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
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
                  Container(
                    width: 72.r,
                    height: 72.r,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.warning.withValues(alpha: 0.15),
                    ),
                    child: Icon(
                      Icons.hourglass_bottom_outlined,
                      size: 36.r,
                      color: AppColors.warning,
                      semanticLabel: AppText.t(
                        'انتهت فترة التجربة',
                        'Trial period has ended',
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    AppText.t('انتهت فترة التجربة', 'Trial period has ended'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    AppText.t(
                      'انتهت فترة التجربة (30 يوم). يمكنك الاتصال بالدعم الآن لتفعيل مؤسستك.',
                      'Your 30-day trial has ended. Contact support now to activate your organization.',
                    ),
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
                        _Row(label: AppText.t('البريد', 'Email'), value: email),
                        _Row(
                          label: AppText.t('الشركة', 'Company'),
                          value: orgId,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  // Three beautiful contact circles: website, call, WhatsApp
                  // (authentic WhatsApp logo). Row flips automatically in RTL
                  // (Arabic), no hard-coded directions. Each circle opens the
                  // AppSupport link — shared with the support sheet.
                  const AppSupportChannels(),
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
