import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/animations/app_animations.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../design_system/widgets/app_paginated_table.dart';
import '../../../design_system/widgets/app_status_badge.dart';
import '../../../di/service_locator.dart';
import '../../inspections/data/inspection_repo.dart';
import '../../inspections/presentation/cubit/inspection_detail_cubit.dart';
import '../../inspections/presentation/inspection_detail_screen.dart';
import '../../reports/data/report_service.dart';
import 'cubit/history_cubit.dart';

/// Inspection history (port of Web HistoryView).
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HistoryCubit>().state;
    final cubit = context.read<HistoryCubit>();
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppText.t('سجل الفحوصات', 'History'),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          AppField(
            label: AppText.t('بحث', 'Search'),
            hint: 'رمز الدخول، الخامة، المورد، رقم الشاحنة…',
            onChanged: cubit.setQuery,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (state.error != null)
            Expanded(
              child: AppEmptyState(
                icon: Icons.error_outline,
                title: AppText.t('تعذر التحميل', 'Failed to load'),
                subtitle: state.error,
                action: TextButton(onPressed: cubit.load, child: const Text('إعادة المحاولة')),
              ),
            )
          else
            Expanded(
              child: state.loading
                  ? const Center(child: CircularProgressIndicator())
                  : state.rows.isEmpty
                      ? AppEmptyState(
                          icon: Icons.inventory_2_outlined,
                          title: AppText.t('لا توجد فحوصات بعد', 'No inspections yet'),
                        )
                      : AppPaginatedTable(
                      loading: state.loading,
                      headers: [
                        AppText.t('رقم الدخول', 'Code'),
                        AppText.t('الخامة', 'Material'),
                        AppText.t('التاريخ', 'Date'),
                        AppText.t('المورد', 'Supplier'),
                        AppText.t('الحالة', 'Status'),
                        '',
                      ],
                      rows: [
                        for (final r in state.rows)
                          [
                            Text('${r['entry_code'] ?? ''}'),
                            Text('${r['material_name'] ?? ''}'),
                            Text('${r['inspection_date'] ?? ''}'),
                            Text('${r['supplier'] ?? '-'}'),
                            AppStatusBadge('${r['decision_status'] ?? ''}'),
                            IconButton(
                              icon: Icon(Icons.chevron_left, size: 18.r),
                              tooltip: AppText.t('عرض', 'View'),
                              onPressed: () => _openDetail(context, r),
                            ),
                          ],
                      ],
                      onRowTap: (index) => _openDetail(context, state.rows[index]),
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, Map<String, dynamic> row) async {
    final id = (row['id'] as num).toInt();
    final changed = await Navigator.of(context).push<bool>(
      AppPageRoute(
        builder: (_) => BlocProvider(
          create: (c) => InspectionDetailCubit(
            inspectionId: id,
            repo: getIt<InspectionRepo>(),
            reports: getIt<ReportService>(),
          )..load(),
          child: InspectionDetailScreen(inspectionId: id),
        ),
      ),
    );
    if (changed == true && context.mounted) {
      context.read<HistoryCubit>().load();
    }
  }
}