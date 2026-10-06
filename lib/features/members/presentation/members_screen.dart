import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../app/auth_gate.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_strings.dart';
import '../../../di/service_locator.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../organizations/domain/organization_repository.dart';
import '../domain/member_repository.dart';
import 'leave_organization_section.dart';

/// MembersScreen (plan P3.4): list + Add(email, role) + Activate + Change role
/// + Disable. Every action is online-only; the guard message explains why a
/// button is disabled instead of failing after a click.
class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key, this.embedded = false});

  /// Renders without its own page padding, for hosting inside the Settings tabs.
  final bool embedded;

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  MemberRepository? _repo;
  List<Member> _members = const [];
  String? _error;
  bool _busy = false;
  String _role = AppRoles.lab;

  @override
  void initState() {
    super.initState();
    _repo = getIt<MemberRepository>();
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final members = await _repo!.listMembers();
      if (mounted) setState(() => _members = members);
    } on OrganizationFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } on OrganizationFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
      if (mounted) AppFeedback.error(context, e.message);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
      if (mounted) AppFeedback.errorFrom(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Sends an invite for [role]. The owner uses the co-owner shortcut to make
  /// a second administrator, which is how ownership is shared: `ownerUid` is
  /// immutable in the rules, so a second `admin` is the supported form of
  /// co-ownership.
  Future<void> _invite(String role) async {
    final email = _email.text.trim();
    await _run(() => _repo!.invite(email: email, role: role));
    if (mounted) {
      _email.clear();
      final message = role == AppRoles.admin
          ? AppText.t(
              'تم إرسال دعوة مالك آخر — فعّلها ليتمكن من إدارة المؤسسة.',
              'Co-owner invite sent — activate it to grant organization management.',
            )
          : AppText.t('تم إرسال الدعوة', 'Invite sent.');
      AppFeedback.success(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    final canInvite = gate.canWrite(Permission.usersCreate);
    final canUpdate = gate.canWrite(Permission.usersUpdate);
    final canDisable = gate.canWrite(Permission.usersDisable);
    bool isSelf(String id) => id == gate.session.memberId;

    return ListView(
      padding: widget.embedded
          ? EdgeInsets.zero
          : const EdgeInsets.all(AppSpacing.page),
      children: [
        Row(
          children: [
            Text(
              'أعضاء المؤسسة',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'تحديث',
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (!canInvite)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Text(
              'الدعوة والتعديل يتطلبان اتصالاً بالإنترنت وجلسة صالحة '
              '(الدور الحالي: ${AppRoles.label(gate.role)}).',
              style: TextStyle(color: AppColors.warning, fontSize: 12.spMax),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: AppColors.danger, fontSize: 13.spMax),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (_busy && _members.isEmpty)
          const Center(child: CircularProgressIndicator()),
        Card(
          child: Column(
            children: [
              for (final m in _members)
                _MemberTile(
                  member: m,
                  isSelf: isSelf(m.id),
                  canUpdate: canUpdate,
                  canDisable: canDisable,
                  onActivate: () => _run(
                    () => _repo!.setStatus(memberId: m.id, status: 'active'),
                  ),
                  onDisable: () => _run(
                    () => _repo!.setStatus(memberId: m.id, status: 'disabled'),
                  ),
                  onRole: (role) =>
                      _run(() => _repo!.changeRole(memberId: m.id, role: role)),
                  onRemove: () =>
                      _run(() => _repo!.removeMember(memberId: m.id)),
                ),
              if (_members.isEmpty && !_busy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('لا يوجد أعضاء بعد — أضف أول دعوة.'),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'إضافة عضو',
          style: TextStyle(fontSize: 15.spMax, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 260.w,
              child: AppField(
                label: 'البريد الإلكتروني',
                controller: _email,
                hint: 'name@company.com',
              ),
            ),
            SizedBox(
              width: 190.w,
              child: DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(
                  labelText: 'الدور',
                  isDense: true,
                ),
                items: [
                  for (final role in AppRoles.all)
                    DropdownMenuItem(
                      value: role,
                      child: Text(AppRoles.label(role)),
                    ),
                ],
                onChanged: (v) => setState(() => _role = v ?? AppRoles.lab),
              ),
            ),
            SizedBox(
              height: 42.h,
              child: AppButton(
                label: 'إرسال دعوة',
                small: true,
                loading: _busy,
                onPressed: canInvite && !_busy ? () => _invite(_role) : null,
              ),
            ),
            SizedBox(
              height: 42.h,
              child: AppButton(
                label: AppText.t('دعوة مالك آخر', 'Invite co-owner'),
                small: true,
                style: AppButtonStyle.secondary,
                icon: const Icon(Icons.workspace_premium_outlined, size: 18),
                loading: _busy,
                onPressed: canInvite && !_busy
                    ? () => _invite(AppRoles.admin)
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          AppText.t(
            '«دعوة مالك آخر» ترسل الدعوة بدور مدير المؤسسة، فيحصل على نفس صلاحياتك '
                'على الأعضاء. يمكن إضافة أكثر من مالك.',
            '"Invite co-owner" sends the invite with the organization-owner role, so '
                'they get the same member-management rights as you. More than one is '
                'allowed.',
          ),
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
        const SizedBox(height: AppSpacing.lg),
        const LeaveOrganizationSection(),
        const SizedBox(height: AppSpacing.md),
        Text(
          'بعد إرسال الدعوة يسجّل العضو الدخول بحسابه في Google بنفس البريد، ثم '
          'يظهر له "بانتظار التفعيل" حتى تفعّله.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isSelf,
    required this.canUpdate,
    required this.canDisable,
    required this.onActivate,
    required this.onDisable,
    required this.onRole,
    required this.onRemove,
  });

  final Member member;
  final bool isSelf;
  final bool canUpdate;
  final bool canDisable;
  final VoidCallback onActivate;
  final VoidCallback onDisable;
  final ValueChanged<String> onRole;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final color = switch (member.status) {
      'active' => AppColors.success,
      'invited' => AppColors.warning,
      _ => AppColors.textMuted,
    };
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: member.isActive
            ? AppColors.primary
            : AppColors.borderMuted,
        child: Text(
          member.email.isEmpty
              ? '?'
              : member.email.substring(0, 1).toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Text('${member.label}${isSelf ? ' (أنت)' : ''}'),
      subtitle: Text(
        '${member.email} · ${AppRoles.label(member.role)} · ${_statusLabel(member.status)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsetsDirectional.only(end: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              member.status,
              style: TextStyle(fontSize: 11.spMax, color: color),
            ),
          ),
          if (canUpdate && member.isInvited)
            IconButton(
              tooltip: 'تفعيل',
              onPressed: onActivate,
              icon: const Icon(Icons.check_circle_outline, size: 20),
            ),
          if (canUpdate && member.isActive && !isSelf)
            PopupMenuButton<String>(
              tooltip: 'تغيير الدور',
              onSelected: onRole,
              itemBuilder: (_) => [
                for (final role in AppRoles.all)
                  PopupMenuItem(value: role, child: Text(AppRoles.label(role))),
              ],
              icon: const Icon(Icons.manage_accounts_outlined, size: 20),
            ),
          if (canDisable && member.isActive && !isSelf)
            IconButton(
              tooltip: 'تعطيل',
              onPressed: onDisable,
              icon: const Icon(Icons.block, size: 20),
            ),
          if (canDisable && !isSelf)
            IconButton(
              tooltip: 'إزالة',
              onPressed: onRemove,
              icon: const Icon(Icons.person_remove_outlined, size: 20),
            ),
        ],
      ),
    );
  }

  static String _statusLabel(String status) => switch (status) {
    'active' => 'نشط',
    'invited' => 'مدعو',
    _ => 'معطّل',
  };
}
