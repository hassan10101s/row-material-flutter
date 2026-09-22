import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'dart:convert';
import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_status_badge.dart';
import '../../../di/service_locator.dart';
import 'cubit/inspection_detail_cubit.dart';
import 'inspection_widgets.dart';
/// Inspection detail: results vs reference, status history, decision
/// update and PDF export.
class InspectionDetailScreen extends StatelessWidget {
  final int inspectionId;
  const InspectionDetailScreen({super.key, required this.inspectionId});
  Future<void> _exportPdf(BuildContext context, String kind) async {
    try {
      final path = await context.read<InspectionDetailCubit>().exportPdf(kind);
      if (!context.mounted) return;
      AppFeedback.success(context, '${AppText.t('تم التصدير', 'Exported')}: $path');
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.error(context, '$e');
    }
  }
  Future<void> _openDecisionDialog(BuildContext context) async {
    final cubit = context.read<InspectionDetailCubit>();
    // Event handler — must not listen (watch) outside the widget tree.
    final inspection = cubit.state.inspection;
    if (inspection == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => DecisionDialog(
        inspectionId: inspectionId,
        inspection: inspection,
      ),
    );
    if (saved == true) {
      await cubit.load();
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم تحديث القرار', 'Decision updated.'));
      }
    }
  }
  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppText.t('حذف الفحص', 'Delete inspection')),
        content: Text(AppText.t(
          'سيتم حذف الفحص نهائياً. هل أنت متأكد؟',
          'This removes the record permanently.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppStrings.delete),
          ),
        ],
      ),
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
      if (context.mounted) AppFeedback.error(context, '$e');
    }
  }
  @override
  Widget build(BuildContext context) {
    final state = context.watch<InspectionDetailCubit>().state;
    final cubit = context.read<InspectionDetailCubit>();
    final inspection = state.inspection;
    if (state.loading) {
      return const SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.xxxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (state.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.error!, style: TextStyle(color: AppColors.danger)),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              style: AppButtonStyle.secondary,
              label: AppText.t('إعادة المحاولة', 'Retry'),
              onPressed: cubit.load,
            ),
          ],
        ),
      );
    }
    if (inspection == null) {
      return Center(child: Text(AppText.t('غير موجود', 'Not found')));
    }
    final samples = _sampleLabels(inspection);
    final user = getIt<AuthGate>().currentUser;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final title = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${inspection['material_name']}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall),
                  Text(
                    '${inspection['entry_code']} — ${inspection['material_code']}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ],
              );
              final actions = <Widget>[
                AppStatusBadge('${inspection['decision_status']}'),
                AppButton(
                  style: AppButtonStyle.pdf,
                  label: AppStrings.exportPdf,
                  icon: Icon(Icons.picture_as_pdf, size: 18.r),
                  loading: state.busy == 'report',
                  onPressed: state.busy.isEmpty ? () => _exportPdf(context, 'report') : null,
                ),
                AppButton(
                  style: AppButtonStyle.secondary,
                  label: AppText.t('ملصق', 'Label'),
                  icon: Icon(Icons.label_outline, size: 18.r),
                  loading: state.busy == 'label',
                  onPressed: state.busy.isEmpty ? () => _exportPdf(context, 'label') : null,
                ),
              ];
              if (constraints.maxWidth >= 760) {
                return Row(
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: AppSpacing.md),
                    ...actions,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: actions,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.xl),
          Wrap(
            spacing: AppSpacing.xl,
            runSpacing: AppSpacing.sm,
            children: [
              InfoItem(
                  label: AppText.t('تاريخ الفحص', 'Date'), value: '${inspection['inspection_date']}'),
              if ('${inspection['expiry_date'] ?? ''}'.trim().isNotEmpty)
                InfoItem(
                      label: AppText.t('تاريخ الانتهاء', 'Expiry'), value: '${inspection['expiry_date']}'),
                    InfoItem(label: AppText.t('المورد', 'Supplier'), value: '${inspection['supplier']}'),
              if ('${inspection['truck_number'] ?? ''}'.trim().isNotEmpty)
                InfoItem(label: AppText.t('الشاحنة', 'Truck'), value: '${inspection['truck_number']}'),
              InfoItem(label: AppText.t('الكمية', 'Qty'), value: '${inspection['quantity']}'),
              InfoItem(
                  label: AppText.t('آخذ العينة', 'Sample taker'), value: '${inspection['sample_taken_by']}'),
              InfoItem(
                    label: AppText.t('الأخصائي', 'Specialist'), value: '${inspection['specialist_name']}'),
                  InfoItem(label: AppText.t('النسخة', 'Version'), value: '${inspection['decision_version']}'),
            ],
          ),
          if ('${inspection['decision_reason'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text('${AppText.t('سبب القرار', 'Reason')}: ${inspection['decision_reason']}'),
          ],
          if ('${inspection['follow_up_note'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('${AppText.t('ملاحظة المتابعة', 'Follow-up')}: ${inspection['follow_up_note']}'),
          ],
          const SizedBox(height: AppSpacing.xl),
          ResultsCard(
            title: AppText.t('النتائج الفيزيائية', 'Physical results'),
            reference: _asMap(inspection['physical_reference']),
            results: _asMap(inspection['physical_results']),
            samples: samples,
            numeric: false,
          ),
          const SizedBox(height: AppSpacing.md),
          ResultsCard(
            title: AppText.t('النتائج الكيميائية', 'Chemical results'),
            reference: _asMap(inspection['chemical_reference']),
            results: _asMap(inspection['chemical_results']),
            samples: samples,
            numeric: true,
          ),
          if (state.history.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            HistoryCard(history: state.history),
          ],
          const SizedBox(height: AppSpacing.xl),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppButton(
                style: AppButtonStyle.accent,
                label: AppText.t('تحديث القرار', 'Update decision'),
                icon: Icon(Icons.gavel, size: 18.r),
                onPressed: (user?.canEditInspections ?? false) ? () => _openDecisionDialog(context) : null,
              ),
              if (user?.canEditUsers ?? false)
                AppButton(
                  style: AppButtonStyle.danger,
                  label: AppStrings.delete,
                  icon: Icon(Icons.delete_outline, size: 18.r),
                  onPressed: () => _delete(context),
                ),
            ],
          ),
        ],
      ),
    );
  }
  static List<String> _sampleLabels(Map<String, dynamic> inspection) {
    final names = _jsonList(inspection['sample_names']);
    final labels = names.isEmpty ? <String>['Result'] : [for (final n in names) '$n'];
    while (labels.length < 3) {
      labels.add('Sample #${labels.length + 1}');
    }
    return labels;
  }
  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }
  static List<dynamic> _jsonList(dynamic value) {
    if (value == null) return const [];
    if (value is List) return value;
    try {
      return jsonDecode('$value');
    } catch (_) {
      return const [];
    }
  }
}
/// Results vs reference table.
class ResultsCard extends StatelessWidget {
  final String title;
  final Map<String, dynamic> reference;
  final Map<String, dynamic> results;
  final List<String> samples;
  final bool numeric;
  const ResultsCard({
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
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text(AppText.t('الخاصية', 'Parameter'),
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.spMax)),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text(AppText.t('المرجعية', 'Reference'),
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.spMax)),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text(AppText.t('النتيجة', 'Result'),
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.spMax)),
                    ),
                    SizedBox(),
                  ],
                ),
                for (final param in params)
                  TableRow(
                    children: _rowFor(param),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  List<Widget> _rowFor(String param) {
    final ref = '${reference[param] ?? ''}';
    dynamic value = results[param];
    final List<dynamic> values = value is List
        ? value
        : value == null || '$value'.trim().isEmpty
            ? <dynamic>[]
            : <dynamic>[value];
    final cells = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(param, style: TextStyle(fontSize: 13.spMax)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(ref,
            style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: values.isEmpty
            ? Text('—', style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax))
            : Wrap(
                spacing: AppSpacing.lg,
                children: [
                  for (var i = 0; i < values.length; i++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (values.length > 1)
                          Text('${samples[i]} ',
                              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax)),
                        Text('${values[i]}', style: TextStyle(fontSize: 13.spMax)),
                      ],
                    ),
                ],
              ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _statusIcon(ref, values),
      ),
    ];
    return cells;
  }
  Widget _statusIcon(String ref, List<dynamic> values) {
    if (!numeric || ref.trim().isEmpty || values.isEmpty) {
      return const SizedBox();
    }
    final anyFail = values.any((v) =>
        checkResultPass(reference: ref, value: '$v', numeric: true).pass == false);
    if (anyFail) {
      return Icon(Icons.close, size: 16.r, color: AppColors.danger);
    }
    return Icon(Icons.check_circle_outline, size: 16.r, color: AppColors.success);
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
            Text(AppText.t('سجل القرارات', 'Decision history'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
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
                            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
                          ),
                          if ('${row['change_reason'] ?? ''}'.trim().isNotEmpty)
                            Text('سبب: ${row['change_reason']}',
                                style: TextStyle(fontSize: 12.spMax)),
                          if ('${row['follow_up_note'] ?? ''}'.trim().isNotEmpty)
                            Text('متابعة: ${row['follow_up_note']}',
                                style: TextStyle(fontSize: 12.spMax)),
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