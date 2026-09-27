import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_field.dart';
import 'cubit/create_organization_cubit.dart';
import 'cubit/create_organization_state.dart';

/// `noProfile` destination of the auth state machine (plan §8.5).
///
/// Two paths:
/// * **create** — the founder names the organization; the app writes
///   `organizations/{orgId}` + `meta` + `members/member_<uid>` + `users/{uid}`.
/// * **invite** — an invited employee types the organization id and claims the
///   invitation stored at `invites/{b64url(lower(email))}`.
class CreateOrganizationScreen extends StatefulWidget {
  const CreateOrganizationScreen({super.key});

  @override
  State<CreateOrganizationScreen> createState() => _CreateOrganizationScreenState();
}

class _CreateOrganizationScreenState extends State<CreateOrganizationScreen> {
  final _name = TextEditingController();
  final _inviteCode = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _inviteCode.dispose();
    super.dispose();
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
                        Icon(Icons.apartment, size: 44.r, color: AppColors.primary),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          isCreate ? 'إنشاء مؤسسة جديدة' : 'لدي دعوة انضمام',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          isCreate
                              ? 'أنشئ مؤسسة وسيتم ربط كل عيّناتها ومختبراتها وحساباتها بها.'
                              : 'أدخل كود المؤسسة الذي أرسله لك مدير المؤسسة.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        if (isCreate)
                          AppField(
                            label: 'اسم المؤسسة',
                            controller: _name,
                            hint: 'اسم الشركة أو المصنع',
                            onChanged: cubit.setName,
                          )
                        else
                          AppField(
                            label: 'كود المؤسسة',
                            controller: _inviteCode,
                            hint: 'org_…',
                            onChanged: cubit.setInviteCode,
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
                          label: isCreate ? 'إنشاء المؤسسة' : 'انضمام بالدعوة',
                          expanded: true,
                          loading: state.busy,
                          onPressed: state.busy ? null : cubit.submit,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        TextButton(
                          onPressed: state.busy
                              ? null
                              : () => isCreate ? cubit.useInvite() : cubit.useCreate(),
                          child: Text(isCreate ? 'لدي دعوة انضمام' : 'إنشاء مؤسسة جديدة'),
                        ),
                      ],
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
