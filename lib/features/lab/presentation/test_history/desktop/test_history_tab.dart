import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
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

/// Desktop test history: the pre-split pixels (toolbar + 10-column
/// sortable table + 1040px new-test window + 760px filter window).
class DesktopTestHistoryTab extends StatelessWidget {
  const DesktopTestHistoryTab({super.key, this.refreshTick = 0});

  final int refreshTick;

  Future<void> _openNewTest(BuildContext context) async {
    await showAppWindow<void>(
      context,
      title: AppText.t('اختبار جديد', 'New Test'),
      icon: Icons.science_outlined,
      maxWidth: 1040,
      height: 780,
      scrollBody: false,
      child: BlocProvider(
        create: (_) => RunTestCubit(
          config: getIt<LabConfigurationRepository>(),
          results: getIt<LabResultRepository>(),
          local: getIt<LabLocalRepository>(),
        )..load(),
        child: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: RunTestTab(onTestRun: () {}),
            ),
          ),
        ),
      ),
    );
    if (context.mounted) context.read<TestHistoryCubit>().load();
  }

  Future<void> _openFilterDialog(
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

    await showAppWindow<void>(
      context,
      title: AppText.t('الفلاتر', 'Filters'),
      icon: Icons.filter_alt_outlined,
      maxWidth: 760,
      height: 640,
      scrollBody: false,
      child: StatefulBuilder(
        builder: (dialogContext, setDraft) {
          Future<void> pickDate() async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: dialogContext,
              initialDate: thParseDay(dDate) ?? now,
              firstDate: DateTime(now.year - 20),
              lastDate: DateTime(now.year + 1),
            );
            if (picked == null || !dialogContext.mounted) return;
            setDraft(() => dDate = thTodayISO(picked));
          }

          return Column(
            children: [
              Expanded(
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
                    onDate: pickDate,
                    onAnalysis: (v) => setDraft(() => dAnalysis = v),
                    onSource: (v) => setDraft(() => dSource = v),
                    onChemical: (v) => setDraft(() => dChemical = v),
                    onRange: (v) => setDraft(() => dRange = v),
                    onLimit: (v) => setDraft(() => dLimit = v),
                  ),
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSoft,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(4),
                  ),
                  border: Border(top: BorderSide(color: AppColors.borderMuted)),
                ),
                child: Row(
                  children: [
                    AppButton(
                      label: AppText.t('مسح الكل', 'Clear all'),
                      style: AppButtonStyle.ghost,
                      small: true,
                      onPressed: () => setDraft(() {
                        dMode = 'all';
                        dDate = '';
                        dAnalysis = '';
                        dSource = '';
                        dChemical = '';
                        dRange = '';
                      }),
                    ),
                    const Spacer(),
                    AppButton(
                      label: AppText.t('إلغاء', 'Cancel'),
                      style: AppButtonStyle.secondary,
                      small: true,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                    const SizedBox(width: 8),
                    AppButton(
                      label: AppText.t('تطبيق', 'Apply'),
                      style: AppButtonStyle.primary,
                      small: true,
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
                        Navigator.of(dialogContext).pop();
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        AppText.t('سجل تحاليل المعمل', 'Test history'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    AppButton(
                      label: 'اختبار جديد',
                      icon: Icon(Icons.add_circle_outline, size: 18.r),
                      onPressed: () => _openNewTest(context),
                    ),
                  ],
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
                        onOpenFilters: () => _openFilterDialog(
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
                TestHistoryTable(
                  slice: d.paged.slice,
                  start: d.paged.start,
                  isEmpty: state.rows.isEmpty,
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
                if (d.paged.pageCount > 1) ...[
                  const SizedBox(height: AppSpacing.md),
                  TestHistoryPagination(
                    page: scope.page,
                    pageCount: d.paged.pageCount,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
