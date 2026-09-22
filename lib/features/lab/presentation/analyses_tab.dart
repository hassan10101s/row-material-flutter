import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../di/service_locator.dart';
import '../data/lab_repo.dart';
import 'cubit/analyses_cubit.dart';

/// Analyses management tab (list + create/edit/delete).
class AnalysesTab extends StatelessWidget {
  const AnalysesTab({super.key});

  Future<void> _openEditor(BuildContext context, [Map<String, dynamic>? analysis]) async {
    final cubit = context.read<AnalysesCubit>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AnalysisDialog(analysis: analysis),
    );
    if (saved == true) await cubit.load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> analysis) async {
    final cubit = context.read<AnalysesCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppText.t('حذف التحليل', 'Delete analysis')),
        content: Text('${AppText.t('حذف', 'Delete')} "${analysis['name']}"?'),
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
    if (confirmed != true) return;
    try {
      await cubit.delete((analysis['id'] as num).toInt());
      if (!context.mounted) return;
      AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      await cubit.load();
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AnalysesCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(AppText.t('التحليلات', 'Analyses'), style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            AppButton(
              small: true,
              label: AppText.t('إضافة تحليل', 'Add analysis'),
              icon: Icon(Icons.add, size: 16.r),
              onPressed: () => _openEditor(context),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (state.loading) ...[
          const Center(child: CircularProgressIndicator()),
        ] else if (state.error != null) ...[
          Text(state.error!, style: TextStyle(color: AppColors.danger)),
        ] else if (state.rows.isEmpty) ...[
          Text(AppText.t('لا توجد تحليلات', 'No analyses')),
        ] else
          AppCard(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: [
                    DataColumn(label: Text(AppText.t('الاسم', 'Name'))),
                    DataColumn(label: Text(AppText.t('الوحدة', 'Unit'))),
                    DataColumn(label: Text(AppText.t('المعادلة', 'Formula'))),
                    DataColumn(label: Text(AppText.t('المواد', 'Items'))),
                    DataColumn(label: Text(AppText.t('الحقول', 'Fields'))),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final r in state.rows)
                      DataRow(
                        cells: [
                          DataCell(Text('${r['name']}')),
                          DataCell(Text('${r['unit'] ?? '%'}')),
                          DataCell(Text(
                            '${(r['formula'] is Map ? (r['formula'] as Map)['expression'] : '') ?? ''}',
                            overflow: TextOverflow.ellipsis,
                          )),
                          DataCell(Text('${(r['items'] as List?)?.length ?? 0}')),
                          DataCell(Text((r['dynamic_fields'] as List?)?.join(', ') ?? '')),
                          DataCell(Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: AppStrings.edit,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openEditor(context, r),
                                icon: Icon(Icons.edit_outlined, size: 18.r),
                              ),
                              IconButton(
                                tooltip: AppStrings.delete,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _delete(context, r),
                                icon: Icon(Icons.delete_outline, size: 18.r),
                              ),
                            ],
                          )),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AnalysisDialog extends StatefulWidget {
  final Map<String, dynamic>? analysis;
  const _AnalysisDialog({this.analysis});

  @override
  State<_AnalysisDialog> createState() => _AnalysisDialogState();
}

class _AnalysisDialogState extends State<_AnalysisDialog> {
  final _repo = getIt<LabRepo>();
  late final TextEditingController _name =
      TextEditingController(text: '${widget.analysis?['name'] ?? ''}');
  late final TextEditingController _unit =
      TextEditingController(text: '${widget.analysis?['unit'] ?? '%'}');
  late final TextEditingController _description =
      TextEditingController(text: '${widget.analysis?['description'] ?? ''}');
  late final TextEditingController _fields = TextEditingController(
      text: (widget.analysis?['dynamic_fields'] as List?)?.join(', ') ?? 'Sample Name');
  late final TextEditingController _formula = TextEditingController(
      text: '${widget.analysis?['formula'] is Map ? (widget.analysis?['formula'] as Map)['expression'] : ''}');
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _description.dispose();
    _fields.dispose();
    _formula.dispose();
    super.dispose();
  }

  List<String> get _fieldList => [
        for (final f in _fields.text.split(','))
          if (f.trim().isNotEmpty) f.trim(),
      ];

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (widget.analysis == null) {
        await _repo.createAnalysis(
          name: _name.text,
          unit: _unit.text,
          description: _description.text,
          dynamicFields: _fieldList,
          formula: _formula.text.trim(),
        );
      } else {
        await _repo.updateAnalysis(
          analysisId: (widget.analysis!['id'] as num).toInt(),
          unit: _unit.text,
          description: _description.text,
          dynamicFields: _fieldList,
          formula: _formula.text.trim(),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.analysis == null ? 'إضافة تحليل | Add analysis' : 'تعديل تحليل | Edit analysis'),
      content: SizedBox(
        width: 460.w,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                enabled: widget.analysis == null,
                decoration: const InputDecoration(labelText: 'الاسم | Name', isDense: true),
              ),
              TextField(
                controller: _unit,
                decoration: const InputDecoration(labelText: 'الوحدة | Unit', isDense: true),
              ),
              TextField(
                controller: _description,
                maxLines: 2,
                decoration:
                    const InputDecoration(labelText: 'الوصف | Description', isDense: true),
              ),
              TextField(
                controller: _fields,
                decoration: const InputDecoration(
                  labelText: 'الحقول الديناميكية | Dynamic fields (comma-separated)',
                  isDense: true,
                ),
              ),
              TextField(
                controller: _formula,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'المعادلة | Formula expression (optional)',
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? SizedBox(
                  width: 18.r,
                  height: 18.r,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
    );
  }
}