import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_lab/core/l10n/app_localizations_x.dart';
import '../../../core/constants/app_strings.dart';
import '../../../design_system/animations/app_animations.dart';
import '../../../design_system/feedback/app_error_feedback.dart';
import '../../../design_system/tokens/app_breakpoints.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_skeleton.dart';
import '../../../design_system/widgets/app_status_badge.dart';
import '../../../design_system/widgets/app_summary_card.dart';
import 'cubit/dashboard_cubit.dart';
import 'cubit/dashboard_kpis_cubit.dart';
import 'cubit/dashboard_kpis_state.dart';
import 'cubit/dashboard_state.dart';
import '../domain/dashboard_repository.dart';
/// Dashboard (port of Web DashboardView + dashboard summary analytics).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<DashboardCubit>().state;
    final cubit = context.read<DashboardCubit>();
    return AppErrorFeedback<DashboardCubit, DashboardState>(
      selector: (s) => s.error,
      child: SingleChildScrollView(
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
            if (state.loading && state.summary == null)
              const AppSkeletonList(rows: 4, lines: 3, height: 360)
            else if (state.error != null)
              AppEmptyState(
                icon: Icons.error_outline,
                title: AppText.t('تعذر تحميل اللوحة', 'Failed to load dashboard'),
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
                // Cross-module analyst KPIs (display-only, all business logic)
                BlocBuilder<DashboardKpisCubit, DashboardKpisState>(
                  builder: (context, kpi) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _VolumeQualitySection(kpi: kpi),
                      const SizedBox(height: AppSpacing.lg),
                      _LabQcSection(kpi: kpi),
                      const SizedBox(height: AppSpacing.lg),
                      _NcrSection(kpi: kpi),
                      const SizedBox(height: AppSpacing.lg),
                      _SopGoalsSection(kpi: kpi),
                      const SizedBox(height: AppSpacing.lg),
                      _InventorySection(kpi: kpi),
                      const SizedBox(height: AppSpacing.lg),
                      _TrendChartSection(kpi: kpi),
                      const SizedBox(height: AppSpacing.lg),
                      _AgingDefectsSection(kpi: kpi),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  ),
                ),
                // Recommendations & Insights Section
                _InsightsAndRecommendationsSection(summary: state.summary!),
                const SizedBox(height: AppSpacing.lg),
                // Top Materials & Top Suppliers Section
                _TopBreakdownSection(summary: state.summary!),
              ],
            ],
          ],
        ),
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
                final isWide = constraints.maxWidth >= AppBreakpoints.medium;
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
        final width = constraints.maxWidth >= AppBreakpoints.medium ? 4 : 2;
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
              final tile = AppBreakpoints.fitsColumnsIn(
                availableWidth: constraints.maxWidth,
                columns: insightCards.length,
                minColumnWidth: 280,
                gap: AppSpacing.md,
              )
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
        final cardWidth = AppBreakpoints.fitsColumnsIn(
          availableWidth: constraints.maxWidth,
          columns: 2,
          minColumnWidth: 300,
          gap: AppSpacing.md,
        )
            ? (constraints.maxWidth - AppSpacing.md) / 2
            : constraints.maxWidth;

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

// ── Senior-analyst cross-module sections (display-only) ──────────────
// Every section reads DashboardKpisState.bundle; zeros render as "0", null
// rates render as "—" (never NaN). No onTap navigation per requirements.

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  const _SectionTitle(
      {required this.icon, required this.color, required this.title, this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20.r),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(subtitle!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11.spMax)),
            ),
          ],
        ],
      ),
    );
  }
}

class _VolumeQualitySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _VolumeQualitySection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final v = kpi.bundle.volume;
    final q = kpi.bundle.quality;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.query_stats,
          color: AppColors.primary,
          title: AppText.t('حجم الفحص وجودة القرارات', 'Volume & Decision Quality'),
          subtitle: AppText.t('الفترة المحددة', 'Selected period'),
        ),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
          final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
          final cards = <Widget>[
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('قيد الانتظار', 'Pending'), value: '${v.pending}', color: AppColors.warning, icon: Icons.hourglass_empty)),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('متابعات مفتوحة', 'Open follow-ups'), value: '${v.openFollowUps}', color: AppColors.info, icon: Icons.follow_the_signs_outlined, hint: AppText.t('قبول مشروط بملاحظة', 'Conditional with note'))),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('معدل القبول', 'Acceptance rate'), value: '${q.acceptanceRate}%', color: AppColors.success, icon: Icons.verified_outlined, hint: AppText.t('نهائي + مشروط', 'Approved + conditional'))),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('قبول صارم', 'Strict approval'), value: '${q.strictRate}%', color: AppColors.primary, icon: Icons.check_circle_outline)),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('نسبة كمية مرفوضة', 'Rejected qty %'), value: '${q.rejectedQtyRatio}%', color: AppColors.danger, icon: Icons.scale_outlined, hint: '${q.rejectedQty.toStringAsFixed(1)} / ${q.totalQty.toStringAsFixed(1)}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('مشروط / جزئي / كلي', 'Cond / Part / Full'), value: '${q.conditional} / ${q.partial} / ${q.rejected}', color: AppColors.accent, icon: Icons.pie_chart_outline, hint: '${AppText.t('مشروط', 'Cond')}: ${q.conditionalShare}%')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('مقابل متوسط 7 أيام', 'vs 7-day avg'), value: '${v.today} / ${v.weekAvg}', color: AppColors.primary, icon: Icons.today_outlined, hint: '${v.vsWeekAvg >= 0 ? '+' : ''}${v.vsWeekAvg.toStringAsFixed(1)}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('انتهاء / منتهي', 'Expiring / expired'), value: '${q.expiryRisk} / ${q.expired}', color: AppColors.danger, icon: Icons.event_busy_outlined, hint: AppText.t('30 يوم / منتهي', '30d / expired'))),
          ];
          return Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.md, children: cards);
        }),
        const SizedBox(height: AppSpacing.sm),
        // Decision donut: approved / conditional / partial / full.
        if (q.total > 0)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                height: 200,
                child: PieChart(
                  PieChartData(
                    centerSpaceRadius: 42,
                    sectionsSpace: 2,
                    sections: [
                      PieChartSectionData(value: q.approved.toDouble(), color: AppColors.success, title: '${q.approved}', titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      PieChartSectionData(value: q.conditional.toDouble(), color: AppColors.info, title: '${q.conditional}', titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      PieChartSectionData(value: q.partial.toDouble(), color: AppColors.warning, title: '${q.partial}', titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      PieChartSectionData(value: q.rejected.toDouble(), color: AppColors.danger, title: '${q.rejected}', titleStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _LabQcSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _LabQcSection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final lab = kpi.bundle.lab;
    final qc = kpi.bundle.qc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.biotech_outlined,
          color: AppColors.success,
          title: AppText.t('المعمل وفحوصات الجودة', 'Lab & QC Checks'),
          subtitle: AppText.t('الفترة المحددة', 'Selected period'),
        ),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
          final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
          return Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.md, children: [
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('اختبارات المعمل', 'Lab tests'), value: '${lab.totalTests}', color: AppColors.success, icon: Icons.science_outlined, hint: '${AppText.t('مقيّم', 'Evaluated')}: ${lab.evaluated}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('ناجح / راسب QC', 'QC pass / fail'), value: '${qc.pass} / ${qc.fail}', color: AppColors.primary, icon: Icons.fact_check_outlined, hint: '${AppText.t('مشروط', 'Cond')}: ${qc.conditional}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('متوسط الدرجة', 'Avg score'), value: '${qc.avgScore}%', color: AppColors.accent, icon: Icons.score_outlined, hint: '${AppText.t('إجمالي', 'Total')}: ${qc.total}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('معدل NC', 'NC rate'), value: '${qc.ncRate}%', color: AppColors.danger, icon: Icons.warning_amber_outlined, hint: 'C:${qc.critical} M:${qc.major} m:${qc.minor}')),
          ]);
        }),
      ],
    );
  }
}

class _NcrSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _NcrSection({required this.kpi});
  String _pct(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}%';
  String _days(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}d';
  @override
  Widget build(BuildContext context) {
    final n = kpi.bundle.ncr;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.report_problem_outlined,
          color: AppColors.danger,
          title: AppText.t('عدم المطابقة CAPA', 'NCR & CAPA'),
          subtitle: AppText.t('كل الفترات', 'All time'),
        ),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
          final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
          return Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.md, children: [
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('مفتوح', 'Open'), value: '${n.open}', color: AppColors.warning, icon: Icons.folder_open_outlined, hint: '${AppText.t('إجمالي', 'Total')}: ${n.total}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('متأخر', 'Overdue'), value: '${n.overdue}', color: AppColors.danger, icon: Icons.schedule_outlined, hint: '${n.overduePct.toStringAsFixed(1)}%')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('حرج', 'Critical'), value: '${n.critical}', color: AppColors.danger, icon: Icons.priority_high, hint: 'M:${n.major} m:${n.minor}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('إغلاق في الموعد', 'On-time closure'), value: _pct(n.onTimePct), color: AppColors.success, icon: Icons.event_available_outlined, hint: '${n.closedOnTime}/${n.closed}')),
            SizedBox(width: tile, child: AppSummaryCard(label: 'MTTC', value: _days(n.mttcDays), color: AppColors.primary, icon: Icons.timelapse_outlined)),
            SizedBox(width: tile, child: AppSummaryCard(label: 'MTTV', value: _days(n.mttvDays), color: AppColors.accent, icon: Icons.verified_outlined)),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('تغطية CAPA', 'CAPA coverage'), value: '${n.capaCoveragePct.toStringAsFixed(1)}%', color: AppColors.info, icon: Icons.link_outlined, hint: '${n.capaLinked}/${n.total}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('CAPA متأخر', 'CAPA overdue'), value: '${n.capaOverdue}', color: AppColors.danger, icon: Icons.alarm_outlined)),
          ]);
        }),
      ],
    );
  }
}

class _SopGoalsSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _SopGoalsSection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final s = kpi.bundle.sopGoals;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.menu_book_outlined,
          color: AppColors.accent,
          title: AppText.t('SOP والأهداف', 'SOPs & Goals'),
          subtitle: AppText.t('كل الفترات', 'All time'),
        ),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
          final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
          return Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.md, children: [
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('SOP منشور', 'SOP published'), value: '${s.sopPublished}', color: AppColors.primary, icon: Icons.description_outlined, hint: '${AppText.t('إجمالي', 'Total')}: ${s.sopTotal}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('منتهي / قريب', 'Expired / soon'), value: '${s.sopExpired} / ${s.sopExpiring}', color: AppColors.danger, icon: Icons.event_busy_outlined, hint: '${AppText.t('بانتظار', 'Pending')}: ${s.sopPending}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('أهداف نشطة', 'Active goals'), value: '${s.goalActive}', color: AppColors.accent, icon: Icons.flag_outlined, hint: '${AppText.t('إجمالي', 'Total')}: ${s.goalTotal}')),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('متأخر / مكتمل', 'Overdue / done'), value: '${s.goalOverdue} / ${s.goalCompleted}', color: AppColors.warning, icon: Icons.task_alt_outlined, hint: '${AppText.t('تقدم', 'Progress')}: ${s.goalAvgProgress}% · ${AppText.t('إجراءات', 'Actions')}: ${s.goalOverdueActions}')),
          ]);
        }),
      ],
    );
  }
}

class _InventorySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _InventorySection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final inv = kpi.bundle.inventory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.inventory_2_outlined,
          color: AppColors.info,
          title: AppText.t('المخزون', 'Inventory'),
          subtitle: AppText.t('لقطة حالية', 'Snapshot'),
        ),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
          final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
          return Wrap(spacing: AppSpacing.md, runSpacing: AppSpacing.md, children: [
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('أصناف', 'SKUs'), value: '${inv.skus}', color: AppColors.info, icon: Icons.inventory_outlined)),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('منخفض', 'Low'), value: '${inv.low}', color: AppColors.warning, icon: Icons.trending_down)),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('فارغ', 'Empty'), value: '${inv.empty}', color: AppColors.danger, icon: Icons.remove_shopping_cart_outlined)),
            SizedBox(width: tile, child: AppSummaryCard(label: AppText.t('سليم', 'OK'), value: '${inv.ok}', color: AppColors.success, icon: Icons.check_circle_outline)),
          ]);
        }),
        if (inv.lowItems.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final it in inv.lowItems)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text('${it['name']}', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.spMax, fontWeight: FontWeight.w600))),
                          Text('${it['current_qty']}/${it['min_qty']} ${it['unit'] ?? ''}', style: TextStyle(color: AppColors.danger, fontSize: 12.spMax, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _TrendChartSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _TrendChartSection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final trend = kpi.bundle.trend;
    final hasData = trend.any((t) => t.total > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.show_chart,
          color: AppColors.accent,
          title: AppText.t('اتجاه 6 أشهر: الحجم والقبول', '6-month trend: volume & approval'),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: !hasData
                ? Center(child: Text(context.l10n.monthly_trend_empty, style: TextStyle(color: AppColors.textMuted)))
                : SizedBox(
                    height: 220,
                    child: BarChart(
                      BarChartData(
                        barGroups: [
                          for (var i = 0; i < trend.length; i++)
                            BarChartGroupData(x: i, barRods: [
                              BarChartRodData(toY: trend[i].total.toDouble(), color: AppColors.primary, width: 18, borderRadius: BorderRadius.circular(4)),
                            ]),
                        ],
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36)),
                          bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                  showTitles: true,
                                  getTitlesWidget: (v, _) {
                                    final i = v.toInt();
                                    if (i < 0 || i >= trend.length) return const SizedBox.shrink();
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(trend[i].label.split(' ').first, style: const TextStyle(fontSize: 10)),
                                    );
                                  })),
                          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        ),
                        gridData: const FlGridData(show: true),
                        borderData: FlBorderData(show: false),
                      ),
                    ),
                  ),
          ),
        ),
        if (hasData)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                height: 180,
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: 100,
                    lineBarsData: [
                      LineChartBarData(
                        spots: [for (var i = 0; i < trend.length; i++) FlSpot(i.toDouble(), trend[i].approvalRate)],
                        isCurved: true,
                        color: AppColors.success,
                        barWidth: 3,
                        dotData: const FlDotData(show: true),
                      ),
                    ],
                    titlesData: FlTitlesData(
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
                      bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                              showTitles: true,
                              getTitlesWidget: (v, _) {
                                final i = v.toInt();
                                if (i < 0 || i >= trend.length) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(trend[i].label.split(' ').first, style: const TextStyle(fontSize: 10)),
                                );
                              })),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    gridData: const FlGridData(show: true),
                    borderData: FlBorderData(show: false),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AgingDefectsSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _AgingDefectsSection({required this.kpi});
  static const _labels = ['0-7', '8-14', '15-30', '31-60', '>60'];
  @override
  Widget build(BuildContext context) {
    final n = kpi.bundle.ncr;
    final maxAging = n.aging.fold<int>(0, (a, b) => a > b ? a : b);
    final maxDefect = n.topDefects.fold<int>(0, (a, d) => (d['count'] as int? ?? 0) > a ? (d['count'] as int? ?? 0) : a);
    if (n.total == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.hourglass_bottom_outlined,
          color: AppColors.warning,
          title: AppText.t('أعمار NCR المفتوحة والعيوب', 'Open NCR aging & defects'),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (var i = 0; i < _labels.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(width: 52, child: Text(_labels[i], style: TextStyle(fontSize: 12.spMax, fontWeight: FontWeight.w600))),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: maxAging == 0 ? 0 : n.aging[i] / maxAging,
                              minHeight: 8,
                              color: AppColors.warning,
                              backgroundColor: AppColors.borderMuted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(width: 32, child: Text('${n.aging[i]}', textAlign: TextAlign.end, style: TextStyle(fontSize: 12.spMax, fontWeight: FontWeight.bold))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (n.topDefects.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppText.t('أعلى العيوب', 'Top defects'), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: AppSpacing.sm),
                  for (final d in n.topDefects)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text('${d['label']}', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5.spMax))),
                              Text('${d['count']}', style: TextStyle(fontSize: 12.spMax, fontWeight: FontWeight.bold, color: AppColors.danger)),
                            ],
                          ),
                          const SizedBox(height: 3),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: maxDefect == 0 ? 0 : ((d['count'] as int? ?? 0) / maxDefect),
                              minHeight: 6,
                              color: AppColors.danger,
                              backgroundColor: AppColors.borderMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}