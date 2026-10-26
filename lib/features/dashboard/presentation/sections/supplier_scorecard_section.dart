import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';
import '../../domain/dashboard_kpis.dart';
import '../../../../design_system/widgets/app_card.dart';

String dashboardTierWord(String tier) {
  return switch (tier) {
    'A' => AppText.t('ممتاز', 'Excellent'),
    'B' => AppText.t('جيد', 'Good'),
    'C' => AppText.t('يحتاج متابعة', 'Needs follow-up'),
    'D' => AppText.t('خطر', 'At risk'),
    _ => AppText.t('لا يوجد', 'None'),
  };
}

class TierBadge extends StatelessWidget {
  final String tier;
  const TierBadge(this.tier, {super.key});
  @override
  Widget build(BuildContext context) {
    final color = switch (tier) {
      'A' => AppColors.success,
      'B' => AppColors.primary,
      'C' => AppColors.warning,
      'D' => AppColors.danger,
      _ => AppColors.textMuted,
    };
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        tier,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: color,
          fontSize: 13.spMax,
        ),
      ),
    );
  }
}

class SupplierScorecardSection extends StatelessWidget {
  final DashboardKpisState kpi;

  /// Optional drill-down: tapping a supplier opens the register filtered to
  /// that supplier (wired by the dashboard screen, so the section stays
  /// navigation-free).
  final ValueChanged<SupplierScore>? onOpenSupplier;
  const SupplierScorecardSection({
    super.key,
    required this.kpi,
    this.onOpenSupplier,
  });
  @override
  Widget build(BuildContext context) {
    final scores = kpi.bundle.supplierScores;
    if (scores.isEmpty) return const SizedBox.shrink();
    final maxScore = scores.fold<double>(
      0,
      (m, s) => s.score > m ? s.score : m,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.leaderboard_outlined,
          color: AppColors.primary,
          title: AppText.t('أداء الموردين', 'Supplier performance'),
          subtitle: AppText.t(
            'مرتب حسب نسبة القبول وعدد الفحوصات',
            'Sorted by acceptance % and volume',
          ),
        ),
        AppCard(
          padding: EdgeInsets.zero,
          enableHover: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (var i = 0; i < scores.length; i++) ...[
                  SupplierRow(
                    score: scores[i],
                    maxScore: maxScore,
                    rank: i + 1,
                    onTap: onOpenSupplier == null
                        ? null
                        : () => onOpenSupplier!(scores[i]),
                  ),
                  if (i != scores.length - 1) const Divider(height: 16),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class SupplierRow extends StatefulWidget {
  final SupplierScore score;
  final double maxScore;
  final int rank;

  /// Optional drill-down tap (null = inert row, tests keep the old behavior).
  final VoidCallback? onTap;
  const SupplierRow({
    super.key,
    required this.score,
    required this.maxScore,
    required this.rank,
    this.onTap,
  });

  @override
  State<SupplierRow> createState() => _SupplierRowState();
}

class _SupplierRowState extends State<SupplierRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        decoration: BoxDecoration(
          color: _isHovered
              ? AppColors.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onTap,
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${widget.rank}',
                  style: TextStyle(
                    fontSize: 12.spMax,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              TierBadge(widget.score.tier),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.score.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.spMax,
                              height: 1.35,
                              color: _isHovered ? AppColors.primary : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${widget.score.approvalRate}%',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13.spMax,
                            color: widget.score.tier == 'A'
                                ? AppColors.success
                                : widget.score.tier == 'D'
                                ? AppColors.danger
                                : AppColors.textStrong,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${widget.score.total} ${AppText.t('فحص', 'inspections')} • ${AppText.t('الرفض', 'Rejected')}: ${widget.score.rejected} • ${AppText.t('الحالة', 'Status')}: ${dashboardTierWord(widget.score.tier)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.spMax,
                        height: 1.4,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: widget.maxScore == 0
                            ? 0
                            : (widget.score.score / widget.maxScore).clamp(
                                0.0,
                                1.0,
                              ),
                        minHeight: 6,
                        color: AppColors.primary,
                        backgroundColor: AppColors.borderMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
