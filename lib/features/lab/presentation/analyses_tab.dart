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
import '../core/formula_engine.dart'
    show inventoryUnits, safeFormulaFloat, unitDimOf, validateFormula;
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
  late final TextEditingController _formula = TextEditingController(
      text: '${widget.analysis?['formula'] is Map ? (widget.analysis?['formula'] as Map)['expression'] : ''}');
  final _newFieldController = TextEditingController();
  final List<TextEditingController> _fieldControllers = [];
  final List<Map<String, dynamic>> _fieldLinks = [];
  final List<Map<String, dynamic>> _consumedItems = [];
  List<Map<String, dynamic>> _inventory = [];
  int _linkPicker = -1;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final fields = [
      for (final f in (widget.analysis?['dynamic_fields'] as List?) ??
          const ['Sample Name'])
        if ('$f'.trim().isNotEmpty) '$f'.trim(),
    ];
    final links = Map<String, Map<String, dynamic>>.fromEntries([
      for (final l in (widget.analysis?['field_chemical_links'] as List?) ??
          const <Object?>[])
        if (l is Map && '${l['dynamic_field'] ?? ''}'.trim().isNotEmpty)
          MapEntry(
            '${l['dynamic_field']}'.trim(),
            Map<String, dynamic>.from(l),
          ),
    ]);
    for (final f in fields) {
      _fieldControllers.add(TextEditingController(text: f));
      _fieldLinks.add(_decodeFieldConfig(links[f]));
    }
    for (final item in (widget.analysis?['items'] as List?) ?? const []) {
      if (item is Map) {
        final m = Map<String, dynamic>.from(item);
        m['qtyCtrl'] =
            TextEditingController(text: _fmtNum(item['qty_per_sample']));
        _consumedItems.add(m);
      }
    }
    _loadInventory();
  }

  Map<String, dynamic> _decodeFieldConfig(Map<String, dynamic>? row) {
    if (row == null) return {'kind': 'none'};
    final kind = '${row['kind'] ?? 'link'}';
    final cfg = <String, dynamic>{'kind': kind};
    if (kind == 'link') {
      cfg['inventory_id'] = row['inventory_id'];
      cfg['inventory_name'] = row['inventory_name'] ?? '';
      cfg['unit'] = row['unit'] ?? 'mL';
    } else if (kind == 'value') {
      cfg['fixed_value'] = safeFormulaFloat(row['fixed_value']);
    } else if (kind == 'list') {
      cfg['list_values'] = [
        for (final v in row['list_values'] is List
            ? row['list_values'] as List
            : const [])
          '$v',
      ];
    }
    return cfg;
  }

  Future<void> _loadInventory() async {
    try {
      final items = await _repo.listInventory();
      if (mounted) setState(() => _inventory = items);
    } catch (_) {}
  }

  void _disposeFieldEditors(int index) {
    final cfg = _fieldLinks[index];
    (cfg['valueCtrl'] as TextEditingController?)?.dispose();
    (cfg['listAddCtrl'] as TextEditingController?)?.dispose();
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _description.dispose();
    _formula.dispose();
    _newFieldController.dispose();
    for (final c in _fieldControllers) {
      c.dispose();
    }
    for (final cfg in _fieldLinks) {
      (cfg['valueCtrl'] as TextEditingController?)?.dispose();
      (cfg['listAddCtrl'] as TextEditingController?)?.dispose();
    }
    for (final item in _consumedItems) {
      (item['qtyCtrl'] as TextEditingController?)?.dispose();
    }
    super.dispose();
  }

  List<String> get _fieldList => [
        for (final c in _fieldControllers)
          if (c.text.trim().isNotEmpty) c.text.trim(),
      ];

  static const List<String> _formulaOps = ['(', ')', '+', '-', '*', '/', '^', '%'];

  List<({String label, String value})> get _formulaTokens {
    final tokens = <({String label, String value})>[
      for (final f in _fieldList)
        if (f.isNotEmpty) (label: '$f (حقل)', value: f),
    ];
    for (final n in _existingConstants?.keys ?? const <String>[]) {
      if (n.trim().isNotEmpty) tokens.add((label: '$n (ثابت)', value: n));
    }
    return tokens;
  }

  Map<String, dynamic>? get _existingConstants {
    final raw = widget.analysis?['formula'];
    if (raw is Map && raw['constants'] is Map) {
      return Map<String, dynamic>.from(raw['constants'] as Map);
    }
    return null;
  }

  void _insertFormulaToken(String token) {
    final text = _formula.text;
    final sel = _formula.selection;
    final start = sel.isValid && sel.start >= 0 ? sel.start : text.length;
    final end = sel.isValid && sel.end >= start ? sel.end : start;
    final next = text.replaceRange(start, end, token);
    _formula.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  ({String? error, List<String> unresolved, bool empty}) get _formulaStatus {
    final expr = _formula.text.trim();
    if (expr.isEmpty) return (error: null, unresolved: const [], empty: true);
    try {
      final vars = validateFormula(expr);
      final known = <String>{
        for (final f in _fieldList)
          if (f.trim().isNotEmpty) f.trim(),
        ...?_existingConstants?.keys,
        for (final i in widget.analysis?['items'] as List? ?? const [])
          if (i is Map) '${i['inventory_name'] ?? ''}'.trim(),
      };
      final unresolved = [
        for (final v in vars)
          if (!known.contains(v) &&
              v.toLowerCase() != 'true' &&
              v.toLowerCase() != 'false')
            v
      ];
      return (error: null, unresolved: unresolved, empty: false);
    } on ValidationError catch (e) {
      return (error: e.message, unresolved: const [], empty: false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final links = <Map<String, dynamic>>[];
    for (var i = 0; i < _fieldControllers.length; i++) {
      final cfg = _fieldLinks[i];
      final field = _fieldList[i];
      final kind = '${cfg['kind'] ?? 'none'}';
      if (kind == 'link') {
        final id = int.tryParse('${cfg['inventory_id'] ?? 0}') ?? 0;
        if (id > 0) {
          links.add({
            'dynamic_field': field,
            'kind': 'link',
            'inventory_id': id,
            'unit': cfg['unit'] ?? 'mL',
          });
        }
      } else if (kind == 'value') {
        final v = safeFormulaFloat(cfg['fixed_value']);
        if (v != null) {
          links.add({
            'dynamic_field': field,
            'kind': 'value',
            'inventory_id': 0,
            'fixed_value': v,
          });
        }
      } else if (kind == 'list') {
        final values = <num>[
          for (final s in (cfg['list_values'] as List?) ?? const [])
            if (safeFormulaFloat(s) != null) safeFormulaFloat(s)!,
        ];
        if (values.isNotEmpty) {
          links.add({
            'dynamic_field': field,
            'kind': 'list',
            'inventory_id': 0,
            'list_values': values,
          });
        }
      }
    }
    final consumedItems = <Map<String, dynamic>>[
      for (final item in _consumedItems)
        {
          'inventory_id':
              int.tryParse('${item['inventory_id'] ?? 0}') ?? 0,
          'qty_per_sample': safeFormulaFloat(
                  (item['qtyCtrl'] as TextEditingController).text) ??
              0,
          'unit': '${item['unit'] ?? 'g'}',
        },
    ];
    try {
      if (widget.analysis == null) {
        await _repo.createAnalysis(
          name: _name.text,
          unit: _unit.text,
          description: _description.text,
          dynamicFields: _fieldList,
          formula: _formula.text.trim(),
          items: consumedItems,
          fieldChemicalLinks: links,
        );
      } else {
        await _repo.updateAnalysis(
          analysisId: (widget.analysis!['id'] as num).toInt(),
          unit: _unit.text,
          description: _description.text,
          dynamicFields: _fieldList,
          formula: _formula.text.trim(),
          items: consumedItems,
          fieldChemicalLinks: links,
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

  void _addField() {
    final name = _newFieldController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _fieldControllers.add(TextEditingController(text: name));
      _fieldLinks.add({'kind': 'none'});
      _newFieldController.clear();
    });
  }

  void _removeField(int index) {
    setState(() {
      _disposeFieldEditors(index);
      _fieldControllers[index].dispose();
      _fieldControllers.removeAt(index);
      _fieldLinks.removeAt(index);
      if (_linkPicker >= _fieldControllers.length) _linkPicker = -1;
    });
  }

  String _kindOf(int index) => '${_fieldLinks[index]['kind'] ?? 'none'}';

  void _setFieldKind(int index, String kind) {
    setState(() {
      final prev = _kindOf(index);
      if (prev == kind) return;
      _disposeFieldEditors(index);
      final cfg = <String, dynamic>{'kind': kind};
      if (kind == 'link') cfg['unit'] = 'mL';
      if (kind == 'list') cfg['list_values'] = <String>['2', '5', '10'];
      _fieldLinks[index] = cfg;
      _linkPicker = -1;
    });
  }

  Widget _kindChips(int index) {
    final kind = _kindOf(index);
    return Wrap(
      spacing: 4,
      children: [
        _kindChip(index, 'none', kind, 'بدون'),
        _kindChip(index, 'link', kind, 'رابط'),
        _kindChip(index, 'value', kind, 'قيمة'),
        _kindChip(index, 'list', kind, 'قائمة'),
      ],
    );
  }

  Widget _fieldSummaryChip(int index) {
    final kind = _kindOf(index);
    if (kind == 'value') {
      final v = safeFormulaFloat(_fieldLinks[index]['fixed_value']);
      return v == null
          ? const SizedBox.shrink()
          : _stateChip(Icons.pin_outlined, '= $v', AppColors.info);
    }
    if (kind == 'list') {
      final n =
          ((_fieldLinks[index]['list_values'] as List?) ?? const []).length;
      return n == 0
          ? const SizedBox.shrink()
          : _stateChip(Icons.view_list_outlined, 'قائمة ($n)', AppColors.accent);
    }
    if (kind == 'link') {
      final id = int.tryParse('${_fieldLinks[index]['inventory_id'] ?? 0}') ?? 0;
      final name = '${_fieldLinks[index]['inventory_name'] ?? ''}';
      return id <= 0
          ? const SizedBox.shrink()
          : _stateChip(Icons.link_outlined, name, AppColors.success);
    }
    return const SizedBox.shrink();
  }

  Widget _stateChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13.r, color: color),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.spMax, color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kindChip(int index, String value, String current, String label) {
    return ChoiceChip(
      visualDensity: VisualDensity.compact,
      label: Text(label, style: TextStyle(fontSize: 12.spMax)),
      selected: current == value,
      onSelected: (_) => _setFieldKind(index, value),
    );
  }

  Widget _linkSummary(int index) {
    final cfg = _fieldLinks[index];
    if (int.tryParse('${cfg['inventory_id'] ?? 0}') == null ||
        (int.tryParse('${cfg['inventory_id'] ?? 0}') ?? 0) <= 0) {
      return ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.link, size: 14.r),
        label: Text('ربط', style: TextStyle(fontSize: 12.spMax)),
        onPressed: () => setState(() => _linkPicker = _linkPicker == index ? -1 : index),
      );
    }
    final name = '${cfg['inventory_name'] ?? ''}';
    final unit = '${cfg['unit'] ?? ''}';
    return InputChip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.link, size: 14.r),
      label: Text(name.isEmpty ? 'مرتبط' : '$name ${unit.isNotEmpty ? '($unit)' : ''}',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.spMax)),
      onPressed: () => setState(() => _linkPicker = _linkPicker == index ? -1 : index),
      onDeleted: () => setState(() {
        _fieldLinks[index] = {'kind': 'link', 'unit': 'mL'};
        _linkPicker = -1;
      }),
    );
  }

  Widget _linkPanel(int index) {
    if (_inventory.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('لا توجد مواد في المخزون.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax)),
      );
    }
    final cfg = _fieldLinks[index];
    final selectedId = int.tryParse('${cfg['inventory_id'] ?? ''}');
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ربط بمادة المخزون (استهلاك تلقائي)',
              style: TextStyle(
                  color: AppColors.textMuted, fontSize: 11.spMax)),
          const SizedBox(height: 6),
          DropdownButtonFormField<int?>(
            initialValue: selectedId,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'المادة', isDense: true),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('— بدون ربط —')),
              for (final inv in _inventory)
                DropdownMenuItem<int?>(
                  value: int.tryParse('${inv['id']}'),
                  child: Text('${inv['name']}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() {
              if (v == null) {
                _fieldLinks[index] = {'kind': 'link', 'unit': 'mL'};
              } else {
                final inv = _inventory.firstWhere((e) => '${e['id']}' == '$v');
                _fieldLinks[index] = {
                  'kind': 'link',
                  'inventory_id': v,
                  'inventory_name': '${inv['name']}',
                  'unit': '${inv['unit'] ?? 'mL'}',
                };
              }
            }),
          ),
          if (_kindOf(index) == 'link' &&
              (int.tryParse('${_fieldLinks[index]['inventory_id'] ?? 0}') ??
                      0) >
                  0) ...[
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: '${_fieldLinks[index]['unit'] ?? 'mL'}',
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'وحدة الاستهلاك', isDense: true),
              items: [
                for (final u in inventoryUnits)
                  DropdownMenuItem<String>(value: u, child: Text(u)),
              ],
              onChanged: (u) => setState(() {
                _fieldLinks[index] = {..._fieldLinks[index]}..['unit'] = u;
              }),
            ),
            if (unitDimOf('${_fieldLinks[index]['unit'] ?? 'mL'}') !=
                unitDimOf('${_inventory
                    .firstWhere((e) => '${e['id']}' ==
                        '${_fieldLinks[index]['inventory_id']}')
                    ['unit'] ?? ''}')) ...[
              const SizedBox(height: 4),
              Text(
                'تنبيه: وحدة الاستهلاك لا تطابق وحدة المادة، الكمية قد تُستهلك بقيمة رقمية مباشرة.',
                style: TextStyle(
                    color: AppColors.warning, fontSize: 11.spMax),
              ),
            ],
          ],
        ],
      ),
    );
  }

  TextEditingController _valueCtrl(int index) {
    final cfg = _fieldLinks[index];
    var c = cfg['valueCtrl'] as TextEditingController?;
    if (c == null) {
      final v = cfg['fixed_value'];
      c = TextEditingController(text: v == null ? '' : '$v');
      cfg['valueCtrl'] = c;
    }
    return c;
  }

  Widget _valuePanel(int index) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('قيمة ثابتة تستخدم في المعادلة',
              style: TextStyle(
                  color: AppColors.textMuted, fontSize: 11.spMax)),
          const SizedBox(height: 6),
          TextField(
            controller: _valueCtrl(index),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (t) {
              _fieldLinks[index]['fixed_value'] = safeFormulaFloat(t);
            },
            decoration: const InputDecoration(
                labelText: 'قيمة ثابتة', isDense: true),
          ),
        ],
      ),
    );
  }

  TextEditingController _listAddCtrl(int index) {
    final cfg = _fieldLinks[index];
    var c = cfg['listAddCtrl'] as TextEditingController?;
    if (c == null) {
      c = TextEditingController();
      cfg['listAddCtrl'] = c;
    }
    return c;
  }

  void _addListValue(int index) {
    final c = _listAddCtrl(index);
    final v = c.text.trim();
    if (v.isEmpty) return;
    setState(() {
      (_fieldLinks[index]['list_values'] as List<String>).add(v);
      c.clear();
    });
  }

  Widget _listPanel(int index) {
    final values = (_fieldLinks[index]['list_values'] as List<String>?) ?? [];
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('قيم متعددة — يختار المستخدم قيمة لكل اختبار',
              style: TextStyle(
                  color: AppColors.textMuted, fontSize: 11.spMax)),
          if (values.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < values.length; i++)
                  InputChip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(Icons.tag, size: 14.r),
                    label: Text(values[i],
                        style: TextStyle(fontSize: 12.spMax)),
                    onDeleted: () => setState(() => values.removeAt(i)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _listAddCtrl(index),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      labelText: 'قيمة...', isDense: true),
                ),
              ),
              const SizedBox(width: 6),
              AppButton(
                small: true,
                label: 'إضافة',
                icon: Icon(Icons.add, size: 14.r),
                onPressed: () => _addListValue(index),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _consumptionCard() {
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.surfaceSoft, AppColors.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.science_outlined,
                  size: 16.r, color: AppColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  AppText.t('المواد المستهلكة تلقائياً', 'Auto-consumed chemicals'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.spMax,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_consumedItems.isEmpty)
            Text(
              AppText.t('لا توجد مواد مستهلكة بعد', 'No consumed chemicals yet'),
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            )
          else
            for (final item in _consumedItems) _itemEditor(item),
          const SizedBox(height: 4),
          _addItemRow(),
        ],
      ),
    );
  }

  Widget _itemEditor(Map<String, dynamic> item) {
    final ctrl = item['qtyCtrl'] as TextEditingController;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.biotech, size: 14.r, color: AppColors.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${item['inventory_name'] ?? ''}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5.spMax,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 84,
            child: TextField(
              controller: ctrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(fontSize: 12.5.spMax),
              decoration: const InputDecoration(
                labelText: 'الكمية',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: DropdownButtonFormField<String>(
              initialValue: '${item['unit'] ?? 'g'}',
              isExpanded: true,
              isDense: true,
              decoration: const InputDecoration(isDense: true),
              style: TextStyle(fontSize: 12.spMax),
              items: [
                for (final u in inventoryUnits)
                  DropdownMenuItem<String>(value: u, child: Text(u)),
              ],
              onChanged: (u) {
                if (u != null) setState(() => item['unit'] = u);
              },
            ),
          ),
          IconButton(
            tooltip: AppText.t('حذف المادة', 'Remove chemical'),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() {
              _consumedItems.remove(item);
              ctrl.dispose();
            }),
            icon: Icon(Icons.close, size: 16.r, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _addItemRow() {
    if (_inventory.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ActionChip(
        avatar: Icon(Icons.add, size: 14.r),
        label: Text(AppText.t('إضافة مادة مستهلكة', 'Add consumed chemical'),
            style: TextStyle(fontSize: 12.spMax)),
        onPressed: _pickInventoryItem,
      ),
    );
  }

  Future<void> _pickInventoryItem() async {
    if (_inventory.isEmpty) return;
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(AppText.t('اختر مادة مستهلكة', 'Pick consumed chemical')),
        children: [
          for (final inv in _inventory)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(inv),
              child: Row(
                children: [
                  Icon(Icons.science_outlined,
                      size: 16.r, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${inv['name']} (${inv['unit'] ?? ''})',
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final id = int.tryParse('${selected['id']}') ?? 0;
    if (_consumedItems.any((e) => '${e['inventory_id']}' == '$id')) return;
    setState(() {
      _consumedItems.add({
        'inventory_id': id,
        'inventory_name': '${selected['name'] ?? ''}',
        'unit': '${selected['unit'] ?? 'g'}',
        'qtyCtrl': TextEditingController(text: '1'),
      });
    });
  }

  String _fmtNum(Object? v) {
    final d = safeFormulaFloat(v);
    if (d == null) return '0';
    return d == d.roundToDouble() ? d.toInt().toString() : '$d';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.analysis == null ? 'إضافة تحليل' : 'تعديل تحليل'),
      content: SizedBox(
        width: 720.w,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                enabled: widget.analysis == null,
                decoration: const InputDecoration(labelText: 'الاسم', isDense: true),
              ),
              TextField(
                controller: _unit,
                decoration: const InputDecoration(labelText: 'الوحدة', isDense: true),
              ),
              TextField(
                controller: _description,
                maxLines: 2,
                decoration:
                    const InputDecoration(labelText: 'الوصف', isDense: true),
              ),
              Text(
                'الحقول الديناميكية (البارامترات)',
                style:
                    TextStyle(fontWeight: FontWeight.w600, fontSize: 13.spMax),
              ),
              const SizedBox(height: 4),
              Text(
                'لكل حقل حدد كيف تُملأ قيمته: مرتبط بمادة من المخزون (تُستهلك تلقائياً)، أو قيمة ثابتة تدخل في المعادلة، أو قائمة قيم يختار منها المستخدم.',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 11.spMax),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _fieldControllers.length; i++) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSoft,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.borderMuted),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(Icons.tune, size: 16.r,
                              color: AppColors.textMuted),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: _fieldControllers[i],
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                labelText: 'اسم الحقل ${i + 1}',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          _fieldSummaryChip(i),
                          IconButton(
                            tooltip: 'حذف الحقل',
                            visualDensity: VisualDensity.compact,
                            onPressed: _fieldControllers.length > 1
                                ? () => _removeField(i)
                                : null,
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _kindChips(i),
                      ),
                      if (_kindOf(i) == 'link') ...[
                        if (_linkPicker == i)
                          _linkPanel(i)
                        else
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _linkSummary(i),
                          ),
                      ] else if (_kindOf(i) == 'value')
                        _valuePanel(i)
                      else if (_kindOf(i) == 'list')
                        _listPanel(i),
                    ],
                  ),
                ),
                if (i < _fieldControllers.length - 1)
                  const SizedBox(height: 8),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newFieldController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'أضف حقلاً...',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AppButton(
                    small: true,
                    label: 'إضافة',
                    icon: Icon(Icons.add, size: 16.r),
                    onPressed: _addField,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _formula,
                maxLines: 2,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontFamily: 'monospace'),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'المعادلة',
                  hintText: '(V1 - V2) * C * 1.4007 * F / m',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (_formulaTokens.isNotEmpty)
                    PopupMenuButton<String>(
                      tooltip: 'إدراج حقل / مادة / ثابت',
                      onSelected: _insertFormulaToken,
                      itemBuilder: (context) => [
                        for (final t in _formulaTokens)
                          PopupMenuItem<String>(
                            value: t.value,
                            child: Text(
                              t.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      child: const Chip(
                        avatar: Icon(Icons.add, size: 18),
                        label: Text('إدراج'),
                      ),
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final op in _formulaOps)
                          ActionChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(op,
                                style:
                                    const TextStyle(fontFamily: 'monospace')),
                            onPressed: () => _insertFormulaToken(op),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!_formulaStatus.empty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _formulaStatus.error != null
                      ? Text(
                          _formulaStatus.error!,
                          style: TextStyle(
                              color: AppColors.danger, fontSize: 12.spMax),
                        )
                      : Text(
                          _formulaStatus.unresolved.isEmpty
                              ? 'معادلة صالحة بدون متغيرات.'
                              : 'المتغيرات المطلوبة: '
                                  '${_formulaStatus.unresolved.join(', ')}',
                          style: TextStyle(
                              color: AppColors.textMuted, fontSize: 12.spMax),
                        ),
                ),
              _consumptionCard(),
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