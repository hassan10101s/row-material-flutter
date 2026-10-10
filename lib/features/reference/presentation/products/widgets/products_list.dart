import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_format.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';

/// Small list widgets for the products tab, composed by both variants.

class ProductsHeader extends StatelessWidget {
  const ProductsHeader({super.key, required this.onAdd, this.compact = false});

  final VoidCallback onAdd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      AppText.t('المنتجات', 'Products'),
      style: Theme.of(context).textTheme.titleLarge,
    );
    if (!compact) {
      return Row(
        children: [
          title,
          const Spacer(),
          AppButton(
            small: true,
            icon: Icon(Icons.add, size: 16.r),
            label: AppText.t('منتج جديد', 'New Product'),
            onPressed: onAdd,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onAdd,
            icon: Icon(Icons.add, size: 20.r),
            label: Text(AppText.t('منتج جديد', 'New Product')),
          ),
        ),
      ],
    );
  }
}

/// Desktop: the pre-split table + the ranges card beneath it, verbatim.
class ProductsTable extends StatelessWidget {
  const ProductsTable({
    super.key,
    required this.rows,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row) onEdit;
  final void Function(Map<String, dynamic> row) onDelete;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Flexible(
            flex: 5,
            child: AppCard(
              padding: EdgeInsets.zero,
              child: SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: [
                        DataColumn(
                          label: Text(AppText.t('المنتج', 'Product')),
                        ),
                        DataColumn(
                          label: Text(AppText.t('النوع', 'Category')),
                        ),
                        DataColumn(
                          label: Text(AppText.t('الوصف', 'Description')),
                        ),
                        DataColumn(
                          label: Text(AppText.t('الإجراءات', 'Actions')),
                        ),
                      ],
                      rows: [
                        for (final p in rows)
                          DataRow(
                            cells: [
                              DataCell(
                                Text(
                                  '${p['name'] ?? ''}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              DataCell(Text('${p['category'] ?? '-'}')),
                              DataCell(Text('${p['description'] ?? '-'}')),
                              DataCell(
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: AppStrings.edit,
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () => onEdit(p),
                                      icon: Icon(
                                        Icons.edit_outlined,
                                        size: 18.r,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: AppStrings.delete,
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () => onDelete(p),
                                      icon: Icon(
                                        Icons.delete_outline,
                                        size: 18.r,
                                        color: AppColors.danger,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (rows.isNotEmpty)
            Flexible(
              flex: 3,
              child: AppCard(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppText.t('النطاقات', 'Ranges'),
                        style: TextStyle(
                          fontSize: 14.spMax,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      for (final p in rows)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: AppSpacing.sm,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${p['name'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 13.spMax,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              RangesChips(p['ranges'] as List? ?? []),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Analysis-range chips, shared by the desktop ranges card and mobile cards.
class RangesChips extends StatelessWidget {
  const RangesChips(this.ranges, {super.key});

  final List<dynamic> ranges;

  @override
  Widget build(BuildContext context) {
    if (ranges.isEmpty) return const Text('—');
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final r in ranges)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.surfaceSoft,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.borderMuted),
            ),
            child: Text(
              '${r['analysis_name'] ?? ''}: '
              '${r['min_value'] ?? '-'} - ${r['max_value'] ?? '-'} '
              '${r['unit'] ?? ''}',
              style: TextStyle(fontSize: 12.spMax),
            ),
          ),
      ],
    );
  }
}

/// Reference chips for one product: physical + chemical entries from the
/// reference maps (مطلوب entries get a check), falling back to the legacy
/// ranges table for products saved before the reference editor.
class ProductRefChips extends StatelessWidget {
  const ProductRefChips(this.product, {super.key});

  final Map<String, dynamic> product;

  @override
  Widget build(BuildContext context) {
    final physical = product['physical_reference'] is Map
        ? Map<String, dynamic>.from(product['physical_reference'] as Map)
        : <String, dynamic>{};
    final chemical = product['chemical_reference'] is Map
        ? Map<String, dynamic>.from(product['chemical_reference'] as Map)
        : <String, dynamic>{};
    if (physical.isEmpty && chemical.isEmpty) {
      return RangesChips(product['ranges'] as List? ?? []);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _refSection(
          AppText.t('الفحص الظاهري', 'Physical'),
          physical,
        ),
        _refSection(
          AppText.t('التحليل الكيميائي', 'Chemical'),
          chemical,
        ),
      ],
    );
  }

  Widget _refSection(String title, Map<String, dynamic> map) {
    if (map.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12.spMax,
            color: AppColors.textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final e in map.entries)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: isReferenceRequired(e.value)
                      ? AppColors.primary.withValues(alpha: 0.10)
                      : AppColors.surfaceSoft,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isReferenceRequired(e.value)
                        ? AppColors.primary.withValues(alpha: 0.4)
                        : AppColors.borderMuted,
                  ),
                ),
                child: Text(
                  '${isReferenceRequired(e.value) ? '✓ ' : ''}${e.key}: '
                  '${referenceValueText(e.value)}',
                  style: TextStyle(fontSize: 12.spMax),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Mobile card list: product + ranges inline (no table, no split panes).
class ProductsCards extends StatelessWidget {
  const ProductsCards({
    super.key,
    required this.rows,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic> row) onEdit;
  final void Function(Map<String, dynamic> row) onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (context, index) {
        final p = rows[index];
        return ProductCard(
          name: '${p['name'] ?? ''}',
          category: '${p['category'] ?? '-'}',
          description: '${p['description'] ?? '-'}',
          product: p,
          onEdit: () => onEdit(p),
          onDelete: () => onDelete(p),
        );
      },
    );
  }
}

class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.name,
    required this.category,
    required this.description,
    required this.product,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final String category;
  final String description;
  final Map<String, dynamic> product;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.spMax,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textStrong,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '$category • $description',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                onPressed: onEdit,
                icon: Icon(Icons.edit_outlined, size: 20.r),
              ),
              IconButton(
                tooltip: AppStrings.delete,
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                onPressed: onDelete,
                icon: Icon(
                  Icons.delete_outline,
                  size: 20.r,
                  color: AppColors.danger,
                ),
              ),
            ],
          ),
          const Divider(height: AppSpacing.lg),
          ProductRefChips(product),
        ],
      ),
    );
  }
}
