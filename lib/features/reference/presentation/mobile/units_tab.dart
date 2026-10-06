import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../cubit/units_cubit.dart';
import '../cubit/units_state.dart';
import '../units_editor.dart';

/// Mobile units settings.
///
/// The table becomes a card per unit, led by the symbol because that is the
/// identity the user scans for and the value the delete confirmation quotes.
/// The 420dp dialog becomes a full-screen route: three text fields plus the
/// on-screen keyboard does not fit a dialog on a 400dp grid.
class MobileUnitsTab extends StatelessWidget {
  const MobileUnitsTab({super.key});

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? unit,
  ]) async {
    final cubit = context.read<UnitsCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => _UnitEditorRoute(onSubmit: cubit.upsert, unit: unit),
      ),
    );
    if (saved != true || !context.mounted) return;
    await cubit.load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> unit) async {
    final cubit = context.read<UnitsCubit>();
    final symbol = '${unit['symbol'] ?? ''}';
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف الوحدة', 'Delete unit'),
      name: symbol,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await cubit.delete(symbol);
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
      await cubit.load();
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UnitsCubit>().state;
    return AppErrorFeedback<UnitsCubit, UnitsState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('إعدادات الوحدات', 'Units Settings'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: () => _openEditor(context),
            icon: Icon(Icons.add, size: 20.r),
            label: Text(AppText.t('وحدة جديدة', 'New Unit')),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isEmpty)
            const AppSkeletonList(rows: 6, lines: 3, height: 380)
          else if (state.rows.isEmpty)
            Expanded(
              child: AppEmptyState(
                icon: Icons.straighten_outlined,
                title: AppText.t('لا توجد وحدات.', 'No units found.'),
                subtitle: AppText.t(
                  'أضف وحدات مثل % و mg/kg و ppm.',
                  'Add units like %, mg/kg, ppm.',
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: state.rows.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final u = state.rows[index];
                  return _UnitCard(
                    symbol: '${u['symbol'] ?? ''}',
                    name: '${u['name'] ?? '-'}',
                    dimension: '${u['dimension'] ?? '-'}',
                    onEdit: () => _openEditor(context, u),
                    onDelete: () => _delete(context, u),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// One unit as a card. The dimension line is omitted rather than shown as a
/// bare dash when unset, so an ungrouped unit does not read as a placeholder
/// the user should fill in.
class _UnitCard extends StatelessWidget {
  const _UnitCard({
    required this.symbol,
    required this.name,
    required this.dimension,
    required this.onEdit,
    required this.onDelete,
  });

  final String symbol;
  final String name;
  final String dimension;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    symbol,
                    style: TextStyle(
                      fontSize: 14.spMax,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textStrong,
                    ),
                  ),
                  if (name.isNotEmpty && name != '-')
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  if (dimension.isNotEmpty && dimension != '-')
                    Text(
                      dimension,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: AppStrings.edit,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onEdit,
              icon: Icon(Icons.edit_outlined, size: 20.r),
            ),
            IconButton(
              tooltip: AppStrings.delete,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onDelete,
              icon: Icon(
                Icons.delete_outline,
                size: 20.r,
                color: AppColors.danger,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The editor as a full-screen route.
class _UnitEditorRoute extends StatelessWidget {
  const _UnitEditorRoute({required this.onSubmit, this.unit});

  final Future<void> Function(String symbol, {String name, String dimension})
  onSubmit;

  final Map<String, dynamic>? unit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(unitsEditorTitle(unit == null))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: UnitsEditor(
            onSubmit: onSubmit,
            unit: unit,
            actions: (_, state) => UnitsEditorActions(state: state),
          ),
        ),
      ),
    );
  }
}
