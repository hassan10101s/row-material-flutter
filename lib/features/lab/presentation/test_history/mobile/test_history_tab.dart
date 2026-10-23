import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../../core/test_history_logic.dart';
import '../../../domain/lab_local_repository.dart';
import '../../../domain/lab_result_repository.dart';
import '../../cubit/run_test_cubit.dart';
import '../../cubit/test_history_cubit.dart';
import '../../cubit/test_history_state.dart';
import '../../run_test/run_test_tab.dart';
import '../test_history_detail_screen.dart';
import '../test_history_linked_report.dart';
import '../test_history_pdf.dart';
import '../test_history_scope.dart';
import '../widgets/test_history_parts.dart';

/// Mobile test history: stacked toolbar + cards + full-screen new-test
/// route + filter bottom sheet (no 10-column table, no 1040px window).
class MobileTestHistoryTab extends StatelessWidget {
  const MobileTestHistoryTab({super.key, this.refreshTick = 0});

  final int refreshTick;

  /// In select mode a tap toggles the checkbox instead of opening the editor.
  Future<void> _openRow(
    BuildContext context,
    TestHistoryScopeState scope,
    Map<String, dynamic> row,
  ) async {
    if (scope.selecting) {
      scope.toggleSelected(thRowKey(row));
      return;
    }
    final edited = await TestHistoryDetailScreen.open(context, row);
    if (context.mounted && edited) {
      context.read<TestHistoryCubit>().load();
    }
  }

  Future<void> _openNewTest(BuildContext context) async {
    await Navigator.of(context).push<void>(
      appMaterialPageRoute<void>(
        builder: (_) => BlocProvider(
          create: (_) => RunTestCubit(
            config: getIt<LabConfigurationRepository>(),
            results: getIt<LabResultRepository>(),
            local: getIt<LabLocalRepository>(),
          )..load(),
          child: Scaffold(
            appBar: AppBar(title: Text(AppText.t('اختبار جديد', 'New Test'))),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.pageMobile),
                child: RunTestTab(onTestRun: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    if (context.mounted) context.read<TestHistoryCubit>().load();
  }

  Future<void> _openFilterSheet(
    BuildContext context,
    TestHistoryScopeState scope,
    TestHistoryState state,
    List<({String value, String label})> chemOptions,
  ) async {
    var dMode = scope.filterMode;
    var dDate = scope.specificDate;
    var dAnalysis = scope.analysisId;
    var dSource = scope.sourceType;
    var dChemical = scope.chemicalId;
    var dRange = scope.rangeState;
    var dReason = scope.reasonState;
    var dLimit = scope.recordLimit;

    await showAppOverlay<void>(
      context,
      title: AppText.t('الفلاتر', 'Filters'),
      icon: Icons.filter_alt_outlined,
      builder: (sheetContext, close) {
        return StatefulBuilder(
          builder: (context, setDraft) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    child: testHistoryFilterGrid(
                      state,
                      chemOptions,
                      mode: dMode,
                      specificDate: dDate,
                      analysisId: dAnalysis,
                      sourceType: dSource,
                      chemicalId: dChemical,
                      rangeState: dRange,
                      reasonState: dReason,
                      recordLimit: dLimit,
                      onMode: (v) => setDraft(() {
                        dMode = v;
                        if (v != 'specific-date') {
                          dDate = '';
                        } else if (dDate.isEmpty) {
                          dDate = thTodayISO();
                        }
                      }),
                      onDate: () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: thParseDay(dDate) ?? now,
                          firstDate: DateTime(now.year - 20),
                          lastDate: DateTime(now.year + 1),
                        );
                        if (picked == null) return;
                        setDraft(() => dDate = thTodayISO(picked));
                      },
                      onAnalysis: (v) => setDraft(() => dAnalysis = v),
                      onSource: (v) => setDraft(() => dSource = v),
                      onChemical: (v) => setDraft(() => dChemical = v),
                      onRange: (v) => setDraft(() => dRange = v),
                      onReason: (v) => setDraft(() => dReason = v),
                      onLimit: (v) => setDraft(() => dLimit = v),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: AppSpacing.mobileCtaHeight.h,
                        child: AppButton(
                          label: AppText.t('إلغاء', 'Cancel'),
                          style: AppButtonStyle.secondary,
                          expanded: true,
                          onPressed: () => close(),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: AppSpacing.mobileCtaHeight.h,
                        child: AppButton(
                          label: AppText.t('تطبيق', 'Apply'),
                          expanded: true,
                          onPressed: () {
                            scope.applyFilters(
                              mode: dMode,
                              date: dDate,
                              analysis: dAnalysis,
                              source: dSource,
                              chemical: dChemical,
                              range: dRange,
                              reason: dReason,
                              limit: dLimit,
                            );
                            close();
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return TestHistoryScope(
      refreshTick: refreshTick,
      builder: (context, scope, d) {
        final state = context.watch<TestHistoryCubit>().state;
        if (state.loading && state.rows.isEmpty) {
          return const AppSkeletonList(rows: 8, lines: 5, height: 460);
        }
        return AppErrorFeedback<TestHistoryCubit, TestHistoryState>(
          selector: (s) => s.error,
          // Own Scaffold so the add action floats exactly like the
          // raw-material register instead of blocking the top of the
          // screen. No title: the tab chip already says where you are.
          // No hero animation: sibling lab tabs share one IndexedStack,
          // so default-tagged FAB heroes would collide (same rule as the
          // inspections registers).
          child: Scaffold(
            backgroundColor: AppColors.background,
            floatingActionButton: FloatingActionButton(
              heroTag: null,
              tooltip: AppText.t('اختبار جديد', 'New test'),
              onPressed: () => _openNewTest(context),
              child: Icon(Icons.add, size: 24.r),
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Pinned: search + filters + counts never scroll away.
                AppCard(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TestHistoryToolbar(
                        chips: d.chips,
                        hasQuery: scope.query.text.isNotEmpty,
                        onOpenFilters: () => _openFilterSheet(
                          context,
                          scope,
                          state,
                          d.chemOptions,
                        ),
                        onClearAll: scope.clearAllFilters,
                        onExportPdf: d.sorted.isEmpty
                            ? null
                            : () => TestHistoryPdf.export(context, d.sorted),
                      ),
                      // Active filters ride on their own single scrollable
                      // line, and only when something is actually filtered —
                      // so the pinned header is one row by default and never
                      // grows past two single-line rows. The filter button
                      // badge already carries the active count.
                      if (d.chips.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.sm),
                        TestHistoryChips(
                          chips: d.chips,
                          showing: d.paged.slice.length,
                          total: d.sorted.length,
                          summary: d.summary,
                          onClearAll: scope.clearAllFilters,
                        ),
                      ],
                    ],
                  ),
                ),
                if (scope.selecting) ...[
                  const SizedBox(height: AppSpacing.sm),
                  TestHistorySelectionBar(
                    rows: scope.selectedRows(d.sorted),
                    onClear: scope.clearSelection,
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => context.read<TestHistoryCubit>().load(),
                    // Perf: the slice can hold up to thPageSize* rows; eager
                    // Column layout inside a SingleChildScrollView built and
                    // laid out every card at once. A CustomScrollView keeps
                    // the card list virtualized — offscreen cards cost
                    // nothing. Empty state keeps the simple scroll view.
                    child: d.paged.slice.isEmpty
                        ? SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AppEmptyState(
                                  icon: Icons.science_outlined,
                                  title: state.rows.isEmpty
                                      ? AppText.t(
                                          'لا توجد تحاليل بعد',
                                          'No analyses yet',
                                        )
                                      : AppText.t(
                                          'لا توجد نتائج مطابقة',
                                          'No matching results',
                                        ),
                                ),
                                const SizedBox(height: AppSpacing.md),
                                TestHistoryPagination(
                                  page: scope.page,
                                  pageCount: d.paged.pageCount,
                                ),
                                // Breathing room above the FAB / gesture bar.
                                const SizedBox(height: 80),
                              ],
                            ),
                          )
                        : CustomScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              SliverPadding(
                                padding: const EdgeInsets.only(
                                  bottom: AppSpacing.md,
                                ),
                                sliver: SliverList.builder(
                                  itemCount: d.paged.slice.length,
                                  itemBuilder: (cardContext, i) {
                                    final row = d.paged.slice[i];
                                    return Padding(
                                      // md (12) between cards so they read as
                                      // separate tappable rows instead of one
                                      // stuck mass — sm (8) is reserved for
                                      // in-card gaps.
                                      padding: const EdgeInsets.only(
                                        bottom: AppSpacing.md,
                                      ),
                                      child: RepaintBoundary(
                                        child: TestHistoryCard(
                                          key: ValueKey(thRowKey(row)),
                                          row: row,
                                          index: d.paged.start + i + 1,
                                          onTap: scope.selecting
                                              ? null
                                              : () => _openRow(
                                                  context,
                                                  scope,
                                                  row,
                                                ),
                                          onOpenReport: () =>
                                              openLinkedInspection(
                                                context,
                                                row,
                                              ),
                                          selected: scope.selectedIds.contains(
                                            thRowKey(row),
                                          ),
                                          showSelect: scope.selecting,
                                          onToggleSelect: () => scope
                                              .toggleSelected(thRowKey(row)),
                                          onLongPress: () => scope
                                              .toggleSelected(thRowKey(row)),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TestHistoryPagination(
                                      page: scope.page,
                                      pageCount: d.paged.pageCount,
                                    ),
                                    // Breathing room above the FAB / gesture bar.
                                    const SizedBox(height: 80),
                                  ],
                                ),
                              ),
                            ],
                          ),
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
