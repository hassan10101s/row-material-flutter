import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../../cubit/products_cubit.dart';
import '../../cubit/products_state.dart';
import 'product_editor.dart';
import '../widgets/products_list.dart';

/// Mobile products tab: searchable infinite cards with inline references +
/// the shared editor as a full-screen route (mirrors `MobileMaterialsTab`).
class MobileProductsTab extends StatefulWidget {
  const MobileProductsTab({super.key});

  @override
  State<MobileProductsTab> createState() => _MobileProductsTabState();
}

class _MobileProductsTabState extends State<MobileProductsTab> {
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
      context.read<ProductsCubit>().setQuery(_searchCtrl.text.trim());
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
    Map<String, dynamic>? product,
  ]) async {
    final cubit = context.read<ProductsCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) =>
            MobileProductEditor(productsCubit: cubit, product: product),
      ),
    );
    if (saved != true || !context.mounted) return;
    await context.read<ProductsCubit>().load();
    if (context.mounted) {
      AppFeedback.success(context, AppText.t('تم الحفظ', 'Saved'));
    }
  }

  Future<void> _delete(
    BuildContext context,
    Map<String, dynamic> product,
  ) async {
    final cubit = context.read<ProductsCubit>();
    final name = '${product['name'] ?? ''}';
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف المنتج', 'Delete product'),
      name: name,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await cubit.delete((product['id'] as num).toInt());
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ProductsCubit>();
    final state = context.watch<ProductsCubit>().state;
    return AppErrorFeedback<ProductsCubit, ProductsState>(
      selector: (s) => s.error,
      // Add floats like the raw-material register (heroTag null: sibling
      // tabs share one IndexedStack).
      child: Scaffold(
        floatingActionButton: FloatingActionButton(
          heroTag: null,
          tooltip: AppText.t('منتج جديد', 'New Product'),
          onPressed: () => _openEditor(context),
          child: Icon(Icons.add, size: 24.r),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header entrance only (see params_tab for the rationale).
            AppEntrance(
              child: ProductsHeader(
                compact: true,
                showAdd: false,
                subtitle:
                    '${state.hasMore ? '${state.rows.length}+' : '${state.rows.length}'} ${AppText.t('منتج', 'products')}',
                onAdd: () => _openEditor(context),
                canExport: state.rows.isNotEmpty,
                onExportTable: () => TableHtmlExport.export(
                  context,
                  filePrefix: 'products',
                  title: ProductsTable.exportTitle(),
                  headers: ProductsTable.exportHeaders(),
                  rows: ProductsTable.exportRows(state.rows),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AppField(
              label: AppText.t('بحث بالاسم', 'Search by name...'),
              controller: _searchCtrl,
            ),
            const SizedBox(height: AppSpacing.sm),
            if (state.loading && state.rows.isNotEmpty)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _buildBody(context, cubit, state)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ProductsCubit cubit,
    ProductsState state,
  ) {
    if (state.loading && state.rows.isEmpty) {
      return const AppSkeletonList(rows: 6, lines: 3, height: 380);
    }
    if (state.rows.isEmpty && state.error != null) {
      return RefreshIndicator(
        onRefresh: () => cubit.refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            AppEmptyState(
              icon: Icons.cloud_off_outlined,
              title: AppText.t(
                'تعذر تحميل المنتجات',
                'Could not load products',
              ),
              subtitle: state.error,
              action: AppButton(
                style: AppButtonStyle.secondary,
                icon: Icon(Icons.refresh, size: 16.r),
                label: AppText.t('إعادة المحاولة', 'Retry'),
                onPressed: () => cubit.refresh(),
              ),
            ),
          ],
        ),
      );
    }
    if (state.rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => cubit.refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            AppEmptyState(
              icon: Icons.inventory_2_outlined,
              title: state.query.isEmpty
                  ? AppText.t('لا توجد منتجات.', 'No products.')
                  : AppText.t('لا توجد نتائج مطابقة', 'No matching products.'),
              subtitle: state.query.isEmpty
                  ? AppText.t('أضف أول منتج للبدء.', 'Add your first product.')
                  : null,
              action: state.query.isEmpty
                  ? null
                  : AppButton(
                      style: AppButtonStyle.secondary,
                      label: AppText.t('مسح البحث', 'Clear search'),
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
    // NOTE: no nested SingleChildScrollView — AppInfiniteList owns the scroll
    // so pull-to-refresh + auto-load share one controller.
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
            '${state.rows.length} ${AppText.t('منتج', 'products')} • ${AppText.t('نهاية القائمة', 'End of list')}',
        itemBuilder: (context, index) {
          final p = state.rows[index];
          return ProductCard(
            name: '${p['name'] ?? ''}',
            category: '${p['category'] ?? '-'}',
            description: '${p['description'] ?? '-'}',
            product: p,
            onEdit: () => _openEditor(context, p),
            onDelete: () => _delete(context, p),
          );
        },
      ),
    );
  }
}
