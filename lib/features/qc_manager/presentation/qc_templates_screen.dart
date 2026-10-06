import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_template.dart';
import 'cubit/qc_templates_cubit.dart';
import 'qc_template_editor_screen.dart';
import 'widgets/qc_pill.dart';

/// The checklist library: what exists, what is issued, and what an inspection
/// can actually be started from.
///
/// "Available" is counted separately from "published" on purpose. A template can
/// be published and still be unusable - archived, or past its expiry - and a
/// library that conflated the two would promise a checklist the runner cannot
/// open.
class QcTemplatesScreen extends StatelessWidget {
  const QcTemplatesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcTemplatesCubit>();
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('قوائم الفحص', 'Checklists'),
        actions: [
          IconButton(
            tooltip: AppText.t('تحديث', 'Refresh'),
            onPressed: () => cubit.refresh(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: AppText.t('فلاتر', 'Filters'),
            onPressed: () => _openFilters(context),
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: AppText.t('قائمة جديدة', 'New checklist'),
            onPressed: () => QcTemplateEditorScreen.open(context),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: BlocConsumer<QcTemplatesCubit, QcTemplatesState>(
        listenWhen: (a, b) => a.error != b.error && b.error != null,
        listener: (context, state) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(state.error!)));
          cubit.clearError();
        },
        builder: (context, state) {
          if (state.loading && state.templates.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.templates.isEmpty) {
            // An error is not an empty library. Saying "no checklists yet" after a
            // failed read tells the reader to start writing one when the truth is
            // that the list could not be fetched - and invites a duplicate.
            final error = state.error;
            return AppEmptyState(
              icon: error == null
                  ? Icons.checklist_outlined
                  : Icons.cloud_off_outlined,
              title: error == null
                  ? AppText.t('لا توجد قوائم فحص', 'No checklists yet')
                  : AppText.t(
                      'تعذر تحميل قوائم الفحص',
                      'Could not load the checklists',
                    ),
              subtitle:
                  error ??
                  (state.filters.isEmpty
                      ? AppText.t(
                          'أنشئ أول قائمة فحص',
                          'Draft the first checklist',
                        )
                      : AppText.t(
                          'لا توجد قوائم تطابق هذه الفلاتر',
                          'No checklists match these filters',
                        )),
              action: error != null
                  // A failed read is worth retrying; a genuinely empty
                  // library is not, and offering "retry" there would just
                  // fail again.
                  ? FilledButton.tonal(
                      onPressed: () => cubit.refresh(),
                      child: Text(AppText.t('إعادة المحاولة', 'Try again')),
                    )
                  : state.filters.isEmpty
                  ? null
                  : FilledButton.tonal(
                      onPressed: () => cubit.clearFilters(),
                      child: Text(AppText.t('مسح الفلاتر', 'Clear filters')),
                    ),
            );
          }
          return Column(
            children: [
              _SummaryStrip(summary: state.summary),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => cubit.refresh(),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: state.templates.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, i) =>
                        _TemplateTile(template: state.templates[i]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openFilters(BuildContext context) {
    final cubit = context.read<QcTemplatesCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const _TemplateFilterSheet()),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final QcTemplateSummary summary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('الإجمالي', 'Total'),
              value: '${summary.total}',
              icon: Icons.checklist_outlined,
              color: AppColors.primary,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('منشور', 'Published'),
              value: '${summary.published}',
              icon: Icons.verified_outlined,
              color: AppColors.success,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('مسودة', 'Draft'),
              value: '${summary.drafts}',
              icon: Icons.edit_note,
              color: AppColors.textMuted,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('صالحة للاستخدام', 'Usable'),
              value: '${summary.available}',
              icon: Icons.play_circle_outline,
              color: summary.available > 0
                  ? AppColors.info
                  : AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.template});

  final QcTemplate template;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => QcTemplateEditorScreen.open(
        context,
        templateId: template.templateId ?? 0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  template.name,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.spMax,
                  ),
                ),
              ),
              QcPill.version('v${template.version}'),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              QcPill.publication(
                published: template.isPublished,
                archived: template.isArchived,
              ),
              QcPill.type(template.type),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            children: [
              if (template.code.isNotEmpty)
                _Meta(icon: Icons.tag, text: template.code),
              if (template.dept.isNotEmpty)
                _Meta(icon: Icons.apartment_outlined, text: template.dept),
              if (template.expiryDate.isNotEmpty)
                _Meta(
                  icon: Icons.event_outlined,
                  text: template.expiryDate.substring(0, 10),
                  danger: template.isExpired,
                ),
            ],
          ),
          if (template.isPublished && !template.isAvailable) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              template.isArchived
                  ? AppText.t(
                      'مؤرشف - لا يمكن بدء فحص منه',
                      'Archived - no longer starts an inspection',
                    )
                  : AppText.t(
                      'منتهي - لا يمكن بدء فحص منه',
                      'Expired - no longer starts an inspection',
                    ),
              style: TextStyle(fontSize: 11.spMax, color: AppColors.danger),
            ),
          ],
          if (template.requiresApprovalOnSubmit) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              AppText.t(
                'يتطلب موافقة قبل الإغلاق',
                'Needs approval before closing',
              ),
              style: TextStyle(fontSize: 11.spMax, color: AppColors.warning),
            ),
          ],
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.danger = false});

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14.r, color: color),
        const SizedBox(width: AppSpacing.xs),
        Text(
          text,
          style: TextStyle(fontSize: 12.spMax, color: color),
        ),
      ],
    );
  }
}

class _TemplateFilterSheet extends StatefulWidget {
  const _TemplateFilterSheet();

  @override
  State<_TemplateFilterSheet> createState() => _TemplateFilterSheetState();
}

class _TemplateFilterSheetState extends State<_TemplateFilterSheet> {
  final _search = TextEditingController();
  final _dept = TextEditingController();

  @override
  void initState() {
    super.initState();
    final f = context.read<QcTemplatesCubit>().state.filters;
    _search.text = f.text;
    _dept.text = f.dept;
  }

  @override
  void dispose() {
    _search.dispose();
    _dept.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcTemplatesCubit>();
    return BlocBuilder<QcTemplatesCubit, QcTemplatesState>(
      bloc: cubit,
      builder: (context, state) {
        final f = state.filters;
        return Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            top: AppSpacing.lg,
            bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppText.t('فلاتر القوائم', 'Checklist filters'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16.spMax,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: AppText.t('بحث', 'Search'),
                    hintText: AppText.t('اسم أو رمز', 'Name or code'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => cubit.applyFilters(f.copyWith(text: v)),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _dept,
                  decoration: InputDecoration(
                    labelText: AppText.t('القسم', 'Department'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(dept: v.trim())),
                ),
                const SizedBox(height: AppSpacing.md),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: f.publishedOnly,
                  title: Text(AppText.t('المنشورة فقط', 'Published only')),
                  subtitle: Text(
                    AppText.t(
                      'ما يمكن بدء فحص منه',
                      'What an inspection can start from',
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(publishedOnly: v)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: f.includeArchived,
                  title: Text(AppText.t('إظهار المؤرشف', 'Show archived')),
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(includeArchived: v)),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(AppText.t('النوع', 'Type')),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final type in QcTemplateType.all)
                      FilterChip(
                        label: Text(QcPill.typeLabel(type)),
                        selected: f.types.contains(type),
                        onSelected: (_) => cubit.toggleType(type),
                      ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => cubit.clearFilters(),
                      child: Text(AppText.t('مسح', 'Clear')),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(AppText.t('تم', 'Done')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
