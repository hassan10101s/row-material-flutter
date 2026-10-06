import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_sop.dart';
import 'cubit/qc_sops_cubit.dart';
import 'qc_sop_detail_screen.dart';
import 'qc_sop_form_screen.dart';
import 'widgets/sop_pill.dart';

/// The SOP register: every procedure, where it sits in its lifecycle, and
/// which ones are about to lapse.
///
/// Read-only here. Advancing a procedure through approval is a decision with
/// an audit consequence, so it lives on the detail screen where the revision
/// history is visible next to the action.
class QcSopsScreen extends StatelessWidget {
  const QcSopsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcSopsCubit>();
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('إجراءات التشغيل', 'Procedures'),
        actions: [
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
      body: BlocConsumer<QcSopsCubit, QcSopsState>(
        listenWhen: (a, b) => a.error != b.error && b.error != null,
        listener: (context, state) => ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state.error!))),
        builder: (context, state) {
          if (state.loading && state.sops.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.sops.isEmpty) {
            return AppEmptyState(
              icon: Icons.menu_book_outlined,
              title: AppText.t('لا توجد إجراءات', 'No procedures yet'),
              subtitle: state.filters.isEmpty
                  ? AppText.t(
                      'أنشئ أول إجراء تشغيل',
                      'Draft the first procedure',
                    )
                  : AppText.t(
                      'لا توجد إجراءات تطابق هذه الفلاتر',
                      'No procedures match these filters',
                    ),
              action: state.filters.isEmpty
                  ? null
                  : FilledButton.tonal(
                      onPressed: () => cubit.clearFilters(),
                      child: Text(AppText.t('مسح الفلاتر', 'Clear filters')),
                    ),
            );
          }
          return Column(
            children: [
              _SummaryStrip(summary: state.summary),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => cubit.refresh(),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: state.sops.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, i) => _SopTile(sop: state.sops[i]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openFilters(BuildContext context) {
    final cubit = context.read<QcSopsCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const _SopFilterSheet()),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final QcSopSummary summary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('الإجمالي', 'Total'),
              value: '${summary.total}',
              icon: Icons.menu_book_outlined,
              color: AppColors.primary,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('مسودة', 'Draft'),
              value: '${summary.draft}',
              icon: Icons.edit_note,
              color: AppColors.textMuted,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('بانتظار الموافقة', 'Awaiting'),
              value: '${summary.awaitingApproval}',
              icon: Icons.hourglass_empty,
              color: AppColors.warning,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('ينتهي قريبًا', 'Expiring'),
              value: '${summary.expiringSoon}',
              icon: Icons.event_busy_outlined,
              color: summary.expiringSoon > 0
                  ? AppColors.danger
                  : AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _SopTile extends StatelessWidget {
  const _SopTile({required this.sop});

  final QcSop sop;

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
        return Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            top: AppSpacing.lg,
            bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppText.t('فلاتر الإجراءات', 'Procedure filters'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16.spMax,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: AppText.t('بحث', 'Search'),
                    hintText: AppText.t('رمز أو عنوان', 'Code or title'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => cubit.applyFilters(f.copyWith(text: v)),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _dept,
                  decoration: InputDecoration(
                    labelText: AppText.t('القسم', 'Department'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(dept: v.trim())),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(AppText.t('الحالة', 'Status')),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final status in SopStatus.all)
                      FilterChip(
                        label: Text(SopPill.statusLabel(status)),
                        selected: f.statuses.contains(status),
                        onSelected: (_) => cubit.toggleStatus(status),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: f.includeArchived,
                  title: Text(AppText.t('إظهار المؤرشف', 'Show archived')),
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(includeArchived: v)),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => cubit.clearFilters(),
                      child: Text(AppText.t('مسح', 'Clear')),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(AppText.t('تم', 'Done')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
