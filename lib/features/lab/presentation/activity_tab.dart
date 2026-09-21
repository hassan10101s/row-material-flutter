import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_card.dart';
import 'cubit/activity_cubit.dart';
/// Activity-log tab: stock adjustments + consumptions.
class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<ActivityCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('سجل النشاط | Activity log', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AppSpacing.md),
        if (state.loading) ...[
          const Center(child: CircularProgressIndicator()),
        ] else if (state.error != null) ...[
          Text(state.error!, style: TextStyle(color: AppColors.danger)),
        ] else if (state.rows.isEmpty) ...[
          const Text('لا يوجد نشاط | No activity yet'),
        ] else
          AppCard(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final r in state.rows)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          r['type'] == 'adjust'
                              ? Icons.tune
                              : Icons.science_outlined,
                          size: 20,
                          color: r['type'] == 'adjust'
                              ? AppColors.info
                              : AppColors.primary,
                        ),
                        title: Text('${r['inventory_name']}  ·  ${r['quantity_text']}'),
                        subtitle: Text(
                          '${r['user_name']}${(r['reason'] ?? '').toString().trim().isNotEmpty ? ' — ${r['reason']}' : ''}\n${r['at']}',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
                        ),
                        isThreeLine: true,
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}