import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
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
import '../test_history_scope.dart';
import '../widgets/test_history_parts.dart';

/// Mobile test history: stacked toolbar + cards + full-screen new-test
/// route + filter bottom sheet (no 10-column table, no 1040px window).
class MobileTestHistoryTab extends StatelessWidget {
  const MobileTestHistoryTab({super.key, this.refreshTick = 0});

  final int refreshTick;

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
            appBar: AppBar(
              title: Text(AppText.t('اختبار جديد', 'New Test')),
            ),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.pageMobile),
                child: RunTestTab(
                  onTestRun: () {},
                ),
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
                        child: OutlinedButton(
                          onPressed: () => close(),
                          child: Text(AppText.t('إلغاء', 'Cancel')),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: AppSpacing.mobileCtaHeight.h,
                        child: FilledButton(
                          onPressed: () {
                            scope.applyFilters(
                              mode: dMode,
                              date: dDate,
                              analysis: dAnalysis,
                              source: dSource,
                              chemical: dChemical,
                              range: dRange,
                              limit: dLimit,
                            );
                            close();
                          },
                          child: Text(AppText.t('تطبيق', 'Apply')),
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppText.t('سجل تحاليل المعمل', 'Test history'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              const AppSkeletonList(rows: 8, lines: 5, height: 460),
            ],
          );
        }
        return AppErrorFeedback<TestHistoryCubit, TestHistoryState>(
          selector: (s) => s.error,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppText.t('سجل تحاليل المعمل', 'Test history'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: AppButton(
                    label: AppText.t('اختبار جديد', 'New test'),
                    icon: Icon(Icons.add_circle_outline, size: 20.r),
                    onPressed: () => _openNewTest(context),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                AppCard(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
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
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      TestHistoryChips(
                        chips: d.chips,
                        showing: d.paged.slice.length,
                        total: d.sorted.length,
                        summary: d.summary,
                        onClearAll: scope.clearAllFilters,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (d.paged.slice.isEmpty)
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
                  )
                else
                  TestHistoryCards(
                    slice: d.paged.slice,
                    start: d.paged.start,
                    onOpen: (row) async {
                      final edited = await TestHistoryDetailScreen.open(
                        context,
                        row,
                      );
                      if (edited && context.mounted) {
                        context.read<TestHistoryCubit>().load();
                      }
                    },
                  ),
                const SizedBox(height: AppSpacing.md),
                TestHistoryPagination(
                  page: scope.page,
                  pageCount: d.paged.pageCount,
                ),
                // Breathing room above the bottom nav / gesture bar.
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        );
      },
    );
  }
}
