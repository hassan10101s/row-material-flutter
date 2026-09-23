import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../di/service_locator.dart';
import '../../lab/data/lab_repo.dart';
import '../data/reference_repo.dart';

/// Full material editor — port of `MaterialsView` (web/src/42_materials_editor.js).
/// Creates or updates a reference material with physical and chemical
/// parameters. Self-contained: loads analyses/parameters/units itself and
/// saves via `materials_update/create` + `lab_material_ranges_save`.
class MaterialEditor extends StatefulWidget {
  final int? materialId;
  const MaterialEditor({super.key, this.materialId});

  @override
  State<MaterialEditor> createState() => _MaterialEditorState();
}

class _PhysicalParamRow {
  final TextEditingController nameCtrl;
  final TextEditingController reqCtrl;
  _PhysicalParamRow({String name = '', String requirement = ''})
      : nameCtrl = TextEditingController(text: name),
        reqCtrl = TextEditingController(text: requirement);
  void dispose() {
    nameCtrl.dispose();
    reqCtrl.dispose();
  }
}

class _ChemicalParamRow {
  int? analysisId;
  final TextEditingController nameCtrl;
  final TextEditingController minCtrl;
  final TextEditingController maxCtrl;
  final TextEditingController unitCtrl;
  _ChemicalParamRow({
    this.analysisId,
    String name = '',
    String min = '',
    String max = '',
    String unit = '%',
  })  : nameCtrl = TextEditingController(text: name),
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

class _MaterialEditorState extends State<MaterialEditor> {
  final _refRepo = getIt<ReferenceRepo>();
  final _labRepo = getIt<LabRepo>();

  late final TextEditingController _nameEn;
  late final TextEditingController _nameAr;
  late final TextEditingController _code;

  final _physical = <_PhysicalParamRow>[];
  final _chemical = <_ChemicalParamRow>[];
  List<Map<String, dynamic>> _analyses = [];
  List<Map<String, dynamic>> _parameters = [];
  List<Map<String, dynamic>> _units = [];

  bool _loading = true;
  bool _saving = false;
  String? _nameError;
  String? _codeError;

  static const _rejectWords = [
    'abnormal', 'غير طبيعي', 'غير مطابق', 'not good', 'not-good',
    'notgood', 'pale', 'سيء',
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
    return (en: parts.isNotEmpty ? parts[0] : '', ar: parts.length > 1 ? parts[1] : '');
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
      final analyses = await _labRepo.listAnalyses();
      final parameters = await _refRepo.listParameters();
      final units = await _refRepo.listUnits();
      var physicalRows = <_PhysicalParamRow>[];
      var chemicalRows = <_ChemicalParamRow>[];
      var initialName = '';
      var initialCode = '';

      if (widget.materialId != null) {
        final raw = await _refRepo.getMaterialRaw(widget.materialId!);
        if (raw == null) throw const NotFoundError('Material not found.');
        initialName = '${raw['material_name'] ?? ''}';
        initialCode = '${raw['material_code'] ?? ''}';
        final physMap = jsonLoads('${raw['physical_reference_json']}');
        physicalRows = [
          for (final e in physMap.entries)
            _PhysicalParamRow(
              name: e.key,
              requirement: referenceValueText(e.value),
            ),
        ];

        final chemRef = jsonLoads('${raw['chemical_reference_json']}');
        final rangeMap = <String, Map<String, dynamic>>{};
        final rangesAll = await _labRepo.listMaterialRanges();
        for (final r in rangesAll) {
          if ('${r['material_id']}' == '${widget.materialId}') {
            rangeMap['${r['analysis_id']}'] = r;
          }
        }
        final nameToAnalysis = {
          for (final a in analyses) '${a['name']}': a,
        };
        final chemRefUnit = <String, String>{};
        chemRef.forEach((name, refVal) {
          if (refVal is Map && '${refVal['unit']}'.trim().isNotEmpty) {
            chemRefUnit[name] = '${refVal['unit']}';
          }
        });

        final seenAnalysis = <String>{};
        rangeMap.forEach((aid, cur) {
          final a = analyses.where((x) => '${x['id']}' == aid).firstOrNull;
          if (a == null) return;
          seenAnalysis.add(aid);
          chemicalRows.add(_ChemicalParamRow(
            analysisId: int.tryParse(aid),
            name: '${a['name']}',
            min: cur['min_value'] != null ? '${cur['min_value']}' : '',
            max: cur['max_value'] != null ? '${cur['max_value']}' : '',
            unit: '${cur['unit'] ?? ''}'.trim().isNotEmpty
                ? '${cur['unit']}'
                : (chemRefUnit['${a['name']}'] ??
                    ('${a['unit'] ?? ''}'.trim().isNotEmpty ? '${a['unit']}' : '%')),
          ));
        });
        chemRef.forEach((name, refVal) {
          final nameStr = name;
          final a = nameToAnalysis[nameStr];
          final aid = a != null ? '${a['id']}' : null;
          if (aid != null && seenAnalysis.contains(aid)) return;
          Object? valueObj;
          String refUnit = '';
          if (refVal is Map) {
            valueObj = (refVal['value'] is Map)
                ? jsonDumps(refVal['value'])
                : refVal['value'];
            refUnit = '${refVal['unit'] ?? ''}'.trim();
          } else {
            valueObj = refVal;
          }
          final parsed = _parseRangeText('${valueObj ?? ''}');
          chemicalRows.add(_ChemicalParamRow(
            analysisId: aid != null ? int.tryParse(aid) : null,
            name: nameStr,
            min: parsed.min,
            max: parsed.max,
            unit: refUnit.isNotEmpty
                ? refUnit
                : '${a?['unit'] ?? ''}'.trim().isNotEmpty
                    ? '${a?['unit']}'
                    : '%',
          ));
        });
      } else {
        chemicalRows = [
          for (final a in analyses)
            _ChemicalParamRow(
              analysisId: int.tryParse('${a['id']}'),
              name: '${a['name']}',
              unit: '${a['unit'] ?? ''}'.trim().isNotEmpty ? '${a['unit']}' : '%',
            ),
        ];
      }

      final parts = _splitName(initialName);
      if (!mounted) return;
      setState(() {
        _analyses = analyses;
        _parameters = parameters;
        _units = units;
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
      AppFeedback.error(context, '$e');
      Navigator.of(context).pop(false);
    }
  }

  List<String> get _uniqueUnitSuggestions {
    final seen = <String>{};
    final out = <String>[];
    for (final u in _units) {
      final s = '${u['symbol'] ?? ''}'.trim();
      if (s.isNotEmpty && seen.add(s.toLowerCase())) out.add(s);
    }
    for (final p in _parameters) {
      final u = '${p['unit'] ?? ''}'.trim();
      if (u.isNotEmpty && seen.add(u.toLowerCase())) out.add(u);
    }
    return out;
  }

  void _addPhysicalRow() => setState(() => _physical.add(_PhysicalParamRow()));

  void _removePhysicalRow(int index) {
    final row = _physical.removeAt(index);
    row.dispose();
    setState(() {});
  }

  void _addChemicalRow() =>
      setState(() => _chemical.add(_ChemicalParamRow()));

  void _removeChemicalRow(int index) {
    final row = _chemical.removeAt(index);
    row.dispose();
    setState(() {});
  }

  Set<String> _usedAnalysisIds(int excludeIndex) => {
        for (var i = 0; i < _chemical.length; i++)
          if (i != excludeIndex && _chemical[i].analysisId != null)
            '${_chemical[i].analysisId}',
      };

  void _onAnalysisChange(_ChemicalParamRow row) {
    final a = row.analysisId == null
        ? null
        : _analyses
            .where((x) => '${x['id']}' == '${row.analysisId}')
            .firstOrNull;
    setState(() {
      if (a == null) {
        row.nameCtrl.text = '';
        return;
      }
      row.nameCtrl.text = '${a['name'] ?? ''}';
      row.unitCtrl.text = '${a['unit'] ?? ''}'.trim().isNotEmpty
          ? '${a['unit']}'
          : (row.unitCtrl.text.trim().isNotEmpty ? row.unitCtrl.text.trim() : '%');
    });
  }

  bool _isRejectWord(String word) {
    final w = word.trim().toLowerCase();
    if (_rejectWords.contains(w)) return true;
    if (w.contains(RegExp(r'\bno\b')) && !w.contains(RegExp(r'\bnormal\b'))) return true;
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
          ? AppText.t('الاسم مطلوب بالإنجليزية أو العربية', 'Name is required (EN or AR).')
          : null;
      _codeError =
          code.isEmpty ? AppText.t('كود الخامة مطلوب', 'Material code is required.') : null;
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
        if (name.isNotEmpty) physicalReference[name] = p.reqCtrl.text.trim();
      }
      for (final c in _chemical) {
        final name = c.nameCtrl.text.trim();
        if (name.isEmpty) continue;
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
        chemicalReference[name] = range;
        final unit = c.unitCtrl.text.trim();
        if (unit.isNotEmpty) units[name] = unit;
      }

      final combinedName = [
        _nameEn.text.trim(),
        _nameAr.text.trim(),
      ].where((s) => s.isNotEmpty).join(' | ');
      final code = _code.text.trim();

      final rangesPayload = <Map<String, dynamic>>[
        for (final c in _chemical)
          if (c.analysisId != null)
            {
              'analysis_id': c.analysisId,
              'min_value': c.minCtrl.text.trim(),
              'max_value': c.maxCtrl.text.trim(),
              'unit': c.unitCtrl.text.trim().isNotEmpty ? c.unitCtrl.text.trim() : '%',
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
        await _labRepo.saveMaterialRanges(id, rangesPayload);
      } else {
        await _refRepo.updateMaterial(
          widget.materialId!,
          materialName: combinedName,
          materialCode: code,
          physicalReference: physicalReference,
          chemicalReference: chemicalReference,
          units: units,
        );
        await _labRepo.saveMaterialRanges(widget.materialId!, rangesPayload);
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
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      backgroundColor: AppColors.surface,
      child: SizedBox(
        width: 880.w,
        height: 680.h,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
              child: Text(
                widget.materialId == null
                    ? AppText.t('مادة جديدة', 'New Material')
                    : AppText.t('تعديل المادة', 'Edit Material'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (_loading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _labeled(
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
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: _labeled(
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
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SizedBox(
                        width: 360.w,
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
                            for (var i = 0; i < _physical.length; i++)
                              _physicalRow(i),
                            const SizedBox(height: AppSpacing.sm),
                            Align(
                              alignment: Alignment.centerLeft,
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
                            for (var i = 0; i < _chemical.length; i++)
                              _chemicalRow(i),
                            const SizedBox(height: AppSpacing.sm),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: AppButton(
                                small: true,
                                style: AppButtonStyle.secondary,
                                icon: Icon(Icons.add, size: 16.r),
                                label: AppText.t('إضافة من جدول التحاليل', 'Add from Analyses'),
                                onPressed: _saving ? null : _addChemicalRow,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              AppText.t(
                                'تُحمّل البارامترات افتراضياً من جدول التحاليل؛ يمكنك أيضاً إضافة المزيد من القائمة أو حذف غير المطلوب.',
                                'Parameters are loaded from the analyses list by default; you can add more or remove unwanted ones.',
                              ),
                              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppButton(
                    style: AppButtonStyle.secondary,
                    label: AppStrings.cancel,
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  AppButton(
                    style: AppButtonStyle.primary,
                    loading: _saving,
                    label: AppText.t('حفظ', 'Save'),
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _labeled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax)),
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

  Widget _physicalRow(int index) {
    final row = _physical[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.nameCtrl,
              enabled: !_saving,
              decoration: InputDecoration(
                isDense: true,
                hintText: AppText.t('مثال: اللون', 'e.g. Color'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            flex: 3,
            child: Column(
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
            ),
          ),
          IconButton(
            tooltip: AppStrings.delete,
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : () => _removePhysicalRow(index),
            icon: Icon(Icons.remove_circle_outline, size: 18.r, color: AppColors.danger),
          ),
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
    final used = _usedAnalysisIds(index);
    final enabled = row.analysisId != null && !_saving;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<int?>(
              initialValue: row.analysisId,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              hint: Text(
                AppText.t('اختر تحليلاً…', 'Choose an analysis…'),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                softWrap: false,
              ),
              selectedItemBuilder: (_) => [
                Text(
                  AppText.t('اختر تحليلاً…', 'Choose an analysis…'),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false,
                ),
                for (final a in _analyses)
                  Text(
                    '${a['name']}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    softWrap: false,
                  ),
              ],
              items: [
                DropdownMenuItem<int?>(
                  value: null,
                  enabled: false,
                  child: Text(
                    AppText.t('اختر تحليلاً…', 'Choose an analysis…'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (final a in _analyses)
                  DropdownMenuItem<int?>(
                    value: int.tryParse('${a['id']}'),
                    enabled: !used.contains('${a['id']}'),
                    child: Text(
                      '${a['name']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (v) {
                      row.analysisId = v;
                      _onAnalysisChange(row);
                    },
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 90.w,
            child: TextField(
              controller: row.minCtrl,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                labelText: AppText.t('الحد الأدنى', 'Min'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 90.w,
            child: TextField(
              controller: row.maxCtrl,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                labelText: AppText.t('الحد الأقصى', 'Max'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 110.w,
            child: TextField(
              controller: row.unitCtrl,
              enabled: enabled,
              decoration: InputDecoration(
                isDense: true,
                labelText: AppText.t('الوحدة', 'Unit'),
                border: const OutlineInputBorder(),
                suffixIcon: PopupMenuButton<String>(
                  enabled: enabled,
                  tooltip: AppText.t('اقتراحات الوحدات', 'Unit suggestions'),
                  onSelected: (v) => setState(() => row.unitCtrl.text = v),
                  itemBuilder: (_) => [
                    for (final u in _uniqueUnitSuggestions)
                      PopupMenuItem(value: u, child: Text(u)),
                  ],
                  icon: Icon(Icons.arrow_drop_down, size: 18.r),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: AppStrings.delete,
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : () => _removeChemicalRow(index),
            icon: Icon(Icons.remove_circle_outline, size: 18.r, color: AppColors.danger),
          ),
        ],
      ),
    );
  }
}