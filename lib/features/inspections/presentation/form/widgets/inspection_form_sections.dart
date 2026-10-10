import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_format.dart';
import '../../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_autocomplete.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_date_field.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_history_autocomplete.dart';
import '../../../../../design_system/widgets/app_required_toggle.dart';
import '../../../../lab/core/formula_engine.dart';
import '../../cubit/inspection_form_cubit.dart';

/// Parsed chemical reference range shown in the results grid.
class ChemCell {
  final String minText;
  final String maxText;
  final num? minNumeric;
  final num? maxNumeric;
  final num? exact;
  final String unit;
  const ChemCell({
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
ChemCell _chemCell(Object? value) {
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
  return ChemCell(
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

bool _chemOut(TextEditingController ctrl, ChemCell cell) {
  if (cell.exact != null) {
    final v = double.tryParse(ctrl.text.trim());
    if (v == null) return false;
    return v != cell.exact;
  }
  return isOutOfRange(ctrl.text, cell.minNumeric, cell.maxNumeric);
}

String _chemPlaceholder(ChemCell cell) {
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

/// One titled card in the inspection form.
class FormSectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const FormSectionCard({super.key, required this.title, required this.children});
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

/// The four inspection-form sections as composable widgets.
///
/// Pure view over the screen state's controllers: the desktop shell stacks
/// all four (verbatim pre-split pixels), the mobile wizard shows one per
/// step. Cubit-derived data (materials, decision, references) is watched
/// from context, so both chromes stay in sync for free.
class InspectionFormSections {
  /// Product (batch) mode: formula/batch replace supplier/vehicle and the
  /// catalog list holds products.
  final bool isProduct;
  final TextEditingController date;
  final TextEditingController expiry;
  final TextEditingController supplier;
  final TextEditingController truck;
  final TextEditingController formula;
  final TextEditingController batch;
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

  const InspectionFormSections({
    this.isProduct = false,
    required this.date,
    required this.expiry,
    required this.supplier,
    required this.truck,
    required this.formula,
    required this.batch,
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
  });

  bool get hasResults => physical.isNotEmpty || chemical.isNotEmpty;

  Widget basicCard(BuildContext context) {
    final state = context.watch<InspectionFormCubit>().state;
    return FormSectionCard(
      title: AppText.t('البيانات الأساسية', 'Basic data'),
      children: [
        _materialPicker(state.materials, state.materialId),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: AppDateField(
                label: AppText.t('تاريخ الفحص', 'Date (YYYY-MM-DD)'),
                controller: date,
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppDateField(
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
            if (isProduct) ...[
              Expanded(
                child: AppField(
                  label: AppText.t('رقم الفورمولا', 'Formula no.'),
                  controller: formula,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: AppField(
                  label: AppText.t('رقم التشغيلة', 'Batch no.'),
                  controller: batch,
                ),
              ),
            ] else ...[
              Expanded(
                child: AppHistoryAutocomplete(
                  label: AppText.t('المورد', 'Supplier'),
                  controller: supplier,
                  options: state.supplierOptions,
                  hint: AppText.t(
                    'اكتب للبحث في موردي الخامة…',
                    'Type to search this material\u2019s suppliers…',
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: AppField(
                  label: AppText.t('رقم الشاحنة', 'Truck no.'),
                  controller: truck,
                ),
              ),
            ],
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
              child: AppHistoryAutocomplete(
                label: AppText.t('آخذ العينة', 'Sample taker'),
                controller: sampleTaker,
                options: state.sampleTakerOptions,
                hint: AppText.t(
                  'اكتب للبحث في سجل الفنيين…',
                  'Type to search the technicians log…',
                ),
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
    );
  }

  Widget physicalCard(BuildContext context) {
    if (physical.isEmpty) return const SizedBox.shrink();
    final state = context.watch<InspectionFormCubit>().state;
    return FormSectionCard(
      title: AppText.t('النتائج الفيزيائية', 'Physical results'),
      children: [
        _scrollableGrid(
          _physicalGrid(physical, state.physicalReference),
        ),
      ],
    );
  }

  Widget chemicalCard(BuildContext context) {
    if (chemical.isEmpty) return const SizedBox.shrink();
    final state = context.watch<InspectionFormCubit>().state;
    return FormSectionCard(
      title: AppText.t('النتائج الكيميائية', 'Chemical results'),
      children: [
        _scrollableGrid(
          _chemicalGrid(chemical, state.chemicalReference),
        ),
      ],
    );
  }

  /// Add-sample action. Shown once, after the results cards — never
  /// twice. Hidden when there are no result grids to add a column to.
  Widget addSampleButton(BuildContext context) {
    if (!hasResults) return const SizedBox.shrink();
    return Center(
      child: AppButton(
        small: true,
        style: AppButtonStyle.secondary,
        label: AppText.t('إضافة عينة جديدة', 'Add New Sample'),
        icon: Icon(Icons.add, size: 18.r),
        onPressed: sampleCount >= 3 ? null : onAddSample,
      ),
    );
  }

  Widget decisionCard(BuildContext context) {
    final state = context.watch<InspectionFormCubit>().state;
    return FormSectionCard(
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
          isProduct
              ? AppText.t('اسم المنتج', 'Product Name')
              : AppText.t('اسم الخامة', 'Material Name'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: AppAutocomplete<int>(
                options: [for (final m in materials) (m['id'] as num).toInt()],
                selected: selectedId,
                displayString: (id) {
                  final m = _materialById(materials, id);
                  return m == null
                      ? ''
                      : '${m['material_name']} (${m['material_code']})';
                },
                filter: (id, query) {
                  final m = _materialById(materials, id);
                  if (m == null) return false;
                  return '${m['material_name']}'
                          .toLowerCase()
                          .contains(query) ||
                      '${m['material_code']}'
                          .toLowerCase()
                          .contains(query);
                },
                onSelected: onSelectMaterial,
                controller: materialController,
                focusNode: materialFocus,
                hint: AppText.t(
                  'اكتب للبحث أو اختر من القائمة…',
                  'Type to search or pick…',
                ),
                prefixIcon: isProduct
                    ? Icons.factory_outlined
                    : Icons.inventory_2_outlined,
                emptyLabel: isProduct
                    ? AppText.t(
                        'لا يوجد منتج مطابق',
                        'No matching product',
                      )
                    : AppText.t(
                        'لا توجد خامة مطابقة',
                        'No matching material',
                      ),
                dropdownLabel:
                    AppText.t('عرض القائمة', 'Show the list'),
                optionBuilder: (context, id, onSelected) =>
                    _materialOption(materials, id, onSelected),
              ),
            ),
            if (selected) ...[
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                tooltip: isProduct
                    ? AppText.t('تغيير المنتج', 'Change product')
                    : AppText.t('تغيير الخامة', 'Change material'),
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
        // Below this the side-by-side parameter grid is narrower than a single
        // readable cell, so it scrolls horizontally instead of squeezing.
        const minWidth = AppBreakpoints.medium + 60;
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
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              param,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13.spMax,
                              ),
                            ),
                            if (isReferenceRequired(refs[param]))
                              const RequiredBadge(),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${refs[param] == null ? '' : referenceValueText(refs[param])}',
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
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          param,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.spMax,
                          ),
                        ),
                        if (isReferenceRequired(refs[param]))
                          const RequiredBadge(),
                      ],
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

  Widget _chemicalInput(ChemCell cell, TextEditingController ctrl) {
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
                padding: const EdgeInsetsDirectional.only(start: 6, top: 2),
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
