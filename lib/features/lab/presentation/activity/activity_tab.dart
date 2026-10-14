import 'package:flutter/material.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/responsive/form_factor.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_page_header.dart';
import '../cubit/activity_cubit.dart';
import '../cubit/activity_state.dart';

/// Activity-log tab: stock adjustments + consumptions.
///
/// Lazily built (`SliverList`, up to 300 rows): an eager `Column` built
/// every tile on each frame.
class ActivityTab extends StatelessWidget {
  const ActivityTab({super.key});
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ActivityCubit>();
    final state = context.watch<ActivityCubit>().state;
    return AppErrorFeedback<ActivityCubit, ActivityState>(
      selector: (s) => s.error,
      child: RefreshIndicator(
        onRefresh: () => cubit.load(),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Desktop title lives in the shell topbar.
                  if (FormFactor.current.isMobile) ...[
                    AppPageHeader(
                      title: AppText.t('سجل النشاط', 'Activity log'),
                      subtitle:
                          '${state.rows.length} ${AppText.t('حدث', 'events')}',
                      icon: Icons.history_outlined,
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (state.loading && state.rows.isNotEmpty)
                    const AppRefreshBar(),
                ],
              ),
            ),
            if (state.loading && state.rows.isEmpty)
              const SliverToBoxAdapter(
                child: AppSkeletonList(rows: 6, lines: 3, height: 380),
              )
            else if (state.rows.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: state.error != null
                    ? AppErrorState(
                        title: AppText.t('تعذّر التحميل', 'Could not load'),
                        subtitle: state.error,
                        onRetry: () => cubit.load(),
                      )
                    : AppEmptyState(
                        icon: Icons.history_outlined,
                        title: AppText.t('لا يوجد نشاط', 'No activity yet'),
                        subtitle: AppText.t(
                          'ستظهر هنا حركات المخزون والاستهلاك.',
                          'Stock and consumption events will appear here.',
                        ),
                      ),
              )
            else
              SliverList.separated(
                itemCount: state.rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = state.rows[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      r['type'] == 'adjust'
                          ? Icons.tune
                          : Icons.science_outlined,
                      size: 20.r,
                      color: r['type'] == 'adjust'
                          ? AppColors.info
                          : AppColors.primary,
                    ),
                    title: Text(
                      '${r['inventory_name']}  ·  ${r['quantity_text']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${r['user_name']}${(r['reason'] ?? '').toString().trim().isNotEmpty ? ' — ${r['reason']}' : ''}\n${r['at']}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.spMax,
                      ),
                    ),
                    isThreeLine: true,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
