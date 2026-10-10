import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../cubit/inventory_cubit.dart';
import '../../cubit/inventory_state.dart';
import '../inventory_forms.dart';
import '../widgets/inventory_cards.dart';

/// Mobile inventory: card list + full-screen editors (no DataTable).
class MobileInventoryTab extends StatelessWidget {
  const MobileInventoryTab({super.key});

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? item,
  ]) async {
    final cubit = context.read<InventoryCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => BlocProvider.value(
          value: cubit,
          child: _InventoryEditorRoute(item: item),
        ),
      ),
    );
    if (saved == true) await cubit.load();
  }

  Future<void> _openAdjust(
    BuildContext context,
    Map<String, dynamic> row,
  ) async {
    final cubit = context.read<InventoryCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => BlocProvider.value(
          value: cubit,
          child: _AdjustEditorRoute(item: row),
        ),
      ),
    );
    if (saved == true) await cubit.load();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<InventoryCubit>().state;
    return AppErrorFeedback<InventoryCubit, InventoryState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('المخزون', 'Inventory'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openEditor(context),
              icon: Icon(Icons.add, size: 20.r),
              label: Text(AppText.t('إضافة مادة', 'Add item')),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
          Expanded(
            child: state.loading && state.rows.isEmpty
                ? const AppSkeletonList(rows: 6, lines: 3, height: 380)
                : state.rows.isEmpty
                ? AppEmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: AppText.t('لا توجد مواد', 'No inventory items'),
                  )
                : InventoryCards(
                    rows: state.rows,
                    onEdit: (r) => _openEditor(context, r),
                    onAdjust: (r) => _openAdjust(context, r),
                  ),
          ),
        ],
      ),
    );
  }

}

/// Full-screen editor route sharing the same repo/save as desktop.
class _InventoryEditorRoute extends StatefulWidget {
  const _InventoryEditorRoute({this.item});
  final Map<String, dynamic>? item;
  @override
  State<_InventoryEditorRoute> createState() => _InventoryEditorRouteState();
}

class _InventoryEditorRouteState extends State<_InventoryEditorRoute> {
  final _formKey = GlobalKey<InventoryItemFormState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.item == null
              ? AppText.t('إضافة مادة', 'Add item')
              : AppText.t('تعديل مادة', 'Edit item'),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.pageMobile),
                child: InventoryItemForm(item: widget.item, key: _formKey),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.pageMobile),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(AppText.t('إلغاء', 'Cancel')),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      child: FilledButton(
                        onPressed: () => _formKey.currentState?.save(),
                        child: Text(AppText.t('حفظ', 'Save')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdjustEditorRoute extends StatelessWidget {
  const _AdjustEditorRoute({required this.item});
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppText.t('تسوية الكمية', 'Adjust quantity'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.pageMobile),
          child: InventoryAdjustForm(item: item),
        ),
      ),
    );
  }
}
