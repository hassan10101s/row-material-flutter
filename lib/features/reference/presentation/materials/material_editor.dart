import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_errors.dart';
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
import '../../../lab/domain/lab_result_repository.dart';
import '../../domain/parameter_type.dart';
import '../../domain/reference_repository.dart';

/// How the editor arranges its fields.
///
/// An explicit prop rather than a width or platform lookup: the shared editor is
/// handed the arrangement by the variant that owns the chrome, so the choice is
/// visible at the call site instead of being re-derived inside the form.
enum MaterialEditorLayout {
  /// Side-by-side name fields, and one row per parameter. Needs ~880dp.
  desktop,

  /// Stacked fields, one field per line. Fits a 400dp grid.
  compact,
}

/// Full material editor — port of `MaterialsView` (web/src/42_materials_editor.js).
/// Creates or updates a reference material with physical and chemical
/// parameters. Loads analyses/parameters/units itself and saves via
/// `materials_update/create` + `lab_material_ranges_save`.
///
/// Chrome-free by design: the title and the action row are supplied by
/// [actions] and hosted by the variant, so the desktop dialog and the phone
/// route share one implementation of the form and the save path.
class MaterialEditor extends StatefulWidget {
  const MaterialEditor({
    super.key,
    required this.refRepo,
    required this.labConfig,
    this.materialId,
    this.layout = MaterialEditorLayout.desktop,
    this.actions,
  });

  /// The material being created or updated, or null to create one.
  final int? materialId;

  /// Injected rather than resolved from `getIt`: the editor is shown inside a
  /// dialog on desktop, which pushes onto the root navigator, so it is a sibling
  /// of the screen's providers rather than a descendant and cannot read them.
  final ReferenceRepository refRepo;

  /// Owns the per-material acceptance bounds.
  final LabConfigurationRepository labConfig;

  final MaterialEditorLayout layout;

  /// Builds the per-experience action row, handed this widget's [State].
  final Widget Function(BuildContext context, MaterialEditorState state)?
  actions;

  @override
  State<MaterialEditor> createState() => MaterialEditorState();
}

class _PhysicalParamRow {
  int? parameterId;
  bool required;
  final TextEditingController nameCtrl;
  final TextEditingController reqCtrl;
  _PhysicalParamRow({
    this.parameterId,
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
    this.parameterId,
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

typedef _NameParts = ({String en, String ar});

class MaterialEditorState extends State<MaterialEditor> {
  late final TextEditingController _nameEn;
  late final TextEditingController _nameAr;
  late final TextEditingController _code;

  final _physical = <_PhysicalParamRow>[];
  final _chemical = <_ChemicalParamRow>[];
  List<Map<String, dynamic>> _parameters = [];

  bool _loading = true;
  bool _saving = false;
  String? _nameError;
  String? _codeError;

  /// True on the phone layout, where fields stack instead of sitting side by
  /// side. Read from [MaterialEditor.layout] rather than from the window.
  bool get _compact => widget.layout == MaterialEditorLayout.compact;

  bool get saving => _saving;

  ReferenceRepository get _refRepo => widget.refRepo;

  LabConfigurationRepository get _labConfig => widget.labConfig;

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
    _nameEn = TextEditingController();
    _nameAr = TextEditingController();
    _code = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _nameEn.dispose();
    _nameAr.dispose();
    _code.dispose();
    for (final r in _physical) {
      r.dispose();
    }
    for (final r in _chemical) {
      r.dispose();
    }
    super.dispose();
  }

  _NameParts _splitName(Object? raw) {
    final parts = '${raw ?? ''}'.split(RegExp(r'\s*\|\s*'));
    return (
      en: parts.isNotEmpty ? parts[0] : '',
      ar: parts.length > 1 ? parts[1] : '',
    );
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

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final parameters = await _refRepo.listParameters();
      var physicalRows = <_PhysicalParamRow>[];
      var chemicalRows = <_ChemicalParamRow>[];
      var initialName = '';
      var initialCode = '';

      if (widget.materialId != null) {
        final raw = await _refRepo.getMaterialRaw(widget.materialId!);
        if (raw == null) throw NotFoundError(AppErrors.materialNotFound);
        initialName = '${raw['material_name'] ?? ''}';
        initialCode = '${raw['material_code'] ?? ''}';
        final physMap = jsonLoads('${raw['physical_reference_json']}');
        physicalRows = [
          for (final e in physMap.entries)
            _PhysicalParamRow(
              parameterId:
                  parameters
                          .where(
                            (p) =>
                                ParameterType.physical.matches(
                                  p['parameter_type'],
                                ) &&
                                '${p['parameter_name']}'.trim().toLowerCase() ==
                                    e.key.trim().toLowerCase(),
                          )
                          .firstOrNull?['id']
                      as int?,
              name: e.key,
              requirement: referenceValueText(e.value),
              required: isReferenceRequired(e.value),
            ),
        ];

        final chemRef = jsonLoads('${raw['chemical_reference_json']}');
        final matAnalyses = await _labConfig.getMaterialAnalyses(
          widget.materialId!,
        );
        final chemicalByName = <String, _ChemicalParamRow>{};
        for (final f
            in (matAnalyses['chemical']?['fields'] as List? ?? const [])) {
          final fm = Map<String, dynamic>.from(f as Map);
          final name = '${fm['parameter_name'] ?? ''}'.trim();
          if (name.isEmpty) continue;
          final unit = '${fm['unit'] ?? ''}';
          chemicalByName[name.toLowerCase()] = _ChemicalParamRow(
            parameterId: fm['parameter_id'] as int?,
            name: name,
            min: fm['min']?.toString() ?? '',
            max: fm['max']?.toString() ?? '',
            unit: unit,
            required: fm['is_required'] == 1 || fm['is_required'] == true,
          );
        }
        final seenChemical = <String>{};
        chemicalByName.forEach((key, c) => seenChemical.add(key));
        chemRef.forEach((name, refVal) {
          if (seenChemical.contains(name.trim().toLowerCase())) return;
          final nameStr = name;
          String refUnit = '';
          if (refVal is Map) {
            refUnit = '${refVal['unit'] ?? ''}'.trim();
          }
          final parsed = _parseRangeText(referenceValueText(refVal));
          chemicalByName[nameStr.trim().toLowerCase()] = _ChemicalParamRow(
            name: nameStr,
            min: parsed.min,
            max: parsed.max,
            unit: refUnit,
            required: isReferenceRequired(refVal),
          );
        });
        // Merge required flag from JSON when bounds row missed it.
        chemRef.forEach((name, refVal) {
          final row = chemicalByName[name.trim().toLowerCase()];
          if (row != null && isReferenceRequired(refVal)) row.required = true;
        });
        // Merge required flag for physical bounds fields too.
        final physAnalyses = matAnalyses['physical']?['fields'] as List? ?? const [];
        for (final f in physAnalyses) {
          final fm = Map<String, dynamic>.from(f as Map);
          if (fm['is_required'] != 1 && fm['is_required'] != true) continue;
          final key = '${fm['parameter_name'] ?? ''}'.trim().toLowerCase();
          for (final r in physicalRows) {
            if (r.nameCtrl.text.trim().toLowerCase() == key) r.required = true;
          }
        }
        chemicalRows = chemicalByName.values.toList();
      }

      final parts = _splitName(initialName);
      if (!mounted) return;
      setState(() {
        _parameters = parameters;
        _physical.addAll(physicalRows);
        _chemical.addAll(chemicalRows);
        _nameEn.text = parts.en;
        _nameAr.text = parts.ar;
        _code.text = initialCode;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.errorFrom(context, e);
      Navigator.of(context).pop(false);
    }
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

  Set<String> _usedParameterIds(int excludeIndex) => {
    for (var i = 0; i < _chemical.length; i++)
      if (i != excludeIndex && _chemical[i].parameterId != null)
        '${_chemical[i].parameterId}',
  };

  Set<String> _usedPhysicalParameterIds(int excludeIndex) => {
    for (var i = 0; i < _physical.length; i++)
      if (i != excludeIndex && _physical[i].parameterId != null)
        '${_physical[i].parameterId}',
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

  void _onPhysicalParameterChange(_PhysicalParamRow row, int? id) {
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

  void _onParameterChange(_ChemicalParamRow row) {
    final p = row.parameterId == null
        ? null
        : _chemicalParameters
              .where((x) => '${x['id']}' == '${row.parameterId}')
              .firstOrNull;
    setState(() {
      if (p == null) {
        row.nameCtrl.text = '';
        return;
      }
      row.nameCtrl.text = '${p['parameter_name'] ?? ''}';
      row.unitCtrl.text = '${p['unit'] ?? ''}';
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
    final nameEn = _nameEn.text.trim();
    final nameAr = _nameAr.text.trim();
    final code = _code.text.trim();
    setState(() {
      _nameError = (nameEn.isEmpty && nameAr.isEmpty)
          ? AppText.t(
              'الاسم مطلوب بالإنجليزية أو العربية',
              'Name is required (EN or AR).',
            )
          : null;
      _codeError = code.isEmpty
          ? AppText.t('كود الخامة مطلوب', 'Material code is required.')
          : null;
    });
    if (_nameError == null || _codeError == null) return true;
    return (_nameError == null) && (_codeError == null);
  }

  Future<void> _save() async {
    if (!_validate()) return;
    setState(() => _saving = true);
    try {
      final physicalReference = <String, dynamic>{};
      final chemicalReference = <String, dynamic>{};
      final units = <String, dynamic>{};

      for (final p in _physical) {
        final name = p.nameCtrl.text.trim();
        if (name.isNotEmpty) {
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
          physicalReference[name] = withReferenceRequired(
            p.reqCtrl.text.trim(),
            p.required,
            '${parameter['unit'] ?? ''}',
          );
        }
      }
      for (final c in _chemical) {
        final name = c.nameCtrl.text.trim();
        if (name.isEmpty) continue;
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
        chemicalReference[name] = withReferenceRequired(
          range,
          c.required,
          '${parameter['unit'] ?? ''}',
        );
        final unit = '${parameter['unit'] ?? ''}'.trim();
        units[name] = unit;
      }

      final combinedName = [
        _nameEn.text.trim(),
        _nameAr.text.trim(),
      ].where((s) => s.isNotEmpty).join(' | ');
      final code = _code.text.trim();

      final boundsPayload = <Map<String, dynamic>>[
        for (final p in _physical)
          if (p.nameCtrl.text.trim().isNotEmpty) ...[
            {
              'parameter_name': p.nameCtrl.text.trim(),
              'parameter_type': ParameterType.physical.value,
              'unit':
                  '${_physicalParameters.where((item) => '${item['id']}' == '${p.parameterId}').firstOrNull?['unit'] ?? ''}',
              'min_value': _parseRangeText(p.reqCtrl.text.trim()).min,
              'max_value': _parseRangeText(p.reqCtrl.text.trim()).max,
              'is_required': p.required,
            },
          ],
        for (final c in _chemical)
          if (c.nameCtrl.text.trim().isNotEmpty)
            {
              'parameter_name': c.nameCtrl.text.trim(),
              'parameter_type': ParameterType.chemical.value,
              'unit': c.unitCtrl.text.trim(),
              'min_value': c.minCtrl.text.trim(),
              'max_value': c.maxCtrl.text.trim(),
              'is_required': c.required,
            },
      ];

      if (widget.materialId == null) {
        final id = await _refRepo.createMaterial(
          materialName: combinedName,
          materialCode: code,
          physicalReference: physicalReference,
          chemicalReference: chemicalReference,
          units: units,
        );
        await _labConfig.saveMaterialBounds(id, boundsPayload);
      } else {
        await _refRepo.updateMaterial(
          widget.materialId!,
          materialName: combinedName,
          materialCode: code,
          physicalReference: physicalReference,
          chemicalReference: chemicalReference,
          units: units,
        );
        await _labConfig.saveMaterialBounds(widget.materialId!, boundsPayload);
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
    _nameFields(),
    const SizedBox(height: AppSpacing.md),
    SizedBox(
      width: _compact ? null : 360.w,
      child: _labeled(
        AppText.t('كود الخامة', 'Material Code'),
        TextField(
          controller: _code,
          onChanged: (_) => setState(() => _codeError = null),
          enabled: !_saving,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'e.g. APL',
            errorText: _codeError,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
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
              'تُحمَّل البارامترات من المرجع (القاموس القياسي)؛ كل بارامتر يُمثِّل اسماً متوارثاً وله حدود قبول ورفض خاصة بهذه الخامة.',
              'Parameters are loaded from the reference (canonical dictionary); each parameter is an inherited name with this material\'s own acceptance/rejection limits.',
            ),
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
        ],
      ),
    ),
    const SizedBox(height: AppSpacing.lg),
  ];

  /// English and Arabic name side by side on desktop, stacked on a phone —
  /// two 200dp fields across a 400dp grid leaves neither usable.
  Widget _nameFields() {
    final en = _labeled(
      AppText.t('الاسم بالإنجليزية', 'English Name'),
      TextField(
        controller: _nameEn,
        onChanged: (_) => setState(() => _nameError = null),
        enabled: !_saving,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'e.g. Apple Pomace',
          errorText: _nameError,
          border: const OutlineInputBorder(),
        ),
      ),
    );
    final ar = _labeled(
      AppText.t('الاسم بالعربية', 'Arabic Name'),
      TextField(
        controller: _nameAr,
        onChanged: (_) => setState(() => _nameError = null),
        enabled: !_saving,
        decoration: const InputDecoration(
          isDense: true,
          hintText: 'مثال: تفل تفاح',
          border: OutlineInputBorder(),
        ),
      ),
    );
    if (_compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          en,
          const SizedBox(height: AppSpacing.md),
          ar,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: en),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: ar),
      ],
    );
  }

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

  Widget _requiredToggle(bool value, ValueChanged<bool?> onChanged) {
    return AppRequiredToggle(
      value: value,
      enabled: !_saving,
      onChanged: (v) => onChanged(v),
    );
  }

  Widget _physicalRow(int index) {
    final row = _physical[index];
    final used = _usedPhysicalParameterIds(index);
    // NOTE: bare dropdown — each branch wraps it in exactly one Expanded.
    // An Expanded inside another Expanded crashes with competing
    // ParentDataWidgets.
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
      onChanged: _saving ? null : (id) => _onPhysicalParameterChange(row, id),
    );
    // NOTE: bare column — never Expanded here. The stacked layout lives
    // in a scrolling dialog (unbounded height) where a vertical flex
    // crashes; only the side-by-side desktop row wraps it in Expanded.
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
                  (v) => setState(() => row.required = v ?? false),
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
                  (v) => setState(() => row.required = v ?? false),
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
    final used = _usedParameterIds(index);
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
              _onParameterChange(row);
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
                  (v) => setState(() => row.required = v ?? false),
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
                  (v) => setState(() => row.required = v ?? false),
                ),
                remove,
              ],
            ),
    );
  }
}

/// Cancel + Save, the chrome both experiences show.
class MaterialEditorActions extends StatelessWidget {
  const MaterialEditorActions({
    super.key,
    required this.state,
    this.compact = false,
  });

  final MaterialEditorState state;

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
String materialEditorTitle(bool isNew) => isNew
    ? AppText.t('مادة جديدة', 'New Material')
    : AppText.t('تعديل المادة', 'Edit Material');
