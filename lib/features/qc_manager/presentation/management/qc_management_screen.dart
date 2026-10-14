import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../di/service_locator.dart';
import '../../../../router/app_router.dart';
import '../cubit/qc_goals_cubit.dart';
import '../cubit/qc_inspections_cubit.dart';
import '../cubit/qc_ncr_cubit.dart';
import '../cubit/qc_sops_cubit.dart';
import '../cubit/qc_templates_cubit.dart';
import '../goals/qc_goals_screen.dart';
import '../inspections/qc_inspections_screen.dart';
import '../ncr/qc_ncr_dashboard_screen.dart';
import '../sops/qc_sops_screen.dart';
import '../templates/qc_templates_screen.dart';

class _QualityTab {
  const _QualityTab({
    required this.label,
    required this.icon,
    required this.builder,
  });

  final String label;
  final IconData icon;
  final WidgetBuilder builder;
}

/// Unified entry point for quality inspection and quality-management work.
///
/// The detail registers remain dedicated screens, while this hub keeps the
/// operational and management areas one tap apart.
class QcManagementScreen extends StatefulWidget {
  const QcManagementScreen({super.key});

  @override
  State<QcManagementScreen> createState() => _QcManagementScreenState();
}

class _QcManagementScreenState extends State<QcManagementScreen> {
  int _selectedTab = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = <_QualityTab>[
      _QualityTab(
        label: AppText.t('فحوصات الجودة', 'Quality inspections'),
        icon: Icons.checklist_rtl_outlined,
        builder: (_) => BlocProvider(
          create: (_) => getIt<QcInspectionsCubit>()..load(),
          child: const QcInspectionsScreen(),
        ),
      ),
      _QualityTab(
        label: AppText.t('عدم المطابقة', 'Non-conformance'),
        icon: Icons.fact_check_outlined,
        builder: (_) => BlocProvider(
          create: (_) => getIt<QcNcrCubit>()
            ..loadOptions()
            ..load(),
          child: QcNcrDashboardScreen(
            onOpenList: () => context.push(AppRoutes.qcNcrList),
          ),
        ),
      ),
      _QualityTab(
        label: AppText.t('الأهداف', 'Goals'),
        icon: Icons.flag_outlined,
        builder: (_) => BlocProvider(
          create: (_) => getIt<QcGoalsCubit>()..load(),
          child: const QcGoalsScreen(),
        ),
      ),
      _QualityTab(
        label: AppText.t('الإجراءات SOP', 'Procedures SOP'),
        icon: Icons.menu_book_outlined,
        builder: (_) => BlocProvider(
          create: (_) => getIt<QcSopsCubit>()..load(),
          child: const QcSopsScreen(),
        ),
      ),
      _QualityTab(
        label: AppText.t('قوائم الفحص', 'Checklists'),
        icon: Icons.checklist_outlined,
        builder: (_) => BlocProvider(
          create: (_) => getIt<QcTemplatesCubit>()..load(),
          child: const QcTemplatesScreen(),
        ),
      ),
    ];

    // Title lives in the shell topbar (both experiences); the DS tab bar
    // below already says where you are.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.page),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              for (var index = 0; index < tabs.length; index++)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
                  child: AppButton(
                    small: true,
                    style: _selectedTab == index
                        ? AppButtonStyle.primary
                        : AppButtonStyle.secondary,
                    icon: Icon(tabs[index].icon, size: 18.r),
                    label: tabs[index].label,
                    onPressed: () => setState(() => _selectedTab = index),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: IndexedStack(
            index: _selectedTab,
            children: [
              for (var index = 0; index < tabs.length; index++)
                _LazyQualityTab(
                  key: ValueKey('quality-tab-$index'),
                  active: _selectedTab == index,
                  builder: tabs[index].builder,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LazyQualityTab extends StatefulWidget {
  const _LazyQualityTab({
    super.key,
    required this.active,
    required this.builder,
  });

  final bool active;
  final WidgetBuilder builder;

  @override
  State<_LazyQualityTab> createState() => _LazyQualityTabState();
}

class _LazyQualityTabState extends State<_LazyQualityTab> {
  late bool _visited = widget.active;

  @override
  void didUpdateWidget(covariant _LazyQualityTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) _visited = true;
  }

  @override
  Widget build(BuildContext context) =>
      _visited ? widget.builder(context) : const SizedBox.shrink();
}
