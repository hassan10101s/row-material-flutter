import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_field.dart';
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
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('سجل الفحوصات | History',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          AppField(
            label: 'بحث | Search',
            hint: 'رمز الدخول، الخامة، المورد، رقم الشاحنة…',
            onChanged: cubit.setQuery,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (state.loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (state.error != null)
            Expanded(
              child: AppEmptyState(
                icon: Icons.error_outline,
                title: 'تعذر التحميل',
                subtitle: state.error,
                action: TextButton(onPressed: cubit.load, child: const Text('إعادة المحاولة')),
              ),
            )
          else
            Expanded(
              child: state.rows.isEmpty
                  ? const AppEmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: 'لا توجد فحوصات بعد | No inspections yet',
                    )
                  : Card(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Scrollbar(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: DataTable(
                              columns: const [
                                DataColumn(label: Text('رقم الدخول | Code')),
                                DataColumn(label: Text('الخامة | Material')),
                                DataColumn(label: Text('التاريخ | Date')),
                                DataColumn(label: Text('المورد | Supplier')),
                                DataColumn(label: Text('الحالة | Status')),
                                DataColumn(label: Text('')),
                              ],
                              rows: [
                                for (final r in state.rows)
                                  DataRow(
                                    cells: [
                                      DataCell(Text('${r['entry_code'] ?? ''}')),
                                      DataCell(Text('${r['material_name'] ?? ''}')),
                                      DataCell(Text('${r['inspection_date'] ?? ''}')),
                                      DataCell(Text('${r['supplier'] ?? '-'}')),
                                      DataCell(AppStatusBadge('${r['decision_status'] ?? ''}')),
                                      DataCell(
                                        IconButton(
                                          icon: Icon(Icons.chevron_left, size: 18.r),
                                          tooltip: 'عرض',
                                          onPressed: () => _openDetail(context, r),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, Map<String, dynamic> row) async {
    final id = (row['id'] as num).toInt();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
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