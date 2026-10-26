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
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../di/service_locator.dart';
import '../../domain/member_repository.dart';

/// "Leave this organization" — available to **every** role, because a `lab` or
/// `viewer` member holds no `users.*` permission and would otherwise have no
/// way out.
///
/// Leaving is online-only (the roster is the authorization source) and it
/// ends the session: the organization binding is dropped remotely, the local
/// database is unbound and the member is sent back to the sign-in screen. They
/// can be invited again later.
///
/// The one exception is the last active owner: leaving would make the company
/// ownerless (and `ownerUid` is immutable), so an owner must first add and
/// activate another owner. The roster is re-read right before leaving so a
/// disabled/invited co-owner is never mistaken for a valid successor.
class LeaveOrganizationSection extends StatefulWidget {
  const LeaveOrganizationSection({super.key});

  @override
  State<LeaveOrganizationSection> createState() =>
      _LeaveOrganizationSectionState();
}

class _LeaveOrganizationSectionState extends State<LeaveOrganizationSection> {
  bool _busy = false;

  /// True when the signed-in member holds a company-owner role (`admin`).
  ///
  /// The founder cannot hand the `ownerUid` over — it is pinned immutable in
  /// `firestore.rules` — so ownership is only ever shared by activating a
  /// second `admin`. A company must never be left ownerless, so an owner can
  /// only leave once another owner is active.
  bool _isOwner = false;

  /// True when a *different* active owner already exists in the roster.
  bool _hasSuccessorOwner = false;

  @override
  void initState() {
    super.initState();
    _loadOwnership();
  }

  /// Resolves whether the current member is an owner and whether another
  /// active owner already exists. Returns the pair so [_leave] can re-check
  /// right before acting (and never trusts a stale `build`).
  Future<({bool isOwner, bool hasSuccessorOwner})> _loadOwnership() async {
    final gate = getIt<AuthGate>();
    var isOwner = false;
    var hasSuccessorOwner = false;
    try {
      final members = await getIt<MemberRepository>().listMembers();
      final uid = gate.session.uid;
      final memberId = gate.session.memberId;
      Member? self;
      for (final member in members) {
        if ((memberId.isNotEmpty && member.id == memberId) ||
            (uid.isNotEmpty && member.uid == uid)) {
          self = member;
          break;
        }
      }
      final current = self;
      if (current != null) {
        isOwner = current.role == AppRoles.admin;
        hasSuccessorOwner = members.any(
          (member) =>
              member.isActive &&
              member.role == AppRoles.admin &&
              member.id != current.id,
        );
      }
    } on Object {
      // Not knowing must not block the member from leaving.
    }
    if (mounted) {
      setState(() {
        _isOwner = isOwner;
        _hasSuccessorOwner = hasSuccessorOwner;
      });
    }
    return (isOwner: isOwner, hasSuccessorOwner: hasSuccessorOwner);
  }

  Future<void> _leave() async {
    final gate = getIt<AuthGate>();
    // Re-read the roster so a co-owner who was disabled (or an owner who was
    // only invited) after the last build cannot be mistaken for a successor.
    final ownership = await _loadOwnership();
    if (!mounted) return;
    if (ownership.isOwner && !ownership.hasSuccessorOwner) {
      AppFeedback.error(
        context,
        AppText.t(
          'لا يمكن مغادرة الشركة إلا بعد إضافة مالك آخر وتفعيله. '
              'استخدم «دعوة مالك آخر» ثم فعّل الدعوة أولاً.',
          'You cannot leave the company until another owner is added and '
              'activated. Use "Invite co-owner" first, then activate it.',
        ),
      );
      return;
    }
    final confirmed = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.logout,
      title: AppText.t('مغادرة الشركة', 'Leave this company?'),
      message: _isOwner
          ? AppText.t(
              'أنت مالك هذه الشركة، وسيستمر المالك الآخر النشط في إدارتها بعد '
                  'مغادرتك. سيتم تسجيل خروجك من التطبيق على هذا الجهاز، ويمكنك '
                  'العودة لاحقاً بدعوة جديدة.',
              'You are the owner of this organization. The other active owner will '
                  'keep managing it after you leave. You will be signed out on this '
                  'device and can rejoin later with a new invite.',
            )
          : AppText.t(
              'سيتم إنهاء عضويتك في هذه الشركة وتسجيل خروجك من التطبيق على هذا '
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
          AppText.t('غادرت الشركة', 'You left the company.'),
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
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
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
            '${AppText.t('الأدوار', 'Roles')}: ${AppRoles.labelMany(gate.session.effectiveRoles)}\n'
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
                style: TextStyle(color: AppColors.warning, fontSize: 12.spMax),
              ),
            )
          else if (_isOwner && !_hasSuccessorOwner)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                AppText.t(
                  'لا يمكن مغادرة الشركة إلا بعد إضافة مالك آخر وتفعيله. '
                      'استخدم «دعوة مالك آخر» ثم فعّل الدعوة أولاً.',
                  'You cannot leave the company until another owner is added '
                      'and activated. Use "Invite co-owner" first, then '
                      'activate it.',
                ),
                style: TextStyle(color: AppColors.warning, fontSize: 12.spMax),
              ),
            ),
          AppButton(
            label: AppText.t('مغادرة الشركة', 'Leave company'),
            style: AppButtonStyle.danger,
            icon: const Icon(Icons.logout, size: 18),
            loading: _busy,
            onPressed: online && !_busy && !_ownerWithoutSuccessor
                ? _leave
                : null,
          ),
        ],
      ),
    );
  }

  /// An owner may not leave while no other active owner exists.
  bool get _ownerWithoutSuccessor => _isOwner && !_hasSuccessorOwner;

  static String _statusLabel(String status) => switch (status) {
    MemberStatus.active => AppText.t('نشط', 'Active'),
    MemberStatus.disabled => AppText.t('معطّل', 'Disabled'),
    _ => AppText.t('بانتظار التفعيل', 'Awaiting activation'),
  };
}
