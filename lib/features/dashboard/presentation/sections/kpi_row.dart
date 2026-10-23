import 'package:flutter/material.dart';
import 'package:material_lab/core/l10n/app_localizations_x.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_format.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_summary_card.dart';

/// Hero KPI strip: today's inspections / approved / rejected plus the
/// all-time total. Cards become tappable when an [onOpen*] callback is
/// provided (drill-down to the filtered inspection list).
class DashboardKpiRow extends StatelessWidget {
  final int todayInspections;
  final int todayApproved;
  final int todayRejected;
  final int totalCount;
  final VoidCallback? onOpenTodayInspections;
  final VoidCallback? onOpenTodayApproved;
  final VoidCallback? onOpenTodayRejected;
  final VoidCallback? onOpenTotal;
  const DashboardKpiRow({
    super.key,
    required this.todayInspections,
    required this.todayApproved,
    required this.todayRejected,
    required this.totalCount,
    this.onOpenTodayInspections,
    this.onOpenTodayApproved,
    this.onOpenTodayRejected,
    this.onOpenTotal,
  });
  @override
  Widget build(BuildContext context) {
    final drillHint = AppText.t('اضغط للتفاصيل', 'Tap for details');
    final cards = <(String, String, Color, IconData, VoidCallback?)>[
      (
        context.l10n.kpi_today_inspections,
        '$todayInspections',
        AppColors.primary,
        Icons.event_note,
        onOpenTodayInspections,
      ),
      (
        context.l10n.kpi_today_approved,
        '$todayApproved',
        AppColors.success,
        Icons.check_circle_outline,
        onOpenTodayApproved,
      ),
      (
        context.l10n.kpi_today_rejected,
        '$todayRejected',
        AppColors.danger,
        Icons.cancel_outlined,
        onOpenTodayRejected,
      ),
      (
        context.l10n.kpi_total,
        formatCount(totalCount),
        AppColors.accent,
        Icons.inventory_2_outlined,
        onOpenTotal,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= AppBreakpoints.medium ? 4 : 2;
        final tile =
            (constraints.maxWidth - AppSpacing.md * (width - 1)) / width;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final c in cards)
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: c.$1,
                  value: c.$2,
                  color: c.$3,
                  icon: c.$4,
                  onTap: c.$5,
                  hint: c.$5 == null ? null : drillHint,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Plan §6 — بطاقة الجودة السريعة: فحوصات الفترة من `qc_inspections`
/// مع معدل القبول والرفض بشكل واضح.
