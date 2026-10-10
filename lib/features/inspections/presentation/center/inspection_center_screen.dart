import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../di/service_locator.dart';
import '../../../reports/domain/report_repository.dart';
import '../../domain/inspection_repository.dart';
import '../cubit/inspections_cubit.dart';
import '../list/inspections_screen.dart';
import '../../../reports/presentation/cubit/reports_cubit.dart';
import '../../../reports/presentation/report/reports_screen.dart';

/// One entry point for raw-material inspection, product (batch) inspection
/// and their related reports.
///
/// Tab 0 is the raw-material register (the legacy screen, `kind = 'raw'`),
/// tab 1 is the product register directly below it (`kind = 'product'`: one
/// row per production batch with formula/batch numbers instead of
/// supplier/vehicle), tab 2 holds the material reports. Both registers share
/// the same screens, cubits and sync pipeline — only the kind filter and the
/// header fields differ.
class InspectionCenterScreen extends StatefulWidget {
  const InspectionCenterScreen({super.key, this.initialReportsTab = false});

  final bool initialReportsTab;

  @override
  State<InspectionCenterScreen> createState() => _InspectionCenterScreenState();
}

class _InspectionCenterScreenState extends State<InspectionCenterScreen> {
  late int _selectedTab = widget.initialReportsTab ? 2 : 0;

  /// The product register owns its cubit (kind filter + paging live there);
  /// the raw register keeps using the router-provided one above this screen.
  /// Its first `load()` is deferred until the tab is first opened, so opening
  /// the center never pays for two registers plus reports up front.
  late final InspectionsCubit _productCubit = InspectionsCubit(
    repo: getIt<InspectionRepository>(),
    reports: getIt<ReportRepository>(),
    kind: 'product',
  );
  bool _productVisited = false;

  void _selectTab(int index) {
    if (index == 1 && !_productVisited) {
      _productVisited = true;
      _productCubit.load();
    }
    setState(() => _selectedTab = index);
  }

  @override
  void dispose() {
    _productCubit.close();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant InspectionCenterScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialReportsTab != widget.initialReportsTab) {
      _selectTab(widget.initialReportsTab ? 2 : 0);
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
          AppText.t('فحص الخامات والمنتجات', 'Material & product inspections'),
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
                label: AppText.t('فحص المنتجات', 'Product inspections'),
                icon: Icons.factory_outlined,
              ),
              _tab(
                context,
                index: 2,
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
              value: _productCubit,
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
    padding: const EdgeInsetsDirectional.only(start: AppSpacing.sm),
    child: ChoiceChip(
      avatar: Icon(icon, size: 18.r),
      label: Text(label),
      selected: _selectedTab == index,
      onSelected: (_) => _selectTab(index),
    ),
  );
}
