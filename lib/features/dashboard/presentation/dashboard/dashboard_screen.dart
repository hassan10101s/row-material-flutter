import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/tokens/app_text_theme.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../cubit/dashboard_cubit.dart';
import '../cubit/dashboard_kpis_cubit.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../cubit/dashboard_state.dart';
import '../sections/aging_defects_section.dart';
import '../sections/data_quality_section.dart';
import '../sections/executive_summary_section.dart';
import '../sections/forecast_stability_section.dart';
import '../sections/insights_section.dart';
import '../sections/inventory_section.dart';
import '../sections/kpi_row.dart';
import '../sections/lab_qc_section.dart';
import '../sections/monthly_trend_section.dart';
import '../sections/ncr_section.dart';
import '../sections/pareto_section.dart';
import '../sections/sop_goals_section.dart';
import '../sections/supplier_scorecard_section.dart';
import '../sections/top_breakdown_section.dart';
import '../sections/trend_chart_section.dart';
import '../sections/volume_quality_section.dart';
import '../widgets/dashboard_bento_band.dart';
import '../widgets/dashboard_filter_sheet.dart';
import '../widgets/dashboard_result_line.dart';
import '../widgets/dashboard_sticky_nav_bar.dart';
import '../widgets/dashboard_to_top_button.dart';
import '../../../../router/app_router.dart';
import '../../../inspections/presentation/list/widgets/inspection_filters.dart'
    show inspectionDayIso;
/// Dashboard (port of Web DashboardView + dashboard summary analytics).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _scroll = ScrollController();

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

  /// Clamp the effective font scale for the sticky bar extent math using the
  /// design-system bounds (0.9 – 1.3).
  static double _textScaleFor(BuildContext context) {
    final raw = MediaQuery.textScalerOf(context).scale(12) / 12;
    return raw.clamp(0.9, AppTextTheme.maxTextScaleFactor);
  }

  /// Drill down to the inspection register with the given filter seeds as URL
  /// query parameters (`/inspections?status=…&supplier=…&from=…&to=…`). Empty
  /// filters are omitted so the URL stays honest.
  void _openInspections({
    String status = '',
    String supplier = '',
    String dateFrom = '',
    String dateTo = '',
  }) {
    final params = <String, String>{
      if (status.isNotEmpty) 'status': status,
      if (supplier.isNotEmpty) 'supplier': supplier,
      if (dateFrom.isNotEmpty) 'from': dateFrom,
      if (dateTo.isNotEmpty) 'to': dateTo,
    };
    final query = params.isEmpty
        ? ''
        : '?${Uri(queryParameters: params).query}';
    context.go('${AppRoutes.inspections}$query');
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
          RefreshIndicator(
            onRefresh: cubit.load,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // Sticky toolbar first: months, filter and refresh stay
                // pinned; the old top header is gone (title lives in the
                // shell topbar), so no space is wasted above it.
                if (ready && state.error == null)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: DashboardStickyNavBar(
                      onGo: _go,
                      topPadding: AppSpacing.page,
                      period: state.period,
                      onPeriodChange: cubit.setPeriod,
                      filterCount: dashboardActiveFilterCount(state),
                      onOpenFilter: () => openDashboardFilterSheet(context),
                      onRefresh: cubit.load,
                      refreshing: state.loading,
                      textScale: _textScaleFor(context),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      AppSpacing.sm,
                      AppSpacing.page,
                      0,
                    ),
                    child: DashboardResultLine(
                      summary: state.summary,
                      filtersActive: dashboardActiveFilterCount(state) > 0,
                      onClearFilters: cubit.clearFilters,
                    ),
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
                      child: AppErrorState(
                        title: AppText.t(
                          'تعذر تحميل اللوحة',
                          'Failed to load dashboard',
                        ),
                        subtitle: state.error,
                        retryLabel: AppText.t('إعادة المحاولة', 'Retry'),
                        onRetry: cubit.load,
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
                        buildWhen: (p, c) => p != c,
                        builder: (context, kpi) => AppStagger(
                          interval: const Duration(milliseconds: 40),
                          children: [
                             // Bento layout band 1: tappable hero KPIs —
                             // each tile deep-links the register with its
                             // own filter seeds.
                             DashboardKpiRow(
                               todayInspections: kpi.todayInspections,
                               todayApproved: kpi.todayApproved,
                               todayRejected: kpi.todayRejected,
                               totalCount: kpi.totalCount,
                               onOpenTodayInspections: () =>
                                   _openInspections(
                                     dateFrom: inspectionDayIso(),
                                     dateTo: inspectionDayIso(),
                                   ),
                               onOpenTodayApproved: () => _openInspections(
                                     status: 'APPROVED',
                                     dateFrom: inspectionDayIso(),
                                     dateTo: inspectionDayIso(),
                                   ),
                               onOpenTodayRejected: () => _openInspections(
                                 status: 'FULL_REJECTION',
                                 dateFrom: inspectionDayIso(),
                                 dateTo: inspectionDayIso(),
                               ),
                               onOpenTotal: () => _openInspections(),
                             ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.page,
                        AppSpacing.md,
                        AppSpacing.page,
                        0,
                      ),
                      child: BlocBuilder<DashboardKpisCubit, DashboardKpisState>(
                        buildWhen: (p, c) => p != c,
                        // Bento layout band 2: QC quick | daily tasks |
                        // decisions overview share one responsive tile group.
                        builder: (context, kpi) => DashboardBentoBand(
                          kpi: kpi,
                          summary: state.summary!,
                        ),
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
                      child: RepaintBoundary(
                        child: MonthlyTrendSection(summary: state.summary!),
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
                            buildWhen: (p, c) => p != c,
                            builder: (context, kpi) => Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  key: _sectionKeys['overview'],
                                  child: ExecutiveSummarySection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                VolumeQualitySection(kpi: kpi),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['suppliers'],
                                  child: SupplierScorecardSection(
                                    kpi: kpi,
                                    onOpenSupplier: (s) => _openInspections(
                                      supplier: s.name,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['rejections'],
                                  child: ParetoSection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['trend'],
                                  child: TrendChartSection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['outlook'],
                                  child: ForecastStabilitySection(kpi: kpi),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                DataQualitySection(kpi: kpi),
                                const SizedBox(height: AppSpacing.lg),
                                Container(
                                  key: _sectionKeys['quality'],
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      LabQcSection(kpi: kpi),
                                      const SizedBox(height: AppSpacing.lg),
                                      NcrSection(kpi: kpi),
                                      const SizedBox(height: AppSpacing.lg),
                                      SopGoalsSection(kpi: kpi),
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
                                      InventorySection(kpi: kpi),
                                      const SizedBox(height: AppSpacing.lg),
                                      AgingDefectsSection(kpi: kpi),
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
                          InsightsAndRecommendationsSection(
                            summary: state.summary!,
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          TopBreakdownSection(summary: state.summary!),
                          const SizedBox(height: 80),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Back-to-top floating button (no Scaffold needed). It owns its
          // own scroll listener so crossing the threshold never rebuilds
          // the whole dashboard sliver tree.
          DashboardToTopButton(scroll: _scroll),
        ],
      ),
    );
  }
}

/// Back-to-top button with a self-contained scroll listener.
///
/// The dashboard screen used to `setState` itself from the scroll controller,
/// rebuilding the entire sliver tree (KPIs, charts, sections) every time the
/// 700px threshold was crossed in either direction. This widget rebuilds only
/// itself.
