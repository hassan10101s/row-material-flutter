import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../di/service_locator.dart';
import '../../../organizations/domain/organization_repository.dart';
import '../../domain/member_repository.dart';

/// "Leave this organization" — available to **every** role, because a `lab` or
/// `viewer` member holds no `users.*` permission and would otherwise have no
/// way out.
///
/// Leaving is online-only (the roster is the authorization source) and it
/// ends the session: the organization binding is dropped remotely, the local
/// database is unbound and the member is sent back to the sign-in screen. They
/// can be invited again later.
class LeaveOrganizationSection extends StatefulWidget {
  const LeaveOrganizationSection({super.key});

  @override
  State<LeaveOrganizationSection> createState() =>
      _LeaveOrganizationSectionState();
}

class _LeaveOrganizationSectionState extends State<LeaveOrganizationSection> {
  bool _busy = false;

  /// `organizations/{orgId}.ownerUid === session.uid`.
  ///
  /// The founder cannot hand the `ownerUid` over — it is pinned immutable in
  /// `firestore.rules` — so leaving makes the organization ownerless. Resolved
  /// here rather than passed in so no caller can get it wrong.
  bool _isOwner = false;

  @override
  void initState() {
    super.initState();
    _loadOwnership();
  }

  Future<void> _loadOwnership() async {
    final gate = getIt<AuthGate>();
    try {
      final organization = await getIt<OrganizationRepository>()
          .loadOrganization();
      if (!mounted) return;
      setState(() {
        _isOwner =
            organization != null &&
            organization.ownerUid == gate.session.uid &&
            gate.session.uid.isNotEmpty;
      });
    } on Object {
      // Not knowing must not block the member from leaving; the dialog simply
      // falls back to the non-owner wording.
    }
  }

  Future<void> _leave() async {
    final gate = getIt<AuthGate>();
    final confirmed = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.logout,
      title: AppText.t('مغادرة المؤسسة', 'Leave this organization?'),
      message: _isOwner
          ? AppText.t(
              'أنت مالك هذه المؤسسة. مغادرتها ستجعل المؤسسة بلا مالك، ولن تتمكن '
                  'من العودة إلا بدعوة جديدة. يُفضّل إضافة مالك آخر أولاً.',
              'You are the owner of this organization. Leaving makes it ownerless '
                  'and you can only return with a new invite. Add another owner first.',
            )
          : AppText.t(
              'سيتم إنهاء عضويتك في هذه المؤسسة وتسجيل خروجك من التطبيق على هذا '
                  'الجهاز. يمكنك العودة لاحقاً بدعوة جديدة.',
              'Your membership will end and you will be signed out on this device. '
                  'You can rejoin later with a new invite.',
            ),
      confirmLabel: AppText.t('نعم، غادر', 'Yes, leave'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      await getIt<MemberRepository>().leave();
      // Unbinds the organization database locally and clears the session, so the
      // router lands on the sign-in screen instead of an empty workspace.
      await gate.auth.signOut();
      gate.updated();
      if (mounted) {
        AppFeedback.info(
          context,
          AppText.t('غادرت المؤسسة', 'You left the organization.'),
        );
        context.go('/login');
      }
    } on Object catch (e) {
      // `OrganizationFailure.toString()` is its own message, so the generic
      // formatter is enough - and it keeps this widget out of the data layer
      // (the architecture ratchet forbids a presentation -> data/ import).
      if (mounted) AppFeedback.errorFrom(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    final online = gate.online;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.badge_outlined,
                  size: 20.spMax,
                  color: AppColors.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    AppText.t('عضويتي', 'My membership'),
                    style: TextStyle(
                      fontSize: 15.spMax,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${AppText.t('الدور', 'Role')}: ${AppRoles.label(gate.role)}\n'
              '${AppText.t('الحالة', 'Status')}: ${_statusLabel(gate.session.status)}',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 13.spMax,
                height: 1.6,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (!online)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  AppText.t(
                    'المغادرة تتطلب اتصالاً بالإنترنت.',
                    'Leaving requires an internet connection.',
                  ),
                  style: TextStyle(
                    color: AppColors.warning,
                    fontSize: 12.spMax,
                  ),
                ),
              ),
            AppButton(
              label: AppText.t('مغادرة المؤسسة', 'Leave organization'),
              style: AppButtonStyle.danger,
              icon: const Icon(Icons.logout, size: 18),
              loading: _busy,
              onPressed: online && !_busy ? _leave : null,
            ),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(String status) => switch (status) {
    MemberStatus.active => AppText.t('نشط', 'Active'),
    MemberStatus.disabled => AppText.t('معطّل', 'Disabled'),
    _ => AppText.t('بانتظار التفعيل', 'Awaiting activation'),
  };
}
