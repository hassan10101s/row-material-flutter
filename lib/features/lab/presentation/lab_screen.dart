import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../di/service_locator.dart';
import '../data/lab_repo.dart';
import '../../reports/data/report_service.dart';
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
  final Widget child;
  const _LabTab(this.label, this.icon, this.child);
}

/// Lab center: inventory, analyses, run test, test history, constants,
/// activity log and lab reports (port of Web LabView panels).
class LabScreen extends StatelessWidget {
  const LabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabCubit>().state;
    final cubit = context.read<LabCubit>();
    final repo = getIt<LabRepo>();
    final tabs = <_LabTab>[
      _LabTab(
        AppText.t('المخزون', 'Inventory'),
        Icons.inventory_2_outlined,
        BlocProvider(
          create: (_) => InventoryCubit(repo: repo)..load(),
          child: const InventoryTab(),
        ),
      ),
      _LabTab(
        AppText.t('التحليلات', 'Analyses'),
        Icons.science_outlined,
        BlocProvider(
          create: (_) => AnalysesCubit(repo: repo)..load(),
          child: const AnalysesTab(),
        ),
      ),
      _LabTab(
        AppText.t('سجل الفحوصات', 'Tests'),
        Icons.history,
        BlocProvider(
          create: (_) => TestHistoryCubit(repo: repo)..load(),
          child: TestHistoryTab(refreshTick: state.historyTick),
        ),
      ),
      _LabTab(
        AppText.t('الثوابت', 'Constants'),
        Icons.functions,
        BlocProvider(
          create: (_) => ConstantsCubit(repo: repo)..load(),
          child: const ConstantsTab(),
        ),
      ),
      _LabTab(
        AppText.t('سجل النشاط', 'Activity'),
        Icons.receipt_long_outlined,
        BlocProvider(
          create: (_) => ActivityCubit(repo: repo)..load(),
          child: const ActivityTab(),
        ),
      ),
      _LabTab(
        AppText.t('تقارير المختبر', 'Reports'),
        Icons.description_outlined,
        BlocProvider(
          create: (_) => LabReportsCubit(reports: getIt<ReportService>()),
          child: const LabReportsTab(),
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.page, AppSpacing.page, 0),
          child: Text(AppStrings.lab, style: Theme.of(context).textTheme.headlineSmall),
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
            child: IndexedStack(index: state.tab, children: [for (final t in tabs) t.child]),
          ),
        ),
      ],
    );
  }
}