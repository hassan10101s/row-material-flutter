import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../app/auth_gate.dart';
import '../../../../../core/auth/permissions.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_summary_card.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../widgets/register_exports.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_sop.dart';
import '../cubit/qc_sops_cubit.dart';
import 'qc_sop_detail_screen.dart';
import 'qc_sop_form_screen.dart';
import '../widgets/sop_pill.dart';

/// The SOP register: every procedure, where it sits in its lifecycle, and
/// which ones are about to lapse.
///
/// Read-only here. Advancing a procedure through approval is a decision with
/// an audit consequence, so it lives on the detail screen where the revision
/// history is visible next to the action.
class QcSopsScreen extends StatelessWidget {
  const QcSopsScreen({super.key, this.embedded = false});

  /// Embedded inside the quality hub: no [Scaffold]/app bar because the hub
  /// draws its own chrome — the register's actions re-render as an inline
  /// toolbar row, matching the routine lists tab's header row.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcSopsCubit>();
    final body = BlocConsumer<QcSopsCubit, QcSopsState>(
      listenWhen: (a, b) => a.error != b.error && b.error != null,
      listener: (context, state) => AppFeedback.error(context, state.error!),
      builder: (context, state) {
        if (state.loading && state.sops.isEmpty) {
          return const AppSkeletonList(rows: 5);
        }
        if (state.sops.isEmpty) {
          return AppEmptyState(
            icon: Icons.menu_book_outlined,
            title: AppText.t('لا توجد إجراءات', 'No procedures yet'),
            subtitle: state.filters.isEmpty
                ? AppText.t('أنشئ أول إجراء تشغيل', 'Draft the first procedure')
                : AppText.t(
                    'لا توجد إجراءات تطابق هذه الفلاتر',
                    'No procedures match these filters',
                  ),
            action: state.filters.isEmpty
                ? null
                : AppButton(
                    label: AppText.t('مسح الفلاتر', 'Clear filters'),
                    style: AppButtonStyle.secondary,
                    onPressed: () => cubit.clearFilters(),
                  ),
          );
        }
        return Column(
          children: [
            if (state.loading && state.sops.isNotEmpty) const AppRefreshBar(),
            _SummaryStrip(summary: state.summary),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                0,
              ),
              child: AppFilterBar(
                searchHint: AppText.t(
                  'بحث بالرمز أو العنوان',
                  'Search code or title',
                ),
                initialSearch: state.filters.text,
                onSearch: (v) =>
                    cubit.applyFilters(state.filters.copyWith(text: v)),
                trailing: AppButton(
                  label: AppText.t('فلاتر', 'Filters'),
                  icon: const Icon(Icons.tune, size: 18),
                  style: AppButtonStyle.ghost,
                  small: true,
                  onPressed: () => _openFilters(context),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => cubit.refresh(),
                child: AppInfiniteList(
                  itemCount: state.sops.length,
                  hasMore: false,
                  itemBuilder: (context, i) => _SopTile(sop: state.sops[i]),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                const Spacer(),
                AppButton(
                  small: true,
                  style: AppButtonStyle.ghost,
                  icon: const Icon(Icons.table_view_outlined, size: 18),
                  onPressed: () =>
                      RegisterExports.sops(context, cubit.state.sops),
                ),
                AppButton(
                  small: true,
                  style: AppButtonStyle.ghost,
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => cubit.refresh(),
                ),
                AppButton(
                  small: true,
                  style: AppButtonStyle.ghost,
                  label: AppText.t('فلاتر', 'Filters'),
                  icon: const Icon(Icons.tune, size: 18),
                  onPressed: () => _openFilters(context),
                ),
                AppButton(
                  small: true,
                  style: AppButtonStyle.secondary,
                  label: AppText.t('إجراء جديد', 'New SOP'),
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () => QcSopFormScreen.open(context),
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('إجراءات التشغيل SOP', 'Procedures SOP'),
        actions: [
          IconButton(
            tooltip: AppText.t('تصدير جدول', 'Export table'),
            onPressed: () => RegisterExports.sops(context, cubit.state.sops),
            icon: const Icon(Icons.table_view_outlined),
          ),
          IconButton(
            tooltip: AppText.t('تحديث', 'Refresh'),
            onPressed: () => cubit.refresh(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: AppText.t('فلاتر', 'Filters'),
            onPressed: () => _openFilters(context),
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: AppText.t('إجراء جديد', 'New SOP'),
            onPressed: () => QcSopFormScreen.open(context),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: body,
    );
  }

  void _openFilters(BuildContext context) {
    final cubit = context.read<QcSopsCubit>();
    showAppOverlay<void>(
      context,
      title: AppText.t('فلاتر الإجراءات', 'Procedure filters'),
      icon: Icons.filter_alt_outlined,
      size: AppWindowSize.sm,
      builder: (_, _) =>
          BlocProvider.value(value: cubit, child: const _SopFilterSheet()),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final QcSopSummary summary;

  @override
  Widget build(BuildContext context) {
    final cards = [
      AppSummaryCard(
        label: AppText.t('الإجمالي', 'Total'),
        value: '${summary.total}',
        icon: Icons.menu_book_outlined,
        color: AppColors.primary,
      ),
      AppSummaryCard(
        label: AppText.t('مسودة', 'Draft'),
        value: '${summary.draft}',
        icon: Icons.edit_note,
        color: AppColors.textMuted,
      ),
      AppSummaryCard(
        label: AppText.t('بانتظار الموافقة', 'Awaiting'),
        value: '${summary.awaitingApproval}',
        icon: Icons.hourglass_empty,
        color: AppColors.warning,
      ),
      AppSummaryCard(
        label: AppText.t('ينتهي قريبًا', 'Expiring'),
        value: '${summary.expiringSoon}',
        icon: Icons.event_busy_outlined,
        color: summary.expiringSoon > 0
            ? AppColors.danger
            : AppColors.textMuted,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 600) {
            return Row(children: [for (final c in cards) Expanded(child: c)]);
          }
          return Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final c in cards)
                SizedBox(
                  width: (constraints.maxWidth - AppSpacing.sm) / 2,
                  child: c,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SopTile extends StatelessWidget {
  const _SopTile({required this.sop});

  final QcSop sop;

  static bool get canDelete {
    try {
      return getIt<AuthGate>().canWrite(Permission.qcWrite);
    } catch (_) {
      return true;
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف الإجراء', 'Delete procedure'),
      name: sop.title.isNotEmpty ? sop.title : sop.code,
    );
    if (!confirmed || !context.mounted) return;
    final cubit = context.read<QcSopsCubit>();
    await cubit.deleteSop(sop.sopId ?? 0);
    if (!context.mounted) return;
    final error = cubit.state.error;
    if (error != null && error.isNotEmpty) {
      AppFeedback.error(context, error);
      cubit.clearError();
    } else {
      AppFeedback.success(context, AppText.t('تم حذف الإجراء', 'SOP deleted'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => QcSopDetailScreen.open(context, sop.sopId ?? 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sop.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.spMax,
                  ),
                ),
              ),
              SopPill.status(sop.status),
              if (canDelete) ...[
                const SizedBox(width: AppSpacing.xs),
                PopupMenuButton<String>(
                  tooltip: AppText.t('خيارات', 'Options'),
                  iconSize: 20,
                  onSelected: (v) {
                    if (v == 'delete') _confirmDelete(context);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: AppColors.danger,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(AppText.t('حذف', 'Delete')),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${sop.code}${sop.revNo > 0 ? '  •  rev ${sop.revNo}' : ''}',
            style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            children: [
              if (sop.dept.isNotEmpty)
                _Meta(icon: Icons.apartment_outlined, text: sop.dept),
              if (sop.category.isNotEmpty)
                _Meta(icon: Icons.label_outline, text: sop.category),
              if (sop.criticality.isNotEmpty)
                _Meta(
                  icon: Icons.priority_high,
                  text: SopPill.criticalityLabel(sop.criticality),
                ),
              if (sop.expiryDate.isNotEmpty)
                _Meta(
                  icon: Icons.event_outlined,
                  text: sop.expiryDate.substring(0, 10),
                  danger: sop.isExpired,
                ),
            ],
          ),
          if (sop.isPublished && sop.needsAck) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(
                  Icons.how_to_reg_outlined,
                  size: 14.r,
                  color: AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  AppText.t(
                    'يتطلب إشعار قراءة',
                    'Needs a read acknowledgement',
                  ),
                  style: TextStyle(
                    fontSize: 11.spMax,
                    color: AppColors.warning,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.danger = false});

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14.r, color: color),
        const SizedBox(width: AppSpacing.xs),
        Text(
          text,
          style: TextStyle(fontSize: 12.spMax, color: color),
        ),
      ],
    );
  }
}

/// Filter sheet.
///
/// A `BlocBuilder`, not a captured state: toggling a status has to be visible
/// in the sheet itself, and a state object handed in once cannot follow its own
/// emissions.
class _SopFilterSheet extends StatefulWidget {
  const _SopFilterSheet();

  @override
  State<_SopFilterSheet> createState() => _SopFilterSheetState();
}

class _SopFilterSheetState extends State<_SopFilterSheet> {
  final _search = TextEditingController();
  final _dept = TextEditingController();

  @override
  void initState() {
    super.initState();
    final f = context.read<QcSopsCubit>().state.filters;
    _search.text = f.text;
    _dept.text = f.dept;
  }

  @override
  void dispose() {
    _search.dispose();
    _dept.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcSopsCubit>();
    return BlocBuilder<QcSopsCubit, QcSopsState>(
      bloc: cubit,
      builder: (context, state) {
        final f = state.filters;
        // Chrome (title, padding, scroll) comes from the overlay host, so
        // desktop and phones share one look.
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppField(
              label: AppText.t('بحث', 'Search'),
              controller: _search,
              hint: AppText.t('رمز أو عنوان', 'Code or title'),
              onChanged: (v) => cubit.applyFilters(f.copyWith(text: v)),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppField(
              label: AppText.t('القسم', 'Department'),
              controller: _dept,
              onChanged: (v) => cubit.applyFilters(f.copyWith(dept: v.trim())),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(AppText.t('الحالة', 'Status')),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final status in SopStatus.all)
                  AppButton(
                    small: true,
                    style: f.statuses.contains(status)
                        ? AppButtonStyle.primary
                        : AppButtonStyle.secondary,
                    label: SopPill.statusLabel(status),
                    onPressed: () => cubit.toggleStatus(status),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              small: true,
              style: f.includeArchived
                  ? AppButtonStyle.primary
                  : AppButtonStyle.secondary,
              icon: Icon(
                f.includeArchived ? Icons.check_circle : Icons.circle_outlined,
                size: 16,
              ),
              label: AppText.t('إظهار المؤرشف', 'Show archived'),
              onPressed: () => cubit.applyFilters(
                f.copyWith(includeArchived: !f.includeArchived),
              ),
            ),
            AppWindow.footer(
              actions: [
                AppButton(
                  label: AppText.t('مسح', 'Clear'),
                  style: AppButtonStyle.ghost,
                  small: true,
                  onPressed: () => cubit.clearFilters(),
                ),
                AppButton(
                  label: AppText.t('تم', 'Done'),
                  small: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
