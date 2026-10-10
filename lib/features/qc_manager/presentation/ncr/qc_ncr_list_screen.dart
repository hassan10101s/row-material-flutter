import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/responsive/form_factor.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_adaptive_list.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../cubit/qc_ncr_cubit.dart';
import 'widgets/ncr_list_parts.dart';

/// The NCR register: one card list on every form factor (unified mobile
/// logic — no table/desktop split). Cards, filters, pills and the filter
/// sheet are the shared pieces in [ncr_list_parts], so all experiences
/// render the same data the same way.
class QcNcrListScreen extends StatelessWidget {
  const QcNcrListScreen({super.key, this.cubit, this.onOpenFinding});

  /// Optional so the same widget works under a `BlocProvider` (the router,
  /// which then owns and closes the cubit) and standalone (tests, previews).
  final QcNcrCubit? cubit;

  /// Called with the tapped finding's id. Optional so the list can be used
  /// in tests and embedded previews without a router.
  final void Function(int findingId)? onOpenFinding;

  @override
  Widget build(BuildContext context) {
    final cubit = this.cubit ?? context.read<QcNcrCubit>();
    return BlocBuilder<QcNcrCubit, QcNcrState>(
      bloc: cubit,
      builder: (context, state) {
        return Scaffold(
          appBar: AppTopAppBar(
            title: AppText.t('حالات عدم المطابقة', 'Non-conformances'),
            actions: [
              IconButton(
                tooltip: AppText.t('تصفية', 'Filters'),
                onPressed: () => openNcrFilters(context, state, cubit),
                icon: Badge(
                  isLabelVisible: state.hasFilters,
                  child: const Icon(Icons.filter_list),
                ),
              ),
              IconButton(
                tooltip: AppText.t('تحديث', 'Refresh'),
                onPressed: state.loading ? null : cubit.load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Column(
            children: [
              if (state.hasFilters) NcrActiveFilterChips(state: state),
              Expanded(
                child: state.error != null && state.rows.isEmpty
                    ? AppEmptyState(
                        icon: Icons.error_outline,
                        title: AppText.t(
                          'تعذر تحميل التقرير',
                          'Report unavailable',
                        ),
                        subtitle: state.error,
                        action: AppButton(
                          label: AppText.t('إعادة المحاولة', 'Retry'),
                          icon: const Icon(Icons.refresh),
                          onPressed: cubit.load,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // The old table carried the total in its footer;
                          // cards have no footer, so the count sits above
                          // the list instead of disappearing.
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.md,
                              AppSpacing.sm,
                              AppSpacing.md,
                              0,
                            ),
                            child: Text(
                              state.total == 0
                                  ? AppText.t('لا نتائج', 'No results')
                                  : '${state.total}',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12.spMax,
                              ),
                            ),
                          ),
                          Expanded(
                            // Wide screens keep the readable card column
                            // instead of stretching rows edge to edge.
                            child: Center(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      FormFactor.current.isMobile ? 720 : 960,
                                ),
                                child: AppAdaptiveDataView(
                                  cardsOnly: true,
                                  headers: ncrHeaders(),
                                  rows: [
                                    for (final r in state.rows)
                                      AppDataRow(
                                        cells: ncrCells(r),
                                        secondary: r.description,
                                        onTap: onOpenFinding == null
                                            ? null
                                            : () => onOpenFinding!(r.findingId),
                                      ),
                                  ],
                                  onRowTap: onOpenFinding == null
                                      ? null
                                      : (index) => onOpenFinding!(
                                          state.rows[index].findingId,
                                        ),
                                  loading: state.loading,
                                  empty: AppEmptyState(
                                    icon: Icons.inbox_outlined,
                                    title: AppText.t(
                                      'لا توجد حالات مطابقة',
                                      'No non-conformances match',
                                    ),
                                    subtitle: state.hasFilters
                                        ? AppText.t(
                                            'وسّع نطاق التاريخ أو أزل بعض عوامل التصفية',
                                            'Widen the date range or drop a filter',
                                          )
                                        : null,
                                  ),
                                  headerTrailing: state.loading
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
