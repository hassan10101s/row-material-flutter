import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../di/service_locator.dart';
import '../../dashboard/data/dashboard_repo.dart';

/// Dashboard (port of Web DashboardView + dashboard summary analytics).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Map<String, dynamic>? _summary;
  Map<String, dynamic>? _kpis;
  String _period = '30d';
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = getIt<DashboardRepo>();
      final results = await Future.wait([
        repo.summary(period: _period),
        repo.todayKpis(),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = results[0];
        _kpis = results[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Hero(period: _period, onPeriod: (p) {
            setState(() => _period = p);
            _load();
          }),
          const SizedBox(height: AppSpacing.lg),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            AppEmptyState(
              icon: Icons.error_outline,
              title: 'تعذر تحميل اللوحة',
              subtitle: _error!,
              action: AppButton(label: 'إعادة المحاولة', onPressed: _load),
            )
          else
            _KpiRow(kpis: _kpis ?? const {}),
          const SizedBox(height: AppSpacing.lg),
          if (_summary != null) _Insights(summary: _summary!),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  final String period;
  final ValueChanged<String> onPeriod;

  const _Hero({required this.period, required this.onPeriod});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDeep],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.dashboard,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            'نظرة عامة على جودة المواد الخام | Raw material quality overview',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (key, label) in [
                ('7d', 'أسبوع | Week'),
                ('30d', 'شهر | Month'),
                ('90d', '3 أشهر | 3 Months'),
                ('365d', 'سنة | Year'),
              ])
                FilterChip(
                  selected: period == key,
                  label: Text(label),
                  onSelected: (_) => onPeriod(key),
                  selectedColor: Colors.white,
                  checkmarkColor: AppColors.primary,
                  backgroundColor: Colors.white24,
                  labelStyle: TextStyle(
                    color: period == key ? AppColors.primaryDeep : Colors.white,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KpiRow extends StatelessWidget {
  final Map<String, dynamic> kpis;
  const _KpiRow({required this.kpis});

  @override
  Widget build(BuildContext context) {
    final cards = <(String, String, Color, IconData)>[
      ('فحوصات اليوم | Today', '${kpis['today_count'] ?? 0}', AppColors.primary, Icons.event_note),
      ('قبول اليوم | Today Approved', '${kpis['today_approved'] ?? 0}', AppColors.success, Icons.check_circle_outline),
      ('رفض اليوم | Today Rejected', '${kpis['today_rejected'] ?? 0}', AppColors.danger, Icons.cancel_outlined),
      ('إجمالي الفحوصات | Total', '${kpis['total_count'] ?? 0}', AppColors.accent, Icons.inventory_2_outlined),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 760 ? 4 : 2;
        final tile = (constraints.maxWidth - AppSpacing.md * (width - 1)) / width;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final c in cards)
              SizedBox(width: tile, child: _KpiCard(title: c.$1, value: c.$2, color: c.$3, icon: c.$4)),
          ],
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  final IconData icon;

  const _KpiCard(
      {required this.title, required this.value, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(color: color)),
                  Text(title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Insights extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _Insights({required this.summary});

  @override
  Widget build(BuildContext context) {
    final totals = summary['totals'] as Map<String, dynamic>? ?? const {};
    final topMaterials = (summary['topMaterials'] as List?) ?? const [];
    final recommendations = (summary['recommendations'] as List?) ?? const [];
    final insightCards = (summary['insightCards'] as List?) ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('نسبة قرارات الفترة | Period decisions',
                style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _Badge('قبول نهائي | Approved', '${totals['approved'] ?? 0}', AppColors.success),
            _Badge('قبول مشروط | Conditional', '${totals['conditional'] ?? 0}', AppColors.info),
            _Badge('رفض جزئي | Partial', '${totals['partial'] ?? 0}', AppColors.partial),
            _Badge('رفض كامل | Rejected', '${totals['rejected'] ?? 0}', AppColors.danger),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'نسبة القبول ${totals['approvalRate'] ?? '0.0'}% — نسبة الرفض ${totals['rejectionRate'] ?? '0.0'}%',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('التوصيات | Recommendations',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        for (final rec in recommendations)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.tips_and_updates_outlined,
                    size: 16, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(child: Text('$rec', style: const TextStyle(fontSize: 13.5))),
              ],
            ),
          ),
        if (insightCards.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('التحليلات | Insights',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final tile = (constraints.maxWidth - AppSpacing.md * 2) / 3;
              return Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: [
                  for (final c in insightCards)
                    SizedBox(
                      width: tile,
                      child: _InsightCard(map: c as Map<String, dynamic>),
                    ),
                ],
              );
            },
          ),
        ],
        if (topMaterials.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('أعلى الخامات فحوصات | Top materials',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  for (final m in topMaterials)
                    LinearProgressLean(
                      label: '${m['name']}',
                      value: int.tryParse('${m['total']}') ?? 0,
                      max: (topMaterials.first['total'] as num?)?.toInt() ?? 1,
                      color: AppColors.primary,
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Badge(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderMuted),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style:
                  TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: color)),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  final Map<String, dynamic> map;
  const _InsightCard({required this.map});

  @override
  Widget build(BuildContext context) {
    final tone = '${map['tone']}';
    final color = switch (tone) {
      'success' => AppColors.success,
      'danger' => AppColors.danger,
      _ => AppColors.warning,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lightbulb_outline, color: color, size: 20),
            const SizedBox(height: 8),
            Text('${map['title']}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('${map['description']}',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }
}

class LinearProgressLean extends StatelessWidget {
  final String label;
  final int value;
  final int max;
  final Color color;
  const LinearProgressLean({
    super.key,
    required this.label,
    required this.value,
    required this.max,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final frac = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 8,
                color: color,
                backgroundColor: AppColors.borderMuted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 40,
              child: Text('$value', textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}