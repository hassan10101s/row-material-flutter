import '../../../../design_system/widgets/app_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../cubit/daily_tasks_cubit.dart';
import '../../../../design_system/widgets/app_card.dart';

class DailyTasksCard extends StatelessWidget {
  const DailyTasksCard({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DailyTasksCubit, DailyTasksState>(
      buildWhen: (p, c) => p != c,
      builder: (context, s) {
        if (!s.hasTasks) {
          // No periodic lists: hide the card (plan §6 cleanup).
          return const SizedBox.shrink();
        }
        final total = s.total;
        final done = s.done;
        final pct = total == 0 ? 0.0 : done / total;
        return AppCard(
          padding: EdgeInsets.zero,
          enableHover: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.task_alt_outlined,
                      color: AppColors.info,
                      size: 22.r,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppText.t('المهام اليومية', 'Daily tasks'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      AppText.t(
                        '$done من $total منجزة',
                        '$done of $total done',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        fontWeight: FontWeight.bold,
                        color: AppColors.info,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: pct.clamp(0.0, 1.0),
                    minHeight: 8,
                    color: AppColors.info,
                    backgroundColor: AppColors.borderMuted,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AppButton(
                    onPressed: () => context.go('/quality-management'),
                    label: AppText.t('عرض المهام', 'View tasks'),
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    style: AppButtonStyle.ghost,
                    small: true,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
