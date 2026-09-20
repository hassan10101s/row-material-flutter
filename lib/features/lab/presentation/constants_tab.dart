import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../di/service_locator.dart';
import '../data/lab_repo.dart';

/// Global formula constants management.
class ConstantsTab extends StatefulWidget {
  const ConstantsTab({super.key});

  @override
  State<ConstantsTab> createState() => _ConstantsTabState();
}

class _ConstantsTabState extends State<ConstantsTab> {
  final _repo = getIt<LabRepo>();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
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
      final rows = await _repo.listGlobalConstants();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _openEditor([Map<String, dynamic>? constant]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ConstantDialog(constant: constant),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> constant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الثابت | Delete constant'),
        content: Text('حذف "${constant['name']}"؟ | Delete this constant?'),
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
      await _repo.deleteGlobalConstant((constant['id'] as num).toInt());
      if (mounted) {
        AppFeedback.success(context, 'تم الحذف | Deleted.');
        _load();
      }
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('الثوابت | Constants', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            AppButton(
              small: true,
              label: 'إضافة ثابت | Add constant',
              icon: const Icon(Icons.add, size: 16),
              onPressed: () => _openEditor(),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (_loading) ...[
          const Center(child: CircularProgressIndicator()),
        ] else if (_error != null) ...[
          Text(_error!, style: TextStyle(color: AppColors.danger)),
        ] else if (_rows.isEmpty) ...[
          const Text('لا توجد ثوابت | No constants'),
        ] else
          AppCard(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('الاسم | Name')),
                    DataColumn(label: Text('الرمز | Symbol')),
                    DataColumn(label: Text('القيمة | Value')),
                    DataColumn(label: Text('الوحدة | Unit')),
                    DataColumn(label: Text('نوع | Type')),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final r in _rows)
                      DataRow(
                        cells: [
                          DataCell(Text('${r['name']}')),
                          DataCell(Text('${r['symbol']}')),
                          DataCell(Text('${r['value_text'] ?? ''}')),
                          DataCell(Text('${r['unit'] ?? ''}')),
                          DataCell(Text((r['is_expression'] as num?)?.toInt() == 1
                              ? 'تعبير | Expression'
                              : 'قيمة | Value')),
                          DataCell(Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: AppStrings.edit,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openEditor(r),
                                icon: const Icon(Icons.edit_outlined, size: 18),
                              ),
                              IconButton(
                                tooltip: AppStrings.delete,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _delete(r),
                                icon: const Icon(Icons.delete_outline, size: 18),
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
        width: 440,
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
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(AppStrings.save),
        ),
      ],
    );
  }
}