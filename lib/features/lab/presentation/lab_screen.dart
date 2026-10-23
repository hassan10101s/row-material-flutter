import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../di/service_locator.dart';
import '../domain/lab_local_repository.dart';
import '../domain/lab_result_repository.dart';
import '../domain/nir_validation_repository.dart';
import '../../reports/domain/report_repository.dart';
import 'activity/activity_tab.dart';
import 'analyses/analyses_tab.dart';
import 'cubit/activity_cubit.dart';
import 'cubit/analyses_cubit.dart';
import 'cubit/inventory_cubit.dart';
import 'cubit/lab_cubit.dart';
import 'cubit/lab_reports_cubit.dart';
import 'cubit/nir_validation_cubit.dart';
import 'cubit/test_history_cubit.dart';
import 'equipment/equipment_tab.dart';
import 'inventory/inventory_tab.dart';
import 'lab_reports/lab_reports_tab.dart';
import 'nir_validation/nir_validation_tab.dart';
import 'test_history/test_history_tab.dart';

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
  // The initially selected tab must build on the first frame, not after the
  // first parent rebuild.
  late bool _visited = widget.active;

  @override
  void didUpdateWidget(covariant _LazyTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_visited) _visited = true;
  }

  @override
  Widget build(BuildContext context) =>
      _visited ? widget.builder(context) : const SizedBox.shrink();
}

/// Lab center: test history (entry), analyses, activity log, lab reports,
/// equipment and inventory last (port of Web LabView panels).
class LabScreen extends StatelessWidget {
  const LabScreen({super.key, this.highlightId});

  /// Local row id from a notification deep-link (`/lab?tab=0&highlight=<id>`).
  final String? highlightId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabCubit>().state;
    final cubit = context.read<LabCubit>();
    final local = getIt<LabLocalRepository>();
    final config = getIt<LabConfigurationRepository>();
    final results = getIt<LabResultRepository>();
    final tabs = <_LabTab>[
      _LabTab(
        AppText.t('سجل التحاليل', 'Test log'),
        Icons.history,
        (context) => BlocProvider(
          create: (_) =>
              TestHistoryCubit(results: results, local: local, config: config)
                ..load(),
          child: TestHistoryTab(refreshTick: state.historyTick),
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
      _LabTab(
        AppText.t('المعدات', 'Equipment'),
        Icons.precision_manufacturing_outlined,
        (context) => const EquipmentTab(),
      ),
      _LabTab(
        AppText.t('المخزون', 'Inventory'),
        Icons.inventory_2_outlined,
        (context) => BlocProvider(
          create: (_) => InventoryCubit(repo: local)..load(),
          child: const InventoryTab(),
        ),
      ),
      _LabTab(
        AppText.t('فلديشن NIR', 'NIR Validation'),
        Icons.query_stats_outlined,
        (context) => BlocProvider(
          create: (_) => NirValidationCubit(
            repo: getIt<NirValidationRepository>(),
          )..load(),
          child: const NirValidationTab(),
        ),
      ),
    ];
    // A stale notification deep-link (`?tab=9`) must not index the
    // `IndexedStack` out of range — clamp to the real tab count.
    final tab = state.tab.clamp(0, tabs.length - 1);
    // Title lives in the shell topbar (both experiences); the tab chips
    // below already say where you are.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.page),
        if (highlightId != null && highlightId!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.sm,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.notifications_active_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      AppText.t(
                        'نتيجة جديدة من الإشعارات (رقم $highlightId) — الأحدث في الأعلى',
                        'New result from notifications (#$highlightId) — newest first',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        SizedBox(
          height: 46.h,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: AppSpacing.sm,
                    ),
                    child: ChoiceChip(
                      label: Text(tabs[i].label),
                      avatar: Icon(tabs[i].icon, size: 18.r),
                      selected: tab == i,
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
            // Soft fade between tabs; the IndexedStack underneath keeps
            // every visited tab's scroll position and running state.
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              // The default layout builder is a `Stack(alignment: center)`:
              // a tab whose content is shorter than the viewport (the test
              // log before any results, for one) was vertically centred and
              // appeared to start halfway down the page. Pinning the stack to
              // the top makes every tab begin where it is expected to.
              layoutBuilder: (currentChild, previousChildren) => Stack(
                alignment: AlignmentDirectional.topStart,
                children: [...previousChildren, ?currentChild],
              ),
              child: KeyedSubtree(
                key: ValueKey('lab-tab-body-$tab'),
                child: IndexedStack(
                  index: tab,
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      _LazyTab(
                        key: ValueKey('lab-tab-$i'),
                        index: i,
                        active: tab == i,
                        builder: tabs[i].builder,
                      ),
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
