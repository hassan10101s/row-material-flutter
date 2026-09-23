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
import '../core/formula_engine.dart' show inventoryUnits, validateFormula;
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
  final List<Map<String, dynamic>?> _fieldLinks = [];
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
      _fieldLinks.add(links[f]);
    }
    _loadInventory();
  }

  Future<void> _loadInventory() async {
    try {
      final items = await _repo.listInventory();
      if (mounted) setState(() => _inventory = items);
    } catch (_) {}
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
    for (final i in widget.analysis?['items'] as List? ?? const []) {
      if (i is Map) {
        final n = '${i['inventory_name'] ?? ''}'.trim();
        if (n.isNotEmpty) tokens.add((label: '$n (مادة)', value: n));
      }
    }
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
    final links = <Map<String, dynamic>>[
      for (var i = 0; i < _fieldControllers.length; i++)
        if (_fieldLinks[i] != null &&
            _fieldLinks[i]!['inventory_id'] != null &&
            (_fieldLinks[i]!['inventory_id'] as num? ?? 0) > 0)
          {
            'dynamic_field': _fieldList[i],
            'inventory_id': _fieldLinks[i]!['inventory_id'],
            'unit': _fieldLinks[i]!['unit'] ?? 'mL',
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
          fieldChemicalLinks: links,
        );
      } else {
        await _repo.updateAnalysis(
          analysisId: (widget.analysis!['id'] as num).toInt(),
          unit: _unit.text,
          description: _description.text,
          dynamicFields: _fieldList,
          formula: _formula.text.trim(),
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
      _fieldLinks.add(null);
      _newFieldController.clear();
    });
  }

  void _removeField(int index) {
    setState(() {
      _fieldControllers[index].dispose();
      _fieldControllers.removeAt(index);
      _fieldLinks.removeAt(index);
      if (_linkPicker >= _fieldControllers.length) _linkPicker = -1;
    });
  }

  Widget _linkSummary(int index) {
    final link = _fieldLinks[index];
    if (link == null) {
      return ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.link, size: 14.r),
        label: Text('ربط', style: TextStyle(fontSize: 12.spMax)),
        onPressed: () => setState(() => _linkPicker = _linkPicker == index ? -1 : index),
      );
    }
    final name = '${link['inventory_name'] ?? ''}';
    final unit = '${link['unit'] ?? ''}';
    return InputChip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.link, size: 14.r),
      label: Text(name.isEmpty ? 'مرتبط' : '$name ${unit.isNotEmpty ? '($unit)' : ''}',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.spMax)),
      onPressed: () => setState(() => _linkPicker = _linkPicker == index ? -1 : index),
      onDeleted: () => setState(() {
        _fieldLinks[index] = null;
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
    final current = _fieldLinks[index];
    final selectedId = current == null ? null : int.tryParse('${current['inventory_id']}');
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
          Text('استهلاك تلقائي',
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
                _fieldLinks[index] = null;
              } else {
                final inv = _inventory.firstWhere((e) => '${e['id']}' == '$v');
                _fieldLinks[index] = {
                  'inventory_id': v,
                  'inventory_name': '${inv['name']}',
                  'unit': '${inv['unit'] ?? 'mL'}',
                };
              }
            }),
          ),
          if (_fieldLinks[index] != null) ...[
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: '${_fieldLinks[index]!['unit'] ?? 'mL'}',
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'وحدة الاستهلاك', isDense: true),
              items: [
                for (final u in inventoryUnits)
                  DropdownMenuItem<String>(value: u, child: Text(u)),
              ],
              onChanged: (u) => setState(() {
                _fieldLinks[index] = {..._fieldLinks[index]!}..['unit'] = u;
              }),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.analysis == null ? 'إضافة تحليل' : 'تعديل تحليل'),
      content: SizedBox(
        width: 460.w,
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
                'لكل حقل اسم ووحدة استهلاك، ويمكن ربطه بمادة من المخزون لتُستهلك تلقائياً بقيمة الخانة.',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 11.spMax),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _fieldControllers.length; i++) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _fieldControllers[i],
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'حقل ${i + 1}',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _linkSummary(i),
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
                if (_linkPicker == i) _linkPanel(i),
                if (i < _fieldControllers.length - 1)
                  const SizedBox(height: 6),
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