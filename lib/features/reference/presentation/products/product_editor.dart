import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../core/utils/app_format.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dropdown.dart';
import '../../../../design_system/widgets/app_required_toggle.dart';
import '../../../../di/service_locator.dart';
import '../../domain/parameter_type.dart';
import '../../domain/reference_repository.dart';
import '../cubit/products_cubit.dart';

/// How the editor arranges its fields (mirrors `MaterialEditorLayout`).
///
/// An explicit prop rather than a width or platform lookup: the shared editor
/// is handed the arrangement by the variant that owns the chrome.
enum ProductEditorLayout {
  /// Side-by-side fields, and one row per parameter. Needs ~880dp.
  desktop,

  /// Stacked fields, one field per line. Fits a 400dp grid.
  compact,
}

class _PhysicalParamRow {
  int? parameterId;
  bool required;
  final TextEditingController nameCtrl;
  final TextEditingController reqCtrl;
  _PhysicalParamRow({
    String name = '',
    String requirement = '',
    this.required = false,
  }) : nameCtrl = TextEditingController(text: name),
       reqCtrl = TextEditingController(text: requirement);
  void dispose() {
    nameCtrl.dispose();
    reqCtrl.dispose();
  }
}

class _ChemicalParamRow {
  int? parameterId;
  bool required;
  final TextEditingController nameCtrl;
  final TextEditingController minCtrl;
  final TextEditingController maxCtrl;
  final TextEditingController unitCtrl;
  _ChemicalParamRow({
    String name = '',
    String min = '',
    String max = '',
    String unit = '%',
    this.required = false,
  }) : nameCtrl = TextEditingController(text: name),
       minCtrl = TextEditingController(text: min),
       maxCtrl = TextEditingController(text: max),
       unitCtrl = TextEditingController(text: unit);
  void dispose() {
    nameCtrl.dispose();
    minCtrl.dispose();
    maxCtrl.dispose();
    unitCtrl.dispose();
  }
}

/// Shared product editor: name/category/description + physical and chemical
/// parameters with مطلوب flags — the exact twin of `MaterialEditor`.
///
/// Chrome-free (mirrors `MaterialEditor`): desktop wraps it in an 880px
/// [AppWindow], mobile in a full-screen route with a compact bottom bar.
class ProductEditor extends StatefulWidget {
  const ProductEditor({
    super.key,
    required this.productsCubit,
    this.product,
    this.layout = ProductEditorLayout.desktop,
    this.actions,
  });

  /// Injected rather than read from context: the editor is shown inside a
  /// dialog/route that is a sibling of the screen's providers.
  final ProductsCubit productsCubit;

  /// The product being created or updated, or null to create one. Carries
  /// `physical_reference` / `chemical_reference` maps (plus legacy
  /// `ranges` for products saved before the reference editor).
  final Map<String, dynamic>? product;

  final ProductEditorLayout layout;

  /// Builds the per-experience action row, handed this widget's [State].
  final Widget Function(BuildContext context, ProductEditorState state)?
  actions;

  @override
  State<ProductEditor> createState() => ProductEditorState();
}

class ProductEditorState extends State<ProductEditor> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.product?['name'] ?? ''}',
  );
  late final TextEditingController _category = TextEditingController(
    text: '${widget.product?['category'] ?? ''}',
  );
  late final TextEditingController _description = TextEditingController(
    text: '${widget.product?['description'] ?? ''}',
  );

  final _physical = <_PhysicalParamRow>[];
  final _chemical = <_ChemicalParamRow>[];
  List<Map<String, dynamic>> _parameters = [];

  bool _loading = true;
  bool _saving = false;
  String? _nameError;

  /// True on the phone layout, where fields stack instead of sitting side by
  /// side. Read from [ProductEditor.layout] rather than from the window.
  bool get _compact => widget.layout == ProductEditorLayout.compact;

  bool get saving => _saving;

  String get editorTitle => widget.product == null
      ? AppText.t('منتج جديد', 'New Product')
      : AppText.t('تعديل المنتج', 'Edit Product');

  /// Exposed for the action row the variant builds.
  Future<void> save() => _save();

  static const _rejectWords = [
    'abnormal',
    'غير طبيعي',
    'غير مطابق',
    'not good',
    'not-good',
    'notgood',
    'pale',
    'سيء',
  ];

  @override
  void initState() {
    super.initState();
    _seedRows();
    _loadParameters();
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _description.dispose();
    for (final r in _physical) {
      r.dispose();
    }
    for (final r in _chemical) {
      r.dispose();
    }
    super.dispose();
  }

  void _seedRows() {
    final product = widget.product;
    if (product == null) return;
    final physMap = product['physical_reference'] is Map
        ? Map<String, dynamic>.from(product['physical_reference'] as Map)
        : jsonLoads('${product['physical_reference_json'] ?? ''}');
    for (final e in physMap.entries) {
      _physical.add(
        _PhysicalParamRow(
          name: e.key,
          requirement: referenceValueText(e.value),
          required: isReferenceRequired(e.value),
        ),
      );
    }
    var chemMap = product['chemical_reference'] is Map
        ? Map<String, dynamic>.from(product['chemical_reference'] as Map)
        : jsonLoads('${product['chemical_reference_json'] ?? ''}');
    if (chemMap.isEmpty) {
      // Legacy product (ranges only): convert ranges into chemical rows.
      chemMap = {
        for (final r in (product['ranges'] as List? ?? []))
          if (r is Map &&
              '${r['analysis_name'] ?? ''}'.trim().isNotEmpty)
            '${r['analysis_name']}'.trim(): {
              'value': _legacyRangeText(r),
              'unit': '${r['unit'] ?? ''}',
              if (r['is_required'] == 1 || r['is_required'] == true)
                'required': true,
            },
      };
    }
    for (final e in chemMap.entries) {
      final parsed = _parseRangeText(referenceValueText(e.value));
      var unit = '';
      if (e.value is Map) unit = '${e.value['unit'] ?? ''}'.trim();
      _chemical.add(
        _ChemicalParamRow(
          name: e.key,
          min: parsed.min,
          max: parsed.max,
          unit: unit.isNotEmpty ? unit : '%',
          required: isReferenceRequired(e.value),
        ),
      );
    }
  }

  static String _legacyRangeText(Map r) {
    final lo = r['min_value'] == null ? '' : '${r['min_value']}'.trim();
    final hi = r['max_value'] == null ? '' : '${r['max_value']}'.trim();
    if (lo.isNotEmpty && hi.isNotEmpty) {
      if (lo == hi) return lo;
      return '$lo-$hi';
    }
    if (lo.isNotEmpty) return 'min $lo';
    if (hi.isNotEmpty) return 'max $hi';
    return '';
  }

  Future<void> _loadParameters() async {
    setState(() => _loading = true);
    try {
      final params =
          await getIt<ReferenceRepository>().listParameters();
      if (!mounted) return;
      setState(() {
        _parameters = params;
        _loading = false;
      });
      _matchRowsByName();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Binds rows loaded without a parameter id (legacy ranges) to reference
  /// parameters by name, so saving keeps working without re-picking.
  void _matchRowsByName() {
    var changed = false;
    for (final row in _physical) {
      if (row.parameterId != null) continue;
      final match = _physicalParameters
          .where(
            (p) =>
                '${p['parameter_name']}'.trim().toLowerCase() ==
                row.nameCtrl.text.trim().toLowerCase(),
          )
          .firstOrNull;
      if (match != null) {
        row.parameterId = int.tryParse('${match['id']}');
        changed = true;
      }
    }
    for (final row in _chemical) {
      if (row.parameterId != null) continue;
      final match = _chemicalParameters
          .where(
            (p) =>
                '${p['parameter_name']}'.trim().toLowerCase() ==
                row.nameCtrl.text.trim().toLowerCase(),
          )
          .firstOrNull;
      if (match != null) {
        row.parameterId = int.tryParse('${match['id']}');
        if ('${match['unit'] ?? ''}'.trim().isNotEmpty) {
          row.unitCtrl.text = '${match['unit']}';
        }
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  ({String min, String max}) _parseRangeText(String text) {
    final t = text.trim();
    if (t.isEmpty) return (min: '', max: '');
    final dash = RegExp(r'^([\d.]+)\s*-\s*([\d.]+)$').firstMatch(t);
    if (dash != null) return (min: dash.group(1)!, max: dash.group(2)!);
    final mn = RegExp(r'^min\s*([\d.]+)', caseSensitive: false).firstMatch(t);
    if (mn != null) return (min: mn.group(1)!, max: '');
    final mx = RegExp(r'^max\s*([\d.]+)', caseSensitive: false).firstMatch(t);
    if (mx != null) return (min: '', max: mx.group(1)!);
    final single = RegExp(r'^[\d.]+$').firstMatch(t);
    if (single != null) return (min: t, max: t);
    return (min: '', max: '');
  }

  void _addPhysicalRow() => setState(() => _physical.add(_PhysicalParamRow()));

  void _removePhysicalRow(int index) {
    final row = _physical.removeAt(index);
    row.dispose();
    setState(() {});
  }

  void _addChemicalRow() => setState(() => _chemical.add(_ChemicalParamRow()));

  void _removeChemicalRow(int index) {
    final row = _chemical.removeAt(index);
    row.dispose();
    setState(() {});
  }

  Set<String> _usedPhysicalIds(int exclude) => {
    for (var i = 0; i < _physical.length; i++)
      if (i != exclude && _physical[i].parameterId != null)
        '${_physical[i].parameterId}',
  };

  Set<String> _usedChemicalIds(int exclude) => {
    for (var i = 0; i < _chemical.length; i++)
      if (i != exclude && _chemical[i].parameterId != null)
        '${_chemical[i].parameterId}',
  };

  /// Both vocabularies inherit the same two kinds from [ParameterType]:
  /// chemical rows can only bind chemical parameters and physical rows only
  /// physical ones — never the full mixed list.
  List<Map<String, dynamic>> get _physicalParameters => [
    for (final parameter in _parameters)
      if (ParameterType.physical.matches(parameter['parameter_type']))
        parameter,
  ];

  List<Map<String, dynamic>> get _chemicalParameters => [
    for (final parameter in _parameters)
      if (ParameterType.chemical.matches(parameter['parameter_type']))
        parameter,
  ];

  void _onPhysicalChange(_PhysicalParamRow row, int? id) {
    final parameter = _physicalParameters
        .where((item) => '${item['id']}' == '$id')
        .firstOrNull;
    setState(() {
      row.parameterId = id;
      if (parameter != null) {
        row.nameCtrl.text = '${parameter['parameter_name'] ?? ''}';
      } else {
        row.nameCtrl.clear();
      }
    });
  }

  void _onChemicalChange(_ChemicalParamRow row, int? id) {
    final parameter = _chemicalParameters
        .where((item) => '${item['id']}' == '$id')
        .firstOrNull;
    setState(() {
      row.parameterId = id;
      if (parameter == null) {
        row.nameCtrl.text = '';
        return;
      }
      row.nameCtrl.text = '${parameter['parameter_name'] ?? ''}';
      row.unitCtrl.text = '${parameter['unit'] ?? ''}';
    });
  }

  bool _isRejectWord(String word) {
    final w = word.trim().toLowerCase();
    if (_rejectWords.contains(w)) return true;
    if (w.contains(RegExp(r'\bno\b')) && !w.contains(RegExp(r'\bnormal\b'))) {
      return true;
    }
    return false;
  }

  List<String> _suggestionChips(String text) => [
    for (final s in text.split(RegExp(r'[,،]+')))
      if (s.trim().isNotEmpty) s.trim(),
  ];

  bool _validate() {
    final name = _name.text.trim();
    setState(() {
      _nameError = name.isEmpty
          ? AppText.t('الاسم مطلوب', 'Name is required.')
          : null;
    });
    return _nameError == null;
  }

  /// Resolves rows whose dropdown was never picked (legacy names) by name,
  /// so a legacy product stays savable without re-picking every row.
  void _resolveUnboundRows() {
    for (final p in _physical) {
      if (p.parameterId != null) continue;
      final name = p.nameCtrl.text.trim();
      if (name.isEmpty) continue;
      final match = _physicalParameters
          .where(
            (item) =>
                '${item['parameter_name']}'.trim().toLowerCase() ==
                name.toLowerCase(),
          )
          .firstOrNull;
      if (match == null) {
        throw ValidationError(
          AppText.t(
            'اختر بارامتراً ظاهرياً من المرجع لكل حقل',
            'Choose a reference physical parameter for every field.',
          ),
        );
      }
      p.parameterId = int.tryParse('${match['id']}');
      p.nameCtrl.text = '${match['parameter_name'] ?? ''}';
    }
    for (final c in _chemical) {
      if (c.parameterId != null) continue;
      final name = c.nameCtrl.text.trim();
      if (name.isEmpty) continue;
      final match = _chemicalParameters
          .where(
            (item) =>
                '${item['parameter_name']}'.trim().toLowerCase() ==
                name.toLowerCase(),
          )
          .firstOrNull;
      if (match == null) {
        throw ValidationError(
          AppText.t(
            'اختر بارامتراً كيميائياً من المرجع لكل حقل',
            'Choose a reference chemical parameter for every field.',
          ),
        );
      }
      c.parameterId = int.tryParse('${match['id']}');
      c.nameCtrl.text = '${match['parameter_name'] ?? ''}';
      if ('${match['unit'] ?? ''}'.trim().isNotEmpty) {
        c.unitCtrl.text = '${match['unit']}';
      }
    }
  }

  Future<void> _save() async {
    if (!_validate() || _loading) return;
    setState(() => _saving = true);
    try {
      _resolveUnboundRows();
      final physicalReference = <String, dynamic>{};
      final chemicalReference = <String, dynamic>{};
      for (final p in _physical) {
        final paramName = p.nameCtrl.text.trim();
        if (paramName.isEmpty) continue;
        final parameter = _physicalParameters
            .where((item) => '${item['id']}' == '${p.parameterId}')
            .firstOrNull;
        if (parameter == null) {
          throw ValidationError(
            AppText.t(
              'اختر بارامتراً ظاهرياً من المرجع لكل حقل',
              'Choose a reference physical parameter for every field.',
            ),
          );
        }
        physicalReference[paramName] = withReferenceRequired(
          p.reqCtrl.text.trim(),
          p.required,
          '${parameter['unit'] ?? ''}',
        );
      }
      for (final c in _chemical) {
        final paramName = c.nameCtrl.text.trim();
        if (paramName.isEmpty) continue;
        final parameter = _chemicalParameters
            .where((item) => '${item['id']}' == '${c.parameterId}')
            .firstOrNull;
        if (parameter == null) {
          throw ValidationError(
            AppText.t(
              'اختر بارامتراً كيميائياً من المرجع لكل حقل',
              'Choose a reference chemical parameter for every field.',
            ),
          );
        }
        c.unitCtrl.text = '${parameter['unit'] ?? ''}';
        final min = c.minCtrl.text.trim();
        final max = c.maxCtrl.text.trim();
        String range = '';
        if (min.isNotEmpty && max.isNotEmpty && min == max) {
          range = min;
        } else if (min.isNotEmpty && max.isNotEmpty) {
          range = '$min-$max';
        } else if (min.isNotEmpty) {
          range = 'min $min';
        } else if (max.isNotEmpty) {
          range = 'max $max';
        }
        chemicalReference[paramName] = withReferenceRequired(
          range,
          c.required,
          '${parameter['unit'] ?? ''}',
        );
      }
      final cubit = widget.productsCubit;
      if (widget.product == null) {
        await cubit.create(
          name: _name.text.trim(),
          category: _category.text.trim(),
          description: _description.text.trim(),
          physicalReference: physicalReference,
          chemicalReference: chemicalReference,
        );
      } else {
        await cubit.update((widget.product!['id'] as num).toInt(), {
          'name': _name.text.trim(),
          'category': _category.text.trim(),
          'description': _description.text.trim(),
          'physical_reference': physicalReference,
          'chemical_reference': chemicalReference,
        });
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

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions?.call(context, this);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: _compact ? 0 : AppSpacing.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _fields(),
                  ),
                ),
        ),
        ?actions,
      ],
    );
  }

  /// The form itself, in document order.
  List<Widget> _fields() => [
    TextField(
      controller: _name,
      onChanged: (_) => setState(() => _nameError = null),
      enabled: !_saving,
      decoration: InputDecoration(
        labelText: AppText.t('الاسم', 'Name'),
        isDense: true,
        errorText: _nameError,
        border: const OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: AppSpacing.md),
    Row(
      children: [
        Expanded(
          child: _labeled(
            AppText.t('النوع', 'Category'),
            TextField(
              controller: _category,
              enabled: !_saving,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: _labeled(
            AppText.t('الوصف', 'Description'),
            TextField(
              controller: _description,
              enabled: !_saving,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ),
      ],
    ),
    const SizedBox(height: AppSpacing.lg),
    _sectionTitle('الفحص الظاهري', 'Physical Parameters'),
    const SizedBox(height: AppSpacing.sm),
    AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          for (var i = 0; i < _physical.length; i++) _physicalRow(i),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              small: true,
              style: AppButtonStyle.secondary,
              icon: Icon(Icons.add, size: 16.r),
              label: AppText.t('إضافة بارامتر', 'Add Parameter'),
              onPressed: _saving ? null : _addPhysicalRow,
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: AppSpacing.lg),
    _sectionTitle('التحليل الكيميائي', 'Chemical Parameters'),
    const SizedBox(height: AppSpacing.sm),
    AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          for (var i = 0; i < _chemical.length; i++) _chemicalRow(i),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              small: true,
              style: AppButtonStyle.secondary,
              icon: Icon(Icons.add, size: 16.r),
              label: AppText.t(
                'إضافة من بارامترات المرجع',
                'Add from Reference Parameters',
              ),
              onPressed: _saving ? null : _addChemicalRow,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            AppText.t(
              'تُحمَّل البارامترات من المرجع (القاموس القياسي)؛ كل بارامتر يُمثِّل اسماً متوارثاً وله حدود خاصة بهذا المنتج.',
              'Parameters are loaded from the reference (canonical dictionary); each parameter is an inherited name with this product\'s own limits.',
            ),
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
        ],
      ),
    ),
    const SizedBox(height: AppSpacing.lg),
  ];

  Widget _labeled(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
      ),
      const SizedBox(height: AppSpacing.xs),
      child,
    ],
  );

  Widget _sectionTitle(String ar, String en) => Row(
    children: [
      Icon(Icons.science_outlined, size: 18.r, color: AppColors.primary),
      const SizedBox(width: AppSpacing.sm),
      Text(
        AppText.t(ar, en),
        style: TextStyle(fontSize: 16.spMax, fontWeight: FontWeight.w700),
      ),
    ],
  );

  Widget _requiredToggle(bool value, ValueChanged<bool> onChanged) {
    return AppRequiredToggle(
      value: value,
      enabled: !_saving,
      onChanged: onChanged,
    );
  }

  Widget _physicalRow(int index) {
    final row = _physical[index];
    final used = _usedPhysicalIds(index);
    // Bare dropdown — each branch below wraps it in exactly one Expanded.
    final name = AppDropdown<int?>(
      value: row.parameterId,
      hintText: AppText.t(
        'اختر بارامتراً ظاهرياً…',
        'Choose a physical parameter…',
      ),
      items: [
        for (final parameter in _physicalParameters)
          AppDropdownItem<int?>(
            value: int.tryParse('${parameter['id']}'),
            enabled: !used.contains('${parameter['id']}'),
            label: '${parameter['parameter_name']}',
          ),
      ],
      onChanged: _saving ? null : (id) => _onPhysicalChange(row, id),
    );
    // Bare column — the stacked layout lives in a scrolling dialog where
    // a vertical flex would crash; only the desktop row wraps it.
    final requirement = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: row.reqCtrl,
          enabled: !_saving,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            hintText: AppText.t('مثال: عادي', 'e.g. Normal'),
            border: const OutlineInputBorder(),
          ),
        ),
        if (_suggestionChips(row.reqCtrl.text).isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final chip in _suggestionChips(row.reqCtrl.text))
                _requirementChip(chip),
            ],
          ),
        ],
      ],
    );
    final remove = IconButton(
      tooltip: AppStrings.delete,
      visualDensity: VisualDensity.compact,
      onPressed: _saving ? null : () => _removePhysicalRow(index),
      icon: Icon(
        Icons.remove_circle_outline,
        size: 18.r,
        color: AppColors.danger,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: _compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: name),
                    remove,
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                requirement,
                _requiredToggle(
                  row.required,
                  (v) => setState(() => row.required = v),
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: name),
                const SizedBox(width: AppSpacing.sm),
                Expanded(flex: 3, child: requirement),
                _requiredToggle(
                  row.required,
                  (v) => setState(() => row.required = v),
                ),
                remove,
              ],
            ),
    );
  }

  Widget _requirementChip(String word) {
    final reject = _isRejectWord(word);
    final color = reject ? AppColors.danger : AppColors.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        word,
        style: TextStyle(color: color, fontSize: 12.spMax),
      ),
    );
  }

  Widget _chemicalRow(int index) {
    final row = _chemical[index];
    final used = _usedChemicalIds(index);
    final enabled = row.parameterId != null && !_saving;
    // A dangling `parameterId` (parameter deleted/retyped after the bounds
    // were saved) used to crash the whole editor on open
    // (`There should be exactly one item with [DropdownButton]'s value`).
    // [AppDropdown] shows it as a disabled "deleted" row instead, and the
    // save path below turns it into the friendly choose-a-parameter message.
    final dropdown = AppDropdown<int?>(
      value: row.parameterId,
      hintText: AppText.t('اختر بارامتراً…', 'Choose a parameter…'),
      items: [
        for (final p in _chemicalParameters)
          AppDropdownItem<int?>(
            value: int.tryParse('${p['id']}'),
            enabled: !used.contains('${p['id']}'),
            label: '${p['parameter_name']}',
          ),
      ],
      onChanged: _saving
          ? null
          : (v) {
              row.parameterId = v;
              _onChemicalChange(row, v);
            },
    );
    final min = TextField(
      controller: row.minCtrl,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        isDense: true,
        labelText: AppText.t('الحد الأدنى', 'Min'),
        border: const OutlineInputBorder(),
      ),
    );
    final max = TextField(
      controller: row.maxCtrl,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        isDense: true,
        labelText: AppText.t('الحد الأقصى', 'Max'),
        border: const OutlineInputBorder(),
      ),
    );
    final unit = TextField(
      controller: row.unitCtrl,
      enabled: false,
      decoration: InputDecoration(
        isDense: true,
        labelText: AppText.t('الوحدة الموروثة', 'Inherited unit'),
        border: const OutlineInputBorder(),
      ),
    );
    final remove = IconButton(
      tooltip: AppStrings.delete,
      visualDensity: VisualDensity.compact,
      onPressed: _saving ? null : () => _removeChemicalRow(index),
      icon: Icon(
        Icons.remove_circle_outline,
        size: 18.r,
        color: AppColors.danger,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: _compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                dropdown,
                const SizedBox(height: AppSpacing.sm),
                // min and max stay paired: they are read as one range, and
                // splitting them across two lines makes the pairing unclear.
                Row(
                  children: [
                    Expanded(child: min),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: max),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(child: unit),
                    remove,
                  ],
                ),
                _requiredToggle(
                  row.required,
                  (v) => setState(() => row.required = v),
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: dropdown),
                const SizedBox(width: AppSpacing.sm),
                SizedBox(width: 90.w, child: min),
                const SizedBox(width: AppSpacing.sm),
                SizedBox(width: 90.w, child: max),
                const SizedBox(width: AppSpacing.sm),
                SizedBox(width: 110.w, child: unit),
                _requiredToggle(
                  row.required,
                  (v) => setState(() => row.required = v),
                ),
                remove,
              ],
            ),
    );
  }
}

/// Cancel + Save, the chrome both experiences show.
class ProductEditorActions extends StatelessWidget {
  const ProductEditorActions({
    super.key,
    required this.state,
    this.compact = false,
  });

  final ProductEditorState state;

  /// Stacks the buttons and spans them, which is what a 400dp grid wants.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cancel = AppButton(
      style: AppButtonStyle.secondary,
      label: AppStrings.cancel,
      onPressed: state.saving ? null : () => Navigator.of(context).pop(false),
    );
    final save = AppButton(
      style: AppButtonStyle.primary,
      loading: state.saving,
      label: AppText.t('حفظ', 'Save'),
      onPressed: state.saving ? null : state.save,
    );

    return Padding(
      padding: EdgeInsets.all(_pad),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                save,
                const SizedBox(height: AppSpacing.sm),
                cancel,
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                cancel,
                const SizedBox(width: AppSpacing.md),
                save,
              ],
            ),
    );
  }

  double get _pad => compact ? AppSpacing.md : AppSpacing.lg;
}

/// Dialog/route title for the create/edit chrome, shared by both experiences.
String productEditorTitle(bool isNew) => isNew
    ? AppText.t('منتج جديد', 'New Product')
    : AppText.t('تعديل المنتج', 'Edit Product');
