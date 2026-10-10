import 'package:flutter/material.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../cubit/activity_cubit.dart';
import '../cubit/activity_state.dart';

/// Activity-log tab: stock adjustments + consumptions.
class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<ActivityCubit>().state;
    return AppErrorFeedback<ActivityCubit, ActivityState>(
      selector: (s) => s.error,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppText.t('سجل النشاط', 'Activity log'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.md),
            if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
            if (state.loading && state.rows.isEmpty) ...[
              const AppSkeletonList(rows: 6, lines: 3, height: 380),
            ] else if (state.rows.isEmpty) ...[
              Text(AppText.t('لا يوجد نشاط', 'No activity yet')),
            ] else
              AppCard(
                padding: EdgeInsets.zero,
                child: SizedBox(
                  width: double.infinity,
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
                          title: Text(
                            '${r['inventory_name']}  ·  ${r['quantity_text']}',
                          ),
                          subtitle: Text(
                            '${r['user_name']}${(r['reason'] ?? '').toString().trim().isNotEmpty ? ' — ${r['reason']}' : ''}\n${r['at']}',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12.spMax,
                            ),
                          ),
                          isThreeLine: true,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
