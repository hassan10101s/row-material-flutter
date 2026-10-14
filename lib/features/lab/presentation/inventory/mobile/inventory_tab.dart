import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../../../core/formula_engine.dart';
import '../../cubit/inventory_cubit.dart';
import '../../cubit/inventory_state.dart';
import '../desktop/inventory_tab.dart' show DesktopInventoryTab;
import '../inventory_forms.dart';
import '../widgets/inventory_cards.dart';

/// Mobile inventory: searchable infinite card list + full-screen editors.
class MobileInventoryTab extends StatefulWidget {
  const MobileInventoryTab({super.key});

  @override
  State<MobileInventoryTab> createState() => _MobileInventoryTabState();
}

class _MobileInventoryTabState extends State<MobileInventoryTab> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      context.read<InventoryCubit>().setQuery(_searchCtrl.text.trim());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

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
    final cubit = context.read<InventoryCubit>();
    final state = context.watch<InventoryCubit>().state;
    final countLabel = state.hasMore
        ? '${state.rows.length}+'
        : '${state.rows.length}';
    return AppErrorFeedback<InventoryCubit, InventoryState>(
      selector: (s) => s.error,
      // Add floats like the raw-material register (heroTag null: sibling
      // lab tabs share one IndexedStack).
      child: Scaffold(
        floatingActionButton: FloatingActionButton(
          heroTag: null,
          tooltip: AppText.t('إضافة مادة', 'Add item'),
          onPressed: () => _openEditor(context),
          child: Icon(Icons.add, size: 24.r),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppPageHeader(
              title: AppText.t('المخزون', 'Inventory'),
              subtitle: '$countLabel ${AppText.t('صنف', 'items')}',
              icon: Icons.inventory_2_outlined,
              actions: [
                IconButton(
                  tooltip: AppText.t('تصدير جدول', 'Export table'),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: state.rows.isEmpty
                      ? null
                      : () => TableHtmlExport.export(
                          context,
                          filePrefix: 'inventory',
                          title: DesktopInventoryTab.exportTitle(),
                          headers: DesktopInventoryTab.exportHeaders(),
                          rows: DesktopInventoryTab.exportRows(state.rows),
                        ),
                  icon: const Icon(Icons.table_view_outlined),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppField(
              label: AppText.t(
                'بحث بالاسم أو الوحدة',
                'Search name or unit...',
              ),
              controller: _searchCtrl,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
            Expanded(child: _buildBody(context, cubit, state)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    InventoryCubit cubit,
    InventoryState state,
  ) {
    if (state.loading && state.rows.isEmpty) {
      return const AppSkeletonList(rows: 6, lines: 3, height: 380);
    }
    if (state.rows.isEmpty) {
      if (state.error != null) {
        return RefreshIndicator(
          onRefresh: () => cubit.refresh(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              AppErrorState(
                title: AppText.t('تعذّر التحميل', 'Could not load'),
                subtitle: state.error,
                onRetry: () => cubit.refresh(),
              ),
            ],
          ),
        );
      }
      return RefreshIndicator(
        onRefresh: () => cubit.refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            AppEmptyState(
              icon: Icons.inventory_2_outlined,
              title: state.query.isEmpty
                  ? AppText.t('لا توجد مواد', 'No inventory items')
                  : AppText.t('لا توجد نتائج مطابقة', 'No matching items.'),
              subtitle: state.query.isEmpty
                  ? AppText.t('أضف أول صنف للبدء.', 'Add your first item.')
                  : AppText.t('جرّب مسح البحث.', 'Try clearing the search.'),
              action: state.query.isEmpty
                  ? null
                  : AppButton(
                      label: AppText.t('مسح البحث', 'Clear search'),
                      style: AppButtonStyle.secondary,
                      onPressed: () {
                        _searchCtrl.clear();
                        cubit.setQuery('');
                      },
                    ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => cubit.refresh(),
      child: AppInfiniteList(
        itemCount: state.rows.length,
        hasMore: state.hasMore,
        loadingMore: state.loadingMore,
        errorMore: state.errorMore,
        onLoadMore: () => cubit.loadMore(),
        onRetry: () => cubit.loadMore(),
        totalLabel:
            '${state.rows.length} ${AppText.t('صنف', 'items')} • ${AppText.t('نهاية القائمة', 'End of list')}',
        itemBuilder: (context, index) {
          final r = state.rows[index];
          return InventoryCard(
            name: '${r['name']}',
            category: inventoryCategoryLabel(r['category']),
            qty: '${r['current_qty'] ?? 0} ${r['unit'] ?? ''}',
            status: inventoryStatusText(r),
            statusColor: inventoryStatusColor(r),
            onEdit: () => _openEditor(context, r),
            onAdjust: () => _openAdjust(context, r),
          );
        },
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
                      child: AppButton(
                        label: AppText.t('إلغاء', 'Cancel'),
                        style: AppButtonStyle.secondary,
                        expanded: true,
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      child: AppButton(
                        label: AppText.t('حفظ', 'Save'),
                        expanded: true,
                        onPressed: () => _formKey.currentState?.save(),
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
