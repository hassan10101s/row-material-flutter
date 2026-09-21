import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_card.dart';
import 'cubit/test_history_cubit.dart';
/// Sample-tests history tab. Reloads whenever [refreshTick] changes (i.e. a
/// test finished and the LabCubit history tick advanced).
class TestHistoryTab extends StatefulWidget {
  final int refreshTick;
  const TestHistoryTab({super.key, this.refreshTick = 0});
  @override
  State<TestHistoryTab> createState() => _TestHistoryTabState();
}
class _TestHistoryTabState extends State<TestHistoryTab> {
  @override
  void initState() {
    super.initState();
    context.read<TestHistoryCubit>().load();
  }
  @override
  void didUpdateWidget(covariant TestHistoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) {
      context.read<TestHistoryCubit>().load();
    }
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<TestHistoryCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('سجل فحوصات المختبر | Test history',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AppSpacing.md),
        if (state.loading) ...[
          const Center(child: CircularProgressIndicator()),
        ] else if (state.error != null) ...[
          Text(state.error!, style: TextStyle(color: AppColors.danger)),
        ] else if (state.rows.isEmpty) ...[
          const Text('لا توجد فحوصات | No tests yet'),
        ] else
          AppCard(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('التوقيت | Time')),
                    DataColumn(label: Text('التحليل | Analysis')),
                    DataColumn(label: Text('المصدر | Source')),
                    DataColumn(label: Text('العينة | Sample')),
                    DataColumn(label: Text('النتيجة | Result')),
                    DataColumn(label: Text('الحدود | Range')),
                    DataColumn(label: Text('حالة | State')),
                  ],
                  rows: [
                    for (final r in state.rows)
                      DataRow(
                        cells: [
                          DataCell(Text('${r['tested_at'] ?? r['created_at'] ?? ''}')),
                          DataCell(Text('${r['analysis_name']}')),
                          DataCell(Text('${r['source_name']}',
                              overflow: TextOverflow.ellipsis)),
                          DataCell(Text('${r['sample_name']}')),
                          DataCell(Text('${r['result_text']}')),
                          DataCell(Text(_rangeText(r))),
                          DataCell(_rangeBadge(r)),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
  String _rangeText(Map<String, dynamic> r) {
    final min = r['min'];
    final max = r['max'];
    if (min == null && max == null) return '-';
    return '${min ?? '...'} - ${max ?? '...'} ${r['range_unit'] ?? ''}';
  }
  Widget _rangeBadge(Map<String, dynamic> r) {
    final state = '${r['range_state'] ?? 'none'}';
    final (label, color) = switch (state) {
      'out' => ('خارج الحدود | Out', AppColors.danger),
      'in' => ('ضمن الحدود | In', AppColors.success),
      _ => ('بدون | None', AppColors.textMuted),
    };
    return Text(label, style: TextStyle(color: color, fontSize: 12.spMax));
  }
}