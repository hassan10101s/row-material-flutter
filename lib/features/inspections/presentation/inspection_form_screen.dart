import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_format.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../design_system/widgets/app_field.dart';
import '../../../design_system/widgets/app_top_app_bar.dart';
import '../../../di/service_locator.dart';
import '../../lab/core/formula_engine.dart';
import '../data/inspection_repo.dart';
import 'cubit/inspection_form_cubit.dart';
import 'cubit/inspection_form_state.dart';

/// Parsed chemical reference range shown in the results grid.
class _ChemCell {
  final String minText;
  final String maxText;
  final num? minNumeric;
  final num? maxNumeric;
  final num? exact;
  final String unit;
  const _ChemCell({
    required this.minText,
    required this.maxText,
    this.minNumeric,
    this.maxNumeric,
    this.exact,
    this.unit = '',
  });
}

num? _numOf(Object? value) {
  if (value == null) return null;
  return double.tryParse('$value');
}

String _refDisplay(Object? value) {
  final u = unwrapReferenceValue(value);
  if (u == null) return '';
  if (u is Map) return jsonDumps(u);
  return '$u'.trim();
}

/// Port of `parseDisplayRange` + unit extraction (useRangeValidator.js).
_ChemCell _chemCell(Object? value) {
  final display = _refDisplay(value);
  final unit = referenceUnitText(value);
  num? minN;
  num? maxN;
  num? exact;
  String minT = '-';
  String maxT = '-';
  dynamic decoded;
  try {
    decoded = jsonDecode(display);
  } catch (_) {}
  if (decoded is Map) {
    final m = decoded['min'];
    final x = decoded['max'];
    final mn = _numOf(m);
    final xn = _numOf(x);
    if (mn != null) {
      minN = mn;
      minT = '$m';
    } else if (m != null) {
      minT = '$m';
    }
    if (xn != null) {
      maxN = xn;
      maxT = '$x';
    } else if (x != null) {
      maxT = '$x';
    }
  } else {
    final t = display
        .toLowerCase()
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll(':', '-')
        .replaceAll(',', '.');
    final maxM = RegExp(
      r'(?:<=|≤|less than|max)\s*(-?\d+(?:\.\d+)?)',
    ).firstMatch(t);
    final minM = RegExp(
      r'(?:>=|≥|more than|min)\s*(-?\d+(?:\.\d+)?)',
    ).firstMatch(t);
    if (maxM != null) {
      maxN = double.parse(maxM.group(1)!);
      maxT = maxM.group(1)!;
    } else if (minM != null) {
      minN = double.parse(minM.group(1)!);
      minT = minM.group(1)!;
    } else {
      final r = parseNumericRange(display);
      minN = r['min_value'] as num?;
      maxN = r['max_value'] as num?;
      minT = '${r['min_text'] ?? '-'}';
      maxT = '${r['max_text'] ?? '-'}';
      final t2 = display.toLowerCase();
      if (minN != null &&
          maxN == null &&
          !t2.contains('min') &&
          !t2.contains('max')) {
        exact = minN;
      }
    }
  }
  return _ChemCell(
    minText: minT,
    maxText: maxT,
    minNumeric: minN,
    maxNumeric: maxN,
    exact: exact,
    unit: unit,
  );
}

String _unitSuffix(String raw, String numericText) {
  final idx = raw.indexOf(numericText);
  if (idx == -1) return '';
  final after = raw.substring(idx + numericText.length);
  final m = RegExp(
    r'^\s*(%|ppm|ppb|°C|°F|mg|g|kg|ml|L|cm|mm|m)\b',
    caseSensitive: false,
  ).firstMatch(after);
  return m == null ? '' : m.group(1)!;
}

/// Port of `extractPhysicalSetValue` (fill button fills the reference value).
String _extractPhysicalSetValue(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  final c = _chemCell(t);
  if (c.maxText != '-' && c.maxNumeric != null) {
    return c.maxText + _unitSuffix(t, c.maxText);
  }
  if (c.minText != '-' && c.minNumeric != null) {
    return c.minText + _unitSuffix(t, c.minText);
  }
  if (t.contains('|') || t.contains('،') || t.contains(',')) {
    final parts = t
        .split(RegExp(r'[|،,]+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isNotEmpty) return parts.first;
  }
  return t;
}

/// Port of `expandPhysicalQuickCode` (blur normalization).
String _expandPhysicalQuickCode(String raw) {
  const aliases = {
    'ok': 'Ok',
    'pass': 'Pass',
    'good': 'Good',
    'no': 'No',
    'fail': 'Fail',
  };
  return aliases[raw.trim().toLowerCase()] ?? raw.trim();
}

/// Port of `normalizeNumericInputValue` (chemical inputs).
String _sanitizeNumeric(String raw) => raw
    .replaceAll(RegExp(r'[^0-9.]'), '')
    .replaceAllMapped(RegExp(r'(\..*)\.'), (m) => m.group(1)!);

/// Port of `getPhysicalSuggestions` + standard quick keywords.
List<String> _physicalSuggestions(String requirement) {
  final result = <String>[];
  final seen = <String>{};
  void add(String s) {
    final c = s.trim();
    if (c.isNotEmpty && seen.add(c.toLowerCase())) result.add(c);
  }

  for (final p in requirement.split(RegExp(r'[|،,\/]+'))) {
    add(p);
    final clean = _extractPhysicalSetValue(p);
    if (clean.isNotEmpty) add(clean);
  }
  for (final k in [
    'Normal',
    'Good',
    'Acceptable',
    'Very Good',
    'OK',
    'Abnormal',
    'Not Good',
    'Pale',
    'No',
  ]) {
    add(k);
  }
  return result;
}

/// Port of `isPhysicalNumeric`.
bool _isPhysicalNumeric(String name, String requirement) {
  final p = name.toLowerCase();
  final r = requirement.toLowerCase();
  return p.contains('density') ||
      p.contains('كثافة') ||
      r.contains('max') ||
      r.contains('min') ||
      RegExp(r'\d').hasMatch(r);
}

bool _chemOut(TextEditingController ctrl, _ChemCell cell) {
  if (cell.exact != null) {
    final v = double.tryParse(ctrl.text.trim());
    if (v == null) return false;
    return v != cell.exact;
  }
  return isOutOfRange(ctrl.text, cell.minNumeric, cell.maxNumeric);
}

String _chemPlaceholder(_ChemCell cell) {
  final min = cell.minNumeric;
  final max = cell.maxNumeric;
  if (min != null && max != null) {
    if (min == max) return '= ${cell.minText}';
    return '${cell.minText} - ${cell.maxText}';
  }
  if (min != null) return 'min ${cell.minText}';
  if (max != null) return 'max ${cell.maxText}';
  return 'Result';
}

InputDecoration _inputDec(bool out, {required String hint}) {
  return InputDecoration(
    isDense: true,
    hintText: hint,
    filled: true,
    fillColor: out
        ? AppColors.danger.withValues(alpha: 0.10)
        : AppColors.surface,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(
        color: out ? AppColors.danger : AppColors.border,
        width: out ? 1.4 : 1,
      ),
    ),
  );
}

String _addMonths(String iso, int months) {
  final d = DateTime.tryParse(iso) ?? DateTime.now();
  final m = (d.month - 1) + months;
  final year = d.year + (m ~/ 12);
  final month = (m % 12) + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  final day = d.day > lastDay ? lastDay : d.day;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${year.toString().padLeft(4, '0')}-${two(month)}-${two(day)}';
}

/// New-inspection form (port of Web InspectionsForm + decision editing).
class InspectionFormScreen extends StatefulWidget {
  final VoidCallback? onSaved;
  const InspectionFormScreen({super.key, this.onSaved});
  @override
  State<InspectionFormScreen> createState() => _InspectionFormScreenState();
}

class _InspectionFormScreenState extends State<InspectionFormScreen> {
  late final TextEditingController _date = TextEditingController(
    text: todayIso(),
  );
  final _expiry = TextEditingController();
  final _supplier = TextEditingController();
  final _truck = TextEditingController();
  final _qty = TextEditingController();
  final _sampleTaker = TextEditingController();
  final _entryCode = TextEditingController();
  final _decisionReason = TextEditingController();
  final _followUp = TextEditingController();
  final _rejectedQty = TextEditingController();
  final List<TextEditingController> _sampleNames = [
    TextEditingController(text: 'Result'),
  ];
  final Map<String, List<TextEditingController>> _physical = {};
  final Map<String, List<TextEditingController>> _chemical = {};
  final _materialController = TextEditingController();
  final _materialFocus = FocusNode();
  int get _sampleCount => _sampleNames.length;
  @override
  void dispose() {
    _materialController.dispose();
    _materialFocus.dispose();
    for (final c in [
      ..._sampleNames,
      _expiry,
      _supplier,
      _truck,
      _qty,
      _sampleTaker,
      _entryCode,
      _decisionReason,
      _followUp,
      _rejectedQty,
    ]) {
      c.dispose();
    }
    for (final list in _physical.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    for (final list in _chemical.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _selectMaterial(int id) async {
    final date = _date.text.trim().isEmpty ? todayIso() : _date.text.trim();
    await context.read<InspectionFormCubit>().selectMaterial(id, date: date);
    if (!mounted) return;
    final st = context.read<InspectionFormCubit>().state;
    if (st.materialId == id) {
      for (final m in st.materials) {
        if ((m['id'] as num).toInt() == id) {
          _materialController.text =
              '${m['material_name']} (${m['material_code']})';
          break;
        }
      }
    }
  }

  void _changeMaterial() {
    _materialController.clear();
    context.read<InspectionFormCubit>().clearMaterial();
    _materialFocus.requestFocus();
  }

  void _rebuildResults(
    Map<String, List<TextEditingController>> target,
    dynamic ref,
    String type,
  ) {
    for (final list in target.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    target.clear();
    final Map<String, dynamic> refMap = ref is Map
        ? Map<String, dynamic>.from(ref)
        : {};
    refMap.forEach((key, _) {
      if (key.toString().trim().isEmpty) return;
      target[key] = [
        for (var i = 0; i < _sampleCount; i++) TextEditingController(),
      ];
    });
  }

  void _addSample() {
    if (_sampleCount >= 3) {
      AppFeedback.error(
        context,
        AppText.t('الحد الأقصى 3 عينات', 'A maximum of 3 samples.'),
      );
      return;
    }
    setState(() {
      _sampleNames.add(TextEditingController());
      for (final map in [_physical, _chemical]) {
        for (final entry in map.entries) {
          entry.value.add(TextEditingController());
        }
      }
    });
  }

  void _removeSample(int index) {
    if (_sampleCount <= 1) return;
    setState(() {
      _sampleNames.removeAt(index).dispose();
      for (final map in [_physical, _chemical]) {
        for (final entry in map.entries) {
          if (index < entry.value.length) {
            entry.value.removeAt(index).dispose();
          }
        }
      }
    });
  }

  Map<String, dynamic> _collectResults(
    Map<String, List<TextEditingController>> source,
  ) {
    final out = <String, dynamic>{};
    source.forEach((param, controllers) {
      if (_sampleCount == 1) {
        out[param] = controllers.first.text;
      } else {
        out[param] = [for (final c in controllers) c.text];
      }
    });
    return out;
  }

  Future<void> _save() async {
    final state = context.read<InspectionFormCubit>().state;
    if (state.materialId == null) {
      AppFeedback.error(
        context,
        AppText.t('يجب اختيار المادة', 'Material selection is required.'),
      );
      return;
    }
    if (_supplier.text.trim().length < 3) {
      AppFeedback.error(
        context,
        AppText.t(
          'اسم المورد مطلوب (3 أحرف على الأقل)',
          'Supplier is required.',
        ),
      );
      return;
    }
    if (_sampleTaker.text.trim().length < 3) {
      AppFeedback.error(
        context,
        AppText.t(
          'اسم آخذ العينة مطلوب (3 أحرف على الأقل)',
          'Sample taker is required.',
        ),
      );
      return;
    }
    final user = getIt<AuthGate>().currentUser;
    if (user == null) {
      AppFeedback.error(context, AppText.t('انتهت الجلسة', 'Session expired.'));
      return;
    }
    final payload = <String, dynamic>{
      'material_id': state.materialId,
      'inspection_date': _date.text.trim(),
      'expiry_date': _expiry.text.trim(),
      'entry_code': _entryCode.text.trim(),
      'supplier': _supplier.text.trim(),
      'truck_number': _truck.text.trim(),
      'quantity': _qty.text.trim(),
      'sample_taken_by': _sampleTaker.text.trim(),
      'sample_names': [for (final c in _sampleNames) c.text],
      'physical_results': _collectResults(_physical),
      'chemical_results': _collectResults(_chemical),
      'decision_status': state.decision,
      'decision_reason': _decisionReason.text.trim(),
      'follow_up_note': _followUp.text.trim(),
      'rejected_quantity': _rejectedQty.text.trim(),
    };
    final ok = await context.read<InspectionFormCubit>().save(
      payload,
      UserContext(id: user.id, fullName: user.fullName, role: user.role),
    );
    if (!mounted) return;
    if (ok) {
      AppFeedback.success(
        context,
        AppText.t('تم حفظ الفحص', 'Inspection saved.'),
      );
      final onSaved = widget.onSaved;
      if (onSaved != null) {
        onSaved();
      } else {
        Navigator.of(context).pop(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<InspectionFormCubit, InspectionFormState>(
      listenWhen: (prev, curr) =>
          prev.refRevision != curr.refRevision ||
          prev.entryCode != curr.entryCode,
      listener: (context, state) {
        if (state.refRevision != 0) {
          _rebuildResults(_physical, state.physicalReference, 'physical');
          _rebuildResults(_chemical, state.chemicalReference, 'chemical');
        }
        if (_entryCode.text != state.entryCode && state.entryCode.isNotEmpty) {
          _entryCode.text = state.entryCode;
        }
      },
      child: _FormBody(
        date: _date,
        expiry: _expiry,
        supplier: _supplier,
        truck: _truck,
        qty: _qty,
        sampleTaker: _sampleTaker,
        entryCode: _entryCode,
        decisionReason: _decisionReason,
        followUp: _followUp,
        rejectedQty: _rejectedQty,
        sampleNames: _sampleNames,
        materialController: _materialController,
        materialFocus: _materialFocus,
        onChangeMaterial: _changeMaterial,
        physical: _physical,
        chemical: _chemical,
        sampleCount: _sampleCount,
        onSelectMaterial: _selectMaterial,
        onAddSample: _addSample,
        onRemoveSample: _removeSample,
        onRegenerateEntry: () async {
          if (context.read<InspectionFormCubit>().state.materialId == null) {
            return;
          }
          final date = _date.text.trim().isEmpty
              ? todayIso()
              : _date.text.trim();
          await context.read<InspectionFormCubit>().regenerateEntryCode(date);
        },
        onSave: _save,
      ),
    );
  }
}

class _FormBody extends StatelessWidget {
  final TextEditingController date;
  final TextEditingController expiry;
  final TextEditingController supplier;
  final TextEditingController truck;
  final TextEditingController qty;
  final TextEditingController sampleTaker;
  final TextEditingController entryCode;
  final TextEditingController decisionReason;
  final TextEditingController followUp;
  final TextEditingController rejectedQty;
  final List<TextEditingController> sampleNames;
  final TextEditingController materialController;
  final FocusNode materialFocus;
  final VoidCallback onChangeMaterial;
  final Map<String, List<TextEditingController>> physical;
  final Map<String, List<TextEditingController>> chemical;
  final int sampleCount;
  final ValueChanged<int> onSelectMaterial;
  final VoidCallback onAddSample;
  final ValueChanged<int> onRemoveSample;
  final VoidCallback onRegenerateEntry;
  final VoidCallback onSave;
  const _FormBody({
    required this.date,
    required this.expiry,
    required this.supplier,
    required this.truck,
    required this.qty,
    required this.sampleTaker,
    required this.entryCode,
    required this.decisionReason,
    required this.followUp,
    required this.rejectedQty,
    required this.sampleNames,
    required this.materialController,
    required this.materialFocus,
    required this.onChangeMaterial,
    required this.physical,
    required this.chemical,
    required this.sampleCount,
    required this.onSelectMaterial,
    required this.onAddSample,
    required this.onRemoveSample,
    required this.onRegenerateEntry,
    required this.onSave,
  });
  @override
  Widget build(BuildContext context) {
    final state = context.watch<InspectionFormCubit>().state;
    Widget body;
    if (state.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppSpacing.md),
            if (state.error != null) ...[
              Text(
                state.error!,
                style: TextStyle(color: AppColors.danger, fontSize: 13.spMax),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            _Card(
              title: AppText.t('البيانات الأساسية', 'Basic data'),
              children: [
                _materialPicker(state.materials, state.materialId),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: AppField(
                        label: AppText.t('تاريخ الفحص', 'Date (YYYY-MM-DD)'),
                        controller: date,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppField(
                            label: AppText.t(
                              'تاريخ الانتهاء',
                              'Expiry (YYYY-MM-DD)',
                            ),
                            controller: expiry,
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            children: [
                              for (final m in const [
                                (3, '3M'),
                                (6, '6M'),
                                (9, '9M'),
                              ])
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(44, 26),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    side: BorderSide(color: AppColors.border),
                                  ),
                                  onPressed: () => expiry.text = _addMonths(
                                    date.text.trim().isEmpty
                                        ? todayIso()
                                        : date.text.trim(),
                                    m.$1,
                                  ),
                                  child: Text(
                                    m.$2,
                                    style: TextStyle(
                                      fontSize: 12.spMax,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: AppField(
                        label: AppText.t('المورد', 'Supplier'),
                        controller: supplier,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: AppField(
                        label: AppText.t('رقم الشاحنة', 'Truck no.'),
                        controller: truck,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: AppField(
                        label: AppText.t('الكمية', 'Quantity'),
                        controller: qty,
                        keyboardType: TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: AppField(
                        label: AppText.t('آخذ العينة', 'Sample taker'),
                        controller: sampleTaker,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: AppField(
                              label: AppText.t('رقم القيد', 'Entry code'),
                              controller: entryCode,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          IconButton(
                            tooltip: AppText.t('إعادة توليد', 'Regenerate'),
                            onPressed: onRegenerateEntry,
                            icon: Icon(Icons.refresh, size: 20.r),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (physical.isNotEmpty)
              _Card(
                title: AppText.t('النتائج الفيزيائية', 'Physical results'),
                children: [
                  _scrollableGrid(
                    _physicalGrid(physical, state.physicalReference),
                  ),
                ],
              ),
            if (chemical.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _Card(
                title: AppText.t('النتائج الكيميائية', 'Chemical results'),
                children: [
                  _scrollableGrid(
                    _chemicalGrid(chemical, state.chemicalReference),
                  ),
                ],
              ),
            ],
            if (physical.isNotEmpty || chemical.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Center(
                child: AppButton(
                  small: true,
                  style: AppButtonStyle.secondary,
                  label: AppText.t('إضافة عينة جديدة', 'Add New Sample'),
                  icon: Icon(Icons.add, size: 18.r),
                  onPressed: sampleCount >= 3 ? null : onAddSample,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            _Card(
              title: AppText.t('قرار الجودة', 'Decision'),
              children: [
                DropdownButtonFormField<String>(
                  initialValue: state.decision,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: AppText.t('القرار', 'Decision'),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'APPROVED',
                      child: Text(AppText.t('قبول نهائي', 'Approved')),
                    ),
                    DropdownMenuItem(
                      value: 'CONDITIONAL_APPROVAL',
                      child: Text(AppText.t('قبول مشروط', 'Conditional')),
                    ),
                    DropdownMenuItem(
                      value: 'PARTIAL_REJECTION',
                      child: Text(AppText.t('رفض جزئي', 'Partial rejection')),
                    ),
                    DropdownMenuItem(
                      value: 'FULL_REJECTION',
                      child: Text(AppText.t('رفض كامل', 'Full rejection')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      context.read<InspectionFormCubit>().setDecision(value);
                    }
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                if (state.decision == 'CONDITIONAL_APPROVAL') ...[
                  AppField(
                    label: AppText.t('ملاحظة المتابعة', 'Follow-up note'),
                    controller: followUp,
                    maxLines: 3,
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (state.decision == 'PARTIAL_REJECTION') ...[
                  AppField(
                    label: AppText.t('الكمية المرفوضة', 'Rejected quantity'),
                    controller: rejectedQty,
                    keyboardType: TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (state.decision == 'FULL_REJECTION' ||
                    state.decision == 'PARTIAL_REJECTION') ...[
                  AppField(
                    label: AppText.t('سبب القرار', 'Decision reason'),
                    controller: decisionReason,
                    maxLines: 3,
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppButton(
                  label: AppStrings.save,
                  icon: Icon(Icons.check, size: 18.r),
                  loading: state.saving,
                  onPressed: state.saving ? null : onSave,
                ),
                AppButton(
                  style: AppButtonStyle.secondary,
                  label: AppStrings.cancel,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppTopAppBar(title: AppText.t('فحص جديد', 'New Inspection')),
      body: body,
    );
  }

  Widget _materialPicker(
    List<Map<String, dynamic>> materials,
    int? selectedId,
  ) {
    final selected = selectedId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppText.t('اسم الخامة', 'Material Name'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: RawAutocomplete<int>(
                textEditingController: materialController,
                focusNode: materialFocus,
                displayStringForOption: (id) {
                  final m = _materialById(materials, id);
                  return m == null
                      ? ''
                      : '${m['material_name']} (${m['material_code']})';
                },
                optionsBuilder: (value) {
                  if (selected) return const Iterable<int>.empty();
                  final q = value.text.trim().toLowerCase();
                  if (q.isEmpty) {
                    return materials.map((m) => (m['id'] as num).toInt());
                  }
                  return materials
                      .where(
                        (m) =>
                            '${m['material_name']}'.toLowerCase().contains(q) ||
                            '${m['material_code']}'.toLowerCase().contains(q),
                      )
                      .map((m) => (m['id'] as num).toInt());
                },
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) {
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        readOnly: selected,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: null,
                          hintText: AppText.t(
                            'اكتب للبحث أو اختر من القائمة…',
                            'Type to search or pick…',
                          ),
                          prefixIcon: Icon(
                            Icons.inventory_2_outlined,
                            size: 20.r,
                          ),
                          suffixIcon: InkWell(
                            onTap: selected
                                ? null
                                : () {
                                    materialFocus.requestFocus();
                                    materialController
                                        .selection = TextSelection.collapsed(
                                      offset: materialController.text.length,
                                    );
                                  },
                            child: Icon(
                              Icons.arrow_drop_down,
                              size: 24.r,
                              color: selected
                                  ? AppColors.textMuted
                                  : AppColors.primary,
                            ),
                          ),
                          filled: true,
                          fillColor: AppColors.surface,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12.w,
                            vertical: 10.h,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadii.sm),
                            borderSide: BorderSide(color: AppColors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadii.sm),
                            borderSide: BorderSide(
                              color: AppColors.primary,
                              width: 1.6,
                            ),
                          ),
                        ),
                      );
                    },
                optionsViewBuilder: (context, onSelected, options) {
                  final ids = options.toList();
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      clipBehavior: Clip.antiAlias,
                      color: AppColors.surface,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 260,
                          maxWidth: 420,
                        ),
                        child: ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          children: [
                            if (ids.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  AppText.t(
                                    'لا توجد خامة مطابقة',
                                    'No matching material',
                                  ),
                                  style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 13.spMax,
                                  ),
                                ),
                              ),
                            for (final id in ids)
                              _materialOption(materials, id, onSelected),
                          ],
                        ),
                      ),
                    ),
                  );
                },
                onSelected: (id) => onSelectMaterial(id),
              ),
            ),
            if (selected) ...[
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                tooltip: AppText.t('تغيير الخامة', 'Change material'),
                onPressed: onChangeMaterial,
                icon: Icon(
                  Icons.swap_horiz,
                  size: 20.r,
                  color: AppColors.primary,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Map<String, dynamic>? _materialById(
    List<Map<String, dynamic>> materials,
    int id,
  ) {
    for (final m in materials) {
      if ((m['id'] as num).toInt() == id) return m;
    }
    return null;
  }

  Widget _materialOption(
    List<Map<String, dynamic>> materials,
    int id,
    void Function(int) onSelected,
  ) {
    final m = _materialById(materials, id);
    if (m == null) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.science_outlined,
        size: 18.r,
        color: AppColors.primary,
      ),
      title: Text(
        '${m['material_name']}',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14.spMax, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${m['material_code']}',
        style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
      ),
      onTap: () => onSelected(id),
    );
  }

  Widget _scrollableGrid(Widget grid) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const minWidth = 780.0;
        final maxW = constraints.maxWidth;
        final width = (maxW.isFinite && maxW > minWidth) ? maxW : minWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: width, child: grid),
        );
      },
    );
  }

  Widget _physicalGrid(
    Map<String, List<TextEditingController>> source,
    Map<String, dynamic> refs,
  ) {
    return Column(
      children: [
        Row(
          children: [
            const Expanded(flex: 2, child: SizedBox()),
            for (var i = 0; i < sampleCount; i++) _sampleHeader(i),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final param in source.keys)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          param,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.spMax,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${refs[param] ?? ''}',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11.spMax,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        ),
                      ],
                    ),
                  ),
                ),
                for (var i = 0; i < sampleCount; i++)
                  Expanded(
                    flex: 3,
                    child: _physicalInput(
                      param,
                      source[param]![i],
                      '${refs[param] ?? ''}',
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _physicalInput(String name, TextEditingController ctrl, String req) {
    final suggestions = _physicalSuggestions(req);
    void normalize() {
      var v = _expandPhysicalQuickCode(ctrl.text);
      v = _isPhysicalNumeric(name, req) ? _sanitizeNumeric(v) : v;
      ctrl.text = v;
    }

    return ListenableBuilder(
      listenable: ctrl,
      builder: (_, _) {
        final out = isPhysicalOutOfRange(ctrl.text, req);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: TextField(
                  controller: ctrl,
                  onSubmitted: (_) => normalize(),
                  decoration: _inputDec(out, hint: 'Result'),
                ),
              ),
            ),
            if (suggestions.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: AppText.t('اقتراحات', 'Suggestions'),
                onSelected: (v) => ctrl.text = v,
                itemBuilder: (_) => [
                  for (final s in suggestions)
                    PopupMenuItem(value: s, child: Text(s)),
                ],
                icon: Icon(Icons.arrow_drop_down, size: 20.r),
              ),
            IconButton(
              tooltip: AppText.t('تعبئة القيمة المرجعية', 'Fill reference'),
              visualDensity: VisualDensity.compact,
              onPressed: () => ctrl.text = _extractPhysicalSetValue(req),
              icon: Icon(
                Icons.content_paste_outlined,
                size: 18.r,
                color: AppColors.primary,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _chemicalGrid(
    Map<String, List<TextEditingController>> source,
    Map<String, dynamic> refs,
  ) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                AppText.t('البارامتر', 'Parameter'),
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.spMax,
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Text(
                'Min',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.spMax,
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Text(
                'Max',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.spMax,
                ),
              ),
            ),
            for (var i = 0; i < sampleCount; i++) _sampleHeader(i),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final param in source.keys)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      param,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.spMax,
                      ),
                    ),
                  ),
                ),
                _boundCell(_chemCell(refs[param]).minText),
                _boundCell(_chemCell(refs[param]).maxText),
                for (var i = 0; i < sampleCount; i++)
                  Expanded(
                    flex: 3,
                    child: _chemicalInput(
                      _chemCell(refs[param]),
                      source[param]![i],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _boundCell(String text) {
    return Expanded(
      flex: 1,
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
      ),
    );
  }

  Widget _sampleHeader(int index) {
    if (sampleCount == 1) {
      return Expanded(
        flex: 3,
        child: Text(
          'Result',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
      );
    }
    return Expanded(
      flex: 3,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: sampleNames[index],
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.spMax, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                isDense: true,
                hintText: AppText.t('اسم العينة', 'Sample name'),
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  borderSide: BorderSide(color: AppColors.border),
                ),
              ),
            ),
          ),
          if (sampleCount > 1 && index > 0)
            IconButton(
              tooltip: AppText.t('حذف العينة', 'Remove sample'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              onPressed: () => onRemoveSample(index),
              icon: Icon(Icons.close, size: 18.r, color: AppColors.danger),
            ),
        ],
      ),
    );
  }

  Widget _chemicalInput(_ChemCell cell, TextEditingController ctrl) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (_, _) {
        final out = _chemOut(ctrl, cell);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: TextField(
                  controller: ctrl,
                  onChanged: (_) {},
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: _inputDec(out, hint: _chemPlaceholder(cell)),
                ),
              ),
            ),
            if (cell.unit.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 2),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSoft,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.borderMuted),
                  ),
                  child: Text(
                    cell.unit,
                    style: TextStyle(
                      fontSize: 12.spMax,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Card({required this.title, required this.children});
  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.sm),
            ...children,
          ],
        ),
      ),
    );
  }
}
