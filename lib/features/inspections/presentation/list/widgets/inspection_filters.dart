import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_status_badge.dart'
    show statusLabel;
import '../../../../reference/domain/reference_repository.dart';
import '../../cubit/inspections_state.dart';

/// Filter chrome for the inspection registers (raw + product share it).
///
/// Same UX as the lab test-history table: a [InspectionFilterButton] with an
/// active-count badge opens the filter dialog/sheet ([inspectionFilterGrid]),
/// and [InspectionFilterChips] shows the active filters with per-chip delete.
/// The raw and product registers share these widgets through their shared
/// list screens, so the two tables can never diverge.

/// Statuses offered in the filter dialog (`''` = All).
const List<String> inspectionFilterStatuses = [
  '',
  'PENDING',
  'APPROVED',
  'CONDITIONAL_APPROVAL',
  'PARTIAL_REJECTION',
  'FULL_REJECTION',
];

/// Dropdown options for the material/product filter as `(id, name)` records:
/// active reference materials on the raw register, active lab products on the
/// product register. Best-effort: a failure yields an empty list and the
/// dropdown offers All only — the filter must never break the register.
Future<List<({int id, String name})>> loadInspectionMaterialOptions({
  required ReferenceRepository ref,
  required bool isProduct,
}) async {
  try {
    if (isProduct) {
      final products = await ref.listProductsForInspection();
      return [
        for (final p in products)
          (id: (p['id'] as num).toInt(), name: '${p['name'] ?? ''}'.trim()),
      ];
    }
    final materials = await ref.listMaterials();
    return [
      for (final m in materials)
        (
          id: (m['id'] as num).toInt(),
          name: '${m['material_name'] ?? ''}'.trim(),
        ),
    ];
  } catch (_) {
    return const [];
  }
}

/// Display name for [id] from [options]. Falls back to [previous] (the option
/// may have left the catalog since it was picked) and finally to `#id`, so
/// the chip never renders blank.
String inspectionMaterialNameFor(
  List<({int id, String name})> options,
  int? id,
  String previous,
) {
  if (id == null) return '';
  for (final option in options) {
    if (option.id == id) return option.name;
  }
  return previous.isNotEmpty ? previous : '#$id';
}

/// `yyyy-MM-dd` of today (or of [when] in tests).
String inspectionDayIso([DateTime? when]) {
  final d = when ?? DateTime.now();
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}

/// `yyyy-MM-dd` of [days] ago (inclusive window start for presets).
String inspectionDaysAgoIso(int days, [DateTime? when]) {
  final d = (when ?? DateTime.now()).subtract(Duration(days: days - 1));
  return inspectionDayIso(d);
}

/// How many filter groups are active (status, material/product and/or dates).
int inspectionActiveFilterCount(InspectionsState state) {
  var count = 0;
  if (state.status.isNotEmpty) count++;
  if (state.materialId != null) count++;
  if (state.dateFrom.isNotEmpty || state.dateTo.isNotEmpty) count++;
  return count;
}

/// Active-filter chips (`status`, material/product and/or `dates`),
/// mirroring the lab chips.
List<({String key, String label})> inspectionFilterChips(
  InspectionsState state, {
  bool isProduct = false,
}) {
  final chips = <({String key, String label})>[];
  if (state.status.isNotEmpty) {
    chips.add((
      key: 'status',
      label: '${AppText.t('الحالة', 'Status')}: ${statusLabel(state.status)}',
    ));
  }
  if (state.materialId != null) {
    final kindLabel = isProduct
        ? AppText.t('المنتج', 'Product')
        : AppText.t('الخامة', 'Material');
    final name = state.materialName.isEmpty
        ? '#${state.materialId}'
        : state.materialName;
    chips.add((key: 'material', label: '$kindLabel: $name'));
  }
  if (state.dateFrom.isNotEmpty || state.dateTo.isNotEmpty) {
    final from = state.dateFrom.isEmpty
        ? '…'
        : parseIsoToDisplay(state.dateFrom) ?? state.dateFrom;
    final to = state.dateTo.isEmpty
        ? '…'
        : parseIsoToDisplay(state.dateTo) ?? state.dateTo;
    chips.add((
      key: 'dates',
      label: '${AppText.t('التاريخ', 'Date')}: $from → $to',
    ));
  }
  return chips;
}

/// Filter button with active-count badge, same visuals as the lab table.
class InspectionFilterButton extends StatelessWidget {
  final int activeCount;
  final VoidCallback onPressed;

  const InspectionFilterButton({
    super.key,
    required this.activeCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final active = activeCount > 0;
    return AppButton(
      label: active
          ? AppText.t('فلترة ($activeCount)', 'Filter ($activeCount)')
          : AppText.t('فلترة', 'Filter'),
      icon: Icon(Icons.filter_alt_outlined, size: 16.r),
      style: active ? AppButtonStyle.primary : AppButtonStyle.secondary,
      small: true,
      onPressed: onPressed,
    );
  }
}

/// Active-filter chips + clear-all, mirroring the lab chips row.
class InspectionFilterChips extends StatelessWidget {
  final List<({String key, String label})> chips;
  final ValueChanged<String> onClearChip;
  final VoidCallback onClearAll;

  const InspectionFilterChips({
    super.key,
    required this.chips,
    required this.onClearChip,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            AppText.t('الفلاتر:', 'Filters:'),
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
          for (final chip in chips)
            InputChip(
              visualDensity: VisualDensity.compact,
              label: Text(
                chip.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.spMax),
              ),
              onDeleted: () => onClearChip(chip.key),
            ),
          AppButton(
            label: AppText.t('مسح الكل', 'Clear all'),
            style: AppButtonStyle.ghost,
            small: true,
            onPressed: onClearAll,
          ),
        ],
      ),
    );
  }
}

/// Status + material/product + date-period grid. Width-responsive by
/// construction (Wraps), so it renders identically in the desktop window and
/// the mobile bottom sheet — same pattern as the lab `testHistoryFilterGrid`.
class InspectionFilterGrid extends StatelessWidget {
  final String status;
  final String dateFrom;
  final String dateTo;
  final ValueChanged<String> onStatus;
  final ValueChanged<String> onFrom;
  final ValueChanged<String> onTo;
  final Future<void> Function(bool isFrom) onPickDate;

  /// Dropdown label (`الخامة` on the raw register, `المنتج` on products).
  final String materialLabel;

  /// Catalog options for the dropdown; empty while still loading.
  final List<({int id, String name})> materialOptions;

  /// Selected option id; null = all.
  final int? selectedMaterialId;
  final ValueChanged<int?> onMaterial;
  final bool isProduct;

  const InspectionFilterGrid({
    super.key,
    required this.status,
    required this.dateFrom,
    required this.dateTo,
    required this.onStatus,
    required this.onFrom,
    required this.onTo,
    required this.onPickDate,
    required this.materialLabel,
    this.materialOptions = const [],
    this.selectedMaterialId,
    required this.onMaterial,
    // Products carry no header decision, so the status row is hidden.
    this.isProduct = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _label(materialLabel),
        const SizedBox(height: AppSpacing.xs),
        AppDropdown<int?>(
          value: selectedMaterialId,
          items: [
            AppDropdownItem(value: null, label: AppText.t('الكل', 'All')),
            for (final option in materialOptions)
              AppDropdownItem(value: option.id, label: option.name),
          ],
          onChanged: onMaterial,
        ),
        // Products carry no header decision: no status filter row.
        if (!isProduct) ...[
          const SizedBox(height: AppSpacing.md),
          _label(AppText.t('الحالة', 'Status')),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final s in inspectionFilterStatuses)
                ChoiceChip(
                  label: Text(
                    s.isEmpty ? AppText.t('الكل', 'All') : statusLabel(s),
                  ),
                  selected: status == s,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => onStatus(s),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        _label(AppText.t('الفترة', 'Period')),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            _periodChip(
              context,
              label: AppText.t('الكل', 'All'),
              selected: dateFrom.isEmpty && dateTo.isEmpty,
              onTap: () {
                onFrom('');
                onTo('');
              },
            ),
            _periodChip(
              context,
              label: AppText.t('اليوم', 'Today'),
              selected: _isPreset(inspectionDayIso(), inspectionDayIso()),
              onTap: () {
                final today = inspectionDayIso();
                onFrom(today);
                onTo(today);
              },
            ),
            _periodChip(
              context,
              label: AppText.t('آخر ٧ أيام', 'Last 7 days'),
              selected: _isPreset(inspectionDaysAgoIso(7), inspectionDayIso()),
              onTap: () {
                onFrom(inspectionDaysAgoIso(7));
                onTo(inspectionDayIso());
              },
            ),
            _periodChip(
              context,
              label: AppText.t('آخر ٣٠ يومًا', 'Last 30 days'),
              selected: _isPreset(inspectionDaysAgoIso(30), inspectionDayIso()),
              onTap: () {
                onFrom(inspectionDaysAgoIso(30));
                onTo(inspectionDayIso());
              },
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _label(AppText.t('نطاق مخصص', 'Custom range')),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppButton(
              small: true,
              style: AppButtonStyle.secondary,
              label: dateFrom.isEmpty
                  ? AppText.t('من: —', 'From: —')
                  : '${AppText.t('من', 'From')}: ${parseIsoToDisplay(dateFrom) ?? dateFrom}',
              icon: Icon(Icons.date_range_outlined, size: 16.r),
              onPressed: () => onPickDate(true),
            ),
            AppButton(
              small: true,
              style: AppButtonStyle.secondary,
              label: dateTo.isEmpty
                  ? AppText.t('إلى: —', 'To: —')
                  : '${AppText.t('إلى', 'To')}: ${parseIsoToDisplay(dateTo) ?? dateTo}',
              icon: Icon(Icons.date_range_outlined, size: 16.r),
              onPressed: () => onPickDate(false),
            ),
          ],
        ),
      ],
    );
  }

  bool _isPreset(String from, String to) => dateFrom == from && dateTo == to;

  Widget _periodChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: AppSpacing.xs),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: TextStyle(
        color: AppColors.textMuted,
        fontSize: 11.spMax,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
