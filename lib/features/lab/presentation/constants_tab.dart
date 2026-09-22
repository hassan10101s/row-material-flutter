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
import 'cubit/constants_cubit.dart';

/// Global formula constants management.
class ConstantsTab extends StatelessWidget {
  const ConstantsTab({super.key});

  Future<void> _openEditor(BuildContext context, [Map<String, dynamic>? constant]) async {
    final cubit = context.read<ConstantsCubit>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ConstantDialog(constant: constant),
    );
    if (saved == true) await cubit.load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> constant) async {
    final cubit = context.read<ConstantsCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppText.t('حذف الثابت', 'Delete constant')),
        content: Text('${AppText.t('حذف', 'Delete')} "${constant['name']}"?'),
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
      await cubit.delete((constant['id'] as num).toInt());
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
    final state = context.watch<ConstantsCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(AppText.t('الثوابت', 'Constants'), style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            AppButton(
              small: true,
              label: AppText.t('إضافة ثابت', 'Add constant'),
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
          Text(AppText.t('لا توجد ثوابت', 'No constants')),
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
                    DataColumn(label: Text(AppText.t('الرمز', 'Symbol'))),
                    DataColumn(label: Text(AppText.t('القيمة', 'Value'))),
                    DataColumn(label: Text(AppText.t('الوحدة', 'Unit'))),
                    DataColumn(label: Text(AppText.t('نوع', 'Type'))),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final r in state.rows)
                      DataRow(
                        cells: [
                          DataCell(Text('${r['name']}')),
                          DataCell(Text('${r['symbol']}')),
                          DataCell(Text('${r['value_text'] ?? ''}')),
                          DataCell(Text('${r['unit'] ?? ''}')),
                          DataCell(Text((r['is_expression'] as num?)?.toInt() == 1
                              ? AppText.t('تعبير', 'Expression')
                              : AppText.t('قيمة', 'Value'))),
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

class _ConstantDialog extends StatefulWidget {
  final Map<String, dynamic>? constant;
  const _ConstantDialog({this.constant});

  @override
  State<_ConstantDialog> createState() => _ConstantDialogState();
}

class _ConstantDialogState extends State<_ConstantDialog> {
  final _repo = getIt<LabRepo>();
  late final TextEditingController _name =
      TextEditingController(text: '${widget.constant?['name'] ?? ''}');
  late final TextEditingController _symbol =
      TextEditingController(text: '${widget.constant?['symbol'] ?? ''}');
  late final TextEditingController _value =
      TextEditingController(text: '${widget.constant?['value_text'] ?? ''}');
  late final TextEditingController _unit =
      TextEditingController(text: '${widget.constant?['unit'] ?? ''}');
  late final TextEditingController _description =
      TextEditingController(text: '${widget.constant?['description'] ?? ''}');
  late bool _isExpression = (widget.constant?['is_expression'] as num?)?.toInt() == 1;
  late final TextEditingController _expression =
      TextEditingController(text: '${(widget.constant?['expression'] is Map ? (widget.constant?['expression'] as Map)['expression'] : widget.constant?['expression']) ?? ''}');
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _symbol.dispose();
    _value.dispose();
    _unit.dispose();
    _description.dispose();
    _expression.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final payload = <String, dynamic>{
        if (widget.constant != null) 'id': widget.constant!['id'],
        'name': _name.text.trim(),
        'symbol': _symbol.text.trim(),
        'unit': _unit.text.trim(),
        'description': _description.text.trim(),
        'is_expression': _isExpression,
        'expression': _expression.text.trim(),
        'value_text': _value.text.trim(),
      };
      await _repo.upsertGlobalConstant(payload);
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
      title: Text(widget.constant == null ? 'إضافة ثابت | Add constant' : 'تعديل ثابت | Edit constant'),
      content: SizedBox(
        width: 440.w,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'الاسم | Name', isDense: true),
              ),
              TextField(
                controller: _symbol,
                decoration: const InputDecoration(
                  labelText: 'الرمز | Symbol (A-Z, a-z, _)',
                  isDense: true,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('تعبير | Expression'),
                      value: _isExpression,
                      onChanged: (v) => setState(() => _isExpression = v),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _unit,
                      decoration: const InputDecoration(labelText: 'الوحدة | Unit', isDense: true),
                    ),
                  ),
                ],
              ),
              if (_isExpression)
                TextField(
                  controller: _expression,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'المعادلة | Formula expression',
                    isDense: true,
                  ),
                )
              else
                TextField(
                  controller: _value,
                  decoration: const InputDecoration(labelText: 'القيمة | Value', isDense: true),
                ),
              TextField(
                controller: _description,
                decoration:
                    const InputDecoration(labelText: 'الوصف | Description', isDense: true),
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