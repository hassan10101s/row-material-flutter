import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/responsive/form_factor.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../di/service_locator.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dialogs.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_page_header.dart';
import '../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../../../design_system/export/table_html_export.dart';
import '../../../../design_system/widgets/app_adaptive.dart';
import '../../../organizations/domain/organization_repository.dart';
import '../../domain/member_repository.dart';
import 'leave_organization_section.dart';

/// MembersScreen (plan P3.4): list + Add(email, role) + Activate + Change role
/// + Disable + Resend invite. Every action is online-only; the guard message
/// explains why a button is disabled instead of failing after a click.
///
/// Invite flow covered here:
/// `invited` (manager sent invite) → member signs in with the same e-mail →
/// `pending_activation` → manager activates → `active`.
class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key, this.embedded = false});

  /// Renders without its own page padding, for hosting inside the Settings tabs.
  final bool embedded;

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _search = TextEditingController();
  MemberRepository? _repo;
  AuthGate? _gate;
  List<Member> _members = const [];
  String? _error;
  bool _busy = false;
  final Set<String> _roles = {AppRoles.lab};
  Timer? _searchDebounce;
  String _query = '';

  @override
  void initState() {
    super.initState();
    try {
      _repo = getIt<MemberRepository>();
      // Perf: cache singleton once instead of getIt<AuthGate>() on every build
      // + every table row. The instance is a singleton; live values
      // (online/role) are still read per-build from the same object.
      _gate = getIt<AuthGate>();
    } on Object catch (e) {
      _error = '$e';
      _repo = null;
      return;
    }
    _load();
  }

  /// Perf: debounce per-keystroke setState (300ms) so typing filters once
  /// instead of rebuilding + re-filtering the roster on every character.
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _query = value.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _email.dispose();
    _code.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_repo == null) return;
    if (!mounted) return;
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
    if (_repo == null) return;
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

  static String? validateInviteEmail(String? value) {
    final v = (value ?? '').trim().toLowerCase();
    if (v.isEmpty) {
      return AppText.t('البريد الإلكتروني مطلوب', 'Email is required.');
    }
    if (v.length < 4 || !v.contains('@') || v.contains(' ')) {
      return AppText.t('البريد الإلكتروني غير صالح', 'Invalid email address.');
    }
    final parts = v.split('@');
    if (parts.length != 2 || parts[0].isEmpty || !parts[1].contains('.')) {
      return AppText.t('البريد الإلكتروني غير صالح', 'Invalid email address.');
    }
    return null;
  }

  /// Sends an invite for [role]. The owner uses the co-owner shortcut to make
  /// a second administrator, which is how ownership is shared: `ownerUid` is
  /// immutable in the rules, so a second `admin` is the supported form of
  /// co-ownership.
  void _toggleRole(Set<String> roles, String role) {
    if (roles.contains(role)) {
      if (roles.length > 1) roles.remove(role);
      return;
    }
    if (role == AppRoles.admin ||
        role == AppRoles.trialOwner ||
        role == AppRoles.viewer) {
      roles
        ..clear()
        ..add(role);
      return;
    }
    roles.removeWhere(
      (value) =>
          value == AppRoles.admin ||
          value == AppRoles.trialOwner ||
          value == AppRoles.viewer,
    );
    roles.add(role);
  }

  Future<void> _invite(List<String> selectedRoles) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final roles = AppRoles.normalizeRoles(
      selectedRoles,
      fallbackRole: selectedRoles.isEmpty
          ? AppRoles.viewer
          : selectedRoles.first,
    );
    if (!AppRoles.isValidAssignment(roles)) return;
    final role = roles.first;
    final email = _email.text.trim().toLowerCase();
    // Client-side duplicate hint before the remote round-trip.
    final duplicate = _members.any((m) => m.email.toLowerCase() == email);
    if (duplicate) {
      final existing = _members.firstWhere(
        (m) => m.email.toLowerCase() == email,
      );
      if (existing.isActive) {
        if (mounted) {
          AppFeedback.error(
            context,
            AppText.t(
              'هذا البريد عضو نشط بالفعل في الشركة',
              'This email is already an active company member.',
            ),
          );
        }
        return;
      }
      // Invited/pending → treat as resend so the manager does not create
      // confusion with two rows for one address.
      await _run(() => _repo!.resendInvite(memberId: existing.id));
      if (mounted) {
        AppFeedback.success(
          context,
          AppText.t('تمت إعادة إرسال الدعوة', 'Invite resent.'),
        );
      }
      return;
    }
    await _run(() => _repo!.invite(email: email, role: role, roles: roles));
    if (mounted) {
      _email.clear();
      _roles
        ..clear()
        ..add(AppRoles.lab);
      final message = roles.contains(AppRoles.admin)
          ? AppText.t(
              'تم إرسال دعوة مالك آخر — فعّلها ليتمكن من إدارة الشركة.',
              'Co-owner invite sent — activate it to grant company management.',
            )
          : AppText.t('تم إرسال الدعوة', 'Invite sent.');
      AppFeedback.success(context, message);
    }
  }

  Future<void> _resend(Member member) async {
    await _run(() => _repo!.resendInvite(memberId: member.id));
    if (mounted) {
      AppFeedback.success(
        context,
        AppText.t('تمت إعادة إرسال الدعوة', 'Invite resent.'),
      );
    }
  }

  Future<void> _confirmDisable(Member member) async {
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('تعطيل العضو؟', 'Disable member?'),
      message: AppText.t(
        'سيتم تعطيل ${member.email} ولن يتمكن من رؤية بيانات الشركة.',
        '${member.email} will be disabled and lose access to company data.',
      ),
      confirmLabel: AppText.t('تعطيل', 'Disable'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
      danger: true,
    );
    if (confirmed == true) {
      await _run(
        () => _repo!.setStatus(memberId: member.id, status: 'disabled'),
      );
    }
  }

  Future<void> _confirmRemove(Member member) async {
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('إزالة العضو؟', 'Remove member?'),
      message: AppText.t(
        'سيتم إزالة ${member.email} من الشركة (تُحفظ كسجل معطّل للتدقيق).',
        '${member.email} will be removed from the company (kept as a disabled audit record).',
      ),
      confirmLabel: AppText.t('إزالة', 'Remove'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
      danger: true,
    );
    if (confirmed == true) {
      await _run(() => _repo!.removeMember(memberId: member.id));
    }
  }

  void _copyOrgCode(String orgId) {
    if (orgId.isEmpty) return;
    Clipboard.setData(ClipboardData(text: orgId));
    AppFeedback.success(
      context,
      AppText.t('تم نسخ كود الشركة', 'Company code copied.'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gate = _gate ?? getIt<AuthGate>();
    // Member writes are online-only (never queued): gate the buttons on live
    // connectivity too, or an exempt admin sees enabled buttons offline that
    // can only fail with a raw error.
    final online = gate.online;
    final canInvite = gate.canWrite(Permission.usersCreate) && online;
    final orgId = gate.organizationId;
    bool isSelf(String id) => id == gate.session.memberId;

    final query = _query;
    final visible = query.isEmpty
        ? _members
        : _members
              .where(
                (m) =>
                    m.email.toLowerCase().contains(query) ||
                    m.label.toLowerCase().contains(query) ||
                    AppRoles.labelMany(
                      m.effectiveRoles,
                    ).toLowerCase().contains(query),
              )
              .toList();
    final activeCount = _members.where((m) => m.isActive).length;
    final pendingCount = _members.where((m) => m.needsActivation).length;

    return ListView(
      padding: widget.embedded
          ? EdgeInsets.zero
          : const EdgeInsets.all(AppSpacing.page),
      children: [
        Row(
          children: [
            Expanded(
              child: AppPageHeader(
                title: AppText.t('أعضاء الشركة', 'Company members'),
                subtitle: AppText.t(
                  'الدعوات والأدوار والحالة',
                  'Invites, roles and status',
                ),
                icon: Icons.group_outlined,
              ),
            ),
            IconButton(
              tooltip: AppText.t('تحديث', 'Refresh'),
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        // Shareable company code: the invitee pastes it in
        // create-organization → join-with-invite.
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              const Icon(Icons.qr_code_2_outlined, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppText.t(
                        'كود الشركة للمشاركة مع المدعو',
                        'Company code to share with the invitee',
                      ),
                      style: TextStyle(
                        fontSize: 12.spMax,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    SelectableText(
                      orgId.isEmpty
                          ? AppText.t('غير متوفر', 'Unavailable')
                          : orgId,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              AppButton(
                key: const Key('copyOrgCode'),
                label: AppText.t('نسخ', 'Copy'),
                icon: const Icon(Icons.copy_outlined, size: 16),
                style: AppButtonStyle.ghost,
                small: true,
                onPressed: orgId.isEmpty ? null : () => _copyOrgCode(orgId),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_members.isNotEmpty)
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              Chip(
                label: Text(
                  AppText.t('نشط: $activeCount', 'Active: $activeCount'),
                ),
              ),
              Chip(
                label: Text(
                  AppText.t(
                    'بانتظار التفعيل: $pendingCount',
                    'Pending: $pendingCount',
                  ),
                ),
              ),
              Chip(
                label: Text(
                  AppText.t(
                    'الكل: ${_members.length}',
                    'All: ${_members.length}',
                  ),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: 260.w,
          child: AppField(
            label: AppText.t('بحث', 'Search'),
            controller: _search,
            hint: 'name@company.com',
            onChanged: _onSearchChanged,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (!online)
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Text(
              AppText.t(
                'غير متصل — الدعوات والتفعيل والتعطيل تتطلب الإنترنت.',
                'Offline — invites, activation and disabling need the internet.',
              ),
              style: TextStyle(color: AppColors.danger, fontSize: 12.spMax),
            ),
          ),
        if (!canInvite && online)
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Text(
              AppText.t(
                'الدعوة والتعديل يتطلبان اتصالاً بالإنترنت وجلسة صالحة '
                    '(الأدوار الحالية: ${AppRoles.labelMany(gate.session.effectiveRoles)}).',
                'Inviting and editing require an internet connection and a valid session '
                    '(current roles: ${AppRoles.labelMany(gate.session.effectiveRoles)}).',
              ),
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
        if (_busy && _members.isEmpty) const AppSkeletonList(rows: 8),
        SizedBox(
          height: 420.h,
          child: appAdaptiveVariant(
            context,
            desktop: (ctx) => AppPaginatedTable(
              minTableWidth: 860,
              columnFlex: const [1.3, 1.4, 1.0, 0.8, 1.5],
              headers: [
                AppText.t('العضو', 'Member'),
                AppText.t('البريد الإلكتروني', 'Email'),
                AppText.t('الدور', 'Role'),
                AppText.t('الحالة', 'Status'),
                AppText.t('الإجراءات', 'Actions'),
              ],
              rows: [for (final m in visible) _memberRow(m, isSelf(m.id))],
              empty: AppEmptyState(
                icon: Icons.group_add_outlined,
                title: AppText.t('لا يوجد أعضاء بعد', 'No members yet'),
                subtitle: query.isEmpty
                    ? AppText.t(
                        'أضف أول دعوة من نموذج «إضافة عضو» أدناه.',
                        'Add the first invite from the form below.',
                      )
                    : AppText.t(
                        'لا نتائج مطابقة للبحث.',
                        'No members match the search.',
                      ),
              ),
            ),
            mobile: (ctx) => _membersMobile(ctx, visible, query, isSelf),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Text(
              AppText.t('إضافة عضو', 'Add member'),
              style: TextStyle(fontSize: 15.spMax, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            IconButton(
              tooltip: AppText.t('تصدير جدول', 'Export table'),
              visualDensity: VisualDensity.compact,
              onPressed: visible.isEmpty ? null : () => _exportRoster(visible),
              icon: const Icon(Icons.table_view_outlined),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Form(
          key: _formKey,
          child: Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260.w,
                child: AppField(
                  label: AppText.t('البريد الإلكتروني', 'Email'),
                  controller: _email,
                  hint: 'name@company.com',
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: validateInviteEmail,
                  onFieldSubmitted: (_) {
                    if (canInvite && !_busy) _invite(_roles.toList());
                  },
                ),
              ),
              SizedBox(
                width: 430.w,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: AppText.t('الأدوار', 'Roles'),
                    border: const OutlineInputBorder(),
                  ),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final candidate in AppRoles.all.where(
                        (role) => role != AppRoles.trialOwner,
                      ))
                        FilterChip(
                          label: Text(AppRoles.label(candidate)),
                          selected: _roles.contains(candidate),
                          onSelected: (_) =>
                              setState(() => _toggleRole(_roles, candidate)),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 42.h,
                child: AppButton(
                  key: const Key('sendInvite'),
                  label: AppText.t('إرسال دعوة', 'Send invite'),
                  small: true,
                  loading: _busy,
                  onPressed: canInvite && !_busy
                      ? () => _invite(_roles.toList())
                      : null,
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
                      ? () => _invite([AppRoles.admin])
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          AppText.t(
            '«دعوة مالك آخر» ترسل الدعوة بدور مدير الشركة، فيحصل على نفس صلاحياتك '
                'على الأعضاء. يمكن إضافة أكثر من مالك.',
            '"Invite co-owner" sends the invite with the company-owner role, so '
                'they get the same member-management rights as you. More than one is '
                'allowed.',
          ),
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
        const SizedBox(height: AppSpacing.lg),
        const LeaveOrganizationSection(),
        const SizedBox(height: AppSpacing.md),
        Text(
          AppText.t(
            'بعد إرسال الدعوة انسخ كود الشركة أعلاه وأرسله للمدعو، ثم يسجّل الدخول بحسابه في Google أو بالبريد وكلمة المرور بنفس البريد، ثم '
                'يظهر له "بانتظار التفعيل" حتى تفعّله من زر التفعيل.',
            'After sending the invite, copy the company code above and share it with the invitee. They sign in with their Google account on the same email, then '
                'show as "awaiting activation" until you activate them with the activate button.',
          ),
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
      ],
    );
  }

  /// The phone experience of the roster: cards instead of the 7-column
  /// table (which would horizontally scroll on a phone). The cells come
  /// from the same [_memberRow] builder the table uses, so the action
  /// gating, the roles and the test keys cannot drift between the two.
  Widget _membersMobile(
    BuildContext context,
    List<Member> visible,
    String query,
    bool Function(String id) isSelf,
  ) {
    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Text(
          query.isEmpty
              ? AppText.t(
                  'لا يوجد أعضاء بعد — أضف أول دعوة.',
                  'No members yet — add the first invite.',
                )
              : AppText.t('لا نتائج مطابقة.', 'No matching members.'),
        ),
      );
    }
    return Column(
      children: [
        for (final m in visible) ...[
          Builder(
            builder: (context) {
              final cells = _memberRow(m, isSelf(m.id));
              return AppCard(
                enableHover: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: cells[0]),
                        const SizedBox(width: AppSpacing.sm),
                        cells[3],
                      ],
                    ),
                    const SizedBox(height: 2),
                    cells[1],
                    const SizedBox(height: 2),
                    cells[2],
                    const SizedBox(height: AppSpacing.sm),
                    cells[4],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }

  /// One roster row for the paginated table. No bulk selection here on
  /// purpose: activate/disable/remove are destructive per-member decisions.
  Future<void> _editMemberRoles(Member member) async {
    final roles = member.effectiveRoles
        .where((role) => role != AppRoles.trialOwner)
        .toSet();
    final selected = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AppWindow(
          title: AppText.t('أدوار الموظف', 'Employee roles'),
          actions: [
            AppButton(
              style: AppButtonStyle.secondary,
              onPressed: () => Navigator.pop(dialogContext),
              label: AppText.t('إلغاء', 'Cancel'),
            ),
            AppButton(
              onPressed: AppRoles.isValidAssignment(roles)
                  ? () => Navigator.pop(dialogContext, roles.toList())
                  : null,
              label: AppText.t('حفظ الأدوار', 'Save roles'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final role in AppRoles.all.where(
                (value) => value != AppRoles.trialOwner,
              ))
                CheckboxListTile(
                  dense: true,
                  value: roles.contains(role),
                  title: Text(AppRoles.label(role)),
                  onChanged: (_) =>
                      setDialogState(() => _toggleRole(roles, role)),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    await _run(
      () => _repo!.changeRole(
        memberId: member.id,
        role: selected.first,
        roles: selected,
      ),
    );
  }

  List<Widget> _memberRow(Member member, bool self) {
    final gate = _gate ?? getIt<AuthGate>();
    final canUpdate = gate.canWrite(Permission.usersUpdate) && gate.online;
    final canDisable = gate.canWrite(Permission.usersDisable) && gate.online;
    final color = _statusColor(member.status);
    // Phone fingers need the 44dp+ floor; the mouse keeps the compact density.
    final touch = FormFactor.current.isMobile
        ? const BoxConstraints(minWidth: 48, minHeight: 48)
        : const BoxConstraints(minWidth: 36, minHeight: 36);
    return [
      Text(
        '${member.label}${self ? ' (${AppText.t('أنت', 'You')})' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      Text(member.email, maxLines: 1, overflow: TextOverflow.ellipsis),
      Text(
        AppRoles.labelMany(member.effectiveRoles),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Text(
          _statusLabel(member.status),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.spMax, color: color),
        ),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canUpdate && member.needsActivation)
            IconButton(
              key: ValueKey('activate_${member.id}'),
              tooltip: AppText.t('تفعيل', 'Activate'),
              visualDensity: VisualDensity.compact,
              constraints: touch,
              onPressed: () => _run(
                () => _repo!.setStatus(memberId: member.id, status: 'active'),
              ),
              icon: const Icon(Icons.check_circle_outline, size: 20),
            ),
          if (canUpdate && member.needsActivation)
            IconButton(
              key: ValueKey('resend_${member.id}'),
              tooltip: AppText.t('إعادة إرسال الدعوة', 'Resend invite'),
              visualDensity: VisualDensity.compact,
              constraints: touch,
              onPressed: () => _resend(member),
              icon: const Icon(Icons.send_outlined, size: 20),
            ),
          if (canUpdate && member.isActive && !self)
            IconButton(
              tooltip: AppText.t('تغيير الدور', 'Change role'),
              onPressed: () => _editMemberRoles(member),
              icon: const Icon(Icons.manage_accounts_outlined, size: 20),
            ),
          if (canDisable && member.isActive && !self)
            IconButton(
              tooltip: AppText.t('تعطيل', 'Disable'),
              visualDensity: VisualDensity.compact,
              constraints: touch,
              onPressed: () => _confirmDisable(member),
              icon: const Icon(Icons.block, size: 20),
            ),
          if (canDisable && !self)
            IconButton(
              tooltip: AppText.t('إزالة', 'Remove'),
              visualDensity: VisualDensity.compact,
              constraints: touch,
              onPressed: () => _confirmRemove(member),
              icon: const Icon(Icons.person_remove_outlined, size: 20),
            ),
        ],
      ),
    ];
  }

  Future<void> _exportRoster(List<Member> rows) => TableHtmlExport.export(
    context,
    filePrefix: 'members',
    title: AppText.t('أعضاء الشركة', 'Company members'),
    headers: [
      AppText.t('العضو', 'Member'),
      AppText.t('البريد الإلكتروني', 'Email'),
      AppText.t('الدور', 'Role'),
      AppText.t('الحالة', 'Status'),
    ],
    rows: [
      for (final m in rows)
        [
          m.label,
          m.email,
          AppRoles.labelMany(m.effectiveRoles),
          _statusLabel(m.status),
        ],
    ],
  );

  static Color _statusColor(String status) => switch (status) {
    'active' => AppColors.success,
    'invited' => AppColors.warning,
    'pending_activation' => AppColors.warning,
    _ => AppColors.textMuted,
  };

  static String _statusLabel(String status) => switch (status) {
    'active' => AppText.t('نشط', 'Active'),
    'invited' => AppText.t('مدعو', 'Invited'),
    'pending_activation' => AppText.t('بانتظار التفعيل', 'Pending activation'),
    'disabled' => AppText.t('معطّل', 'Disabled'),
    _ => AppText.t('غير معروف', 'Unknown'),
  };
}
