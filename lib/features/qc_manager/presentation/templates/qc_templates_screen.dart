import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../app/auth_gate.dart';
import '../../../../../core/auth/permissions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_summary_card.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../widgets/register_exports.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_template.dart';
import '../cubit/qc_templates_cubit.dart';
import 'qc_template_editor_screen.dart';
import '../widgets/qc_pill.dart';

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
            tooltip: AppText.t('تصدير جدول', 'Export table'),
            onPressed: () =>
                RegisterExports.templates(context, cubit.state.templates),
            icon: const Icon(Icons.table_view_outlined),
          ),
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
          AppFeedback.error(context, state.error!);
          cubit.clearError();
        },
        builder: (context, state) {
          if (state.loading && state.templates.isEmpty) {
            return const AppSkeletonList(rows: 5);
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
                  ? AppButton(
                      label: AppText.t('إعادة المحاولة', 'Try again'),
                      style: AppButtonStyle.secondary,
                      onPressed: () => cubit.refresh(),
                    )
                  : state.filters.isEmpty
                  ? null
                  : AppButton(
                      label: AppText.t('مسح الفلاتر', 'Clear filters'),
                      style: AppButtonStyle.secondary,
                      onPressed: () => cubit.clearFilters(),
                    ),
            );
          }
          return Column(
            children: [
              if (state.loading && state.templates.isNotEmpty)
                const AppRefreshBar(),
              _SummaryStrip(summary: state.summary),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  0,
                ),
                child: AppFilterBar(
                  searchHint: AppText.t('بحث بالاسم أو الرمز', 'Search name or code'),
                  initialSearch: state.filters.text,
                  onSearch: (v) => cubit.applyFilters(
                    state.filters.copyWith(text: v),
                  ),
                  trailing: AppButton(
                    label: AppText.t('فلاتر', 'Filters'),
                    icon: const Icon(Icons.tune, size: 18),
                    style: AppButtonStyle.ghost,
                    small: true,
                    onPressed: () => _openFilters(context),
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => cubit.refresh(),
                  child: AppInfiniteList(
                    itemCount: state.templates.length,
                    hasMore: false,
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
    showAppOverlay<void>(
      context,
      title: AppText.t('فلاتر القوائم', 'Checklist filters'),
      icon: Icons.filter_alt_outlined,
      size: AppWindowSize.sm,
      builder: (_, _) => BlocProvider.value(
        value: cubit,
        child: const _TemplateFilterSheet(),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final QcTemplateSummary summary;

  @override
  Widget build(BuildContext context) {
    final cards = [
      AppSummaryCard(
        label: AppText.t('الإجمالي', 'Total'),
        value: '${summary.total}',
        icon: Icons.checklist_outlined,
        color: AppColors.primary,
      ),
      AppSummaryCard(
        label: AppText.t('منشور', 'Published'),
        value: '${summary.published}',
        icon: Icons.verified_outlined,
        color: AppColors.success,
      ),
      AppSummaryCard(
        label: AppText.t('مسودة', 'Draft'),
        value: '${summary.drafts}',
        icon: Icons.edit_note,
        color: AppColors.textMuted,
      ),
      AppSummaryCard(
        label: AppText.t('صالحة للاستخدام', 'Usable'),
        value: '${summary.available}',
        icon: Icons.play_circle_outline,
        color: summary.available > 0 ? AppColors.info : AppColors.textMuted,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 600) {
            return Row(
              children: [for (final c in cards) Expanded(child: c)],
            );
          }
          return Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final c in cards)
                SizedBox(
                  width: (constraints.maxWidth - AppSpacing.sm) / 2,
                  child: c,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.template});

  final QcTemplate template;

  static bool get canDelete {
    try {
      return getIt<AuthGate>().canWrite(Permission.qcWrite);
    } catch (_) {
      return true;
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف قائمة الفحص', 'Delete checklist'),
      name: template.name.isNotEmpty ? template.name : template.code,
    );
    if (!confirmed || !context.mounted) return;
    final cubit = context.read<QcTemplatesCubit>();
    await cubit.deleteTemplate(template.templateId ?? 0);
    if (!context.mounted) return;
    final error = cubit.state.error;
    if (error != null && error.isNotEmpty) {
      AppFeedback.error(context, error);
      cubit.clearError();
    } else {
      AppFeedback.success(
        context,
        AppText.t('تم حذف القائمة', 'Checklist deleted'),
      );
    }
  }

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
              if (canDelete) ...[
                const SizedBox(width: AppSpacing.xs),
                PopupMenuButton<String>(
                  tooltip: AppText.t('خيارات', 'Options'),
                  iconSize: 20,
                  onSelected: (v) {
                    if (v == 'delete') _confirmDelete(context);
                    if (v == 'duplicate') {
                      context.read<QcTemplatesCubit>().duplicateTemplate(
                        template.templateId ?? 0,
                        '${template.code}-COPY',
                        '${template.name} (نسخة)',
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'duplicate',
                      child: Row(
                        children: [
                          const Icon(Icons.copy_outlined, size: 18),
                          const SizedBox(width: AppSpacing.sm),
                          Text(AppText.t('نسخ', 'Duplicate')),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: AppColors.danger,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(AppText.t('حذف', 'Delete')),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
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
              QcPill(
                template.isPeriodic
                    ? AppText.t(
                        'مهام ${_recurrenceLabel(template.recurrence)}',
                        '${_recurrenceLabel(template.recurrence)} tasks',
                      )
                    : AppText.t('فحص جودة', 'Quality check'),
                template.isPeriodic ? AppColors.info : AppColors.success,
              ),
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

/// Localized label for a recurrence value (plan §3: نوعان فقط).
String _recurrenceLabel(String r) => switch (r) {
  QcRecurrence.daily => AppText.t('يومية', 'Daily'),
  QcRecurrence.weekly => AppText.t('أسبوعية', 'Weekly'),
  QcRecurrence.monthly => AppText.t('شهرية', 'Monthly'),
  _ => AppText.t('لمرة واحدة', 'One-time'),
};

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
        // Chrome (title, padding, scroll) comes from the overlay host.
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppField(
                  label: AppText.t('بحث', 'Search'),
                  controller: _search,
                  hint: AppText.t('اسم أو رمز', 'Name or code'),
                  onChanged: (v) => cubit.applyFilters(f.copyWith(text: v)),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppField(
                  label: AppText.t('القسم', 'Department'),
                  controller: _dept,
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(dept: v.trim())),
                ),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    AppButton(
                      small: true,
                      style: f.publishedOnly
                          ? AppButtonStyle.primary
                          : AppButtonStyle.secondary,
                      icon: Icon(
                        f.publishedOnly
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        size: 16,
                      ),
                      label: AppText.t('المنشورة فقط', 'Published only'),
                      onPressed: () => cubit.applyFilters(
                        f.copyWith(publishedOnly: !f.publishedOnly),
                      ),
                    ),
                    AppButton(
                      small: true,
                      style: f.includeArchived
                          ? AppButtonStyle.primary
                          : AppButtonStyle.secondary,
                      icon: Icon(
                        f.includeArchived
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        size: 16,
                      ),
                      label: AppText.t('إظهار المؤرشف', 'Show archived'),
                      onPressed: () => cubit.applyFilters(
                        f.copyWith(includeArchived: !f.includeArchived),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  AppText.t(
                    'ما يمكن بدء فحص منه',
                    'What an inspection can start from',
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(AppText.t('النوع', 'Type')),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final type in QcTemplateType.all)
                      AppButton(
                        small: true,
                        style: f.types.contains(type)
                            ? AppButtonStyle.primary
                            : AppButtonStyle.secondary,
                        label: QcPill.typeLabel(type),
                        onPressed: () => cubit.toggleType(type),
                      ),
                  ],
                ),
                AppWindow.footer(
                  actions: [
                    AppButton(
                      label: AppText.t('مسح', 'Clear'),
                      style: AppButtonStyle.secondary,
                      onPressed: () => cubit.clearFilters(),
                    ),
                    AppButton(
                      label: AppText.t('تم', 'Done'),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ],
            );
      },
    );
  }
}
