import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../di/service_locator.dart';
import '../domain/lab_local_repository.dart';
import '../domain/lab_result_repository.dart';
import '../../reports/domain/report_repository.dart';
import 'activity_tab.dart';
import 'analyses_tab.dart';
import 'constants_tab.dart';
import 'cubit/activity_cubit.dart';
import 'cubit/analyses_cubit.dart';
import 'cubit/constants_cubit.dart';
import 'cubit/inventory_cubit.dart';
import 'cubit/lab_cubit.dart';
import 'cubit/lab_reports_cubit.dart';
import 'cubit/test_history_cubit.dart';
import 'inventory_tab.dart';
import 'lab_reports_tab.dart';
import 'test_history_tab.dart';

class _LabTab {
  final String label;
  final IconData icon;

  /// Builds the tab's subtree the first time it is opened, not when the screen
  /// is built.
  final WidgetBuilder builder;
  const _LabTab(this.label, this.icon, this.builder);
}

/// Builds a tab's subtree the first time that tab is selected, and keeps it
/// afterwards so its state (scroll position, filters, a running test) survives
/// a trip to another tab.
///
/// The tabs used to be constructed by `build`, which meant opening the Lab ran
/// six `load()`s and built six tables before the user looked at any of them -
/// and the `IndexedStack` built all of them on every rebuild of the screen.
class _LazyTab extends StatefulWidget {
  const _LazyTab({
    super.key,
    required this.index,
    required this.active,
    required this.builder,
  });

  final int index;
  final bool active;
  final WidgetBuilder builder;

  @override
  State<_LazyTab> createState() => _LazyTabState();
}

class _LazyTabState extends State<_LazyTab> {
  bool _visited = false;

  @override
  void didUpdateWidget(covariant _LazyTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_visited) _visited = true;
  }

  @override
  Widget build(BuildContext context) =>
      _visited ? widget.builder(context) : const SizedBox.shrink();
}

/// Lab center: inventory, analyses, run test, test history, constants,
/// activity log and lab reports (port of Web LabView panels).
class LabScreen extends StatelessWidget {
  const LabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabCubit>().state;
    final cubit = context.read<LabCubit>();
    final local = getIt<LabLocalRepository>();
    final config = getIt<LabConfigurationRepository>();
    final results = getIt<LabResultRepository>();
    final tabs = <_LabTab>[
      _LabTab(
        AppText.t('المخزون', 'Inventory'),
        Icons.inventory_2_outlined,
        (context) => BlocProvider(
          create: (_) => InventoryCubit(repo: local)..load(),
          child: const InventoryTab(),
        ),
      ),
      _LabTab(
        AppText.t('التحليلات', 'Analyses'),
        Icons.science_outlined,
        (context) => BlocProvider(
          create: (_) => AnalysesCubit(repo: config)..load(),
          child: const AnalysesTab(),
        ),
      ),
      _LabTab(
        AppText.t('سجل الفحوصات', 'Tests'),
        Icons.history,
        (context) => BlocProvider(
          create: (_) =>
              TestHistoryCubit(results: results, local: local, config: config)
                ..load(),
          child: TestHistoryTab(refreshTick: state.historyTick),
        ),
      ),
      _LabTab(
        AppText.t('الثوابت', 'Constants'),
        Icons.functions,
        (context) => BlocProvider(
          create: (_) => ConstantsCubit(repo: local)..load(),
          child: ConstantsTab(repo: local),
        ),
      ),
      _LabTab(
        AppText.t('سجل النشاط', 'Activity'),
        Icons.receipt_long_outlined,
        (context) => BlocProvider(
          create: (_) => ActivityCubit(repo: local)..load(),
          child: const ActivityTab(),
        ),
      ),
      _LabTab(
        AppText.t('تقارير المعمل', 'Reports'),
        Icons.description_outlined,
        (context) => BlocProvider(
          create: (_) => LabReportsCubit(reports: getIt<ReportRepository>()),
          child: const LabReportsTab(),
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.page,
            AppSpacing.page,
            0,
          ),
          child: Text(
            AppStrings.lab,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 46.h,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: ChoiceChip(
                      label: Text(tabs[i].label),
                      avatar: Icon(tabs[i].icon, size: 18.r),
                      selected: state.tab == i,
                      onSelected: (_) => cubit.setTab(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.page),
            child: IndexedStack(
              index: state.tab,
              children: [
                for (var i = 0; i < tabs.length; i++)
                  _LazyTab(
                    key: ValueKey('lab-tab-$i'),
                    index: i,
                    active: state.tab == i,
                    builder: tabs[i].builder,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
