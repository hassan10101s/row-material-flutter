import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_format.dart';
import '../../../../../core/utils/reference_range.dart';
import '../../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_autocomplete.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_date_field.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_history_autocomplete.dart';
import '../../../../../design_system/widgets/app_quantity_field.dart';
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
    return '${cell.minText} – ${cell.maxText}';
  }
  if (min != null) return '≥ ${cell.minText}';
  if (max != null) return '≤ ${cell.maxText}';
  return AppText.t('أدخل النتيجة', 'Enter result');
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
      borderRadius: BorderRadius.circular(AppRadii.sm),
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
  const FormSectionCard({
    super.key,
    required this.title,
    required this.children,
  });
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

  /// Phone layout: every field takes the full width, stacked with generous
  /// gaps and a numbered step marker per group, instead of the desktop's
  /// side-by-side pairs (which squeeze below ~600dp).
  final bool compact;

  /// Inline validation errors keyed by field ('material', 'formula',
  /// 'batch', 'supplier', 'sampleTaker'), computed by the save gate in the
  /// screen so every form factor renders the same messages in place
  /// instead of as toasts.
  final Map<String, String> fieldErrors;

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
    this.compact = false,
    this.fieldErrors = const {},
  });

  bool get hasResults => physical.isNotEmpty || chemical.isNotEmpty;

  Widget basicCard(BuildContext context) {
    final state = context.watch<InspectionFormCubit>().state;
    if (compact) return _basicCardCompact(state);
    return FormSectionCard(
      title: AppText.t('البيانات الأساسية', 'Basic data'),
      children: [
        _materialPicker(
          state.materials,
          state.materialId,
          error: fieldErrors['material'],
        ),
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
                    label: AppText.t('تاريخ الانتهاء', 'Expiry (YYYY-MM-DD)'),
                    controller: expiry,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final m in const [(3, '3M'), (6, '6M'), (9, '9M')])
                        AppButton(
                          small: true,
                          style: AppButtonStyle.secondary,
                          label: m.$2,
                          onPressed: () => expiry.text = _addMonths(
                            date.text.trim().isEmpty
                                ? todayIso()
                                : date.text.trim(),
                            m.$1,
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
                  error: fieldErrors['formula'],
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: AppField(
                  label: AppText.t('رقم التشغيلة', 'Batch no.'),
                  controller: batch,
                  error: fieldErrors['batch'],
                ),
              ),
            ] else ...[
              Expanded(
                child: AppHistoryAutocomplete(
                  label: AppText.t('المورد', 'Supplier'),
                  controller: supplier,
                  options: state.supplierOptions,
                  error: fieldErrors['supplier'],
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
              child: AppQuantityField(
                label: AppText.t('الكمية', 'Quantity'),
                hint: AppText.t('بالطن', 'In tons'),
                controller: qty,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // Product reports are batch-traceability records: no header-level
        // taker — samples carry their own taker, added inside the record.
        if (!isProduct)
          Row(
            children: [
              Expanded(
                child: AppHistoryAutocomplete(
                  label: AppText.t('آخذ العينة', 'Sample taker'),
                  controller: sampleTaker,
                  options: state.sampleTakerOptions,
                  error: fieldErrors['sampleTaker'],
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
          )
        else
          Row(
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
      ],
    );
  }

  /// Phone version of the basics card: one field per line with a numbered
  /// step marker per group, so nothing ever squeezes side-by-side.
  Widget _basicCardCompact(dynamic state) {
    Widget step(int n, String label, Widget field) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24.r,
                height: 24.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(alpha: 0.12),
                ),
                child: Text(
                  '$n',
                  style: TextStyle(
                    fontSize: 13.spMax,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.spMax,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          field,
        ],
      );
    }

    final expiryField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppDateField(
          label: AppText.t('تاريخ الانتهاء', 'Expiry (YYYY-MM-DD)'),
          controller: expiry,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final m in const [(3, '3M'), (6, '6M'), (9, '9M')])
              AppButton(
                small: true,
                style: AppButtonStyle.secondary,
                label: m.$2,
                onPressed: () => expiry.text = _addMonths(
                  date.text.trim().isEmpty ? todayIso() : date.text.trim(),
                  m.$1,
                ),
              ),
          ],
        ),
      ],
    );

    final entryField = Row(
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
    );

    var n = 0;
    final groups = <Widget>[];
    void add(String label, Widget field) {
      if (groups.isNotEmpty) {
        groups.add(const SizedBox(height: AppSpacing.md));
      }
      groups.add(step(++n, label, field));
    }

    add(
      isProduct
          ? AppText.t('المنتج', 'Product')
          : AppText.t('الخامة', 'Material'),
      _materialPicker(
        state.materials,
        state.materialId,
        error: fieldErrors['material'],
      ),
    );
    add(
      AppText.t('التواريخ', 'Dates'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDateField(
            label: AppText.t('تاريخ الفحص', 'Date (YYYY-MM-DD)'),
            controller: date,
          ),
          const SizedBox(height: AppSpacing.md),
          expiryField,
        ],
      ),
    );
    if (isProduct) {
      add(
        AppText.t('التشغيلة', 'Batch'),
        AppField(
          label: AppText.t('رقم الفورمولا', 'Formula no.'),
          controller: formula,
          error: fieldErrors['formula'],
        ),
      );
      add(
        AppText.t('رقم التشغيلة', 'Batch no.'),
        AppField(
          label: AppText.t('رقم التشغيلة', 'Batch no.'),
          controller: batch,
          error: fieldErrors['batch'],
        ),
      );
    } else {
      add(
        AppText.t('المورد', 'Supplier'),
        AppHistoryAutocomplete(
          label: AppText.t('المورد', 'Supplier'),
          controller: supplier,
          options: state.supplierOptions,
          error: fieldErrors['supplier'],
          hint: AppText.t(
            'اكتب للبحث في موردي الخامة…',
            'Type to search this material\u2019s suppliers…',
          ),
        ),
      );
      add(
        AppText.t('الشاحنة', 'Truck'),
        AppField(
          label: AppText.t('رقم الشاحنة', 'Truck no.'),
          controller: truck,
        ),
      );
    }
    add(
      AppText.t('الكمية', 'Quantity'),
      AppQuantityField(
        label: AppText.t('الكمية', 'Quantity'),
        hint: AppText.t('بالطن', 'In tons'),
        controller: qty,
      ),
    );
    // Product reports are batch-traceability records: no header-level
    // taker — samples carry their own taker, added inside the record.
    if (!isProduct) {
      add(
        AppText.t('آخذ العينة', 'Sample taker'),
        AppHistoryAutocomplete(
          label: AppText.t('آخذ العينة', 'Sample taker'),
          controller: sampleTaker,
          options: state.sampleTakerOptions,
          error: fieldErrors['sampleTaker'],
          hint: AppText.t(
            'اكتب للبحث في سجل الفنيين…',
            'Type to search the technicians log…',
          ),
        ),
      );
    }
    add(AppText.t('القيد', 'Record'), entryField);

    return FormSectionCard(
      title: AppText.t('البيانات الأساسية', 'Basic data'),
      children: groups,
    );
  }

  Widget physicalCard(BuildContext context) {
    if (physical.isEmpty) return const SizedBox.shrink();
    final state = context.watch<InspectionFormCubit>().state;
    return FormSectionCard(
      title: AppText.t('النتائج الفيزيائية', 'Physical results'),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final grid = _physicalGrid(physical, state.physicalReference);
            // Stacked cards need no horizontal scroll on phones.
            if (constraints.maxWidth < AppBreakpoints.medium) return grid;
            return _scrollableGrid(grid);
          },
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
        LayoutBuilder(
          builder: (context, constraints) {
            final grid = _chemicalGrid(chemical, state.chemicalReference);
            if (constraints.maxWidth < AppBreakpoints.medium) return grid;
            return _scrollableGrid(grid);
          },
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
        AppDropdown<String>(
          value: state.decision,
          labelText: AppText.t('القرار', 'Decision'),
          items: [
            AppDropdownItem(
              value: 'APPROVED',
              label: AppText.t('قبول نهائي', 'Approved'),
            ),
            AppDropdownItem(
              value: 'CONDITIONAL_APPROVAL',
              label: AppText.t('قبول مشروط', 'Conditional'),
            ),
            AppDropdownItem(
              value: 'PARTIAL_REJECTION',
              label: AppText.t('رفض جزئي', 'Partial rejection'),
            ),
            AppDropdownItem(
              value: 'FULL_REJECTION',
              label: AppText.t('رفض كامل', 'Full rejection'),
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
            hint: AppText.t('اختياري', 'Optional'),
            controller: followUp,
            maxLines: 3,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (state.decision == 'PARTIAL_REJECTION') ...[
          AppQuantityField(
            label: AppText.t('الكمية المرفوضة', 'Rejected quantity'),
            controller: rejectedQty,
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
    int? selectedId, {
    String? error,
  }) {
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
                  return '${m['material_name']}'.toLowerCase().contains(
                        query,
                      ) ||
                      '${m['material_code']}'.toLowerCase().contains(query);
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
                    ? AppText.t('لا يوجد منتج مطابق', 'No matching product')
                    : AppText.t('لا توجد خامة مطابقة', 'No matching material'),
                dropdownLabel: AppText.t('عرض القائمة', 'Show the list'),
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
        if (error != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            error,
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 12.spMax,
            ),
          ),
        ],
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Phones: stacked cards instead of a squeezed table.
        if (constraints.maxWidth < AppBreakpoints.medium) {
          return Column(
            children: [
              for (final param in source.keys)
                _physicalParamCard(param, source[param]!, refs[param]),
            ],
          );
        }
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
                  flex: 2,
                  child: Text(
                    AppText.t('النطاق', 'Range'),
                    textAlign: TextAlign.center,
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
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
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
                    Expanded(flex: 2, child: _rangeCell(refs[param])),
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
      },
    );
  }

  /// One physical parameter as a stacked card (phones).
  Widget _physicalParamCard(
    String param,
    List<TextEditingController> ctrls,
    Object? ref,
  ) {
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      color: AppColors.surfaceSoft,
      enableHover: false,
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
                  fontWeight: FontWeight.w700,
                  fontSize: 14.spMax,
                ),
              ),
              if (isReferenceRequired(ref)) const RequiredBadge(),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          _rangeCell(ref, alignCenter: false),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < sampleCount; i++) ...[
            if (sampleCount > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text(
                  sampleNames[i].text.trim().isEmpty
                      ? AppText.t('عينة ${i + 1}', 'Sample ${i + 1}')
                      : sampleNames[i].text.trim(),
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            _physicalInput(param, ctrls[i], '$ref'),
            if (i < sampleCount - 1) const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
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
                padding: const EdgeInsets.only(top: AppSpacing.xxs),
                child: TextField(
                  controller: ctrl,
                  onSubmitted: (_) => normalize(),
                  decoration: _inputDec(
                    out,
                    hint: AppText.t('أدخل النتيجة', 'Enter result'),
                  ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Phones: one stacked card per parameter (range + full-width inputs)
        // instead of a squeezed multi-column table.
        if (constraints.maxWidth < AppBreakpoints.medium) {
          return Column(
            children: [
              for (final param in source.keys)
                _chemicalParamCard(param, source[param]!, refs[param]),
            ],
          );
        }
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
                  flex: 2,
                  child: Text(
                    AppText.t('النطاق', 'Range'),
                    textAlign: TextAlign.center,
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
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
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
                    Expanded(flex: 2, child: _rangeCell(refs[param])),
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
      },
    );
  }

  /// One parameter as a stacked card (phones): name + range on top,
  /// full-width result inputs below.
  Widget _chemicalParamCard(
    String param,
    List<TextEditingController> ctrls,
    Object? ref,
  ) {
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      color: AppColors.surfaceSoft,
      enableHover: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      param,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.spMax,
                      ),
                    ),
                    if (isReferenceRequired(ref)) const RequiredBadge(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          _rangeCell(ref, alignCenter: false),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < sampleCount; i++) ...[
            if (sampleCount > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text(
                  sampleNames[i].text.trim().isEmpty
                      ? AppText.t('عينة ${i + 1}', 'Sample ${i + 1}')
                      : sampleNames[i].text.trim(),
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            _chemicalInput(_chemCell(ref), ctrls[i]),
            if (i < sampleCount - 1) const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  /// Formatted acceptable range + unit chip (single column replaces the old
  /// Min/Max pair, whose raw `-`/fragments looked broken).
  Widget _rangeCell(Object? ref, {bool alignCenter = true}) {
    final range = formatReferenceRange(ref);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: alignCenter ? WrapAlignment.center : WrapAlignment.start,
        children: [
          Text(
            range.display,
            textAlign: alignCenter ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 13.spMax,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (range.unit.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadii.xl),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.25),
                ),
              ),
              child: Text(
                range.unit,
                style: TextStyle(
                  fontSize: 11.spMax,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sampleHeader(int index) {
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
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.sm,
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
                padding: const EdgeInsets.only(top: AppSpacing.xxs),
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
                padding: const EdgeInsetsDirectional.only(
                  start: AppSpacing.xs,
                  top: AppSpacing.xxs,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSoft,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
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
