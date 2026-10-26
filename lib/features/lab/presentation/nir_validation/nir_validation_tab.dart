import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_adaptive.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_data_table.dart';
import '../../../../design_system/widgets/app_date_field.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_page_header.dart';
import '../../../../design_system/widgets/app_search_field.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../../../design_system/widgets/app_text_field.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../di/service_locator.dart';
import '../../domain/nir_validation_repository.dart';
import '../cubit/nir_validation_cubit.dart';
import '../cubit/nir_validation_state.dart';
import 'nir_item_details_window.dart';
import 'nir_validation_components.dart';

class NirValidationTab extends StatefulWidget {
  const NirValidationTab({super.key});
  @override
  State<NirValidationTab> createState() => _NirValidationTabState();
}

class _NirValidationTabState extends State<NirValidationTab> {
  NirReliability? _reliability;
  int _searchRevision = 0;
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NirValidationCubit>();
    final state = context.watch<NirValidationCubit>().state;
    final scoped = state.filteredStats;
    final visible = scoped
        .where((s) => _reliability == null || s.reliability == _reliability)
        .toList();
    return AppErrorFeedback<NirValidationCubit, NirValidationState>(
      selector: (s) => s.error,
      child: RefreshIndicator(
        onRefresh: cubit.load,
        child: CustomScrollView(
          key: const PageStorageKey('nir-validation-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppPageHeader(
                    title: AppText.t('التحقق من دقة NIR', 'NIR validation'),
                    subtitle: AppText.t(
                      'قارن قراءات الجهاز بالمعمل، وراجع كل تحليل بثقة.',
                      'Compare device readings with the laboratory and review each analysis.',
                    ),
                    icon: Icons.query_stats_outlined,
                    actions: [
                      AppButton(
                        label: AppText.t('تحديث النتائج', 'Refresh results'),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        style: AppButtonStyle.secondary,
                        small: true,
                        loading: state.loading,
                        onPressed: state.loading ? null : cubit.load,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (state.loading && state.stats.isEmpty)
                    const AppSkeletonList(rows: 4, lines: 3, height: 320)
                  else ...[
                    _Overview(
                      stats: scoped,
                      selected: _reliability,
                      onSelected: (value) =>
                          setState(() => _reliability = value),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _Filters(
                      key: ValueKey(_searchRevision),
                      state: state,
                      reliability: _reliability,
                      onReliability: (value) =>
                          setState(() => _reliability = value),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const _ReadingGuide(),
                    const SizedBox(height: AppSpacing.sectionGap),
                    Text(
                      AppText.t(
                        '${visible.length} تحليل مطابق للفلاتر',
                        '${visible.length} analyses match the filters',
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ),
            ),
            if (!(state.loading && state.stats.isEmpty))
              SliverPadding(
                padding: const EdgeInsets.only(bottom: AppSpacing.page),
                sliver: _StatsGroupList(
                  stats: visible,
                  filtered:
                      state.query.trim().isNotEmpty ||
                      state.scopeFilter != null ||
                      _reliability != null,
                  onClear: () {
                    cubit.setQuery('');
                    cubit.setScope(null);
                    setState(() {
                      _reliability = null;
                      _searchRevision++;
                    });
                  },
                  onOpen: (stats) => _openDetails(context, stats),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDetails(
    BuildContext context,
    NirParameterStats stats,
  ) async {
    final cubit = context.read<NirValidationCubit>();
    final canReset =
        getIt.isRegistered<AuthGate>() &&
        getIt<AuthGate>().canWrite(Permission.labResultsUpdate);
    await showNirItemDetails(
      context,
      stats,
      onReset: canReset && !cubit.state.saving
          ? () => _showResetDialog(context, cubit, target: stats)
          : null,
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({
    required this.stats,
    required this.selected,
    required this.onSelected,
  });
  final List<NirParameterStats> stats;
  final NirReliability? selected;
  final ValueChanged<NirReliability?> onSelected;
  @override
  Widget build(BuildContext context) {
    final items = <(NirReliability?, String, IconData, Color)>[
      (
        null,
        AppText.t('كل التحاليل', 'All analyses'),
        Icons.analytics_outlined,
        AppColors.primary,
      ),
      (
        NirReliability.trusted,
        AppText.t('موثوق', 'Trusted'),
        Icons.verified_outlined,
        AppColors.success,
      ),
      (
        NirReliability.needsReview,
        AppText.t('يحتاج مراجعة', 'Needs review'),
        Icons.fact_check_outlined,
        AppColors.warning,
      ),
      (
        NirReliability.insufficientData,
        AppText.t('بيانات غير كافية', 'More data needed'),
        Icons.hourglass_empty_rounded,
        AppColors.textMuted,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth >= 800 &&
                MediaQuery.textScalerOf(context).scale(14) < 19
            ? 4
            : 2;
        final width =
            (constraints.maxWidth - AppSpacing.sm * (columns - 1)) / columns;
        return Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final (status, label, icon, color) in items)
              SizedBox(
                width: width,
                child: Semantics(
                  selected: selected == status,
                  child: AppCard(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    color: selected == status
                        ? color.withValues(alpha: .08)
                        : null,
                    onTap: () => onSelected(status),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(icon, size: 20, color: color),
                            const Spacer(),
                            if (selected == status)
                              Icon(Icons.check_circle, size: 16, color: color),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          '${status == null ? stats.length : stats.where((s) => s.reliability == status).length}',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          label,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    super.key,
    required this.state,
    required this.reliability,
    required this.onReliability,
  });
  final NirValidationState state;
  final NirReliability? reliability;
  final ValueChanged<NirReliability?> onReliability;
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NirValidationCubit>();
    final scopes = Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final scope in <NirScope?>[null, ...NirScope.values])
          ChoiceChip(
            label: Text(
              scope == null
                  ? AppText.t('الكل', 'All')
                  : scope == NirScope.rawMaterial
                  ? AppText.t('الخامات', 'Raw materials')
                  : AppText.t('المنتجات', 'Products'),
            ),
            selected: state.scopeFilter == scope,
            onSelected: (_) => cubit.setScope(scope),
          ),
      ],
    );
    final search = DebouncedSearchField(
      label: AppText.t(
        'ابحث باسم الخامة أو المنتج أو التحليل',
        'Search material, product or analysis',
      ),
      initialValue: state.query,
      onChanged: cubit.setQuery,
    );
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          appAdaptiveVariant(
            context,
            desktop: (_) => LayoutBuilder(
              builder: (_, c) => c.maxWidth < 650
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        search,
                        const SizedBox(height: AppSpacing.sm),
                        scopes,
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: search),
                        const SizedBox(width: AppSpacing.lg),
                        scopes,
                      ],
                    ),
            ),
            mobile: (_) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                search,
                const SizedBox(height: AppSpacing.sm),
                scopes,
              ],
            ),
          ),
          if (reliability != null) ...[
            const SizedBox(height: AppSpacing.sm),
            InputChip(
              label: Text(nirReliabilityLabel(reliability!)),
              onDeleted: () => onReliability(null),
              deleteButtonTooltipMessage: AppText.t(
                'إلغاء فلتر الحالة',
                'Clear status filter',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReadingGuide extends StatelessWidget {
  const _ReadingGuide();
  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      childrenPadding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      leading: Icon(
        Icons.help_outline_rounded,
        size: 20,
        color: AppColors.info,
      ),
      title: Text(
        AppText.t('كيف أقرأ النتائج؟', 'How do I read the results?'),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      children: [
        Text(
          AppText.t(
            '١. تُطابق قراءة NIR مع التحليل المعملي لنفس محضر الفحص.\n٢. «موثوق» تعني 5 نقاط على الأقل وR² لا يقل عن 0.90 وفق المنطق الحالي.\n٣. الانحراف = NIR − المعمل؛ الإشارة توضّح اتجاه الفرق، وليست حكم قبول أو رفض. افتح التحليل لرؤية التوصية والنقاط.',
            '1. NIR and laboratory results are paired using the same inspection.\n2. Trusted means at least 5 pairs and R² ≥ 0.90 under the existing rules.\n3. Bias = NIR − lab. Its sign shows direction, not a pass or fail. Open an analysis for the recommendation and pairs.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class _StatsGroupList extends StatelessWidget {
  const _StatsGroupList({
    required this.stats,
    required this.filtered,
    required this.onClear,
    required this.onOpen,
  });
  final List<NirParameterStats> stats;
  final bool filtered;
  final VoidCallback onClear;
  final ValueChanged<NirParameterStats> onOpen;
  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) {
      return SliverToBoxAdapter(
        child: AppCard(
          child: Column(
            children: [
              AppEmptyState(
                icon: filtered
                    ? Icons.search_off_rounded
                    : Icons.query_stats_outlined,
                title: filtered
                    ? AppText.t(
                        'لا توجد نتائج بهذه الفلاتر',
                        'No results for these filters',
                      )
                    : AppText.t(
                        'ابدأ بأول مقارنة',
                        'Start with your first comparison',
                      ),
                subtitle: filtered
                    ? AppText.t(
                        'جرّب اسمًا آخر أو ألغِ الفلاتر لعرض كل التحاليل.',
                        'Try another name or clear the filters.',
                      )
                    : AppText.t(
                        'سجّل قراءة NIR وتحليلًا معمليًا لنفس محضر الفحص لتظهر المقارنة هنا.',
                        'Record an NIR reading and a laboratory test for the same inspection to see the comparison here.',
                      ),
              ),
              if (filtered)
                AppButton(
                  label: AppText.t('مسح الفلاتر', 'Clear filters'),
                  style: AppButtonStyle.secondary,
                  onPressed: onClear,
                ),
            ],
          ),
        ),
      );
    }
    final groups = <(NirScope, int, String), List<NirParameterStats>>{};
    for (final row in stats) {
      (groups[(row.scope, row.entityId, row.entityName)] ??= []).add(row);
    }
    final entries = groups.values.toList();
    return SliverList.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (_, index) =>
          _EntityCard(rows: entries[index], onOpen: onOpen),
    );
  }
}

class _EntityCard extends StatelessWidget {
  const _EntityCard({required this.rows, required this.onOpen});
  final List<NirParameterStats> rows;
  final ValueChanged<NirParameterStats> onOpen;
  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: NirSectionTitle(
            title: rows.first.entityName,
            icon: rows.first.scope == NirScope.rawMaterial
                ? Icons.grass_outlined
                : Icons.inventory_2_outlined,
            subtitle:
                '${NirValidationState.scopeLabel(rows.first.scope)} · ${rows.length} ${AppText.t('تحليل', 'analyses')}',
          ),
        ),
        Divider(height: 1, color: AppColors.borderMuted),
        appAdaptiveVariant(
          context,
          desktop: (_) => LayoutBuilder(
            builder: (_, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: AppDataTable(
                  showCheckboxColumn: false,
                  columns: [
                    DataColumn(label: Text(AppText.t('التحليل', 'Analysis'))),
                    DataColumn(
                      label: Text(AppText.t('النقاط', 'Pairs')),
                      numeric: true,
                    ),
                    DataColumn(
                      label: Text(AppText.t('الانحراف', 'Bias')),
                      numeric: true,
                    ),
                    const DataColumn(label: Text('R²'), numeric: true),
                    const DataColumn(label: Text('RMSE'), numeric: true),
                    DataColumn(label: Text(AppText.t('الحالة', 'Status'))),
                    const DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final stats in rows)
                      DataRow(
                        cells: [
                          DataCell(
                            Text(
                              '${stats.parameter}${stats.unit.trim().isEmpty ? '' : ' (${stats.unit})'}',
                            ),
                          ),
                          DataCell(Text('${stats.count}')),
                          DataCell(
                            Text(
                              stats.count == 0
                                  ? '—'
                                  : stats.bias.toStringAsFixed(3),
                              textDirection: TextDirection.ltr,
                            ),
                          ),
                          DataCell(
                            Text(
                              stats.count < 2
                                  ? '—'
                                  : stats.r2.toStringAsFixed(3),
                              textDirection: TextDirection.ltr,
                            ),
                          ),
                          DataCell(
                            Text(
                              stats.count < 2
                                  ? '—'
                                  : stats.rmse.toStringAsFixed(3),
                              textDirection: TextDirection.ltr,
                            ),
                          ),
                          DataCell(
                            NirReliabilityBadge(reliability: stats.reliability),
                          ),
                          DataCell(
                            AppButton(
                              label: AppText.t('عرض التحليل', 'View analysis'),
                              icon: const Icon(
                                Icons.insights_outlined,
                                size: 18,
                              ),
                              style: AppButtonStyle.ghost,
                              small: true,
                              onPressed: () => onOpen(stats),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
          mobile: (_) => Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) Divider(height: 1, color: AppColors.borderMuted),
                _MobileParameter(stats: rows[i], onOpen: () => onOpen(rows[i])),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _MobileParameter extends StatelessWidget {
  const _MobileParameter({required this.stats, required this.onOpen});
  final NirParameterStats stats;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${stats.parameter}${stats.unit.trim().isEmpty ? '' : ' (${stats.unit})'}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            NirReliabilityBadge(reliability: stats.reliability),
            Text(
              '${stats.count} ${AppText.t('نقطة مطابقة', 'matched pairs')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        NirMetricGrid(
          columns: 2,
          children: [
            NirMetricTile(
              label: AppText.t('متوسط الانحراف', 'Mean bias'),
              value: stats.count == 0 ? '—' : stats.bias.toStringAsFixed(3),
              hint: stats.count == 0
                  ? null
                  : stats.bias == 0
                  ? AppText.t('لا فرق في المتوسط', 'No average difference')
                  : stats.bias > 0
                  ? AppText.t('NIR أعلى من المعمل', 'NIR reads higher')
                  : AppText.t('NIR أقل من المعمل', 'NIR reads lower'),
            ),
            NirMetricTile(
              label: AppText.t('معامل التحديد R²', 'Determination R²'),
              value: stats.count < 2 ? '—' : stats.r2.toStringAsFixed(3),
              hint: stats.count < 2
                  ? AppText.t(
                      'يلزم نقطتان على الأقل',
                      'At least 2 pairs needed',
                    )
                  : AppText.t('جودة ملاءمة الخط', 'Fit of the regression line'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton(
          label: AppText.t(
            'عرض التحليل والتوصية',
            'View analysis & recommendation',
          ),
          icon: const Icon(Icons.insights_outlined, size: 18),
          style: AppButtonStyle.secondary,
          expanded: true,
          onPressed: onOpen,
        ),
      ],
    ),
  );
}

class _ResetForm extends StatefulWidget {
  const _ResetForm({required this.target});
  final NirParameterStats target;
  @override
  State<_ResetForm> createState() => _ResetFormState();
}

class _ResetFormState extends State<_ResetForm> {
  final _date = TextEditingController(
    text: DateTime.now().toIso8601String().substring(0, 10),
  );
  final _note = TextEditingController();
  @override
  void dispose() {
    _date.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    icon: Icons.restart_alt_outlined,
    title: AppText.t('بدء فترة مقارنة جديدة', 'Start a new comparison period'),
    subtitle: '${widget.target.entityName} · ${widget.target.parameter}',
    actions: [
      AppButton(
        onPressed: () => Navigator.pop(context),
        label: AppText.t('إلغاء', 'Cancel'),
        style: AppButtonStyle.secondary,
      ),
      AppButton(
        onPressed: () =>
            Navigator.pop(context, (_date.text.trim(), _note.text.trim())),
        label: AppText.t('تأكيد بدء الفترة', 'Confirm new period'),
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppText.t(
            'سيُحسب هذا التحليل من التاريخ الجديد. القراءات القديمة تبقى محفوظة، وباقي التحاليل لا تتغير.',
            'This analysis will use the new start date. Older readings remain saved and other analyses keep their current periods.',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppDateField(
          label: AppText.t('تاريخ البداية', 'Start date'),
          controller: _date,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTextField(
          controller: _note,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: AppText.t(
              'سبب بدء الفترة (اختياري)',
              'Reason (optional)',
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> _showResetDialog(
  BuildContext context,
  NirValidationCubit cubit, {
  required NirParameterStats target,
}) async {
  final result = await showAppDialog<(String, String)>(
    context,
    builder: (_) => _ResetForm(target: target),
  );
  if (result == null || !context.mounted) return;
  final saved = await cubit.reset(
    result.$1,
    result.$2,
    scope: target.scope,
    entityId: target.entityId,
    entityName: target.entityName,
    parameter: target.parameter,
  );
  if (saved && cubit.state.pendingApproval && context.mounted) {
    AppFeedback.show(
      context,
      AppText.t(
        'حُفظ طلب تصفير NIR؛ سيُحدّث الأرشيف بعد اعتماد السيرفر.',
        'NIR reset request saved; the archive will update after server approval.',
      ),
      type: AppFeedbackType.info,
    );
  }
}
