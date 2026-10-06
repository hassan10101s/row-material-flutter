import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_spacing.dart';
import 'cubit/inspections_cubit.dart';
import 'inspections_screen.dart';
import '../../reports/presentation/cubit/reports_cubit.dart';
import '../../reports/presentation/reports_screen.dart';

/// One entry point for raw-material inspection and its related reports.
class InspectionCenterScreen extends StatefulWidget {
  const InspectionCenterScreen({super.key, this.initialReportsTab = false});

  final bool initialReportsTab;

  @override
  State<InspectionCenterScreen> createState() => _InspectionCenterScreenState();
}

class _InspectionCenterScreenState extends State<InspectionCenterScreen> {
  late int _selectedTab = widget.initialReportsTab ? 1 : 0;

  @override
  void didUpdateWidget(covariant InspectionCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialReportsTab != widget.initialReportsTab) {
      _selectedTab = widget.initialReportsTab ? 1 : 0;
    }
  }

  @override
  Widget build(BuildContext context) => Column(
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
          AppText.t('فحص الخامات', 'Material inspections'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
      const SizedBox(height: AppSpacing.sm),
      SizedBox(
        height: 46.h,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: Row(
            children: [
              _tab(
                context,
                index: 0,
                label: AppText.t('سجل الفحوصات', 'Inspection register'),
                icon: Icons.fact_check_outlined,
              ),
              _tab(
                context,
                index: 1,
                label: AppText.t('تقارير الخامات', 'Material reports'),
                icon: Icons.description_outlined,
              ),
            ],
          ),
        ),
      ),
      Expanded(
        child: IndexedStack(
          index: _selectedTab,
          children: [
            BlocProvider.value(
              value: context.read<InspectionsCubit>(),
              child: const InspectionsScreen(),
            ),
            BlocProvider.value(
              value: context.read<ReportsCubit>(),
              child: const ReportsScreen(),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _tab(
    BuildContext context, {
    required int index,
    required String label,
    required IconData icon,
  }) => Padding(
    padding: const EdgeInsets.only(left: AppSpacing.sm),
    child: ChoiceChip(
      avatar: Icon(icon, size: 18.r),
      label: Text(label),
      selected: _selectedTab == index,
      onSelected: (_) => setState(() => _selectedTab = index),
    ),
  );
}
