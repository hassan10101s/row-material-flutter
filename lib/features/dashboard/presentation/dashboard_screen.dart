import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_lab/core/l10n/app_localizations_x.dart';
import '../../../core/constants/app_strings.dart';
import '../../../design_system/animations/app_animations.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_status_badge.dart';
import '../../../design_system/widgets/app_summary_card.dart';
import 'cubit/dashboard_cubit.dart';
import 'cubit/dashboard_kpis_cubit.dart';
import 'cubit/dashboard_kpis_state.dart';
import '../data/dashboard_repo.dart';
/// Dashboard (port of Web DashboardView + dashboard summary analytics).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<DashboardCubit>().state;
    final cubit = context.read<DashboardCubit>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero Banner & Filters
          AppEntrance(
            child: _HeroBanner(
              period: state.period,
              selectedMaterial: state.selectedMaterial,
              selectedSupplier: state.selectedSupplier,
              selectedStatus: state.selectedStatus,
              filterOptions: state.filterOptions,
              onPeriodChange: cubit.setPeriod,
              onMaterialChange: cubit.setMaterial,
              onSupplierChange: cubit.setSupplier,
              onStatusChange: cubit.setStatus,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          // Quick Action Buttons
          const _QuickActionsBar(),
          const SizedBox(height: AppSpacing.lg),
          if (state.loading)
            const Padding(
              padding: EdgeInsets.all(60),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (state.error != null)
            AppEmptyState(
              icon: Icons.error_outline,
              title: AppText.t('تعذر تحميل اللوحة', 'Failed to load dashboard'),
              subtitle: state.error!,
              action: AppButton(
                label: AppText.t('إعادة المحاولة', 'Retry'),
                onPressed: cubit.load,
              ),
            )
          else ...[
            // Today KPIs Row
            BlocBuilder<DashboardKpisCubit, DashboardKpisState>(
              builder: (context, kpi) => AppStagger(
                interval: const Duration(milliseconds: 40),
                children: [
                  _KpiRow(
                    todayInspections: kpi.todayInspections,
                    todayApproved: kpi.todayApproved,
                    todayRejected: kpi.todayRejected,
                    totalCount: kpi.totalCount,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (state.summary != null) ...[
              // Period Decisions Overview Card
              AppEntrance(child: _DecisionsOverviewCard(summary: state.summary!)),
              const SizedBox(height: AppSpacing.lg),
              // Monthly Trend & Comparison Section
              _MonthlyTrendSection(summary: state.summary!),
              const SizedBox(height: AppSpacing.lg),
              // Recommendations & Insights Section
              _InsightsAndRecommendationsSection(summary: state.summary!),
              const SizedBox(height: AppSpacing.lg),
              // Top Materials & Top Suppliers Section
              _TopBreakdownSection(summary: state.summary!),
            ],
          ],
        ],
      ),
    );
  }
}
class _HeroBanner extends StatelessWidget {
  final String period;
  final String selectedMaterial;
  final String selectedSupplier;
  final String selectedStatus;
  final DashboardFilterOptions? filterOptions;
  final ValueChanged<String> onPeriodChange;
  final ValueChanged<String> onMaterialChange;
  final ValueChanged<String> onSupplierChange;
  final ValueChanged<String> onStatusChange;
  const _HeroBanner({
    required this.period,
    required this.selectedMaterial,
    required this.selectedSupplier,
    required this.selectedStatus,
    required this.filterOptions,
    required this.onPeriodChange,
    required this.onMaterialChange,
    required this.onSupplierChange,
    required this.onStatusChange,
  });
  String _statusLabel(String status) {
    if (status == 'ALL') return AppText.t('جميع الحالات', 'All Statuses');
    return statusLabel(status);
  }
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDeep],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics_outlined, color: Colors.white, size: 28.r),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppStrings.dashboard,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.dashboard_hero_subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
                fontSize: 14.spMax,
              ),
          ),
          const SizedBox(height: AppSpacing.md),
          // Period Filter Chips
          Material(
            color: Colors.transparent,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (key, label) in [
                  ('7d', context.l10n.period_week),
                  ('30d', context.l10n.period_month),
                  ('90d', context.l10n.period_3months),
                  ('365d', context.l10n.period_year),
                  ('ALL', context.l10n.period_all),
                ])
                  FilterChip(
                    selected: period == key,
                    label: Text(label),
                    onSelected: (_) => onPeriodChange(key),
                    selectedColor: Colors.white,
                    checkmarkColor: AppColors.primary,
                    backgroundColor: Colors.white24,
                    labelStyle: TextStyle(
                      fontWeight: period == key ? FontWeight.bold : FontWeight.normal,
                      color: period == key ? AppColors.primaryDeep : Colors.white,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // Dropdown Filters Row
          if (filterOptions != null)
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 700;
                return Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    // Material Filter
                    SizedBox(
                      width: isWide ? 220 : constraints.maxWidth,
                        child: _HeroDropdown(
                          label: context.l10n.dashboard_material,
                          value: selectedMaterial,
                          items: filterOptions!.materials,
                          onChanged: (v) => onMaterialChange(v ?? 'ALL'),
                        ),
                    ),
                    // Supplier Filter
                    SizedBox(
                      width: isWide ? 220 : constraints.maxWidth,
                        child: _HeroDropdown(
                          label: context.l10n.dashboard_supplier,
                          value: selectedSupplier,
                          items: filterOptions!.suppliers,
                          onChanged: (v) => onSupplierChange(v ?? 'ALL'),
                        ),
                    ),
                    // Status Filter
                    SizedBox(
                      width: isWide ? 200 : constraints.maxWidth,
                        child: _HeroDropdown(
                          label: context.l10n.dashboard_status,
                          value: selectedStatus,
                          items: [
                            for (final st in filterOptions!.statuses)
                              {'id': st, 'name': _statusLabel(st)}
                          ],
                          onChanged: (v) => onStatusChange(v ?? 'ALL'),
                        ),
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}
class _HeroDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<Map<String, dynamic>> items;
  final ValueChanged<String?> onChanged;
  const _HeroDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.any((i) => i['id'] == value) ? value : 'ALL',
          isExpanded: true,
          isDense: true,
          style: TextStyle(fontSize: 13.spMax, color: Color(0xFF0F172A)),
          icon: Icon(Icons.arrow_drop_down, color: AppColors.primary),
          onChanged: onChanged,
          items: [
            for (final item in items)
              DropdownMenuItem<String>(
                value: '${item['id']}',
                child: Text(
                  '${item['name']}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
class _QuickActionsBar extends StatelessWidget {
  const _QuickActionsBar();
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _ActionButton(
            label: context.l10n.dashboard_new_inspection,
            icon: Icons.add_task,
            color: AppColors.primary,
            onTap: () => context.go('/inspection-new'),
          ),
          const SizedBox(width: 10),
          _ActionButton(
            label: context.l10n.dashboard_history,
            icon: Icons.history,
            color: AppColors.accent,
            onTap: () => context.go('/inspections'),
          ),
          const SizedBox(width: 10),
          _ActionButton(
            label: context.l10n.dashboard_reports,
            icon: Icons.description_outlined,
            color: AppColors.info,
            onTap: () => context.go('/reports'),
          ),
          const SizedBox(width: 10),
          _ActionButton(
            label: context.l10n.dashboard_lab,
            icon: Icons.biotech_outlined,
            color: AppColors.success,
            onTap: () => context.go('/lab'),
          ),
        ],
      ),
    );
  }
}
class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.borderMuted),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18.r, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.spMax,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textStrong,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class _KpiRow extends StatelessWidget {
  final int todayInspections;
  final int todayApproved;
  final int todayRejected;
  final int totalCount;
  const _KpiRow({
    required this.todayInspections,
    required this.todayApproved,
    required this.todayRejected,
    required this.totalCount,
  });
  @override
  Widget build(BuildContext context) {
    final cards = <(String, String, Color, IconData)>[
      (context.l10n.kpi_today_inspections, '$todayInspections', AppColors.primary, Icons.event_note),
      (context.l10n.kpi_today_approved, '$todayApproved', AppColors.success, Icons.check_circle_outline),
      (context.l10n.kpi_today_rejected, '$todayRejected', AppColors.danger, Icons.cancel_outlined),
      (context.l10n.kpi_total, '$totalCount', AppColors.accent, Icons.inventory_2_outlined),
    ];    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 760 ? 4 : 2;
        final tile = (constraints.maxWidth - AppSpacing.md * (width - 1)) / width;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final c in cards)
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                    label: c.$1, value: c.$2, color: c.$3, icon: c.$4),
              ),
          ],
        );
      },
    );
  }
}
class _DecisionsOverviewCard extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _DecisionsOverviewCard({required this.summary});
  @override
  Widget build(BuildContext context) {
    final totals = summary['totals'] as Map<String, dynamic>? ?? const {};
    final total = totals['total'] ?? 0;
    final approvalRate = '${totals['approvalRate'] ?? '0.0'}';
    final rejectionRate = '${totals['rejectionRate'] ?? '0.0'}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline, color: AppColors.primary, size: 22.r),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.period_decisions_title,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                      '${context.l10n.rate_approval_rate}$approvalRate%',
                    style: TextStyle(
                      fontSize: 12.spMax,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                _DecisionBadge(context.l10n.decision_approved, '${totals['approved'] ?? 0}', AppColors.success),
                _DecisionBadge(context.l10n.decision_conditional, '${totals['conditional'] ?? 0}', AppColors.info),
                _DecisionBadge(context.l10n.decision_partial, '${totals['partial'] ?? 0}', AppColors.partial),
                _DecisionBadge(context.l10n.decision_rejected, '${totals['rejected'] ?? 0}', AppColors.danger),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: double.tryParse(approvalRate) != null
                    ? double.parse(approvalRate) / 100
                    : 0,
                minHeight: 10,
                color: AppColors.success,
                backgroundColor: AppColors.danger.withValues(alpha: 0.2),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    '${context.l10n.total_in_period}$total',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '${context.l10n.rejection_rate_general}$rejectionRate%',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.danger, fontSize: 12.spMax, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
class _DecisionBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _DecisionBadge(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style:
                  TextStyle(fontWeight: FontWeight.bold, fontSize: 18.spMax, color: color)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5.spMax, color: AppColors.textStrong)),
          ),
        ],
      ),
    );
  }
}
class _MonthlyTrendSection extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _MonthlyTrendSection({required this.summary});
  @override
  Widget build(BuildContext context) {
    final monthlyTrend = (summary['monthlyTrend'] as List?) ?? const [];
    final comparison = summary['comparison'] as Map<String, dynamic>? ?? const {};
    final deltaLabel = '${comparison['label'] ?? ''}';
    final sign = '${comparison['approvalDeltaSign'] ?? ''}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart, color: AppColors.accent, size: 22.r),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.monthly_trend_title,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                if (deltaLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (sign == '+' ? AppColors.success : AppColors.danger)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      deltaLabel,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        fontWeight: FontWeight.bold,
                        color: sign == '+' ? AppColors.success : AppColors.danger,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (monthlyTrend.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Text(context.l10n.monthly_trend_empty,
                      style: TextStyle(color: AppColors.textMuted)),
                ),
              )
            else
              Column(
                children: [
                  for (final item in monthlyTrend)
                    _MonthlyTrendRow(item: item as Map<String, dynamic>),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
class _MonthlyTrendRow extends StatelessWidget {
  final Map<String, dynamic> item;
  const _MonthlyTrendRow({required this.item});
  @override
  Widget build(BuildContext context) {
    final label = '${item['label'] ?? ''}';
    final total = item['total'] ?? 0;
    final rate = '${item['approvalRate'] ?? '0.0'}';
    final approvedPct = double.tryParse('${item['approvedWidth'] ?? 0}') ?? 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.spMax)),
              ),
              const SizedBox(width: 8),
              Text(
                '$total ${AppText.t('فحص', 'inspections')} — ${AppText.t('قبول', 'approved')}: $rate%',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (approvedPct / 100).clamp(0.0, 1.0),
              minHeight: 8,
              color: AppColors.primary,
              backgroundColor: AppColors.borderMuted,
            ),
          ),
        ],
      ),
    );
  }
}
class _InsightsAndRecommendationsSection extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _InsightsAndRecommendationsSection({required this.summary});
  @override
  Widget build(BuildContext context) {
    final recommendations = (summary['recommendations'] as List?) ?? const [];
    final insightCards = (summary['insightCards'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (recommendations.isNotEmpty) ...[
          Text(
            AppText.t('التوصيات الإدارية', 'Recommendations'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final rec in recommendations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.tips_and_updates, size: 18.r, color: AppColors.warning),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '$rec',
                              style: TextStyle(fontSize: 13.5.spMax),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (insightCards.isNotEmpty) ...[
          Text(
            AppText.t('التحليلات والتنبيهات', 'Insights'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 600;
              final tile = isWide
                  ? (constraints.maxWidth - AppSpacing.md * (insightCards.length - 1)) /
                      insightCards.length
                  : constraints.maxWidth;
              return Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: [
                  for (final c in insightCards)
                    SizedBox(
                      width: tile,
                      child: _InsightCard(map: c as Map<String, dynamic>),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}
class _InsightCard extends StatelessWidget {
  final Map<String, dynamic> map;
  const _InsightCard({required this.map});
  @override
  Widget build(BuildContext context) {
    final tone = '${map['tone']}';
    final color = switch (tone) {
      'success' => AppColors.success,
      'danger' => AppColors.danger,
      _ => AppColors.warning,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lightbulb_outline, color: color, size: 20.r),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${map['title']}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold, color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${map['description']}',
              style: TextStyle(fontSize: 12.5.spMax, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
class _TopBreakdownSection extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _TopBreakdownSection({required this.summary});
  @override
  Widget build(BuildContext context) {
    final topMaterials = (summary['topMaterials'] as List?) ?? const [];
    final topSuppliers = (summary['topSuppliers'] as List?) ?? const [];
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 760;
        final cardWidth = isWide ? (constraints.maxWidth - AppSpacing.md) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            // Top Materials Card
            SizedBox(
              width: cardWidth,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.inventory_2_outlined, color: AppColors.primary, size: 20.r),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppText.t('أعلى الخامات فحوصات', 'Top Materials'),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (topMaterials.isEmpty)
                        Text(AppText.t('لا توجد فحوصات خامات', 'No material inspections'),
                            style: TextStyle(color: AppColors.textMuted))
                      else
                        for (final m in topMaterials) ...[
                          _TopItemProgress(
                            label: '${m['name']}',
                            count:
                                '${m['total']} ${AppText.t('فحص', 'inspections')}',
                            rate:
                                '${m['rate']}% ${AppText.t('قبول', 'approved')}',
                            value: double.tryParse('${m['rate']}') ?? 0.0,
                            color: AppColors.primary,
                          ),
                          const SizedBox(height: 8),
                        ],
                    ],
                  ),
                ),
              ),
            ),
            // Top Suppliers Card
            SizedBox(
              width: cardWidth,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.local_shipping_outlined, color: AppColors.accent, size: 20.r),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppText.t('أعلى الموردين فحوصات', 'Top Suppliers'),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (topSuppliers.isEmpty)
                        Text(AppText.t('لا توجد فحوصات موردين', 'No supplier inspections'),
                            style: TextStyle(color: AppColors.textMuted))
                      else
                        for (final s in topSuppliers) ...[
                          _TopItemProgress(
                            label: '${s['name']}',
                            count:
                                '${s['total']} ${AppText.t('فحص', 'inspections')}',
                            rate:
                                '${s['approvalRate']}% ${AppText.t('قبول', 'approved')}',
                            value: double.tryParse('${s['approvalRate']}') ?? 0.0,
                            color: AppColors.accent,
                          ),
                          const SizedBox(height: 8),
                        ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
class _TopItemProgress extends StatelessWidget {
  final String label;
  final String count;
  final String rate;
  final double value;
  final Color color;
  const _TopItemProgress({
    required this.label,
    required this.count,
    required this.rate,
    required this.value,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.spMax),
              ),
            ),
            Text(
              '$count ($rate)',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (value / 100).clamp(0.0, 1.0),
            minHeight: 6,
            color: color,
            backgroundColor: AppColors.borderMuted,
          ),
        ),
      ],
    );
  }
}