import 'package:flutter/material.dart';
import '../../../../core/utils/decimal_input.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_select_field.dart';
import '../../../../design_system/widgets/app_text_field.dart';
import '../../core/formula_engine.dart' show safeFormulaFloat, unitDimOf;

/// Edits a local copy. Closing without Apply never changes the analysis form.
class AnalysisFieldConfigEditor extends StatefulWidget {
  const AnalysisFieldConfigEditor({
    super.key,
    required this.initial,
    required this.inventory,
    required this.units,
  });

  final Map<String, dynamic> initial;
  final List<Map<String, dynamic>> inventory;
  final List<String> Function(String current, int? inventoryId) units;

  @override
  State<AnalysisFieldConfigEditor> createState() =>
      AnalysisFieldConfigEditorState();
}

class AnalysisFieldConfigEditorState extends State<AnalysisFieldConfigEditor> {
  late final _kind = '${widget.initial['kind']}';
  late int? _inventoryId = int.tryParse(
    '${widget.initial['inventory_id'] ?? ''}',
  );
  late String _unit = '${widget.initial['unit'] ?? 'mL'}';
  late final _value = TextEditingController(
    text: '${widget.initial['fixed_value'] ?? ''}',
  );
  final _newValue = TextEditingController();
  late final List<String> _values = [
    for (final value in widget.initial['list_values'] as List? ?? const [])
      '$value',
  ];
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _newValue.dispose();
    super.dispose();
  }

  void _addValue() {
    final text = _newValue.text.trim();
    if (safeFormulaFloat(text) == null) {
      setState(
        () => _error = AppText.t('أدخل قيمة رقمية.', 'Enter a numeric value.'),
      );
      return;
    }
    setState(() {
      _values.add(text);
      _newValue.clear();
      _error = null;
    });
  }

  Map<String, dynamic>? validatedConfiguration() {
    if (_kind == 'list' && _newValue.text.trim().isNotEmpty) {
      if (safeFormulaFloat(_newValue.text.trim()) == null) {
        setState(
          () =>
              _error = AppText.t('أدخل قيمة رقمية.', 'Enter a numeric value.'),
        );
        return null;
      }
      _addValue();
    }
    final item = widget.inventory
        .where((row) => '${row['id']}' == '$_inventoryId')
        .firstOrNull;
    final number = safeFormulaFloat(_value.text);
    final error = _kind == 'link' && item == null
        ? AppText.t('اختر مادة من المخزون.', 'Choose a stock item.')
        : _kind == 'value' && number == null
        ? AppText.t('أدخل قيمة رقمية.', 'Enter a numeric value.')
        : _kind == 'list' && _values.isEmpty
        ? AppText.t('أضف قيمة واحدة على الأقل.', 'Add at least one value.')
        : null;
    setState(() => _error = error);
    if (error != null) return null;
    return switch (_kind) {
      'link' => {
        'kind': 'link',
        'inventory_id': _inventoryId,
        'inventory_name': '${item!['name']}',
        'unit': _unit,
      },
      'value' => {'kind': 'value', 'fixed_value': number},
      _ => {'kind': 'list', 'list_values': List<String>.of(_values)},
    };
  }

  @override
  Widget build(BuildContext context) {
    final selectedAvailable = widget.inventory.any(
      (row) => '${row['id']}' == '$_inventoryId',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_kind == 'link') ...[
          Text(
            AppText.t(
              'اختر المادة التي يُحسب استهلاكها من قيمة هذا الحقل.',
              'Choose the stock item consumed according to this field value.',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppSelectField<int>(
            initialValue: selectedAvailable ? _inventoryId : null,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: InputDecoration(
              labelText: AppText.t('المادة', 'Stock item'),
            ),
            items: [
              for (final item in widget.inventory)
                DropdownMenuItem(
                  value: (item['id'] as num).toInt(),
                  child: Text(
                    '${item['name']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) => setState(() {
              _inventoryId = id;
              final item = widget.inventory
                  .where((row) => '${row['id']}' == '$id')
                  .firstOrNull;
              _unit = '${item?['unit'] ?? 'mL'}';
              _error = null;
            }),
          ),
          if (selectedAvailable) ...[
            const SizedBox(height: AppSpacing.md),
            AppSelectField<String>(
              key: ValueKey('field-consume-unit-$_inventoryId-$_unit'),
              initialValue: _unit.isEmpty ? null : _unit,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: AppText.t('وحدة الاستهلاك', 'Consume unit'),
              ),
              items: [
                for (final unit in widget.units(_unit, _inventoryId))
                  DropdownMenuItem(value: unit, child: Text(unit)),
              ],
              onChanged: (unit) => setState(() => _unit = unit ?? _unit),
            ),
            if (unitDimOf(_unit) !=
                unitDimOf(
                  '${widget.inventory.firstWhere((row) => '${row['id']}' == '$_inventoryId')['unit'] ?? ''}',
                )) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                AppText.t(
                  'وحدة الاستهلاك لا تطابق وحدة مادة المخزون.',
                  'The consumption unit does not match the stock item unit.',
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ] else if (_kind == 'value') ...[
          Text(
            AppText.t(
              'تُستخدم هذه القيمة تلقائيًا في المعادلة.',
              'This value is used automatically in the formula.',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppTextField(
            controller: _value,
            inputFormatters: [DecimalInputFormatter(signed: true)],
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: InputDecoration(
              labelText: AppText.t('القيمة الثابتة', 'Fixed value'),
            ),
          ),
        ] else ...[
          Text(
            AppText.t(
              'أضف القيم المتاحة؛ يختار المستخدم منها عند إجراء الفحص.',
              'Add the available values. The user chooses one during the test.',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (_values.isEmpty)
            Text(
              AppText.t(
                'القائمة فارغة. أضف قيمك أدناه.',
                'The list is empty. Add your values below.',
              ),
            )
          else
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (var index = 0; index < _values.length; index++)
                  InputChip(
                    label: Text(_values[index]),
                    onDeleted: () => setState(() => _values.removeAt(index)),
                  ),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: AppTextField(
                  controller: _newValue,
                  inputFormatters: [DecimalInputFormatter(signed: true)],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  onSubmitted: (_) => _addValue(),
                  decoration: InputDecoration(
                    labelText: AppText.t('قيمة جديدة', 'New value'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppButton(
                small: true,
                label: AppText.t('إضافة', 'Add'),
                onPressed: _addValue,
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}
