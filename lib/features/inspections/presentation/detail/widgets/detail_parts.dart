import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../app/auth_gate.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_status_badge.dart';
import '../../../../../di/service_locator.dart';
import '../../cubit/inspection_detail_cubit.dart';
import '../../cubit/inspection_detail_state.dart';
import 'inspection_widgets.dart';

/// Shared inspection-detail pieces, composed by both variants.
///
/// Data and mutation live in [InspectionDetailCubit]; everything here is
/// pure rendering + callbacks. The desktop variant renders results as a
/// table, the mobile variant as per-parameter cards.

Map<String, dynamic> asMap(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

List<dynamic> jsonList(dynamic value) {
  if (value == null) return const [];
  if (value is List) return value;
  try {
    return jsonDecode('$value');
  } catch (_) {
    return const [];
  }
}

List<String> sampleLabels(Map<String, dynamic> inspection) {
  final names = jsonList(inspection['sample_names']);
  final labels = names.isEmpty
      ? <String>['Result']
      : [for (final n in names) '$n'];
  while (labels.length < 3) {
    labels.add('Sample #${labels.length + 1}');
  }
  return labels;
}

/// Title + decision badge + PDF/label actions. Stacks below the medium
/// breakpoint (single-experience layout, not a form-factor branch).
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.inspection,
    required this.state,
    required this.onExportPdf,
  });

  final Map<String, dynamic> inspection;
  final InspectionDetailState state;
  final void Function(String kind) onExportPdf;

  @override
  Widget build(BuildContext context) {
    return AppPageHeader(
      title: '${inspection['material_name']}',
      subtitle: '${inspection['entry_code']} — ${inspection['material_code']}',
      icon: Icons.fact_check_outlined,
      actions: [
        AppStatusBadge('${inspection['decision_status']}'),
        AppButton(
          style: AppButtonStyle.pdf,
          label: AppStrings.exportPdf,
          icon: Icon(Icons.picture_as_pdf, size: 18.r),
          loading: state.busy == 'report',
          onPressed: state.busy.isEmpty ? () => onExportPdf('report') : null,
        ),
        AppButton(
          style: AppButtonStyle.secondary,
          label: AppText.t('ملصق', 'Label'),
          icon: Icon(Icons.label_outline, size: 18.r),
          loading: state.busy == 'label',
          onPressed: state.busy.isEmpty ? () => onExportPdf('label') : null,
        ),
      ],
    );
  }
}

/// Info facts + decision reason/follow-up lines.
class DetailInfo extends StatelessWidget {
  const DetailInfo({super.key, required this.inspection});

  final Map<String, dynamic> inspection;

  @override
  Widget build(BuildContext context) {
    final isProduct = '${inspection['inspection_kind'] ?? 'raw'}' == 'product';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.xl,
          runSpacing: AppSpacing.sm,
          children: [
            InfoItem(
              label: AppText.t('تاريخ الفحص', 'Date'),
              value: '${inspection['inspection_date']}',
            ),
            if ('${inspection['expiry_date'] ?? ''}'.trim().isNotEmpty)
              InfoItem(
                label: AppText.t('تاريخ الانتهاء', 'Expiry'),
                value: '${inspection['expiry_date']}',
              ),
            if (isProduct) ...[
              InfoItem(
                label: AppText.t('رقم الفورمولا', 'Formula no.'),
                value: '${inspection['formula_number'] ?? ''}',
              ),
              InfoItem(
                label: AppText.t('رقم التشغيلة', 'Batch no.'),
                value: '${inspection['batch_number'] ?? ''}',
              ),
            ] else ...[
              InfoItem(
                label: AppText.t('المورد', 'Supplier'),
                value: '${inspection['supplier']}',
              ),
              if ('${inspection['truck_number'] ?? ''}'.trim().isNotEmpty)
                InfoItem(
                  label: AppText.t('الشاحنة', 'Truck'),
                  value: '${inspection['truck_number']}',
                ),
            ],
            InfoItem(
              label: AppText.t('الكمية', 'Qty'),
              value: '${inspection['quantity']}',
            ),
            InfoItem(
              label: AppText.t('آخذ العينة', 'Sample taker'),
              value: '${inspection['sample_taken_by']}',
            ),
            InfoItem(
              label: AppText.t('الأخصائي', 'Specialist'),
              value: '${inspection['specialist_name']}',
            ),
            InfoItem(
              label: AppText.t('النسخة', 'Version'),
              value: '${inspection['decision_version']}',
            ),
          ],
        ),
        if ('${inspection['decision_reason'] ?? ''}'.trim().isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            '${AppText.t('سبب القرار', 'Reason')}: ${inspection['decision_reason']}',
          ),
        ],
        if ('${inspection['follow_up_note'] ?? ''}'.trim().isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${AppText.t('ملاحظة المتابعة', 'Follow-up')}: ${inspection['follow_up_note']}',
          ),
        ],
      ],
    );
  }
}

/// Bottom edit + update-decision + delete actions.
class DetailFooterActions extends StatelessWidget {
  const DetailFooterActions({
    super.key,
    required this.state,
    required this.onEdit,
    required this.onUpdateDecision,
    required this.onDelete,
  });

  final InspectionDetailState state;
  final VoidCallback onEdit;
  final VoidCallback onUpdateDecision;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final user = getIt<AuthGate>().currentUser;
    final canEdit = user?.canEditInspections ?? false;
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        AppButton(
          label: AppText.t('تعديل المحضر', 'Edit record'),
          icon: Icon(Icons.edit_outlined, size: 18.r),
          onPressed: canEdit ? onEdit : null,
        ),
        AppButton(
          style: AppButtonStyle.accent,
          label: AppText.t('تحديث القرار', 'Update decision'),
          icon: Icon(Icons.gavel, size: 18.r),
          onPressed: canEdit ? onUpdateDecision : null,
        ),
        if (user?.canEditUsers ?? false)
          AppButton(
            style: AppButtonStyle.danger,
            label: AppStrings.delete,
            icon: Icon(Icons.delete_outline, size: 18.r),
            onPressed: onDelete,
          ),
      ],
    );
  }
}

/// Lab chemical analyses linked to the record.
class LabAnalysesCard extends StatelessWidget {
  const LabAnalysesCard({super.key, required this.analyses});

  final List<Map<String, dynamic>> analyses;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t(
              'تحاليل المعمل المرتبطة بالمحضر',
              'Lab chemical analyses linked to this record',
            ),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (analyses.isEmpty)
            Text(
              AppText.t(
                'لا توجد تحاليل معمل مرتبطة بهذا المحضر.',
                'No lab analyses are linked to this inspection record.',
              ),
              style: TextStyle(color: AppColors.textMuted),
            )
          else
            for (var i = 0; i < analyses.length; i++) ...[
              if (i > 0) const Divider(height: AppSpacing.md),
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('${analyses[i]['analysis_name'] ?? ''}'),
                subtitle: Text(
                  '${AppText.t('العينة', 'Sample')}: '
                  '${analyses[i]['sample_name'] ?? ''}'
                  '${'${analyses[i]['tested_at'] ?? ''}'.trim().isEmpty ? '' : ' · ${analyses[i]['tested_at']}'}',
                ),
                trailing: Text(
                  '${analyses[i]['result_text'] ?? ''}'
                  '${'${analyses[i]['analysis_unit'] ?? ''}'.isEmpty ? '' : ' ${analyses[i]['analysis_unit']}'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                  textAlign: TextAlign.end,
                ),
              ),
            ],
        ],
      ),
    );
  }
}

/// Status-history timeline.
class HistoryCard extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  const HistoryCard({super.key, required this.history});
  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppText.t('سجل القرارات', 'Decision history'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final row in history)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.timeline, size: 16.r),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: AppSpacing.sm,
                        runSpacing: 4,
                        children: [
                          AppStatusBadge('${row['new_status']}'),
                          Text(
                            '${AppText.t('النسخة', 'v')} ${row['version']} by '
                            '${row['changed_by_name']} — ${row['changed_at']}',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12.spMax,
                            ),
                          ),
                          if ('${row['change_reason'] ?? ''}'.trim().isNotEmpty)
                            Text(
                              'سبب: ${row['change_reason']}',
                              style: TextStyle(fontSize: 12.spMax),
                            ),
                          if ('${row['follow_up_note'] ?? ''}'
                              .trim()
                              .isNotEmpty)
                            Text(
                              'متابعة: ${row['follow_up_note']}',
                              style: TextStyle(fontSize: 12.spMax),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Pass/fail icon for one reference bound + measured values.
Widget resultStatusIcon(String ref, List<dynamic> values, bool numeric) {
  if (!numeric || ref.trim().isEmpty || values.isEmpty) {
    return const SizedBox();
  }
  final anyFail = values.any(
    (v) =>
        checkResultPass(reference: ref, value: '$v', numeric: true).pass ==
        false,
  );
  if (anyFail) {
    return Icon(Icons.close, size: 16.r, color: AppColors.danger);
  }
  return Icon(
    Icons.check_circle_outline,
    size: 16.r,
    color: AppColors.success,
  );
}

List<dynamic> resultValues(Map<String, dynamic> results, String param) {
  dynamic value = results[param];
  if (value is List) return value;
  if (value == null || '$value'.trim().isEmpty) return <dynamic>[];
  return <dynamic>[value];
}

/// Desktop results-vs-reference table, verbatim from the pre-split screen.
class ResultsTable extends StatelessWidget {
  final String title;
  final Map<String, dynamic> reference;
  final Map<String, dynamic> results;
  final List<String> samples;
  final bool numeric;
  const ResultsTable({
    super.key,
    required this.title,
    required this.reference,
    required this.results,
    required this.samples,
    required this.numeric,
  });

  @override
  Widget build(BuildContext context) {
    if (reference.isEmpty) return const SizedBox.shrink();
    final params = reference.keys.toList();
    Widget cell(String text, {Color? color, bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13.spMax,
          color: color,
          fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.sm),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2.2),
                1: FlexColumnWidth(1.8),
                2: FlexColumnWidth(3.4),
                3: FixedColumnWidth(28),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  children: [
                    cell(
                      AppText.t('الخاصية', 'Parameter'),
                      strong: true,
                    ),
                    cell(
                      AppText.t('المرجعية', 'Reference'),
                      strong: true,
                    ),
                    cell(
                      AppText.t('النتيجة', 'Result'),
                      strong: true,
                    ),
                    const SizedBox(),
                  ],
                ),
                for (final param in params)
                  TableRow(
                    children: [
                      cell(param),
                      cell(
                        '${reference[param] ?? ''}',
                        color: AppColors.textMuted,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: _resultValues(
                          context,
                          param,
                          resultValues(results, param),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: resultStatusIcon(
                          '${reference[param] ?? ''}',
                          resultValues(results, param),
                          numeric,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultValues(
    BuildContext context,
    String param,
    List<dynamic> values,
  ) {
    if (values.isEmpty) {
      return Text(
        '—',
        style: TextStyle(
          color: AppColors.textMuted,
          fontSize: 13.spMax,
        ),
      );
    }
    return Wrap(
      spacing: AppSpacing.lg,
      children: [
        for (var i = 0; i < values.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (values.length > 1)
                Text(
                  '${samples[i]} ',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.spMax,
                  ),
                ),
              Text(
                '${values[i]}',
                style: TextStyle(fontSize: 13.spMax),
              ),
            ],
          ),
      ],
    );
  }
}

/// Mobile results: one card per parameter (a four-column flex table at
/// 400dp squeezes reference and result past readability).
class ResultsCards extends StatelessWidget {
  final String title;
  final Map<String, dynamic> reference;
  final Map<String, dynamic> results;
  final List<String> samples;
  final bool numeric;
  const ResultsCards({
    super.key,
    required this.title,
    required this.reference,
    required this.results,
    required this.samples,
    required this.numeric,
  });

  @override
  Widget build(BuildContext context) {
    if (reference.isEmpty) return const SizedBox.shrink();
    final params = reference.keys.toList();
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.sm),
            for (var p = 0; p < params.length; p++) ...[
              if (p > 0) const Divider(height: AppSpacing.lg),
              _ParamCard(
                param: params[p],
                ref: '${reference[params[p]] ?? ''}',
                values: resultValues(results, params[p]),
                samples: samples,
                numeric: numeric,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ParamCard extends StatelessWidget {
  const _ParamCard({
    required this.param,
    required this.ref,
    required this.values,
    required this.samples,
    required this.numeric,
  });

  final String param;
  final String ref;
  final List<dynamic> values;
  final List<String> samples;
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                param,
                style: TextStyle(
                  fontSize: 13.spMax,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textStrong,
                ),
              ),
            ),
            resultStatusIcon(ref, values, numeric),
          ],
        ),
        Text(
          '${AppText.t('المرجعية', 'Reference')}: $ref',
          style: TextStyle(
            fontSize: 12.spMax,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 4),
        if (values.isEmpty)
          Text(
            '—',
            style: TextStyle(
              fontSize: 13.spMax,
              color: AppColors.textMuted,
            ),
          )
        else
          for (var i = 0; i < values.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  if (values.length > 1)
                    SizedBox(
                      width: 88,
                      child: Text(
                        samples[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.spMax,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      '${values[i]}',
                      style: TextStyle(
                        fontSize: 14.spMax,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textStrong,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// Exports a PDF or label through the cubit and reports the saved file.
Future<void> exportInspectionPdf(BuildContext context, String kind) async {
  try {
    final path = await context.read<InspectionDetailCubit>().exportPdf(kind);
    if (!context.mounted) return;
    AppFeedback.success(
      context,
      '${AppText.t('تم التصدير', 'Exported')}: $path',
    );
  } on AppError catch (e) {
    if (context.mounted) AppFeedback.error(context, e.message);
  } catch (e) {
    if (context.mounted) AppFeedback.errorFrom(context, e);
  }
}

/// Delete with the adaptive confirm (dialog on desktop, sheet on phones).
Future<void> deleteInspection(BuildContext context) async {
  final confirmed = await showAppConfirm(
    context,
    title: AppText.t('حذف الفحص', 'Delete inspection'),
    message: AppText.t(
      'سيتم حذف الفحص نهائياً. هل أنت متأكد؟',
      'This removes the record permanently.',
    ),
    danger: true,
    confirmLabel: AppStrings.delete,
    cancelLabel: AppStrings.cancel,
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await context.read<InspectionDetailCubit>().delete();
    if (!context.mounted) return;
    AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
    Navigator.of(context).pop(true);
  } on AppError catch (e) {
    if (context.mounted) AppFeedback.error(context, e.message);
  } catch (e) {
    if (context.mounted) AppFeedback.errorFrom(context, e);
  }
}
