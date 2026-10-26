import '../../../../design_system/widgets/app_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_lab/core/l10n/app_localizations_x.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_status_badge.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../cubit/dashboard_cubit.dart';
import '../cubit/dashboard_state.dart';

/// Material / supplier / status live in the filter sheet (not inline) to
/// save vertical space; the sticky badge shows how many are active.
Future<void> openDashboardFilterSheet(BuildContext context) async {
  final cubit = context.read<DashboardCubit>();
  final state = cubit.state;
  final options = state.filterOptions;
  if (options == null) return;
  var dMaterial = state.selectedMaterial;
  var dSupplier = state.selectedSupplier;
  var dStatus = state.selectedStatus;

  await showAppOverlay<void>(
    context,
    title: AppText.t('الفلاتر', 'Filters'),
    icon: Icons.filter_alt_outlined,
    builder: (sheetContext, close) {
      return StatefulBuilder(
        builder: (context, setDraft) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DashboardFilterDropdown(
                label: context.l10n.dashboard_material,
                value: dMaterial,
                items: options.materials,
                onChanged: (v) => setDraft(() => dMaterial = v ?? 'ALL'),
              ),
              const SizedBox(height: AppSpacing.md),
              DashboardFilterDropdown(
                label: context.l10n.dashboard_supplier,
                value: dSupplier,
                items: options.suppliers,
                onChanged: (v) => setDraft(() => dSupplier = v ?? 'ALL'),
              ),
              const SizedBox(height: AppSpacing.md),
              DashboardFilterDropdown(
                label: context.l10n.dashboard_status,
                value: dStatus,
                items: [
                  for (final st in options.statuses)
                    {'id': st, 'name': dashboardStatusLabel(st)},
                ],
                onChanged: (v) => setDraft(() => dStatus = v ?? 'ALL'),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      child: AppButton(
                        label: AppText.t('مسح', 'Clear'),
                        style: AppButtonStyle.secondary,
                        expanded: true,
                        onPressed: () {
                          cubit.clearFilters();
                          close();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      child: AppButton(
                        label: AppText.t('تطبيق', 'Apply'),
                        expanded: true,
                        onPressed: () {
                          cubit.setMaterial(dMaterial);
                          cubit.setSupplier(dSupplier);
                          cubit.setStatus(dStatus);
                          close();
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    },
  );
}

String dashboardStatusLabel(String status) {
  if (status == 'ALL') return AppText.t('جميع الحالات', 'All Statuses');
  return statusLabel(status);
}

/// How many of material / supplier / status differ from ALL: the sticky
/// filter badge count.
int dashboardActiveFilterCount(DashboardState state) => [
  state.selectedMaterial,
  state.selectedSupplier,
  state.selectedStatus,
].where((v) => v != 'ALL').length;

/// Live result line under the filters: how many inspections match plus the
/// latest one. Hidden until the first summary arrives.

class DashboardFilterDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<Map<String, dynamic>> items;
  final ValueChanged<String?> onChanged;
  const DashboardFilterDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return AppDropdown<String>(
      value: items.any((i) => i['id'] == value) ? value : 'ALL',
      labelText: label,
      items: [
        for (final item in items)
          AppDropdownItem(value: '${item['id']}', label: '${item['name']}'),
      ],
      onChanged: onChanged,
    );
  }
}
