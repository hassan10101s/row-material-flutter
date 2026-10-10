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
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../cubit/products_cubit.dart';
import '../../cubit/products_state.dart';
import 'product_editor.dart';
import '../widgets/products_list.dart';

/// Mobile products tab: cards with inline references + the shared editor
/// as a full-screen route (mirrors `MobileMaterialsTab`).
class MobileProductsTab extends StatelessWidget {
  const MobileProductsTab({super.key});

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? product,
  ]) async {
    final cubit = context.read<ProductsCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => MobileProductEditor(
          productsCubit: cubit,
          product: product,
        ),
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
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('حذف المنتج', 'Delete product'),
      message: '${AppText.t('حذف', 'Delete')} "$name"؟',
      danger: true,
      confirmLabel: AppStrings.delete,
      cancelLabel: AppStrings.cancel,
    );
    if (confirmed != true || !context.mounted) return;
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
    final state = context.watch<ProductsCubit>().state;
    return AppErrorFeedback<ProductsCubit, ProductsState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProductsHeader(
            compact: true,
            onAdd: () => _openEditor(context),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isEmpty)
            const AppSkeletonList(rows: 6, lines: 3, height: 380)
          else if (state.rows.isEmpty && state.error != null)
            AppEmptyState(
              icon: Icons.cloud_off_outlined,
              title: AppText.t(
                'تعذر تحميل المنتجات',
                'Could not load products',
              ),
              action: AppButton(
                style: AppButtonStyle.secondary,
                icon: Icon(Icons.refresh, size: 16.r),
                label: AppText.t('إعادة المحاولة', 'Retry'),
                onPressed: () => context.read<ProductsCubit>().load(),
              ),
            )
          else if (state.rows.isEmpty)
            AppEmptyState(
              icon: Icons.inventory_2_outlined,
              title: AppText.t('لا توجد منتجات.', 'No products.'),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    if (state.loading) const LinearProgressIndicator(),
                    ProductsCards(
                      rows: state.rows,
                      onEdit: (p) => _openEditor(context, p),
                      onDelete: (p) => _delete(context, p),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
