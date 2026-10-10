import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_dropdown.dart';
import '../../../../design_system/widgets/app_unit_field.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../di/service_locator.dart';
import '../../core/formula_engine.dart'
    show
        categoryUnits,
        inventoryUnits,
        safeFormulaFloat,
        unitAllowedForCategory,
        unitDimOf,
        validateFormula;
import '../../domain/lab_local_repository.dart';
import '../../domain/lab_result_repository.dart';
import '../../../reference/domain/reference_repository.dart';

/// Shared analysis editor: all fields, formula, items and save path.
///
/// Chrome-free on purpose (mirrors `MaterialEditor`): the desktop variant
/// wraps this in an [AppWindow] dialog, the mobile variant in a full-screen
/// route with a 52h bottom bar. Behaviour can never diverge — only chrome.
class AnalysisEditor extends StatefulWidget {
  final Map<String, dynamic>? analysis;
  const AnalysisEditor({super.key, this.analysis});

  @override
  State<AnalysisEditor> createState() => AnalysisEditorState();
}

class AnalysisEditorState extends State<AnalysisEditor> {
  // The analysis definition replicates; the chemical stock it draws on does not,
  // so this dialog legitimately needs both contracts.
  final _repo = getIt<LabConfigurationRepository>();
  final _stock = getIt<LabLocalRepository>();
  final _reference = getIt<ReferenceRepository>();
  late final TextEditingController _name = TextEditingController(
    text: '${widget.analysis?['name'] ?? ''}',
  );
  late final TextEditingController _unit = TextEditingController(
    text: '${widget.analysis?['unit'] ?? '%'}',
  );
  late final TextEditingController _description = TextEditingController(
    text: '${widget.analysis?['description'] ?? ''}',
  );
  late final TextEditingController _formula = TextEditingController(
    text:
        '${widget.analysis?['formula'] is Map ? (widget.analysis?['formula'] as Map)['expression'] : ''}',
  );
  final _newFieldController = TextEditingController();
  final List<TextEditingController> _fieldControllers = [];
  final List<Map<String, dynamic>> _fieldLinks = [];
  final List<Map<String, dynamic>> _consumedItems = [];
  List<Map<String, dynamic>> _inventory = [];
  List<String> _unitSymbols = const [];
  List<Map<String, dynamic>> _parameters = [];
  int? _parameterId;
  Future<void>? _parameterLoad;
  int _linkPicker = -1;
  bool _saving = false;
  String? _parameterError;
  String? _nameError;

  /// True while the name/unit are inherited from a reference parameter.
  /// False means manual entry (used when the reference has no parameters
  /// yet, or after unlinking) — the name/unit fields unlock.
  bool get _linked => _parameterId != null;

  @override
  void initState() {
    super.initState();
    final fields = [
      for (final f
          in (widget.analysis?['dynamic_fields'] as List?) ??
              const ['Sample Name'])
        if ('$f'.trim().isNotEmpty) '$f'.trim(),
    ];
    final links = Map<String, Map<String, dynamic>>.fromEntries([
      for (final l
          in (widget.analysis?['field_chemical_links'] as List?) ??
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
        m['qtyCtrl'] = TextEditingController(
          text: _fmtNum(item['qty_per_sample']),
        );
        _consumedItems.add(m);
      }
    }
    _parameterId = int.tryParse('${widget.analysis?['parameter_id'] ?? ''}');
    _loadInventory();
    _parameterLoad = _loadReferenceParameters();
  }

  Future<void> _loadReferenceParameters() async {
    try {
      final parameters = await _reference.listParameters();
      if (!mounted) return;
      final linkedId = _parameterId;
      final linked = parameters.where((row) => '${row['id']}' == '$linkedId');
      final matchingName = parameters.where(
        (row) =>
            '${row['parameter_name']}'.trim().toLowerCase() ==
            _name.text.trim().toLowerCase(),
      );
      final parameter =
          linked.firstOrNull ??
          (linkedId == null ? matchingName.firstOrNull : null);
      setState(() {
        _parameters = parameters;
        if (parameter != null) {
          _parameterId = int.tryParse('${parameter['id']}');
          _name.text = '${parameter['parameter_name'] ?? ''}';
          _unit.text = '${parameter['unit'] ?? ''}';
        }
      });
    } catch (e) {
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  void _selectReferenceParameter(int? id) {
    final parameter = _parameters
        .where((row) => '${row['id']}' == '$id')
        .firstOrNull;
    setState(() {
      _parameterId = id;
      _parameterError = null;
      _nameError = null;
      if (parameter != null) {
        _name.text = '${parameter['parameter_name'] ?? ''}';
        _unit.text = '${parameter['unit'] ?? ''}';
      }
    });
  }

  /// Drops the reference link and keeps the current texts editable, so an
  /// analysis can be created (or kept) with a hand-typed name even when
  /// the reference holds no parameters at all.
  void _unlinkParameter() {
    setState(() {
      _parameterId = null;
      _parameterError = null;
    });
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
        for (final v
            in row['list_values'] is List
                ? row['list_values'] as List
                : const [])
          '$v',
      ];
    }
    return cfg;
  }

  Future<void> _loadInventory() async {
    try {
      final items = await _stock.listInventory();
      if (mounted) setState(() => _inventory = items);
    } catch (_) {}
    // Consume-unit pickers inherit from the `lab_units` registry.
    try {
      final symbols = await _stock.listUnitSymbols();
      if (mounted) setState(() => _unitSymbols = symbols);
    } catch (_) {}
  }

  /// Registry options for a consume-unit dropdown, narrowed to the linked
  /// inventory item's category (a liquid offers litres, a powder grams, a
  /// counted item pieces only). Legacy values outside the registry — or a
  /// legacy mismatched unit — stay selectable instead of crashing the
  /// dropdown; the repository rejects a mismatching unit on save.
  List<String> _consumeOptions(String current, [int? inventoryId]) {
    var options = _unitSymbols.isEmpty
        ? List<String>.from(inventoryUnits)
        : List<String>.from(_unitSymbols);
    if (inventoryId != null && inventoryId > 0) {
      final inv = _inventory
          .where((e) => '${e['id']}' == '$inventoryId')
          .firstOrNull;
      final allowed =
          categoryUnits['${inv?['category'] ?? ''}'.trim().toLowerCase()];
      if (allowed != null) {
        options = [
          for (final u in options)
            if (allowed.any((a) => a.toLowerCase() == u.toLowerCase())) u,
        ];
        for (final a in allowed) {
          if (!options.any((u) => u.toLowerCase() == a.toLowerCase())) {
            options.add(a);
          }
        }
      }
    }
    if (current.isNotEmpty && !options.contains(current)) {
      return [...options, current];
    }
    return options;
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

  static const List<String> _formulaOps = [
    '(',
    ')',
    '+',
    '-',
    '*',
    '/',
    '^',
    '%',
  ];

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
            v,
      ];
      return (error: null, unresolved: unresolved, empty: false);
    } on ValidationError catch (e) {
      return (error: e.message, unresolved: const [], empty: false);
    }
  }

  /// Runs validation + create/update and pops `true` on success.
  /// Called by both chromes (desktop dialog buttons, mobile bottom bar).
  Future<void> save() async {
    await _parameterLoad;
    if (!mounted) return;
    if (_parameterId == null) {
      // Manual mode (no reference parameters yet, or unlinked): the typed
      // name is required instead of a reference pick.
      if (_name.text.trim().isEmpty) {
        setState(
          () => _nameError = AppText.t(
            'اكتب اسم التحليل',
            'Type the analysis name.',
          ),
        );
        return;
      }
    } else if (!_parameters.any(
      (row) => '${row['id']}' == '$_parameterId',
    )) {
      setState(
        () => _parameterError = AppText.t(
          'اختر بارامتراً أساسياً من المرجع',
          'Choose a base parameter from Reference.',
        ),
      );
      return;
    }
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
          'inventory_id': int.tryParse('${item['inventory_id'] ?? 0}') ?? 0,
          'qty_per_sample':
              safeFormulaFloat(
                (item['qtyCtrl'] as TextEditingController).text,
              ) ??
              0,
          'unit': '${item['unit'] ?? 'g'}',
        },
    ];
    try {
      if (widget.analysis == null) {
        await _repo.createAnalysis(
          name: _name.text,
          unit: _unit.text,
          parameterId: _parameterId,
          description: _description.text,
          dynamicFields: _fieldList,
          formula: _formula.text.trim(),
          items: consumedItems,
          fieldChemicalLinks: links,
        );
      } else {
        final hadLink = '${widget.analysis?['parameter_id'] ?? ''}'.trim().isNotEmpty;
        await _repo.updateAnalysis(
          analysisId: (widget.analysis!['id'] as num).toInt(),
          name: _linked ? null : _name.text.trim(),
          unit: _unit.text,
          parameterId: _parameterId,
          // Unlinking a previously linked analysis clears the reference.
          clearParameter: !_linked && hadLink,
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
      if (mounted) AppFeedback.errorFrom(context, e);
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
          : _stateChip(
              Icons.view_list_outlined,
              'قائمة ($n)',
              AppColors.accent,
            );
    }
    if (kind == 'link') {
      final id =
          int.tryParse('${_fieldLinks[index]['inventory_id'] ?? 0}') ?? 0;
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
                fontSize: 11.spMax,
                color: color,
                fontWeight: FontWeight.w600,
              ),
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
        label: Text(
          AppText.t('ربط', 'Link'),
          style: TextStyle(fontSize: 12.spMax),
        ),
        onPressed: () =>
            setState(() => _linkPicker = _linkPicker == index ? -1 : index),
      );
    }
    final name = '${cfg['inventory_name'] ?? ''}';
    final unit = '${cfg['unit'] ?? ''}';
    return InputChip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.link, size: 14.r),
      label: Text(
        name.isEmpty
            ? AppText.t('مرتبط', 'Linked')
            : '$name ${unit.isNotEmpty ? '($unit)' : ''}',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.spMax),
      ),
      onPressed: () =>
          setState(() => _linkPicker = _linkPicker == index ? -1 : index),
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
        child: Text(
          'لا توجد مواد في المخزون.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
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
          Text(
            AppText.t(
              'ربط بمادة المخزون (استهلاك تلقائي)',
              'Link to stock item (auto consume)',
            ),
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.spMax),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<int?>(
            initialValue: selectedId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: AppText.t('المادة', 'Material'),
              isDense: true,
            ),
            items: [
              DropdownMenuItem<int?>(
                value: null,
                child: Text(AppText.t('— بدون ربط —', '— no link —')),
              ),
              for (final inv in _inventory)
                DropdownMenuItem<int?>(
                  value: int.tryParse('${inv['id']}'),
                  child: Text(
                    '${inv['name']}',
                    overflow: TextOverflow.ellipsis,
                  ),
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
            Builder(
              builder: (context) {
                final current = '${_fieldLinks[index]['unit'] ?? 'mL'}';
                final linkInvId =
                    int.tryParse('${_fieldLinks[index]['inventory_id'] ?? 0}') ??
                        0;
                return DropdownButtonFormField<String>(
                  initialValue: current.isEmpty ? null : current,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: AppText.t('وحدة الاستهلاك', 'Consume unit'),
                    isDense: true,
                  ),
                  items: [
                    for (final u in _consumeOptions(current, linkInvId))
                      DropdownMenuItem<String>(value: u, child: Text(u)),
                  ],
                  onChanged: (u) => setState(() {
                    _fieldLinks[index] = {..._fieldLinks[index]}..['unit'] = u;
                  }),
                );
              },
            ),
            if (unitDimOf('${_fieldLinks[index]['unit'] ?? 'mL'}') !=
                unitDimOf(
                  '${_inventory.firstWhere((e) => '${e['id']}' == '${_fieldLinks[index]['inventory_id']}')['unit'] ?? ''}',
                )) ...[
              const SizedBox(height: 4),
              Text(
                'تنبيه: وحدة الاستهلاك لا تطابق وحدة المادة، الكمية قد تُستهلك بقيمة رقمية مباشرة.',
                style: TextStyle(color: AppColors.warning, fontSize: 11.spMax),
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
          Text(
            AppText.t(
              'قيمة ثابتة تستخدم في المعادلة',
              'Fixed value used in the formula',
            ),
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.spMax),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _valueCtrl(index),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (t) {
              _fieldLinks[index]['fixed_value'] = safeFormulaFloat(t);
            },
            decoration: InputDecoration(
              labelText: AppText.t('قيمة ثابتة', 'Fixed value'),
              isDense: true,
            ),
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
          Text(
            AppText.t(
              'قيم متعددة — يختار المستخدم قيمة لكل اختبار',
              'Multiple values — user picks one per test',
            ),
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.spMax),
          ),
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
                    label: Text(
                      values[i],
                      style: TextStyle(fontSize: 12.spMax),
                    ),
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
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: AppText.t('قيمة...', 'Value...'),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              AppButton(
                small: true,
                label: AppText.t('إضافة', 'Add'),
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
              Icon(
                Icons.science_outlined,
                size: 16.r,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  AppText.t(
                    'المواد المستهلكة تلقائياً',
                    'Auto-consumed chemicals',
                  ),
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
              AppText.t(
                'لا توجد مواد مستهلكة بعد',
                'No consumed chemicals yet',
              ),
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

  /// Category of the inventory item behind a consumed row, for unit gating.
  String _itemCategory(Map<String, dynamic> item) {
    final id = int.tryParse('${item['inventory_id'] ?? 0}') ?? 0;
    for (final inv in _inventory) {
      if ('${inv['id']}' == '$id') return '${inv['category'] ?? ''}';
    }
    return '';
  }

  Widget _itemEditor(Map<String, dynamic> item) {
    final ctrl = item['qtyCtrl'] as TextEditingController;
    final itemId = int.tryParse('${item['inventory_id'] ?? 0}') ?? 0;
    final knownCategory = _itemCategory(item);
    final mismatched = knownCategory.isNotEmpty &&
        !unitAllowedForCategory('${item['unit'] ?? ''}', knownCategory);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.biotech, size: 14.r, color: AppColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${item['inventory_name'] ?? ''}',
                  maxLines: 1,
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
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: TextStyle(fontSize: 12.5.spMax),
                  decoration: InputDecoration(
                    labelText: AppText.t('الكمية', 'Qty'),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 76,
                child: Builder(
                  builder: (context) {
                    final current = '${item['unit'] ?? 'g'}';
                    return DropdownButtonFormField<String>(
                      initialValue: current.isEmpty ? null : current,
                      isExpanded: true,
                      isDense: true,
                      decoration: const InputDecoration(isDense: true),
                      style: TextStyle(fontSize: 12.spMax),
                      items: [
                        for (final u in _consumeOptions(current, itemId))
                          DropdownMenuItem<String>(value: u, child: Text(u)),
                      ],
                      onChanged: (u) {
                        if (u != null) setState(() => item['unit'] = u);
                      },
                    );
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
                icon: Icon(
                  Icons.close,
                  size: 16.r,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          if (mismatched)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                AppText.t(
                  'الوحدة لا تناسب نوع المادة — لن يُحفظ التحليل.',
                  'The unit does not fit the item type — the analysis will not save.',
                ),
                style: TextStyle(
                  color: AppColors.danger,
                  fontSize: 11.spMax,
                ),
              ),
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
        label: Text(
          AppText.t('إضافة مادة مستهلكة', 'Add consumed chemical'),
          style: TextStyle(fontSize: 12.spMax),
        ),
        onPressed: _pickInventoryItem,
      ),
    );
  }

  Future<void> _pickInventoryItem() async {
    if (_inventory.isEmpty) return;
    // Adaptive chrome: centred window on desktop, bottom sheet on phones.
    final selected = await showAppOverlay<Map<String, dynamic>>(
      context,
      title: AppText.t('اختر مادة مستهلكة', 'Pick consumed chemical'),
      icon: Icons.science_outlined,
      size: AppWindowSize.sm,
      builder: (context, close) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final inv in _inventory)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.science_outlined,
                size: 16.r,
                color: AppColors.accent,
              ),
              title: Text(
                '${inv['name']} (${inv['unit'] ?? ''})',
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => close(inv),
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

  bool get saving => _saving;

  /// Dialog/route title shared by both chromes.
  String get editorTitle =>
      widget.analysis == null ? 'إضافة تحليل' : 'تعديل تحليل';

  /// Form content without chrome: hosts wrap this in [AppWindow] (desktop)
  /// or a full-screen [Scaffold] (mobile) and drive [save] themselves.
  @override
  Widget build(BuildContext context) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppDropdown<int>(
            value: _parameterId,
            labelText: AppText.t('البارامتر المرجعي', 'Reference parameter'),
            hintText: _parameters.isEmpty
                ? AppText.t(
                    'لا توجد بارامترات — اكتب الاسم يدوياً',
                    'No parameters — type the name manually',
                  )
                : AppText.t(
                    'اختياري — أو اكتب الاسم يدوياً',
                    'Optional — or type the name manually',
                  ),
            errorText: _parameterError,
            items: [
              for (final parameter in _parameters)
                if (int.tryParse('${parameter['id']}') != null)
                  AppDropdownItem<int>(
                    value: int.parse('${parameter['id']}'),
                    label:
                        '${parameter['parameter_name']}'
                        ' (${parameter['unit'] ?? ''})',
                  ),
            ],
            onChanged: _selectReferenceParameter,
          ),
          if (_linked)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _saving ? null : _unlinkParameter,
                icon: Icon(Icons.edit_outlined, size: 16.r),
                label: Text(
                  AppText.t(
                    'إلغاء الربط والكتابة يدوياً',
                    'Unlink and type manually',
                  ),
                ),
              ),
            ),
          if (!_linked && _parameters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                AppText.t(
                  'وضع يدوي: الاسم والوحدة من كتابتك.',
                  'Manual mode: name and unit are yours to type.',
                ),
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.spMax,
                ),
              ),
            ),
          TextField(
            controller: _name,
            enabled: !_linked && !_saving,
            onChanged: (_) => setState(() => _nameError = null),
            decoration: InputDecoration(
              labelText: AppText.t('الاسم', 'Name'),
              hintText: _linked
                  ? null
                  : AppText.t('مثال: الرطوبة', 'e.g. Moisture'),
              errorText: _nameError,
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          if (_linked)
            TextField(
              controller: _unit,
              enabled: false,
              decoration: InputDecoration(
                labelText: AppText.t(
                  'الوحدة الموروثة من المرجع',
                  'Unit inherited from reference',
                ),
                isDense: true,
              ),
            )
          else
            AppUnitField(
              controller: _unit,
              symbols: _unitSymbols,
              enabled: !_saving,
            ),
          TextField(
            controller: _description,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: AppText.t('الوصف', 'Description'),
              isDense: true,
            ),
          ),
          Text(
            AppText.t(
              'الحقول الديناميكية (البارامترات)',
              'Dynamic fields (parameters)',
            ),
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.spMax),
          ),
          const SizedBox(height: 4),
          Text(
            AppText.t(
              'لكل حقل حدد كيف تُملأ قيمته: مرتبط بمادة من المخزون (تُستهلك تلقائياً)، أو قيمة ثابتة تدخل في المعادلة، أو قائمة قيم يختار منها المستخدم.',
              'For each field choose how its value is filled: linked to a stock item (auto consumed), a fixed value in the formula, or a list the user picks from.',
            ),
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.spMax),
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
                      Icon(Icons.tune, size: 16.r, color: AppColors.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _fieldControllers[i],
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: AppText.t(
                              'اسم الحقل ${i + 1}',
                              'Field name ${i + 1}',
                            ),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _fieldSummaryChip(i),
                      IconButton(
                        tooltip: AppText.t('حذف الحقل', 'Delete field'),
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
            if (i < _fieldControllers.length - 1) const SizedBox(height: 8),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newFieldController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: AppText.t('أضف حقلاً...', 'Add a field...'),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              AppButton(
                small: true,
                label: AppText.t('إضافة', 'Add'),
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
              labelText: AppText.t('المعادلة', 'Formula'),
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
                  tooltip: AppText.t(
                    'إدراج حقل / مادة / ثابت',
                    'Insert field / item / constant',
                  ),
                  onSelected: _insertFormulaToken,
                  itemBuilder: (context) => [
                    for (final t in _formulaTokens)
                      PopupMenuItem<String>(
                        value: t.value,
                        child: Text(t.label, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: Text(AppText.t('إدراج', 'Insert')),
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
                        label: Text(
                          op,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
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
                        color: AppColors.danger,
                        fontSize: 12.spMax,
                      ),
                    )
                  : Text(
                      _formulaStatus.unresolved.isEmpty
                          ? 'معادلة صالحة بدون متغيرات.'
                          : 'المتغيرات المطلوبة: '
                                '${_formulaStatus.unresolved.join(', ')}',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.spMax,
                      ),
                    ),
            ),
          _consumptionCard(),
        ],
    );
  }
}
