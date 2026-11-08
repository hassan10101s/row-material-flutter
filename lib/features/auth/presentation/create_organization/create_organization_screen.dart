import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../cubit/create_organization_cubit.dart';
import '../cubit/create_organization_state.dart';
import '../../../../design_system/widgets/app_card.dart';

/// `noProfile` destination of the auth state machine (plan §8.5).
///
/// Two paths:
/// * **create** — the founder names the organization; the app writes
///   organization, protocol, zero counter, member and profile atomically.
/// * **invite** — an invited employee types the organization id and claims the
///   invitation stored at `invites/{b64url(lower(email))}`.
class CreateOrganizationScreen extends StatefulWidget {
  const CreateOrganizationScreen({super.key});

  @override
  State<CreateOrganizationScreen> createState() =>
      _CreateOrganizationScreenState();
}

class _CreateOrganizationScreenState extends State<CreateOrganizationScreen> {
  final _name = TextEditingController();
  final _inviteCode = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Probe `email_verified` once so the verification banner appears before
    // the doomed submit attempt (the server refuses unverified genesis).
    final cubit = context.read<CreateOrganizationCubit>();
    Future<void>.microtask(cubit.loadEmailVerified);
  }

  @override
  void dispose() {
    _name.dispose();
    _inviteCode.dispose();
    super.dispose();
  }

  /// Verification gate banner: the Firestore rules refuse company creation
  /// and invite reads for an unverified e-mail, so unverified accounts see
  /// the resend + re-check actions instead of a server `permission-denied`.
  Widget _verificationBanner(
    BuildContext context,
    CreateOrganizationCubit cubit,
    CreateOrganizationState state,
  ) {
    final border = AppColors.warning.withValues(alpha: 0.30);
    final fill = AppColors.warning.withValues(alpha: 0.08);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.mark_email_unread_outlined,
                size: 18.r,
                color: AppColors.warning,
              ),
              SizedBox(width: 8.w),
              Expanded(
                child: Text(
                  AppText.t(
                    'بريدك غير موثّق. افتح بريدك الإلكتروني واضغط رابط التوثيق المرسل عند إنشاء الحساب.',
                    'Your email is not verified. Open your inbox and click the verification link sent when the account was created.',
                  ),
                  style: TextStyle(
                    color: AppColors.warning,
                    fontSize: 12.spMax,
                  ),
                ),
              ),
            ],
          ),
          if (state.notice != null) ...[
            SizedBox(height: 6.h),
            Text(
              state.notice!,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
          ],
          SizedBox(height: 10.h),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: AppText.t('إعادة إرسال الرابط', 'Resend the link'),
                  small: true,
                  style: AppButtonStyle.ghost,
                  loading: state.verificationBusy,
                  onPressed: state.verificationBusy
                      ? null
                      : cubit.resendVerificationEmail,
                ),
              ),
              SizedBox(width: 8.w),
              Expanded(
                child: AppButton(
                  label: AppText.t('تحققت الآن', 'I verified now'),
                  small: true,
                  loading: state.verificationBusy,
                  onPressed: state.verificationBusy
                      ? null
                      : cubit.refreshEmailVerified,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<CreateOrganizationCubit, CreateOrganizationState>(
      // Fire once on every completed attempt: error states are ignored, the
      // router guard then redirects to the dashboard (or back to /login when
      // Firebase has no profile yet).
      listenWhen: (previous, current) =>
          previous.busy && !current.busy && current.error == null,
      listener: (context, state) {
        context.go('/login');
      },
      builder: (context, state) {
        final cubit = context.read<CreateOrganizationCubit>();
        final isCreate = state.mode == CreateMode.create;
        return AppErrorFeedback<
          CreateOrganizationCubit,
          CreateOrganizationState
        >(
          selector: (s) => s.error,
          child: Scaffold(
            backgroundColor: AppColors.background,
            body: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 460.w),
                  child: AppCard(
                    padding: EdgeInsets.zero,
                    enableHover: false,
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(
                            Icons.apartment,
                            size: 44.r,
                            color: AppColors.primary,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            isCreate
                                ? AppText.t(
                                    'إنشاء شركة جديدة',
                                    'Create a new company',
                                  )
                                : AppText.t(
                                    'لدي دعوة انضمام',
                                    'I have an invite',
                                  ),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            isCreate
                                ? AppText.t(
                                    'أنشئ مؤسستك وستصبح مالكها بكامل الصلاحيات. تبدأ المؤسسة فعّالة، وترتبط بها الفحوص وأعمال المعمل والحسابات.',
                                    'Create your organization as its full owner. It starts active, with its inspections, lab work and accounts linked to it.',
                                  )
                                : AppText.t(
                                    'أدخل كود الشركة الذي أرسله لك مدير الشركة.',
                                    'Enter the company code your manager sent you.',
                                  ),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13.spMax,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          if (state.emailVerified == false) ...[
                            _verificationBanner(context, cubit, state),
                            SizedBox(height: AppSpacing.lg),
                          ],
                          if (isCreate)
                            AppField(
                              label: AppText.t('اسم الشركة', 'Company name'),
                              controller: _name,
                              hint: AppText.t(
                                'اسم الشركة أو المصنع',
                                'Company or factory name',
                              ),
                              onChanged: cubit.setName,
                            )
                          else
                            AppField(
                              label: AppText.t('كود الشركة', 'Company code'),
                              controller: _inviteCode,
                              hint: AppText.t('org_…', 'org_…'),
                              onChanged: cubit.setInviteCode,
                            ),
                          const SizedBox(height: AppSpacing.lg),
                          AppButton(
                            label: isCreate
                                ? AppText.t('إنشاء الشركة', 'Create company')
                                : AppText.t(
                                    'انضمام بالدعوة',
                                    'Join with invite',
                                  ),
                            expanded: true,
                            loading: state.busy,
                            onPressed: state.busy ? null : cubit.submit,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          AppButton(
                            onPressed: state.busy
                                ? null
                                : () => isCreate
                                      ? cubit.useInvite()
                                      : cubit.useCreate(),
                            label: isCreate
                                ? AppText.t(
                                    'لدي دعوة انضمام',
                                    'I have an invite',
                                  )
                                : AppText.t(
                                    'إنشاء شركة جديدة',
                                    'Create a new company',
                                  ),
                            style: AppButtonStyle.ghost,
                            small: true,
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
