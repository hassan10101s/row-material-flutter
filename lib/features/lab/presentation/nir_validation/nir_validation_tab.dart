import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/responsive/form_factor.dart';
import '../../../../core/responsive/layout_spec.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_date_field.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_page_header.dart';
import '../../../../design_system/widgets/app_search_field.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../domain/nir_validation_repository.dart';
import '../cubit/nir_validation_cubit.dart';
import '../cubit/nir_validation_state.dart';
import 'nir_item_details_window.dart';

/// NIR فلديشن tab: validates the NIR device against laboratory references.
///
/// Every محضر فحص result (خامات + منتجات) is a NIR reading; the paired lab
/// result (سجل الفحوصات, same entry code) is the reference. Per
/// خامة/منتج × تحليل it shows the average deviation, the proposed
/// slope/intercept and accuracy metrics — plus the horizon (last reset date)
/// and the reset action.
class NirValidationTab extends StatelessWidget {
  const NirValidationTab({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NirValidationCubit>();
    final state = context.watch<NirValidationCubit>().state;
    return AppErrorFeedback<NirValidationCubit, NirValidationState>(
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
                  if (FormFactor.current.isMobile) ...[
                    AppPageHeader(
                      title: AppText.t('فلديشن NIR', 'NIR Validation'),
                      subtitle: AppText.t(
                        'التأكد من دقة جهاز NIR بالمقارنة مع نتائج المعمل',
                        'NIR device accuracy versus laboratory references',
                      ),
                      icon: Icons.query_stats_outlined,
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (state.loading && state.stats.isEmpty)
                    const AppSkeletonList(rows: 5, lines: 3, height: 320)
                  else ...[
                    _FilterRow(
                      selected: state.scopeFilter,
                      query: state.query,
                      onScope: cubit.setScope,
                      onQuery: cubit.setQuery,
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.only(bottom: AppSpacing.page),
              sliver: _StatsGroupList(stats: state.filteredStats),
            ),
          ],
        ),
      ),
    );
  }

}

String _todayIso() => DateTime.now().toIso8601String().substring(0, 10);

/// `yyyy-MM-dd` → `dd/MM/yyyy` (Arabic) / ISO (English).
String _displayDate(String iso) {
  final parts = iso.split('-');
  if (parts.length == 3) {
    return AppText.t('${parts[2]}/${parts[1]}/${parts[0]}', iso);
  }
  return iso;
}

/// Opens the reset dialog for a single (خامة/منتج × تحليل) item — resets are
/// always per-item; there is no whole-calibration reset action.
Future<void> _showResetDialog(
  BuildContext context,
  NirValidationCubit cubit, {
  required NirParameterStats target,
}) async {
  final dateController = TextEditingController(text: _todayIso());
  final noteController = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        AppText.t(
          'تصفير ${target.parameter} — ${target.entityName}',
          'Reset ${target.parameter} — ${target.entityName}',
        ),
      ),
      content: SizedBox(
        // Fixed pixel dimensions are a desktop affordance only; a phone
        // dialog runs its own intrinsic width (LayoutSpec contract).
        width:
            LayoutSpec.of(FormFactor.current).allowsFixedDialog ? 420 : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppText.t(
                'سيبدأ حساب «${target.parameter}» لهذا البند من التاريخ المحدد من جديد — بقية البنود تستمر من تصفيرها الخاص.',
                'Counting for “${target.parameter}” restarts from the chosen date — other items keep their own horizon.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            AppDateField(
              label: AppText.t('تاريخ بداية جديد', 'New start date'),
              controller: dateController,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: noteController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: AppText.t('ملاحظة (اختياري)', 'Note (optional)'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(AppText.t('إلغاء', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(AppText.t('تصفير', 'Reset')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await cubit.reset(
    dateController.text.trim(),
    noteController.text.trim(),
    scope: target.scope,
    entityId: target.entityId,
    entityName: target.entityName,
    parameter: target.parameter,
  );
}

/// Scope chips + search.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selected,
    required this.query,
    required this.onScope,
    required this.onQuery,
  });

  final NirScope? selected;
  final String query;
  final ValueChanged<NirScope?> onScope;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ChoiceChip(
          label: Text(AppText.t('الكل', 'All')),
          selected: selected == null,
          onSelected: (_) => onScope(null),
        ),
        ChoiceChip(
          label: Text(AppText.t('خامات', 'Raw materials')),
          selected: selected == NirScope.rawMaterial,
          onSelected: (_) => onScope(NirScope.rawMaterial),
        ),
        ChoiceChip(
          label: Text(AppText.t('منتجات', 'Products')),
          selected: selected == NirScope.product,
          onSelected: (_) => onScope(NirScope.product),
        ),
        SizedBox(
          width: 280.w,
          child: DebouncedSearchField(
            label: AppText.t('بحث', 'Search'),
            initialValue: query,
            onChanged: onQuery,
          ),
        ),
      ],
    );
  }
}

/// Groups the stats rows by خامة/منتج; each group is a card whose rows are
/// expandable into the matched-point table.
class _StatsGroupList extends StatelessWidget {
  const _StatsGroupList({required this.stats});

  final List<NirParameterStats> stats;

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: AppEmptyState(
          icon: Icons.query_stats_outlined,
          title: AppText.t('لا يوجد نقاط مطابقة', 'No matched points'),
          subtitle: AppText.t(
            'يلزم وجود تحليل كيميائي معملي (ريفرنس) على نفس المحضر لتظهر الانحرافات.',
            'A laboratory reference test on the same محضر is required to produce deviations.',
          ),
        ),
      );
    }
    // Group by (scope, entityId, entityName): raw-material ids and product
    // ids come from different tables and collide, so grouping on the id alone
    // would merge a product into a raw-material card (wrong name + icon).
    // Scope + identity are part of the key so each product is shown on its
    // own, even when legacy rows have no product id.
    final groups = <(NirScope, int, String), List<NirParameterStats>>{};
    for (final s in stats) {
      (groups[(s.scope, s.entityId, s.entityName)] ??= []).add(s);
    }
    return SliverList.separated(
      itemCount: groups.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) {
        final rows = groups.values.elementAt(i);
        final groupPoints = rows.fold<int>(0, (n, s) => n + s.count);
        return _EntityGroupCard(
          entityName: rows.first.entityName,
          scope: rows.first.scope,
          rows: rows,
          statsHeader: AppText.t(
            '$groupPoints نقطة مطابقة',
            '$groupPoints matched points',
          ),
        );
      },
    );
  }
}

/// One خامة/منتج card with a parameter table.
class _EntityGroupCard extends StatelessWidget {
  const _EntityGroupCard({
    required this.entityName,
    required this.scope,
    required this.rows,
    required this.statsHeader,
  });

  final String entityName;
  final NirScope scope;
  final List<NirParameterStats> rows;
  final String statsHeader;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                scope == NirScope.rawMaterial
                    ? Icons.grass_outlined
                    : Icons.inventory_2_outlined,
                color: scope == NirScope.rawMaterial
                    ? AppColors.info
                    : AppColors.primary,
                size: 20.r,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entityName,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                statsHeader,
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: AppColors.textMuted,
                    ),
              ),
            ],
          ),
          const Divider(height: AppSpacing.md),
          for (final row in rows) _ParameterRow(stats: row),
        ],
      ),
    );
  }
}

/// One parameter row: metrics + expansion of the point table.
class _ParameterRow extends StatelessWidget {
  const _ParameterRow({required this.stats});

  final NirParameterStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = stats.count;
    final biasText =
        n == 0 ? '-' : stats.bias.toStringAsFixed(3);
    final slopeText = n < 2 ? '-' : stats.slope.toStringAsFixed(4);
    final interceptText = n < 2 ? '-' : stats.intercept.toStringAsFixed(4);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
      dense: true,
      // The arrow stays at the start; the trailing slot holds the details
      // window button (diagram + full metrics + adjustment mode choice).
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        '${stats.parameter}${_unitSuffix()}  ·  ${NirValidationState.scopeLabel(stats.scope)}',
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 10,
          runSpacing: 4,
          children: [
            _MetricChip(label: 'N', value: '$n'),
            _MetricChip(
              label: AppText.t('الانحراف', 'Bias'),
              value: biasText,
              color: stats.bias > 0 ? AppColors.danger : AppColors.success,
            ),
            _MetricChip(label: 'Slope', value: slopeText),
            _MetricChip(label: 'Intercept', value: interceptText),
            _MetricChip(
              label: 'R²',
              value: n < 2 ? '-' : stats.r2.toStringAsFixed(3),
            ),
            _MetricChip(
              label: 'RMSE',
              value: n < 2 ? '-' : stats.rmse.toStringAsFixed(3),
            ),
            _ReliabilityChip(stats: stats),
            if (stats.scopedHorizon)
              _MetricChip(
                label: AppText.t('تصفير خاص', 'Item reset'),
                value: _displayDate(stats.horizonStart),
                color: AppColors.primary,
              ),
          ],
        ),
      ),
      trailing: IconButton(
        tooltip: AppText.t('الرسم والتفاصيل', 'Diagram & details'),
        icon: const Icon(Icons.insights_outlined, size: 20),
        onPressed: () => showNirItemDetails(context, stats),
      ),
      children: [
        _ItemHorizonBar(stats: stats),
        NirPointsTable(points: stats.points, unit: stats.unit),
      ],
    );
  }

  String _unitSuffix() {
    final u = stats.unit.trim();
    return u.isEmpty ? '' : ' ($u)';
  }
}

/// The effective horizon of one parameter row plus its per-item reset action:
/// resetting here restarts only this (خامة/منتج × تحليل) item, leaving every
/// other row counting from its own horizon.
class _ItemHorizonBar extends StatelessWidget {
  const _ItemHorizonBar({required this.stats});

  final NirParameterStats stats;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NirValidationCubit>();
    final saving = context.watch<NirValidationCubit>().state.saving;
    final horizon = stats.horizonStart.trim();
    final label = horizon.isEmpty
        ? AppText.t(
            'بلا تصفير — كل النقاط محسوبة',
            'No reset — all points count',
          )
        : AppText.t(
            'حساب البند من: ${_displayDate(horizon)}${stats.scopedHorizon ? ' (تصفير خاص)' : ' (تصفير عام)'}',
            'Counting from: ${_displayDate(horizon)}${stats.scopedHorizon ? ' (item reset)' : ' (global reset)'}',
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Icon(
            stats.scopedHorizon ? Icons.flag : Icons.flag_outlined,
            size: 14.r,
            color: stats.scopedHorizon
                ? AppColors.primary
                : AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: AppColors.textMuted,
                  ),
            ),
          ),
          TextButton.icon(
            onPressed: saving
                ? null
                : () => _showResetDialog(context, cubit, target: stats),
            icon: const Icon(Icons.restart_alt_outlined, size: 16),
            label: Text(AppText.t('تصفير هذا البند', 'Reset this item')),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12.spMin,
          fontWeight: FontWeight.w600,
          color: resolved,
        ),
      ),
    );
  }
}

class _ReliabilityChip extends StatelessWidget {
  const _ReliabilityChip({required this.stats});

  final NirParameterStats stats;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (stats.reliability) {
      NirReliability.trusted => (
          AppColors.success,
          AppText.t('موثوق', 'Trusted'),
        ),
      NirReliability.needsReview => (
          AppColors.warning,
          AppText.t('يحتاج مراجعة', 'Needs review'),
        ),
      NirReliability.insufficientData => (
          AppColors.textMuted,
          AppText.t('نقاط غير كافية', 'Not enough points'),
        ),
    };
    return _MetricChip(label: label, value: '', color: color);
  }
}

