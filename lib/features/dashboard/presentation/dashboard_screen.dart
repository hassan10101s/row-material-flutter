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
import '../../../design_system/widgets/app_window.dart';
import '../../../di/service_locator.dart';
import '../../../core/database/database_helper.dart';
import '../../inspections/domain/inspection_repository.dart';
import '../../reference/domain/reference_repository.dart';
import '../../inspections/presentation/cubit/inspection_form_cubit.dart';
import '../../inspections/presentation/inspection_form_screen.dart';
import 'cubit/dashboard_cubit.dart';
import 'cubit/dashboard_kpis_cubit.dart';
import 'cubit/dashboard_kpis_state.dart';
import 'cubit/dashboard_state.dart';
import '../domain/dashboard_analytics.dart' as analytics;
import '../domain/dashboard_kpis.dart';
import '../domain/dashboard_repository.dart';


/// Dashboard (port of Web DashboardView + dashboard summary analytics).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _scroll = ScrollController();
  bool _showTop = false;

  final _sectionKeys = <String, GlobalKey>{
    'overview': GlobalKey(),
    'suppliers': GlobalKey(),
    'rejections': GlobalKey(),
    'trend': GlobalKey(),
    'outlook': GlobalKey(),
    'quality': GlobalKey(),
    'stock': GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final show = _scroll.hasClients && _scroll.offset > 700;
      if (show != _showTop && mounted) setState(() => _showTop = show);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _go(String id) {
    final key = _sectionKeys[id];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeInOutCubic,
      alignment: 0.03,
    );
  }

  void _toTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<DashboardCubit>().state;
    final cubit = context.read<DashboardCubit>();
    final ready = !state.loading || state.summary != null;
    return AppErrorFeedback<DashboardCubit, DashboardState>(
      selector: (s) => s.error,
      child: Stack(
        children: [
          CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    AppSpacing.page,
                    AppSpacing.page,
                    0,
                  ),
                  child: AppEntrance(
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
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.page,
                  ),
                  child: const _QuickActionsBar(),
                ),
              ),
              // Sticky period + quick section navigation (professional scroll).
              if (ready && state.error == null)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _StickyNavBar(
                    period: state.period,
                    onPeriodChange: cubit.setPeriod,
                    onGo: _go,
                    topPadding: AppSpacing.page,
                  ),
                ),
              if (state.loading && state.summary == null)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.page),
                    child: AppSkeletonList(rows: 4, lines: 3, height: 360),
                  ),
                )
              else if (state.error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.page),
                    child: AppEmptyState(
                      icon: Icons.error_outline,
                      title: AppText.t(
                        'تعذر تحميل اللوحة',
                        'Failed to load dashboard',
                      ),
                      action: AppButton(
                        label: AppText.t('إعادة المحاولة', 'Retry'),
                        onPressed: cubit.load,
                      ),
                    ),
                  ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      AppSpacing.md,
                      AppSpacing.page,
                      0,
                    ),
                    child: BlocBuilder<DashboardKpisCubit, DashboardKpisState>(
                      builder: (context, kpi) => AppStagger(
                        interval: const Duration(milliseconds: 40),
                        children: [
                          _KpiRow(
                            todayInspections: kpi.todayInspections,
                            todayApproved: kpi.todayApproved,
                            todayRejected: kpi.todayRejected,
                            totalCount: kpi.totalCount,
                          ),
                          // Plan §6: quick quality card + daily tasks card.
                          _QcQuickCard(kpi: kpi),
                          const _DailyTasksCard(),
                        ],
                      ),
                    ),
                  ),
                ),
                if (state.summary != null) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.page,
                        AppSpacing.lg,
                        AppSpacing.page,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppEntrance(
                            child: _DecisionsOverviewCard(
                              summary: state.summary!,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          _MonthlyTrendSection(summary: state.summary!),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.page,
                        AppSpacing.lg,
                        AppSpacing.page,
                        0,
                      ),
                      child:
                          BlocBuilder<DashboardKpisCubit, DashboardKpisState>(
                            builder: (context, kpi) => Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  key: _sectionKeys['overview'],
                                  child: _ExecutiveSummarySection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                _VolumeQualitySection(kpi: kpi),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['suppliers'],
                                  child: _SupplierScorecardSection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['rejections'],
                                  child: _ParetoSection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['trend'],
                                  child: _TrendChartSection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['outlook'],
                                  child: _ForecastStabilitySection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                _DataQualitySection(kpi: kpi),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['quality'],
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _LabQcSection(kpi: kpi),
                                      const SizedBox(height: AppSpacing.lg),
                                      _NcrSection(kpi: kpi),
                                      const SizedBox(height: AppSpacing.lg),
                                      _SopGoalsSection(kpi: kpi),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['stock'],
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _InventorySection(kpi: kpi),
                                      const SizedBox(height: AppSpacing.lg),
                                      _AgingDefectsSection(kpi: kpi),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                              ],
                            ),
                          ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.page,
                        0,
                        AppSpacing.page,
                        AppSpacing.page,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _InsightsAndRecommendationsSection(
                            summary: state.summary!,
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          _TopBreakdownSection(summary: state.summary!),
                          const SizedBox(height: 80),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
          // Back-to-top floating button (no Scaffold needed).
          Positioned(
            right: 16,
            bottom: 20,
            child: AnimatedOpacity(
              opacity: _showTop ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !_showTop,
                child: Material(
                  color: AppColors.primary,
                  shape: const CircleBorder(),
                  elevation: 6,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _toTop,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(
                        Icons.arrow_upward,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StickyNavBar extends SliverPersistentHeaderDelegate {
  final String period;
  final ValueChanged<String> onPeriodChange;
  final ValueChanged<String> onGo;
  final double topPadding;
  const _StickyNavBar({
    required this.period,
    required this.onPeriodChange,
    required this.onGo,
    required this.topPadding,
  });

  // Fixed 120px window: two compact chip rows (~78 px of chips + gap at
  // default scale, more under `spMax`) plus 24 px of container padding.
  //
  // The child MUST fill the extent exactly. A pinned header reports
  // `paintExtent = min(childExtent, remaining)` against
  // `layoutExtent = maxExtent`: when the content sized itself to 102 px
  // inside a 116 px extent the geometry went invalid
  // (`layoutExtent 116 > paintExtent 102`) and crashed the whole viewport.
  // The `SizedBox` below pins the child to [_extent] so the geometry is
  // valid at every text scale; leftover space is plain header background.
  static const double _extent = 120;

  @override
  double get minExtent => _extent;
  @override
  double get maxExtent => _extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final sections = <(String, String, IconData)>[
      ('overview', AppText.t('الوضع', 'Overview'), Icons.grid_view_outlined),
      (
        'suppliers',
        AppText.t('الموردين', 'Suppliers'),
        Icons.local_shipping_outlined,
      ),
      ('rejections', AppText.t('الرفض', 'Rejects'), Icons.bar_chart_outlined),
      ('trend', AppText.t('الاتجاه', 'Trend'), Icons.show_chart),
      ('outlook', AppText.t('التوقع', 'Outlook'), Icons.auto_graph_outlined),
      ('quality', AppText.t('الجودة', 'Quality'), Icons.verified_outlined),
      ('stock', AppText.t('المخزون', 'Stock'), Icons.inventory_2_outlined),
    ];
    return SizedBox(
      height: _extent,
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        padding: EdgeInsets.fromLTRB(topPadding, 6, topPadding, 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderMuted),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (key, label) in [
                      ('7d', AppText.t('أسبوع', 'Week')),
                      ('30d', AppText.t('شهر', 'Month')),
                      ('90d', AppText.t('3 شهور', '3 months')),
                      ('365d', AppText.t('سنة', 'Year')),
                      ('ALL', AppText.t('الكل', 'All')),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(
                            label,
                            style: TextStyle(fontSize: 12.spMax),
                          ),
                          selected: period == key,
                          onSelected: (_) => onPeriodChange(key),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final s in sections)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          avatar: Icon(s.$3, size: 14.r),
                          label: Text(
                            s.$2,
                            style: TextStyle(fontSize: 11.5.spMax),
                          ),
                          onPressed: () => onGo(s.$1),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyNavBar old) =>
      old.period != period || old.topPadding != topPadding;
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
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
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
                      fontWeight: period == key
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: period == key
                          ? AppColors.primaryDeep
                          : Colors.white,
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
                            {'id': st, 'name': _statusLabel(st)},
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
                child: Text('${item['name']}', overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );
  }
}

class _QuickActionsBar extends StatelessWidget {
  const _QuickActionsBar();

  Future<void> _openNewInspection(BuildContext context) async {
    final wide = MediaQuery.of(context).size.width >= AppBreakpoints.medium;
    if (wide) {
      final saved = await showAppWindow<bool>(
        context,
        title: AppText.t('فحص خامة جديد', 'New Material Inspection'),
        icon: Icons.add_task,
        size: AppWindowSize.lg,
        scrollBody: false,
        child: BlocProvider(
          create: (c) => InspectionFormCubit(
            repo: getIt<InspectionRepository>(),
            reference: getIt<ReferenceRepository>(),
          )..loadMaterials(),
          child: const InspectionFormScreen(),
        ),
      );
      if (saved == true && context.mounted) {
        context.read<DashboardCubit>().load();
      }
    } else {
      context.go('/inspection-new');
    }
  }

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
            onTap: () => _openNewInspection(context),
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

class _ActionButton extends StatefulWidget {
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
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _isHovered = false;

  void _setHovered(bool value) {
    if (!mounted || _isHovered == value) return;
    setState(() => _isHovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: _isHovered
              ? widget.color.withValues(alpha: isDark ? 0.20 : 0.08)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _isHovered
                ? widget.color.withValues(alpha: 0.55)
                : AppColors.borderMuted,
            width: _isHovered ? 1.2 : 1.0,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(10),
            mouseCursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedScale(
                    scale: _isHovered ? 1.12 : 1.0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: Icon(widget.icon, size: 18.r, color: widget.color),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 13.spMax,
                      fontWeight: FontWeight.w600,
                      color: _isHovered ? widget.color : AppColors.textStrong,
                    ),
                  ),
                ],
              ),
            ),
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
      (
        context.l10n.kpi_today_inspections,
        '$todayInspections',
        AppColors.primary,
        Icons.event_note,
      ),
      (
        context.l10n.kpi_today_approved,
        '$todayApproved',
        AppColors.success,
        Icons.check_circle_outline,
      ),
      (
        context.l10n.kpi_today_rejected,
        '$todayRejected',
        AppColors.danger,
        Icons.cancel_outlined,
      ),
      (
        context.l10n.kpi_total,
        '$totalCount',
        AppColors.accent,
        Icons.inventory_2_outlined,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= AppBreakpoints.medium ? 4 : 2;
        final tile =
            (constraints.maxWidth - AppSpacing.md * (width - 1)) / width;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final c in cards)
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: c.$1,
                  value: c.$2,
                  color: c.$3,
                  icon: c.$4,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Plan §6 — بطاقة الجودة السريعة: فحوصات الفترة من `qc_inspections`
/// مع معدل القبول والرفض بشكل واضح.
class _QcQuickCard extends StatelessWidget {
  final DashboardKpisState kpi;
  const _QcQuickCard({required this.kpi});

  @override
  Widget build(BuildContext context) {
    final qc = kpi.bundle.qc;
    final total = qc.total;
    final acceptRate = total == 0
        ? 0.0
        : (qc.pass / total * 100);
    final rejectRate = total == 0
        ? 0.0
        : (qc.fail / total * 100);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.verified_outlined,
                  color: AppColors.success,
                  size: 22.r,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppText.t('جودة الفحوصات', 'Inspection quality'),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${AppText.t('قبول', 'Accept')}: ${acceptRate.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 12.spMax,
                      fontWeight: FontWeight.bold,
                      color: AppColors.success,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (total == 0)
              Text(
                AppText.t(
                  'لا توجد فحوصات جودة في هذه الفترة',
                  'No quality checks in this period',
                ),
                style: TextStyle(color: AppColors.textMuted),
              )
            else ...[
              Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.sm,
                children: [
                  _DecisionBadge(
                    AppText.t('مطابق', 'Pass'),
                    '${qc.pass}',
                    AppColors.success,
                  ),
                  _DecisionBadge(
                    AppText.t('مشروط', 'Conditional'),
                    '${qc.conditional}',
                    AppColors.info,
                  ),
                  _DecisionBadge(
                    AppText.t('غير مطابق', 'Fail'),
                    '${qc.fail}',
                    AppColors.danger,
                  ),
                  _DecisionBadge(
                    AppText.t('منتظر', 'Pending'),
                    '${qc.pending}',
                    AppColors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: (acceptRate / 100).clamp(0.0, 1.0),
                  minHeight: 10,
                  color: AppColors.success,
                  backgroundColor: AppColors.danger.withValues(alpha: 0.2),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      '${AppText.t('الإجمالي', 'Total')}: $total',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.spMax,
                      ),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      '${AppText.t('رفض', 'Reject')}: ${rejectRate.toStringAsFixed(1)}%',
                      style: TextStyle(
                        color: AppColors.danger,
                        fontSize: 12.spMax,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Plan §6 — بطاقة المهام اليومية: القوائم الدورية المنشورة مقابل
/// ما بدأ منها اليوم (مثال: "3 من 5 مهام يومية منجزة").
class _DailyTasksCard extends StatelessWidget {
  const _DailyTasksCard();

  Future<({int total, int done})> _load() async {
    try {
      final db = await getIt<DatabaseHelper>().database;
      // Periodic published lists (plan §3).
      List<Map<String, Object?>> templates = const [];
      try {
        templates = await db.rawQuery(
          "SELECT template_id FROM qc_templates WHERE deleted_at IS NULL "
          "AND is_published = 1 AND is_archived = 0 "
          "AND COALESCE(recurrence,'once') != 'once'",
        );
      } catch (_) {
        // Column missing on very old installs: fall back to zero.
        return (total: 0, done: 0);
      }
      if (templates.isEmpty) return (total: 0, done: 0);
      final ids = <int>{};
      for (final t in templates) {
        final id = (t['template_id'] as num?)?.toInt();
        if (id != null) ids.add(id);
      }
      final now = DateTime.now();
      String p(int v) => v.toString().padLeft(2, '0');
      final today = '${now.year}-${p(now.month)}-${p(now.day)}';
      final placeholders = List.filled(ids.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT DISTINCT template_id FROM qc_inspections '
        'WHERE deleted_at IS NULL AND template_id IN ($placeholders) '
        "AND substr(COALESCE(inspection_date,created_at,''),1,10) = ?",
        [...ids, today],
      );
      return (total: ids.length, done: rows.length);
    } catch (_) {
      return (total: 0, done: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({int total, int done})>(
      future: _load(),
      builder: (context, snap) {
        final total = snap.data?.total ?? 0;
        final done = snap.data?.done ?? 0;
        if (snap.connectionState == ConnectionState.done && total == 0) {
          // No periodic lists: hide the card (plan §6 cleanup).
          return const SizedBox.shrink();
        }
        final pct = total == 0 ? 0.0 : done / total;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.task_alt_outlined,
                      color: AppColors.info,
                      size: 22.r,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppText.t('المهام اليومية', 'Daily tasks'),
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      AppText.t(
                        '$done من $total منجزة',
                        '$done of $total done',
                      ),
                      style: TextStyle(
                        fontSize: 12.spMax,
                        fontWeight: FontWeight.bold,
                        color: AppColors.info,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: pct.clamp(0.0, 1.0),
                    minHeight: 8,
                    color: AppColors.info,
                    backgroundColor: AppColors.borderMuted,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => context.go('/qc-templates'),
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: Text(AppText.t('عرض المهام', 'View tasks')),
                  ),
                ),
              ],
            ),
          ),
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
                Icon(
                  Icons.pie_chart_outline,
                  color: AppColors.primary,
                  size: 22.r,
                ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
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
                _DecisionBadge(
                  context.l10n.decision_approved,
                  '${totals['approved'] ?? 0}',
                  AppColors.success,
                ),
                _DecisionBadge(
                  context.l10n.decision_conditional,
                  '${totals['conditional'] ?? 0}',
                  AppColors.info,
                ),
                _DecisionBadge(
                  context.l10n.decision_partial,
                  '${totals['partial'] ?? 0}',
                  AppColors.partial,
                ),
                _DecisionBadge(
                  context.l10n.decision_rejected,
                  '${totals['rejected'] ?? 0}',
                  AppColors.danger,
                ),
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
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.spMax,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '${context.l10n.rejection_rate_general}$rejectionRate%',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.danger,
                      fontSize: 12.spMax,
                      fontWeight: FontWeight.bold,
                    ),
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
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18.spMax,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5.spMax,
                color: AppColors.textStrong,
              ),
            ),
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
    final comparison =
        summary['comparison'] as Map<String, dynamic>? ?? const {};
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (sign == '+' ? AppColors.success : AppColors.danger)
                              .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      deltaLabel,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        fontWeight: FontWeight.bold,
                        color: sign == '+'
                            ? AppColors.success
                            : AppColors.danger,
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
                  child: Text(
                    context.l10n.monthly_trend_empty,
                    style: TextStyle(color: AppColors.textMuted),
                  ),
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

class _MonthlyTrendRow extends StatefulWidget {
  final Map<String, dynamic> item;
  const _MonthlyTrendRow({required this.item});

  @override
  State<_MonthlyTrendRow> createState() => _MonthlyTrendRowState();
}

class _MonthlyTrendRowState extends State<_MonthlyTrendRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final label = '${widget.item['label'] ?? ''}';
    final total = widget.item['total'] ?? 0;
    final rate = '${widget.item['approvalRate'] ?? '0.0'}';
    final approvedPct = double.tryParse('${widget.item['approvedWidth'] ?? 0}') ?? 0.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: _isHovered
              ? AppColors.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.spMax,
                      color: _isHovered ? AppColors.primary : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$total ${AppText.t('فحص', 'inspections')} — ${AppText.t('قبول', 'approved')}: $rate%',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.spMax,
                  ),
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
                          Icon(
                            Icons.tips_and_updates,
                            size: 18.r,
                            color: AppColors.warning,
                          ),
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
              final tile =
                  AppBreakpoints.fitsColumnsIn(
                    availableWidth: constraints.maxWidth,
                    columns: insightCards.length,
                    minColumnWidth: 280,
                    gap: AppSpacing.md,
                  )
                  ? (constraints.maxWidth -
                            AppSpacing.md * (insightCards.length - 1)) /
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
              style: TextStyle(
                fontSize: 12.5.spMax,
                color: AppColors.textMuted,
              ),
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
        final cardWidth =
            AppBreakpoints.fitsColumnsIn(
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
                          Icon(
                            Icons.inventory_2_outlined,
                            color: AppColors.primary,
                            size: 20.r,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppText.t('أعلى الخامات فحوصات', 'Top Materials'),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (topMaterials.isEmpty)
                        Text(
                          AppText.t(
                            'لا توجد فحوصات خامات',
                            'No material inspections',
                          ),
                          style: TextStyle(color: AppColors.textMuted),
                        )
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
                          Icon(
                            Icons.local_shipping_outlined,
                            color: AppColors.accent,
                            size: 20.r,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppText.t(
                                'أعلى الموردين فحوصات',
                                'Top Suppliers',
                              ),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (topSuppliers.isEmpty)
                        Text(
                          AppText.t(
                            'لا توجد فحوصات موردين',
                            'No supplier inspections',
                          ),
                          style: TextStyle(color: AppColors.textMuted),
                        )
                      else
                        for (final s in topSuppliers) ...[
                          _TopItemProgress(
                            label: '${s['name']}',
                            count:
                                '${s['total']} ${AppText.t('فحص', 'inspections')}',
                            rate:
                                '${s['approvalRate']}% ${AppText.t('قبول', 'approved')}',
                            value:
                                double.tryParse('${s['approvalRate']}') ?? 0.0,
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

class _TopItemProgress extends StatefulWidget {
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
  State<_TopItemProgress> createState() => _TopItemProgressState();
}

class _TopItemProgressState extends State<_TopItemProgress> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        decoration: BoxDecoration(
          color: _isHovered
              ? widget.color.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.spMax,
                      color: _isHovered ? widget.color : null,
                    ),
                  ),
                ),
                Text(
                  '${widget.count} (${widget.rate})',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.spMax,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (widget.value / 100).clamp(0.0, 1.0),
                minHeight: 6,
                color: widget.color,
                backgroundColor: AppColors.borderMuted,
              ),
            ),
          ],
        ),
      ),
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
  const _SectionTitle({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20.r),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                subtitle!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11.spMax,
                ),
              ),
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
          title: AppText.t('الفحص والقرارات', 'Checks & decisions'),
          subtitle: AppText.t('الفترة المحددة', 'Selected period'),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            final cards = <Widget>[
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('قيد الانتظار', 'Pending'),
                  value: '${v.pending}',
                  color: AppColors.warning,
                  icon: Icons.hourglass_empty,
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('متابعات مفتوحة', 'Open follow-ups'),
                  value: '${v.openFollowUps}',
                  color: AppColors.info,
                  icon: Icons.follow_the_signs_outlined,
                  hint: AppText.t(
                    'قبول مشروط بملاحظة',
                    'Conditional with note',
                  ),
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('معدل القبول', 'Acceptance rate'),
                  value: '${q.acceptanceRate}%',
                  color: AppColors.success,
                  icon: Icons.verified_outlined,
                  hint: AppText.t('نهائي + مشروط', 'Approved + conditional'),
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('قبول صارم', 'Strict approval'),
                  value: '${q.strictRate}%',
                  color: AppColors.primary,
                  icon: Icons.check_circle_outline,
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('نسبة كمية مرفوضة', 'Rejected qty %'),
                  value: '${q.rejectedQtyRatio}%',
                  color: AppColors.danger,
                  icon: Icons.scale_outlined,
                  hint:
                      '${q.rejectedQty.toStringAsFixed(1)} / ${q.totalQty.toStringAsFixed(1)}',
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('مشروط / جزئي / كلي', 'Cond / Part / Full'),
                  value: '${q.conditional} / ${q.partial} / ${q.rejected}',
                  color: AppColors.accent,
                  icon: Icons.pie_chart_outline,
                  hint: '${AppText.t('مشروط', 'Cond')}: ${q.conditionalShare}%',
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('مقابل متوسط 7 أيام', 'vs 7-day avg'),
                  value: '${v.today} / ${v.weekAvg}',
                  color: AppColors.primary,
                  icon: Icons.today_outlined,
                  hint:
                      '${v.vsWeekAvg >= 0 ? '+' : ''}${v.vsWeekAvg.toStringAsFixed(1)}',
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('انتهاء / منتهي', 'Expiring / expired'),
                  value: '${q.expiryRisk} / ${q.expired}',
                  color: AppColors.danger,
                  icon: Icons.event_busy_outlined,
                  hint: AppText.t('30 يوم / منتهي', '30d / expired'),
                ),
              ),
            ];
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: cards,
            );
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        // Decision donut: approved / conditional / partial / full + legend
        // with shares (data-analyst upgrade: composition, not just counts).
        if (q.total > 0)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SizedBox(
                    height: 200,
                    child: PieChart(
                      PieChartData(
                        centerSpaceRadius: 42,
                        sectionsSpace: 2,
                        pieTouchData: PieTouchData(
                          touchCallback: (event, response) {},
                        ),
                        sections: [
                          PieChartSectionData(
                            value: q.approved.toDouble(),
                            color: AppColors.success,
                            title: '${q.approved}',
                            titleStyle: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          PieChartSectionData(
                            value: q.conditional.toDouble(),
                            color: AppColors.info,
                            title: '${q.conditional}',
                            titleStyle: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          PieChartSectionData(
                            value: q.partial.toDouble(),
                            color: AppColors.warning,
                            title: '${q.partial}',
                            titleStyle: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          PieChartSectionData(
                            value: q.rejected.toDouble(),
                            color: AppColors.danger,
                            title: '${q.rejected}',
                            titleStyle: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      _DonutLegend(
                        color: AppColors.success,
                        label:
                            '${AppText.t('نهائي', 'Approved')} ${q.strictRate}%',
                      ),
                      _DonutLegend(
                        color: AppColors.info,
                        label:
                            '${AppText.t('مشروط', 'Conditional')} ${q.conditionalShare}%',
                      ),
                      _DonutLegend(
                        color: AppColors.warning,
                        label:
                            '${AppText.t('جزئي', 'Partial')} ${q.partialRate}%',
                      ),
                      _DonutLegend(
                        color: AppColors.danger,
                        label: '${AppText.t('كلي', 'Full')} ${q.fullRate}%',
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppText.t(
                      'القبول الموسّع (نهائي + مشروط): ${q.acceptanceRate}% • الصارم: ${q.strictRate}%',
                      'Broad acceptance (approved + conditional): ${q.acceptanceRate}% • Strict: ${q.strictRate}%',
                    ),
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.spMax,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
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
    // Plan §6 cleanup: hide when always empty.
    if (lab.totalTests == 0 && qc.total == 0) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.biotech_outlined,
          color: AppColors.success,
          title: AppText.t('المعمل وفحوصات الجودة', 'Lab & QC Checks'),
          subtitle: AppText.t('الفترة المحددة', 'Selected period'),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('اختبارات المعمل', 'Lab tests'),
                    value: '${lab.totalTests}',
                    color: AppColors.success,
                    icon: Icons.science_outlined,
                    hint:
                        '${AppText.t('مقيّم', 'Evaluated')}: ${lab.evaluated}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('ناجح / راسب QC', 'QC pass / fail'),
                    value: '${qc.pass} / ${qc.fail}',
                    color: AppColors.primary,
                    icon: Icons.fact_check_outlined,
                    hint: '${AppText.t('مشروط', 'Cond')}: ${qc.conditional}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متوسط الدرجة', 'Avg score'),
                    value: '${qc.avgScore}%',
                    color: AppColors.accent,
                    icon: Icons.score_outlined,
                    hint: '${AppText.t('إجمالي', 'Total')}: ${qc.total}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('فحص ساقط', 'Failed checks'),
                    value: '${qc.ncRate}%',
                    color: AppColors.danger,
                    icon: Icons.warning_amber_outlined,
                    hint: AppText.t(
                      'خطر:${qc.critical} كبير:${qc.major} صغير:${qc.minor}',
                      'Critical:${qc.critical} Major:${qc.major} Minor:${qc.minor}',
                    ),
                  ),
                ),
              ],
            );
          },
        ),
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
    // Plan §6 cleanup: hide when always empty.
    if (n.total == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.report_problem_outlined,
          color: AppColors.danger,
          title: AppText.t('المشاكل والحلول', 'Issues & fixes'),
          subtitle: AppText.t('كل الفترات', 'All time'),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('مفتوح', 'Open'),
                    value: '${n.open}',
                    color: AppColors.warning,
                    icon: Icons.folder_open_outlined,
                    hint: '${AppText.t('إجمالي', 'Total')}: ${n.total}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متأخر', 'Overdue'),
                    value: '${n.overdue}',
                    color: AppColors.danger,
                    icon: Icons.schedule_outlined,
                    hint: '${n.overduePct.toStringAsFixed(1)}%',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('حرج', 'Critical'),
                    value: '${n.critical}',
                    color: AppColors.danger,
                    icon: Icons.priority_high,
                    hint: AppText.t(
                      'كبير:${n.major} صغير:${n.minor}',
                      'Major:${n.major} Minor:${n.minor}',
                    ),
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('اتقفل في معاده', 'Closed on time'),
                    value: _pct(n.onTimePct),
                    color: AppColors.success,
                    icon: Icons.event_available_outlined,
                    hint: '${n.closedOnTime}/${n.closed}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متوسط القفل', 'Avg days to close'),
                    value: _days(n.mttcDays),
                    color: AppColors.primary,
                    icon: Icons.timelapse_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متوسط التحقق', 'Avg days to verify'),
                    value: _days(n.mttvDays),
                    color: AppColors.accent,
                    icon: Icons.verified_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('ليه خطة حل', 'With fix plan'),
                    value: '${n.capaCoveragePct.toStringAsFixed(1)}%',
                    color: AppColors.info,
                    icon: Icons.link_outlined,
                    hint: '${n.capaLinked}/${n.total}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('حل متأخر', 'Fix overdue'),
                    value: '${n.capaOverdue}',
                    color: AppColors.danger,
                    icon: Icons.alarm_outlined,
                  ),
                ),
              ],
            );
          },
        ),
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
    // Plan §6 cleanup: hide when always empty.
    if (s.sopTotal == 0 && s.goalTotal == 0) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.menu_book_outlined,
          color: AppColors.accent,
          title: AppText.t('الإجراءات والأهداف', 'Procedures & goals'),
          subtitle: AppText.t('كل الفترات', 'All time'),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('إجراء معتمد', 'Approved procedure'),
                    value: '${s.sopPublished}',
                    color: AppColors.primary,
                    icon: Icons.description_outlined,
                    hint: '${AppText.t('إجمالي', 'Total')}: ${s.sopTotal}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('منتهي / قريب', 'Expired / soon'),
                    value: '${s.sopExpired} / ${s.sopExpiring}',
                    color: AppColors.danger,
                    icon: Icons.event_busy_outlined,
                    hint: '${AppText.t('بانتظار', 'Pending')}: ${s.sopPending}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('أهداف نشطة', 'Active goals'),
                    value: '${s.goalActive}',
                    color: AppColors.accent,
                    icon: Icons.flag_outlined,
                    hint: '${AppText.t('إجمالي', 'Total')}: ${s.goalTotal}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متأخر / مكتمل', 'Overdue / done'),
                    value: '${s.goalOverdue} / ${s.goalCompleted}',
                    color: AppColors.warning,
                    icon: Icons.task_alt_outlined,
                    hint:
                        '${AppText.t('تقدم', 'Progress')}: ${s.goalAvgProgress}% · ${AppText.t('إجراءات', 'Actions')}: ${s.goalOverdueActions}',
                  ),
                ),
              ],
            );
          },
        ),
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
    // Plan §6 cleanup: hide when always empty.
    if (inv.skus == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.inventory_2_outlined,
          color: AppColors.info,
          title: AppText.t('المخزون', 'Inventory'),
          subtitle: AppText.t('لقطة حالية', 'Snapshot'),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('أصناف', 'Items'),
                    value: '${inv.skus}',
                    color: AppColors.info,
                    icon: Icons.inventory_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('منخفض', 'Low'),
                    value: '${inv.low}',
                    color: AppColors.warning,
                    icon: Icons.trending_down,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('فارغ', 'Empty'),
                    value: '${inv.empty}',
                    color: AppColors.danger,
                    icon: Icons.remove_shopping_cart_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('سليم', 'OK'),
                    value: '${inv.ok}',
                    color: AppColors.success,
                    icon: Icons.check_circle_outline,
                  ),
                ),
              ],
            );
          },
        ),
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
                          Expanded(
                            child: Text(
                              '${it['name']}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.spMax,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${it['current_qty']}/${it['min_qty']} ${it['unit'] ?? ''}',
                            style: TextStyle(
                              color: AppColors.danger,
                              fontSize: 12.spMax,
                              fontWeight: FontWeight.bold,
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

class _DonutLegend extends StatelessWidget {
  final Color color;
  final String label;
  const _DonutLegend({required this.color, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
        ),
      ],
    );
  }
}

class _ChartLegend extends StatelessWidget {
  final Color color;
  final String label;
  final bool dashed;
  const _ChartLegend({
    required this.color,
    required this.label,
    this.dashed = false,
  });
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 4,
          decoration: BoxDecoration(
            color: dashed ? Colors.transparent : color,
            borderRadius: BorderRadius.circular(2),
            border: dashed
                ? Border(top: BorderSide(color: color, width: 2))
                : null,
          ),
          child: dashed
              ? Row(
                  children: [
                    for (var i = 0; i < 4; i++)
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          height: 3,
                          color: color,
                        ),
                      ),
                  ],
                )
              : null,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
        ),
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
    final forecast = kpi.bundle.forecast;
    final hasData = trend.any((t) => t.total > 0);
    final maxVol = trend.fold<int>(0, (m, t) => t.total > m ? t.total : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.show_chart,
          color: AppColors.accent,
          title: AppText.t(
            'آخر 6 شهور: الفحص والقبول',
            'Last 6 months: checks & acceptance',
          ),
          subtitle: AppText.t(
            'الأعمدة = عدد الفحوص • الخط = نسبة القبول',
            'Bars = number of checks • Line = acceptance %',
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: !hasData
                ? Center(
                    child: Text(
                      context.l10n.monthly_trend_empty,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  )
                : Column(
                    children: [
                      SizedBox(
                        height: 220,
                        child: BarChart(
                          BarChartData(
                            maxY: (maxVol == 0 ? 10 : maxVol * 1.2).toDouble(),
                            barTouchData: BarTouchData(
                              touchTooltipData: BarTouchTooltipData(
                                getTooltipItem: (group, groupIndex, rod, rodIndex) {
                                  if (group.x < 0 || group.x >= trend.length) return null;
                                  final t = trend[group.x];
                                  return BarTooltipItem(
                                    '${t.label}\n${t.total} ${AppText.t('فحص', 'inspections')} • ${t.approvalRate}%',
                                    const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  );
                                },
                              ),
                            ),
                            barGroups: [
                              for (var i = 0; i < trend.length; i++)
                                BarChartGroupData(
                                  x: i,
                                  barRods: [
                                    BarChartRodData(
                                      toY: trend[i].total.toDouble(),
                                      color: trend[i].total == 0
                                          ? AppColors.borderMuted
                                          : AppColors.primary,
                                      width: 18,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ],
                                ),
                            ],
                            titlesData: FlTitlesData(
                              leftTitles: const AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 36,
                                ),
                              ),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  getTitlesWidget: (v, _) {
                                    final i = v.toInt();
                                    if (i < 0 || i >= trend.length) {
                                      return const SizedBox.shrink();
                                    }
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        trend[i].label.split(' ').first,
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                            ),
                            gridData: const FlGridData(show: true),
                            borderData: FlBorderData(show: false),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 14,
                        runSpacing: 6,
                        children: [
                          _ChartLegend(
                            color: AppColors.primary,
                            label: AppText.t('الحجم', 'Volume'),
                          ),
                          _ChartLegend(
                            color: AppColors.success,
                            label: AppText.t('القبول %', 'Approval %'),
                          ),
                          _ChartLegend(
                            color: AppColors.info,
                            label: AppText.t(
                              'متوسط آخر شهور',
                              'Recent average',
                            ),
                            dashed: true,
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
        if (hasData) ...[
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                height: 200,
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: 100,
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (spots) => [
                          for (final s in spots)
                            if (s.x.toInt() >= 0 && s.x.toInt() < trend.length)
                              LineTooltipItem(
                                '${trend[s.x.toInt()].label}\n${s.y.toStringAsFixed(1)}%',
                                const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              )
                            else
                              null,
                        ],
                      ),
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < trend.length; i++)
                            FlSpot(i.toDouble(), trend[i].approvalRate),
                        ],
                        isCurved: true,
                        color: AppColors.success,
                        barWidth: 3,
                        dotData: const FlDotData(show: true),
                      ),
                      if (forecast.any((f) => f.movingAvg != null))
                        LineChartBarData(
                          spots: [
                            for (var i = 0; i < forecast.length; i++)
                              if (forecast[i].movingAvg != null)
                                FlSpot(i.toDouble(), forecast[i].movingAvg!),
                          ],
                          isCurved: true,
                          color: AppColors.info,
                          barWidth: 2,
                          dashArray: [6, 4],
                          dotData: const FlDotData(show: false),
                        ),
                    ],
                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 40,
                          interval: 25,
                          getTitlesWidget: (v, _) => Text(
                            '${v.toInt()}%',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (v, _) {
                            final i = v.toInt();
                            if (i < 0 || i >= trend.length) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                trend[i].label.split(' ').first,
                                style: const TextStyle(fontSize: 10),
                              ),
                            );
                          },
                        ),
                      ),
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                    ),
                    gridData: const FlGridData(show: true),
                    borderData: FlBorderData(show: false),
                  ),
                ),
              ),
            ),
          ),
        ],
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
    final maxDefect = n.topDefects.fold<int>(
      0,
      (a, d) => (d['count'] as int? ?? 0) > a ? (d['count'] as int? ?? 0) : a,
    );
    if (n.total == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.hourglass_bottom_outlined,
          color: AppColors.warning,
          title: AppText.t('المشاكل المفتوحة حسب قدمها', 'Open issues by age'),
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
                        SizedBox(
                          width: 52,
                          child: Text(
                            _labels[i],
                            style: TextStyle(
                              fontSize: 12.spMax,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
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
                        SizedBox(
                          width: 32,
                          child: Text(
                            '${n.aging[i]}',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 12.spMax,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
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
                  Text(
                    AppText.t('أعلى العيوب', 'Top defects'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final d in n.topDefects)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${d['label']}',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12.5.spMax),
                                ),
                              ),
                              Text(
                                '${d['count']}',
                                style: TextStyle(
                                  fontSize: 12.spMax,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.danger,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: maxDefect == 0
                                  ? 0
                                  : ((d['count'] as int? ?? 0) / maxDefect),
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

// ── Data-scientist layer: executive summary + scorecards + Pareto +
// forecast/stability + data quality (all display-only, bilingual) ─────

String _tierWord(String tier) {
  return switch (tier) {
    'A' => AppText.t('ممتاز', 'Excellent'),
    'B' => AppText.t('جيد', 'Good'),
    'C' => AppText.t('يحتاج متابعة', 'Needs follow-up'),
    'D' => AppText.t('خطر', 'At risk'),
    _ => AppText.t('لا يوجد', 'None'),
  };
}

class _TierBadge extends StatelessWidget {
  final String tier;
  const _TierBadge(this.tier);
  @override
  Widget build(BuildContext context) {
    final color = switch (tier) {
      'A' => AppColors.success,
      'B' => AppColors.primary,
      'C' => AppColors.warning,
      'D' => AppColors.danger,
      _ => AppColors.textMuted,
    };
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        tier,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: color,
          fontSize: 13.spMax,
        ),
      ),
    );
  }
}

class _ExecutiveSummarySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _ExecutiveSummarySection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final b = kpi.bundle;
    if (b.quality.total == 0 && b.volume.total == 0) {
      return const SizedBox.shrink();
    }
    final signals = analytics.buildExecutiveSignals(
      trend: b.trend,
      suppliers: b.supplierScores,
      materialPareto: b.materialPareto,
      quality: b.dataQuality,
      totalInspections: b.quality.total,
    );
    final direction = '${signals['direction']}';
    final delta = (signals['deltaPp'] as double?) ?? 0.0;
    final dirColor = direction == 'up'
        ? AppColors.success
        : direction == 'down'
        ? AppColors.danger
        : AppColors.textMuted;
    final dirIcon = direction == 'up'
        ? Icons.trending_up
        : direction == 'down'
        ? Icons.trending_down
        : Icons.trending_flat;
    final dirText = direction == 'up'
        ? AppText.t('أحسن من الشهر اللي فات', 'Better than last month')
        : direction == 'down'
        ? AppText.t('أقل من الشهر اللي فات', 'Lower than last month')
        : direction == 'flat'
        ? AppText.t('زي الشهر اللي فات', 'Same as last month')
        : AppText.t('لسه مفيش اتجاه واضح', 'No clear trend yet');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  color: AppColors.primary,
                  size: 22.r,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppText.t('الوضع باختصار', "What's happening"),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              AppText.t(
                'من ${b.quality.total} فحص: اتقبل ${b.quality.acceptanceRate}%. $dirText (${delta >= 0 ? '+' : ''}$delta%). '
                    'أكتر رفض جاي من: ${signals['topRiskMaterial']}. '
                    'المورد اللي محتاج متابعة: ${signals['topRiskSupplier']}.',
                'Out of ${b.quality.total} inspections: ${b.quality.acceptanceRate}% accepted. $dirText (${delta >= 0 ? '+' : ''}$delta%). '
                    'Most rejections come from: ${signals['topRiskMaterial']}. '
                    'Supplier to follow up: ${signals['topRiskSupplier']}.',
              ),
              style: TextStyle(fontSize: 13.spMax, height: 1.6),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SummaryChip(
                  icon: dirIcon,
                  color: dirColor,
                  text: '$dirText ${delta >= 0 ? '+' : ''}$delta%',
                ),
                _SummaryChip(
                  icon: Icons.pie_chart_outline,
                  color: AppColors.accent,
                  text: AppText.t(
                    'أكتر رفض: ${signals['topRiskMaterial']} (${signals['concentrationPct']}%)',
                    'Top rejection: ${signals['topRiskMaterial']} (${signals['concentrationPct']}%)',
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

class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _SummaryChip({
    required this.icon,
    required this.color,
    required this.text,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14.r, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5.spMax,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SupplierScorecardSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _SupplierScorecardSection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final scores = kpi.bundle.supplierScores;
    if (scores.isEmpty) return const SizedBox.shrink();
    final maxScore = scores.fold<double>(
      0,
      (m, s) => s.score > m ? s.score : m,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.leaderboard_outlined,
          color: AppColors.primary,
          title: AppText.t('أداء الموردين', 'Supplier performance'),
          subtitle: AppText.t(
            'مرتب حسب نسبة القبول وعدد الفحوصات',
            'Sorted by acceptance % and volume',
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (var i = 0; i < scores.length; i++) ...[
                  _SupplierRow(
                    score: scores[i],
                    maxScore: maxScore,
                    rank: i + 1,
                  ),
                  if (i != scores.length - 1) const Divider(height: 16),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SupplierRow extends StatefulWidget {
  final SupplierScore score;
  final double maxScore;
  final int rank;
  const _SupplierRow({
    required this.score,
    required this.maxScore,
    required this.rank,
  });

  @override
  State<_SupplierRow> createState() => _SupplierRowState();
}

class _SupplierRowState extends State<_SupplierRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        decoration: BoxDecoration(
          color: _isHovered
              ? AppColors.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '${widget.rank}',
                style: TextStyle(
                  fontSize: 12.spMax,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textMuted,
                ),
              ),
            ),
            _TierBadge(widget.score.tier),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.score.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.spMax,
                            color: _isHovered ? AppColors.primary : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${widget.score.approvalRate}%',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13.spMax,
                          color: widget.score.tier == 'A'
                              ? AppColors.success
                              : widget.score.tier == 'D'
                              ? AppColors.danger
                              : AppColors.textStrong,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.score.total} ${AppText.t('فحص', 'inspections')} • ${AppText.t('الرفض', 'Rejected')}: ${widget.score.rejected} • ${AppText.t('الحالة', 'Status')}: ${_tierWord(widget.score.tier)}',
                    style: TextStyle(
                      fontSize: 11.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: widget.maxScore == 0
                          ? 0
                          : (widget.score.score / widget.maxScore).clamp(0.0, 1.0),
                      minHeight: 6,
                      color: AppColors.primary,
                      backgroundColor: AppColors.borderMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParetoSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _ParetoSection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final mat = kpi.bundle.materialPareto;
    final sup = kpi.bundle.supplierPareto;
    if (mat.isEmpty && sup.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.bar_chart_outlined,
          color: AppColors.warning,
          title: AppText.t('الرفض جاي منين؟', 'Where do rejections come from?'),
          subtitle: AppText.t(
            'ركز على أول 3 أسباب',
            'Focus on the top 3 first',
          ),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= AppBreakpoints.medium
                ? (c.maxWidth - AppSpacing.md) / 2
                : c.maxWidth;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                if (mat.isNotEmpty)
                  SizedBox(
                    width: wide,
                    child: _ParetoCard(
                      title: AppText.t(
                        'الرفض حسب الخامة',
                        'Rejections by material',
                      ),
                      entries: mat,
                    ),
                  ),
                if (sup.isNotEmpty)
                  SizedBox(
                    width: wide,
                    child: _ParetoCard(
                      title: AppText.t(
                        'الرفض حسب المورّد',
                        'Rejections by supplier',
                      ),
                      entries: sup,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ParetoCard extends StatelessWidget {
  final String title;
  final List<ParetoEntry> entries;
  const _ParetoCard({required this.title, required this.entries});
  @override
  Widget build(BuildContext context) {
    final maxCount = entries.fold<int>(0, (m, e) => e.count > m ? e.count : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              AppText.t(
                'ابدأ من فوق — أول سبب هو الأهم.',
                'Start from the top — the first cause matters most.',
              ),
              style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (var i = 0; i < entries.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 20,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 11.spMax,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            entries[i].label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5.spMax,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${entries[i].count} ${AppText.t('رفض', 'rejected')} (${entries[i].pct}%)',
                          style: TextStyle(
                            fontSize: 11.5.spMax,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: maxCount == 0 ? 0 : entries[i].count / maxCount,
                        minHeight: 7,
                        color: i < 3 ? AppColors.danger : AppColors.warning,
                        backgroundColor: AppColors.borderMuted,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ForecastStabilitySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _ForecastStabilitySection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final b = kpi.bundle;
    if (b.forecast.isEmpty) return const SizedBox.shrink();
    final hasAny = b.forecast.any((f) => f.hasData);
    if (!hasAny) return const SizedBox.shrink();
    final next = b.forecast.isEmpty ? null : b.forecast.last.forecast;
    final st = b.stability;
    final volColor = st.volatility == 'low'
        ? AppColors.success
        : st.volatility == 'medium'
        ? AppColors.warning
        : st.volatility == 'high'
        ? AppColors.danger
        : AppColors.textMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.auto_graph_outlined,
          color: AppColors.info,
          title: AppText.t('توقع الشهر الجاي', 'Next month outlook'),
          subtitle: AppText.t(
            'على حسب آخر 3 شهور',
            'Based on the last 3 months',
          ),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 2 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            final outlookOk = st.volatility == 'low';
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('القبول المتوقع', 'Expected acceptance'),
                    value: next == null ? '—' : '$next%',
                    color: AppColors.info,
                    icon: Icons.timeline_outlined,
                    hint: AppText.t('توقع تقريبي', 'Rough estimate'),
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('الوضع', 'Trend status'),
                    value: outlookOk
                        ? AppText.t('مستقر', 'Steady')
                        : st.volatility == 'unknown'
                        ? AppText.t('لسه بدري', 'Too early')
                        : AppText.t('متغير', 'Changing'),
                    color: outlookOk ? AppColors.success : AppColors.warning,
                    icon: Icons.waves_outlined,
                    hint: AppText.t('آخر شهور', 'Recent months'),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lightbulb_outline, color: volColor, size: 20.r),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    st.volatility == 'high'
                        ? AppText.t(
                            'النسب طالعة نازلة — استنى شهر كمان قبل ما تحكم.',
                            'Numbers are going up and down — wait one more month before judging.',
                          )
                        : st.volatility == 'medium'
                        ? AppText.t(
                            'في تغير بسيط — تابع الشهرين الجايين.',
                            'Slight change — keep watching the next two months.',
                          )
                        : st.volatility == 'low'
                        ? AppText.t(
                            'الدنيا مستقرة — ركز على المورد اللي عنده رفض كتير.',
                            'Things are steady — focus on the supplier with most rejections.',
                          )
                        : AppText.t(
                            'البيانات لسه قليلة — استنى شهرين قبل ما تستنتج.',
                            'Not enough data yet — wait two months before concluding.',
                          ),
                    style: TextStyle(fontSize: 12.5.spMax, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DataQualitySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const _DataQualitySection({required this.kpi});
  @override
  Widget build(BuildContext context) {
    final q = kpi.bundle.dataQuality;
    if (q.total == 0) return const SizedBox.shrink();
    final okColor = q.completenessPct >= 80
        ? AppColors.success
        : q.completenessPct >= 60
        ? AppColors.warning
        : AppColors.danger;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          icon: Icons.verified_outlined,
          color: AppColors.success,
          title: AppText.t(
            'بيانات ناقصة محتاجة تكملة',
            'Missing info to complete',
          ),
          subtitle: AppText.t(
            'كملها عشان النسب تبقى صح',
            'Complete it so rates stay correct',
          ),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('كامل', 'Complete'),
                    value: '${q.completenessPct}%',
                    color: okColor,
                    icon: Icons.checklist_outlined,
                    hint: AppText.t('من الفحوصات', 'of inspections'),
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('قرارات معلقة', 'Pending'),
                    value: '${q.pending}',
                    color: q.pendingPct > 10
                        ? AppColors.danger
                        : AppColors.warning,
                    icon: Icons.hourglass_empty,
                    hint: '${q.pendingPct}%',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('بدون مورّد', 'Missing supplier'),
                    value: '${q.missingSupplier}',
                    color: AppColors.warning,
                    icon: Icons.local_shipping_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('بدون صلاحية', 'Missing expiry'),
                    value: '${q.missingExpiry}',
                    color: AppColors.warning,
                    icon: Icons.event_busy_outlined,
                  ),
                ),
              ],
            );
          },
        ),
        if (q.completenessPct < 80 || q.pendingPct > 10) ...[
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    color: AppColors.warning,
                    size: 20.r,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      AppText.t(
                        'في بيانات ناقصة (${q.pending} معلق) — كمل المورد وتاريخ الصلاحية عشان تحكم صح.',
                        'Some info is missing (${q.pending} pending) — fill supplier and expiry date to judge fairly.',
                      ),
                      style: TextStyle(fontSize: 12.5.spMax, height: 1.6),
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
